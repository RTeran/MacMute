# MacMute - Build & Install

## Prerequisites

- macOS 13 (Ventura) or later
- Xcode 15+
- Google Chrome with the MacMute extension loaded

## Build

Open the project in Xcode and build in Release mode from the command line:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release build
```

## Signing

The recommended build is the one that `scripts/release.sh` makes: it signs the app and the helper with the MacMute certificate and the hardened runtime. See "Publish a release" in [README.md](README.md).

The commands in this file make an ad-hoc build instead. An ad-hoc app trusts the helper that is in its `Contents/Resources` folder when it starts. Another program running as your user could replace that helper between two launches.

Do not mix a Debug build from Xcode with a build in `/Applications`. Each one trusts only the helper inside its own bundle, so they reject each other's helper. MacMute already refuses to start a second instance, and the app that is running writes the native messaging manifest so that it points to its own helper. When you switch builds, quit the other one first, then check that `path` in `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.macmute.helper.json` is inside the app you are running.

## Install to /Applications

Copy the built app to `/Applications`:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

Or build and install in one step:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

## First run

1. Load the extension: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and select the `chrome-extension/` folder. Steps 1 and 2 can go in any order. Do not load a release copy of the extension in the same Chrome profile: it has the same ID.
2. Open MacMute from `/Applications`
3. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility)
4. Reload the MacMute extension in `chrome://extensions` so it connects to the helper, and reload any open Meet tab
5. Configure a global shortcut by clicking the mic icon in the menu bar

If you loaded `chrome-extension/` before it had a fixed ID, remove it in `chrome://extensions` and load it again with **Load unpacked**: its ID changed.

See [README.md](README.md) for an overview, troubleshooting and tests.

## Update

After making changes, rebuild and overwrite. Use `clean build` to avoid stale cached artifacts:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

> **Note:** After replacing the binary you may need to re-enable Accessibility permission in System Settings.
