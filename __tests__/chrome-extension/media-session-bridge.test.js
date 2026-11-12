const MESSAGE_TYPE = "macmute:media-session";

function givenMediaSession(methods) {
  global.MediaSession = class {};
  Object.assign(global.MediaSession.prototype, methods);
}

function loadBridge() {
  jest.isolateModules(() => require("../../chrome-extension/media-session-bridge"));
}

let postMessage;
let warn;

beforeEach(() => {
  postMessage = jest.spyOn(window, "postMessage").mockImplementation(() => {});
  warn = jest.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  delete global.MediaSession;
  jest.restoreAllMocks();
});

test("calls the original setMicrophoneActive with the same arguments and returns its result", () => {
  const original = jest.fn(() => "original result");
  givenMediaSession({ setMicrophoneActive: original });
  loadBridge();
  const session = new MediaSession();

  const result = session.setMicrophoneActive(false);

  expect(original).toHaveBeenCalledWith(false);
  expect(original.mock.contexts[0]).toBe(session);
  expect(result).toBe("original result");
});

test("forwards microphone activity to the isolated content script", () => {
  givenMediaSession({ setMicrophoneActive: jest.fn() });
  loadBridge();

  new MediaSession().setMicrophoneActive(false);

  expect(postMessage).toHaveBeenCalledWith(
    { type: MESSAGE_TYPE, kind: "mic", active: false },
    window.location.origin
  );
});

test("forwards camera activity to the isolated content script", () => {
  givenMediaSession({ setCameraActive: jest.fn() });
  loadBridge();

  new MediaSession().setCameraActive(true);

  expect(postMessage).toHaveBeenCalledWith(
    { type: MESSAGE_TYPE, kind: "camera", active: true },
    window.location.origin
  );
});

test("lets an error from the original method reach Meet and forwards nothing", () => {
  givenMediaSession({
    setMicrophoneActive: () => {
      throw new Error("not allowed");
    },
  });
  loadBridge();

  expect(() => new MediaSession().setMicrophoneActive(true)).toThrow("not allowed");
  expect(postMessage).not.toHaveBeenCalled();
});

test("does not break Meet when forwarding the message fails, and warns", () => {
  givenMediaSession({ setMicrophoneActive: jest.fn(() => "ok") });
  postMessage.mockImplementation(() => {
    throw new Error("cannot post");
  });
  loadBridge();

  expect(new MediaSession().setMicrophoneActive(true)).toBe("ok");
  expect(warn).toHaveBeenCalledWith(expect.stringContaining("could not forward"), expect.any(Error));
});

test("forwards the boolean the browser would use for a missing or non-boolean argument", () => {
  givenMediaSession({ setMicrophoneActive: jest.fn(), setCameraActive: jest.fn() });
  loadBridge();

  new MediaSession().setMicrophoneActive();
  new MediaSession().setCameraActive(1);

  expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ kind: "mic", active: false }), expect.anything());
  expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ kind: "camera", active: true }), expect.anything());
});

test("wraps only once when the script runs twice", () => {
  givenMediaSession({ setMicrophoneActive: jest.fn() });
  loadBridge();
  loadBridge();

  new MediaSession().setMicrophoneActive(false);

  expect(postMessage).toHaveBeenCalledTimes(1);
});

test("warns and does nothing when the Media Session API is missing", () => {
  expect(loadBridge).not.toThrow();
  expect(warn).toHaveBeenCalledWith(expect.stringContaining("Media Session API not available"));
});

test("warns and does not add a method the browser lacks", () => {
  givenMediaSession({ setMicrophoneActive: jest.fn() });
  loadBridge();

  expect(MediaSession.prototype.setCameraActive).toBeUndefined();
  expect(warn).toHaveBeenCalledWith(expect.stringContaining("setCameraActive"));
});

test("does not warn when every method is wrapped", () => {
  givenMediaSession({ setMicrophoneActive: jest.fn(), setCameraActive: jest.fn() });
  loadBridge();
  loadBridge();

  expect(warn).not.toHaveBeenCalled();
});
