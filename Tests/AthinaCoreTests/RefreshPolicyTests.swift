import Foundation
import Testing

@testable import AthinaCore

/// `MentorScheduler.refreshGate` under every condition that can hold it: the
/// single decision for whether the understanding needs a call of its own.
@Suite struct RefreshPolicyTests {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private var settings: MentorSettings {
    var s = MentorSettings()
    s.understandingRefreshInterval = 900
    return s
  }

  private func conditions(
    mode: SensingMode = .watching,
    key: Bool = true,
    inFlight: Bool = false,
    spend: Double = 0,
    multiplier: Double = 1
  ) -> MentorScheduler.Conditions {
    MentorScheduler.Conditions(
      mode: mode,
      hasAPIKey: key,
      callInFlight: inFlight,
      spendFraction: spend,
      cadenceMultiplier: multiplier,
      nextHourStart: t0 + 3600
    )
  }

  /// A period that began at `t0` with the user active ever since, and
  /// activity a second ago: due 901 seconds in.
  private func gate(
    _ scheduler: MentorScheduler,
    conditions: MentorScheduler.Conditions,
    context: ContextPlacement? = .notEnforced,
    period: RefreshPeriod? = nil,
    lastActivityAt: Date? = nil,
    now: Date? = nil
  ) -> MentorScheduler.RefreshGate {
    let moment = now ?? t0.addingTimeInterval(901)
    return scheduler.refreshGate(
      conditions: conditions,
      context: context,
      period: period ?? RefreshPeriod(startedAt: t0),
      lastActivityAt: lastActivityAt ?? moment.addingTimeInterval(-1),
      now: moment
    )
  }

  // MARK: Runs

  @Test func runsAfterARefreshIntervalOfActiveUse() {
    let scheduler = MentorScheduler(settings: settings)
    #expect(gate(scheduler, conditions: conditions()) == .run(since: t0))
  }

