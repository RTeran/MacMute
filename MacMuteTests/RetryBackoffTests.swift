import XCTest

final class RetryBackoffTests: XCTestCase {
    func testDoublesTheDelayFromOneSecondUpToThirty() {
        var backoff = RetryBackoff()

        let delays = (0..<8).map { _ in backoff.nextDelay() }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testStartsOverAfterAReset() {
        var backoff = RetryBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()

        backoff.reset()

        XCTAssertEqual(backoff.nextDelay(), 1)
    }

    func testScalesForShorterDelays() {
        var backoff = RetryBackoff(first: 0.01, maximum: 0.03)

        XCTAssertEqual((0..<3).map { _ in backoff.nextDelay() }, [0.01, 0.02, 0.03])
    }
}
