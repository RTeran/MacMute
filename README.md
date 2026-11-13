# MacMute

Mute your microphone and turn your camera on or off in Google Meet with a global keyboard shortcut, from any app.

MacMute is a macOS menu-bar app plus a Chrome extension:

- **Global shortcuts** for the microphone and the camera, configured from the menu-bar icon.
- **Screen border feedback**: a colored border around the screen shows when the microphone is muted (red by default) or the camera is off (blue by default). Colors are configurable.
- **Confirmed toggles**: every shortcut waits for Meet to confirm the change, even when the Meet tab is hidden or on another desktop. If Meet does not confirm it, the border blinks amber three times and the menu-bar icon shows a warning.

## How it works

```
Global shortcut ─▶ MacMute.app ─▶ MacMuteHelper ─▶ Chrome extension ─▶ Google Meet tab
                    (menu bar)    (native messaging,  (content script)
                                   Unix socket)
```

- `MacMute/`: the menu-bar app (Swift/SwiftUI). It owns the shortcuts and the screen border.
- `MacMuteHelper/`: a small native messaging host that Chrome starts. It relays messages between the extension and the app.
- `chrome-extension/`: a Manifest V3 extension that clicks the Meet buttons and reports the result.

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15 or later
- Google Chrome 111 or later
- Node.js, only to run the extension tests

## Install

The order matters: the app looks for the extension in your Chrome profiles when it starts, and only then allows it to connect.

1. **Load the extension in Chrome**
   1. Open `chrome://extensions`.
   2. Turn on **Developer mode**.
   3. Click **Load unpacked** and select the `chrome-extension/` folder of this repo.

2. **Build and install the app**

   ```bash
   xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
   cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
   ```

3. **Open MacMute** from `/Applications` and grant **Accessibility** permission when asked (System Settings → Privacy & Security → Accessibility). Global shortcuts need it.

4. **Reload the extension** in `chrome://extensions` and reload any open Meet tab.

5. **Set your shortcuts**: click the MacMute icon in the menu bar and record a shortcut for the microphone and one for the camera.

If you install the extension after opening the app, quit and reopen MacMute so it picks up the extension.

## Update

Pull the changes, then rebuild and reinstall the app:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

Then reload the extension in `chrome://extensions` and reload the Meet tab.

The app is signed ad hoc, so macOS may forget the Accessibility permission after a rebuild. If the shortcuts stop working, remove MacMute from the Accessibility list and add it again.

## Troubleshooting

Watch the app and helper logs:

```bash
/usr/bin/log stream --info --predicate 'subsystem == "com.macmute.app"'
```

Use `/usr/bin/log`, not `log`: in zsh, `log` is a built-in command.

Each shortcut press logs the request and its result (`toggle_result`), including whether Meet confirmed it. For extension-side details, open the DevTools console of the Meet tab and filter by `MacMute:` with the **Verbose** level enabled.

## Development

Run the extension tests:

```bash
npm install
npm test
```

Run the app tests and build:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute test
xcodebuild -project MacMute.xcodeproj -scheme MacMute build
```
