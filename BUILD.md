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

1. Load the extension first: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and select the `chrome-extension/` folder. The app looks for the extension when it starts.
2. Open MacMute from `/Applications`
3. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility)
4. Reload the MacMute extension in `chrome://extensions` so it picks up the new native messaging manifest, and reload any open Meet tab
5. Configure a global shortcut by clicking the mic icon in the menu bar

See [README.md](README.md) for an overview, troubleshooting and tests.

## Update

After making changes, rebuild and overwrite. Use `clean build` to avoid stale cached artifacts:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

> **Note:** After replacing the binary you may need to re-enable Accessibility permission in System Settings.
