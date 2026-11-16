import XCTest

final class CallRouterTests: XCTestCase {
    private var router = CallRouter()

    func testSelectsNothingWithoutHelpers() {
        XCTAssertNil(router.selected)
    }

    func testSelectsTheOnlyHelper() {
        router.connect(1)

        XCTAssertEqual(router.selected, 1)
    }

    func testSelectsTheNewestHelperWhileNoneHasActivity() {
        router.connect(1)
        router.connect(2)

        XCTAssertEqual(router.selected, 2)
    }

    func testSelectsTheHelperWithTheMostRecentStateChangeWhenNoneIsInCall() {
        router.connect(1)
        router.connect(2)
        router.recordState(.mic, true, from: 1)
        router.recordState(.mic, true, from: 2)

        router.recordState(.mic, false, from: 1)

        XCTAssertEqual(router.selected, 1)
    }

    func testANewIdleHelperDoesNotTakeTheSelectionFromAnActiveOne() {
        router.connect(1)
        router.recordState(.mic, true, from: 1)
        router.recordState(.mic, false, from: 1)

        router.connect(2)
        router.recordState(.mic, true, from: 2)

        XCTAssertEqual(router.selected, 1)
    }

    func testTheFirstReportedStateIsNotActivity() {
        router.connect(1)
        router.recordState(.mic, true, from: 1)
        router.recordState(.mic, false, from: 1)
        router.connect(2)

        router.recordState(.camera, true, from: 2)

        XCTAssertEqual(router.selected, 1)
    }

    func testPrefersAHelperWithAKnownStateWhileNoneHasActivity() {
        router.connect(1)
        router.recordState(.mic, false, from: 1)

        router.connect(2)

        XCTAssertEqual(router.selected, 1)
    }

    func testAmongHelpersWithAKnownStateAndNoActivityPrefersTheNewest() {
        router.connect(1)
        router.recordState(.mic, false, from: 1)
        router.connect(2)

        router.recordState(.camera, true, from: 2)

        XCTAssertEqual(router.selected, 2)
    }

    func testRepeatingTheStoredStateIsNotActivity() {
        router.connect(1)
        router.recordState(.mic, true, from: 1)
        router.connect(2)
        router.recordState(.mic, true, from: 2)
        router.recordState(.mic, false, from: 2)

        router.recordState(.mic, true, from: 1)

        XCTAssertEqual(router.selected, 2)
    }

    func testAConfirmedToggleIsActivityAndStoresTheState() {
        router.connect(1)
        router.connect(2)

        router.recordConfirmedToggle(.mic, true, from: 1)

        XCTAssertEqual(router.selected, 1)
        XCTAssertEqual(router.profile(1)?.muted, true)
    }

    func testAHelperInCallWinsOverOneWithMoreRecentActivity() {
        router.connect(1)
        router.connect(2)
        router.setInCall(true, for: 1)

        router.recordConfirmedToggle(.mic, true, from: 2)

        XCTAssertEqual(router.selected, 1)
    }

    func testTheHelperThatJoinedTheCallLastWins() {
        router.connect(1)
        router.connect(2)
        router.setInCall(true, for: 2)
        router.setInCall(true, for: 1)

        router.recordConfirmedToggle(.mic, true, from: 2)

        XCTAssertEqual(router.selected, 1)
    }

    func testRepeatingInCallDoesNotMoveTheJoinOrder() {
        router.connect(1)
        router.connect(2)
        router.setInCall(true, for: 1)
        router.setInCall(true, for: 2)

        router.setInCall(true, for: 1)

        XCTAssertEqual(router.selected, 2)
    }

    func testRejoiningACallCountsAsJoiningLast() {
        router.connect(1)
        router.connect(2)
        router.setInCall(true, for: 1)
        router.setInCall(true, for: 2)

        router.setInCall(false, for: 1)
        router.setInCall(true, for: 1)

        XCTAssertEqual(router.selected, 1)
    }

    func testFallsBackToTheMostRecentActivityWhenTheHelperInCallDisconnects() {
        router.connect(1)
        router.connect(2)
        router.connect(3)
        router.recordConfirmedToggle(.mic, true, from: 2)
        router.setInCall(true, for: 3)

        router.disconnect(3)

        XCTAssertEqual(router.selected, 2)
    }

    func testLeavingTheCallKeepsEachProfileStateAndSelectsTheOtherCall() {
        router.connect(1)
        router.connect(2)
        router.recordState(.mic, true, from: 1)
        router.recordState(.mic, false, from: 2)
        router.setInCall(true, for: 1)
        router.setInCall(true, for: 2)

        router.setInCall(false, for: 2)

        XCTAssertEqual(router.selected, 1)
        XCTAssertEqual(router.profile(1), CallRouter.Profile(muted: true, cameraOff: nil, inCall: true))
        XCTAssertEqual(router.profile(2), CallRouter.Profile(muted: false, cameraOff: nil, inCall: false))
    }

    func testOnlyTheHelperAToggleWasSentToIsItsRecipient() {
        router.connect(1)
        router.connect(2)

        router.toggleSent(.mic, to: 1)
        router.toggleSent(.camera, to: 2)

        XCTAssertEqual(router.toggleRecipient(for: .mic), 1)
        XCTAssertEqual(router.toggleRecipient(for: .camera), 2)
    }

    func testDisconnectingReturnsTheTargetsItWasTheToggleRecipientFor() {
        router.connect(1)
        router.connect(2)
        router.toggleSent(.mic, to: 1)
        router.toggleSent(.camera, to: 2)

        XCTAssertEqual(router.disconnect(1), [.mic])
        XCTAssertNil(router.toggleRecipient(for: .mic))
    }

    func testIgnoresHelpersItDoesNotKnow() {
        router.connect(1)
        router.recordState(.mic, true, from: 1)
        router.disconnect(1)

        router.recordState(.mic, false, from: 1)
        router.recordState(.camera, true, from: 3)
        router.recordConfirmedToggle(.mic, false, from: 1)
        router.setInCall(true, for: 1)
        router.connect(2)

        XCTAssertNil(router.profile(1))
        XCTAssertNil(router.profile(3))
        XCTAssertEqual(router.profile(2), CallRouter.Profile())
        XCTAssertEqual(router.selected, 2)
    }
}
