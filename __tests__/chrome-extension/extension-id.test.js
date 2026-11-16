const crypto = require("crypto");
const manifest = require("../../chrome-extension/manifest.json");

const keyBytes = () => Buffer.from(manifest.key ?? "", "base64");

// Chrome's ID: the first 128 bits of the key's SHA-256, written with the letters a-p.
function extensionIdFor(spki) {
  const hex = crypto.createHash("sha256").update(spki).digest("hex").slice(0, 32);
  return [...hex].map((digit) => String.fromCharCode("a".charCodeAt(0) + parseInt(digit, 16))).join("");
}

test("pins the extension ID with an RSA public key", () => {
  const publicKey = crypto.createPublicKey({ key: keyBytes(), format: "der", type: "spki" });

  expect(publicKey.asymmetricKeyType).toBe("rsa");
});

test("derives an extension ID in Chrome's format", () => {
  expect(extensionIdFor(keyBytes())).toMatch(/^[a-p]{32}$/);
});

test("derives the ID the native host manifest allows", () => {
  expect(extensionIdFor(keyBytes())).toBe("ealicgogcpkafcocpppnmhgcaiepdple");
});
