import Foundation

/// Fans one stream of events out to any number of `AsyncStream` subscribers.
///
/// Subscribers that fall behind lose the oldest buffered events rather than
/// blocking the producer.
public actor EventBroadcaster<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let bufferSize: Int

    public init(bufferSize: Int = 256) {
        self.bufferSize = bufferSize
    }

    public func subscribe() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    public func send(_ element: Element) {
        for continuation in continuations.values {
            continuation.yield(element)
        }
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }

    public var subscriberCount: Int { continuations.count }
}

/// Lets a sleeping loop be woken early. `wait(for:)` returns when signaled or
/// after the timeout, whichever comes first.
actor AsyncSignal {
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending = false

    func signal() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            pending = true
        }
    }

    func wait(for timeout: Duration) async {
        if pending {
            pending = false
            return
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.signal()
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
        timer.cancel()
    }
}
