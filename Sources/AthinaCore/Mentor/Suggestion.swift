import Foundation

/// The closed set of suggestion kinds. "Never for this" suppresses one
/// category for one app, so the set stays small and stable.
///
/// The last three judge the current action against the goal Athina has
/// inferred, and are raised only when there is an understanding to judge
/// against; the first seven stand on the moment alone.
public enum SuggestionCategory: String, Codable, CaseIterable, Sendable, Identifiable {
  case shortcut
  case workflow
  case tool
  case approach
  case correctness
  case risk
  case other
  // The raw values stay snake_case, matching the other multi-word JSON names
  // in the prompts, so the schema's enum and the prompt text agree.
  /// The approach will not get the user to the goal they appear to have.
  case wontAchieveGoal = "wont_achieve_goal"
  /// It will get there, but an available alternative gets there for less work.
  case lessEfficient = "less_efficient"
  /// It will get there and bring a consequence the user would not want.
  case unwantedSideEffect = "unwanted_side_effect"

  public var id: String { rawValue }

  /// True for the kinds that are judged against an inferred goal.
  public var judgesAgainstGoal: Bool {
    switch self {
    case .wontAchieveGoal, .lessEfficient, .unwantedSideEffect: true
    case .shortcut, .workflow, .tool, .approach, .correctness, .risk, .other: false
    }
  }

  public var label: String {
    switch self {
    case .shortcut: "Shortcut"
    case .workflow: "Workflow"
    case .tool: "Tool"
    case .approach: "Approach"
    case .correctness: "Correctness"
    case .risk: "Risk"
    case .other: "Other"
    case .wontAchieveGoal: "Will not reach the goal"
    case .lessEfficient: "Less efficient"
    case .unwantedSideEffect: "Unwanted side effect"
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
    case .wontAchieveGoal: "flag.slash"
    case .lessEfficient: "tortoise"
    case .unwantedSideEffect: "bolt.trianglebadge.exclamationmark"
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
  /// The inferred goal this was judged against, when there was one. Shown in
  /// the history window and the debug panel so a suggestion can be read
  /// against what Athina thought the user was trying to do.
  public var judgedGoal: String?
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
    judgedGoal: String? = nil,
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
    self.judgedGoal = judgedGoal
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
  /// A periodic refresh of the understanding, made only when no mentor call
  /// has refreshed it within the refresh interval.
  case understanding
  /// The Settings "Test connection" button.
  case test

  public var label: String {
    switch self {
    case .triage: "Triage"
    case .mentor: "Mentor"
    case .followUp: "Follow-up"
    case .understanding: "Understanding"
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
  /// A refresh call rewrote the understanding.
  case refreshed
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
    case .refreshed: "Refreshed"
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

    /// Whether Athina can work out an understanding at all: not while it is
    /// off or has no key. A reached cap only delays it.
    public var formsUnderstanding: Bool {
      switch self {
      case .ready, .capReached: true
      case .disabled, .noAPIKey: false
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

  /// The last time the refresh gate looked, and why it did not refresh.
  public struct RefreshHoldRecord: Equatable, Sendable {
    public var at: Date
    public var hold: MentorScheduler.RefreshHold

    public init(at: Date, hold: MentorScheduler.RefreshHold) {
      self.at = at
      self.hold = hold
    }
  }

  public var availability: Availability
  /// The sensing mode the loop last heard, which every gate reads.
  public var mode: SensingMode
  public var lastGate: GateRecord?
  public var lastContext: ContextRecord?
  public var lastTriage: ModelCallRecord?
  public var lastMentorHold: MentorHoldRecord?
  public var lastMentor: ModelCallRecord?
  /// The understanding being carried between calls, or nil when none has
  /// formed yet, it expired, or it was reset.
  public var understanding: UnderstandingRecord?
  public var lastRefreshHold: RefreshHoldRecord?
  public var lastRefresh: ModelCallRecord?
  public var nextRefreshAt: Date?
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
    understanding: UnderstandingRecord? = nil,
    lastRefreshHold: RefreshHoldRecord? = nil,
    lastRefresh: ModelCallRecord? = nil,
    nextRefreshAt: Date? = nil,
    spendThisHour: Double = 0,
    hourStart: Date = .distantPast,
    callsThisHour: Int = 0,
    cadenceMultiplier: Double = 1,
    nextTriageAt: Date? = nil,
    nextMentorAt: Date? = nil,
    inFlight: ModelTier? = nil,
    pendingFollowUp: PendingFollowUp? = nil,
    mode: SensingMode = .stopped
  ) {
    self.availability = availability
    self.mode = mode
    self.lastGate = lastGate
    self.lastContext = lastContext
    self.lastTriage = lastTriage
    self.lastMentorHold = lastMentorHold
    self.lastMentor = lastMentor
    self.understanding = understanding
    self.lastRefreshHold = lastRefreshHold
    self.lastRefresh = lastRefresh
    self.nextRefreshAt = nextRefreshAt
    self.spendThisHour = spendThisHour
    self.hourStart = hourStart
    self.callsThisHour = callsThisHour
    self.cadenceMultiplier = cadenceMultiplier
    self.nextTriageAt = nextTriageAt
    self.nextMentorAt = nextMentorAt
    self.inFlight = inFlight
    self.pendingFollowUp = pendingFollowUp
  }

  /// Whether the cadence is stretched enough to call it slowed. The spend
  /// slowdown leaves 1 with the first cheap call of the hour, so a readout
  /// only names it past a slowdown a person would notice.
  public var isCadenceSlowed: Bool { cadenceMultiplier > 1.05 }

  /// Where the periodic refresh stands now, for a readout.
  public enum RefreshStanding: Equatable, Sendable {
    /// The mode counts no active use, so no refresh is due until it does.
    case notCounting(SensingMode)
    /// Nothing is counting: there is no record, and the count starts from
    /// zero with the next screen, as after a launch, an expiry, or a reset.
    case notStarted
    /// Counting toward `next`. `hold` is why the refresh gate last held,
    /// while that is still the reason in force.
    case counting(next: Date, hold: RefreshHoldRecord?)
  }

  /// The refresh's standing in `mode`, derived from the current state rather
  /// than from the refresh gate's last look, which may predate a pause, a
  /// reset, or a new record. A not-due hold is in force only while its time
  /// is still the next refresh.
  public func refreshStanding(mode: SensingMode) -> RefreshStanding {
    guard mode.capturesFrames else { return .notCounting(mode) }
    guard let next = nextRefreshAt else { return .notStarted }
    var hold = lastRefreshHold
    if case .notDue(let until)? = hold?.hold, until != next { hold = nil }
    return .counting(next: next, hold: hold)
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
