import Foundation
import Testing
@testable import MentorCore

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
            mode: mode, hasAPIKey: key, callInFlight: inFlight, spendFraction: spend,
            cadenceMultiplier: multiplier, nextHourStart: t0 + 3600
        )
    }

    /// A period that started 901 seconds ago with activity since: due.
    private func gate(
        _ scheduler: MentorScheduler,
        conditions: MentorScheduler.Conditions,
        context: ContextPlacement? = .notEnforced,
        periodStart: Date? = nil,
        lastActivityAt: Date? = nil,
        now: Date? = nil
    ) -> MentorScheduler.RefreshGate {
        let moment = now ?? t0.addingTimeInterval(901)
        return scheduler.refreshGate(
            conditions: conditions,
            context: context,
            periodStart: periodStart ?? t0,
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
        #expect(gate(
            scheduler, conditions: conditions(), periodStart: lastRefresh,
            lastActivityAt: now.addingTimeInterval(-1), now: now
        ) == .run(since: lastRefresh))
    }

    // MARK: Not due

    @Test func holdsUntilTheWholeIntervalHasPassed() {
        let scheduler = MentorScheduler(settings: settings)
        let now = t0.addingTimeInterval(899)
        #expect(gate(scheduler, conditions: conditions(), now: now) == .hold(.notDue(until: t0.addingTimeInterval(900))))
    }

    @Test func theFirstObservationOfASessionNeverBuysACallOfItsOwn() {
        let scheduler = MentorScheduler(settings: settings)
        // The period starts with that first observation, so nothing is due yet.
        #expect(gate(
            scheduler, conditions: conditions(), periodStart: t0,
            lastActivityAt: t0, now: t0
        ) == .hold(.notDue(until: t0.addingTimeInterval(900))))
    }

    @Test func aMentorCallThatJustRefreshedLeavesNothingToDo() {
        let scheduler = MentorScheduler(settings: settings)
        let refreshed = t0.addingTimeInterval(890)
        let now = t0.addingTimeInterval(901)
        #expect(gate(
            scheduler, conditions: conditions(), periodStart: refreshed,
            lastActivityAt: now, now: now
        ) == .hold(.notDue(until: refreshed.addingTimeInterval(900))))
    }

    /// A failed or empty refresh must not be retried on the next observation:
    /// the attempt itself starts the interval over, as the other tiers do.
    @Test func aRefreshAttemptStartsTheIntervalOverWhateverCameOfIt() {
        var scheduler = MentorScheduler(settings: settings)
        let attempt = t0.addingTimeInterval(901)
        scheduler.noteRefreshStarted(now: attempt)
        // The period is as overdue as before, but the attempt was just made.
        #expect(gate(scheduler, conditions: conditions(), now: attempt.addingTimeInterval(1))
            == .hold(.notDue(until: attempt.addingTimeInterval(900))))
        #expect(scheduler.nextRefreshAllowed(after: t0, multiplier: 1) == attempt.addingTimeInterval(900))
        // A refresh that later rewrote the record moves the period past the attempt.
        let refreshed = attempt.addingTimeInterval(300)
        #expect(scheduler.nextRefreshAllowed(after: refreshed, multiplier: 1) == refreshed.addingTimeInterval(900))
        #expect(gate(scheduler, conditions: conditions(), now: attempt.addingTimeInterval(901)) == .run(since: t0))
    }

    @Test func spendSlowingStretchesTheIntervalLikeTheOtherTiers() {
        let scheduler = MentorScheduler(settings: settings)
        let now = t0.addingTimeInterval(901)
        #expect(gate(scheduler, conditions: conditions(multiplier: 2), now: now)
            == .hold(.notDue(until: t0.addingTimeInterval(1800))))
        #expect(scheduler.nextRefreshAllowed(after: t0, multiplier: 2) == t0.addingTimeInterval(1800))
        // A multiplier below one never speeds the cadence up.
        #expect(scheduler.nextRefreshAllowed(after: t0, multiplier: 0.5) == t0.addingTimeInterval(900))
    }

    // MARK: No new activity

    @Test func holdsWhenNothingHasEverBeenObserved() {
        let scheduler = MentorScheduler(settings: settings)
        #expect(scheduler.refreshGate(
            conditions: conditions(), context: .notEnforced, periodStart: t0, lastActivityAt: nil,
            now: t0.addingTimeInterval(901)
        ) == .hold(.noNewActivity))
    }

    @Test func holdsBeforeAnyActivityHasStartedAPeriod() {
        let scheduler = MentorScheduler(settings: settings)
        #expect(scheduler.refreshGate(
            conditions: conditions(), context: .notEnforced, periodStart: nil, lastActivityAt: nil, now: t0
        ) == .hold(.noNewActivity))
    }

    /// Activity with no period behind it (the record just expired, say) never
    /// buys a call: the period has to start first and run its whole interval.
    @Test func holdsWhenActivityHasNoPeriodBehindIt() {
        let scheduler = MentorScheduler(settings: settings)
        let now = t0.addingTimeInterval(901)
        #expect(scheduler.refreshGate(
            conditions: conditions(), context: .notEnforced, periodStart: nil, lastActivityAt: now, now: now
        ) == .hold(.noNewActivity))
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
        #expect(gate(scheduler, conditions: conditions(spend: 1))
            == .hold(.unavailable(.spendCapReached(until: t0 + 3600))))
    }

    @Test func neverRefreshesWhileTheLoopIsOffInSettings() {
        var off = settings
        off.enabled = false
        #expect(gate(MentorScheduler(settings: off), conditions: conditions()) == .hold(.unavailable(.disabled)))
    }

    @Test func neverRefreshesWhileACallIsInFlight() {
        let scheduler = MentorScheduler(settings: settings)
        #expect(gate(scheduler, conditions: conditions(inFlight: true)) == .hold(.callInFlight))
    }

    // MARK: Mentorship contexts

    private static let declared = MentorshipContext(name: "writing Swift")
    private static let inside = ContextPlacement.inside(ContextMatch(contextID: declared.id, name: declared.name))
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
        let placements: [ContextPlacement?] = [nil, .notEnforced, .outside(.noMatch(reason: "")), Self.inside]
        for placement in placements {
            #expect(gate(scheduler, conditions: conditions(), context: placement) == .run(since: t0))
        }
    }

    @Test func enforcingWithNoContextDeclaredHoldsTheRefreshLikeEveryTier() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true, declared: false))
        for placement in [nil, Self.inside] {
            #expect(gate(scheduler, conditions: conditions(), context: placement)
                == .hold(.unavailable(.noContextsDeclared)))
        }
    }

    @Test func outOfContextNeverBuysARefreshHoweverOverdueItIs() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        for exclusion in Self.exclusions {
            #expect(gate(scheduler, conditions: conditions(), context: .outside(exclusion))
                == .hold(.outOfContext(exclusion)))
        }
    }

    /// No verdict for the frontmost app, or one reached while the switch was
    /// off, is not evidence the work is inside a context: the refresh waits
    /// for triage to place it rather than trusting the last app's verdict.
    @Test func anAppTriageHasNotPlacedYetHoldsTheRefresh() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        for placement in [nil, ContextPlacement.notEnforced] {
            #expect(gate(scheduler, conditions: conditions(), context: placement) == .hold(.notPlacedInAContext))
        }
    }

    @Test func insideAContextStillHasToPassEveryOtherCheck() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        #expect(gate(scheduler, conditions: conditions(), context: Self.inside) == .run(since: t0))
        #expect(gate(scheduler, conditions: conditions(inFlight: true), context: Self.inside) == .hold(.callInFlight))
        #expect(gate(scheduler, conditions: conditions(), context: Self.inside, now: t0.addingTimeInterval(899))
            == .hold(.notDue(until: t0.addingTimeInterval(900))))
        #expect(gate(scheduler, conditions: conditions(spend: 1), context: Self.inside)
            == .hold(.unavailable(.spendCapReached(until: t0 + 3600))))
    }

    /// As at the mentor gate, the context is settled before anything about
    /// timing, so a held refresh says why in the same terms whatever else
    /// would have held it.
    @Test func theContextIsSettledBeforeTheCallInFlightAndDueChecks() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        let outside = ContextPlacement.outside(.noMatch(reason: ""))
        #expect(gate(scheduler, conditions: conditions(inFlight: true), context: outside)
            == .hold(.outOfContext(.noMatch(reason: ""))))
        #expect(gate(scheduler, conditions: conditions(), context: outside, now: t0.addingTimeInterval(1))
            == .hold(.outOfContext(.noMatch(reason: ""))))
        #expect(gate(scheduler, conditions: conditions(), context: nil, periodStart: nil, lastActivityAt: nil, now: t0)
            == .hold(.notPlacedInAContext))
    }

    // MARK: The off position

    private var offSettings: MentorSettings {
        var never = settings
        never.understandingRefreshInterval = MentorSettings.refreshIntervalRange.upperBound
        return never
    }

    @Test func theTopOfTheRangeMeansOnlyMentorCallsEverRefresh() {
        let scheduler = MentorScheduler(settings: offSettings)
        #expect(offSettings.periodicRefreshIsOff)
        // Half a day of active use later, still nothing due.
        #expect(gate(scheduler, conditions: conditions(), now: t0.addingTimeInterval(43200 - 1))
            == .hold(.periodicRefreshOff))
        #expect(scheduler.nextRefreshAllowed(after: t0, multiplier: 1) == nil)
    }

    /// Off means off, not a very long interval: once a whole top-of-range
    /// interval has run, with or without a record behind the period, no
    /// refresh call comes due.
    @Test(arguments: [43200.0, 43200.0 + 86400])
    func theTopOfTheRangeHoldsHoweverLongThePeriodHasRun(elapsed: TimeInterval) {
        let scheduler = MentorScheduler(settings: offSettings)
        let now = t0.addingTimeInterval(elapsed)
        // A record's last write, or the run's first observation, started the period.
        #expect(gate(scheduler, conditions: conditions(), periodStart: t0, now: now) == .hold(.periodicRefreshOff))
        // No period has begun at all.
        #expect(scheduler.refreshGate(
            conditions: conditions(), context: .notEnforced, periodStart: nil,
            lastActivityAt: now.addingTimeInterval(-1), now: now
        ) == .hold(.periodicRefreshOff))
    }

    /// Only the top itself is off: one second below it still comes due after
    /// its interval, so the 43199 s case above holds because it is off.
    @Test func justBelowTheTopOfTheRangeStillRefreshes() {
        var almost = settings
        almost.understandingRefreshInterval = MentorSettings.refreshIntervalRange.upperBound - 1
        let scheduler = MentorScheduler(settings: almost)
        #expect(!almost.periodicRefreshIsOff)
        #expect(gate(scheduler, conditions: conditions(), now: t0.addingTimeInterval(43200 - 1)) == .run(since: t0))
    }

    /// A reason that holds every tier, or the context boundary, still says
    /// why while the periodic refresh is off.
    @Test func theOffPositionIsCheckedAfterTheAvailabilityAndContextHolds() {
        let now = t0.addingTimeInterval(43200)
        let scheduler = MentorScheduler(settings: offSettings)
        #expect(gate(scheduler, conditions: conditions(mode: .paused), now: now) == .hold(.unavailable(.paused)))
        #expect(gate(scheduler, conditions: conditions(mode: .idle), now: now) == .hold(.unavailable(.idle)))
        #expect(gate(scheduler, conditions: conditions(inFlight: true), now: now) == .hold(.periodicRefreshOff))
        var enforcing = offSettings
        enforcing.onlyMentorInsideContexts = true
        enforcing.contexts = [Self.declared]
        let bounded = MentorScheduler(settings: enforcing)
        #expect(gate(bounded, conditions: conditions(), context: .outside(.noMatch(reason: "")), now: now)
            == .hold(.outOfContext(.noMatch(reason: ""))))
        #expect(gate(bounded, conditions: conditions(), context: nil, now: now) == .hold(.notPlacedInAContext))
        #expect(gate(bounded, conditions: conditions(), context: Self.inside, now: now) == .hold(.periodicRefreshOff))
    }

    @Test func settingsClampTheIntervalIntoItsRange() {
        var tooFast = MentorSettings()
        tooFast.understandingRefreshInterval = 5
        #expect(tooFast.validated().understandingRefreshInterval == MentorSettings.refreshIntervalRange.lowerBound)
        var tooSlow = MentorSettings()
        tooSlow.understandingRefreshInterval = 999_999
        #expect(tooSlow.validated().understandingRefreshInterval == MentorSettings.refreshIntervalRange.upperBound)
    }
}
