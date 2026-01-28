import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var muteStateManager: MuteStateManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MacMute: App launched")
        muteStateManager = MuteStateManager.shared
        statusBarController = StatusBarController(muteStateManager: muteStateManager)
        muteStateManager.start()
        installNativeMessagingHost()
    }

    func applicationWillTerminate(_ notification: Notification) {
        muteStateManager.stop()
    }

    private func installNativeMessagingHost() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let chromeNMHDir = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")

        do {
            try fileManager.createDirectory(at: chromeNMHDir, withIntermediateDirectories: true)
        } catch {
            NSLog("MacMute: Failed to create NativeMessagingHosts directory: \(error)")
            return
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MacMuteHelper")
        let helperPath = helperURL.path

        guard fileManager.fileExists(atPath: helperPath) else {
            NSLog("MacMute: MacMuteHelper not found at \(helperPath)")
            return
        }

        // Ensure the helper is executable
        try? fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperPath
        )

        let extensionIds = findMacMuteExtensionIds()
        let origins = extensionIds.map { "chrome-extension://\($0)/" }

        if origins.isEmpty {
            NSLog("MacMute: WARNING - No MacMute extension found in Chrome. Install the extension and restart the app.")
        } else {
            NSLog("MacMute: Found extension IDs: \(extensionIds)")
        }

        let manifest: [String: Any] = [
            "name": "com.macmute.helper",
            "description": "MacMute Native Messaging Helper",
            "path": helperPath,
            "type": "stdio",
            "allowed_origins": origins
        ]

        let manifestPath = chromeNMHDir.appendingPathComponent("com.macmute.helper.json")

        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestPath)
            NSLog("MacMute: Installed native messaging manifest at \(manifestPath.path)")
            NSLog("MacMute: Helper path: \(helperPath)")
        } catch {
            NSLog("MacMute: Failed to write manifest: \(error)")
        }
    }

    private func findMacMuteExtensionIds() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let chromeDir = home.appendingPathComponent("Library/Application Support/Google/Chrome")

        // Check Default and numbered profiles
        var profileDirs = [chromeDir.appendingPathComponent("Default")]
        if let contents = try? fileManager.contentsOfDirectory(atPath: chromeDir.path) {
            for name in contents where name.hasPrefix("Profile ") {
                profileDirs.append(chromeDir.appendingPathComponent(name))
            }
        }

        var extensionIds: Set<String> = []

        for profileDir in profileDirs {
            // Read Secure Preferences — contains ALL extensions including unpacked
            let securePrefsPath = profileDir.appendingPathComponent("Secure Preferences")
            if let ids = extractExtensionIds(fromPrefsAt: securePrefsPath) {
                extensionIds.formUnion(ids)
            }

            // Also check regular Preferences as fallback
            let prefsPath = profileDir.appendingPathComponent("Preferences")
            if let ids = extractExtensionIds(fromPrefsAt: prefsPath) {
                extensionIds.formUnion(ids)
            }
        }

        return Array(extensionIds)
    }

    private func extractExtensionIds(fromPrefsAt url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let settings = extensions["settings"] as? [String: Any] else {
            return nil
        }

        var ids: [String] = []
        for (extId, value) in settings {
            guard let extInfo = value as? [String: Any] else { continue }

            // Check manifest.name inside the settings entry
            if let manifest = extInfo["manifest"] as? [String: Any],
               let name = manifest["name"] as? String,
               name.contains("MacMute") {
                ids.append(extId)
                continue
            }

            // Also check the path — unpacked extensions loaded from our project dir
            if let path = extInfo["path"] as? String,
               path.contains("MacMute") {
                ids.append(extId)
            }
        }

        return ids.isEmpty ? nil : ids
    }
}
