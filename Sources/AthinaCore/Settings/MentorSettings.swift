import Foundation

/// Everything the mentor loop can be tuned with.
///
/// Persisted inside `settings.json` under the `mentor` key; missing fields take
/// their defaults (`SettingsSection`).
public struct MentorSettings: SettingsSection, Equatable, Sendable {
  // MARK: Provider

  /// Whose API answers model calls, with the person's own key for it:
  /// Anthropic unless the person picks another in Settings > Models.
  ///
  /// Each provider sends to a different company, so each needs its own Allow
  /// on the consent page (`SensingSettings.hasConsent`).
  public var provider: ModelProvider = .anthropic
  /// The models and efforts OpenAI answers with.
  public var openAIModels = TierModels.openAIDefaults
  /// The models and efforts OpenCode answers with.
  public var openCodeModels = TierModels.openCodeDefaults

  // MARK: Models

  /// Master switch.
  ///
  /// Off means no model call of any kind, but for a Test Connection the user
  /// asks for.
  public var enabled = true
  /// The id of the Anthropic model that makes the triage call, one of
  /// `ModelCatalog.triageChoices`; each other provider keeps its own
  /// (`TierModels`).
  public var triageModel = ModelCatalog.haiku45.id
  /// The id of the model that makes mentor and follow-up calls, one of
  /// `ModelCatalog.mentorChoices`.
  public var mentorModel = ModelCatalog.opus5.id
  /// The model that rewrites the understanding on a periodic refresh.
  ///
  /// A mentor call refreshes it for free, so this one runs only in the gaps.
  public var understandingModel = ModelCatalog.opus5.id
  /// Reasoning depth per tier, sent only to models that accept it.
  public var triageEffort: Effort = .low
  /// The reasoning depth sent with mentor and follow-up calls.
  public var mentorEffort: Effort = .medium
  /// The reasoning depth sent with the understanding's refresh calls.
  public var understandingEffort: Effort = .low

  // MARK: Cadence

  /// At most one triage call per this many seconds (before spend slowing).
  public var triageMinInterval: TimeInterval = 20
  /// At most one mentor call per this many seconds (before spend slowing).
  public var mentorMinInterval: TimeInterval = 120
  /// Triage is skipped when the screen text's line overlap with the last
  /// triaged screen of the same window is at least this (0 to 1).
  public var triageSimilarityThreshold: Double = 0.9

  // MARK: Mentorship contexts

  /// Hard boundary: when on, only activity the triage tier places in one of the
  /// declared contexts may reach the mentor tier.
  ///
  /// On with no context declared means nowhere is inside, so no triage,
  /// mentor or refresh call runs; a question asked of a toast still does.
  public var onlyMentorInsideContexts = false
  /// The kinds of work the user wants mentoring in, in their own words.
  public var contexts: [MentorshipContext] = []

  // MARK: Context window

  /// How far back the mentor tier's rolling window reaches.
  public var mentorWindowDuration: TimeInterval = 600
  /// Rough token budget for the rolling window's text.
  public var mentorWindowTokenBudget = 6000
  /// Whether the latest kept thumbnail is sent to the mentor tier as an image.
  public var sendThumbnail = true

  // MARK: Understanding

  /// How much active use the understanding may go unrefreshed before a refresh
  /// call of its own is made.
  ///
  /// Mentor calls refresh it on the way past, so this only fires in a stretch
  /// with no mentor call. Raise it to spend less.
  public var understandingRefreshInterval: TimeInterval = 900
  /// Rough token budget for the whole understanding.
  ///
  /// It is trimmed to fit, oldest first, so it can never grow without bound.
  /// Its range keeps the record inside both tiers' replies
  /// (`understandingTokenBudgetRange`).
  public var understandingTokenBudget = 1200
  /// The understanding expires after this long with no activity, and always
  /// at a new day, so a new session starts from what is actually happening.
  public var understandingIdleGap: TimeInterval = 4 * 3600

  // MARK: Delivery

  /// Suggestions under this confidence are logged but not shown.
  public var minimumConfidence = 0.6
  /// Seconds a toast stays up without interaction.
  ///
  /// The countdown pauses while the pointer is over the toast, and a suggestion
  /// brought back with Show Last Suggestion does not expire at all.
  public var toastTimeout: TimeInterval = 60
  /// How long "Not now" keeps that category quiet for that app.
  public var notNowSnooze: TimeInterval = 3600

  // MARK: Callouts and talking back

  /// Draw a callout on screen when a suggestion points at one spot.
  public var showCallouts = true
  /// Held to talk back to the current suggestion.
  ///
  /// Nil until one is recorded.
  public var pushToTalkHotKey: HotKey?

  // MARK: Spend

