import Foundation
import Combine

extension Notification.Name {
    static let muteStateDidChange = Notification.Name("muteStateDidChange")
}

class MuteStateManager: ObservableObject {
    static let shared = MuteStateManager()

    @Published var isMuted: Bool = false

    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
    private let audioManager = AudioManager.shared
    private let shortcutManager = GlobalShortcutManager.shared

    private init() {}

    func start() {
        // Setup socket server
        socketServer.onMessageReceived = { [weak self] message in
            self?.handleMessage(message)
        }
        socketServer.onClientConnected = { [weak self] in
            NSLog("MacMute: Helper connected, requesting state")
            self?.requestState()
        }
        socketServer.start()

        // Setup shortcut
        shortcutManager.onShortcutTriggered = { [weak self] in
            self?.toggleMute()
        }
        shortcutManager.start()
    }

    func stop() {
        shortcutManager.stop()
        socketServer.stop()
    }

    func toggleMute() {
        // Only send the command — state updates when the extension confirms
        socketServer.sendMessage(["type": "toggle"])
        NSLog("MacMute: Toggle sent to extension, waiting for confirmation")
    }

    func requestState() {
        socketServer.sendMessage(["type": "get_state"])
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "state_update":
            if let muted = message["muted"] as? Bool {
                updateState(muted: muted)
                audioManager.setSystemMicMute(muted)
            }
        default:
            NSLog("MacMute: Unknown message type: \(type)")
        }
    }

    private func updateState(muted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isMuted = muted
            self.overlayManager.updateOverlay(muted: muted)
            NotificationCenter.default.post(name: .muteStateDidChange, object: nil)
        }
    }
}
