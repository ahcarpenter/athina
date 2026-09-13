import CoreGraphics
import Foundation
import Testing
@testable import MentorCore

enum Fixtures {
    static func observation(
        id: Int64 = 1,
        at time: Date,
        app: String = "Xcode",
        bundleID: String? = "com.apple.dt.Xcode",
        window: String? = "main.swift",
        text: String = "let x = 1\nprint(x)",
        reason: CaptureReason = .focusChange,
        jpeg: Data? = nil
    ) -> ActivityObservation {
        let focus = FocusContext(
            timestamp: time, pid: 42, bundleID: bundleID, appName: app, windowTitle: window,
            focusedRole: "AXTextArea", focusedValue: "let x = 1", focusedValueLength: 9
        )
        let frame = FrameInfo(
            hash: PerceptualHash(words: [1, 2, 3, 4]), width: 1280, height: 800, displayID: 1,
            screenRect: CGRect(x: 0, y: 0, width: 2560, height: 1600), jpeg: jpeg
        )
        let blocks = text.split(separator: "\n").enumerated().map { index, line in
            TextBlock(
                text: String(line), confidence: 0.9,
                imageRect: CGRect(x: 10, y: 20 * CGFloat(index), width: 100, height: 12),
                screenRect: CGRect(x: 20, y: 40 * CGFloat(index), width: 200, height: 24)
            )
        }
        return ActivityObservation(id: id, timestamp: time, focus: focus, frame: frame, textBlocks: blocks, reason: reason)
    }

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

@Suite struct MentorSchedulerTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private var settings: MentorSettings {
        var s = MentorSettings()
        s.triageMinInterval = 20
        s.mentorMinInterval = 120
        s.triageSimilarityThreshold = 0.9
        return s
    }

    private func conditions(mode: SensingMode = .watching, key: Bool = true, inFlight: Bool = false, spend: Double = 0, multiplier: Double = 1) -> MentorScheduler.Conditions {
        MentorScheduler.Conditions(
            mode: mode, hasAPIKey: key, callInFlight: inFlight,
            spendFraction: spend, cadenceMultiplier: multiplier, nextHourStart: t0 + 3600
        )
    }

    @Test func changeMomentsRunAndFloorFramesDoNot() {
        let scheduler = MentorScheduler(settings: settings)
        #expect(scheduler.triageGate(for: Fixtures.observation(at: t0, reason: .focusChange), conditions: conditions(), now: t0) == .run)
        #expect(scheduler.triageGate(for: Fixtures.observation(at: t0, reason: .inputSettled), conditions: conditions(), now: t0) == .run)
        #expect(scheduler.triageGate(for: Fixtures.observation(at: t0, reason: .manual), conditions: conditions(), now: t0) == .run)
        #expect(scheduler.triageGate(for: Fixtures.observation(at: t0, reason: .floor), conditions: conditions(), now: t0) == .hold(.notAChangeMoment(.floor)))
    }

