import Foundation

/// Fans one stream of events out to any number of `AsyncStream` subscribers.
///
/// Subscribers that fall behind lose the oldest buffered events rather than
/// blocking the producer.
public actor EventBroadcaster<Element: Sendable> {
  private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
  private let bufferSize: Int

  /// Creates a broadcaster that buffers up to `bufferSize` events for each
  /// subscriber.
  public init(bufferSize: Int = 256) {
    self.bufferSize = bufferSize
  }

  /// Returns a stream of every event sent from now on.
  ///
  /// The subscription ends when the stream is dropped or `finish()` is called.
  public func subscribe() -> AsyncStream<Element> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Element>.makeStream(
      bufferingPolicy: .bufferingNewest(bufferSize)
    )
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.remove(id) }
    }
    return stream
  }

  /// Delivers an event to every current subscriber.
  public func send(_ element: Element) {
    for continuation in continuations.values {
      continuation.yield(element)
    }
  }

  /// Ends every current subscriber's stream and forgets them.
  public func finish() {
    for continuation in continuations.values {
      continuation.finish()
    }
    continuations.removeAll()
  }

  private func remove(_ id: UUID) {
    continuations[id] = nil
  }
}

/// Lets a sleeping loop be woken early. `wait(for:)` returns when signaled or
/// after the timeout on `clock`, whichever comes first.
actor AsyncSignal {
  private let clock: any AthinaClock
  private var waiter: CheckedContinuation<Void, Never>?
  private var pending = false
  private var generation = 0

  init(clock: any AthinaClock) {
    self.clock = clock
  }

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
    generation += 1
    let current = generation
    let timer = Task { [clock] in
      try? await clock.sleep(for: timeout)
      self.timeOut(generation: current)
    }
    await withCheckedContinuation { continuation in
      waiter = continuation
    }
    timer.cancel()
  }

  private func timeOut(generation: Int) {
    guard generation == self.generation, let waiter else { return }
    self.waiter = nil
    waiter.resume()
  }
}
