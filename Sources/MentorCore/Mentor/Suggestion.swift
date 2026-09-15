import Foundation

/// The closed set of suggestion kinds. "Never for this" suppresses one
/// category for one app, so the set stays small and stable.
public enum SuggestionCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case shortcut
    case workflow
    case tool
    case approach
    case correctness
    case risk
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .shortcut: "Shortcut"
        case .workflow: "Workflow"
        case .tool: "Tool"
        case .approach: "Approach"
        case .correctness: "Correctness"
        case .risk: "Risk"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .shortcut: "keyboard"
        case .workflow: "arrow.triangle.branch"
        case .tool: "wrench.and.screwdriver"
        case .approach: "lightbulb"
        case .correctness: "checkmark.circle"
        case .risk: "exclamationmark.triangle"
        case .other: "sparkles"
        }
    }
}

/// What the user did with a suggestion. Nil while the toast is still up.
public enum SuggestionFeedback: String, Codable, CaseIterable, Sendable {
    case tellMeMore
    case notNow
    case never
    /// The toast timed out with no action.
    case expired
    /// Held while the user talked to another toast, and stale by the time
    /// that ended: never shown at all.
    case expiredUnseen
    /// The user closed the toast without answering.
    case dismissed

    public var label: String {
        switch self {
        case .tellMeMore: "Tell me more"
        case .notNow: "Not now"
        case .never: "Never for this"
        case .expired: "Expired"
        case .expiredUnseen: "Expired, never shown"
        case .dismissed: "Dismissed"
        }
    }

    /// True for the non-answers, which never overwrite an answer.
    public var isNonAnswer: Bool {
        switch self {
        case .expired, .expiredUnseen, .dismissed: true
        case .tellMeMore, .notNow, .never: false
        }
    }
}

/// A suggestion the mentor tier produced, as stored in the journal.
public struct Suggestion: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var bundleID: String?
    public var appName: String
    public var windowTitle: String?
    public var category: SuggestionCategory
    public var title: String
    public var body: String
    public var explanation: String
    public var confidence: Double
    public var observationID: Int64?
    public var model: String
    public var promptVersion: Int
    public var feedback: SuggestionFeedback?
    public var feedbackAt: Date?
    /// The spot on screen the suggestion is about, in the pixels of the frame
    /// it was made from, when the mentor tier gave one and it lay inside the frame.
    public var region: CalloutRegion?
    /// Whether a callout was drawn on screen for it.
    public var calloutShown: Bool

    public init(
        id: Int64 = 0,
        timestamp: Date,
        bundleID: String?,
        appName: String,
        windowTitle: String?,
        category: SuggestionCategory,
        title: String,
        body: String,
        explanation: String,
        confidence: Double,
        observationID: Int64?,
        model: String,
        promptVersion: Int,
        feedback: SuggestionFeedback? = nil,
        feedbackAt: Date? = nil,
        region: CalloutRegion? = nil,
        calloutShown: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.category = category
        self.title = title
        self.body = body
        self.explanation = explanation
        self.confidence = confidence
        self.observationID = observationID
        self.model = model
        self.promptVersion = promptVersion
        self.feedback = feedback
        self.feedbackAt = feedbackAt
        self.region = region
        self.calloutShown = calloutShown
    }
}

/// Which tier made a model call.
public enum ModelTier: String, Codable, Sendable, CaseIterable {
    case triage
    case mentor
    /// The mentor model answering something the user said about a suggestion.
    case followUp
    /// The Settings "Test connection" button.
    case test

    public var label: String {
        switch self {
        case .triage: "Triage"
        case .mentor: "Mentor"
        case .followUp: "Follow-up"
        case .test: "Test"
        }
    }
}

/// How a model call ended, for the call log.
public enum ModelCallOutcome: String, Codable, Sendable, CaseIterable {
    /// Triage said nothing is worth a look.
    case quiet
    /// Triage said the mentor should look.
    case candidate
    /// Triage placed the activity outside every declared context, so the
    /// mentor tier was never reached.
    case outOfContext
    /// The mentor looked and chose silence.
    case nothingToSay
    /// A suggestion was shown.
    case suggested
    /// A suggestion came back under the confidence threshold and was dropped.
    case belowConfidence
    /// A suggestion came back for a snoozed or never-for-this category and was dropped.
    case suppressed
    /// The API declined the request (`stop_reason: refusal`).
    case refused
    /// The response hit `max_tokens` before finishing.
    case truncated
    /// A transport, API, or decoding error.
    case error
    /// The test call succeeded.
    case ok
    /// A follow-up question was answered.
    case answered

    public var label: String {
        switch self {
        case .quiet: "Quiet"
        case .candidate: "Candidate"
        case .outOfContext: "Out of context"
        case .nothingToSay: "Nothing to say"
        case .suggested: "Suggested"
        case .belowConfidence: "Below confidence"
        case .suppressed: "Suppressed"
        case .refused: "Refused"
        case .truncated: "Truncated"
        case .error: "Error"
        case .ok: "OK"
        case .answered: "Answered"
        }
    }
}

