import Foundation
import Testing

@testable import AthinaCore

/// The test clock: time stands still until it is advanced, and a sleep ends
/// exactly when an advance reaches its deadline.
@Suite(.timeLimit(.minutes(1)))
struct AdjustableClockTests {
  private let t0 = Date(timeIntervalSince1970: 1_789_473_600)

  @Test func timeStandsStillUntilItIsAdvanced() {
    let clock = AdjustableClock(startingAt: t0, uptime: 100)
    #expect(clock.date == t0)
    #expect(clock.uptime == 100)
    #expect(clock.rate == 0)
    clock.advance(by: .seconds(90))
    #expect(clock.date == t0 + 90)
    #expect(clock.uptime == 190)
    #expect(clock.movedAhead == .seconds(90))
  }

  /// Time the Mac slept moves the date and not the time awake, the way the
  /// system uptime stops under a closed lid.
  @Test func timeAsleepMovesTheDateAndNotTheUptime() {
    let clock = AdjustableClock(startingAt: t0)
    clock.advance(by: .seconds(3600), awake: false)
    #expect(clock.date == t0 + 3600)
    #expect(clock.uptime == 0)
    clock.advance(by: .seconds(60))
    #expect(clock.uptime == 60)
  }

  @Test func advancingToADateOnlyEverMovesForward() {
    let clock = AdjustableClock(startingAt: t0)
    clock.advance(toDate: t0 + 600)
    #expect(clock.date == t0 + 600)
    clock.advance(toDate: t0 + 30)
    #expect(clock.date == t0 + 600)
  }

  @Test func aSleepEndsExactlyWhenAnAdvanceReachesItsDeadline() async throws {
    let clock = AdjustableClock(startingAt: t0)
    let sleeping = Task { try await clock.sleep(for: .seconds(60)) }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(59))
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(1))
    try await sleeping.value
    #expect(clock.sleeperCount == 0)
    #expect(clock.date == t0 + 60)
  }

  @Test func oneAdvanceEndsEverySleepItReachesAndNoOther() async throws {
    let clock = AdjustableClock(startingAt: t0)
    let short = Task { try await clock.sleep(for: .seconds(10)) }
    let long = Task { try await clock.sleep(untilDate: t0 + 3600) }
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(600))
    try await short.value
    #expect(clock.sleeperCount == 1)
    clock.advance(toDate: t0 + 3600)
    try await long.value
  }

  @Test func aSleepUntilADateThatHasPassedReturnsAtOnce() async throws {
    let clock = AdjustableClock(startingAt: t0)
    try await clock.sleep(untilDate: t0 - 5)
    try await clock.sleep(for: .zero)
    #expect(clock.sleeperCount == 0)
  }

  /// A test's time limit cancels it, so a wait for a sleeper that never
  /// comes ends instead of hanging the run.
  @Test func aCancelledWaitForSleepersReturns() async {
    let clock = AdjustableClock(startingAt: t0)
    let waiting = Task { await clock.waitForSleepers() }
    waiting.cancel()
    await waiting.value
    let sleeping = Task { try await clock.sleep(for: .seconds(1)) }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(1))
    try? await sleeping.value
  }

  @Test func aCancelledSleepThrowsAndLeavesNothingWaiting() async {
    let clock = AdjustableClock(startingAt: t0)
    let sleeping = Task { try await clock.sleep(for: .seconds(60)) }
    await clock.waitForSleepers()
    sleeping.cancel()
    await #expect(throws: CancellationError.self) { try await sleeping.value }
    #expect(clock.sleeperCount == 0)
  }
}

/// A replay's clock: another clock's time run faster, and moved ahead on
/// demand.
///
/// Proven over a test clock, so no real time passes.
@Suite(.timeLimit(.minutes(1)))
struct ScaledClockTests {
  private let t0 = Date(timeIntervalSince1970: 1_789_473_600)

  @Test func itRunsItsBaseScaleTimesFaster() {
    let base = AdjustableClock(startingAt: t0, uptime: 500)
    let clock = AdjustableClock(running: base, scale: 60)
    #expect(clock.date == t0)
    #expect(clock.uptime == 500)
    #expect(clock.rate == 60)
    base.advance(by: .seconds(2))
    #expect(clock.date == t0 + 120)
    #expect(clock.uptime == 620)
    // Time the base slept is date and not uptime on the faster clock too.
    base.advance(by: .seconds(10), awake: false)
    #expect(clock.date == t0 + 720)
    #expect(clock.uptime == 620)
    // And it moves ahead on top.
    clock.advance(by: .seconds(3600))
    #expect(clock.date == t0 + 4320)
    #expect(clock.uptime == 4220)
  }

