import XCTest

private final class ManualTimer: ToggleTimer {
    let kind: ToggleTimerKind
    let work: () -> Void
    private(set) var isCancelled = false

    init(kind: ToggleTimerKind, work: @escaping () -> Void) {
        self.kind = kind
        self.work = work
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else { return }
        work()
    }
}

final class MuteStateCoordinatorTests: XCTestCase {
    private var sent: [(message: [String: Any], helper: ClientID)] = []
    private var timers: [ManualTimer] = []
    private var events: [String] = []
    private var coordinator: MuteStateCoordinator!

    override func setUp() {
        super.setUp()
        var requestNumber = 0
        coordinator = MuteStateCoordinator(
            confirmationTimeouts: ConfirmationTimeouts(mic: 3, camera: 4),
            feedbackDuration: 3,
            send: { [unowned self] message, helper, completion in
                self.sent.append((message, helper))
                completion(.success(()))
            },
            schedule: { [unowned self] kind, _, work in
                let timer = ManualTimer(kind: kind, work: work)
                self.timers.append(timer)
                return timer
            },
            makeRequestId: {
                requestNumber += 1
                return "r\(requestNumber)"
            }
        )
        coordinator.onDisplayedStateChange = { [unowned self] target, state in
            self.events.append("\(target.rawValue) muted=\(state.isMuted) cameraOff=\(state.isCameraOff)")
        }
        coordinator.onUnconfirmedFeedbackStart = { [unowned self] target in
            self.events.append("amber \(target.rawValue)")
        }
        coordinator.onUnconfirmedFeedbackEnd = { [unowned self] state in
            self.events.append("amber end muted=\(state.isMuted)")
        }
    }

    // MARK: - Connecting

    func testAsksOnlyTheNewHelperForItsState() {
        coordinator.helperConnected(1)
        sent.removeAll()

        coordinator.helperConnected(2)

        XCTAssertEqual(sent.map(\.helper), [2, 2])
        XCTAssertEqual(sent.compactMap { $0.message["type"] as? String }, ["get_state", "get_camera_state"])
    }

    // MARK: - A single helper behaves as before

    func testASingleHelperDrivesTheIndicatorAndReceivesToggles() {
        coordinator.helperConnected(1)

        coordinator.handle(["type": "state_update", "muted": true], from: 1)
        coordinator.handle(["type": "camera_state_update", "active": false], from: 1)
        coordinator.toggle(.mic)

        XCTAssertEqual(coordinator.displayed, DisplayedMuteState(isMuted: true, isCameraOff: true))
        XCTAssertEqual(lastToggle()?.helper, 1)
        XCTAssertEqual(lastToggle()?.message["type"] as? String, "toggle")
    }

    func testAToggleWithoutHelpersShowsTheWarning() {
        coordinator.toggle(.mic)

        XCTAssertEqual(events, ["amber mic"])
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Routing

    func testWithoutCallStatusTogglesGoToTheMostRecentlyActiveHelper() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)

        coordinator.handle(["type": "state_update", "muted": true], from: 1)
        coordinator.toggle(.mic)

