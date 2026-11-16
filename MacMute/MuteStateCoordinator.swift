import Foundation
import os

struct DisplayedMuteState: Equatable {
    var isMuted = false
    var isCameraOff = false

    subscript(target: ToggleTarget) -> Bool {
        get { target == .mic ? isMuted : isCameraOff }
        set {
            if target == .mic { isMuted = newValue } else { isCameraOff = newValue }
        }
    }
}

/// Turns helper messages and shortcut presses into the state the indicator shows. Free of AppKit
/// so it can be tested; runs on the main queue in the app.
final class MuteStateCoordinator {
    typealias Send = (
        _ message: [String: Any], _ helper: ClientID, _ completion: @escaping (Result<Void, SocketSendError>) -> Void
    ) -> Void

    var onDisplayedStateChange: ((ToggleTarget, DisplayedMuteState) -> Void)?
    var onUnconfirmedFeedbackStart: ((ToggleTarget) -> Void)?
    var onUnconfirmedFeedbackEnd: ((DisplayedMuteState) -> Void)?

    private(set) var displayed = DisplayedMuteState()
    private var router = CallRouter()
    private let send: Send
    private let logger = Logger(subsystem: "com.macmute.app", category: "toggle")
    private var toggleConfirmation: ToggleConfirmation!

    init(
        confirmationTimeouts: ConfirmationTimeouts,
        feedbackDuration: TimeInterval,
        send: @escaping Send,
        schedule: @escaping ToggleConfirmation.Schedule = ToggleConfirmation.scheduleOnMain,
        makeRequestId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.send = send
        toggleConfirmation = ToggleConfirmation(
            confirmationTimeouts: confirmationTimeouts,
            feedbackDuration: feedbackDuration,
            confirmedState: { [unowned self] target in self.router.selected.flatMap(self.router.profile)?[target] },
            send: { [unowned self] target, requestId, completion in
                self.sendToggle(target, requestId: requestId, completion: completion)
            },
            schedule: schedule,
            makeRequestId: makeRequestId
        )
        toggleConfirmation.onUnconfirmedFeedbackStart = { [unowned self] target in
            self.onUnconfirmedFeedbackStart?(target)
        }
        toggleConfirmation.onUnconfirmedFeedbackEnd = { [unowned self] in
            self.onUnconfirmedFeedbackEnd?(self.displayed)
        }
        toggleConfirmation.onConfirmed = { [unowned self] target, newState in
            guard let recipient = self.router.toggleRecipient(for: target) else {
                self.logger.fault("Confirmed a \(target.rawValue, privacy: .public) toggle that has no recipient")
                assertionFailure("Confirmed a toggle that has no recipient")
                return
            }
            self.router.recordConfirmedToggle(target, newState, from: recipient)
            // The confirmation counts as activity and can change which helper is selected.
            self.refreshDisplay()
        }
    }

    func toggle(_ target: ToggleTarget) {
        if toggleConfirmation.pendingToggles.pending[target] != nil,
           let previous = router.toggleRecipient(for: target), previous != router.selected {
            // The previous press can no longer be confirmed: only the new recipient's replies count.
            logger.notice("New \(target.rawValue, privacy: .public) press replaces one pending on helper \(previous, privacy: .public), sent to helper \(String(describing: self.router.selected), privacy: .public)")
        }
        toggleConfirmation.toggle(target)
    }

    func helperConnected(_ helper: ClientID) {
        router.connect(helper)
        logger.notice("Helper \(helper, privacy: .public) connected, requesting mic and camera state")
        send(["type": "get_state"], helper) { _ in }
        send(["type": "get_camera_state"], helper) { _ in }
    }

    func helperDisconnected(_ helper: ClientID) {
        let recipientTargets = router.disconnect(helper)
        refreshDisplay()
        for target in recipientTargets where toggleConfirmation.failPending(target, reason: "helper_disconnected") {
            logger.error("Helper \(helper, privacy: .public) disconnected with a \(target.rawValue, privacy: .public) toggle pending")
        }
    }

    func handle(_ message: [String: Any], from helper: ClientID) {
        guard let type = message["type"] as? String else {
            logger.error("Message without type from helper \(helper, privacy: .public)")
            return
        }

        switch type {
        case "state_update":
            guard let muted = message["muted"] as? Bool else { return logMalformed(message, from: helper) }
            handleState(.mic, muted, from: helper)
        case "camera_state_update":
            guard let active = message["active"] as? Bool else { return logMalformed(message, from: helper) }
            handleState(.camera, !active, from: helper)
        case "call_status":
            guard let inCall = message["inCall"] as? Bool else { return logMalformed(message, from: helper) }
            router.setInCall(inCall, for: helper)
            refreshDisplay()
        case "toggle_result":
            handleToggleResult(message, from: helper)
        default:
            logger.error("Unknown message type from helper \(helper, privacy: .public): \(preview(type), privacy: .public)")
        }
    }

    // The new state is shown before the confirmation runs: ending the amber warning redraws the
    // indicator, which must already show the state that ended it.
    private func handleState(_ target: ToggleTarget, _ state: Bool, from helper: ClientID) {
        router.recordState(target, state, from: helper)
        refreshDisplay()
        if router.isToggleRecipient(helper, for: target) {
            toggleConfirmation.handlePassiveUpdate(target, newState: state)
        }
    }

    private func handleToggleResult(_ message: [String: Any], from helper: ClientID) {
        guard let result = ToggleResult(message: message) else { return logMalformed(message, from: helper) }
        if case let .confirmed(newState) = result.outcome {
            router.recordState(result.target, newState, from: helper)
            refreshDisplay()
        }
        guard router.isToggleRecipient(helper, for: result.target) else {
            logger.notice("\(result.target.rawValue, privacy: .public) toggle_result from helper \(helper, privacy: .public) does not confirm the toggle, it was not sent to it")
            return
        }
        if result.outcome == .failed(reason: "missing_state") {
            logger.error("toggle_result ok without state: \(preview(message), privacy: .public)")
        }
        toggleConfirmation.handle(result)
    }

    private func sendToggle(
        _ target: ToggleTarget, requestId: String, completion: @escaping (ToggleSendOutcome) -> Void
    ) {
        guard let helper = router.selected else {
            return completion(.failed(reason: SocketSendError.noSocketClient.rawValue))
        }
        router.toggleSent(target, to: helper)
        send(["type": target.commandType, "requestId": requestId], helper) { result in
            switch result {
            case .success: completion(.sent)
            case let .failure(error): completion(.failed(reason: error.rawValue))
            }
        }
    }

    // An unknown state shows as not active: a false "muted" while the mic is live is the dangerous error.
    private func refreshDisplay() {
        let profile = router.selected.flatMap(router.profile) ?? CallRouter.Profile()
        for target in [ToggleTarget.mic, .camera] {
            let state = profile[target] ?? false
            guard state != displayed[target] else { continue }
            displayed[target] = state
            onDisplayedStateChange?(target, displayed)
        }
    }

    private func logMalformed(_ message: [String: Any], from helper: ClientID) {
        logger.error("Malformed message from helper \(helper, privacy: .public): \(preview(message), privacy: .public)")
    }
}