  @Test func aSleepOnItTakesTheScaledTimeOnItsBase() async throws {
    let base = AdjustableClock(startingAt: t0)
    let clock = AdjustableClock(running: base, scale: 60)
    let sleeping = Task { try await clock.sleep(for: .seconds(120)) }
    await base.waitForSleepers()
    base.advance(by: .milliseconds(1999))
    #expect(base.sleeperCount == 1)
    base.advance(by: .milliseconds(1))
    try await sleeping.value
    #expect(clock.date == t0 + 120)
  }

  @Test func movingItAheadEndsASleepWithoutItsBase() async throws {
    let base = AdjustableClock(startingAt: t0)
    let clock = AdjustableClock(running: base, scale: 60)
    let sleeping = Task { try await clock.sleep(for: .seconds(900)) }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(900))
    try await sleeping.value
    #expect(base.date == t0)
  }
}

@Suite struct SystemClockTests {
  @Test func itIsRealTime() async throws {
    let clock = SystemClock()
    #expect(clock.rate == 1)
    #expect(abs(clock.date.timeIntervalSinceNow) < 1)
    #expect(abs(clock.uptime - ProcessInfo.processInfo.systemUptime) < 1)
    try await clock.sleep(for: .zero)
  }
}

/// The launch flags that set a replay's clock, and their refusal everywhere else.
@Suite struct ClockModeTests {
  private let replay = ModelClientMode.replay(
    directory: URL(fileURLWithPath: "/fixtures"),
    allowStale: false
  )

