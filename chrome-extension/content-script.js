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

  // Worst case in a hidden tab: this wait, rounded up by Chrome's ~1 s timer alignment,
  // plus the background's 200 ms reinjection delay. The app waits 2.5 s, so it must stay below that.
  const STATE_CHANGE_TIMEOUT_MS = 1200;

  const STATE_OBSERVER_OPTIONS = {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["data-is-muted", "aria-label", "aria-pressed"],
  };

  const togglesInProgress = new Set();

  function toggleControl(target, findButton, readState, timeoutMs) {
    return new Promise((resolve) => {
      const startedAt = Date.now();
      const visibility = document.visibilityState;
      let settled = false;
      let timer = null;
      let observer = null;

      function finish(result) {
        if (settled) return;
        settled = true;
        observer?.disconnect();
        clearTimeout(timer);
        togglesInProgress.delete(target);
        const fullResult = { ...result, visibility, elapsedMs: Date.now() - startedAt };
        console.debug(`MacMute: ${target} toggle result`, fullResult);
        resolve(fullResult);
      }

      // A second click while the first is unconfirmed would undo it.
      if (togglesInProgress.has(target)) {
        const busy = { ok: false, reason: "busy", before: null, after: null, visibility, elapsedMs: 0 };
        console.debug(`MacMute: ${target} toggle result`, busy);
        resolve(busy);
        return;
      }
      togglesInProgress.add(target);

      try {
        const button = findButton();
        if (!button) {
          finish({ ok: false, reason: "button_not_found", before: null, after: null });
          return;
        }

        const before = readState();
        if (before === null) {
          finish({ ok: false, reason: "state_unknown", before: null, after: null });
          return;
        }

        const checkFlip = () => {
          const after = readState();
          if (after !== null && after !== before) {
            finish({ ok: true, before, after });
          }
        };

        observer = new MutationObserver(checkFlip);
        observer.observe(document.body, STATE_OBSERVER_OPTIONS);
        timer = setTimeout(() => {
          checkFlip();
          finish({ ok: false, reason: "timeout", before, after: readState() });
        }, timeoutMs);

        console.debug(`MacMute: ${target} click`, { before, visibility, at: startedAt });
        button.click();
        checkFlip();
      } catch (error) {
        finish({ ok: false, reason: "exception", error: error.message, before: null, after: null });
      }
    });
  }

  function respondWith(toggle, sendResponse) {
    toggle.then(sendResponse, (error) =>
      sendResponse({ ok: false, reason: "exception", error: error?.message })
    );
  }

  function toggleMute(timeoutMs = STATE_CHANGE_TIMEOUT_MS) {
    return toggleControl("mic", findMuteButton, getMuteState, timeoutMs);
  }

  function toggleCamera(timeoutMs = STATE_CHANGE_TIMEOUT_MS) {
    return toggleControl("camera", findCameraButton, getCameraState, timeoutMs);
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
        respondWith(toggleMute(), sendResponse);
        return true;

      case "get_state":
        const state = getMuteState();
        if (state !== null) {
          currentMuteState = state;
          sendStateUpdate(state);
        }
        break;

      case "toggle_camera":
        respondWith(toggleCamera(), sendResponse);
        return true;

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
    observer.observe(document.body, STATE_OBSERVER_OPTIONS);

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
      STATE_CHANGE_TIMEOUT_MS,
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
