import Foundation

final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var pending: (item: DispatchWorkItem, action: () -> Void)?

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ action: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending?.item.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            action()
        }
        pending = (item, action)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let pending else { return }
        self.pending = nil
        pending.item.cancel()
        pending.action()
    }
}