  @Test func everyLaunchIsRealTimeUnlessAReplayAsksOtherwise() {
    #expect(ClockMode(arguments: ["Athina"], clientMode: .live) == .system)
    #expect(
      ClockMode(
        arguments: ["Athina", "--record"],
        clientMode: .record(directory: URL(fileURLWithPath: "/r"))
      ) == .system
    )
    #expect(
      ClockMode(arguments: ["Athina", "--replay", "/fixtures"], clientMode: replay)
        == .replay(scale: 1, ahead: 0)
    )
    let both = ClockMode(
      arguments: ["Athina", "--replay", "/f", "--time-scale", "60", "--advance-clock", "1d12h"],
      clientMode: replay
    )
    #expect(both == .replay(scale: 60, ahead: 129_600))
    #expect(
      ClockMode(arguments: ["--time-scale", "2.5"], clientMode: replay)
        == .replay(scale: 2.5, ahead: 0)
    )
  }

  /// Live and recording runs can never use a controlled clock.
  @Test func theFlagsAreRefusedOutsideAReplay() {
    #expect(
      ClockMode(arguments: ["--time-scale", "60"], clientMode: .live)
        == .refused("--time-scale applies only to --replay")
    )
    #expect(
      ClockMode(
        arguments: ["--advance-clock", "2h"],
        clientMode: .record(directory: URL(fileURLWithPath: "/r"))
      )
        == .refused("--advance-clock applies only to --replay")
    )
    #expect(
      ClockMode(arguments: ["--time-scale", "60", "--advance-clock", "2h"], clientMode: .live)
        == .refused("--time-scale and --advance-clock apply only to --replay")
    )
    // A replay that could not start keeps the replay's journal, so its clock too.
    #expect(
      ClockMode(
        arguments: ["--time-scale", "60"],
        clientMode: .invalid("--replay needs the directory of fixtures to replay")
      )
        == .replay(scale: 60, ahead: 0)
    )
    #expect(
      ClockMode(
        arguments: ["Athina"],
        clientMode: .invalid("--record and --replay cannot be combined")
      ) == .replay(scale: 1, ahead: 0)
    )
    let (clock, control) = ClockMode.refused("x").makeClock()
    #expect(clock is SystemClock)
    #expect(control == nil)
    #expect(ClockMode.system.makeClock().control == nil)
  }

  @Test(arguments: [
    ["--time-scale"],
    ["--time-scale", "fast"],
    ["--time-scale", "0.5"],
    ["--time-scale", "101"],
    ["--time-scale", "--open"],
  ])
  func aScaleOutsideTheRangeIsRefused(arguments: [String]) {
    #expect(
      ClockMode(arguments: arguments, clientMode: replay)
        == .replay(scale: 1, ahead: 0, refusal: "--time-scale needs a number from 1 to 100")
    )
  }

  @Test(arguments: [
    ["--advance-clock"],
    ["--advance-clock", "soon"],
    ["--advance-clock", "0"],
    ["--advance-clock", "31d"],
    ["--advance-clock", "-5m"],
  ])
  func anAdvanceThatCannotBeUsedIsRefused(arguments: [String]) {
    #expect(
      ClockMode(arguments: arguments, clientMode: replay)
        == .replay(
          scale: 1,
          ahead: 0,
          refusal: "--advance-clock needs an interval such as 15m, 2h, or 1d, up to 30d"
        )
    )
  }

  /// A flag value a replay cannot use is refused, and the replay still gets a
  /// clock of its own at real time, with nothing added ahead, that the debug
  /// panel and `ClockRemote` can still move.
  @Test func aRefusedFlagInAReplayStillLeavesItAClockOfItsOwn() throws {
    let now = Date(timeIntervalSince1970: 1_789_473_600)
    let mode = ClockMode(
      arguments: ["Athina", "--replay", "/f", "--time-scale", "500", "--advance-clock", "2h"],
      clientMode: replay
    )
    #expect(mode.refusal == "--time-scale needs a number from 1 to 100")
    let base = AdjustableClock(startingAt: now)
    let (clock, control) = mode.makeClock(base: base)
    let adjustable = try #require(control)
    #expect(clock.rate == 1)

    mode.startReplay(adjustable)
    #expect(clock.date == now)
    adjustable.advance(by: .seconds(3600))
    base.advance(by: .seconds(10))
    #expect(clock.date == now + 3610)
    #expect(ClockMode.refused("x").refusal == "x")
    #expect(ClockMode.system.refusal == nil)
  }

  @Test func aReplaysClockRunsFasterAndIsTheOneThatMoves() throws {
    let base = AdjustableClock(startingAt: Date(timeIntervalSince1970: 1_789_473_600))
    let (clock, control) = ClockMode.replay(scale: 30, ahead: 0).makeClock(base: base)
    let adjustable = try #require(control)
    #expect(clock.rate == 30)
    base.advance(by: .seconds(1))
    #expect(clock.date == base.date + 29)
    adjustable.advance(by: .seconds(60))
    #expect(clock.date == base.date + 89)
  }

  /// A replay's clock starts at real time and `--advance-clock` moves it that
  /// far ahead; a mode that is not a replay is not moved at all.
  @Test func aReplaysClockStartsAtRealTimeAndAdvanceClockMovesItAhead() {
    let now = Date(timeIntervalSince1970: 1_789_473_600)
    let ahead = AdjustableClock(startingAt: now)
    ClockMode.replay(scale: 1, ahead: 3600).startReplay(ahead)
    #expect(ahead.date == now + 3600)

    let plain = AdjustableClock(startingAt: now)
    ClockMode.replay(scale: 1, ahead: 0).startReplay(plain)
    #expect(plain.date == now)

    let untouched = AdjustableClock(startingAt: now)
    ClockMode.system.startReplay(untouched)
    #expect(untouched.date == now)
  }

  @Test func aJournalsNewestTimeIsItsLatestStampAnywhere() async throws {
    let journal = try Journal.inMemory()
    #expect(try await journal.newestTimestamp() == nil)
    let t0 = Date(timeIntervalSince1970: 1_789_473_600)
    try await journal.record(Fixtures.observation(at: t0))
    try await journal.record(JournalEvent(timestamp: t0 + 10, kind: .stopped))
    #expect(try await journal.newestTimestamp() == t0 + 10)
    try await journal.storeRefreshPeriod(
      RefreshPeriod(startedAt: t0, activeUse: 30, countedAt: t0 + 40)
    )
    #expect(try await journal.newestTimestamp() == t0 + 40)
    let suggestion = try await journal.record(
      Suggestion(
        timestamp: t0 + 20,
        bundleID: nil,
        appName: "A",
        windowTitle: nil,
        category: .shortcut,
        title: "t",
        body: "b",
        explanation: "e",
        confidence: 1,
        observationID: nil,
        model: "m",
        promptVersion: 1
      )
    )
    _ = try await journal.updateFeedback(
      suggestionID: suggestion.id,
      feedback: .notNow,
      at: t0 + 90
    )
    #expect(try await journal.newestTimestamp() == t0 + 90)
  }
}

/// The launch flag that sets how long a replayed call takes, and its refusal
/// everywhere else.
@Suite struct ReplayLatencyModeTests {
  private let replay = ModelClientMode.replay(
    directory: URL(fileURLWithPath: "/fixtures"),
    allowStale: false
  )

