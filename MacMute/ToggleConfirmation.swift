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

/// A `toggle_result` from the extension. `newState` is `true` when the mic is muted or the camera is off.
struct ToggleResult: Equatable {
    enum Outcome: Equatable {
        case confirmed(newState: Bool)
        case failed(reason: String)
    }

    let target: ToggleTarget
    let requestId: String?
    let outcome: Outcome
    /// What confirmed the toggle in the extension ("dom" or "media_session"); only for logging.
    let source: String?

    init(target: ToggleTarget, requestId: String?, outcome: Outcome, source: String? = nil) {
        self.target = target
        self.requestId = requestId
        self.outcome = outcome
        self.source = source
    }

    init?(message: [String: Any]) {
        guard let targetName = message["target"] as? String,
              let target = ToggleTarget(rawValue: targetName),
              let ok = message["ok"] as? Bool else { return nil }

        self.target = target
        self.requestId = message["requestId"] as? String
        self.source = message["source"] as? String

        let stateKey = target == .mic ? "muted" : "off"
        if !ok {
            outcome = .failed(reason: message["reason"] as? String ?? "unknown")
        } else if let newState = message[stateKey] as? Bool {
            outcome = .confirmed(newState: newState)
        } else {
            outcome = .failed(reason: "missing_state")
        }
    }
}

enum ToggleSendOutcome: Equatable {
    case sent
    case failed(reason: String)
}

/// How long the app waits for a toggle_result before showing the unconfirmed feedback.
struct ConfirmationTimeouts: Equatable {
    // Each budget must outlast the content script's wait for that target (1200 ms mic, 2500 ms
    // camera), rounded up by hidden-tab timer alignment (~1 s), plus the 200 ms reinjection delay.
    static let standard = ConfirmationTimeouts(mic: 3.0, camera: 4.0)

    let mic: TimeInterval
    let camera: TimeInterval

    func timeout(for target: ToggleTarget) -> TimeInterval {
        switch target {
        case .mic: return mic
        case .camera: return camera
        }
    }
}

enum ToggleTimerKind {
    case confirmation
    case unconfirmedFeedback
}

protocol ToggleTimer {
    func cancel()
}

extension DispatchWorkItem: ToggleTimer {}

/// Decides when a toggle counts as confirmed and when to show the unconfirmed (amber) feedback.
/// Runs on a single queue (main in the app); timers, sending and request ids are injected for tests.
final class ToggleConfirmation {
    typealias Send = (
        _ target: ToggleTarget, _ requestId: String, _ completion: @escaping (ToggleSendOutcome) -> Void
    ) -> Void
    typealias Schedule = (_ kind: ToggleTimerKind, _ delay: TimeInterval, _ work: @escaping () -> Void) -> ToggleTimer

    var onUnconfirmedFeedbackStart: ((ToggleTarget) -> Void)?
    var onUnconfirmedFeedbackEnd: (() -> Void)?

    private(set) var pendingToggles = PendingToggleTracker()
    var isShowingUnconfirmedFeedback: Bool { unconfirmed != nil }

    private let confirmationTimeouts: ConfirmationTimeouts
    private let feedbackDuration: TimeInterval
    private let confirmedState: (ToggleTarget) -> Bool
    private let send: Send
    private let schedule: Schedule
    private let makeRequestId: () -> String
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")

    private var confirmationTimers: [ToggleTarget: ToggleTimer] = [:]
    private var unconfirmed: (target: ToggleTarget, toggle: PendingToggleTracker.Pending, end: ToggleTimer)?

    init(
        confirmationTimeouts: ConfirmationTimeouts,
        feedbackDuration: TimeInterval,
        confirmedState: @escaping (ToggleTarget) -> Bool,
        send: @escaping Send,
        schedule: @escaping Schedule = ToggleConfirmation.scheduleOnMain,
        makeRequestId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.confirmationTimeouts = confirmationTimeouts
        self.feedbackDuration = feedbackDuration
        self.confirmedState = confirmedState
        self.send = send
        self.schedule = schedule
        self.makeRequestId = makeRequestId
    }

