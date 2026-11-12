import XCTest

private final class FakeTimer: ToggleTimer {
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

private final class Harness {
    var confirmedMuted = false
    var confirmedCameraOff = false
    var sendOutcome = ToggleSendOutcome.sent
    private(set) var sentRequests: [(target: ToggleTarget, requestId: String)] = []
    private(set) var timers: [FakeTimer] = []
    private(set) var feedbackStarts: [ToggleTarget] = []
    private(set) var feedbackEnds = 0
    private var nextRequestNumber = 0

    lazy var confirmation: ToggleConfirmation = {
        let confirmation = ToggleConfirmation(
            confirmationTimeout: 3,
            feedbackDuration: 3,
            confirmedState: { [unowned self] target in
                target == .mic ? self.confirmedMuted : self.confirmedCameraOff
            },
            send: { [unowned self] target, requestId, completion in
                self.sentRequests.append((target, requestId))
                completion(self.sendOutcome)
            },
            schedule: { [unowned self] kind, _, work in
                let timer = FakeTimer(kind: kind, work: work)
                self.timers.append(timer)
                return timer
            },
            makeRequestId: { [unowned self] in
                self.nextRequestNumber += 1
                return "r\(self.nextRequestNumber)"
            }
        )
        confirmation.onUnconfirmedFeedbackStart = { [unowned self] target in
            self.feedbackStarts.append(target)
        }
        confirmation.onUnconfirmedFeedbackEnd = { [unowned self] in
            self.feedbackEnds += 1
        }
        return confirmation
    }()

    func confirmationTimer(_ index: Int = 0) -> FakeTimer {
        timers.filter { $0.kind == .confirmation }[index]
    }

    func feedbackTimer(_ index: Int = 0) -> FakeTimer {
        timers.filter { $0.kind == .unconfirmedFeedback }[index]
    }

    func confirm(_ target: ToggleTarget, _ requestId: String?, newState: Bool) {
        confirmation.handle(ToggleResult(target: target, requestId: requestId, outcome: .confirmed(newState: newState)))
    }

    func fail(_ target: ToggleTarget, _ requestId: String?, reason: String) {
        confirmation.handle(ToggleResult(target: target, requestId: requestId, outcome: .failed(reason: reason)))
    }
}

final class ToggleConfirmationTests: XCTestCase {
    private var harness: Harness!

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    func testSendsTheToggleWithARequestId() {
        harness.confirmation.toggle(.mic)

        XCTAssertEqual(harness.sentRequests.map(\.requestId), ["r1"])
        XCTAssertEqual(harness.sentRequests.map(\.target), [.mic])
    }

    func testSuccessWithMatchingRequestIdConfirmsWithoutFeedback() {
        harness.confirmation.toggle(.mic)

        harness.confirm(.mic, "r1", newState: true)
        harness.confirmationTimer().fire()

        XCTAssertTrue(harness.confirmationTimer().isCancelled)
        XCTAssertTrue(harness.feedbackStarts.isEmpty)
        XCTAssertNil(harness.confirmation.pendingToggles.pending[.mic])
    }

    func testStaleRequestIdIsIgnored() {
        harness.confirmation.toggle(.mic)

        harness.fail(.mic, "old", reason: "timeout")
        harness.confirm(.mic, "old", newState: true)

        XCTAssertTrue(harness.feedbackStarts.isEmpty)
        XCTAssertEqual(harness.confirmation.pendingToggles.pending[.mic]?.requestId, "r1")
        XCTAssertFalse(harness.confirmationTimer().isCancelled)
    }

    func testSuccessWithMatchingRequestIdButUnexpectedStateShowsFeedback() {
        harness.confirmation.toggle(.mic)

        harness.confirm(.mic, "r1", newState: false)

        XCTAssertEqual(harness.feedbackStarts, [.mic])
        XCTAssertTrue(harness.confirmationTimer().isCancelled)
        XCTAssertNil(harness.confirmation.pendingToggles.pending[.mic])
    }

    func testFirstPressFailingWhileSecondIsPendingThenSecondReachingTheWrongStateShowsFeedback() {
        harness.confirmation.toggle(.mic)
        harness.confirmation.toggle(.mic)
        harness.fail(.mic, "r1", reason: "timeout")
        XCTAssertTrue(harness.feedbackStarts.isEmpty)

        harness.confirm(.mic, "r2", newState: true)

        XCTAssertEqual(harness.feedbackStarts, [.mic])
    }

