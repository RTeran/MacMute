// MacMute Content Script for Google Meet
// Detects and controls the mute button and camera button in Google Meet

(function () {
  // Re-injection guard: Chrome may inject this script multiple times per tab.
  // Using window (page global) ensures the guard persists across re-injections.
  if (window.__macMuteLoaded) return;
  window.__macMuteLoaded = true;

  let currentMuteState = null;
  let currentCameraState = null;

  // Selectors for the Meet mute button
  const MUTE_BUTTON_SELECTORS = [
    '[data-is-muted]',
    'button[aria-label*="microphone" i]',
    'button[aria-label*="micrófono" i]',
    'button[aria-label*="mikrofon" i]',
    'button[data-tooltip*="microphone" i]',
    'button[data-tooltip*="micrófono" i]',
  ];

  // Selectors for the Meet camera button
  const CAMERA_BUTTON_SELECTORS = [
    'button[aria-label*="camera" i]',
    'button[aria-label*="cámara" i]',
    'button[aria-label*="kamera" i]',
    'button[data-tooltip*="camera" i]',
    'button[data-tooltip*="cámara" i]',
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

  function findCameraButton() {
    for (const selector of CAMERA_BUTTON_SELECTORS) {
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
    // "desactivar" contains "activar" as a substring, so check it first in the
    // muted (false) block to avoid a false positive on the unmuted (true) block.
    if (
      ariaLabel.includes("unmute") ||
      (ariaLabel.includes("activar") && !ariaLabel.includes("desactivar")) ||
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

  // Returns true if camera is active (on), false if camera is off, null if unknown
  function getCameraState() {
    const button = findCameraButton();
    if (!button) return null;

    const ariaLabel = (button.getAttribute("aria-label") || "").toLowerCase();

    // "turn on camera" → camera is currently OFF
    if (ariaLabel.includes("turn on") || ariaLabel.includes("activar cámara") || ariaLabel.includes("camera einschalten")) {
      return false;
    }
    // "turn off camera" → camera is currently ON
    if (ariaLabel.includes("turn off") || ariaLabel.includes("desactivar cámara") || ariaLabel.includes("kamera ausschalten")) {
      return true;
    }

    // Fallback: check aria-pressed attribute
    const ariaPressed = button.getAttribute("aria-pressed");
    if (ariaPressed !== null) {
      return ariaPressed === "true";
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

  function toggleCamera() {
    const button = findCameraButton();
    if (!button) {
      console.log("MacMute: Camera button not found");
      return;
    }

    button.click();

    // Read new state after a short delay
    setTimeout(() => {
      const newState = getCameraState();
      if (newState !== null) {
        currentCameraState = newState;
        sendCameraStateUpdate(newState);
      }
    }, 200);
  }

  function sendStateUpdate(muted) {
    chrome.runtime.sendMessage({ type: "state_update", muted: muted });
  }

  function sendCameraStateUpdate(active) {
    chrome.runtime.sendMessage({ type: "camera_state_update", active: active });
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

      case "toggle_camera":
        toggleCamera();
        break;

      case "get_camera_state":
        const cameraState = getCameraState();
        if (cameraState !== null) {
          currentCameraState = cameraState;
          sendCameraStateUpdate(cameraState);
        }
        break;
    }
    return false;
  });

  // Observe DOM for mute button appearance and state changes
  const observer = new MutationObserver(() => {
    const newMuteState = getMuteState();
    if (newMuteState !== null && newMuteState !== currentMuteState) {
      currentMuteState = newMuteState;
      sendStateUpdate(newMuteState);
    }

    const newCameraState = getCameraState();
    if (newCameraState !== null && newCameraState !== currentCameraState) {
      currentCameraState = newCameraState;
      sendCameraStateUpdate(newCameraState);
    }
  });

  // Start observing once the page is ready
  function startObserving() {
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-is-muted", "aria-label", "aria-pressed"],
    });

    // Report initial state
    const initialMuteState = getMuteState();
    if (initialMuteState !== null) {
      currentMuteState = initialMuteState;
      sendStateUpdate(initialMuteState);
    }

    const initialCameraState = getCameraState();
    if (initialCameraState !== null) {
      currentCameraState = initialCameraState;
      sendCameraStateUpdate(initialCameraState);
    }
  }

  if (document.body) {
    startObserving();
  } else {
    document.addEventListener("DOMContentLoaded", startObserving);
  }

  console.log("MacMute: Content script loaded on", window.location.href);

  // Test export shim — never runs in the browser (module is undefined there)
  if (typeof module !== "undefined" && module.exports) {
    module.exports = {
      findMuteButton,
      getMuteState,
      toggleMute,
      sendStateUpdate,
      startObserving,
      MUTE_BUTTON_SELECTORS,
      findCameraButton,
      getCameraState,
      toggleCamera,
      sendCameraStateUpdate,
      CAMERA_BUTTON_SELECTORS,
      _getObserver: () => observer,
      _getState: () => ({ currentMuteState, currentCameraState }),
      _setState: (s) => {
        if (s === null) { currentMuteState = null; currentCameraState = null; return; }
        currentMuteState = s.currentMuteState ?? currentMuteState;
        currentCameraState = s.currentCameraState ?? currentCameraState;
      },
    };
  }
})();
