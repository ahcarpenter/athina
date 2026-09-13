import Foundation

/// Everything the mentor loop can be tuned with. Persisted inside
/// `settings.json` under the `mentor` key; missing fields take their defaults.
public struct MentorSettings: Codable, Equatable, Sendable {
    // MARK: Models

    /// Master switch. Off means no model call of any kind.
    public var enabled = true
    public var triageModel = ModelCatalog.haiku45.id
    public var mentorModel = ModelCatalog.opus5.id
    /// Reasoning depth per tier, sent only to models that accept it.
    public var triageEffort: Effort = .low
    public var mentorEffort: Effort = .medium

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
    /// Apps and sites Mentor must never look at. These skip triage whether or
    /// not the switch above is on, so nothing from them is ever sent.
    public var alwaysOutside: [ContextRule] = []
    /// Triage's context answer must be at least this confident to count as inside.
    public var contextConfidence = 0.6

    // MARK: Context window

    /// How far back the mentor tier's rolling window reaches.
    public var mentorWindowDuration: TimeInterval = 600
    /// Rough token budget for the rolling window's text.
    public var mentorWindowTokenBudget = 6000
    /// Whether the latest kept thumbnail is sent to the mentor tier as an image.
    public var sendThumbnail = true

    // MARK: Delivery

    /// Suggestions under this confidence are logged but not shown.
    public var minimumConfidence = 0.6
    /// Seconds a toast stays up without interaction. The countdown pauses
    /// while the pointer is over the toast, and a suggestion brought back with
    /// Show Last Suggestion does not expire at all.
    public var toastTimeout: TimeInterval = 60
    /// How long "Not now" keeps that category quiet for that app.
    public var notNowSnooze: TimeInterval = 3600

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
        case enabled, triageModel, mentorModel, triageEffort, mentorEffort
        case triageMinInterval, mentorMinInterval, triageSimilarityThreshold
        case onlyMentorInsideContexts, contexts, alwaysOutside, contextConfidence
        case mentorWindowDuration, mentorWindowTokenBudget, sendThumbnail
        case minimumConfidence, toastTimeout, notNowSnooze
        case hourlySpendCap, prices
        case neverRules, snoozes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MentorSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        triageModel = try c.decodeIfPresent(String.self, forKey: .triageModel) ?? d.triageModel
        mentorModel = try c.decodeIfPresent(String.self, forKey: .mentorModel) ?? d.mentorModel
        triageEffort = try c.decodeIfPresent(Effort.self, forKey: .triageEffort) ?? d.triageEffort
        mentorEffort = try c.decodeIfPresent(Effort.self, forKey: .mentorEffort) ?? d.mentorEffort
        triageMinInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .triageMinInterval) ?? d.triageMinInterval
        mentorMinInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .mentorMinInterval) ?? d.mentorMinInterval
        triageSimilarityThreshold = try c.decodeIfPresent(Double.self, forKey: .triageSimilarityThreshold) ?? d.triageSimilarityThreshold
        onlyMentorInsideContexts = try c.decodeIfPresent(Bool.self, forKey: .onlyMentorInsideContexts) ?? d.onlyMentorInsideContexts
        contexts = try c.decodeIfPresent([MentorshipContext].self, forKey: .contexts) ?? d.contexts
        alwaysOutside = try c.decodeIfPresent([ContextRule].self, forKey: .alwaysOutside) ?? d.alwaysOutside
        contextConfidence = try c.decodeIfPresent(Double.self, forKey: .contextConfidence) ?? d.contextConfidence
        mentorWindowDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .mentorWindowDuration) ?? d.mentorWindowDuration
        mentorWindowTokenBudget = try c.decodeIfPresent(Int.self, forKey: .mentorWindowTokenBudget) ?? d.mentorWindowTokenBudget
        sendThumbnail = try c.decodeIfPresent(Bool.self, forKey: .sendThumbnail) ?? d.sendThumbnail
        minimumConfidence = try c.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? d.minimumConfidence
        toastTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .toastTimeout) ?? d.toastTimeout
        notNowSnooze = try c.decodeIfPresent(TimeInterval.self, forKey: .notNowSnooze) ?? d.notNowSnooze
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
        s.triageMinInterval = s.triageMinInterval.clamped(to: 5...3600)
        s.mentorMinInterval = s.mentorMinInterval.clamped(to: 10...7200)
        s.triageSimilarityThreshold = s.triageSimilarityThreshold.clamped(to: 0.5...1)
        s.contexts = ContextRules.normalized(s.contexts)
        s.alwaysOutside = ContextRules.normalized(s.alwaysOutside)
        s.contextConfidence = s.contextConfidence.clamped(to: 0...1)
        s.mentorWindowDuration = s.mentorWindowDuration.clamped(to: 30...7200)
        s.mentorWindowTokenBudget = s.mentorWindowTokenBudget.clamped(to: 500...60000)
        s.minimumConfidence = s.minimumConfidence.clamped(to: 0...1)
        s.toastTimeout = s.toastTimeout.clamped(to: 5...600)
        s.notNowSnooze = s.notNowSnooze.clamped(to: 60...(7 * 86400))
        s.hourlySpendCap = s.hourlySpendCap.clamped(to: 0.05...1000)
        s.prices = s.prices.validated()
        var seen = Set<String>()
        s.neverRules = s.neverRules.reversed().filter { seen.insert($0.id).inserted }.reversed()
        return s
    }

    // MARK: Convenience

    public var triageModelInfo: ClaudeModel { ModelCatalog.model(id: triageModel) ?? ModelCatalog.haiku45 }
    public var mentorModelInfo: ClaudeModel { ModelCatalog.model(id: mentorModel) ?? ModelCatalog.opus5 }

    /// The effort to send for a tier: nil when its model rejects the parameter.
    public func effort(for tier: ModelTier) -> Effort? {
        switch tier {
        case .triage: triageModelInfo.supportsEffort ? triageEffort : nil
        case .mentor: mentorModelInfo.supportsEffort ? mentorEffort : nil
        case .test: nil
        }
    }

    // MARK: Mentorship contexts

    /// The always-outside rule matching this activity, if any. Checked whether
    /// or not enforcement is on, so an always-outside app never reaches the API.
    public func alwaysOutsideRule(matching focus: FocusContext) -> ContextRule? {
        ContextRules.alwaysOutsideRule(matching: focus, rules: alwaysOutside)
    }

    /// The declared context an always-inside rule puts this activity in, if any.
    /// Only consulted while enforcing; otherwise the contexts gate nothing.
    public func pinnedContext(for focus: FocusContext) -> (context: MentorshipContext, rule: ContextRule)? {
        guard onlyMentorInsideContexts else { return nil }
        return ContextRules.pinnedContext(for: focus, contexts: contexts)
    }

    /// Where an activity sits relative to the declared contexts, given what
    /// triage answered. `.notEnforced` whenever the switch is off.
    public func contextPlacement(for focus: FocusContext, triage: TriageVerdict) -> ContextPlacement {
        guard onlyMentorInsideContexts else { return .notEnforced }
        return ContextRules.placement(
            triage: triage,
            pinned: ContextRules.pinnedContext(for: focus, contexts: contexts),
            contexts: contexts,
            confidenceThreshold: contextConfidence
        )
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
}