    func testSuccessWithoutRequestIdConfirmsWhenItReachesTheExpectedState() {
        harness.confirmation.toggle(.mic)

        harness.confirm(.mic, nil, newState: true)

        XCTAssertNil(harness.confirmation.pendingToggles.pending[.mic])
        XCTAssertTrue(harness.confirmationTimer().isCancelled)
        XCTAssertTrue(harness.feedbackStarts.isEmpty)
    }

    func testSuccessWithoutRequestIdAndUnexpectedStateLeavesTheToggleRunning() {
        harness.confirmation.toggle(.mic)

        harness.confirm(.mic, nil, newState: false)

        XCTAssertEqual(harness.confirmation.pendingToggles.pending[.mic]?.requestId, "r1")
        XCTAssertFalse(harness.confirmationTimer().isCancelled)
    }

    func testPassiveConfirmationCancelsTheTimeout() {
        harness.confirmation.toggle(.camera)

        harness.confirmation.handlePassiveUpdate(.camera, newState: true)
        harness.confirmationTimer().fire()

        XCTAssertTrue(harness.feedbackStarts.isEmpty)
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
    }

    func testSecondFailureKeepsTheFeedbackAfterTheFirstEndTimer() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer(0).fire()
        harness.confirmation.toggle(.camera)
        harness.confirmationTimer(1).fire()

        harness.feedbackTimer(0).fire()

        XCTAssertTrue(harness.confirmation.isShowingUnconfirmedFeedback)
        XCTAssertEqual(harness.feedbackEnds, 0)
        harness.feedbackTimer(1).fire()
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
    }

    func testResultWithoutRequestIdDoesNotResolveThePendingToggle() {
        harness.confirmation.toggle(.mic)

        harness.fail(.mic, nil, reason: "timeout")

        XCTAssertTrue(harness.feedbackStarts.isEmpty)
        XCTAssertEqual(harness.confirmation.pendingToggles.pending[.mic]?.requestId, "r1")
    }

    func testTimeoutShowsUnconfirmedFeedback() {
        harness.confirmation.toggle(.camera)

        harness.confirmationTimer().fire()

        XCTAssertEqual(harness.feedbackStarts, [.camera])
        XCTAssertTrue(harness.confirmation.isShowingUnconfirmedFeedback)
        XCTAssertNil(harness.confirmation.pendingToggles.pending[.camera])
    }

    func testFailureResultShowsUnconfirmedFeedback() {
        harness.confirmation.toggle(.mic)

        harness.fail(.mic, "r1", reason: "no_meet_tab")

        XCTAssertEqual(harness.feedbackStarts, [.mic])
        XCTAssertTrue(harness.confirmationTimer().isCancelled)
    }

    func testSendWithoutClientShowsUnconfirmedFeedback() {
        harness.sendOutcome = .failed(reason: "no_socket_client")

        harness.confirmation.toggle(.mic)

        XCTAssertEqual(harness.feedbackStarts, [.mic])
        XCTAssertTrue(harness.confirmationTimer().isCancelled)
    }

    func testFeedbackEndsAfterItsDuration() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.feedbackTimer().fire()

