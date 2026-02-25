let script;
let messageListener;

beforeAll(() => {
  jest.resetModules();

  global.chrome = {
    runtime: {
      sendMessage: jest.fn(),
      onMessage: {
        addListener: jest.fn(),
      },
    },
  };

  // Ensure the IIFE guard is not set so the module initializes
  delete window.__macMuteLoaded;

  script = require("../../chrome-extension/content-script");

  // Capture the registered listener immediately — before any clearAllMocks() runs
  messageListener = chrome.runtime.onMessage.addListener.mock.calls[0][0];
});

beforeEach(() => {
  document.body.innerHTML = "";
  jest.clearAllMocks();
  script._setState(null);
});

// ---------------------------------------------------------------------------
// findMuteButton
// ---------------------------------------------------------------------------
describe("findMuteButton", () => {
  test("returns null when no mute button exists", () => {
    expect(script.findMuteButton()).toBeNull();
  });

  test("finds button by data-is-muted attribute", () => {
    document.body.innerHTML = '<button data-is-muted="false">Mute</button>';
    const btn = script.findMuteButton();
    expect(btn).not.toBeNull();
    expect(btn.tagName).toBe("BUTTON");
  });

  test("finds button by aria-label containing 'microphone' (case-insensitive)", () => {
    document.body.innerHTML =
      '<button aria-label="Turn off Microphone">Mute</button>';
    expect(script.findMuteButton()).not.toBeNull();
  });

  test("finds button by aria-label 'micrófono'", () => {
    document.body.innerHTML =
      '<button aria-label="Desactivar micrófono"></button>';
    expect(script.findMuteButton()).not.toBeNull();
  });

  test("finds button by aria-label 'mikrofon'", () => {
    document.body.innerHTML =
      '<button aria-label="Mikrofon ausschalten"></button>';
    expect(script.findMuteButton()).not.toBeNull();
  });

  test("finds button by data-tooltip containing 'microphone'", () => {
    document.body.innerHTML =
      '<button data-tooltip="Turn off microphone"></button>';
    expect(script.findMuteButton()).not.toBeNull();
  });

  test("returns first match when multiple selectors match (data-is-muted has priority)", () => {
    document.body.innerHTML = `
      <button id="a" data-is-muted="true"></button>
      <button id="b" aria-label="microphone"></button>
    `;
    const btn = script.findMuteButton();
    expect(btn.id).toBe("a");
  });
});

