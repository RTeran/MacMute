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

1. Open MacMute from `/Applications`
2. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility)
3. Open `chrome://extensions` in Chrome, reload the MacMute extension so it picks up the new native messaging manifest
4. Configure a global shortcut by clicking the mic icon in the menu bar

## Update

After making changes, rebuild and overwrite. Use `clean build` to avoid stale cached artifacts:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

> **Note:** After replacing the binary you may need to re-enable Accessibility permission in System Settings.
