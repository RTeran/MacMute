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
        /// `nil` when the state before the press is unknown: then its own `toggle_result` confirms it
        /// whatever state it carries.
        let expected: Bool?
        /// The press whose expected state this one undoes, if it chained on one.
        let chainedOn: String?

        func acceptsResult(_ newState: Bool) -> Bool {
            expected.map { $0 == newState } ?? true
        }

        func withoutBaseline() -> Pending {
            Pending(requestId: requestId, expected: nil, chainedOn: chainedOn)
        }
    }

    private(set) var pending: [ToggleTarget: Pending] = [:]

    // A press made before the previous one is confirmed expects to undo that previous press, unless
    // it goes elsewhere: then only the confirmed state of its own recipient is a valid baseline.
    mutating func begin(
        _ target: ToggleTarget, requestId: String, confirmedState: Bool?, chainsPending: Bool = true
    ) -> Pending {
        let previous = chainsPending ? pending[target] : nil
        let baseline = previous.map(\.expected) ?? confirmedState
        let toggle = Pending(requestId: requestId, expected: baseline.map { !$0 }, chainedOn: previous?.requestId)
        pending[target] = toggle
        return toggle
    }

    mutating func resolve(_ target: ToggleTarget, requestId: String) -> Pending? {
        guard let toggle = pending[target], toggle.requestId == requestId else { return nil }
        pending[target] = nil
        return toggle
    }

    mutating func dropBaseline(_ target: ToggleTarget, requestId: String) {
        guard let toggle = pending[target], toggle.requestId == requestId else { return }
        pending[target] = toggle.withoutBaseline()
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
    // camera), rounded up by hidden-tab timer alignment (~1 s), plus the 200 ms reinjection delay
    // and the IPC round trip through the helper.
    static let standard = ConfirmationTimeouts(mic: 3.0, camera: 4.5)

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
/// Only a press's own `toggle_result` confirms it; passive state updates never do, because a late
/// update from an older press is indistinguishable from the reply to a newer one.
/// Every press stays outstanding until its own result arrives or its timeout expires, so a press
/// that a newer one chained over or replaced can still report its failure. A press that ends
/// without its own success always shows the warning, and the warning has a single slot: a newer
/// failure replaces the older one.
/// Runs on a single queue (main in the app); timers, sending and request ids are injected for tests.
final class ToggleConfirmation {
    typealias Send = (
        _ target: ToggleTarget, _ requestId: String, _ completion: @escaping (ToggleSendOutcome) -> Void
    ) -> Void
    typealias Schedule = (_ kind: ToggleTimerKind, _ delay: TimeInterval, _ work: @escaping () -> Void) -> ToggleTimer

    static let maxOutstandingPresses = 32

    var onUnconfirmedFeedbackStart: ((ToggleTarget) -> Void)?
    var onUnconfirmedFeedbackEnd: (() -> Void)?
    var onConfirmed: ((ToggleTarget, _ newState: Bool, _ recipient: ClientID?) -> Void)?

    private(set) var pendingToggles = PendingToggleTracker()
    var isShowingUnconfirmedFeedback: Bool { unconfirmed != nil }

    private struct Press {
        let target: ToggleTarget
        var toggle: PendingToggleTracker.Pending
        let sequence: Int
        let timer: ToggleTimer
        var recipient: ClientID?

        var requestId: String { toggle.requestId }
    }

    private struct Unconfirmed {
        let press: Press
        /// The press sequence when the warning started: only a press made after it can end it.
        let startedAt: Int
        let end: ToggleTimer
    }

    private let confirmationTimeouts: ConfirmationTimeouts
    private let feedbackDuration: TimeInterval
    private let confirmedState: (ToggleTarget) -> Bool?
    private let chainsPending: (ToggleTarget) -> Bool
    private let send: Send
    private let schedule: Schedule
    private let makeRequestId: () -> String
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")

    private var outstanding: [String: Press] = [:]
    private var lastSequence = 0
    private var unconfirmed: Unconfirmed?

    init(
        confirmationTimeouts: ConfirmationTimeouts,
        feedbackDuration: TimeInterval,
        confirmedState: @escaping (ToggleTarget) -> Bool?,
        chainsPending: @escaping (ToggleTarget) -> Bool = { _ in true },
        send: @escaping Send,
        schedule: @escaping Schedule = ToggleConfirmation.scheduleOnMain,
        makeRequestId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.confirmationTimeouts = confirmationTimeouts
        self.feedbackDuration = feedbackDuration
        self.confirmedState = confirmedState
        self.chainsPending = chainsPending
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
        let toggle = pendingToggles.begin(
            target, requestId: requestId,
            confirmedState: confirmedState(target), chainsPending: chainsPending(target)
        )
        lastSequence += 1
        let timer = schedule(.confirmation, confirmationTimeouts.timeout(for: target)) { [weak self] in
            self?.expire(requestId)
        }
        // Registered before sending: the send can set the recipient or fail synchronously.
        outstanding[requestId] = Press(target: target, toggle: toggle, sequence: lastSequence, timer: timer)
        dropOldestIfOverLimit()
        logger.debug("Toggle \(target.rawValue, privacy: .public) sent, request \(preview(requestId), privacy: .public), expected \(String(describing: toggle.expected), privacy: .public)")

        send(target, requestId) { [weak self] outcome in
            if case let .failed(reason) = outcome {
                self?.fail(target, requestId: requestId, reason: reason)
            }
        }
    }

    /// Records which helper a press was sent to; only that helper's results count for it.
    func setRecipient(_ helper: ClientID, for requestId: String) {
        outstanding[requestId]?.recipient = helper
    }

    /// Whether `result` answers a press of this helper that is still waiting for its result.
    func isOutstandingPress(_ result: ToggleResult, from helper: ClientID?) -> Bool {
        guard let requestId = result.requestId, let press = outstanding[requestId] else { return false }
        return press.target == result.target && press.recipient == helper
    }

    func handle(_ result: ToggleResult, from helper: ClientID?) {
        let target = result.target
        guard let requestId = result.requestId else { return handleWithoutRequestId(result, from: helper) }
        guard let press = outstanding[requestId], press.target == target, press.recipient == helper else {
            return handleUnmatched(result, requestId: requestId, from: helper)
        }

        switch result.outcome {
        case let .failed(reason):
            fail(target, requestId: requestId, reason: reason)

        case let .confirmed(newState):
            let wasPending = pendingToggles.pending[target]?.requestId == requestId
            finish(requestId)
            if !press.toggle.acceptsResult(newState) {
                unconfirm(press, reason: "unexpected_state", source: result.source)
            } else if wasPending {
                confirmed(press, newState: newState, source: result.source ?? "unknown")
            } else {
                logger.notice("\(target.rawValue, privacy: .public) request \(preview(requestId), privacy: .public) succeeded after a newer press; it does not confirm that press")
            }
        }
    }

    /// Fails every outstanding press sent to `helper`.
    func failPresses(sentTo helper: ClientID, reason: String) {
        let presses = outstanding.values.filter { $0.recipient == helper }.sorted { $0.sequence < $1.sequence }
        for press in presses {
            fail(press.target, requestId: press.requestId, reason: reason)
        }
    }

    private func handleWithoutRequestId(_ result: ToggleResult, from helper: ClientID?) {
        let target = result.target
        switch result.outcome {
        case let .failed(reason):
            logger.warning("toggle_result failure for \(target.rawValue, privacy: .public) without requestId (\(preview(reason), privacy: .public)), not matched to a pending toggle")
        case .confirmed:
            logger.notice("toggle_result for \(target.rawValue, privacy: .public) from helper \(String(describing: helper), privacy: .public) without requestId cannot be matched to a press; only its state is used")
        }
    }

    private func handleUnmatched(_ result: ToggleResult, requestId: String, from helper: ClientID?) {
        let target = result.target
        switch result.outcome {
        case let .failed(reason):
            if unconfirmed?.press.requestId == requestId {
                logger.error("Toggle \(target.rawValue, privacy: .public) already unconfirmed; real reason \(preview(reason), privacy: .public), request \(preview(requestId), privacy: .public)")
            } else {
                logger.notice("Ignoring \(target.rawValue, privacy: .public) failure (\(preview(reason), privacy: .public)) for request \(preview(requestId), privacy: .public): not an outstanding press of this helper")
            }
        case let .confirmed(newState):
            logger.notice("toggle_result for \(target.rawValue, privacy: .public) request \(preview(requestId), privacy: .public) that is not an outstanding press of this helper, source \(preview(result.source ?? "unknown"), privacy: .public)")
            endUnconfirmedFeedback(ifLateSuccessOf: requestId, target: target, reached: newState, from: helper)
        }
    }

    private func expire(_ requestId: String) {
        guard let press = outstanding[requestId] else { return }
        fail(press.target, requestId: requestId, reason: "timeout")
    }

    private func dropOldestIfOverLimit() {
        guard outstanding.count > Self.maxOutstandingPresses else { return }
        let pendingIds = Set(pendingToggles.pending.values.map(\.requestId))
        guard let oldest = outstanding.values
            .filter({ !pendingIds.contains($0.requestId) })
            .min(by: { $0.sequence < $1.sequence }) else { return }
        finish(oldest.requestId)
        logger.notice("Dropping \(oldest.target.rawValue, privacy: .public) request \(preview(oldest.requestId), privacy: .public): too many presses outstanding")
    }

    @discardableResult
    private func finish(_ requestId: String) -> Press? {
        guard let press = outstanding.removeValue(forKey: requestId) else { return nil }
        press.timer.cancel()
        _ = pendingToggles.resolve(press.target, requestId: requestId)
        return press
    }

    private func confirmed(_ press: Press, newState: Bool, source: String) {
        logger.notice("Toggle \(press.target.rawValue, privacy: .public) confirmed by \(preview(source), privacy: .public), request \(preview(press.requestId), privacy: .public)")
        onConfirmed?(press.target, newState, press.recipient)
        if let failed = unconfirmed, failed.press.target == press.target, press.sequence > failed.startedAt {
            endUnconfirmedFeedback()
        }
    }

    private func fail(_ target: ToggleTarget, requestId: String, reason: String) {
        guard let press = finish(requestId) else {
            if unconfirmed?.press.requestId == requestId {
                logger.error("Toggle \(target.rawValue, privacy: .public) already unconfirmed; real reason \(preview(reason), privacy: .public), request \(preview(requestId), privacy: .public)")
            } else {
                logger.notice("Ignoring stale \(target.rawValue, privacy: .public) failure (\(preview(reason), privacy: .public)), request \(preview(requestId), privacy: .public)")
            }
            return
        }
        unconfirm(press, reason: reason)
    }

    private func unconfirm(_ press: Press, reason: String, source: String? = nil) {
        logger.error("Toggle \(press.target.rawValue, privacy: .public) unconfirmed (\(preview(reason), privacy: .public)), source \(preview(source ?? "none"), privacy: .public), request \(preview(press.requestId), privacy: .public), helper \(String(describing: press.recipient), privacy: .public)")
        dropBaselines(chainedOn: press.requestId)
        unconfirmed?.end.cancel()
        let end = schedule(.unconfirmedFeedback, feedbackDuration) { [weak self] in
            self?.endUnconfirmedFeedback()
        }
        unconfirmed = Unconfirmed(press: press, startedAt: lastSequence, end: end)
        onUnconfirmedFeedbackStart?(press.target)
    }

    // The press did not reach the state it expected, so a press chained on it cannot know its own.
    private func dropBaselines(chainedOn requestId: String) {
        guard let next = outstanding.values.first(where: { $0.toggle.chainedOn == requestId }),
              next.toggle.expected != nil else { return }
        outstanding[next.requestId]?.toggle = next.toggle.withoutBaseline()
        pendingToggles.dropBaseline(next.target, requestId: next.requestId)
        logger.notice("\(next.target.rawValue, privacy: .public) request \(preview(next.requestId), privacy: .public) lost its baseline: the press it chained on failed")
        dropBaselines(chainedOn: next.requestId)
    }

    // A late success after the timeout still carries the real state, but only if it is the one the
    // failed press wanted.
    private func endUnconfirmedFeedback(
        ifLateSuccessOf requestId: String, target: ToggleTarget, reached newState: Bool, from helper: ClientID?
    ) {
        guard let failed = unconfirmed, failed.press.requestId == requestId, failed.press.target == target,
              failed.press.recipient == helper, failed.press.toggle.acceptsResult(newState) else { return }
        endUnconfirmedFeedback()
    }

    private func endUnconfirmedFeedback() {
        guard let failed = unconfirmed else { return }
        failed.end.cancel()
        unconfirmed = nil
        onUnconfirmedFeedbackEnd?()
    }
}
