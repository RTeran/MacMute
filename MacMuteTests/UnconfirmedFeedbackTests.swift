import XCTest

final class UnconfirmedFeedbackTests: XCTestCase {
    func testTheBorderBlinksExactlyThreeTimes() {
        let blink = UnconfirmedFeedback.blinkAnimation()

        XCTAssertEqual(blink.repeatCount, 3)
        XCTAssertTrue(blink.autoreverses)
    }

    func testTheFeedbackEndsWhenTheLastBlinkEnds() {
        let blink = UnconfirmedFeedback.blinkAnimation()
        let blinkingTime = blink.duration * 2 * Double(blink.repeatCount)

        XCTAssertEqual(UnconfirmedFeedback.duration, blinkingTime, accuracy: 0.001)
    }
}
