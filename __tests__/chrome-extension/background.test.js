let background;
let port;

function givenMeetTabs(tabs) {
  chrome.tabs.query.mockImplementation((_queryInfo, callback) => {
    if (callback) callback(tabs);
    return Promise.resolve(tabs);
  });
}

function givenTabResponses(responsesByTabId) {
  chrome.tabs.sendMessage.mockImplementation((tabId) => {
    const response = responsesByTabId[tabId];
    return response instanceof Error ? Promise.reject(response) : Promise.resolve(response);
  });
}

function postedToggleResults() {
  return port.postMessage.mock.calls
    .map(([message]) => message)
    .filter((message) => message.type === "toggle_result");
}

beforeEach(() => {
  global.chrome = createChromeMock();
  jest.resetModules();
  jest.spyOn(console, "log").mockImplementation(() => {});
  background = require("../../chrome-extension/background");
  port = chrome.runtime.connectNative.mock.results[0].value;
});

afterEach(() => {
  jest.useRealTimers();
  jest.restoreAllMocks();
});

describe("mic toggle", () => {
  test("forwards the toggle to every Meet tab", async () => {
    givenMeetTabs([{ id: 1 }, { id: 2 }]);
    givenTabResponses({ 1: { ok: true, before: false, after: true }, 2: { ok: true, before: false, after: true } });

    await background.handleNativeMessage({ type: "toggle" });

    expect(chrome.tabs.sendMessage).toHaveBeenCalledWith(1, { type: "toggle" });
    expect(chrome.tabs.sendMessage).toHaveBeenCalledWith(2, { type: "toggle" });
  });

  test("reports the confirmed muted state and its source to the app", async () => {
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({ 1: { ok: true, before: false, after: true, source: "media_session" } });

    await background.handleNativeMessage({ type: "toggle", requestId: "r1" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "mic", ok: true, muted: true, source: "media_session", requestId: "r1" },
    ]);
  });

  test("reports no_meet_tab when there is no Meet tab", async () => {
    givenMeetTabs([]);

    await background.handleNativeMessage({ type: "toggle" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "mic", ok: false, reason: "no_meet_tab" },
    ]);
  });

  test("passes on the content script failure reason", async () => {
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({ 1: { ok: false, reason: "timeout", before: false, after: false } });

    await background.handleNativeMessage({ type: "toggle" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "mic", ok: false, reason: "timeout" },
    ]);
  });

  test("is confirmed when one tab confirms and another tab has no mic button", async () => {
    givenMeetTabs([{ id: 1 }, { id: 2 }]);
    givenTabResponses({
      1: { ok: false, reason: "button_not_found", before: null, after: null },
      2: { ok: true, before: true, after: false },
    });

    await background.handleNativeMessage({ type: "toggle" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "mic", ok: true, muted: false },
    ]);
  });

  test("reports as soon as one tab confirms, without waiting for slower tabs", async () => {
    givenMeetTabs([{ id: 1 }, { id: 2 }]);
    let answerSlowTab;
    chrome.tabs.sendMessage.mockImplementation((tabId) =>
      tabId === 1
        ? Promise.resolve({ ok: true, before: false, after: true })
        : new Promise((resolve) => {
            answerSlowTab = resolve;
          })
    );

    await background.handleNativeMessage({ type: "toggle" });
    const resultsBeforeSlowTab = postedToggleResults();
    answerSlowTab({ ok: false, reason: "timeout", before: false, after: false });
    await Promise.resolve();

    expect(resultsBeforeSlowTab).toEqual([
      { type: "toggle_result", target: "mic", ok: true, muted: true },
    ]);
    expect(postedToggleResults()).toHaveLength(1);
  });

  test("reports tabs_query_failed when the Meet tabs cannot be listed", async () => {
    chrome.tabs.query.mockRejectedValue(new Error("tabs unavailable"));

    await background.handleNativeMessage({ type: "toggle", requestId: "q1" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "mic", ok: false, reason: "tabs_query_failed", requestId: "q1" },
    ]);
  });

  test("prefers a real failure reason over button_not_found when no tab confirms", async () => {
    givenMeetTabs([{ id: 1 }, { id: 2 }]);
    givenTabResponses({
      1: { ok: false, reason: "button_not_found", before: null, after: null },
      2: { ok: false, reason: "timeout", before: true, after: true },
    });

    await background.handleNativeMessage({ type: "toggle" });

    expect(postedToggleResults()[0]).toEqual(
      expect.objectContaining({ ok: false, reason: "timeout" })
    );
  });

  test("reports no_response when the tab answers nothing", async () => {
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({ 1: undefined });

    await background.handleNativeMessage({ type: "toggle" });

    expect(postedToggleResults()[0]).toEqual(
      expect.objectContaining({ ok: false, reason: "no_response" })
    );
  });
});

