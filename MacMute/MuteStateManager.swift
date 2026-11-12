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

/// Tracks the toggle waiting for confirmation per target. A state flag is `true` when the mic is
/// muted or the camera is off.
struct PendingToggleTracker {
    struct Pending: Equatable {
        let requestId: String
        let expected: Bool
    }

    private(set) var pending: [ToggleTarget: Pending] = [:]

    // A press made before the previous one is confirmed expects to undo that previous press.
    mutating func begin(_ target: ToggleTarget, requestId: String, confirmedState: Bool) -> Pending {
        let baseline = pending[target]?.expected ?? confirmedState
        let toggle = Pending(requestId: requestId, expected: !baseline)
        pending[target] = toggle
        return toggle
    }

    mutating func resolve(_ target: ToggleTarget, requestId: String) -> Pending? {
        guard let toggle = pending[target], toggle.requestId == requestId else { return nil }
        pending[target] = nil
        return toggle
    }

    mutating func resolvePassive(_ target: ToggleTarget, newState: Bool) -> Pending? {
        guard let toggle = pending[target], toggle.expected == newState else { return nil }
        pending[target] = nil
        return toggle
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

    // Covers the content script wait (1200 ms) rounded up by hidden-tab timer alignment (~1 s)
    // plus the 200 ms reinjection delay.
    static let toggleConfirmationTimeout: TimeInterval = 2.5
    static let unconfirmedFeedbackDuration: TimeInterval = 3
    private static let unconfirmedColor = NSColor.systemOrange.withAlphaComponent(0.85)

    private let socketServer = SocketServer()
    private let overlayManager = MenuBarOverlayManager()
    private let shortcutManager = GlobalShortcutManager.shared
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")
    private var pendingToggles = PendingToggleTracker()
    private var toggleTimeouts: [ToggleTarget: DispatchWorkItem] = [:]
    private var unconfirmedFeedbackEnd: DispatchWorkItem?
    private var unconfirmedToggle: (target: ToggleTarget, toggle: PendingToggleTracker.Pending)?

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
        let toggle = pendingToggles.begin(target, requestId: requestId, confirmedState: confirmedState(of: target))

        toggleTimeouts[target]?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.failToggle(target, requestId: requestId, reason: "timeout")
        }
        toggleTimeouts[target] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toggleConfirmationTimeout, execute: timeout)

        socketServer.sendMessage(["type": target.commandType, "requestId": requestId]) { [weak self] sent in
            if !sent {
                self?.failToggle(target, requestId: requestId, reason: "no_socket_client")
            }
        }
        logger.debug("Toggle \(target.rawValue, privacy: .public) sent, request \(requestId, privacy: .public), expected \(toggle.expected)")
    }

    private func confirmedState(of target: ToggleTarget) -> Bool {
        switch target {
        case .mic: return isMuted
        case .camera: return isCameraOff
        }
    }

    private func settle(_ target: ToggleTarget, _ toggle: PendingToggleTracker.Pending) {
        toggleTimeouts[target]?.cancel()
        toggleTimeouts[target] = nil
        logger.debug("Toggle \(target.rawValue, privacy: .public) confirmed, request \(toggle.requestId, privacy: .public)")
    }

    private func failToggle(_ target: ToggleTarget, requestId: String, reason: String) {
        guard let toggle = pendingToggles.resolve(target, requestId: requestId) else {
            logger.debug("Ignoring stale \(target.rawValue, privacy: .public) failure (\(reason, privacy: .public)), request \(requestId, privacy: .public)")
            return
        }
        toggleTimeouts[target]?.cancel()
        toggleTimeouts[target] = nil
        logger.error("Toggle \(target.rawValue, privacy: .public) unconfirmed (\(reason, privacy: .public)), request \(toggle.requestId, privacy: .public)")
        startUnconfirmedFeedback(for: target, toggle)
    }

    private func startUnconfirmedFeedback(for target: ToggleTarget, _ toggle: PendingToggleTracker.Pending) {
        unconfirmedFeedbackEnd?.cancel()
        unconfirmedToggle = (target, toggle)
        let end = DispatchWorkItem { [weak self] in
            self?.endUnconfirmedFeedback()
        }
        unconfirmedFeedbackEnd = end
        overlayManager.showUnconfirmed(color: Self.unconfirmedColor)
        NotificationCenter.default.post(name: .unconfirmedToggleFeedbackDidStart, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unconfirmedFeedbackDuration, execute: end)
    }

    // A state that is not the one the failed press wanted (e.g. the first press of a fast double
    // press confirming late) must not hide the warning.
    private func endUnconfirmedFeedback(for target: ToggleTarget, reached newState: Bool) {
        guard let failed = unconfirmedToggle,
              failed.target == target, failed.toggle.expected == newState else { return }
        endUnconfirmedFeedback()
    }

    private func endUnconfirmedFeedback() {
        guard let end = unconfirmedFeedbackEnd else { return }
        end.cancel()
        unconfirmedFeedbackEnd = nil
        unconfirmedToggle = nil
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
        guard let type = message["type"] as? String else {
            logger.error("Message without type: \(String(describing: message), privacy: .public)")
            return
        }

        switch type {
        case "state_update":
            if let muted = message["muted"] as? Bool {
                handlePassiveUpdate(.mic, newState: muted)
                updateMicState(muted: muted)
            }
        case "camera_state_update":
            if let active = message["active"] as? Bool {
                handlePassiveUpdate(.camera, newState: !active)
                updateCameraState(active: active)
            }
        case "toggle_result":
            handleToggleResult(message)
        default:
            logger.error("Unknown message type: \(type, privacy: .public)")
        }
    }

    // A passive update that reaches the state the pending press expects is as good as a toggle_result.
    private func handlePassiveUpdate(_ target: ToggleTarget, newState: Bool) {
        if let toggle = pendingToggles.resolvePassive(target, newState: newState) {
            settle(target, toggle)
        }
        endUnconfirmedFeedback(for: target, reached: newState)
    }

    private func handleToggleResult(_ message: [String: Any]) {
        guard let targetName = message["target"] as? String,
              let target = ToggleTarget(rawValue: targetName),
              let ok = message["ok"] as? Bool else {
            logger.error("Malformed toggle_result: \(String(describing: message), privacy: .public)")
            return
        }

        if let requestId = message["requestId"] as? String {
            if ok {
                if let toggle = pendingToggles.resolve(target, requestId: requestId) {
                    settle(target, toggle)
                }
            } else {
                failToggle(target, requestId: requestId, reason: message["reason"] as? String ?? "unknown")
            }
        } else {
            logger.warning("toggle_result without requestId, not matched to a pending toggle: \(String(describing: message), privacy: .public)")
        }

        guard ok else { return }
        let stateKey = target == .mic ? "muted" : "off"
        guard let newState = message[stateKey] as? Bool else {
            logger.error("toggle_result ok without \(stateKey, privacy: .public): \(String(describing: message), privacy: .public)")
            return
        }
        // A late success after the timeout still carries the real state.
        endUnconfirmedFeedback(for: target, reached: newState)
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
