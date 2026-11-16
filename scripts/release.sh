#!/bin/bash
set -euo pipefail

IDENTITY="${MACMUTE_SIGNING_IDENTITY:-MacMute Code Signing}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/Build/Products/Release/MacMute.app"

cd "$ROOT"
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release \
  -derivedDataPath "$BUILD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build -quiet

# Re-sign with a stable identity so macOS keeps the Accessibility permission across updates.
codesign --force --sign "$IDENTITY" --options runtime --identifier com.macmute.helper "$APP/Contents/Resources/MacMuteHelper"
codesign --force --sign "$IDENTITY" --options runtime --entitlements MacMute/MacMute.entitlements "$APP"
codesign --verify --deep --strict "$APP"

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

# The app always has entitlements, so an empty or unparsable answer means the check above saw nothing.
require_readable_entitlements() {
  local entitlements
  entitlements="$(entitlements_xml "$1")" || exit 1
  if ! plutil -lint - <<<"$entitlements" >/dev/null; then
    echo "error: cannot parse the entitlements of $1" >&2
    exit 1
  fi
}

for code in "$APP/Contents/Resources/MacMuteHelper" "$APP"; do
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
