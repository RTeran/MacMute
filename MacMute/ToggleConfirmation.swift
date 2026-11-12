import Foundation
import os

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

protocol ToggleTimer {
    func cancel()
}

extension DispatchWorkItem: ToggleTimer {}

/// Decides when a toggle counts as confirmed and when to show the unconfirmed (amber) feedback.
/// Runs on a single queue (main in the app); timers, sending and request ids are injected for tests.
final class ToggleConfirmation {
    typealias Send = (_ target: ToggleTarget, _ requestId: String, _ completion: @escaping (Bool) -> Void) -> Void
    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> ToggleTimer

    var onUnconfirmedFeedbackStart: ((ToggleTarget) -> Void)?
    var onUnconfirmedFeedbackEnd: (() -> Void)?

    private(set) var pendingToggles = PendingToggleTracker()
    var isShowingUnconfirmedFeedback: Bool { unconfirmed != nil }

    private let confirmationTimeout: TimeInterval
    private let feedbackDuration: TimeInterval
    private let confirmedState: (ToggleTarget) -> Bool
    private let send: Send
    private let schedule: Schedule
    private let makeRequestId: () -> String
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")

    private var confirmationTimers: [ToggleTarget: ToggleTimer] = [:]
    private var unconfirmed: (target: ToggleTarget, toggle: PendingToggleTracker.Pending, end: ToggleTimer)?

    init(
        confirmationTimeout: TimeInterval,
        feedbackDuration: TimeInterval,
        confirmedState: @escaping (ToggleTarget) -> Bool,
        send: @escaping Send,
        schedule: @escaping Schedule = ToggleConfirmation.scheduleOnMain,
        makeRequestId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.confirmationTimeout = confirmationTimeout
        self.feedbackDuration = feedbackDuration
        self.confirmedState = confirmedState
        self.send = send
        self.schedule = schedule
        self.makeRequestId = makeRequestId
    }

    static func scheduleOnMain(after delay: TimeInterval, _ work: @escaping () -> Void) -> ToggleTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    func toggle(_ target: ToggleTarget) {
        let requestId = makeRequestId()
        let toggle = pendingToggles.begin(target, requestId: requestId, confirmedState: confirmedState(target))

        confirmationTimers[target]?.cancel()
        confirmationTimers[target] = schedule(confirmationTimeout) { [weak self] in
            self?.fail(target, requestId: requestId, reason: "timeout")
        }
        logger.debug("Toggle \(target.rawValue, privacy: .public) sent, request \(requestId, privacy: .public), expected \(toggle.expected)")

        send(target, requestId) { [weak self] sent in
            if !sent {
                self?.fail(target, requestId: requestId, reason: "no_socket_client")
            }
        }
    }

    /// `newState` is `true` when the mic is muted or the camera is off.
    func handleToggleResult(_ target: ToggleTarget, requestId: String?, ok: Bool, newState: Bool?, reason: String?) {
        if let requestId = requestId {
            if ok {
                if let toggle = pendingToggles.resolve(target, requestId: requestId) {
                    confirmed(target, toggle)
                }
            } else {
                fail(target, requestId: requestId, reason: reason ?? "unknown")
            }
        } else {
            logger.warning("toggle_result for \(target.rawValue, privacy: .public) without requestId, not matched to a pending toggle")
        }

        // A late success after the timeout still carries the real state.
        if ok, let newState = newState {
            endUnconfirmedFeedback(for: target, reached: newState)
        }
    }

    // A passive update that reaches the state the pending press expects is as good as a toggle_result.
    func handlePassiveUpdate(_ target: ToggleTarget, newState: Bool) {
        if let toggle = pendingToggles.resolvePassive(target, newState: newState) {
            confirmed(target, toggle)
        }
        endUnconfirmedFeedback(for: target, reached: newState)
    }

    private func confirmed(_ target: ToggleTarget, _ toggle: PendingToggleTracker.Pending) {
        confirmationTimers.removeValue(forKey: target)?.cancel()
        logger.debug("Toggle \(target.rawValue, privacy: .public) confirmed, request \(toggle.requestId, privacy: .public)")
    }

    private func fail(_ target: ToggleTarget, requestId: String, reason: String) {
        guard let toggle = pendingToggles.resolve(target, requestId: requestId) else {
            logger.debug("Ignoring stale \(target.rawValue, privacy: .public) failure (\(reason, privacy: .public)), request \(requestId, privacy: .public)")
            return
        }
        confirmationTimers.removeValue(forKey: target)?.cancel()
        logger.error("Toggle \(target.rawValue, privacy: .public) unconfirmed (\(reason, privacy: .public)), request \(toggle.requestId, privacy: .public)")
        startUnconfirmedFeedback(for: target, toggle)
    }

    private func startUnconfirmedFeedback(for target: ToggleTarget, _ toggle: PendingToggleTracker.Pending) {
        unconfirmed?.end.cancel()
        let end = schedule(feedbackDuration) { [weak self] in
            self?.endUnconfirmedFeedback()
        }
        unconfirmed = (target, toggle, end)
        onUnconfirmedFeedbackStart?(target)
    }

    // A state that is not the one the failed press wanted (e.g. the first press of a fast double
    // press confirming late) must not hide the warning.
    private func endUnconfirmedFeedback(for target: ToggleTarget, reached newState: Bool) {
        guard let failed = unconfirmed,
              failed.target == target, failed.toggle.expected == newState else { return }
        endUnconfirmedFeedback()
    }

    private func endUnconfirmedFeedback() {
        guard let failed = unconfirmed else { return }
        failed.end.cancel()
        unconfirmed = nil
        onUnconfirmedFeedbackEnd?()
    }
}