  @Test func runsAgainAnIntervalAfterTheLastRefresh() {
    let scheduler = MentorScheduler(settings: settings)
    let lastRefresh = t0.addingTimeInterval(901)
    let now = lastRefresh.addingTimeInterval(901)
    #expect(
      gate(
        scheduler,
        conditions: conditions(),
        period: RefreshPeriod(startedAt: lastRefresh),
        lastActivityAt: now.addingTimeInterval(-1),
        now: now
      ) == .run(since: lastRefresh)
    )
  }

  // MARK: Not due

  @Test func holdsUntilTheWholeIntervalHasPassed() {
    let scheduler = MentorScheduler(settings: settings)
    let now = t0.addingTimeInterval(899)
    #expect(
      gate(scheduler, conditions: conditions(), now: now)
        == .hold(.notDue(until: t0.addingTimeInterval(900)))
    )
  }

  @Test func theFirstObservationOfASessionNeverBuysACallOfItsOwn() {
    let scheduler = MentorScheduler(settings: settings)
    // The period starts with that first observation, so nothing is due yet.
    #expect(
      gate(
        scheduler,
        conditions: conditions(),
        period: RefreshPeriod(startedAt: t0),
        lastActivityAt: t0,
        now: t0
      ) == .hold(.notDue(until: t0.addingTimeInterval(900)))
    )
  }

  @Test func aMentorCallThatJustRefreshedLeavesNothingToDo() {
    let scheduler = MentorScheduler(settings: settings)
    let refreshed = t0.addingTimeInterval(890)
    let now = t0.addingTimeInterval(901)
    #expect(
      gate(
        scheduler,
        conditions: conditions(),
        period: RefreshPeriod(startedAt: refreshed),
        lastActivityAt: now,
        now: now
      ) == .hold(.notDue(until: refreshed.addingTimeInterval(900)))
    )
  }

  /// A failed or empty refresh must not be retried on the next observation:
  /// the attempt itself starts the count over, as the other tiers do, while
  /// the screens the next attempt reads still reach back to the period's start.
  @Test func aRefreshAttemptStartsTheCountOverWhateverCameOfIt() {
    let scheduler = MentorScheduler(settings: settings)
    let attempt = t0.addingTimeInterval(901)
    let restarted = RefreshPeriod(startedAt: t0).counted(
      through: attempt,
      awake: 901,
      in: .watching
    ).restarted(at: attempt)
    #expect(restarted == RefreshPeriod(startedAt: t0, activeUse: 0, countedAt: attempt))
    // The period is as old as before, but the attempt was just made.
    #expect(
      gate(
        scheduler,
        conditions: conditions(),
        period: restarted,
        now: attempt.addingTimeInterval(1)
      )
        == .hold(.notDue(until: attempt.addingTimeInterval(900)))
    )
    #expect(
      scheduler.nextRefreshAllowed(after: restarted, mode: .watching, multiplier: 1)
        == attempt.addingTimeInterval(900)
    )
    #expect(
      gate(
        scheduler,
        conditions: conditions(),
        period: restarted,
        now: attempt.addingTimeInterval(900)
      )
        == .run(since: t0)
    )
  }

  @Test func spendSlowingStretchesTheIntervalLikeTheOtherTiers() {
    let scheduler = MentorScheduler(settings: settings)
    let now = t0.addingTimeInterval(901)
    let period = RefreshPeriod(startedAt: t0)
    #expect(
      gate(scheduler, conditions: conditions(multiplier: 2), now: now)
        == .hold(.notDue(until: t0.addingTimeInterval(1800)))
    )
    #expect(
      scheduler.nextRefreshAllowed(after: period, mode: .watching, multiplier: 2)
        == t0.addingTimeInterval(1800)
    )
    // A multiplier below one never speeds the cadence up.
    #expect(
      scheduler.nextRefreshAllowed(after: period, mode: .watching, multiplier: 0.5)
        == t0.addingTimeInterval(900)
    )
  }

  // MARK: Active use

  /// The record is written at 10:00, the user works until 10:05, goes to
  /// lunch, and is back at 11:00. The hour away is not use, so the first
  /// observation after lunch buys nothing and the refresh comes due at
  /// 11:10, after ten more minutes of work.
  @Test func aLunchBreakDoesNotCountTowardTheInterval() {
    let scheduler = MentorScheduler(settings: settings)
    let written = t0
    let lunch = written.addingTimeInterval(300)
    let back = written.addingTimeInterval(3600)
    // The loop counts at each mode change: into idle at lunch, out of it on return.
    let period = RefreshPeriod(startedAt: written)
      .counted(through: lunch, awake: 300, in: .watching)
      .counted(through: back, awake: 3300, in: .idle)
    #expect(period.activeUse == 300)
    #expect(period.countedAt == back)

    let due = back.addingTimeInterval(600)
    #expect(
      gate(scheduler, conditions: conditions(), period: period, lastActivityAt: back, now: back)
        == .hold(.notDue(until: due))
    )
    #expect(scheduler.nextRefreshAllowed(after: period, mode: .watching, multiplier: 1) == due)
    let almost = due.addingTimeInterval(-1)
    #expect(
      gate(scheduler, conditions: conditions(), period: period, lastActivityAt: almost, now: almost)
        == .hold(.notDue(until: due))
    )
    #expect(
      gate(scheduler, conditions: conditions(), period: period, lastActivityAt: due, now: due)
        == .run(since: written)
    )
  }

  /// The same lunch with the lid closed at 10:05:20, before the mode could go
  /// idle, and opened at 11:00. The mode never left one that captures the
  /// screen, but the Mac slept, so only the twenty seconds before the lid
  /// closed and the five after it opened count, not the hour between.
  @Test func aLunchWithTheLidClosedDoesNotCountTheSleep() {
    let scheduler = MentorScheduler(settings: settings)
    let written = t0
    let lastCount = written.addingTimeInterval(300)
    let back = written.addingTimeInterval(3600)
    let period = RefreshPeriod(startedAt: written)
      .counted(through: lastCount, awake: 300, in: .watching)
      .counted(through: back, awake: 25, in: .watching)
    #expect(period.activeUse == 325)
    #expect(period.countedAt == back)

    let due = back.addingTimeInterval(575)
    #expect(
      gate(scheduler, conditions: conditions(), period: period, lastActivityAt: back, now: back)
        == .hold(.notDue(until: due))
    )
    #expect(
      gate(scheduler, conditions: conditions(), period: period, lastActivityAt: due, now: due)
        == .run(since: written)
    )
  }

  /// Only the smaller of the wall-clock gap and the time awake counts, and
  /// nothing at all before the loop has a clock reading to measure from, as
  /// right after a launch; the count still moves on to `now` either way.
  @Test func onlyTheSmallerOfTheWallClockAndTheTimeAwakeCounts() {
    let period = RefreshPeriod(startedAt: t0, activeUse: 60, countedAt: t0.addingTimeInterval(60))
    let now = t0.addingTimeInterval(120)
    #expect(period.counted(through: now, awake: 45, in: .watching).activeUse == 105)
    #expect(period.counted(through: now, awake: 600, in: .watching).activeUse == 120)
    let unmeasured = period.counted(through: now, awake: nil, in: .watching)
    #expect(unmeasured.activeUse == 60)
    #expect(unmeasured.countedAt == now)
  }

  /// Only a mode that captures the screen counts. The time a closed app
  /// spends stopped counts for nothing too, so a relaunch neither restarts
  /// the count nor adds the time it was closed.
  @Test(arguments: SensingMode.allCases)
  func onlyTimeInAModeThatCapturesTheScreenCounts(mode: SensingMode) {
    let period = RefreshPeriod(startedAt: t0, activeUse: 120, countedAt: t0.addingTimeInterval(120))
    let counted = period.counted(through: t0.addingTimeInterval(180), awake: 60, in: mode)
    let counts = mode == .watching || mode == .screenOnly
    #expect(counted.activeUse == (counts ? 180 : 120))
    #expect(counted.countedAt == t0.addingTimeInterval(180))
    #expect(counted.startedAt == t0)
  }

  @Test func countingIsIdempotentAndNeverRunsBackwards() {
    let period = RefreshPeriod(startedAt: t0, activeUse: 60, countedAt: t0.addingTimeInterval(60))
    let once = period.counted(through: t0.addingTimeInterval(90), awake: 30, in: .watching)
    #expect(once.counted(through: t0.addingTimeInterval(90), awake: 0, in: .watching) == once)
    #expect(once.counted(through: t0.addingTimeInterval(30), awake: 5, in: .watching) == once)
  }

  /// While nothing counts, nothing comes due, so no countdown is shown.
  @Test func thereIsNoNextRefreshWhileTheModeCountsNoUse() {
    let scheduler = MentorScheduler(settings: settings)
    let period = RefreshPeriod(startedAt: t0, activeUse: 300, countedAt: t0.addingTimeInterval(300))
    for mode in SensingMode.allCases {
      let next = scheduler.nextRefreshAllowed(after: period, mode: mode, multiplier: 1)
      #expect(next == (mode.capturesFrames ? t0.addingTimeInterval(900) : nil))
    }
    #expect(scheduler.nextRefreshAllowed(after: nil, mode: .watching, multiplier: 1) == nil)
  }

  // MARK: No new activity

  @Test func holdsWhenNothingHasEverBeenObserved() {
    let scheduler = MentorScheduler(settings: settings)
    #expect(
      scheduler.refreshGate(
        conditions: conditions(),
        context: .notEnforced,
        period: RefreshPeriod(startedAt: t0),
        lastActivityAt: nil,
        now: t0.addingTimeInterval(901)
      ) == .hold(.noNewActivity)
    )
  }

  @Test func holdsBeforeAnyActivityHasStartedAPeriod() {
    let scheduler = MentorScheduler(settings: settings)
    #expect(
      scheduler.refreshGate(
        conditions: conditions(),
        context: .notEnforced,
        period: nil,
        lastActivityAt: nil,
        now: t0
      ) == .hold(.noNewActivity)
    )
  }

  /// Activity with no period behind it (the record just expired, say) never
  /// buys a call: the period has to start first and run its whole interval.
  @Test func holdsWhenActivityHasNoPeriodBehindIt() {
    let scheduler = MentorScheduler(settings: settings)
    let now = t0.addingTimeInterval(901)
    #expect(
      scheduler.refreshGate(
        conditions: conditions(),
        context: .notEnforced,
        period: nil,
        lastActivityAt: now,
        now: now
      ) == .hold(.noNewActivity)
    )
  }

  // MARK: Availability

  @Test func neverRefreshesWhileTheLoopIsUnavailable() {
    let scheduler = MentorScheduler(settings: settings)
    let cases: [(SensingMode, MentorScheduler.Hold)] = [
      (.paused, .paused),
      (.idle, .idle),
      (.excluded, .excludedApp),
      (.waitingForPermissions, .waitingForPermissions),
      (.stopped, .notSensing),
    ]
    for (mode, hold) in cases {
      #expect(gate(scheduler, conditions: conditions(mode: mode)) == .hold(.unavailable(hold)))
    }
  }

  @Test func neverRefreshesWithoutAKey() {
    let scheduler = MentorScheduler(settings: settings)
    #expect(gate(scheduler, conditions: conditions(key: false)) == .hold(.unavailable(.noAPIKey)))
  }

  @Test func neverRefreshesOverTheSpendCap() {
    let scheduler = MentorScheduler(settings: settings)
    #expect(
      gate(scheduler, conditions: conditions(spend: 1))
        == .hold(.unavailable(.spendCapReached(until: t0 + 3600)))
    )
  }

  @Test func neverRefreshesWhileTheLoopIsOffInSettings() {
    var off = settings
    off.enabled = false
    #expect(
      gate(MentorScheduler(settings: off), conditions: conditions())
        == .hold(.unavailable(.disabled))
    )
  }

  @Test func neverRefreshesWhileACallIsInFlight() {
    let scheduler = MentorScheduler(settings: settings)
    #expect(gate(scheduler, conditions: conditions(inFlight: true)) == .hold(.callInFlight))
  }

  // MARK: Mentorship contexts

  private static let declared = MentorshipContext(name: "writing Swift")
  private static let inside = ContextPlacement.inside(
    ContextMatch(contextID: declared.id, name: declared.name)
  )
  private static let exclusions: [ContextExclusion] = [
    .noMatch(reason: ""),
    .noMatch(reason: "triage answered \"cooking\", which is not declared"),
    .noContextsDeclared,
  ]

  private func contextSettings(enforcing: Bool, declared: Bool = true) -> MentorSettings {
    var s = settings
    s.onlyMentorInsideContexts = enforcing
    s.contexts = declared ? [Self.declared] : []
    return s
  }

  @Test func withTheSwitchOffThePlacementNeverHoldsTheRefresh() {
    let scheduler = MentorScheduler(settings: contextSettings(enforcing: false))
    let placements: [ContextPlacement?] = [
      nil, .notEnforced, .outside(.noMatch(reason: "")), Self.inside,
    ]
    for placement in placements {
      #expect(gate(scheduler, conditions: conditions(), context: placement) == .run(since: t0))
    }
  }

  @Test func enforcingWithNoContextDeclaredHoldsTheRefreshLikeEveryTier() {
    let scheduler = MentorScheduler(settings: contextSettings(enforcing: true, declared: false))
    for placement in [nil, Self.inside] {
      #expect(
        gate(scheduler, conditions: conditions(), context: placement)
          == .hold(.unavailable(.noContextsDeclared))
      )
    }
  }

  @Test func outOfContextNeverBuysARefreshHoweverOverdueItIs() {
    let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
    for exclusion in Self.exclusions {
      #expect(
        gate(scheduler, conditions: conditions(), context: .outside(exclusion))
          == .hold(.outOfContext(exclusion))
      )
    }
  }

  /// No verdict for the frontmost app, or one reached while the switch was
  /// off, is not evidence the work is inside a context: the refresh waits
  /// for triage to place it rather than trusting the last app's verdict.
  @Test func anAppTriageHasNotPlacedYetHoldsTheRefresh() {
    let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
    for placement in [nil, ContextPlacement.notEnforced] {
      #expect(
        gate(scheduler, conditions: conditions(), context: placement) == .hold(.notPlacedInAContext)
      )
    }
  }

  @Test func insideAContextStillHasToPassEveryOtherCheck() {
    let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
    #expect(gate(scheduler, conditions: conditions(), context: Self.inside) == .run(since: t0))
    #expect(
      gate(scheduler, conditions: conditions(inFlight: true), context: Self.inside)
        == .hold(.callInFlight)
    )
    #expect(
      gate(
        scheduler,
        conditions: conditions(),
        context: Self.inside,
        now: t0.addingTimeInterval(899)
      )
        == .hold(.notDue(until: t0.addingTimeInterval(900)))
    )
    #expect(
      gate(scheduler, conditions: conditions(spend: 1), context: Self.inside)
        == .hold(.unavailable(.spendCapReached(until: t0 + 3600)))
    )
  }

  /// As at the mentor gate, the context is settled before anything about
  /// timing, so a held refresh says why in the same terms whatever else
  /// would have held it.
  @Test func theContextIsSettledBeforeTheCallInFlightAndDueChecks() {
    let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
    let outside = ContextPlacement.outside(.noMatch(reason: ""))
    #expect(
      gate(scheduler, conditions: conditions(inFlight: true), context: outside)
        == .hold(.outOfContext(.noMatch(reason: "")))
    )
    #expect(
      gate(scheduler, conditions: conditions(), context: outside, now: t0.addingTimeInterval(1))
        == .hold(.outOfContext(.noMatch(reason: "")))
    )
    #expect(
      scheduler.refreshGate(
        conditions: conditions(),
        context: nil,
        period: nil,
        lastActivityAt: nil,
        now: t0
      ) == .hold(.notPlacedInAContext)
    )
  }

  /// The top of the range is an ordinary interval like any other.
  @Test func theTopOfTheRangeIsAPlainInterval() {
    var slowest = settings
    slowest.understandingRefreshInterval = MentorSettings.refreshIntervalRange.upperBound
    let scheduler = MentorScheduler(settings: slowest)
    let top = MentorSettings.refreshIntervalRange.upperBound
    #expect(
      gate(scheduler, conditions: conditions(), now: t0.addingTimeInterval(top - 1))
        == .hold(.notDue(until: t0.addingTimeInterval(top)))
    )
    #expect(
      gate(scheduler, conditions: conditions(), now: t0.addingTimeInterval(top)) == .run(since: t0)
    )
  }

  @Test func settingsClampTheIntervalIntoItsRange() {
    var tooFast = MentorSettings()
    tooFast.understandingRefreshInterval = 5
    #expect(
      tooFast.validated().understandingRefreshInterval
        == MentorSettings.refreshIntervalRange.lowerBound
    )
    var tooSlow = MentorSettings()
    tooSlow.understandingRefreshInterval = 999_999
    #expect(
      tooSlow.validated().understandingRefreshInterval
        == MentorSettings.refreshIntervalRange.upperBound
    )
  }

  // MARK: Standing

  /// A status as the loop leaves it once the gate held a counting period as
  /// not due until `next`.
  private func heldNotDue(until next: Date) -> MentorStatus {
    MentorStatus(
      lastRefreshHold: MentorStatus.RefreshHoldRecord(at: t0, hold: .notDue(until: next)),
      nextRefreshAt: next
    )
  }

  @Test func aHoldStillInForceIsShownWithTheNextRefresh() {
    let next = t0.addingTimeInterval(600)
    let status = heldNotDue(until: next)
    for mode in SensingMode.allCases where mode.capturesFrames {
      #expect(
        status.refreshStanding(mode: mode) == .counting(next: next, hold: status.lastRefreshHold)
      )
    }
    var outside = status
    outside.lastRefreshHold = MentorStatus.RefreshHoldRecord(
      at: t0,
      hold: .outOfContext(.noMatch(reason: ""))
    )
    #expect(
      outside.refreshStanding(mode: .watching)
        == .counting(next: next, hold: outside.lastRefreshHold)
    )
  }

  /// A mode that counts no use says so, whatever the gate last held, and
  /// however much of the interval was counted before it.
  @Test func whileTheModeCountsNoUseNoRefreshIsDue() {
    var status = heldNotDue(until: t0.addingTimeInterval(600))
    for mode in SensingMode.allCases where !mode.capturesFrames {
      #expect(status.refreshStanding(mode: mode) == .notCounting(mode))
    }
    status.nextRefreshAt = nil
    #expect(status.refreshStanding(mode: .paused) == .notCounting(.paused))
  }

  /// With no count running, as after Reset Understanding, an old not-due
  /// hold is never shown.
  @Test func withNoCountRunningNothingIsHeldOrDue() {
    var status = heldNotDue(until: t0.addingTimeInterval(600))
    status.nextRefreshAt = nil
    #expect(status.refreshStanding(mode: .watching) == .notStarted)
  }

  /// Once the next refresh moves, as after a pause, a new record, or a
  /// changed interval, a not-due hold naming the old time is not in force.
  @Test func aNotDueHoldNamingAnotherTimeIsNotShown() {
    var status = heldNotDue(until: t0.addingTimeInterval(600))
    status.nextRefreshAt = t0.addingTimeInterval(745)
    #expect(
      status.refreshStanding(mode: .watching)
        == .counting(next: t0.addingTimeInterval(745), hold: nil)
    )
  }
}