// ---------------------------------------------------------------------------
// getMuteState
// ---------------------------------------------------------------------------
describe("getMuteState", () => {
  test("returns null when no button is found", () => {
    expect(script.getMuteState()).toBeNull();
  });

  test("returns true when data-is-muted='true'", () => {
    document.body.innerHTML = '<button data-is-muted="true"></button>';
    expect(script.getMuteState()).toBe(true);
  });

  test("returns false when data-is-muted='false'", () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    expect(script.getMuteState()).toBe(false);
  });

  test("returns true when aria-label contains 'unmute'", () => {
    document.body.innerHTML =
      '<button aria-label="Unmute microphone"></button>';
    expect(script.getMuteState()).toBe(true);
  });

  test("returns true when aria-label contains 'activar' (Spanish unmute)", () => {
    document.body.innerHTML =
      '<button aria-label="Activar micrófono"></button>';
    expect(script.getMuteState()).toBe(true);
  });

  test("returns true when aria-label contains 'turn on'", () => {
    document.body.innerHTML =
      '<button aria-label="Turn on microphone"></button>';
    expect(script.getMuteState()).toBe(true);
  });

  test("returns false when aria-label contains 'mute'", () => {
    document.body.innerHTML =
      '<button aria-label="Mute microphone"></button>';
    expect(script.getMuteState()).toBe(false);
  });

  test("returns false when aria-label contains 'desactivar' (Spanish mute)", () => {
    document.body.innerHTML =
      '<button aria-label="Desactivar micrófono"></button>';
    expect(script.getMuteState()).toBe(false);
  });

  test("returns false when aria-label contains 'turn off'", () => {
    document.body.innerHTML =
      '<button aria-label="Turn off microphone"></button>';
    expect(script.getMuteState()).toBe(false);
  });

  test("returns null when button exists but has no recognizable state signal", () => {
    document.body.innerHTML =
      '<button aria-label="microphone settings"></button>';
    expect(script.getMuteState()).toBeNull();
  });

  test("data-is-muted takes priority over aria-label", () => {
    // data-is-muted="true" even though aria-label implies unmuted
    document.body.innerHTML =
      '<button data-is-muted="true" aria-label="Mute microphone"></button>';
    expect(script.getMuteState()).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// sendStateUpdate
// ---------------------------------------------------------------------------
describe("sendStateUpdate", () => {
  test("calls chrome.runtime.sendMessage with correct muted=true payload", () => {
    script.sendStateUpdate(true);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "state_update",
      muted: true,
    });
  });

  test("calls chrome.runtime.sendMessage with correct muted=false payload", () => {
    script.sendStateUpdate(false);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "state_update",
      muted: false,
    });
  });

  test("is called exactly once per invocation", () => {
    script.sendStateUpdate(true);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// toggleMute
// ---------------------------------------------------------------------------
describe("toggleMute", () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test("logs and does nothing when no mute button is found", () => {
    const consoleSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});
    script.toggleMute();
    jest.runAllTimers();
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining("Mute button not found")
    );
    consoleSpy.mockRestore();
  });

  test("clicks the mute button", () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    const btn = document.querySelector("[data-is-muted]");
    const clickSpy = jest.spyOn(btn, "click");
    script.toggleMute();
    expect(clickSpy).toHaveBeenCalledTimes(1);
  });

  test("after 200ms delay reads new state and calls sendStateUpdate", () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    const btn = document.querySelector("[data-is-muted]");
    // Simulate the DOM change that Meet would do on click
    btn.addEventListener("click", () => {
      btn.setAttribute("data-is-muted", "true");
    });

    script.toggleMute();
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();

    jest.advanceTimersByTime(200);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "state_update",
      muted: true,
    });
  });

  test("does not call sendStateUpdate if getMuteState returns null after toggle", () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    const btn = document.querySelector("[data-is-muted]");
    // Button disappears after click (page transition mid-meeting)
    btn.addEventListener("click", () => {
      btn.removeAttribute("data-is-muted");
      btn.removeAttribute("aria-label");
    });

    script.toggleMute();
    jest.advanceTimersByTime(200);
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// message listener
// ---------------------------------------------------------------------------
describe("message listener", () => {
  // messageListener is captured in the top-level beforeAll (before any clearAllMocks runs)
  const getListener = () => messageListener;

  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
    document.body.innerHTML = "";
    script._setState(null);
    jest.clearAllMocks();
  });

  test("handles 'toggle' message by clicking the mute button", () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    const btn = document.querySelector("[data-is-muted]");
    const clickSpy = jest.spyOn(btn, "click");

    getListener()({ type: "toggle" }, {}, () => {});
    expect(clickSpy).toHaveBeenCalledTimes(1);
  });

  test("handles 'get_state' message: sends state update when state is readable", () => {
    document.body.innerHTML = '<button data-is-muted="true"></button>';

    getListener()({ type: "get_state" }, {}, () => {});
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "state_update",
      muted: true,
    });
  });

  test("handles 'get_state' message: does NOT call sendStateUpdate if state is null", () => {
    // No button in DOM → getMuteState returns null
    getListener()({ type: "get_state" }, {}, () => {});
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
  });

  test("returns false to keep message channel synchronous", () => {
    const result = getListener()({ type: "toggle" }, {}, () => {});
    expect(result).toBe(false);
  });

  test("ignores unknown message types without throwing", () => {
    expect(() => {
      getListener()({ type: "unknown_command" }, {}, () => {});
    }).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// startObserving
// ---------------------------------------------------------------------------
describe("startObserving", () => {
  test("calls observer.observe on document.body with correct options", () => {
    const observer = script._getObserver();
    const observeSpy = jest.spyOn(observer, "observe");

    script.startObserving();

    expect(observeSpy).toHaveBeenCalledWith(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-is-muted", "aria-label", "aria-pressed"],
    });
  });

  test("reports initial muted=false state via sendStateUpdate when button is present", () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';

    script.startObserving();

    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "state_update",
      muted: false,
    });
  });

  test("does not call sendStateUpdate when no button is present", () => {
    script.startObserving();
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
  });

  test("MutationObserver callback sends update when mute state changes", async () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    const btn = document.querySelector("[data-is-muted]");

    // startObserving sets currentMuteState = false
    script.startObserving();
    jest.clearAllMocks();

    // Simulate Meet toggling the DOM attribute
    btn.setAttribute("data-is-muted", "true");

    // jsdom fires MutationObserver callbacks in a microtask
    await Promise.resolve();

    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "state_update",
      muted: true,
    });
  });

  test("MutationObserver callback does NOT send duplicate update for same state", async () => {
    document.body.innerHTML = '<button data-is-muted="false"></button>';
    const btn = document.querySelector("[data-is-muted]");

    script.startObserving(); // sets currentMuteState = false
    jest.clearAllMocks();

    // Set the same value — state has not changed
    btn.setAttribute("data-is-muted", "false");
    await Promise.resolve();

    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// findCameraButton
// ---------------------------------------------------------------------------
describe("findCameraButton", () => {
  test("returns null when no camera button exists", () => {
    expect(script.findCameraButton()).toBeNull();
  });

  test("finds button by aria-label containing 'camera' (case-insensitive)", () => {
    document.body.innerHTML =
      '<button aria-label="Turn off Camera">Camera</button>';
    expect(script.findCameraButton()).not.toBeNull();
  });

  test("finds button by aria-label 'cámara'", () => {
    document.body.innerHTML =
      '<button aria-label="Desactivar cámara"></button>';
    expect(script.findCameraButton()).not.toBeNull();
  });

  test("finds button by data-tooltip containing 'camera'", () => {
    document.body.innerHTML =
      '<button data-tooltip="Turn off camera"></button>';
    expect(script.findCameraButton()).not.toBeNull();
  });
});

// ---------------------------------------------------------------------------
// getCameraState
// ---------------------------------------------------------------------------
describe("getCameraState", () => {
  test("returns null when no camera button exists", () => {
    expect(script.getCameraState()).toBeNull();
  });

  test("returns false when aria-label contains 'turn on camera' (camera is off)", () => {
    document.body.innerHTML =
      '<button aria-label="Turn on camera"></button>';
    expect(script.getCameraState()).toBe(false);
  });

  test("returns true when aria-label contains 'turn off camera' (camera is on)", () => {
    document.body.innerHTML =
      '<button aria-label="Turn off camera"></button>';
    expect(script.getCameraState()).toBe(true);
  });

  test("returns false when aria-pressed='false' (camera is off)", () => {
    document.body.innerHTML =
      '<button aria-label="camera settings" aria-pressed="false"></button>';
    expect(script.getCameraState()).toBe(false);
  });

  test("returns true when aria-pressed='true' (camera is on)", () => {
    document.body.innerHTML =
      '<button aria-label="camera settings" aria-pressed="true"></button>';
    expect(script.getCameraState()).toBe(true);
  });

  test("returns null when button has no recognizable state signal", () => {
    document.body.innerHTML =
      '<button aria-label="camera settings"></button>';
    expect(script.getCameraState()).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// sendCameraStateUpdate
// ---------------------------------------------------------------------------
describe("sendCameraStateUpdate", () => {
  test("calls chrome.runtime.sendMessage with active=true payload", () => {
    script.sendCameraStateUpdate(true);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "camera_state_update",
      active: true,
    });
  });

  test("calls chrome.runtime.sendMessage with active=false payload", () => {
    script.sendCameraStateUpdate(false);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "camera_state_update",
      active: false,
    });
  });
});

// ---------------------------------------------------------------------------
// toggleCamera
// ---------------------------------------------------------------------------
describe("toggleCamera", () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test("logs and does nothing when no camera button is found", () => {
    const consoleSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});
    script.toggleCamera();
    jest.runAllTimers();
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining("Camera button not found")
    );
    consoleSpy.mockRestore();
  });

  test("clicks the camera button", () => {
    document.body.innerHTML = '<button aria-label="Turn off camera"></button>';
    const btn = document.querySelector("button");
    const clickSpy = jest.spyOn(btn, "click");
    script.toggleCamera();
    expect(clickSpy).toHaveBeenCalledTimes(1);
  });

  test("after 200ms delay reads new camera state and sends update", () => {
    document.body.innerHTML =
      '<button aria-label="Turn off camera"></button>';
    const btn = document.querySelector("button");
    btn.addEventListener("click", () => {
      btn.setAttribute("aria-label", "Turn on camera");
    });

    script.toggleCamera();
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();

    jest.advanceTimersByTime(200);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "camera_state_update",
      active: false,
    });
  });
});

