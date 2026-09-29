import Foundation

/// The three kinds of note Athina shows, PRODUCT.md's own three: a faster way,
/// a risk the person may have missed, and a step that will not get them where
/// they are going.
///
/// The model keeps its ten categories (`SuggestionCategory`), which the prompt
/// names and the journal records; the note and its callout fold them into
/// these three, so a person learns three shapes rather than ten. Changing the
/// folding is an interface change, never a prompt change.
public enum NoteKind: String, CaseIterable, Sendable {
  case fasterWay
  case risk
  case deadEnd

  /// The kind a category is shown as.
  public init(_ category: SuggestionCategory) {
    switch category {
    case .shortcut, .workflow, .tool, .approach, .lessEfficient, .other:
      self = .fasterWay
    case .correctness, .risk, .unwantedSideEffect:
      self = .risk
    case .wontAchieveGoal:
      self = .deadEnd
    }
  }

  /// The kind's name as the note and its tile's label show it.
  public var label: String {
    switch self {
    case .fasterWay: "Faster way"
    case .risk: "Risk"
    case .deadEnd: "Dead end"
    }
  }

  /// The SF Symbol on the kind's tile.
  public var symbol: String {
    switch self {
    case .fasterWay: "hare.fill"
    case .risk: "exclamationmark.triangle.fill"
    case .deadEnd: "arrow.triangle.branch"
    }
  }
}
