const NATIVE_HOST = "com.macmute.helper";

let port = null;

// The helper exits at once when the app rejects it, so a fixed short delay would respawn it
// forever. The delay grows until the app answers on a connection.
const RECONNECT_INITIAL_DELAY_MS = 3000;
const RECONNECT_MAX_DELAY_MS = 5 * 60 * 1000;
let reconnectDelayMs = RECONNECT_INITIAL_DELAY_MS;

// Only the current port's first disconnect or a failed connect gets here, so one timer runs at a time.
function scheduleReconnect() {
  const delayMs = reconnectDelayMs;
  reconnectDelayMs = Math.min(delayMs * 2, RECONNECT_MAX_DELAY_MS);
  console.log(`MacMute: Reconnecting to the native host in ${delayMs / 1000} s`);
  setTimeout(connectNative, delayMs);
}

function connectNative() {
  let connection;
  try {
    connection = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (error) {
    console.error("MacMute: Failed to connect to native host:", error);
    scheduleReconnect();
    return;
  }
  port = connection;
  let answered = false;

  connection.onMessage.addListener((message) => {
    // The helper only relays what the app sends, so any message means the app accepted it.
    answered = true;
    if (connection === port) reconnectDelayMs = RECONNECT_INITIAL_DELAY_MS;
    console.log("MacMute: Received from native host:", message);
    Promise.resolve(handleNativeMessage(message)).catch((error) => {
      console.error("MacMute: Failed to handle native message:", message, error);
    });
  });

  connection.onDisconnect.addListener(() => {
    if (connection !== port) return;
    // Closing before any message means the host is missing, forbidden or rejected by the app.
    const log = answered ? console.log : console.warn;
    log("MacMute: Native host disconnected:", chrome.runtime.lastError?.message);
    port = null;
    scheduleReconnect();
  });

  console.log("MacMute: Connected to native host");
}

const MEET_URL_PREFIX = "https://meet.google.com/";
const MEET_URL_PATTERN = `${MEET_URL_PREFIX}*`;
const RECEIVER_MISSING_ERROR = "Receiving end does not exist";
const REINJECT_DELAY_MS = 200;
const TOGGLE_TARGETS = { toggle: "mic", toggle_camera: "camera" };

// Passive updates are resent on the next change. A dropped toggle result is lost for good. A
// dropped call status or reset is not queued: postCallStatus() sends it in full on the app's
// get_state for the next connection, so a warning is enough here.
function postToNative(message, { mustArrive = message.type === "toggle_result" || message.type === "call_status" } = {}) {
  if (!port) {
    const log = mustArrive ? console.warn : console.debug;
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
      return queryStateAndCall();

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
        files: ["media-session-bridge.js"],
        world: "MAIN",
      });
    } catch (bridgeError) {
      // Without the bridge the content script still confirms through the DOM while Meet renders.
      console.warn("MacMute: could not inject the Media Session bridge", bridgeError.message);
    }
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
  if (result.ok && aggregated.source !== undefined) result.source = aggregated.source;
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
  return Promise.all(
    tabs.map((tab) =>
      sendToTab(tab.id, message).then(
        (response) => ({ tabId: tab.id, reached: true, response }),
        (err) => {
          console.warn(`MacMute: Could not reach tab ${tab.id}:`, err.message);
          return { tabId: tab.id, reached: false, response: undefined };
        }
      )
    )
  );
}

// The service worker loses tabsInCall when Chrome stops it, so the app's get_state on a new
// connection rebuilds it. A tab that could not tell keeps its last known membership.
async function queryStateAndCall() {
  const trackedBefore = [...tabsInCall];
  let answers;
  try {
    answers = await broadcastToMeetTabs({ type: "get_state" });
  } catch (error) {
    console.warn("MacMute: tabs_query_failed while answering get_state", error);
    // Right after a service worker restart nothing is known yet, and a reset could end a live call.
    if (trackedBefore.length > 0) postCallStatus();
    return;
  }
  // Only tabs known before the broadcast: one that joined meanwhile may not be in the list yet.
  const meetTabIds = new Set(answers.map(({ tabId }) => tabId));
  for (const tabId of trackedBefore) {
    if (!meetTabIds.has(tabId)) tabsInCall.delete(tabId);
  }
  for (const { tabId, reached, response } of answers) {
    const inCall = inCallFromAnswer(tabId, reached, response);
    if (inCall === true) tabsInCall.add(tabId);
    if (inCall === false) tabsInCall.delete(tabId);
  }
  postCallStatus();
}