// ---------------------------------------------------------------------------
// message listener — camera commands
// ---------------------------------------------------------------------------
describe("message listener — camera", () => {
  const getListener = () => messageListener;

  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
    document.body.innerHTML = "";
    script._setState(null);
    jest.clearAllMocks();
  });

  test("handles 'toggle_camera' message by clicking the camera button", () => {
    document.body.innerHTML =
      '<button aria-label="Turn off camera"></button>';
    const btn = document.querySelector("button");
    const clickSpy = jest.spyOn(btn, "click");

    getListener()({ type: "toggle_camera" }, {}, () => {});
    expect(clickSpy).toHaveBeenCalledTimes(1);
  });

  test("handles 'get_camera_state' message: sends camera state update when state is readable", () => {
    document.body.innerHTML =
      '<button aria-label="Turn on camera"></button>';

    getListener()({ type: "get_camera_state" }, {}, () => {});
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: "camera_state_update",
      active: false,
    });
  });

  test("handles 'get_camera_state' message: does NOT call sendCameraStateUpdate if state is null", () => {
    getListener()({ type: "get_camera_state" }, {}, () => {});
    expect(chrome.runtime.sendMessage).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// Re-injection guard
// ---------------------------------------------------------------------------
describe("re-injection guard (window.__macMuteLoaded)", () => {
  test("window.__macMuteLoaded is true after first load", () => {
    expect(window.__macMuteLoaded).toBe(true);
  });

  test("re-requiring with guard set does not re-register chrome listeners", () => {
    const callsBefore =
      chrome.runtime.onMessage.addListener.mock.calls.length;

    // Simulate a second injection: clear module cache but keep the guard
    jest.resetModules();
    // Do NOT delete window.__macMuteLoaded — the guard should prevent execution
    require("../../chrome-extension/content-script");

    const callsAfter =
      chrome.runtime.onMessage.addListener.mock.calls.length;
    expect(callsAfter).toBe(callsBefore);
  });
});
