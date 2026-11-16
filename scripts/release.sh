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
codesign --force --sign "$IDENTITY" --identifier com.macmute.helper "$APP/Contents/Resources/MacMuteHelper"
codesign --force --sign "$IDENTITY" --entitlements MacMute/MacMute.entitlements "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/MacMute-app.zip"
cp -R chrome-extension "$DIST/MacMute-chrome-extension"
find "$DIST/MacMute-chrome-extension" -name .DS_Store -delete
(cd "$DIST" && zip -qr MacMute-chrome-extension.zip MacMute-chrome-extension && rm -rf MacMute-chrome-extension)

echo "Release files in $DIST:"
ls -1 "$DIST"
