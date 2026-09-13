import Foundation

/// Everything the mentor loop can be tuned with. Persisted inside
/// `settings.json` under the `mentor` key; missing fields take their defaults.
public struct MentorSettings: Codable, Equatable, Sendable {
    // MARK: Models

    /// Master switch. Off means no model call of any kind.
    public var enabled = true
    public var triageModel = ModelCatalog.haiku45.id
    public var mentorModel = ModelCatalog.fable51.id
    /// Reasoning depth for the mentor tier on models that accept it.
    public var mentorEffort: Effort = .medium

    // MARK: Cadence

    /// At most one triage call per this many seconds (before spend slowing).
    public var triageMinInterval: TimeInterval = 20
    /// At most one mentor call per this many seconds (before spend slowing).
    public var mentorMinInterval: TimeInterval = 120
    /// Triage is skipped when the screen text's line overlap with the last
    /// triaged screen of the same window is at least this (0 to 1).
    public var triageSimilarityThreshold: Double = 0.9

    // MARK: Context

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
        case enabled, triageModel, mentorModel, mentorEffort
        case triageMinInterval, mentorMinInterval, triageSimilarityThreshold
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
        mentorEffort = try c.decodeIfPresent(Effort.self, forKey: .mentorEffort) ?? d.mentorEffort
        triageMinInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .triageMinInterval) ?? d.triageMinInterval
        mentorMinInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .mentorMinInterval) ?? d.mentorMinInterval
        triageSimilarityThreshold = try c.decodeIfPresent(Double.self, forKey: .triageSimilarityThreshold) ?? d.triageSimilarityThreshold
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
        if ModelCatalog.model(id: s.triageModel) == nil { s.triageModel = ModelSettingsDefaults.triageModel }
        if ModelCatalog.model(id: s.mentorModel) == nil { s.mentorModel = ModelSettingsDefaults.mentorModel }
        s.triageMinInterval = s.triageMinInterval.clamped(to: 5...3600)
        s.mentorMinInterval = s.mentorMinInterval.clamped(to: 10...7200)
        s.triageSimilarityThreshold = s.triageSimilarityThreshold.clamped(to: 0.5...1)
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
    public var mentorModelInfo: ClaudeModel { ModelCatalog.model(id: mentorModel) ?? ModelCatalog.fable51 }

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
