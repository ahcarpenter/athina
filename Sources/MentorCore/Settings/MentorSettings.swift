import Foundation

/// Everything the mentor loop can be tuned with. Persisted inside
/// `settings.json` under the `mentor` key; missing fields take their defaults.
public struct MentorSettings: Codable, Equatable, Sendable {
    // MARK: Models

    /// Master switch. Off means no model call of any kind.
    public var enabled = true
    public var triageModel = ModelCatalog.haiku45.id
    public var mentorModel = ModelCatalog.opus5.id
    /// The model that rewrites the understanding on a periodic refresh. Mentor
    /// calls refresh it for free, so this one runs only in the gaps.
    public var understandingModel = ModelCatalog.opus5.id
    /// Reasoning depth per tier, sent only to models that accept it.
    public var triageEffort: Effort = .low
    public var mentorEffort: Effort = .medium
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

    /// Hard boundary: when on, only activity the triage tier places in one of
    /// the declared contexts may reach the mentor tier. On with no context
    /// declared means nowhere is inside, so no tier runs at all.
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

    /// How much active use the understanding may go unrefreshed before a
    /// refresh call of its own is made. Mentor calls refresh it on the way
    /// past, so this only fires in a stretch with no mentor call. Raise it to
    /// spend less.
    public var understandingRefreshInterval: TimeInterval = 900
    /// Rough token budget for the whole understanding. It is trimmed to fit,
    /// oldest first, so it can never grow without bound. Its range keeps the
    /// record inside both tiers' replies (`understandingTokenBudgetRange`).
    public var understandingTokenBudget = 1200
    /// The understanding expires after this long with no activity, and always
    /// at a new day, so a new session starts from what is actually happening.
    public var understandingIdleGap: TimeInterval = 4 * 3600

    // MARK: Delivery

    /// Suggestions under this confidence are logged but not shown.
    public var minimumConfidence = 0.6
    /// Seconds a toast stays up without interaction. The countdown pauses
    /// while the pointer is over the toast, and a suggestion brought back with
    /// Show Last Suggestion does not expire at all.
    public var toastTimeout: TimeInterval = 60
    /// How long "Not now" keeps that category quiet for that app.
    public var notNowSnooze: TimeInterval = 3600

    // MARK: Callouts and talking back

    /// Draw a callout on screen when a suggestion points at one spot.
    public var showCallouts = true
    /// Held to talk back to the current suggestion. Nil until one is recorded.
    public var pushToTalkHotKey: HotKey?

    // MARK: Spend

    /// Dollars per clock hour. Cadence slows as spend approaches it; calls stop at it.
    public var hourlySpendCap = 1.0
    public var prices = PriceTable.defaults

    // MARK: Feedback rules

    public var neverRules: [NeverRule] = []
    public var snoozes: [Snooze] = []

    public init() {}

    // MARK: Codable with per-field defaults

