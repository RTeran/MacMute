import Cocoa
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var muteStateManager: MuteStateManager!
    private var didInstallNativeMessagingHost = false
    private let logger = Logger(subsystem: "com.macmute.app", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MacMute: App launched")
        muteStateManager = MuteStateManager.shared
        statusBarController = StatusBarController(muteStateManager: muteStateManager)
        // Written only once this instance owns the socket: a second instance must not point Chrome
        // at its own helper before it quits.
        muteStateManager.onSocketServerListening = { [weak self] in
            guard let self, !self.didInstallNativeMessagingHost else { return }
            // The server reports listening once per launch, so a failed install stays failed until
            // the next launch; meanwhile the popover says MacMute can't accept connections from Chrome.
            self.didInstallNativeMessagingHost = self.installNativeMessagingHost()
            self.muteStateManager.nativeMessagingHostInstallFailed = !self.didInstallNativeMessagingHost
        }
        muteStateManager.onAnotherInstanceRunning = { [weak self] in
            self?.quitBecauseAnotherInstanceIsRunning()
        }
        muteStateManager.start()
    }

    private func quitBecauseAnotherInstanceIsRunning() {
        // An agent app is not active on its own, so the alert would open behind other windows.
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.messageText = "MacMute is already running"
        alert.informativeText = "Another copy of MacMute is open, so this one will quit."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        muteStateManager.stop()
    }

    private func installNativeMessagingHost() -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let chromeNMHDir = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")

        do {
            try fileManager.createDirectory(at: chromeNMHDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create the NativeMessagingHosts directory: \(errorCode(error), privacy: .public)")
            return false
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MacMuteHelper")
        let helperPath = helperURL.path

        guard fileManager.fileExists(atPath: helperPath) else {
            logger.error("MacMuteHelper not found at \(helperPath)")
            return false
        }

        let executability = ensureExecutable(atPath: helperPath)
        if let error = executability.chmodError {
            logger.error("Failed to make MacMuteHelper executable: \(errorCode(error), privacy: .public)")
        }
        guard executability.isExecutable else {
            logger.error("MacMuteHelper is not executable")
            return false
        }

        let manifest = NativeMessagingHost.manifest(helperPath: helperPath)
        let manifestPath = chromeNMHDir.appendingPathComponent("\(NativeMessagingHost.name).json")

        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestPath)
            logger.notice("Installed the native messaging manifest at \(manifestPath.path) for the helper at \(helperPath)")
            return true
        } catch {
            logger.error("Failed to write the native messaging manifest: \(errorCode(error), privacy: .public)")
            return false
        }
    }
}
