import Foundation
import Synchronization

/// The one source of time for everything in Athina that depends on it: the
/// dates the journal is stamped with and every gate compares, the calendar
/// rules that read them (the spend hour, a new day), the time awake that
/// counts toward a refresh, and every wait (a toast's countdown, the callout's
/// check, the sensing cadence, a replayed call's latency).
///
/// The app runs on `SystemClock`, which is real time. Tests run on an
/// `AdjustableClock` that moves only when a test advances it, so a behavior
/// that takes minutes or hours is proven in no real time at all, and a replay
/// may run on one that runs real time faster (`ClockMode`).
public protocol AthinaClock: Clock, Sendable where Duration == Swift.Duration {
  /// The wall-clock date now.
  var date: Date { get }
  /// How long the Mac has been awake, on a clock that stops while it sleeps.
  var uptime: TimeInterval { get }
  /// Seconds that pass on this clock for each real second, for readings the
  /// system takes in real time, such as the seconds since the last input:
  /// 1 on the system clock, `scale` on a scaled replay's, and 0 on a test
  /// clock, where time stands still until it is advanced.
  var rate: Double { get }
}

extension AthinaClock {
  /// Sleeps until the wall-clock `date`, returning at once when it has passed.
  public func sleep(untilDate date: Date) async throws {
    try await sleep(for: .seconds(max(0, date.timeIntervalSince(self.date))))
  }
}

/// Real time: `ContinuousClock` for waits, `Date()` for dates, and the system
/// uptime for time awake.
///
/// What the app always runs on outside a replay.
public struct SystemClock: AthinaClock {
  /// An instant of `ContinuousClock`, which keeps counting while the Mac
  /// sleeps.
  public typealias Instant = ContinuousClock.Instant

  private let continuous = ContinuousClock()

  /// Creates the real-time clock.
  public init() {}

  /// The current instant of `ContinuousClock`.
  public var now: Instant { continuous.now }
  /// The resolution of `ContinuousClock`.
  public var minimumResolution: Duration { continuous.minimumResolution }

  /// Sleeps on `ContinuousClock` until `deadline`.
  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    try await continuous.sleep(until: deadline, tolerance: tolerance)
  }

  /// The real date now.
  public var date: Date { Date() }
  /// The system uptime, which stops while the Mac sleeps.
  public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
  /// Always 1: real seconds are this clock's seconds.
  public var rate: Double { 1 }
}

/// A clock that can be moved ahead on demand.
///
/// Made with a start date and nothing else, it is the test clock: time stands
/// still until `advance(by:awake:)` moves it, and a sleep ends exactly when an
/// advance reaches its deadline. `waitForSleepers` lets a test advance only
/// once the code it drives has started waiting, so nothing depends on real
/// time passing.
///
/// Made over another clock with a scale, it runs that clock's time `scale`
/// times faster from the moment it is made, and an advance moves it ahead on
/// top. That is a replay's clock (`ClockMode`), over the system clock.
public final class AdjustableClock: AthinaClock {
  /// A point on this clock, measured from when the clock was made.
  public struct Instant: InstantProtocol {
    /// Time since the clock was made, including any time moved ahead.
    public var offset: Swift.Duration

    /// Creates the instant `offset` after the clock was made.
    public init(offset: Swift.Duration) {
      self.offset = offset
    }

