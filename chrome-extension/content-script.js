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

  // Worst case in a hidden tab: this wait, rounded up by Chrome's ~1 s timer alignment, plus the
  // background's 200 ms reinjection delay. It must stay below the app's ConfirmationTimeouts
  // for the same target (3 s mic, 4.5 s camera).
  const MIC_STATE_CHANGE_TIMEOUT_MS = 1200;
  // Turning the camera on in a hidden page takes ~1.2 s to warm up before Meet reports it.
  const CAMERA_STATE_CHANGE_TIMEOUT_MS = 2500;

  const STATE_OBSERVER_OPTIONS = {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["data-is-muted", "aria-label", "aria-pressed"],
  };

  const togglesInProgress = new Set();

  // Same message type as media-session-bridge.js, which runs in the page's MAIN world.
  const MEDIA_SESSION_MESSAGE_TYPE = "macmute:media-session";
  const mediaSessionWaiters = { mic: null, camera: null };

  // The DOM freezes while Chrome does not render Meet (window on another Space), but Meet still
  // reports through the Media Session. This keeps the latest state from either source, so a
  // second toggle in that situation does not start from the frozen DOM.
  const knownState = { mic: null, camera: null };
  // Media Session states seen since the page was last made visible; a hidden DOM that disagrees is stale.
  const mediaSessionSinceVisible = { mic: undefined, camera: undefined };

  function remember(target, state, source) {
    knownState[target] = { state, source, at: Date.now() };
  }

  // Maps "is the device active" to the state each target reads: mic → muted, camera → active.
  const stateFromMediaSession = {
    mic: (active) => !active,
    camera: (active) => active,
  };

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
        mediaSessionWaiters[target] = null;
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

      const failWith = (error) =>
        finish({ ok: false, reason: "exception", error: error?.message, before: null, after: null });
      const guarded = (callback) => () => {
        try {
          callback();
        } catch (error) {
          failWith(error);
        }
      };

      try {
        const button = findButton();
        if (!button) {
          finish({ ok: false, reason: "button_not_found", before: null, after: null });
          return;
        }

        const domBefore = readState();
        if (domBefore === null) {
          finish({ ok: false, reason: "state_unknown", before: null, after: null });
          return;
        }
        const known = knownState[target];
        const before = known?.state ?? domBefore;

        const checkFlip = () => {
          const after = readState();
          if (after !== null && after !== domBefore) {
            finish({ ok: true, before: domBefore, after, source: "dom" });
          }
        };

        mediaSessionWaiters[target] = (state) => {
          if (state !== before) {
            finish({ ok: true, before, after: state, source: "media_session" });
          }
        };

        observer = new MutationObserver(guarded(checkFlip));
        observer.observe(document.body, STATE_OBSERVER_OPTIONS);
        timer = setTimeout(
          guarded(() => {
            checkFlip();
            finish({ ok: false, reason: "timeout", before: domBefore, after: readState() });
          }),
          timeoutMs
        );

        console.debug(`MacMute: ${target} click`, {
          before,
          beforeSource: known?.source ?? "dom",
          domBefore,
          visibility,
          at: startedAt,
        });
        button.click();
        checkFlip();
      } catch (error) {
        failWith(error);
      }
    });
  }

  function respondWith(toggle, sendResponse) {
    toggle.then(sendResponse, (error) =>
      sendResponse({ ok: false, reason: "exception", error: error?.message })
    );
  }

  function toggleMute(timeoutMs = MIC_STATE_CHANGE_TIMEOUT_MS) {
    return toggleControl("mic", findMuteButton, getMuteState, timeoutMs);
  }

  function toggleCamera(timeoutMs = CAMERA_STATE_CHANGE_TIMEOUT_MS) {
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

  function isMediaSessionMessage(event) {
    const data = event.data;
    return (
      event.source === window &&
      data !== null &&
      typeof data === "object" &&
      data.type === MEDIA_SESSION_MESSAGE_TYPE &&
      Object.hasOwn(stateFromMediaSession, data.kind) &&
      typeof data.active === "boolean"
    );
  }

  const findButtonFor = { mic: findMuteButton, camera: findCameraButton };

  // Meet's own page can forge this message; that is acceptable, so only its shape is checked.
  // Meet also calls the Media Session outside our toggles (lobby, leaving, device loss), so a
  // signal only confirms a pending toggle and is never reported to the app on its own.
  window.addEventListener("message", (event) => {
    if (!isMediaSessionMessage(event)) return;
    const { kind, active } = event.data;
    const state = stateFromMediaSession[kind](active);
    console.debug(`MacMute: media session ${kind} active=${active}`);

    remember(kind, state, "media_session");
    mediaSessionSinceVisible[kind] = state;

    const waiter = mediaSessionWaiters[kind];
    if (!waiter) return;
    if (!findButtonFor[kind]()) {
      console.debug(`MacMute: ignoring media session ${kind} signal, no ${kind} button`);
      return;
    }
    waiter(state);
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    mediaSessionSinceVisible.mic = undefined;
    mediaSessionSinceVisible.camera = undefined;
  });

  function reportDomState(target, state) {
    if (state === null) return;
    const mediaSessionState = mediaSessionSinceVisible[target];
    if (document.visibilityState === "hidden" && mediaSessionState !== undefined && state !== mediaSessionState) {
      console.debug(`MacMute: ignoring hidden ${target} DOM state ${state}, media session reported ${mediaSessionState}`);
      return;
    }
    remember(target, state, "dom");
    if (target === "mic" && state !== currentMuteState) {
      currentMuteState = state;
      sendStateUpdate(state);
    } else if (target === "camera" && state !== currentCameraState) {
      currentCameraState = state;
      sendCameraStateUpdate(state);
    }
  }

  // Observe DOM for mute button appearance and state changes
  const observer = new MutationObserver(() => {
    reportDomState("mic", getMuteState());
    reportDomState("camera", getCameraState());
  });

  // Start observing once the page is ready
  function startObserving() {
    observer.observe(document.body, STATE_OBSERVER_OPTIONS);

    // Report initial state
    const initialMuteState = getMuteState();
    if (initialMuteState !== null) {
      remember("mic", initialMuteState, "dom");
      currentMuteState = initialMuteState;
      sendStateUpdate(initialMuteState);
    }

    const initialCameraState = getCameraState();
    if (initialCameraState !== null) {
      remember("camera", initialCameraState, "dom");
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
      MIC_STATE_CHANGE_TIMEOUT_MS,
      CAMERA_STATE_CHANGE_TIMEOUT_MS,
      _getObserver: () => observer,
      _getState: () => ({ currentMuteState, currentCameraState }),
      _setState: (s) => {
        if (s === null) {
          currentMuteState = null;
          currentCameraState = null;
          knownState.mic = null;
          knownState.camera = null;
          mediaSessionSinceVisible.mic = undefined;
          mediaSessionSinceVisible.camera = undefined;
          return;
        }
        currentMuteState = s.currentMuteState ?? currentMuteState;
        currentCameraState = s.currentCameraState ?? currentCameraState;
      },
    };
  }
})();
