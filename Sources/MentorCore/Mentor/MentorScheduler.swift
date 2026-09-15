import Foundation

/// Pure decision logic for when each tier runs.
///
/// Three gates, each a single function: `triageGate` decides whether an
/// observation is a change moment worth a triage call, `mentorGate` is the
/// yes-or-no between triage's verdict and the mentor tier, and `refreshGate`
/// decides whether the understanding needs a refresh call of its own. The
/// declared mentorship contexts are enforced in these three functions and
/// nowhere else: an enforced but empty list holds triage, and an
/// out-of-context placement holds the mentor tier and the refresh. Two smaller
/// ones follow the calls: `publishGate` decides whether a finished suggestion
/// may be shown now, and `followUpGate` whether a question the user asked may
/// be sent.
public struct MentorScheduler: Equatable, Sendable {
    /// What the loop knows about the world when it asks a gate.
    public struct Conditions: Equatable, Sendable {
        public var mode: SensingMode
        public var hasAPIKey: Bool
        public var callInFlight: Bool
        /// A toast the user has talked to is up: from the key going down until
        /// that toast is closed, so its answer can be read.
        public var talkingBack: Bool
        /// Spend this hour as a fraction of the cap (1 or more means capped).
        public var spendFraction: Double
        /// How much slower the cadences currently run because of spend.
        public var cadenceMultiplier: Double
        /// When the spend bucket rolls over.
        public var nextHourStart: Date

        public init(
            mode: SensingMode,
            hasAPIKey: Bool,
            callInFlight: Bool = false,
            talkingBack: Bool = false,
            spendFraction: Double = 0,
            cadenceMultiplier: Double = 1,
            nextHourStart: Date
        ) {
            self.mode = mode
            self.hasAPIKey = hasAPIKey
            self.callInFlight = callInFlight
            self.talkingBack = talkingBack
            self.spendFraction = spendFraction
            self.cadenceMultiplier = cadenceMultiplier
            self.nextHourStart = nextHourStart
        }
    }

    /// Why triage did not run for an observation.
    public enum Hold: Equatable, Sendable {
        case disabled
        case noAPIKey
        case paused
        case idle
        case excludedApp
        case waitingForPermissions
        case notSensing
        case callInFlight
        case spendCapReached(until: Date)
        case notAChangeMoment(CaptureReason)
        /// Contexts are enforced and none is declared, so nowhere is inside.
        case noContextsDeclared
        /// The observation waited in the queue behind a long call and no longer shows the present.
        case stale(age: TimeInterval)
        case tooSoon(until: Date)
        case nearIdentical(similarity: Double)

        public var label: String {
            switch self {
            case .disabled: "mentor is off in Settings"
            case .noAPIKey: "no API key"
            case .paused: "paused"
            case .idle: "idle"
            case .excludedApp: "excluded app"
            case .waitingForPermissions: "waiting for permissions"
            case .notSensing: "not sensing"
            case .callInFlight: "a call is in flight"
            case .spendCapReached(let until): "spend cap reached until \(until.formatted(date: .omitted, time: .shortened))"
            case .notAChangeMoment(let reason): "not a change moment (\(reason.label))"
            case .noContextsDeclared: "only mentoring inside declared contexts, and none is declared"
            case .stale(let age): "observation is \(Int(age))s old"
            case .tooSoon(let until): "too soon, next at \(until.formatted(date: .omitted, time: .standard))"
            case .nearIdentical(let similarity): "screen text \(Int((similarity * 100).rounded()))% the same as last triaged"
            }
        }
    }

    /// Observations older than this when they reach the gate are dropped:
    /// they queued behind a long mentor call and describe a screen that is gone.
    public static let maxObservationAge: TimeInterval = 30

    public enum TriageGate: Equatable, Sendable {
        case run
        case hold(Hold)
    }

    /// Why the mentor tier did not run after triage.
    public enum MentorHold: Equatable, Sendable {
        /// Triage placed the activity outside every declared context.
        case outOfContext(ContextExclusion)
        case triageSaidNo(reason: String)
        case tooSoon(until: Date)
        case spendCapReached(until: Date)

        public var label: String {
            switch self {
            case .outOfContext(let exclusion): "outside every declared context (\(exclusion.label))"
            case .triageSaidNo(let reason): "triage passed: \(reason)"
            case .tooSoon(let until): "too soon, next at \(until.formatted(date: .omitted, time: .standard))"
            case .spendCapReached(let until): "spend cap reached until \(until.formatted(date: .omitted, time: .shortened))"
            }
        }
    }

