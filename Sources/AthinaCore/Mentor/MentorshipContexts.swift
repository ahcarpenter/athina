import Foundation

/// One kind of work the user wants mentoring in, in their own words.
public struct MentorshipContext: Codable, Equatable, Sendable, Identifiable {
  /// The longest name kept, in characters.
  public static let maxNameLength = 60
  /// The longest detail kept, in characters.
  public static let maxDetailLength = 280

  /// A stable identity that survives renames.
  public var id: UUID
  /// A short name, for example "building web apps".
  ///
  /// Also the label the triage model answers with, so it must be unique and
  /// readable.
  public var name: String
  /// An optional longer description, sent to the triage model with the name.
  public var detail: String

  private enum CodingKeys: String, CodingKey {
    case id, name, detail
  }

  /// Creates a context, with a new id unless one is given.
  public init(id: UUID = UUID(), name: String, detail: String = "") {
    self.id = id
    self.name = name
    self.detail = detail
  }

  /// Decodes a context, filling a missing id with a new one and a missing
  /// name or detail with empty text.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
  }
}

/// Where an activity sits relative to the declared contexts.
///
/// The mentor gate turns this into a yes or no; the debug panel shows its
/// label and the menu a line of its own.
public enum ContextPlacement: Equatable, Sendable {
  /// "Only mentor inside these contexts" is off, so contexts gate nothing.
  case notEnforced
  case inside(ContextMatch)
  case outside(ContextExclusion)

  /// A short phrase for the placement, as the debug panel shows it.
  public var label: String {
    switch self {
    case .notEnforced: "not enforced"
    case .inside(let match): match.label
    case .outside(let exclusion): "outside every context (\(exclusion.label))"
    }
  }

  /// The declared context this activity was placed in, if any.
  public var contextName: String? {
    switch self {
    case .inside(let match): match.name
    case .notEnforced, .outside: nil
    }
  }

  /// The id of the declared context this activity was placed in, if any.
  public var contextID: UUID? {
    switch self {
    case .inside(let match): match.contextID
    case .notEnforced, .outside: nil
    }
  }

  /// Whether the activity was placed outside every declared context.
  public var isOutside: Bool {
    if case .outside = self { return true }
    return false
  }
}

/// An activity placed inside a declared context.
public struct ContextMatch: Equatable, Sendable {
  /// The id of the declared context the activity was placed in.
  public var contextID: UUID
  /// The context's name as declared.
  public var name: String

  /// Creates a match with a declared context.
  public init(contextID: UUID, name: String) {
    self.contextID = contextID
    self.name = name
  }

  /// The match as the menu and the debug panel show it: inside, then the
  /// name in quotes.
  public var label: String {
    "inside \"\(name)\""
  }
}

/// Why an activity is outside every declared context.
public enum ContextExclusion: Equatable, Sendable {
  /// The switch is on and no context is declared, so nothing is inside.
  case noContextsDeclared
  /// Triage named none of the declared contexts, which is also how it says
  /// it is unsure.
  case noMatch(reason: String)

  /// A short phrase for why the activity is outside, naming what triage
  /// answered when it gave a name that is not declared.
  public var label: String {
    switch self {
    case .noContextsDeclared: "no context is declared"
    case .noMatch(let reason):
      reason.isEmpty ? "triage matched no declared context" : reason
    }
  }
}

/// Pure normalizing and placement for the declared contexts.
///
/// Everything here is a function of the settings and one triage answer, so the
/// gate, the prompts, the settings editor, and the tests all see the same
/// answer.
public enum ContextRules {
  /// The most contexts kept; the settings editor offers no more.
  public static let maxContexts = 12

  // MARK: Normalizing

  /// Trims names and details, drops nameless contexts and duplicate names, and
  /// caps the count.
  ///
  /// The settings editor refuses exactly what this drops, so nothing the user
  /// saves disappears silently.
  public static func normalized(_ contexts: [MentorshipContext]) -> [MentorshipContext] {
    var seen = Set<String>()
    var out: [MentorshipContext] = []
    for context in contexts {
      var normalizedContext = context
      normalizedContext.name = trimmedAndCapped(
        singleLine(context.name),
        to: MentorshipContext.maxNameLength
      )
      normalizedContext.detail = trimmedAndCapped(
        singleLine(context.detail),
        to: MentorshipContext.maxDetailLength
      )
      guard !normalizedContext.name.isEmpty else { continue }
      guard seen.insert(normalizedContext.name.lowercased()).inserted else { continue }
      out.append(normalizedContext)
      if out.count == maxContexts { break }
    }
    return out
  }

  /// What `normalized` keeps of a name or a detail.
  public static func trimmedAndCapped(_ text: String, to limit: Int) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }

  /// Interior newlines become single spaces, so one declared context is
  /// always one line wherever it is rendered, however the editor wrapped it.
  public static func singleLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
  }

  /// The editor's as-you-type cap: text within the limit is left exactly as
  /// typed, and anything longer snaps to what `normalized` would keep, so a
  /// saved name or detail is never cut after the fact.
  public static func capped(_ text: String, to limit: Int) -> String {
    let kept = trimmedAndCapped(text, to: limit)
    return kept.count == text.trimmingCharacters(in: .whitespacesAndNewlines).count ? text : kept
  }

  // MARK: Matching

  /// Returns the declared context whose name matches `name` ignoring case,
  /// or nil when none does.
  public static func context(
    named name: String,
    in contexts: [MentorshipContext]
  ) -> MentorshipContext? {
    contexts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// Whether `name` would collide with a context other than `excluding`, which
  /// `normalized` resolves by dropping the later one.
  ///
  /// The editor asks this before saving so the user is refused rather than
  /// silently ignored.
  public static func isDuplicateName(
    _ name: String,
    in contexts: [MentorshipContext],
    excluding id: UUID?
  ) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return contexts.contains {
      $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
    }
  }

  // MARK: Placement

  /// Turns the triage answer into a placement.
  ///
  /// A name the model did not give, or gave and is not declared, is outside:
  /// enforcement fails closed.
  public static func placement(
    triage: TriageVerdict,
    contexts: [MentorshipContext]
  ) -> ContextPlacement {
    guard !contexts.isEmpty else { return .outside(.noContextsDeclared) }
    guard let name = triage.context, !name.isEmpty else {
      return .outside(.noMatch(reason: ""))
    }
    guard let context = context(named: name, in: contexts) else {
      return .outside(.noMatch(reason: "triage answered \"\(name)\", which is not declared"))
    }
    return .inside(ContextMatch(contextID: context.id, name: context.name))
  }
}
