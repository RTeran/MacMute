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

Download these files from the [latest release](https://github.com/RTeran/MacMute/releases/latest) into the same folder:

- `MacMute-app.zip`: the menu-bar app (universal: Apple Silicon and Intel).
- `MacMute-chrome-extension.zip`: the Chrome extension.
- `SHA256SUMS.txt`: the checksums of both zips.

Before you unzip anything, check the downloads. In Terminal, go to that folder and run:

```bash
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Each zip must show `OK`. If one does not, delete it and download it again.

You need macOS 13 (Ventura) or later and Google Chrome 111 or later.

You can install the app and the extension in any order.

### 1. Install the Chrome extension

1. Unzip `MacMute-chrome-extension.zip`. You get a folder named `MacMute-chrome-extension`.
2. Move that folder to a permanent place, for example `~/Applications/MacMute-chrome-extension`. Chrome loads the extension from this folder every time it starts, so do not delete it or leave it in `Downloads`.
3. Open `chrome://extensions` in Chrome.
4. Turn on **Developer mode** (top-right switch).
5. Click **Load unpacked** and select the `MacMute-chrome-extension` folder.

The folder name does not matter. Load only one copy of the extension in each Chrome profile: every copy has the same ID, so Chrome cannot load a release copy and the repo's `chrome-extension/` folder at the same time.

### 2. Install the app

1. Unzip `MacMute-app.zip` and move `MacMute.app` to `/Applications`.
2. Check that the app is signed with the MacMute certificate:

   ```bash
   codesign -dr - /Applications/MacMute.app
   ```

   The output must contain `H"0ccd508916a1b2a377ee3718b8315a7bae324c52"`, the hash of the MacMute certificate. If it does not, delete the app and do not open it.
3. Open it once. The app is not notarized by Apple, so macOS blocks it the first time with a message like *"MacMute" cannot be opened* or *Apple could not verify "MacMute"*. Open **System Settings → Privacy & Security**, scroll down to the message about MacMute and click **Open Anyway**. Then open the app again.

   If **Open Anyway** does not appear, and only after the checks above passed, remove the quarantine flag instead:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacMute.app
   ```

4. Grant **Accessibility** permission when asked (System Settings → Privacy & Security → Accessibility). Global shortcuts need it.

### 3. Connect them

1. Go back to `chrome://extensions` and click the reload icon on the MacMute extension.
2. Reload any open Google Meet tab.
3. Click the MacMute icon in the menu bar and record a shortcut for the microphone and one for the camera.

### Update

One time only: if you loaded the extension before it had a fixed ID, its ID changes with this update and the app accepts only the new one. In step 3, do not click reload: remove the extension in `chrome://extensions` and add it again with **Load unpacked**, then check that `chrome://extensions` shows the ID `ealicgogcpkafcocpppnmhgcaiepdple`.

1. Download the new files from the [latest release](https://github.com/RTeran/MacMute/releases/latest), including `SHA256SUMS.txt`, and check them as in [Install](#install).
2. Quit MacMute before replacing it. Then replace `/Applications/MacMute.app` with the new one, and check and allow it again as in [2. Install the app](#2-install-the-app).
3. Replace the contents of your `MacMute-chrome-extension` folder with the new ones and click reload in `chrome://extensions`.
4. Reload the Meet tab.

Releases after 1.1 are signed with a new certificate, so macOS treats them as a different app and you must grant **Accessibility** and **Microphone** again, once. This is on purpose: older releases have no hardened runtime, and another program running as your user could put one of them back and inject code into it. The old grants must not stay with them. When you update from 1.1 or older, quit MacMute and remove its old permissions before you open the new version:

```bash
tccutil reset Accessibility com.macmute.app
tccutil reset Microphone com.macmute.app
```

Then open the new MacMute and grant both permissions when asked. Later releases keep the same certificate, so macOS keeps the permissions after an update.

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

## Known limits

The extension's ID comes from the public `key` in `chrome-extension/manifest.json`. Another unpacked extension that copies this key gets the same ID and can talk to the app. Only an unpacked extension can do this. The Chrome Web Store assigns its own ID, so a store version would need a new allowed origin.

A program that runs as your user can start the real helper itself and send fake messages to the app through the helper's standard input. The app cannot tell these messages from Chrome's. This risk is accepted: such a program already runs with your permissions.

The same kind of program could create the app's socket, `~/Library/Application Support/MacMute/macmute.sock`, and then start the real app inside its own process (fork, then exec). It is not verified whether the helper would accept that app. This risk is also accepted.

The app and the helper only accept each other from this release on. v1.0 is not signed with the MacMute certificate (it is ad-hoc), and v1.1 runs without the hardened runtime, so the new app and helper reject both. Do not mix versions: run only the latest MacMute.

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

Releases are signed with a self-signed certificate named `MacMute Code Signing 2026`. It is not trusted by Apple, so Gatekeeper still asks users to allow the app once, but its identity stays the same between releases and macOS keeps the Accessibility and Microphone permissions. Releases signed with a different certificate make every user grant the permissions again, so keep a backup of it. Releases up to 1.1 used an older certificate named `MacMute Code Signing`; it can stay in the keychain, but do not sign with it.

To create the certificate, open Keychain Access and choose **Certificate Assistant → Create a Certificate…**. Use the name `MacMute Code Signing 2026`, identity type **Self Signed Root**, certificate type **Code Signing**, and tick **Let me override defaults**: validity 3650 days, RSA 2048-bit key, Key Usage **Signature** (critical), Extended Key Usage **Code Signing** (critical), Basic Constraints not a certificate authority, keychain **login**. Then print its SHA-1, which goes in lowercase into `LEAF_PIN`:

```bash
security find-identity -p codesigning | grep '"MacMute Code Signing 2026"'
```

Export it with its key as a `.p12` file and keep the backup off the Mac. The certificate must be in your login keychain. To use it on another Mac, import the backup:

```bash
security import MacMute-signing-2026.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```

Build a universal app, sign it and package both downloads into `dist/`:

```bash
./scripts/release.sh
gh release create vX.Y dist/MacMute-app.zip dist/MacMute-chrome-extension.zip dist/SHA256SUMS.txt
```

To sign with another identity, set `MACMUTE_SIGNING_IDENTITY`.

Releases pin the SHA-1 hash of the signing certificate: the app and the helper refuse to connect unless they are signed with that exact certificate. A new certificate means updating `LEAF_PIN` in `scripts/release.sh`. The script stops before building if `LEAF_PIN` does not match the certificate of the signing identity.
