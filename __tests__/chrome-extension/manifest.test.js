const manifest = require("../../chrome-extension/manifest.json");

const entryFor = (file) => manifest.content_scripts.find((entry) => entry.js.includes(file));

test("loads the Media Session bridge in the page's main world before Meet runs", () => {
  const bridge = entryFor("media-session-bridge.js");

  expect(bridge).toEqual(expect.objectContaining({ world: "MAIN", run_at: "document_start" }));
});

test("loads the bridge on the same pages as the content script", () => {
  expect(entryFor("media-session-bridge.js").matches).toEqual(entryFor("content-script.js").matches);
});

test("requires a Chrome version that supports main-world content scripts", () => {
  expect(Number(manifest.minimum_chrome_version)).toBeGreaterThanOrEqual(111);
});