/// One model call: what it cost and how it ended. Prompt text is never stored.
public struct ModelCallRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var tier: ModelTier
    public var model: String
    public var promptVersion: Int
    public var promptCharacters: Int
    public var imageBytes: Int
    public var usage: Usage
    /// Estimated dollars from the usage fields and the price table.
    public var cost: Double
    public var latency: TimeInterval
    public var outcome: ModelCallOutcome
    /// The model's one-line reason, or the error message.
    public var detail: String?
    /// Answered from a recording, not the network: never billed, never counted
    /// against the hourly cap, and shown as a replay wherever calls are listed.
    /// The usage is the recorded call's; the cost is zero.
    public var replayed: Bool

    public init(
        id: Int64 = 0,
        timestamp: Date,
        tier: ModelTier,
        model: String,
        promptVersion: Int,
        promptCharacters: Int,
        imageBytes: Int,
        usage: Usage,
        cost: Double,
        latency: TimeInterval,
        outcome: ModelCallOutcome,
        detail: String?,
        replayed: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tier = tier
        self.model = model
        self.promptVersion = promptVersion
        self.promptCharacters = promptCharacters
        self.imageBytes = imageBytes
        self.usage = usage
        self.cost = cost
        self.latency = latency
        self.outcome = outcome
        self.detail = detail
        self.replayed = replayed
    }
}

/// Live state of the mentor loop, for the menu and the debug panel.
public struct MentorStatus: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case ready
        case disabled
        case noAPIKey
        case capReached(until: Date)

        public var label: String {
            switch self {
            case .ready: "Ready"
            case .disabled: "Off in Settings"
            case .noAPIKey: "No API key"
            case .capReached: "Spend cap reached"
            }
        }
    }

    /// The last time the triage gate looked at an observation, and what it decided.
    public struct GateRecord: Equatable, Sendable {
        public var at: Date
        public var observationID: Int64
        /// Nil when triage ran.
        public var hold: MentorScheduler.Hold?

        public init(at: Date, observationID: Int64, hold: MentorScheduler.Hold?) {
            self.at = at
            self.observationID = observationID
            self.hold = hold
        }
    }

    /// The latest verdict on where the user's activity sits relative to the
    /// declared contexts, and what settled it.
    public struct ContextRecord: Equatable, Sendable {
        public var at: Date
        public var placement: ContextPlacement
        /// The app the verdict was made for, so a stale readout is recognisable.
        public var appName: String

        public init(at: Date, placement: ContextPlacement, appName: String) {
            self.at = at
            self.placement = placement
            self.appName = appName
        }
    }

    public struct MentorHoldRecord: Equatable, Sendable {
        public var at: Date
        public var hold: MentorScheduler.MentorHold

        public init(at: Date, hold: MentorScheduler.MentorHold) {
            self.at = at
            self.hold = hold
        }
    }

    /// A follow-up question waiting for the call in flight to return before it is asked.
    public struct PendingFollowUp: Equatable, Sendable {
        public var suggestionID: Int64
        public var question: String
        public var since: Date

        public init(suggestionID: Int64, question: String, since: Date) {
            self.suggestionID = suggestionID
            self.question = question
            self.since = since
        }
    }

    public var availability: Availability
    public var lastGate: GateRecord?
    public var lastContext: ContextRecord?
    public var lastTriage: ModelCallRecord?
    public var lastMentorHold: MentorHoldRecord?
    public var lastMentor: ModelCallRecord?
    public var spendThisHour: Double
    public var hourStart: Date
    public var callsThisHour: Int
    public var cadenceMultiplier: Double
    public var nextTriageAt: Date?
    public var nextMentorAt: Date?
    public var inFlight: ModelTier?
    public var pendingFollowUp: PendingFollowUp?

    public init(
        availability: Availability = .noAPIKey,
        lastGate: GateRecord? = nil,
        lastContext: ContextRecord? = nil,
        lastTriage: ModelCallRecord? = nil,
        lastMentorHold: MentorHoldRecord? = nil,
        lastMentor: ModelCallRecord? = nil,
        spendThisHour: Double = 0,
        hourStart: Date = SpendMeter.hourStart(of: Date()),
        callsThisHour: Int = 0,
        cadenceMultiplier: Double = 1,
        nextTriageAt: Date? = nil,
        nextMentorAt: Date? = nil,
        inFlight: ModelTier? = nil,
        pendingFollowUp: PendingFollowUp? = nil
    ) {
        self.availability = availability
        self.lastGate = lastGate
        self.lastContext = lastContext
        self.lastTriage = lastTriage
        self.lastMentorHold = lastMentorHold
        self.lastMentor = lastMentor
        self.spendThisHour = spendThisHour
        self.hourStart = hourStart
        self.callsThisHour = callsThisHour
        self.cadenceMultiplier = cadenceMultiplier
        self.nextTriageAt = nextTriageAt
        self.nextMentorAt = nextMentorAt
        self.inFlight = inFlight
        self.pendingFollowUp = pendingFollowUp
    }
}

/// Everything the mentor loop publishes.
public enum MentorEvent: Sendable {
    case status(MentorStatus)
    /// A suggestion passed every gate and should be shown.
    case suggestion(Suggestion)
    /// A suggestion's feedback was recorded.
    case feedback(Suggestion)
    /// The user talked back to a suggestion and the exchange was journaled,
    /// with the answer or with why there is none.
    case followUp(FollowUp)
    case call(ModelCallRecord)
    /// The loop journaled an event (a suggestion or feedback), for timelines.
    case event(JournalEvent)
}
