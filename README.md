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

## Install

Download both files from the [latest release](https://github.com/RTeran/MacMute/releases/latest):

- `MacMute-app.zip`: the menu-bar app (universal: Apple Silicon and Intel).
- `MacMute-chrome-extension.zip`: the Chrome extension.

You need macOS 13 (Ventura) or later and Google Chrome 111 or later.

The order matters: the app looks for the extension in your Chrome profiles when it starts, and only then allows it to connect. Install the extension first.

### 1. Install the Chrome extension

1. Unzip `MacMute-chrome-extension.zip`. You get a folder named `MacMute-chrome-extension`.
2. Move that folder to a permanent place, for example `~/Applications/MacMute-chrome-extension`. Chrome loads the extension from this folder every time it starts, so do not delete it or leave it in `Downloads`.
3. Keep `MacMute` in the folder name. The app uses it to find the extension.
4. Open `chrome://extensions` in Chrome.
5. Turn on **Developer mode** (top-right switch).
6. Click **Load unpacked** and select the `MacMute-chrome-extension` folder.

### 2. Install the app

1. Unzip `MacMute-app.zip` and move `MacMute.app` to `/Applications`.
2. Open it once. The app is not notarized by Apple, so macOS blocks it the first time with a message like *"MacMute" cannot be opened* or *Apple could not verify "MacMute"*. Allow it in one of these two ways:
   - Open **System Settings → Privacy & Security**, scroll down to the message about MacMute and click **Open Anyway**. Then open the app again.
   - Or run this command in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/MacMute.app
     ```

3. Grant **Accessibility** permission when asked (System Settings → Privacy & Security → Accessibility). Global shortcuts need it.

### 3. Connect them

1. Go back to `chrome://extensions` and click the reload icon on the MacMute extension.
2. Reload any open Google Meet tab.
3. Click the MacMute icon in the menu bar and record a shortcut for the microphone and one for the camera.

If you install the extension after opening the app, quit and reopen MacMute so it picks up the extension.

### Update

1. Download the new files from the [latest release](https://github.com/RTeran/MacMute/releases/latest).
2. Quit MacMute, replace `/Applications/MacMute.app` with the new one and allow it again as in step 2.
3. Replace the contents of your `MacMute-chrome-extension` folder with the new ones and click reload in `chrome://extensions`.
4. Reload the Meet tab.

The app is signed ad hoc, so macOS may forget the Accessibility permission after an update. If the shortcuts stop working, remove MacMute from the Accessibility list and add it again.

### Uninstall

1. Quit MacMute and delete `/Applications/MacMute.app`.
2. Remove the extension in `chrome://extensions` and delete its folder.
3. Delete `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.macmute.helper.json`.

## Troubleshooting

Watch the app and helper logs:

```bash
/usr/bin/log stream --info --predicate 'subsystem == "com.macmute.app"'
```

Use `/usr/bin/log`, not `log`: in zsh, `log` is a built-in command.

Each shortcut press logs the request and its result (`toggle_result`), including whether Meet confirmed it. For extension-side details, open the DevTools console of the Meet tab and filter by `MacMute:` with the **Verbose** level enabled.

## Development

Requirements: Xcode 15 or later, and Node.js for the extension tests.

### Build from source

Load the `chrome-extension/` folder of this repo with **Load unpacked** (see above), then build and install the app:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release clean build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacMute-*/Build/Products/Release/MacMute.app /Applications/
```

### Tests

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

### Publish a release

Build a universal app and package both downloads:

```bash
xcodebuild -project MacMute.xcodeproj -scheme MacMute -configuration Release \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build
mkdir -p dist
ditto -c -k --keepParent build/Build/Products/Release/MacMute.app dist/MacMute-app.zip
cp -R chrome-extension dist/MacMute-chrome-extension
(cd dist && zip -qr MacMute-chrome-extension.zip MacMute-chrome-extension && rm -rf MacMute-chrome-extension)
gh release create vX.Y dist/MacMute-app.zip dist/MacMute-chrome-extension.zip
```