    /// Returns the instant `duration` later.
    public func advanced(by duration: Swift.Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    /// Returns the time from this instant to `other`, negative when `other`
    /// is earlier.
    public func duration(to other: Instant) -> Swift.Duration {
      other.offset - offset
    }

    /// Whether `lhs` comes before `rhs`.
    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  /// The clock a scaled one runs on, captured with its concrete type.
  private struct Base: Sendable {
    /// Time on the base clock since this clock was made.
    var elapsed: @Sendable () -> Swift.Duration
    /// Time the Mac has been awake since this clock was made.
    var awake: @Sendable () -> TimeInterval
    var sleep: @Sendable (Swift.Duration) async throws -> Void
  }

  private struct State {
    /// Moved ahead on demand with the Mac awake.
    var advanced: Swift.Duration = .zero
    /// Moved ahead as if the Mac slept: the date moves, the uptime does not.
    var slept: Swift.Duration = .zero
    /// Counts advances, so a sleep that measured its wait before one knows to measure again.
    var generation = 0
    /// Numbers sleepers and the waits for them, so a cancelled one can be found.
    var nextID = 0
    var sleepers: [Int: Sleeper] = [:]
    var sleeperWaiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
  }

  private struct Sleeper {
    var deadline: Instant
    var continuation: CheckedContinuation<Void, any Error>
  }

  /// How much faster than its base this clock runs; 1 for a test clock, which has none.
  public let scale: Double
  private let startDate: Date
  private let startUptime: TimeInterval
  private let base: Base?
  private let state = Mutex(State())

  /// A test clock: it reads `date` and `uptime` until it is advanced.
  public init(startingAt date: Date, uptime: TimeInterval = 0) {
    startDate = date
    startUptime = uptime
    scale = 1
    base = nil
  }

  /// A clock that starts at the date of `base` and runs `scale` times faster than it.
  public init(running base: some AthinaClock, scale: Double) {
    precondition(scale > 0, "a scaled clock must move forward")
    let startInstant = base.now
    let baseUptime = base.uptime
    startDate = base.date
    startUptime = baseUptime
    self.scale = scale
    self.base = Base(
      elapsed: { startInstant.duration(to: base.now) },
      awake: { base.uptime - baseUptime },
      sleep: { try await base.sleep(for: $0) }
    )
  }

  // MARK: Reading

  /// The current instant: the base clock's scaled time since this clock was
  /// made, if it has a base, plus everything moved ahead.
  public var now: Instant {
    state.withLock { offset(in: $0) }
  }

  /// One nanosecond.
  public var minimumResolution: Swift.Duration { .nanoseconds(1) }

  /// The start date plus the time `now` has moved since the clock was made,
  /// including time moved ahead asleep.
  public var date: Date {
    startDate.addingTimeInterval(now.offset.timeInterval)
  }

  /// The starting uptime plus the base's scaled time awake and the time
  /// moved ahead awake; time moved ahead asleep does not count.
  public var uptime: TimeInterval {
    let advanced = state.withLock { $0.advanced }
    return startUptime + (base.map { $0.awake() * scale } ?? 0) + advanced.timeInterval
  }

  /// The scale for a clock over a base, and 0 for a test clock, which stands
  /// still until it is advanced.
  public var rate: Double { base == nil ? 0 : scale }

  /// Everything moved ahead on demand, awake or asleep.
  public var movedAhead: Swift.Duration {
    state.withLock { $0.advanced + $0.slept }
  }

  /// How many sleeps are waiting on this clock.
  public var sleeperCount: Int {
    state.withLock { $0.sleepers.count }
  }

  private func offset(in state: State) -> Instant {
    let running = base.map { $0.elapsed() * scale } ?? .zero
    return Instant(offset: running + state.advanced + state.slept)
  }

  // MARK: Moving ahead

  /// Moves the clock ahead by `duration`.
  ///
  /// With `awake` false the Mac is taken to have slept through it: the date
  /// moves and the uptime does not. Every sleep whose deadline this reaches
  /// ends.
  public func advance(by duration: Swift.Duration, awake: Bool = true) {
    precondition(duration >= .zero, "a clock only moves forward")
    let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      if awake {
        state.advanced += duration
      } else {
        state.slept += duration
      }
      state.generation += 1
      let now = offset(in: state)
      // A scaled clock's sleepers each measured a real wait that this
      // shortened, so all of them measure again; a test clock's only end.
      let ending = state.sleepers.filter { base != nil || $0.value.deadline <= now }
      for id in ending.keys { state.sleepers[id] = nil }
      return ending.values.map(\.continuation)
    }
    for continuation in woken { continuation.resume() }
  }

  /// Moves the clock ahead to `date`, awake; nothing happens when it is not ahead.
  public func advance(toDate date: Date) {
    let gap = date.timeIntervalSince(self.date)
    guard gap > 0 else { return }
    advance(by: .seconds(gap))
  }

  // MARK: Sleeping

  /// Sleeps until this clock reaches `deadline`, whether by its base running
  /// on or by an advance; `tolerance` is ignored.
  ///
  /// - Throws: `CancellationError` when the task is cancelled.
  public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
    try Task.checkCancellation()
    guard let base else {
      try await park(until: deadline, generation: nil)
      return
    }
    while true {
      let (now, generation) = state.withLock { (offset(in: $0), $0.generation) }
      guard now < deadline else { return }
      let wait = now.duration(to: deadline) / scale
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await base.sleep(wait) }
        group.addTask { try await self.park(until: deadline, generation: generation) }
        try await group.next()
        group.cancelAll()
      }
    }
  }

  /// Returns once at least `count` sleeps are waiting on this clock, so a test
  /// can advance it knowing the code it drives is already waiting.
  ///
  /// A cancelled wait returns at once, so a test's time limit ends one that
  /// would never be satisfied.
  public func waitForSleepers(_ count: Int = 1) async {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let ready = state.withLock { state -> Bool in
            if Task.isCancelled || state.sleepers.count >= count { return true }
            state.sleeperWaiters[id] = (count, continuation)
            return false
          }
          if ready { continuation.resume() }
        }
      },
      onCancel: {
        let waiter = state.withLock { $0.sleeperWaiters.removeValue(forKey: id) }
        waiter?.continuation.resume()
      }
    )
  }

  /// Waits until an advance ends it: when it reaches `deadline`, or on a
  /// scaled clock any advance at all. `generation` is the advance count the
  /// caller measured its wait at; if an advance came since, it returns at
  /// once so the caller measures again.
  private func park(until deadline: Instant, generation: Int?) async throws {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          let (outcome, satisfied) = state.withLock {
            state -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
            if Task.isCancelled { return (.failure(CancellationError()), []) }
            if let generation, generation != state.generation { return (.success(()), []) }
            if deadline <= offset(in: state) { return (.success(()), []) }
            state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            let count = state.sleepers.count
            let ready = state.sleeperWaiters.filter { $0.value.count <= count }
            for waiter in ready.keys { state.sleeperWaiters[waiter] = nil }
            return (nil, ready.values.map(\.continuation))
          }
          if let outcome { continuation.resume(with: outcome) }
          for waiter in satisfied { waiter.resume() }
        }
      },
      onCancel: {
        let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
        sleeper?.continuation.resume(throwing: CancellationError())
      }
    )
  }
}

extension Swift.Duration {
  /// The duration in seconds, as Foundation measures intervals.
  public var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18
  }
}
