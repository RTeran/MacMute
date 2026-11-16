#!/bin/bash
set -euo pipefail

IDENTITY="${MACMUTE_SIGNING_IDENTITY:-MacMute Code Signing 2026}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/Build/Products/Release/MacMute.app"
# SHA-1 of the signing certificate. The app and the helper trust no peer unless their own
# certificate has this hash, so a new certificate needs a new value here.
LEAF_PIN="0ccd508916a1b2a377ee3718b8315a7bae324c52"

# The identity is self-signed, so `find-identity -v` hides it; a trusted one is listed twice.
identity_sha1s() {
  security find-identity -p codesigning |
    awk -v id="$1" 'match($0, /[0-9A-F]{40} "/) {
      hash = substr($0, RSTART, 40); name = substr($0, RSTART + 42); sub(/".*$/, "", name)
      if (name == id || hash == toupper(id)) print tolower(hash)
    }' | sort -u
}

require_pin_matches_identity() {
  local hashes
  hashes="$(identity_sha1s "$1")"
  if [[ -z "$hashes" || "$hashes" == *$'\n'* ]]; then
    echo "error: expected exactly one code signing identity named $1" >&2
    exit 1
  fi
  if [[ "$hashes" != "$2" ]]; then
    echo "error: the certificate of $1 has SHA-1 $hashes, but LEAF_PIN is $2" >&2
    exit 1
  fi
}

cd "$ROOT"
require_pin_matches_identity "$IDENTITY" "$LEAF_PIN"
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release \
  -derivedDataPath "$BUILD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO MACMUTE_LEAF_PIN="$LEAF_PIN" clean build -quiet

HELPER="$APP/Contents/Resources/MacMuteHelper"

# Re-sign with a stable identity so macOS keeps the Accessibility permission across updates.
# A name picks by identity preference or by a substring of the common name; the hash picks exactly one certificate.
codesign --force --sign "$LEAF_PIN" --options runtime --identifier com.macmute.helper "$HELPER"
codesign --force --sign "$LEAF_PIN" --options runtime --entitlements MacMute/MacMute.entitlements "$APP"
codesign --verify --deep --strict "$APP"

require_signed_by_pin() {
  local certificates leaf
  certificates="$(mktemp -d)"
  codesign -d --extract-certificates="$certificates/c" "$1" 2>/dev/null || true
  leaf="$(shasum -a 1 "$certificates/c0" 2>/dev/null | cut -d ' ' -f 1)" || true
  rm -rf "$certificates"
  if [[ "$leaf" != "$2" ]]; then
    echo "error: $1 is not signed by the certificate with SHA-1 $2" >&2
    exit 1
  fi
}

# An empty pin would ship a signed release that trusts whatever certificate its own signature carries.
require_embedded_pins() {
  local app_pin
  app_pin="$(plutil -extract MacMuteLeafPin raw -o - "$1/Contents/Info.plist" 2>/dev/null)" || true
  if [[ "$app_pin" != "$3" ]]; then
    echo "error: the Info.plist of $1 does not pin $3" >&2
    exit 1
  fi
  # launchctl reads only the first slice of a universal binary.
  local slices arch archs pinned=1
  archs="$(lipo -archs "$2" 2>/dev/null)" || archs=""
  slices="$(mktemp -d)"
  [[ -n "$archs" ]] || pinned=0
  for arch in $archs; do
    if ! lipo -thin "$arch" "$2" -output "$slices/$arch" 2>/dev/null &&
       ! { [[ "$archs" == "$arch" ]] && cp "$2" "$slices/$arch"; }; then
      pinned=0
    elif ! launchctl plist __TEXT,__info_plist "$slices/$arch" 2>/dev/null | grep -qxF "	\"MacMuteLeafPin\" = \"$3\";"; then
      pinned=0
    fi
  done
  rm -rf "$slices"
  if (( pinned == 0 )); then
    echo "error: the embedded Info.plist of $2 does not pin $3 in every architecture" >&2
    exit 1
  fi
}

require_signed_by_pin "$HELPER" "$LEAF_PIN"
require_signed_by_pin "$APP" "$LEAF_PIN"
require_embedded_pins "$APP" "$HELPER" "$LEAF_PIN"

require_hardened_runtime() {
  local details
  details="$(codesign -dv "$1" 2>&1)"
  if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details"; then
    echo "error: $1 is not signed with the hardened runtime" >&2
    exit 1
  fi
}
# Each of these would let other code attach to the signed app or load into it.
UNSAFE_ENTITLEMENTS=(
  com.apple.security.get-task-allow
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.disable-executable-page-protection
  com.apple.security.cs.allow-jit
)

entitlements_xml() {
  if ! codesign -d --entitlements - --xml "$1" 2>/dev/null; then
    echo "error: cannot read the entitlements of $1" >&2
    exit 1
  fi
}

reject_unsafe_entitlements() {
  local entitlements key
  entitlements="$(entitlements_xml "$1")" || exit 1
  for key in "${UNSAFE_ENTITLEMENTS[@]}"; do
    if grep -qF "<key>$key</key>" <<<"$entitlements"; then
      echo "error: $1 is signed with $key" >&2
      exit 1
    fi
  done
}

# The app's entitlements always set the sandbox key, so an answer without it means the check above saw nothing.
# plutil reads dots as key path separators, hence the escapes.
require_readable_entitlements() {
  local entitlements
  entitlements="$(entitlements_xml "$1")" || exit 1
  if ! plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - <<<"$entitlements" >/dev/null; then
    echo "error: cannot find the sandbox entitlement of $1" >&2
    exit 1
  fi
}

for code in "$HELPER" "$APP"; do
  require_hardened_runtime "$code"
  reject_unsafe_entitlements "$code"
done
require_readable_entitlements "$APP"

rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/MacMute-app.zip"
cp -R chrome-extension "$DIST/MacMute-chrome-extension"
find "$DIST/MacMute-chrome-extension" -name .DS_Store -delete
(cd "$DIST" && zip -qr MacMute-chrome-extension.zip MacMute-chrome-extension && rm -rf MacMute-chrome-extension)
(cd "$DIST" && shasum -a 256 MacMute-app.zip MacMute-chrome-extension.zip > SHA256SUMS.txt)

echo "Release files in $DIST:"
ls -1 "$DIST"