    private enum CodingKeys: String, CodingKey {
        case enabled, triageModel, mentorModel, understandingModel
        case triageEffort, mentorEffort, understandingEffort
        case triageMinInterval, mentorMinInterval, triageSimilarityThreshold
        case onlyMentorInsideContexts, contexts
        case mentorWindowDuration, mentorWindowTokenBudget, sendThumbnail
        case understandingRefreshInterval, understandingTokenBudget, understandingIdleGap
        case minimumConfidence, toastTimeout, notNowSnooze
        case showCallouts, pushToTalkHotKey
        case hourlySpendCap, prices
        case neverRules, snoozes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MentorSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        triageModel = try c.decodeIfPresent(String.self, forKey: .triageModel) ?? d.triageModel
        mentorModel = try c.decodeIfPresent(String.self, forKey: .mentorModel) ?? d.mentorModel
        understandingModel = try c.decodeIfPresent(String.self, forKey: .understandingModel) ?? d.understandingModel
        triageEffort = try c.decodeIfPresent(Effort.self, forKey: .triageEffort) ?? d.triageEffort
        mentorEffort = try c.decodeIfPresent(Effort.self, forKey: .mentorEffort) ?? d.mentorEffort
        understandingEffort = try c.decodeIfPresent(Effort.self, forKey: .understandingEffort) ?? d.understandingEffort
        triageMinInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .triageMinInterval) ?? d.triageMinInterval
        mentorMinInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .mentorMinInterval) ?? d.mentorMinInterval
        triageSimilarityThreshold = try c.decodeIfPresent(Double.self, forKey: .triageSimilarityThreshold) ?? d.triageSimilarityThreshold
        onlyMentorInsideContexts = try c.decodeIfPresent(Bool.self, forKey: .onlyMentorInsideContexts) ?? d.onlyMentorInsideContexts
        contexts = try c.decodeIfPresent([MentorshipContext].self, forKey: .contexts) ?? d.contexts
        mentorWindowDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .mentorWindowDuration) ?? d.mentorWindowDuration
        mentorWindowTokenBudget = try c.decodeIfPresent(Int.self, forKey: .mentorWindowTokenBudget) ?? d.mentorWindowTokenBudget
        sendThumbnail = try c.decodeIfPresent(Bool.self, forKey: .sendThumbnail) ?? d.sendThumbnail
        understandingRefreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .understandingRefreshInterval) ?? d.understandingRefreshInterval
        understandingTokenBudget = try c.decodeIfPresent(Int.self, forKey: .understandingTokenBudget) ?? d.understandingTokenBudget
        understandingIdleGap = try c.decodeIfPresent(TimeInterval.self, forKey: .understandingIdleGap) ?? d.understandingIdleGap
        minimumConfidence = try c.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? d.minimumConfidence
        toastTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .toastTimeout) ?? d.toastTimeout
        notNowSnooze = try c.decodeIfPresent(TimeInterval.self, forKey: .notNowSnooze) ?? d.notNowSnooze
        showCallouts = try c.decodeIfPresent(Bool.self, forKey: .showCallouts) ?? d.showCallouts
        pushToTalkHotKey = try c.decodeIfPresent(HotKey.self, forKey: .pushToTalkHotKey)
        hourlySpendCap = try c.decodeIfPresent(Double.self, forKey: .hourlySpendCap) ?? d.hourlySpendCap
        prices = try c.decodeIfPresent(PriceTable.self, forKey: .prices) ?? d.prices
        neverRules = try c.decodeIfPresent([NeverRule].self, forKey: .neverRules) ?? d.neverRules
        snoozes = try c.decodeIfPresent([Snooze].self, forKey: .snoozes) ?? d.snoozes
        self = validated()
    }

    /// Clamps every value into a range the loop can operate with.
    public func validated() -> MentorSettings {
        var s = self
        if !ModelCatalog.triageChoices.contains(where: { $0.id == s.triageModel }) { s.triageModel = ModelSettingsDefaults.triageModel }
        if !ModelCatalog.mentorChoices.contains(where: { $0.id == s.mentorModel }) { s.mentorModel = ModelSettingsDefaults.mentorModel }
        if !ModelCatalog.understandingChoices.contains(where: { $0.id == s.understandingModel }) { s.understandingModel = ModelSettingsDefaults.understandingModel }
        s.triageMinInterval = s.triageMinInterval.clamped(to: 5...3600)
        s.mentorMinInterval = s.mentorMinInterval.clamped(to: 10...7200)
        s.triageSimilarityThreshold = s.triageSimilarityThreshold.clamped(to: 0.5...1)
        s.contexts = ContextRules.normalized(s.contexts)
        s.mentorWindowDuration = s.mentorWindowDuration.clamped(to: 30...7200)
        s.mentorWindowTokenBudget = s.mentorWindowTokenBudget.clamped(to: 500...60000)
        s.understandingRefreshInterval = s.understandingRefreshInterval.clamped(to: MentorSettings.refreshIntervalRange)
        s.understandingTokenBudget = s.understandingTokenBudget.clamped(to: MentorSettings.understandingTokenBudgetRange)
        s.understandingIdleGap = s.understandingIdleGap.clamped(to: 600...(7 * 86400))
        s.minimumConfidence = s.minimumConfidence.clamped(to: 0...1)
        s.toastTimeout = s.toastTimeout.clamped(to: 5...600)
        s.notNowSnooze = s.notNowSnooze.clamped(to: 60...(7 * 86400))
        if let key = s.pushToTalkHotKey, !key.isUsable { s.pushToTalkHotKey = nil }
        s.hourlySpendCap = s.hourlySpendCap.clamped(to: 0.05...1000)
        s.prices = s.prices.validated()
        var seen = Set<String>()
        s.neverRules = s.neverRules.reversed().filter { seen.insert($0.id).inserted }.reversed()
        return s
    }

    // MARK: Convenience

    public var triageModelInfo: ClaudeModel { ModelCatalog.model(id: triageModel) ?? ModelCatalog.haiku45 }
    public var mentorModelInfo: ClaudeModel { ModelCatalog.model(id: mentorModel) ?? ModelCatalog.opus5 }
    public var understandingModelInfo: ClaudeModel { ModelCatalog.model(id: understandingModel) ?? ModelCatalog.opus5 }

    /// Settable range for the refresh interval.
    public static let refreshIntervalRange: ClosedRange<TimeInterval> = 300...43200

    /// Settable range for the token budget. The top leaves a mentor reply room
    /// for its thinking and a suggestion beside the record it carries.
    public static let understandingTokenBudgetRange: ClosedRange<Int> = 200...3000

    /// The effort to send for a tier: nil when its model rejects the parameter.
    public func effort(for tier: ModelTier) -> Effort? {
        switch tier {
        case .triage: triageModelInfo.supportsEffort ? triageEffort : nil
        case .mentor, .followUp: mentorModelInfo.supportsEffort ? mentorEffort : nil
        case .understanding: understandingModelInfo.supportsEffort ? understandingEffort : nil
        case .test: nil
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
    public func suppression(for category: SuggestionCategory, bundleID: String?, now: Date) -> SuppressionRules.Reason? {
        SuppressionRules.reason(for: category, bundleID: bundleID, neverRules: neverRules, snoozes: snoozes, now: now)
    }

    public func suppressedCategories(bundleID: String?, now: Date) -> [SuggestionCategory] {
        SuppressionRules.suppressedCategories(bundleID: bundleID, neverRules: neverRules, snoozes: snoozes, now: now)
    }
}

private enum ModelSettingsDefaults {
    static let triageModel = MentorSettings().triageModel
    static let mentorModel = MentorSettings().mentorModel
    static let understandingModel = MentorSettings().understandingModel
}
