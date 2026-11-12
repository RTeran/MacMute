const NATIVE_HOST = "com.macmute.helper";

let port = null;

function connectNative() {
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST);

    port.onMessage.addListener((message) => {
      console.log("MacMute: Received from native host:", message);
      Promise.resolve(handleNativeMessage(message)).catch((error) => {
        console.error("MacMute: Failed to handle native message:", message, error);
      });
    });

    port.onDisconnect.addListener(() => {
      console.log(
        "MacMute: Native host disconnected:",
        chrome.runtime.lastError?.message
      );
      port = null;
      // Reconnect after a delay
      setTimeout(connectNative, 3000);
    });

    console.log("MacMute: Connected to native host");
  } catch (error) {
    console.error("MacMute: Failed to connect to native host:", error);
    setTimeout(connectNative, 5000);
  }
}

const MEET_URL_PATTERN = "https://meet.google.com/*";
const RECEIVER_MISSING_ERROR = "Receiving end does not exist";
const REINJECT_DELAY_MS = 200;
const TOGGLE_TARGETS = { toggle: "mic", toggle_camera: "camera" };

function postToNative(message) {
  if (!port) {
    // Passive updates are resent on the next change; a lost toggle_result is what the user notices.
    const log = message.type === "toggle_result" ? console.warn : console.debug;
    log("MacMute: Native port not connected, dropping message", message);
    return;
  }
  try {
    port.postMessage(message);
  } catch (error) {
    console.warn("MacMute: native_port_lost, dropping message", { ...message, error: error.message });
  }
}

function handleNativeMessage(message) {
  switch (message.type) {
    case "toggle":
    case "toggle_camera":
      return toggleInMeetTabs(message.type, message.requestId);

    case "get_state":
    case "get_camera_state":
      return broadcastToMeetTabs({ type: message.type });

    default:
      console.log("MacMute: Unknown message type:", message.type);
  }
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class InjectionError extends Error {}

// Only a missing receiver is safe to retry: any other error may come after the
// content script already clicked the button, and a retry would toggle twice.
async function sendToTab(tabId, message) {
  try {
    return await chrome.tabs.sendMessage(tabId, message);
  } catch (error) {
    if (!String(error?.message).includes(RECEIVER_MISSING_ERROR)) throw error;

    console.debug(`MacMute: Injecting content script into tab ${tabId}`);
    try {
      await chrome.scripting.executeScript({
        target: { tabId },
        files: ["content-script.js"],
      });
    } catch (injectionError) {
      throw new InjectionError(injectionError.message);
    }
    await delay(REINJECT_DELAY_MS);
    return chrome.tabs.sendMessage(tabId, message);
  }
}

function toTabResponse(settled) {
  if (settled.status === "rejected") {
    const reason = settled.reason instanceof InjectionError ? "injection_failed" : "send_failed";
    return { ok: false, reason, error: settled.reason?.message };
  }
  return settled.value ?? { ok: false, reason: "no_response" };
}

function aggregateTabResponses(responses) {
  if (responses.length === 0) return { ok: false, reason: "no_meet_tab" };
  return (
    responses.find((response) => response.ok === true) ??
    responses.find((response) => response.reason !== "button_not_found") ??
    responses[0]
  );
}

function buildToggleResult(target, aggregated, requestId) {
  const result = { type: "toggle_result", target, ok: aggregated.ok === true };
  if (result.ok && target === "mic") result.muted = aggregated.after;
  if (result.ok && target === "camera") result.off = !aggregated.after;
  if (!result.ok) result.reason = aggregated.reason;
  if (requestId !== undefined) result.requestId = requestId;
  return result;
}

// Resolves with the first confirmed tab, or with every response once all tabs have answered.
function collectTabResponses(tabs, message) {
  return new Promise((resolve) => {
    const responses = [];
    let pending = tabs.length;
    if (pending === 0) resolve(responses);

    for (const tab of tabs) {
      sendToTab(tab.id, message)
        .then((value) => ({ status: "fulfilled", value }), (reason) => ({ status: "rejected", reason }))
        .then((settled) => {
          const response = toTabResponse(settled);
          responses.push(response);
          pending -= 1;
          if (response.ok === true || pending === 0) resolve(responses);
        });
    }
  });
}

async function toggleInMeetTabs(type, requestId) {
  const target = TOGGLE_TARGETS[type];
  let tabs;
  try {
    tabs = await chrome.tabs.query({ url: MEET_URL_PATTERN });
  } catch (error) {
    console.warn("MacMute: Could not list Meet tabs", error);
    postToNative(buildToggleResult(target, { ok: false, reason: "tabs_query_failed" }, requestId));
    return;
  }
  const responses = await collectTabResponses(tabs, { type });
  const result = buildToggleResult(target, aggregateTabResponses(responses), requestId);

  console.debug("MacMute: Toggle result", { result, tabIds: tabs.map((tab) => tab.id), responses });
  postToNative(result);
}

async function broadcastToMeetTabs(message) {
  const tabs = await chrome.tabs.query({ url: MEET_URL_PATTERN });
  await Promise.allSettled(
    tabs.map((tab) =>
      sendToTab(tab.id, message).catch((err) => {
        console.log(`MacMute: Could not reach tab ${tab.id}:`, err.message);
      })
    )
  );
}

// Track mic and camera state reported by content scripts
let lastKnownMuted = false;
let lastKnownCameraActive = true; // true = camera on

// Listen for messages from content scripts
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "state_update") {
    console.log("MacMute: State update from content script:", message.muted);
    lastKnownMuted = message.muted;
    postToNative({ type: "state_update", muted: message.muted });
  } else if (message.type === "camera_state_update") {
    console.log("MacMute: Camera state update from content script:", message.active);
    lastKnownCameraActive = message.active;
    postToNative({ type: "camera_state_update", active: message.active });
  }
  return false;
});

// Unmute mic and re-enable camera when no active Meet tabs remain (closed or suspended)
function checkNoMeetTabsLeft() {
  chrome.tabs.query({ url: MEET_URL_PATTERN }, (tabs) => {
    if (tabs.length === 0) {
      if (lastKnownMuted) {
        console.log("MacMute: No active Meet tabs remain, sending unmute");
        lastKnownMuted = false;
        postToNative({ type: "state_update", muted: false });
      }
      if (!lastKnownCameraActive) {
        console.log("MacMute: No active Meet tabs remain, restoring camera state");
        lastKnownCameraActive = true;
        postToNative({ type: "camera_state_update", active: true });
      }
    }
  });
}

// Tab closed
chrome.tabs.onRemoved.addListener(() => checkNoMeetTabsLeft());

// Tab URL changed (e.g. hibernated by a tab suspender extension)
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url && !changeInfo.url.startsWith("https://meet.google.com/")) {
    checkNoMeetTabsLeft();
  }
});

// Connect on startup
connectNative();

// Test export shim — never runs in the browser (module is undefined there)
if (typeof module !== "undefined" && module.exports) {
  module.exports = { handleNativeMessage };
}
