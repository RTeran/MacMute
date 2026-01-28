// MacMute Content Script for Google Meet
// Detects and controls the mute button in Google Meet

let currentMuteState = null;
let muteButton = null;

// Selectors for the Meet mute button
const MUTE_BUTTON_SELECTORS = [
  '[data-is-muted]',
  'button[aria-label*="microphone" i]',
  'button[aria-label*="micrófono" i]',
  'button[aria-label*="mikrofon" i]',
  'button[data-tooltip*="microphone" i]',
  'button[data-tooltip*="micrófono" i]',
];

function findMuteButton() {
  for (const selector of MUTE_BUTTON_SELECTORS) {
    const button = document.querySelector(selector);
    if (button) {
      return button;
    }
  }
  return null;
}

function getMuteState() {
  const button = findMuteButton();
  if (!button) return null;

  // Check data-is-muted attribute
  if (button.hasAttribute("data-is-muted")) {
    return button.getAttribute("data-is-muted") === "true";
  }

  // Check aria-label for muted state
  const ariaLabel = (button.getAttribute("aria-label") || "").toLowerCase();
  if (
    ariaLabel.includes("unmute") ||
    ariaLabel.includes("activar") ||
    ariaLabel.includes("turn on")
  ) {
    return true; // Button says "unmute" means mic is currently muted
  }
  if (
    ariaLabel.includes("mute") ||
    ariaLabel.includes("desactivar") ||
    ariaLabel.includes("turn off")
  ) {
    return false; // Button says "mute" means mic is currently unmuted
  }

  return null;
}

function toggleMute() {
  const button = findMuteButton();
  if (!button) {
    console.log("MacMute: Mute button not found");
    return;
  }

  button.click();

  // Read new state after a short delay
  setTimeout(() => {
    const newState = getMuteState();
    if (newState !== null) {
      currentMuteState = newState;
      sendStateUpdate(newState);
    }
  }, 200);
}

function sendStateUpdate(muted) {
  chrome.runtime.sendMessage({ type: "state_update", muted: muted });
}

// Listen for messages from background script
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  switch (message.type) {
    case "toggle":
      toggleMute();
      break;

    case "get_state":
      const state = getMuteState();
      if (state !== null) {
        currentMuteState = state;
        sendStateUpdate(state);
      }
      break;
  }
  return false;
});

// Observe DOM for mute button appearance and state changes
const observer = new MutationObserver(() => {
  const newState = getMuteState();
  if (newState !== null && newState !== currentMuteState) {
    currentMuteState = newState;
    sendStateUpdate(newState);
  }
});

// Start observing once the page is ready
function startObserving() {
  observer.observe(document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["data-is-muted", "aria-label"],
  });

  // Report initial state
  const initialState = getMuteState();
  if (initialState !== null) {
    currentMuteState = initialState;
    sendStateUpdate(initialState);
  }
}

if (document.body) {
  startObserving();
} else {
  document.addEventListener("DOMContentLoaded", startObserving);
}

console.log("MacMute: Content script loaded on", window.location.href);