        XCTAssertEqual(lastToggle()?.helper, 1)
    }

    func testTogglesGoToTheHelperThatJoinedTheCallLast() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 2)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)

        coordinator.toggle(.mic)

        XCTAssertEqual(lastToggle()?.helper, 1)
    }

    func testMessagesThatAreNotStateChangesDoNotMoveTheSelection() {
        connectWithMic(1, muted: false)
        coordinator.handle(["type": "state_update", "muted": true], from: 1)
        connectWithMic(2, muted: false)

        coordinator.handle(["type": "unknown"], from: 2)
        coordinator.handle(["type": "state_update", "muted": "yes"], from: 2)
        coordinator.handle(["type": "call_status", "inCall": "yes"], from: 2)
        coordinator.handle(["type": "state_update", "muted": false], from: 2)
        coordinator.toggle(.mic)

        XCTAssertEqual(lastToggle()?.helper, 1)
    }

    // MARK: - Indicator

    func testANonSelectedHelperDoesNotDriveTheIndicator() {
        connectWithMic(1, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)
        connectWithMic(2, muted: false)

        coordinator.handle(["type": "state_update", "muted": true], from: 2)

        XCTAssertFalse(coordinator.displayed.isMuted)
    }

    func testTheIndicatorFollowsTheSelectionWhenItChanges() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)
        coordinator.handle(["type": "state_update", "muted": true], from: 2)
        XCTAssertFalse(coordinator.displayed.isMuted)

        coordinator.handle(["type": "call_status", "inCall": true], from: 2)

        XCTAssertTrue(coordinator.displayed.isMuted)
    }

    func testAConfirmedToggleForAHelperNoLongerSelectedDoesNotMoveTheIndicator() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)
        coordinator.toggle(.mic)

        coordinator.handle(["type": "call_status", "inCall": true], from: 2)
        coordinator.handle(toggleResult(.mic, "r1", ok: true, newState: true), from: 1)

        XCTAssertFalse(coordinator.displayed.isMuted)
    }

    // MARK: - Unknown state never shows

    func testASelectedHelperWithoutStateShowsNothingActive() {
        connectWithMic(1, muted: true)
        coordinator.helperConnected(2)

        coordinator.handle(["type": "call_status", "inCall": true], from: 2)

        XCTAssertEqual(coordinator.displayed, DisplayedMuteState(isMuted: false, isCameraOff: false))
    }

    func testATargetWithoutStateInTheSelectedHelperShowsNotActive() {
        connectWithMic(1, muted: true)
        coordinator.handle(["type": "camera_state_update", "active": false], from: 1)
        connectWithMic(2, muted: true)

        coordinator.handle(["type": "call_status", "inCall": true], from: 2)

        XCTAssertEqual(coordinator.displayed, DisplayedMuteState(isMuted: true, isCameraOff: false))
    }

    func testShowsNothingActiveOnceEveryHelperHasDisconnected() {
        connectWithMic(1, muted: true)
        coordinator.handle(["type": "camera_state_update", "active": false], from: 1)

        coordinator.helperDisconnected(1)

        XCTAssertEqual(coordinator.displayed, DisplayedMuteState(isMuted: false, isCameraOff: false))
    }

    func testAToggleResultConfirmsAToggleWithoutBaselineWhateverItsState() {
        coordinator.helperConnected(1)
        coordinator.toggle(.mic)

        coordinator.handle(toggleResult(.mic, "r1", ok: true, newState: false), from: 1)

        XCTAssertTrue(confirmationTimer().isCancelled)
        XCTAssertFalse(events.contains("amber mic"))
    }

    func testTheRecipientsFirstStateConfirmsAToggleWithoutBaselineWhateverItsValue() {
        coordinator.helperConnected(1)
        coordinator.toggle(.camera)

        coordinator.handle(["type": "camera_state_update", "active": true], from: 1)

        XCTAssertTrue(confirmationTimer().isCancelled)
        XCTAssertFalse(events.contains("amber camera"))
    }

    func testALateStateEndsTheWarningOfAToggleWithoutBaseline() {
        coordinator.helperConnected(1)
        coordinator.toggle(.mic)
        confirmationTimer().fire()

        coordinator.handle(["type": "state_update", "muted": false], from: 1)

        XCTAssertEqual(events.last, "amber end muted=false")
    }

    // MARK: - Confirmation only from the recipient

    func testAStateChangeFromAnotherHelperDoesNotConfirmTheToggle() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)
        coordinator.toggle(.mic)

        coordinator.handle(["type": "state_update", "muted": true], from: 2)
        confirmationTimer().fire()

        XCTAssertEqual(events.last, "amber mic")
    }

    func testAToggleResultFromAnotherHelperIsIgnored() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)
        coordinator.toggle(.mic)

        coordinator.handle(toggleResult(.mic, "r1", ok: false, reason: "no_meet_tab"), from: 2)

        XCTAssertFalse(events.contains("amber mic"))
        XCTAssertFalse(confirmationTimer().isCancelled)
    }

    func testTheRecipientsStateChangeConfirmsTheToggle() {
        connectWithMic(1, muted: false)
        coordinator.toggle(.mic)

        coordinator.handle(["type": "state_update", "muted": true], from: 1)

        XCTAssertTrue(confirmationTimer().isCancelled)
        XCTAssertTrue(coordinator.displayed.isMuted)
    }

    func testAConfirmedToggleCountsAsActivity() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: false)
        coordinator.handle(["type": "call_status", "inCall": true], from: 1)
        coordinator.toggle(.mic)
        coordinator.handle(["type": "state_update", "muted": true], from: 2)

        coordinator.handle(toggleResult(.mic, "r1", ok: true, newState: true), from: 1)
        coordinator.handle(["type": "call_status", "inCall": false], from: 1)
        coordinator.toggle(.mic)

        XCTAssertEqual(lastToggle()?.helper, 1)
    }

    func testAConfirmedToggleCountsAsActivityEvenWithoutAKnownPreviousState() {
        connectWithMic(1, muted: false)
        coordinator.handle(["type": "state_update", "muted": true], from: 1)
        coordinator.helperConnected(2)
        coordinator.handle(["type": "call_status", "inCall": true], from: 2)
        coordinator.toggle(.mic)

        coordinator.handle(toggleResult(.mic, "r1", ok: true, newState: false), from: 2)
        coordinator.handle(["type": "call_status", "inCall": false], from: 2)
        coordinator.toggle(.mic)

        XCTAssertEqual(lastToggle()?.helper, 2)
    }

    // MARK: - Disconnection

    func testAPendingToggleFailsAtOnceWhenItsHelperDisconnects() {
        connectWithMic(1, muted: false)
        connectWithMic(2, muted: true)
        coordinator.handle(["type": "call_status", "inCall": true], from: 2)
        coordinator.toggle(.mic)
        events.removeAll()

        coordinator.helperDisconnected(2)

        XCTAssertEqual(events, ["mic muted=false cameraOff=false", "amber mic"])
        XCTAssertTrue(confirmationTimer().isCancelled)
    }

    // MARK: - B14

    func testTheIndicatorShowsTheConfirmedStateWhenTheWarningEnds() {
        connectWithMic(1, muted: false)
        coordinator.toggle(.mic)
        confirmationTimer().fire()

        coordinator.handle(["type": "state_update", "muted": true], from: 1)

        XCTAssertEqual(events.last, "amber end muted=true")
    }

    // MARK: - Helpers

    private func connectWithMic(_ helper: ClientID, muted: Bool) {
        coordinator.helperConnected(helper)
        coordinator.handle(["type": "state_update", "muted": muted], from: helper)
    }

    private func lastToggle() -> (message: [String: Any], helper: ClientID)? {
        sent.last { ($0.message["type"] as? String)?.hasPrefix("toggle") == true }
    }

    private func confirmationTimer() -> ManualTimer {
        timers.last { $0.kind == .confirmation }!
    }

    private func toggleResult(
        _ target: ToggleTarget, _ requestId: String, ok: Bool, newState: Bool? = nil, reason: String? = nil
    ) -> [String: Any] {
        var message: [String: Any] = ["type": "toggle_result", "target": target.rawValue, "requestId": requestId, "ok": ok]
        if let newState { message[target == .mic ? "muted" : "off"] = newState }
        if let reason { message["reason"] = reason }
        return message
    }
}
