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
            scheduleColorSave()
            refreshOverlayIfVisible()
        }
    }
    @Published var cameraOffColor: Color = .blue {
        didSet {
            scheduleColorSave()
            refreshOverlayIfVisible()
        }
    }

    private static let unconfirmedColor = NSColor.systemOrange.withAlphaComponent(0.85)

    // The ColorPicker reports every step of a drag, so colors are saved once it settles.
    private let colorSaveDebouncer = Debouncer(delay: 0.5)
    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
    private let shortcutManager = GlobalShortcutManager.shared
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")
    private lazy var toggleConfirmation: ToggleConfirmation = {
        let confirmation = ToggleConfirmation(
            confirmationTimeouts: .standard,
            feedbackDuration: UnconfirmedFeedback.duration,
            confirmedState: { [unowned self] target in
                target == .mic ? self.isMuted : self.isCameraOff
            },
            send: { [weak self] target, requestId, completion in
                guard let self = self else { return completion(.failed(reason: "app_shutting_down")) }
                self.socketServer.sendMessage(["type": target.commandType, "requestId": requestId]) { result in
                    switch result {
                    case .success: completion(.sent)
                    case let .failure(error): completion(.failed(reason: error.rawValue))
                    }
                }
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
            self?.logger.notice("Helper connected, requesting mic and camera state")
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
        colorSaveDebouncer.flush()
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
                updateMicState(muted: muted)
                toggleConfirmation.handlePassiveUpdate(.mic, newState: muted)
            }
        case "camera_state_update":
            if let active = message["active"] as? Bool {
                updateCameraState(active: active)
                toggleConfirmation.handlePassiveUpdate(.camera, newState: !active)
            }
        case "toggle_result":
            handleToggleResult(message)
        default:
            logger.error("Unknown message type: \(type, privacy: .public)")
        }
    }

    private func handleToggleResult(_ message: [String: Any]) {
        guard let result = ToggleResult(message: message) else {
            logger.error("Malformed toggle_result: \(String(describing: message), privacy: .public)")
            return
        }
        if result.outcome == .failed(reason: "missing_state") {
            logger.error("toggle_result ok without state: \(String(describing: message), privacy: .public)")
        }

        // The confirmed state must be current before handle() ends the unconfirmed feedback, which
        // restores the overlay and the menu bar icon from it.
        if case let .confirmed(newState) = result.outcome {
            switch result.target {
            case .mic: updateMicState(muted: newState)
            case .camera: updateCameraState(active: !newState)
            }
        }
        toggleConfirmation.handle(result)
    }

    // Socket messages are delivered on main (SocketServer), so these run synchronously.
    private func updateMicState(muted: Bool) {
        isMuted = muted
        pushOverlayState()
        NotificationCenter.default.post(name: .muteStateDidChange, object: nil)
    }

    private func updateCameraState(active: Bool) {
        isCameraOff = !active
        pushOverlayState()
        NotificationCenter.default.post(name: .cameraStateDidChange, object: nil)
    }

    private func pushOverlayState() {
        overlayManager.updateOverlay(
            micMuted: isMuted,
            cameraOff: isCameraOff,
            micColor: NSColor(micMutedColor).withAlphaComponent(0.7),
            cameraColor: NSColor(cameraOffColor).withAlphaComponent(0.7)
        )
    }

    private func refreshOverlayIfVisible() {
        guard isMuted || isCameraOff else { return }
        pushOverlayState()
    }

    private func scheduleColorSave() {
        colorSaveDebouncer.schedule { [weak self] in
            guard let self = self else { return }
            self.saveColor(self.micMutedColor, forKey: "micMutedColorData")
            self.saveColor(self.cameraOffColor, forKey: "cameraOffColorData")
        }
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