    static func scheduleOnMain(
        _ kind: ToggleTimerKind, after delay: TimeInterval, _ work: @escaping () -> Void
    ) -> ToggleTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    func toggle(_ target: ToggleTarget) {
        let requestId = makeRequestId()
        let toggle = pendingToggles.begin(target, requestId: requestId, confirmedState: confirmedState(target))

        confirmationTimers[target]?.cancel()
        confirmationTimers[target] = schedule(.confirmation, confirmationTimeouts.timeout(for: target)) { [weak self] in
            self?.fail(target, requestId: requestId, reason: "timeout")
        }
        logger.debug("Toggle \(target.rawValue, privacy: .public) sent, request \(requestId, privacy: .public), expected \(toggle.expected)")

        send(target, requestId) { [weak self] outcome in
            if case let .failed(reason) = outcome {
                self?.fail(target, requestId: requestId, reason: reason)
            }
        }
    }

    func handle(_ result: ToggleResult) {
        let target = result.target
        switch (result.outcome, result.requestId) {
        case let (.failed(reason), requestId?):
            fail(target, requestId: requestId, reason: reason)

        case let (.failed(reason), nil):
            logger.warning("toggle_result failure for \(target.rawValue, privacy: .public) without requestId (\(reason, privacy: .public)), not matched to a pending toggle")

        case let (.confirmed(newState), requestId?):
            if let toggle = pendingToggles.resolve(target, requestId: requestId) {
                if newState == toggle.expected {
                    confirmed(target, toggle, source: result.source ?? "unknown")
                } else {
                    unconfirm(target, toggle, reason: "unexpected_state", source: result.source)
                }
            }
            // A late success after the timeout still carries the real state.
            endUnconfirmedFeedback(for: target, reached: newState)

        case let (.confirmed(newState), nil):
            logger.warning("toggle_result for \(target.rawValue, privacy: .public) without requestId, matching it as a passive update")
            handlePassiveUpdate(target, newState: newState)
        }
    }

    // A passive update that reaches the state the pending press expects is as good as a toggle_result.
    func handlePassiveUpdate(_ target: ToggleTarget, newState: Bool) {
        if let toggle = pendingToggles.resolvePassive(target, newState: newState) {
            confirmed(target, toggle, source: "passive_update")
        }
        endUnconfirmedFeedback(for: target, reached: newState)
    }

    private func confirmed(_ target: ToggleTarget, _ toggle: PendingToggleTracker.Pending, source: String) {
        confirmationTimers.removeValue(forKey: target)?.cancel()
        logger.notice("Toggle \(target.rawValue, privacy: .public) confirmed by \(source, privacy: .public), request \(toggle.requestId, privacy: .public)")
    }

    private func fail(_ target: ToggleTarget, requestId: String, reason: String) {
        guard let toggle = pendingToggles.resolve(target, requestId: requestId) else {
            if unconfirmed?.toggle.requestId == requestId {
                logger.error("Toggle \(target.rawValue, privacy: .public) already unconfirmed; real reason \(reason, privacy: .public), request \(requestId, privacy: .public)")
            } else {
                logger.notice("Ignoring stale \(target.rawValue, privacy: .public) failure (\(reason, privacy: .public)), request \(requestId, privacy: .public)")
            }
            return
        }
        unconfirm(target, toggle, reason: reason)
    }

    private func unconfirm(
        _ target: ToggleTarget, _ toggle: PendingToggleTracker.Pending, reason: String, source: String? = nil
    ) {
        confirmationTimers.removeValue(forKey: target)?.cancel()
        logger.error("Toggle \(target.rawValue, privacy: .public) unconfirmed (\(reason, privacy: .public)), source \(source ?? "none", privacy: .public), request \(toggle.requestId, privacy: .public)")
        startUnconfirmedFeedback(for: target, toggle)
    }

    private func startUnconfirmedFeedback(for target: ToggleTarget, _ toggle: PendingToggleTracker.Pending) {
        unconfirmed?.end.cancel()
        let end = schedule(.unconfirmedFeedback, feedbackDuration) { [weak self] in
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