    public enum MentorGate: Equatable, Sendable {
        case run
        case hold(MentorHold)
    }

    /// Whether a suggestion the mentor tier has just made may be shown.
    public enum PublishGate: Equatable, Sendable {
        case show
        /// The user is talking back to the toast that is up; another toast
        /// would cut the exchange off, so this one waits for it to end.
        case hold
        /// It waited out an exchange and describes a screen that is gone.
        case expired(age: TimeInterval)
    }

    /// Whether a follow-up question may go to the mentor tier. A held
    /// question is journaled with the reason and never sent; a waiting one
    /// is asked once the call in flight returns.
    public enum FollowUpGate: Equatable, Sendable {
        case run
        case wait
        case hold(Hold)
    }

    public var settings: MentorSettings
    public private(set) var lastTriageAt: Date?
    public private(set) var lastTriagedWindow: String?
    public private(set) var lastTriagedText: String?
    public private(set) var lastMentorAt: Date?

    public init(settings: MentorSettings) {
        self.settings = settings
    }

    // MARK: Triage gate

    /// Whether this observation is a change moment worth a triage call.
    public func triageGate(for observation: ActivityObservation, conditions: Conditions, now: Date) -> TriageGate {
        if let hold = availabilityHold(conditions: conditions) { return .hold(hold) }
        if let hold = contextHold() { return .hold(hold) }
        if conditions.callInFlight { return .hold(.callInFlight) }
        guard observation.reason.isChangeMoment else { return .hold(.notAChangeMoment(observation.reason)) }
        let age = now.timeIntervalSince(observation.timestamp)
        if age > MentorScheduler.maxObservationAge { return .hold(.stale(age: age)) }
        if let next = nextTriageAllowed(multiplier: conditions.cadenceMultiplier), next > now {
            return .hold(.tooSoon(until: next))
        }
        if let lastTriagedWindow, let lastTriagedText, lastTriagedWindow == observation.focus.windowSignature {
            let similarity = TextSimilarity.lineJaccard(lastTriagedText, observation.ocrText)
            if similarity >= settings.triageSimilarityThreshold {
                return .hold(.nearIdentical(similarity: similarity))
            }
        }
        return .run
    }

    /// Everything that blocks every tier regardless of the observation.
    public func availabilityHold(conditions: Conditions) -> Hold? {
        guard settings.enabled else { return .disabled }
        switch conditions.mode {
        case .paused: return .paused
        case .idle: return .idle
        case .excluded: return .excludedApp
        case .waitingForPermissions: return .waitingForPermissions
        case .stopped: return .notSensing
        case .watching, .accessibilityOnly, .screenOnly: break
        }
        guard conditions.hasAPIKey else { return .noAPIKey }
        if conditions.spendFraction >= 1 { return .spendCapReached(until: conditions.nextHourStart) }
        return nil
    }

    /// What the declared contexts decide before any call: enforcing an empty
    /// list means no activity can ever be inside, so no tier should spend
    /// anything.
    public func contextHold() -> Hold? {
        guard settings.onlyMentorInsideContexts, settings.contexts.isEmpty else { return nil }
        return .noContextsDeclared
    }

    public mutating func noteTriageStarted(observation: ActivityObservation, now: Date) {
        lastTriageAt = now
        lastTriagedWindow = observation.focus.windowSignature
        lastTriagedText = observation.ocrText
    }

    /// When the next triage call may start, or nil when none has run yet.
    public func nextTriageAllowed(multiplier: Double) -> Date? {
        lastTriageAt?.addingTimeInterval(settings.triageMinInterval * max(1, multiplier))
    }

    // MARK: Mentor gate

    /// The single yes-or-no between triage and the mentor tier. The context
    /// placement is checked first: while the user enforces contexts, an
    /// activity outside them can never produce a suggestion, whatever else
    /// triage thought of it.
    public func mentorGate(triage: TriageVerdict, context: ContextPlacement, conditions: Conditions, now: Date) -> MentorGate {
        if case .outside(let exclusion) = context { return .hold(.outOfContext(exclusion)) }
        guard triage.worthALook else { return .hold(.triageSaidNo(reason: triage.reason)) }
        if conditions.spendFraction >= 1 { return .hold(.spendCapReached(until: conditions.nextHourStart)) }
        if let next = nextMentorAllowed(multiplier: conditions.cadenceMultiplier), next > now {
            return .hold(.tooSoon(until: next))
        }
        return .run
    }