describe("camera toggle", () => {
  test("reports the confirmed camera state as off", async () => {
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({ 1: { ok: true, before: true, after: false, source: "dom" } });

    await background.handleNativeMessage({ type: "toggle_camera", requestId: "c1" });

    expect(chrome.tabs.sendMessage).toHaveBeenCalledWith(1, { type: "toggle_camera" });
    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "camera", ok: true, off: true, source: "dom", requestId: "c1" },
    ]);
  });

  test("reports the camera as not off when it was turned on", async () => {
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({ 1: { ok: true, before: false, after: true } });

    await background.handleNativeMessage({ type: "toggle_camera" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "camera", ok: true, off: false },
    ]);
  });

  test("reports no_meet_tab for the camera when there is no Meet tab", async () => {
    givenMeetTabs([]);

    await background.handleNativeMessage({ type: "toggle_camera" });

    expect(postedToggleResults()).toEqual([
      { type: "toggle_result", target: "camera", ok: false, reason: "no_meet_tab" },
    ]);
  });
});

describe("requestId echo", () => {
  const cases = [
    ["toggle", "success", { target: "mic", ok: true, muted: true }],
    ["toggle", "no_meet_tab", { target: "mic", ok: false, reason: "no_meet_tab" }],
    ["toggle", "tabs_query_failed", { target: "mic", ok: false, reason: "tabs_query_failed" }],
    ["toggle_camera", "success", { target: "camera", ok: true, off: false }],
    ["toggle_camera", "no_meet_tab", { target: "camera", ok: false, reason: "no_meet_tab" }],
    ["toggle_camera", "tabs_query_failed", { target: "camera", ok: false, reason: "tabs_query_failed" }],
  ];

  test.each(cases)("%s echoes requestId on %s", async (type, outcome, expected) => {
    if (outcome === "success") {
      givenMeetTabs([{ id: 1 }]);
      givenTabResponses({ 1: { ok: true, before: false, after: true } });
    } else if (outcome === "no_meet_tab") {
      givenMeetTabs([]);
    } else {
      chrome.tabs.query.mockRejectedValue(new Error("tabs unavailable"));
    }

    await background.handleNativeMessage({ type, requestId: "r1" });

    expect(postedToggleResults()).toEqual([{ type: "toggle_result", ...expected, requestId: "r1" }]);
  });
});