  /// Dollars per clock hour, across every provider.
  ///
  /// Cadence slows as spend approaches it; calls stop at it, but for a Test
  /// Connection the user asks for.
  public var hourlySpendCap = 1.0
  /// Dollars per million tokens for each model, which every call's usage is
  /// priced with toward the spend cap; edited in Settings > Models.
  public var prices = PriceTable.defaults

  // MARK: Feedback rules

  /// The Never for This rules: a category never raised again for an app.
  public var neverRules: [NeverRule] = []
  /// The Not Now snoozes: a category kept quiet for an app until a deadline.
  ///
  /// One whose deadline has passed no longer counts.
  public var snoozes: [Snooze] = []

  // MARK: Initializers

  /// Creates the default settings.
  public init() {}

  /// Clamps every value into a range the loop can operate with.
  public func validated() -> MentorSettings {
    var s = self
    if !ModelCatalog.triageChoices.contains(where: { $0.id == s.triageModel }) {
      s.triageModel = ModelSettingsDefaults.triageModel
    }
    if !ModelCatalog.mentorChoices.contains(where: { $0.id == s.mentorModel }) {
      s.mentorModel = ModelSettingsDefaults.mentorModel
    }
    if !ModelCatalog.understandingChoices.contains(where: { $0.id == s.understandingModel }) {
      s.understandingModel = ModelSettingsDefaults.understandingModel
    }
    s.triageMinInterval = s.triageMinInterval.clamped(to: 5...3600)
    s.mentorMinInterval = s.mentorMinInterval.clamped(to: 10...7200)
    s.triageSimilarityThreshold = s.triageSimilarityThreshold.clamped(to: 0.5...1)
    s.contexts = ContextRules.normalized(s.contexts)
    s.mentorWindowDuration = s.mentorWindowDuration.clamped(to: 30...7200)
    s.mentorWindowTokenBudget = s.mentorWindowTokenBudget.clamped(to: 500...60000)
    s.understandingRefreshInterval = s.understandingRefreshInterval.clamped(
      to: MentorSettings.refreshIntervalRange
    )
    s.understandingTokenBudget = s.understandingTokenBudget.clamped(
      to: MentorSettings.understandingTokenBudgetRange
    )
    s.understandingIdleGap = s.understandingIdleGap.clamped(to: MentorSettings.idleGapRange)
    s.minimumConfidence = s.minimumConfidence.clamped(to: 0...1)
    s.toastTimeout = s.toastTimeout.clamped(to: 5...600)
    s.notNowSnooze = s.notNowSnooze.clamped(to: 60...(7 * 86400))
    if let key = s.pushToTalkHotKey, !key.isUsable { s.pushToTalkHotKey = nil }
    s.hourlySpendCap = s.hourlySpendCap.clamped(to: 0.05...1000)
    s.openAIModels = s.openAIModels.validated(for: .openAI)
    s.openCodeModels = s.openCodeModels.validated(for: .openCode)
    s.prices = s.prices.validated()
    var seen = Set<String>()
    s.neverRules = s.neverRules.reversed().filter { seen.insert($0.id).inserted }.reversed()
    return s
  }

  // MARK: Convenience

  /// The provider in force's models and efforts: Anthropic's in the fields
  /// above, every other provider's in its own `TierModels`.
  public var tierModels: TierModels {
    get {
      switch provider {
      case .anthropic:
        TierModels(
          triage: triageModel,
          mentor: mentorModel,
          understanding: understandingModel,
          triageEffort: triageEffort,
          mentorEffort: mentorEffort,
          understandingEffort: understandingEffort
        )
      case .openAI: openAIModels
      case .openCode: openCodeModels
      }
    }
    set {
      switch provider {
      case .anthropic:
        triageModel = newValue.triage
        mentorModel = newValue.mentor
        understandingModel = newValue.understanding
        triageEffort = newValue.triageEffort
        mentorEffort = newValue.mentorEffort
        understandingEffort = newValue.understandingEffort
      case .openAI: openAIModels = newValue
      case .openCode: openCodeModels = newValue
      }
    }
  }

  /// The catalog entry for the provider in force's triage model.
  public var triageModelInfo: ClaudeModel { model(for: .triage) }
  /// The catalog entry for the provider in force's mentor model, which also
  /// answers follow-ups.
  public var mentorModelInfo: ClaudeModel { model(for: .mentor) }
  /// The catalog entry for the provider in force's understanding model.
  public var understandingModelInfo: ClaudeModel { model(for: .understanding) }

  /// The catalog entry for the model that makes the calls of `tier` at the
  /// provider in force, or the provider's default when its id is not in the
  /// catalog.
  public func model(for tier: ModelTier) -> ClaudeModel {
    let models = tierModels
    let id =
      switch tier {
      case .triage, .test: models.triage
      case .mentor, .followUp: models.mentor
      case .understanding: models.understanding
      }
    return ModelCatalog.model(id: id, provider: provider)
      ?? ModelCatalog.choices(for: tier, provider: provider)[0]
  }

