import Testing

@testable import AthinaCore

@Suite struct NoteKindTests {
  @Test func everyCategoryIsShownAsOneOfTheThreeKinds() {
    let kinds = Dictionary(grouping: SuggestionCategory.allCases, by: NoteKind.init)
    #expect(kinds[.fasterWay] == [.shortcut, .workflow, .tool, .approach, .other, .lessEfficient])
    #expect(kinds[.risk] == [.correctness, .risk, .unwantedSideEffect])
    #expect(kinds[.deadEnd] == [.wontAchieveGoal])
  }

  /// A warning is never softened into a tip: each kind a category can warn
  /// with keeps its own shape.
  @Test func noWarningIsShownAsAFasterWay() {
    for category in [SuggestionCategory.correctness, .risk, .unwantedSideEffect, .wontAchieveGoal] {
      #expect(NoteKind(category) != .fasterWay, "\(category) is shown as a faster way")
    }
  }

  @Test func eachKindHasItsOwnNameAndSymbol() {
    #expect(Set(NoteKind.allCases.map(\.label)).count == NoteKind.allCases.count)
    #expect(Set(NoteKind.allCases.map(\.symbol)).count == NoteKind.allCases.count)
  }
}