    public mutating func noteMentorStarted(now: Date) {
        lastMentorAt = now
    }

    // MARK: Publish gate

    /// The yes-or-no between a finished mentor call and the toast. A
    /// suggestion made while a talked-to toast is up is held so that toast,
    /// the recording, the pending answer, and the answer on screen stay as
    /// they are; when that toast closes it is shown, unless it waited longer
    /// than `maxObservationAge`, in which case it expires unseen.
    public func publishGate(madeAt: Date, conditions: Conditions, now: Date) -> PublishGate {
        if conditions.talkingBack { return .hold }
        let age = now.timeIntervalSince(madeAt)
        if age > MentorScheduler.maxObservationAge { return .expired(age: age) }
        return .show
    }

    // MARK: Follow-up gate

    /// The user asked, so there is no debounce and no context question: only
    /// what blocks every tier (off, paused, idle, excluded, no key, the spend
    /// cap) holds it, and a call already in flight makes it wait its turn.
    public func followUpGate(conditions: Conditions) -> FollowUpGate {
        if let hold = availabilityHold(conditions: conditions) { return .hold(hold) }
        if conditions.callInFlight { return .wait }
        return .run
    }

    public func nextMentorAllowed(multiplier: Double) -> Date? {
        lastMentorAt?.addingTimeInterval(settings.mentorMinInterval * max(1, multiplier))
    }

    // MARK: Refresh gate

    /// Why the understanding was not refreshed by a call of its own.
    public enum RefreshHold: Equatable, Sendable {
        /// Something holds every tier: off, paused, idle, an excluded app,
        /// missing permissions, no key, the spend cap, or contexts enforced
        /// with none declared.
        case unavailable(Hold)
        /// Contexts are enforced and triage placed the frontmost app outside
        /// every declared one.
        case outOfContext(ContextExclusion)
        /// Contexts are enforced and triage has not placed the frontmost app
        /// since it came to the front, so nothing says the work is inside one.
        case notPlacedInAContext
        case callInFlight
        /// A mentor call or an earlier refresh already rewrote the record
        /// recently enough; `until` is when it comes due if use carries on.
        case notDue(until: Date)
        /// Nothing has been observed yet, so there is nothing to fold in.
        case noNewActivity

        public var label: String {
            switch self {
            case .unavailable(let hold): hold.label
            case .outOfContext(let exclusion): "outside every declared context (\(exclusion.label))"
            case .notPlacedInAContext: "not yet placed in a declared context"
            case .callInFlight: "a call is in flight"
            case .notDue(let until): "not due, next at \(until.formatted(date: .omitted, time: .standard))"
            case .noNewActivity: "nothing observed yet"
            }
        }
    }

    public enum RefreshGate: Equatable, Sendable {
        /// Refresh now, folding in everything since the period began.
        case run(since: Date)
        case hold(RefreshHold)
    }

    /// Whether the understanding needs a refresh call of its own right now.
    ///
    /// Every mentor call rewrites the record on the way past, so this only
    /// fires after a whole refresh interval of active use with no mentor call
    /// in it. `period` counts that use (`RefreshPeriod`): it begins at the
    /// record's last write, or at the first activity seen when there is no
    /// record, so the very first observation of a session never buys a call
    /// of its own, and no period at all means nothing is due. A break, a pause,
    /// or a closed app counts for nothing, so returning from one never buys a
    /// call over the few screens since. A refresh attempt starts the count over
    /// whatever came of it (`RefreshPeriod.restarted(at:)`), like the other
    /// tiers' minimum intervals, so a failed call is not retried on every
    /// observation.
    ///
    /// `context` is triage's latest placement of the frontmost app, or nil
    /// when it has not placed that app. While contexts are enforced the record
    /// is only ever written from inside one: the mentor tier never runs
    /// outside, and this gate waits until the frontmost app is placed inside.
    public func refreshGate(
        conditions: Conditions,
        context: ContextPlacement?,
        period: RefreshPeriod?,
        lastActivityAt: Date?,
        now: Date
    ) -> RefreshGate {
        if let hold = availabilityHold(conditions: conditions) { return .hold(.unavailable(hold)) }
        if let hold = contextHold() { return .hold(.unavailable(hold)) }
        if let hold = placementHold(context) { return .hold(hold) }
        if conditions.callInFlight { return .hold(.callInFlight) }
        guard let period, lastActivityAt != nil else { return .hold(.noNewActivity) }
        let counted = period.counted(through: now, in: conditions.mode)
        if let next = nextRefreshAllowed(after: counted, mode: conditions.mode, multiplier: conditions.cadenceMultiplier),
           next > now {
            return .hold(.notDue(until: next))
        }
        return .run(since: period.startedAt)
    }

