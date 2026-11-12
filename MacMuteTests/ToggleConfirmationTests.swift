import XCTest

private final class FakeTimer: ToggleTimer {
    let delay: TimeInterval
    let work: () -> Void
    private(set) var isCancelled = false

    init(delay: TimeInterval, work: @escaping () -> Void) {
        self.delay = delay
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
    var sendSucceeds = true
    private(set) var sentRequests: [(target: ToggleTarget, requestId: String)] = []
    private(set) var timers: [FakeTimer] = []
    private(set) var feedbackStarts: [ToggleTarget] = []
    private(set) var feedbackEnds = 0
    private var nextRequestNumber = 0

    lazy var confirmation: ToggleConfirmation = {
        let confirmation = ToggleConfirmation(
            confirmationTimeout: 2.5,
            feedbackDuration: 3,
            confirmedState: { [unowned self] target in
                target == .mic ? self.confirmedMuted : self.confirmedCameraOff
            },
            send: { [unowned self] target, requestId, completion in
                self.sentRequests.append((target, requestId))
                completion(self.sendSucceeds)
            },
            schedule: { [unowned self] delay, work in
                let timer = FakeTimer(delay: delay, work: work)
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
        timers.filter { $0.delay == 2.5 }[index]
    }

    func feedbackTimer() -> FakeTimer? {
        timers.last { $0.delay == 3 }
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

        harness.confirmation.handleToggleResult(.mic, requestId: "r1", ok: true, newState: true, reason: nil)
        harness.confirmationTimer().fire()

        XCTAssertTrue(harness.confirmationTimer().isCancelled)
        XCTAssertTrue(harness.feedbackStarts.isEmpty)
        XCTAssertNil(harness.confirmation.pendingToggles.pending[.mic])
    }

    func testStaleRequestIdIsIgnored() {
        harness.confirmation.toggle(.mic)

        harness.confirmation.handleToggleResult(.mic, requestId: "old", ok: false, newState: nil, reason: "timeout")
        harness.confirmation.handleToggleResult(.mic, requestId: "old", ok: true, newState: true, reason: nil)

        XCTAssertTrue(harness.feedbackStarts.isEmpty)
        XCTAssertEqual(harness.confirmation.pendingToggles.pending[.mic]?.requestId, "r1")
        XCTAssertFalse(harness.confirmationTimer().isCancelled)
    }

    func testResultWithoutRequestIdDoesNotResolveThePendingToggle() {
        harness.confirmation.toggle(.mic)

        harness.confirmation.handleToggleResult(.mic, requestId: nil, ok: false, newState: nil, reason: "timeout")

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

        harness.confirmation.handleToggleResult(.mic, requestId: "r1", ok: false, newState: nil, reason: "no_meet_tab")

        XCTAssertEqual(harness.feedbackStarts, [.mic])
        XCTAssertTrue(harness.confirmationTimer().isCancelled)
    }

    func testSendWithoutClientShowsUnconfirmedFeedback() {
        harness.sendSucceeds = false

        harness.confirmation.toggle(.mic)

        XCTAssertEqual(harness.feedbackStarts, [.mic])
        XCTAssertTrue(harness.confirmationTimer().isCancelled)
    }

    func testFeedbackEndsAfterItsDuration() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.feedbackTimer()?.fire()

        XCTAssertEqual(harness.feedbackEnds, 1)
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
    }

    func testLateSuccessAfterTimeoutClearsTheFeedback() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.confirmation.handleToggleResult(.mic, requestId: "r1", ok: true, newState: true, reason: nil)

        XCTAssertEqual(harness.feedbackEnds, 1)
        XCTAssertFalse(harness.confirmation.isShowingUnconfirmedFeedback)
        XCTAssertTrue(harness.feedbackTimer()?.isCancelled ?? false)
    }

    func testLatePassiveUpdateReachingTheExpectedStateClearsTheFeedback() {
        harness.confirmation.toggle(.mic)
        harness.confirmationTimer().fire()

        harness.confirmation.handlePassiveUpdate(.mic, newState: true)

        XCTAssertEqual(harness.feedbackEnds, 1)
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
        harness.confirmation.handleToggleResult(.mic, requestId: "r2", ok: false, newState: nil, reason: "busy")

        harness.confirmation.handleToggleResult(.mic, requestId: "r1", ok: true, newState: true, reason: nil)

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