  /// Settable range for the refresh interval.
  public static let refreshIntervalRange: ClosedRange<TimeInterval> = 300...43200

  /// Settable range for how long a record survives with no activity.
  public static let idleGapRange: ClosedRange<TimeInterval> = 600...(7 * 86400)

  /// Settable range for the token budget.
  ///
  /// The top leaves a mentor reply room for its thinking and a suggestion
  /// beside the record it carries.
  public static let understandingTokenBudgetRange: ClosedRange<Int> = 200...3000

  /// The effort to send for a tier: nil when its model rejects the parameter.
  public func effort(for tier: ModelTier) -> Effort? {
    let models = tierModels
    switch tier {
    case .triage: return triageModelInfo.supportsEffort ? models.triageEffort : nil
    case .mentor, .followUp: return mentorModelInfo.supportsEffort ? models.mentorEffort : nil
    case .understanding:
      return understandingModelInfo.supportsEffort ? models.understandingEffort : nil
    case .test: return nil
    }
  }

  // MARK: Mentorship contexts

  /// Where an activity sits relative to the declared contexts, given what
  /// triage answered. `.notEnforced` whenever the switch is off.
  public func contextPlacement(triage: TriageVerdict) -> ContextPlacement {
    guard onlyMentorInsideContexts else { return .notEnforced }
    return ContextRules.placement(triage: triage, contexts: contexts)
  }

  /// Why a category must not be raised for an app right now, if it must not.
  public func suppression(
    for category: SuggestionCategory,
    bundleID: String?,
    now: Date
  ) -> SuppressionRules.Reason? {
    SuppressionRules.reason(
      for: category,
      bundleID: bundleID,
      neverRules: neverRules,
      snoozes: snoozes,
      now: now
    )
  }

  /// Every category a Never for This rule or a live snooze keeps quiet for
  /// the app at `now`, which the mentor prompt tells the model not to raise.
  public func suppressedCategories(bundleID: String?, now: Date) -> [SuggestionCategory] {
    SuppressionRules.suppressedCategories(
      bundleID: bundleID,
      neverRules: neverRules,
      snoozes: snoozes,
      now: now
    )
  }
}

private enum ModelSettingsDefaults {
  static let triageModel = MentorSettings().triageModel
  static let mentorModel = MentorSettings().mentorModel
  static let understandingModel = MentorSettings().understandingModel
}

/// One provider's model and effort for each tier.
///
/// Anthropic's live in `MentorSettings`' own fields, where every earlier build
/// reads them; each other provider keeps one of these.
public struct TierModels: Codable, Equatable, Sendable {
  /// The id of the model that makes the triage call.
  public var triage: String
  /// The id of the model that makes mentor and follow-up calls.
  public var mentor: String
  /// The id of the model that makes the understanding's refresh calls.
  public var understanding: String
  /// The reasoning depth sent with triage calls.
  public var triageEffort: Effort
  /// The reasoning depth sent with mentor and follow-up calls.
  public var mentorEffort: Effort
  /// The reasoning depth sent with refresh calls.
  public var understandingEffort: Effort

  /// Creates a set of tier models.
  public init(
    triage: String,
    mentor: String,
    understanding: String,
    triageEffort: Effort = .low,
    mentorEffort: Effort = .medium,
    understandingEffort: Effort = .low
  ) {
    self.triage = triage
    self.mentor = mentor
    self.understanding = understanding
    self.triageEffort = triageEffort
    self.mentorEffort = mentorEffort
    self.understandingEffort = understandingEffort
  }

  /// OpenAI's: GPT-6 Luna triages, GPT-6 Sol mentors and refreshes.
  public static let openAIDefaults = TierModels(
    triage: ModelCatalog.gpt6Luna.id,
    mentor: ModelCatalog.gpt6Sol.id,
    understanding: ModelCatalog.gpt6Sol.id
  )
  /// OpenCode's: the same Claude models as Anthropic's defaults.
  public static let openCodeDefaults = TierModels(
    triage: "claude-haiku-4-5",
    mentor: "claude-opus-5",
    understanding: "claude-opus-5"
  )

  /// Each id that `provider` does not offer for its tier replaced with the
  /// provider's default.
  public func validated(for provider: ModelProvider) -> TierModels {
    let defaults = provider == .openCode ? TierModels.openCodeDefaults : .openAIDefaults
    var models = self
    func offered(_ id: String, _ tier: ModelTier) -> Bool {
      ModelCatalog.choices(for: tier, provider: provider).contains { $0.id == id }
    }
    if !offered(models.triage, .triage) { models.triage = defaults.triage }
    if !offered(models.mentor, .mentor) { models.mentor = defaults.mentor }
    if !offered(models.understanding, .understanding) {
      models.understanding = defaults.understanding
    }
    return models
  }
}