    @Test func nothingRunsWhilePausedIdleExcludedUnpermittedOrKeyless() {
        var disabled = settings
        disabled.enabled = false
        let off = MentorScheduler(settings: disabled)
        let observation = Fixtures.observation(at: t0)
        #expect(off.triageGate(for: observation, conditions: conditions(), now: t0) == .hold(.disabled))

        let scheduler = MentorScheduler(settings: settings)
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .paused), now: t0) == .hold(.paused))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .idle), now: t0) == .hold(.idle))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .excluded), now: t0) == .hold(.excludedApp))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .waitingForPermissions), now: t0) == .hold(.waitingForPermissions))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .stopped), now: t0) == .hold(.notSensing))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(key: false), now: t0) == .hold(.noAPIKey))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(inFlight: true), now: t0) == .hold(.callInFlight))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .accessibilityOnly), now: t0) == .run)
        #expect(scheduler.triageGate(for: observation, conditions: conditions(mode: .screenOnly), now: t0) == .run)
    }

    @Test func triageIsDebouncedToTheMinimumInterval() {
        var scheduler = MentorScheduler(settings: settings)
        let first = Fixtures.observation(id: 1, at: t0, text: "alpha\nbeta")
        #expect(scheduler.triageGate(for: first, conditions: conditions(), now: t0) == .run)
        scheduler.noteTriageStarted(observation: first, now: t0)

        let second = Fixtures.observation(id: 2, at: t0 + 5, window: "other.swift", text: "gamma\ndelta")
        #expect(scheduler.triageGate(for: second, conditions: conditions(), now: t0 + 5) == .hold(.tooSoon(until: t0 + 20)))
        #expect(scheduler.triageGate(for: second, conditions: conditions(), now: t0 + 20) == .run)
    }

    @Test func spendMultiplierStretchesBothIntervals() {
        var scheduler = MentorScheduler(settings: settings)
        let observation = Fixtures.observation(at: t0)
        scheduler.noteTriageStarted(observation: observation, now: t0)
        scheduler.noteMentorStarted(now: t0)
        let slowed = conditions(multiplier: 2)
        let later = Fixtures.observation(id: 2, at: t0 + 25, window: "b.swift", text: "different\ntext")
        #expect(scheduler.triageGate(for: later, conditions: slowed, now: t0 + 25) == .hold(.tooSoon(until: t0 + 40)))
        #expect(scheduler.triageGate(for: later, conditions: slowed, now: t0 + 40) == .run)
        let yes = TriageVerdict(worthALook: true, reason: "x")
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: slowed, now: t0 + 130) == .hold(.tooSoon(until: t0 + 240)))
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: slowed, now: t0 + 240) == .run)
        #expect(scheduler.nextTriageAllowed(multiplier: 0.5) == t0 + 20)
    }

    @Test func nearIdenticalTextInTheSameWindowIsSkipped() {
        var scheduler = MentorScheduler(settings: settings)
        let lines = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let first = Fixtures.observation(id: 1, at: t0, text: lines)
        scheduler.noteTriageStarted(observation: first, now: t0)

        let almostSame = Fixtures.observation(id: 2, at: t0 + 30, text: lines + "\nline 21")
        if case .hold(.nearIdentical(let similarity)) = scheduler.triageGate(for: almostSame, conditions: conditions(), now: t0 + 30) {
            #expect(similarity > 0.9)
        } else {
            Issue.record("expected a near-identical hold")
        }

        let changed = Fixtures.observation(id: 3, at: t0 + 30, text: (1...20).map { "other \($0)" }.joined(separator: "\n"))
        #expect(scheduler.triageGate(for: changed, conditions: conditions(), now: t0 + 30) == .run)

        // The same text in a different window is a change moment again.
        let otherWindow = Fixtures.observation(id: 4, at: t0 + 30, window: "b.swift", text: lines)
        #expect(scheduler.triageGate(for: otherWindow, conditions: conditions(), now: t0 + 30) == .run)
    }

    @Test func mentorGateIsASingleDecision() {
        var scheduler = MentorScheduler(settings: settings)
        let no = TriageVerdict(worthALook: false, reason: "reading docs")
        let yes = TriageVerdict(worthALook: true, reason: "repeated manual steps")
        #expect(scheduler.mentorGate(triage: no, context: .notEnforced, conditions: conditions(), now: t0) == .hold(.triageSaidNo(reason: "reading docs")))
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: conditions(), now: t0) == .run)
        scheduler.noteMentorStarted(now: t0)
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: conditions(), now: t0 + 60) == .hold(.tooSoon(until: t0 + 120)))
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: conditions(), now: t0 + 120) == .run)
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: conditions(spend: 1), now: t0 + 120) == .hold(.spendCapReached(until: t0 + 3600)))
    }

    // MARK: Mentorship contexts

    private var contexts: [MentorshipContext] {
        [
            MentorshipContext(name: "writing Swift", alwaysInside: [ContextRule(kind: .app, value: "com.apple.dt.Xcode")]),
            MentorshipContext(name: "reading API documentation"),
        ]
    }

    /// The gate's settings for one combination of the switch and the lists.
    private func contextSettings(enforcing: Bool, declared: Bool = true, alwaysOutside: [ContextRule] = []) -> MentorSettings {
        var s = settings
        s.onlyMentorInsideContexts = enforcing
        s.contexts = declared ? contexts : []
        s.alwaysOutside = alwaysOutside
        return s.validated()
    }

    private func inside(_ name: String, confidence: Double = 0.9) -> ContextPlacement {
        .inside(ContextMatch(contextID: UUID(), name: name, confidence: confidence))
    }

    @Test func anAlwaysOutsideAppSkipsTriageEntirelyWithOrWithoutTheSwitch() {
        let rule = ContextRule(kind: .app, value: "com.apple.dt.Xcode")
        let observation = Fixtures.observation(at: t0)
        for enforcing in [true, false] {
            let scheduler = MentorScheduler(settings: contextSettings(enforcing: enforcing, alwaysOutside: [rule]))
            guard case .hold(.alwaysOutside(let held)) = scheduler.triageGate(for: observation, conditions: conditions(), now: t0) else {
                Issue.record("expected an always-outside hold with the switch \(enforcing ? "on" : "off")")
                return
            }
            #expect(held.value == rule.value)
        }
    }

    @Test func anAlwaysOutsideSiteSkipsTriageOnTheWindowTitle() {
        let scheduler = MentorScheduler(settings: contextSettings(
            enforcing: true, alwaysOutside: [ContextRule(kind: .site, value: "mail.google.com")]
        ))
        let inbox = Fixtures.observation(at: t0, app: "Safari", bundleID: "com.apple.Safari", window: "Inbox - mail.google.com")
        let docs = Fixtures.observation(id: 2, at: t0, app: "Safari", bundleID: "com.apple.Safari", window: "SCStream - Apple Developer")
        #expect(scheduler.triageGate(for: inbox, conditions: conditions(), now: t0).isHold)
        #expect(scheduler.triageGate(for: docs, conditions: conditions(), now: t0) == .run)
    }

    @Test func enforcingWithNoContextDeclaredHoldsTriageSoNothingIsSpent() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true, declared: false))
        #expect(scheduler.triageGate(for: Fixtures.observation(at: t0), conditions: conditions(), now: t0) == .hold(.noContextsDeclared))

        let off = MentorScheduler(settings: contextSettings(enforcing: false, declared: false))
        #expect(off.triageGate(for: Fixtures.observation(at: t0), conditions: conditions(), now: t0) == .run)
    }

    @Test func enforcingWithAContextDeclaredStillRunsTriage() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        #expect(scheduler.triageGate(for: Fixtures.observation(at: t0), conditions: conditions(), now: t0) == .run)
    }

    @Test func outOfContextNeverReachesTheMentorTierHoweverKeenTriageWas() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        let yes = TriageVerdict(worthALook: true, reason: "repeated manual steps", context: nil, contextConfidence: 0.9)
        let exclusions: [ContextExclusion] = [
            .noMatch(reason: ""),
            .belowConfidence(name: "writing Swift", confidence: 0.2, threshold: 0.6),
            .unanswered,
            .noContextsDeclared,
        ]
        for exclusion in exclusions {
            #expect(scheduler.mentorGate(
                triage: yes, context: .outside(exclusion), conditions: conditions(), now: t0
            ) == .hold(.outOfContext(exclusion)))
        }
    }

    @Test func insideAContextStillHasToPassEveryOtherCheck() {
        var scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        let yes = TriageVerdict(worthALook: true, reason: "repeated manual steps", context: "writing Swift", contextConfidence: 0.9)
        let no = TriageVerdict(worthALook: false, reason: "reading", context: "writing Swift", contextConfidence: 0.9)
        let placement = inside("writing Swift")
        #expect(scheduler.mentorGate(triage: yes, context: placement, conditions: conditions(), now: t0) == .run)
        #expect(scheduler.mentorGate(triage: no, context: placement, conditions: conditions(), now: t0) == .hold(.triageSaidNo(reason: "reading")))
        #expect(scheduler.mentorGate(triage: yes, context: placement, conditions: conditions(spend: 1), now: t0) == .hold(.spendCapReached(until: t0 + 3600)))
        scheduler.noteMentorStarted(now: t0)
        #expect(scheduler.mentorGate(triage: yes, context: placement, conditions: conditions(), now: t0 + 60) == .hold(.tooSoon(until: t0 + 120)))
    }

    @Test func theContextCheckIsMadeBeforeTriagesOwnJudgement() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: true))
        let no = TriageVerdict(worthALook: false, reason: "reading", context: nil, contextConfidence: 0.9)
        #expect(scheduler.mentorGate(
            triage: no, context: .outside(.noMatch(reason: "")), conditions: conditions(), now: t0
        ) == .hold(.outOfContext(.noMatch(reason: ""))))
    }

    @Test func withTheSwitchOffTheContextNeverHoldsTheMentorTier() {
        let scheduler = MentorScheduler(settings: contextSettings(enforcing: false))
        let yes = TriageVerdict(worthALook: true, reason: "x")
        #expect(scheduler.mentorGate(triage: yes, context: .notEnforced, conditions: conditions(), now: t0) == .run)
    }

    @Test func observationsThatQueuedBehindALongCallAreDropped() {
        let scheduler = MentorScheduler(settings: settings)
        let observation = Fixtures.observation(at: t0)
        #expect(scheduler.triageGate(for: observation, conditions: conditions(), now: t0 + 29) == .run)
        #expect(scheduler.triageGate(for: observation, conditions: conditions(), now: t0 + 31) == .hold(.stale(age: 31)))
    }

    @Test func spendCapStopsTriageUntilTheHourRollsOver() {
        let scheduler = MentorScheduler(settings: settings)
        let observation = Fixtures.observation(at: t0)
        #expect(scheduler.triageGate(for: observation, conditions: conditions(spend: 1.0), now: t0) == .hold(.spendCapReached(until: t0 + 3600)))
        #expect(scheduler.triageGate(for: observation, conditions: conditions(spend: 0.99), now: t0) == .run)
    }

    @Test func lineSimilarityIgnoresCaseWhitespaceAndOrder() {
        #expect(TextSimilarity.lineJaccard("A\nB\nC", "c\n b \na") == 1)
        #expect(TextSimilarity.lineJaccard("a\nb", "c\nd") == 0)
        #expect(TextSimilarity.lineJaccard("", "") == 1)
        #expect(TextSimilarity.lineJaccard("a\nb\nc\nd", "a\nb\nc\ne") == 0.6)
    }
}

extension MentorScheduler.TriageGate {
    /// Reads better than a full pattern match when only "did it hold" matters.
    var isHold: Bool {
        if case .hold = self { return true }
        return false
    }
}
