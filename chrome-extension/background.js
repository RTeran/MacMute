const NATIVE_HOST = "com.macmute.helper";

let port = null;

function connectNative() {
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST);

    port.onMessage.addListener((message) => {
      console.log("MacMute: Received from native host:", message);
      handleNativeMessage(message);
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

function handleNativeMessage(message) {
  switch (message.type) {
    case "toggle":
      // Forward toggle to all Meet tabs
      sendToMeetTabs({ type: "toggle" });
      break;

    case "get_state":
      // Request state from an active Meet tab
      sendToMeetTabs({ type: "get_state" });
      break;

    default:
      console.log("MacMute: Unknown message type:", message.type);
  }
}

function sendToMeetTabs(message) {
  chrome.tabs.query({ url: "https://meet.google.com/*" }, (tabs) => {
    for (const tab of tabs) {
      chrome.tabs.sendMessage(tab.id, message).catch(() => {
        // Content script not loaded — inject it, then retry
        console.log(`MacMute: Injecting content script into tab ${tab.id}`);
        chrome.scripting
          .executeScript({
            target: { tabId: tab.id },
            files: ["content-script.js"],
          })
          .then(() => {
            // Small delay to let the script initialize
            setTimeout(() => {
              chrome.tabs.sendMessage(tab.id, message).catch((err) => {
                console.log(
                  `MacMute: Still failed for tab ${tab.id}:`,
                  err.message
                );
              });
            }, 200);
          })
          .catch((err) => {
            console.log(`MacMute: Could not inject into tab ${tab.id}:`, err.message);
          });
      });
    }
  });
}

// Track mute state reported by content scripts
let lastKnownMuted = false;

// Listen for messages from content scripts
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "state_update") {
    console.log("MacMute: State update from content script:", message.muted);
    lastKnownMuted = message.muted;
    if (port) {
      port.postMessage({ type: "state_update", muted: message.muted });
    }
  }
  return false;
});

// Unmute when no active Meet tabs remain (closed or suspended)
function checkNoMeetTabsLeft() {
  if (!lastKnownMuted) return;

  chrome.tabs.query({ url: "https://meet.google.com/*" }, (tabs) => {
    if (tabs.length === 0) {
      console.log("MacMute: No active Meet tabs remain, sending unmute");
      lastKnownMuted = false;
      if (port) {
        port.postMessage({ type: "state_update", muted: false });
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