describe("content script injection", () => {
  test("injects the content script and retries once when the tab has no receiver", async () => {
    jest.useFakeTimers();
    givenMeetTabs([{ id: 1 }]);
    chrome.tabs.sendMessage
      .mockRejectedValueOnce(new Error("Could not establish connection. Receiving end does not exist."))
      .mockResolvedValueOnce({ ok: true, before: false, after: true });

    const handled = background.handleNativeMessage({ type: "toggle" });
    await jest.advanceTimersByTimeAsync(200);
    await handled;

    expect(chrome.scripting.executeScript).toHaveBeenCalledWith({
      target: { tabId: 1 },
      files: ["content-script.js"],
    });
    expect(chrome.tabs.sendMessage).toHaveBeenCalledTimes(2);
    expect(postedToggleResults()[0]).toEqual(expect.objectContaining({ ok: true, muted: true }));
  });

  test("also injects the Media Session bridge into the page's main world", async () => {
    jest.useFakeTimers();
    givenMeetTabs([{ id: 1 }]);
    chrome.tabs.sendMessage
      .mockRejectedValueOnce(new Error("Receiving end does not exist."))
      .mockResolvedValueOnce({ ok: true, before: false, after: true });

    const handled = background.handleNativeMessage({ type: "toggle" });
    await jest.advanceTimersByTimeAsync(200);
    await handled;

    expect(chrome.scripting.executeScript).toHaveBeenCalledWith({
      target: { tabId: 1 },
      files: ["media-session-bridge.js"],
      world: "MAIN",
    });
  });

  test("still confirms through the DOM when the Media Session bridge cannot be injected", async () => {
    jest.useFakeTimers();
    const warn = jest.spyOn(console, "warn").mockImplementation(() => {});
    givenMeetTabs([{ id: 1 }]);
    chrome.tabs.sendMessage
      .mockRejectedValueOnce(new Error("Receiving end does not exist."))
      .mockResolvedValueOnce({ ok: true, before: false, after: true, source: "dom" });
    chrome.scripting.executeScript.mockImplementation(({ world }) =>
      world === "MAIN" ? Promise.reject(new Error("no main world")) : Promise.resolve([])
    );

    const handled = background.handleNativeMessage({ type: "toggle" });
    await jest.advanceTimersByTimeAsync(200);
    await handled;

    expect(postedToggleResults()[0]).toEqual(expect.objectContaining({ ok: true, source: "dom" }));
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("Media Session bridge"), expect.any(String));
  });

  test("does not retry on other errors, so a toggle is never clicked twice", async () => {
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({
      1: new Error("The message port closed before a response was received."),
    });

    await background.handleNativeMessage({ type: "toggle" });

    expect(chrome.scripting.executeScript).not.toHaveBeenCalled();
    expect(chrome.tabs.sendMessage).toHaveBeenCalledTimes(1);
    expect(postedToggleResults()[0]).toEqual(
      expect.objectContaining({ ok: false, reason: "send_failed" })
    );
  });

  test("reports injection_failed when the content script cannot be injected", async () => {
    givenMeetTabs([{ id: 1 }]);
    chrome.tabs.sendMessage.mockRejectedValueOnce(new Error("Receiving end does not exist."));
    chrome.scripting.executeScript.mockImplementation(({ files }) =>
      files.includes("content-script.js") ? Promise.reject(new Error("Cannot access contents")) : Promise.resolve([])
    );

    await background.handleNativeMessage({ type: "toggle" });

    expect(postedToggleResults()[0]).toEqual(
      expect.objectContaining({ ok: false, reason: "injection_failed" })
    );
  });
});

describe("native port", () => {
  test("drops the toggle result without throwing when the native port is disconnected", async () => {
    jest.useFakeTimers();
    const onDisconnect = port.onDisconnect.addListener.mock.calls[0][0];
    onDisconnect();
    givenMeetTabs([{ id: 1 }]);
    givenTabResponses({ 1: { ok: true, before: false, after: true } });

    const warn = jest.spyOn(console, "warn").mockImplementation(() => {});

    await background.handleNativeMessage({ type: "toggle", requestId: "lost-1" });

    expect(port.postMessage).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining("Native port not connected"),
      expect.objectContaining({ requestId: "lost-1" })
    );
  });

  test("logs dropped passive state updates at debug level only", () => {
    jest.useFakeTimers();
    const warn = jest.spyOn(console, "warn").mockImplementation(() => {});
    port.onDisconnect.addListener.mock.calls[0][0]();
    const onMessage = chrome.runtime.onMessage.addListener.mock.calls[0][0];

    onMessage({ type: "state_update", muted: true }, {}, () => {});

    expect(warn).not.toHaveBeenCalled();
    expect(console.debug).toHaveBeenCalledWith(
      expect.stringContaining("Native port not connected"),
      expect.objectContaining({ type: "state_update" })
    );
  });

  test("logs native_port_lost when posting to the native port throws", async () => {
    const warn = jest.spyOn(console, "warn").mockImplementation(() => {});
    port.postMessage.mockImplementation(() => {
      throw new Error("Attempting to use a disconnected port object");
    });
    givenMeetTabs([]);

    await background.handleNativeMessage({ type: "toggle", requestId: "lost-2" });

    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining("native_port_lost"),
      expect.objectContaining({ requestId: "lost-2" })
    );
  });

  test("forwards passive state updates from content scripts to the app", () => {
    const onMessage = chrome.runtime.onMessage.addListener.mock.calls[0][0];

    onMessage({ type: "state_update", muted: true }, {}, () => {});

    expect(port.postMessage).toHaveBeenCalledWith({ type: "state_update", muted: true });
  });
});
