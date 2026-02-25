import Foundation
import Combine

extension Notification.Name {
    static let muteStateDidChange = Notification.Name("muteStateDidChange")
    static let cameraStateDidChange = Notification.Name("cameraStateDidChange")
}

class MuteStateManager: ObservableObject {
    static let shared = MuteStateManager()

    @Published var isMuted: Bool = false
    @Published var isCameraOff: Bool = false

    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
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
            self?.requestCameraState()
        }
        socketServer.start()

        // Setup mic shortcut
        shortcutManager.onShortcutTriggered = { [weak self] in
            self?.toggleMute()
        }
        // Setup camera shortcut
        shortcutManager.onCameraShortcutTriggered = { [weak self] in
            self?.toggleCamera()
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
        NSLog("MacMute: Toggle mic sent to extension, waiting for confirmation")
    }

    func toggleCamera() {
        // Only send the command — state updates when the extension confirms
        socketServer.sendMessage(["type": "toggle_camera"])
        NSLog("MacMute: Toggle camera sent to extension, waiting for confirmation")
    }

    func requestState() {
        socketServer.sendMessage(["type": "get_state"])
    }

    func requestCameraState() {
        socketServer.sendMessage(["type": "get_camera_state"])
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "state_update":
            if let muted = message["muted"] as? Bool {
                updateMicState(muted: muted)
            }
        case "camera_state_update":
            if let active = message["active"] as? Bool {
                updateCameraState(active: active)
            }
        default:
            NSLog("MacMute: Unknown message type: \(type)")
        }
    }

    private func updateMicState(muted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isMuted = muted
            self.overlayManager.updateOverlay(micMuted: self.isMuted, cameraOff: self.isCameraOff)
            NotificationCenter.default.post(name: .muteStateDidChange, object: nil)
        }
    }

    private func updateCameraState(active: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isCameraOff = !active
            self.overlayManager.updateOverlay(micMuted: self.isMuted, cameraOff: self.isCameraOff)
            NotificationCenter.default.post(name: .cameraStateDidChange, object: nil)
        }
    }
}
