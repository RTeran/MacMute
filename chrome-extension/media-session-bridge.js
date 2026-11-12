// Runs in the page's MAIN world at document_start. Meet reports mic and camera changes through
// the Media Session API even while Chrome is not rendering the page (window on another Space),
// when the DOM state we read does not update. This forwards those calls to content-script.js.
(function () {
  const MESSAGE_TYPE = "macmute:media-session";
  const WRAPPED = Symbol.for("macmute.mediaSessionWrapped");

  const proto = typeof MediaSession === "function" ? MediaSession.prototype : null;
  if (!proto) return;

  function forward(kind, active) {
    try {
      window.postMessage({ type: MESSAGE_TYPE, kind, active }, window.location.origin);
    } catch (error) {
      console.debug("MacMute: could not forward media session state", error);
    }
  }

  function wrap(method, kind) {
    const original = proto[method];
    if (typeof original !== "function" || original[WRAPPED]) return;

    const wrapper = function (active) {
      const result = original.apply(this, arguments);
      // Mirrors the WebIDL boolean conversion the browser applies to the argument.
      forward(kind, Boolean(active));
      return result;
    };
    Object.defineProperty(wrapper, WRAPPED, { value: true });
    proto[method] = wrapper;
  }

  wrap("setMicrophoneActive", "mic");
  wrap("setCameraActive", "camera");
})();