    /// What the latest placement decides for the refresh while contexts are
    /// enforced. No verdict for the frontmost app, or one reached while the
    /// switch was off, counts as outside: enforcement fails closed here as it
    /// does at the mentor gate.
    private func placementHold(_ context: ContextPlacement?) -> RefreshHold? {
        guard settings.onlyMentorInsideContexts else { return nil }
        switch context {
        case .inside: return nil
        case .outside(let exclusion): return .outOfContext(exclusion)
        case .notEnforced, nil: return .notPlacedInAContext
        }
    }

    /// When the next refresh call may start if use carries on unbroken: once
    /// the period has counted a whole interval of active use. Nil before any
    /// period has begun, and while `mode` counts none, since nothing comes due
    /// until the user is back. `period` must have been counted whenever the
    /// mode last changed, as the loop does.
    public func nextRefreshAllowed(after period: RefreshPeriod?, mode: SensingMode, multiplier: Double) -> Date? {
        guard let period, mode.capturesFrames else { return nil }
        let interval = settings.understandingRefreshInterval * max(1, multiplier)
        return period.countedAt.addingTimeInterval(interval - period.activeUse)
    }
}

/// How far the understanding's refresh interval has run. Only active use
/// counts: time in a mode that captures the screen, and so leaves screens for
/// a refresh to read; never paused, idle, on an excluded app, waiting for
/// permissions, or with the app closed. The loop keeps it in the journal, so a
/// relaunch carries on counting.
public struct RefreshPeriod: Equatable, Sendable {
    /// When the period began: the record's last write, or the first activity
    /// seen with no record. A refresh reads the screens since then.
    public var startedAt: Date
    /// Active use counted toward the next refresh since the period began, or
    /// since the last refresh attempt when one came after that.
    public var activeUse: TimeInterval
    /// When `activeUse` was last brought up to date.
    public var countedAt: Date

    public init(startedAt: Date, activeUse: TimeInterval = 0, countedAt: Date? = nil) {
        self.startedAt = startedAt
        self.activeUse = activeUse
        self.countedAt = countedAt ?? startedAt
    }

    /// The period counted through `now`, with all the time since the last
    /// count spent in `mode`.
    public func counted(through now: Date, in mode: SensingMode) -> RefreshPeriod {
        var counted = self
        if mode.capturesFrames {
            counted.activeUse += max(0, now.timeIntervalSince(countedAt))
        }
        counted.countedAt = max(countedAt, now)
        return counted
    }

    /// The same period with its count started over at `now`, as a refresh
    /// attempt leaves it. Its screens still reach back to `startedAt`.
    public func restarted(at now: Date) -> RefreshPeriod {
        RefreshPeriod(startedAt: startedAt, activeUse: 0, countedAt: now)
    }
}

extension CaptureReason {
    /// Focus changes, input settling, and manual captures are change moments;
    /// the floor cadence is not.
    public var isChangeMoment: Bool {
        switch self {
        case .focusChange, .inputSettled, .manual: true
        case .floor: false
        }
    }
}

/// Cheap text comparison for the near-identical rule.
public enum TextSimilarity {
    /// Non-empty trimmed lines, lowercased.
    public static func lines(_ text: String) -> Set<String> {
        var result = Set<String>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if !trimmed.isEmpty { result.insert(trimmed) }
        }
        return result
    }

    /// Jaccard similarity of the two texts' line sets: 1 when identical, 0 when disjoint.
    public static func lineJaccard(_ a: String, _ b: String) -> Double {
        let left = lines(a)
        let right = lines(b)
        let union = left.union(right)
        guard !union.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(union.count)
    }
}
