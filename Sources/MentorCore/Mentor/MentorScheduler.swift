import Foundation

/// Pure decision logic for when each tier runs.
///
/// Two gates, each a single function: `triageGate` decides whether an
/// observation is a change moment worth a triage call, and `mentorGate` is the
/// yes-or-no between triage's verdict and the mentor tier. The declared
/// mentorship contexts are enforced in these two functions and nowhere else:
/// an enforced but empty list holds triage, and an out-of-context placement
/// holds the mentor tier. Two smaller ones follow the calls: `publishGate`
/// decides whether a finished suggestion may be shown now, and `followUpGate`
/// whether a question the user asked may be sent.
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

    /// Everything that blocks both tiers regardless of the observation.
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
    /// list means no activity can ever be inside, so neither tier should spend
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