        XCTAssertEqual(harness.feedbackEnds, 1)
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
    }

    func testLateSuccessAfterTimeoutClearsTheFeedback() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.confirm(.mic, "r1", newState: true)

        XCTAssertEqual(harness.feedbackEnds, 1)
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
        XCTAssertTrue(harness.feedbackTimer().isCancelled)
    }

    func testLatePassiveUpdateReachingTheExpectedStateClearsTheFeedback() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.confirmation.handlePassiveUpdate(.mic, newState: true)

        XCTAssertEqual(harness.feedbackEnds, 1)
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
    }

    func testFastDoublePressPassiveUpdateConfirmsOnlyTheExpectedState() {
        harness.confirmation.toggle(.mic)
        harness.confirmation.toggle(.mic)

        harness.confirmation.handlePassiveUpdate(.mic, newState: true)
        XCTAssertEqual(harness.confirmation.pendingToggles.pending[.mic]?.requestId, "r2")

        harness.confirmation.handlePassiveUpdate(.mic, newState: false)
        XCTAssertNil(harness.confirmation.pendingToggles.pending[.mic])
        XCTAssertTrue(harness.feedbackStarts.isEmpty)
    }

    func testFastDoublePressLateSuccessOfFirstPressKeepsTheFeedbackOfTheSecond() {
        harness.confirmation.toggle(.mic)
        harness.confirmation.toggle(.mic)
        harness.fail(.mic, "r2", reason: "busy")

        harness.confirm(.mic, "r1", newState: true)

        XCTAssertEqual(harness.feedbackStarts, [.mic])
        XCTAssertEqual(harness.feedbackEnds, 0)
        XCTAssertTrue(harness.confirmation.isShowingUnconfirmedFeedback)
    }

    func testPassiveUpdateForAnotherTargetDoesNotClearTheFeedback() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.confirmation.handlePassiveUpdate(.camera, newState: true)

        XCTAssertEqual(harness.feedbackEnds, 0)
    }
}

final class PendingToggleTrackerTests: XCTestCase {
    func testBeginExpectsTheOppositeOfTheConfirmedState() {
        var tracker = PendingToggleTracker()

        let toggle = tracker.begin(.mic, requestId: "r1", confirmedState: false)

        XCTAssertTrue(toggle.expected)
    }

    func testBeginChainsExpectedStatesWhileAToggleIsPending() {
        var tracker = PendingToggleTracker()
        _ = tracker.begin(.mic, requestId: "r1", confirmedState: false)

        let second = tracker.begin(.mic, requestId: "r2", confirmedState: false)

        XCTAssertFalse(second.expected)
    }

    func testResolveRequiresTheExactRequestId() {
        var tracker = PendingToggleTracker()
        _ = tracker.begin(.camera, requestId: "r1", confirmedState: false)

        XCTAssertNil(tracker.resolve(.camera, requestId: "r0"))
        XCTAssertEqual(tracker.resolve(.camera, requestId: "r1")?.requestId, "r1")
        XCTAssertNil(tracker.pending[.camera])
    }
}

final class ToggleResultParsingTests: XCTestCase {
    func testParsesAConfirmedMicResultFromMuted() {
        let result = ToggleResult(message: ["type": "toggle_result", "target": "mic", "ok": true, "muted": true, "requestId": "r1"])

        XCTAssertEqual(result, ToggleResult(target: .mic, requestId: "r1", outcome: .confirmed(newState: true)))
    }

    func testParsesAConfirmedCameraResultFromOff() {
        let result = ToggleResult(message: ["type": "toggle_result", "target": "camera", "ok": true, "off": false])

        XCTAssertEqual(result, ToggleResult(target: .camera, requestId: nil, outcome: .confirmed(newState: false)))
    }

    func testIgnoresTheOtherTargetsStateKey() {
        let result = ToggleResult(message: ["type": "toggle_result", "target": "camera", "ok": true, "muted": true])

        XCTAssertEqual(result?.outcome, .failed(reason: "missing_state"))
    }

    func testTreatsOkWithoutStateAsMissingState() {
        let result = ToggleResult(message: ["type": "toggle_result", "target": "mic", "ok": true, "requestId": "r1"])

        XCTAssertEqual(result, ToggleResult(target: .mic, requestId: "r1", outcome: .failed(reason: "missing_state")))
    }

    func testParsesAFailureWithItsReason() {
        let result = ToggleResult(message: ["type": "toggle_result", "target": "mic", "ok": false, "reason": "no_meet_tab"])

        XCTAssertEqual(result?.outcome, .failed(reason: "no_meet_tab"))
    }

    func testUsesUnknownWhenAFailureHasNoReason() {
        let result = ToggleResult(message: ["type": "toggle_result", "target": "camera", "ok": false])

        XCTAssertEqual(result?.outcome, .failed(reason: "unknown"))
    }

    func testRejectsMalformedResults() {
        XCTAssertNil(ToggleResult(message: ["type": "toggle_result", "ok": true, "muted": true]))
        XCTAssertNil(ToggleResult(message: ["type": "toggle_result", "target": "speaker", "ok": true]))
        XCTAssertNil(ToggleResult(message: ["type": "toggle_result", "target": "mic", "muted": true]))
    }
}
