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

enum ToggleTarget: String {
    case mic
    case camera

    var commandType: String {
        switch self {
        case .mic: return "toggle"
        case .camera: return "toggle_camera"
        }
    }
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

    // Longer than the content script wait (1200 ms) so its answer can still arrive in time.
    static let toggleConfirmationTimeout: TimeInterval = 1.5
    static let unconfirmedFeedbackDuration: TimeInterval = 3
    private static let unconfirmedColor = NSColor.systemOrange.withAlphaComponent(0.85)

    private struct PendingToggle {
        let requestId: String
        let timeout: DispatchWorkItem
    }

    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
    private let shortcutManager = GlobalShortcutManager.shared
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")
    private var pendingToggles: [ToggleTarget: PendingToggle] = [:]
    private var unconfirmedFeedbackEnd: DispatchWorkItem?
    private var unconfirmedTarget: ToggleTarget?

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
        sendToggle(.mic)
    }

    func toggleCamera() {
        sendToggle(.camera)
    }

    private func sendToggle(_ target: ToggleTarget) {
        let requestId = UUID().uuidString
        pendingToggles[target]?.timeout.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.failToggle(target, requestId: requestId, reason: "timeout")
        }
        pendingToggles[target] = PendingToggle(requestId: requestId, timeout: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toggleConfirmationTimeout, execute: timeout)

        socketServer.sendMessage(["type": target.commandType, "requestId": requestId]) { [weak self] sent in
            if !sent {
                self?.failToggle(target, requestId: requestId, reason: "no_socket_client")
            }
        }
        logger.debug("Toggle \(target.rawValue, privacy: .public) sent, request \(requestId, privacy: .public)")
    }

    private func confirmToggle(_ target: ToggleTarget, requestId: String?) {
        guard let pending = pendingToggles[target],
              requestId == nil || requestId == pending.requestId else { return }
        pending.timeout.cancel()
        pendingToggles[target] = nil
        logger.debug("Toggle \(target.rawValue, privacy: .public) confirmed, request \(pending.requestId, privacy: .public)")
    }

    private func failToggle(_ target: ToggleTarget, requestId: String?, reason: String) {
        guard let pending = pendingToggles[target],
              requestId == nil || requestId == pending.requestId else {
            logger.debug("Ignoring stale \(target.rawValue, privacy: .public) failure: \(reason, privacy: .public)")
            return
        }
        pending.timeout.cancel()
        pendingToggles[target] = nil
        logger.error("Toggle \(target.rawValue, privacy: .public) unconfirmed (\(reason, privacy: .public)), request \(pending.requestId, privacy: .public)")
        startUnconfirmedFeedback(for: target)
    }

    private func startUnconfirmedFeedback(for target: ToggleTarget) {
        unconfirmedFeedbackEnd?.cancel()
        unconfirmedTarget = target
        let end = DispatchWorkItem { [weak self] in
            self?.endUnconfirmedFeedback()
        }
        unconfirmedFeedbackEnd = end
        overlayManager.showUnconfirmed(color: Self.unconfirmedColor)
        NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidStart, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unconfirmedFeedbackDuration, execute: end)
    }

    private func endUnconfirmedFeedback(for target: ToggleTarget? = nil) {
        guard let end = unconfirmedFeedbackEnd,
              target == nil || target == unconfirmedTarget else { return }
        end.cancel()
        unconfirmedFeedbackEnd = nil
        unconfirmedTarget = nil
        overlayManager.hideUnconfirmed()
        NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidEnd, object: nil)
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
                // A passive update that flips the state is as good as a toggle_result.
                if muted != isMuted {
                    confirmToggle(.mic, requestId: nil)
                    endUnconfirmedFeedback(for: .mic)
                }
                updateMicState(muted: muted)
            }
        case "camera_state_update":
            if let active = message["active"] as? Bool {
                if active == isCameraOff {
                    confirmToggle(.camera, requestId: nil)
                    endUnconfirmedFeedback(for: .camera)
                }
                updateCameraState(active: active)
            }
        case "toggle_result":
            handleToggleResult(message)
        default:
            NSLog("MacMute: Unknown message type: \(type)")
        }
    }

    private func handleToggleResult(_ message: [String: Any]) {
        guard let targetName = message["target"] as? String,
              let target = ToggleTarget(rawValue: targetName),
              let ok = message["ok"] as? Bool else {
            logger.error("Malformed toggle_result: \(String(describing: message), privacy: .public)")
            return
        }
        let requestId = message["requestId"] as? String

        guard ok else {
            failToggle(target, requestId: requestId, reason: message["reason"] as? String ?? "unknown")
            return
        }

        confirmToggle(target, requestId: requestId)
        // A late success after the timeout still carries the real state, so apply it and end the warning.
        endUnconfirmedFeedback(for: target)
        switch target {
        case .mic:
            if let muted = message["muted"] as? Bool { updateMicState(muted: muted) }
        case .camera:
            if let off = message["off"] as? Bool { updateCameraState(active: !off) }
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
