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

    private static let unconfirmedColor = NSColor.systemOrange.withAlphaComponent(0.85)

    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
    private let shortcutManager = GlobalShortcutManager.shared
    private lazy var coordinator: MuteStateCoordinator = {
        let coordinator = MuteStateCoordinator(
            confirmationTimeouts: .standard,
            feedbackDuration: UnconfirmedFeedback.duration,
            send: { [weak self] message, helper, completion in
                guard let self = self else { return completion(.failure(.appShuttingDown)) }
                self.socketServer.sendMessage(message, to: helper, completion: completion)
            }
        )
        coordinator.onDisplayedStateChange = { [weak self] target, state in
            self?.show(state, changed: target)
        }
        coordinator.onUnconfirmedFeedbackStart = { [weak self] _ in
            self?.overlayManager.showUnconfirmed(color: Self.unconfirmedColor)
            NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidStart, object: nil)
        }
        coordinator.onUnconfirmedFeedbackEnd = { [weak self] _ in
            self?.overlayManager.hideUnconfirmed()
            NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidEnd, object: nil)
        }
        return coordinator
    }()

    private init() {
        micMutedColor = loadColor(forKey: "micMutedColorData", default: .red)
        cameraOffColor = loadColor(forKey: "cameraOffColorData", default: .blue)
    }

    func start() {
        socketServer.onClientConnected = { [weak self] helper in
            self?.coordinator.helperConnected(helper)
        }
        socketServer.onClientDisconnected = { [weak self] helper in
            self?.coordinator.helperDisconnected(helper)
        }
        socketServer.onMessageReceived = { [weak self] helper, message in
            self?.coordinator.handle(message, from: helper)
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
        coordinator.toggle(.mic)
    }

    func toggleCamera() {
        coordinator.toggle(.camera)
    }

    // Runs synchronously on main: the overlay must get the new state before a following
    // hideUnconfirmed() redraws it (B14).
    private func show(_ state: DisplayedMuteState, changed target: ToggleTarget) {
        isMuted = state.isMuted
        isCameraOff = state.isCameraOff
        overlayManager.updateOverlay(
            micMuted: isMuted,
            cameraOff: isCameraOff,
            micColor: NSColor(micMutedColor).withAlphaComponent(0.7),
            cameraColor: NSColor(cameraOffColor).withAlphaComponent(0.7)
        )
        NotificationCenter.default.post(name: target == .mic ? .muteStateDidChange : .cameraStateDidChange, object: nil)
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