// Undefined when the tab could not tell, so the caller keeps its last known membership.
function inCallFromAnswer(tabId, reached, response) {
  if (typeof response?.inCall === "boolean" && !response.error) return response.inCall;
  if (reached) console.warn(`MacMute: tab ${tabId} could not tell whether it is in a call`, response);
  return undefined;
}

// A finished load may be a reload or a page Meet swapped in without a call_left, so the tab is
// asked again instead of guessing from the load events.
async function recheckTabInCall(tabId) {
  let response;
  try {
    response = await sendToTab(tabId, { type: "get_state" });
  } catch (error) {
    console.warn(`MacMute: Could not reach tab ${tabId}:`, error);
    return;
  }
  // The tab may have left while it was asked; a tab that really rejoins sends its own state update.
  if (!tabsInCall.has(tabId)) return;
  const inCall = inCallFromAnswer(tabId, true, response);
  if (inCall !== undefined) setTabInCall(tabId, inCall);
}

// A new helper connection starts with no call state in the app, so get_state always answers in
// full, including the reset that a call ending while the port was down could not deliver.
function postCallStatus() {
  if (tabsInCall.size > 0) postToNative({ type: "call_status", inCall: true });
  else endCall();
}

const tabsInCall = new Set();

function setTabInCall(tabId, inCall) {
  const wasInCall = tabsInCall.size > 0;
  if (inCall) tabsInCall.add(tabId);
  else tabsInCall.delete(tabId);
  const isInCall = tabsInCall.size > 0;
  if (!wasInCall && isInCall) postToNative({ type: "call_status", inCall: true });
  if (wasInCall && !isInCall) endCall();
}

// The app keeps the last mic and camera state after the call ends, so they are reset here.
function endCall() {
  console.log("MacMute: No Meet tab is in a call anymore, resetting the mic and camera state");
  postToNative({ type: "call_status", inCall: false });
  postToNative({ type: "state_update", muted: false }, { mustArrive: true });
  postToNative({ type: "camera_state_update", active: true }, { mustArrive: true });
}

chrome.runtime.onMessage.addListener((message, sender) => {
  const tabId = sender.tab?.id;
  if (message.type === "state_update") {
    console.log("MacMute: State update from content script:", message.muted);
    if (tabId !== undefined) setTabInCall(tabId, true);
    postToNative({ type: "state_update", muted: message.muted });
  } else if (message.type === "camera_state_update") {
    console.log("MacMute: Camera state update from content script:", message.active);
    if (tabId !== undefined) setTabInCall(tabId, true);
    postToNative({ type: "camera_state_update", active: message.active });
  } else if (message.type === "call_left") {
    console.log(`MacMute: Tab ${tabId} left the call`);
    if (tabId !== undefined) setTabInCall(tabId, false);
  }
  return false;
});

// These events fire for every tab in the browser, so tabs outside a call return at once.
chrome.tabs.onRemoved.addListener((tabId) => {
  if (!tabsInCall.has(tabId)) return;
  setTabInCall(tabId, false);
});

// A tab suspender changes the tab's URL and Chrome's memory saver discards it. Without the "tabs"
// permission, tab.url is only visible while the tab is on Meet, so a missing URL also means it left.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!tabsInCall.has(tabId)) return;
  if (changeInfo.discarded || !tab?.url?.startsWith(MEET_URL_PREFIX)) {
    setTabInCall(tabId, false);
  } else if (changeInfo.status === "complete") {
    recheckTabInCall(tabId).catch((error) => {
      console.warn(`MacMute: Could not check whether tab ${tabId} is still in the call`, error);
    });
  }
});

// Connect on startup
connectNative();

// Test export shim — never runs in the browser (module is undefined there)
if (typeof module !== "undefined" && module.exports) {
  module.exports = { handleNativeMessage };
}
