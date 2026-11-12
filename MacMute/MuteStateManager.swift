import Foundation
import Combine
import SwiftUI
import os

extension Notification.Name {
    static let muteStateDidChange = Notification.Name("muteStateDidChange")
    static let cameraStateDidChange = Notification.Name("cameraStateDidChange")
    static let unconfirmedToggleFeedbackDidStart = Notification.Name("unconfirmedToggleFeedbackDidStart")
    static let unconfirmedToggleFeedbackDidEnd = Notification.Name("unconfirmedToggleFeedbackDidEnd")
}

class MuteStateManager: ObservableObject {
    static let shared = MuteStateManager()

    @Published var isMuted: Bool = false
    @Published var isCameraOff: Bool = false

    @Published var micMutedColor: Color = .red {
        didSet {
            saveColor(micMutedColor, forKey: "micMutedColorData")
            refreshOverlayIfVisible()
        }
    }
    @Published var cameraOffColor: Color = .blue {
        didSet {
            saveColor(cameraOffColor, forKey: "cameraOffColorData")
            refreshOverlayIfVisible()
        }
    }

    // Covers the content script wait (1200 ms) rounded up by hidden-tab timer alignment (~1 s)
    // plus the 200 ms reinjection delay.
    static let toggleConfirmationTimeout: TimeInterval = 2.5
    static let unconfirmedFeedbackDuration: TimeInterval = 3
    private static let unconfirmedColor = NSColor.systemOrange.withAlphaComponent(0.85)

    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
    private let shortcutManager = GlobalShortcutManager.shared
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")
    private lazy var toggleConfirmation: ToggleConfirmation = {
        let confirmation = ToggleConfirmation(
            confirmationTimeout: Self.toggleConfirmationTimeout,
            feedbackDuration: Self.unconfirmedFeedbackDuration,
            confirmedState: { [unowned self] target in
                target == .mic ? self.isMuted : self.isCameraOff
            },
            send: { [weak self] target, requestId, completion in
                guard let self = self else { return completion(false) }
                self.socketServer.sendMessage(["type": target.commandType, "requestId": requestId], completion: completion)
            }
        )
        confirmation.onUnconfirmedFeedbackStart = { [weak self] _ in
            self?.overlayManager.showUnconfirmed(color: Self.unconfirmedColor)
            NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidStart, object: nil)
        }
        confirmation.onUnconfirmedFeedbackEnd = { [weak self] in
            self?.overlayManager.hideUnconfirmed()
            NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidEnd, object: nil)
        }
        return confirmation
    }()

    private init() {
        micMutedColor = loadColor(forKey: "micMutedColorData", default: .red)
        cameraOffColor = loadColor(forKey: "cameraOffColorData", default: .blue)
    }

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
        toggleConfirmation.toggle(.mic)
    }

    func toggleCamera() {
        toggleConfirmation.toggle(.camera)
    }

    func requestState() {
        socketServer.sendMessage(["type": "get_state"])
    }

    func requestCameraState() {
        socketServer.sendMessage(["type": "get_camera_state"])
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else {
            logger.error("Message without type: \(String(describing: message), privacy: .public)")
            return
        }

        switch type {
        case "state_update":
            if let muted = message["muted"] as? Bool {
                toggleConfirmation.handlePassiveUpdate(.mic, newState: muted)
                updateMicState(muted: muted)
            }
        case "camera_state_update":
            if let active = message["active"] as? Bool {
                toggleConfirmation.handlePassiveUpdate(.camera, newState: !active)
                updateCameraState(active: active)
            }
        case "toggle_result":
            handleToggleResult(message)
        default:
            logger.error("Unknown message type: \(type, privacy: .public)")
        }
    }

    private func handleToggleResult(_ message: [String: Any]) {
        guard let targetName = message["target"] as? String,
              let target = ToggleTarget(rawValue: targetName),
              let ok = message["ok"] as? Bool else {
            logger.error("Malformed toggle_result: \(String(describing: message), privacy: .public)")
            return
        }

        let stateKey = target == .mic ? "muted" : "off"
        let newState = message[stateKey] as? Bool
        if ok && newState == nil {
            logger.error("toggle_result ok without \(stateKey, privacy: .public): \(String(describing: message), privacy: .public)")
        }

        toggleConfirmation.handleToggleResult(
            target,
            requestId: message["requestId"] as? String,
            ok: ok,
            newState: newState,
            reason: message["reason"] as? String
        )

        guard ok, let newState = newState else { return }
        switch target {
        case .mic: updateMicState(muted: newState)
        case .camera: updateCameraState(active: !newState)
        }
    }

    private func updateMicState(muted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isMuted = muted
            self.overlayManager.updateOverlay(
                micMuted: self.isMuted,
                cameraOff: self.isCameraOff,
                micColor: NSColor(self.micMutedColor).withAlphaComponent(0.7),
                cameraColor: NSColor(self.cameraOffColor).withAlphaComponent(0.7)
            )
            NotificationCenter.default.post(name: .muteStateDidChange, object: nil)
        }
    }

    private func updateCameraState(active: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isCameraOff = !active
            self.overlayManager.updateOverlay(
                micMuted: self.isMuted,
                cameraOff: self.isCameraOff,
                micColor: NSColor(self.micMutedColor).withAlphaComponent(0.7),
                cameraColor: NSColor(self.cameraOffColor).withAlphaComponent(0.7)
            )
            NotificationCenter.default.post(name: .cameraStateDidChange, object: nil)
        }
    }

    private func refreshOverlayIfVisible() {
        guard isMuted || isCameraOff else { return }
        overlayManager.updateOverlay(
            micMuted: isMuted,
            cameraOff: isCameraOff,
            micColor: NSColor(micMutedColor).withAlphaComponent(0.7),
            cameraColor: NSColor(cameraOffColor).withAlphaComponent(0.7)
        )
    }

    private func saveColor(_ color: Color, forKey key: String) {
        let nsColor = NSColor(color)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: nsColor, requiringSecureCoding: false
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadColor(forKey key: String, default defaultColor: Color) -> Color {
        guard let data = UserDefaults.standard.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: NSColor.self, from: data
              )
        else { return defaultColor }
        return Color(nsColor: nsColor)
    }
}