  /// A replay waits out the recorded latency unless it is asked not to, so
  /// `make run-replay` still looks like a live session.
  @Test func aReplayAnswersAfterTheRecordedLatencyUnlessAskedOtherwise() {
    #expect(
      ReplayLatencyMode(arguments: ["Athina", "--replay", "/fixtures"], clientMode: replay)
        == ReplayLatencyMode(latency: .recorded)
    )
    #expect(
      ReplayLatencyMode(
        arguments: ["Athina", "--replay", "/f", "--replay-latency", "immediate"],
        clientMode: replay
      )
        == ReplayLatencyMode(latency: .immediate)
    )
    #expect(
      ReplayLatencyMode(
        arguments: ["--replay-latency", "recorded", "--time-scale", "60"],
        clientMode: replay
      )
        == ReplayLatencyMode(latency: .recorded)
    )
    #expect(ReplayLatencyMode(arguments: ["Athina"], clientMode: .live) == ReplayLatencyMode())
    #expect(ReplayLatencyMode().refusal == nil)
  }

  /// Nothing is replayed on a live or recording launch, so the flag there is
  /// refused rather than ignored.
  @Test func theFlagIsRefusedOutsideAReplay() {
    let refused = ReplayLatencyMode(
      latency: .recorded,
      refusal: "--replay-latency applies only to --replay"
    )
    #expect(
      ReplayLatencyMode(arguments: ["Athina", "--replay-latency", "immediate"], clientMode: .live)
        == refused
    )
    #expect(
      ReplayLatencyMode(
        arguments: ["--record", "--replay-latency", "immediate"],
        clientMode: .record(directory: URL(fileURLWithPath: "/r"))
      )
        == refused
    )
    #expect(
      ReplayLatencyMode(arguments: ["--replay-latency", "recorded"], clientMode: .live) == refused
    )
    // A replay that could not start is still offline, so it is a replay here too.
    #expect(
      ReplayLatencyMode(
        arguments: ["--replay-latency", "immediate"],
        clientMode: .invalid("--replay needs the directory of fixtures to replay")
      )
        == ReplayLatencyMode(latency: .immediate)
    )
  }

  /// A value that is neither is refused with the reason, and the replay
  /// keeps the recorded latency.
  @Test(arguments: [
    ["--replay-latency"],
    ["--replay-latency", "fast"],
    ["--replay-latency", "Immediate"],
    ["--replay-latency", ""],
    ["--replay-latency", "--open"],
  ])
  func aValueThatIsNeitherIsRefused(arguments: [String]) {
    #expect(
      ReplayLatencyMode(arguments: arguments, clientMode: replay)
        == ReplayLatencyMode(
          latency: .recorded,
          refusal: "--replay-latency needs immediate or recorded"
        )
    )
  }
}

@Suite struct ClockIntervalTests {
  @Test(arguments: [
    ("90", 90.0),
    ("90s", 90),
    ("15m", 900),
    ("2h", 7200),
    ("1d", 86400),
    ("1h30m", 5400),
    ("1d 12h", 129_600),
    ("1.5h", 5400),
    ("2H", 7200),
    (" 45 s ", 45),
  ])
  func typedIntervalsAreRead(text: String, seconds: TimeInterval) {
    #expect(ClockInterval.seconds(from: text) == seconds)
  }

  @Test(arguments: ["", "h", "15x", "1h30", "fifteen", "1..5h", "m15"])
  func anythingElseIsNotAnInterval(text: String) {
    #expect(ClockInterval.seconds(from: text) == nil)
  }

  @Test func intervalsReadLargestUnitFirst() {
    #expect(ClockInterval.description(of: 0) == "0s")
    #expect(ClockInterval.description(of: 45) == "45s")
    #expect(ClockInterval.description(of: 900) == "15m")
    #expect(ClockInterval.description(of: 3630) == "1h 30s")
    #expect(ClockInterval.description(of: 93_600) == "1d 2h")
  }
}

/// The sensing loop's wait between turns, on the test clock: it ends at its
/// timeout, or at once when something wakes it.
@Suite(.timeLimit(.minutes(1)))
struct AsyncSignalTests {
  private let t0 = Date(timeIntervalSince1970: 1_789_473_600)

  @Test func aWaitEndsAtItsTimeoutOnTheClock() async {
    let clock = AdjustableClock(startingAt: t0)
    let signal = AsyncSignal(clock: clock)
    let waiting = Task { await signal.wait(for: .seconds(5)) }
    await clock.waitForSleepers()
    clock.advance(by: .milliseconds(4900))
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .milliseconds(100))
    await waiting.value
  }

  @Test func aSignalEndsTheWaitWithNoTimePassing() async {
    let clock = AdjustableClock(startingAt: t0)
    let signal = AsyncSignal(clock: clock)
    let waiting = Task { await signal.wait(for: .seconds(5)) }
    await clock.waitForSleepers()
    await signal.signal()
    await waiting.value
    #expect(clock.sleeperCount == 0)
    #expect(clock.date == t0)
  }
}
