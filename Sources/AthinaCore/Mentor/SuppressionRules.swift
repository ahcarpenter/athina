import Foundation

/// "Never for this": one category is never raised again for one app.
public struct NeverRule: Codable, Equatable, Hashable, Sendable, Identifiable {
  /// The app's bundle identifier, which the rule matches on, or nil for an
  /// app without one.
  public var bundleID: String?
  /// The app's name, for showing the rule in Settings; matching uses the
  /// bundle identifier.
  public var appName: String
  /// The category never raised again in that app.
  public var category: SuggestionCategory
  /// When the user chose Never for This.
  public var createdAt: Date

  /// Creates a rule.
  public init(bundleID: String?, appName: String, category: SuggestionCategory, createdAt: Date) {
    self.bundleID = bundleID
    self.appName = appName
    self.category = category
    self.createdAt = createdAt
  }

  /// A key of the app's lowercased bundle identifier and the category, so
  /// there is one rule per pair.
  public var id: String { "\(bundleID?.lowercased() ?? "-")|\(category.rawValue)" }
}

/// "Not now": one category stays quiet for one app until a deadline.
public struct Snooze: Codable, Equatable, Hashable, Sendable, Identifiable {
  /// The app's bundle identifier, which the snooze matches on, or nil for an
  /// app without one.
  public var bundleID: String?
  /// The app's name, kept for reading; matching uses the bundle identifier.
  public var appName: String
  /// The category kept quiet in that app.
  public var category: SuggestionCategory
  /// When the snooze ends and the category may be raised again.
  public var until: Date

  /// Creates a snooze.
  public init(bundleID: String?, appName: String, category: SuggestionCategory, until: Date) {
    self.bundleID = bundleID
    self.appName = appName
    self.category = category
    self.until = until
  }

  /// A key of the app's lowercased bundle identifier and the category, so
  /// there is one snooze per pair.
  public var id: String { "\(bundleID?.lowercased() ?? "-")|\(category.rawValue)" }
}

/// Pure matching for the two feedback rules.
///
/// Apps are matched by bundle identifier, case-insensitively; an app without
/// one matches only rules recorded without one.
public enum SuppressionRules {
  /// Why a suggestion's category is suppressed for an app.
  public enum Reason: Equatable, Sendable {
    case never(NeverRule)
    case snoozed(until: Date)

    /// A short phrase for the reason, journaled with the mentor call whose
    /// suggestion it suppressed.
    public var label: String {
      switch self {
      case .never: "never for this app"
      case .snoozed(let until): "snoozed until \(until.formatted(date: .omitted, time: .shortened))"
      }
    }
  }

  static func sameApp(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (let a?, let b?): a.caseInsensitiveCompare(b) == .orderedSame
    default: false
    }
  }

  /// Never rules win over snoozes; expired snoozes are ignored.
  public static func reason(
    for category: SuggestionCategory,
    bundleID: String?,
    neverRules: [NeverRule],
    snoozes: [Snooze],
    now: Date
  ) -> Reason? {
    if let rule = neverRules.first(where: {
      $0.category == category && sameApp($0.bundleID, bundleID)
    }) {
      return .never(rule)
    }
    if let snooze = snoozes.first(where: {
      $0.category == category && sameApp($0.bundleID, bundleID) && $0.until > now
    }) {
      return .snoozed(until: snooze.until)
    }
    return nil
  }

  /// Every category currently suppressed for the app, for the mentor prompt.
  public static func suppressedCategories(
    bundleID: String?,
    neverRules: [NeverRule],
    snoozes: [Snooze],
    now: Date
  ) -> [SuggestionCategory] {
    SuggestionCategory.allCases.filter {
      reason(for: $0, bundleID: bundleID, neverRules: neverRules, snoozes: snoozes, now: now) != nil
    }
  }

  /// Returns the snoozes that have not yet ended at `now`.
  public static func pruned(_ snoozes: [Snooze], now: Date) -> [Snooze] {
    snoozes.filter { $0.until > now }
  }

  /// Adds or replaces the rule for the same app and category.
  public static func adding(_ rule: NeverRule, to rules: [NeverRule]) -> [NeverRule] {
    rules.filter { $0.id != rule.id } + [rule]
  }

  /// Adds or extends the snooze for the same app and category, dropping expired ones.
  public static func adding(_ snooze: Snooze, to snoozes: [Snooze], now: Date) -> [Snooze] {
    pruned(snoozes, now: now).filter { $0.id != snooze.id } + [snooze]
  }
}
