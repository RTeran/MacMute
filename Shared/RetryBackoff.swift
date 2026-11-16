import Foundation

struct RetryBackoff {
    private let first: TimeInterval
    private let maximum: TimeInterval
    private var next: TimeInterval

    init(first: TimeInterval = 1, maximum: TimeInterval = 30) {
        self.first = first
        self.maximum = maximum
        next = first
    }

    mutating func nextDelay() -> TimeInterval {
        let delay = next
        next = min(next * 2, maximum)
        return delay
    }

    mutating func reset() {
        next = first
    }
}
