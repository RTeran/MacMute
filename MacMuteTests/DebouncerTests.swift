import XCTest

final class DebouncerTests: XCTestCase {
    private let queue = DispatchQueue(label: "DebouncerTests")

    func testRunsOnlyTheLastActionOfABurst() {
        let debouncer = Debouncer(delay: 0.05, queue: queue)
        let ran = expectation(description: "last action runs")
        var values: [Int] = []

        for value in 1...5 {
            debouncer.schedule {
                values.append(value)
                if value == 5 { ran.fulfill() }
            }
        }

        wait(for: [ran], timeout: 2)
        queue.sync {}
        XCTAssertEqual(values, [5])
    }

    func testFlushRunsThePendingActionOnceAndRightAway() {
        let debouncer = Debouncer(delay: 0.2, queue: queue)
        var runs = 0
        debouncer.schedule { runs += 1 }

        debouncer.flush()
        XCTAssertEqual(runs, 1)

        let waited = expectation(description: "delay elapsed")
        queue.asyncAfter(deadline: .now() + 0.4) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(runs, 1)
    }

    func testFlushDoesNothingWithoutAPendingAction() {
        let debouncer = Debouncer(delay: 0.05, queue: queue)
        var runs = 0
        debouncer.schedule { runs += 1 }
        debouncer.flush()

        debouncer.flush()

        XCTAssertEqual(runs, 1)
    }
}
