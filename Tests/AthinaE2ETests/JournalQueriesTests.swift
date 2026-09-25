import Foundation
import Testing

@testable import AthinaE2E

@Suite struct JournalQueriesTests {
  @Test func everyQueryIsNamedOnce() {
    #expect(Set(JournalQueries.all.map(\.name)).count == JournalQueries.all.count)
    for query in JournalQueries.all {
      #expect(JournalQueries.named(query.name) == query)
    }
  }

  @Test func unknownQueryIsNil() {
    #expect(JournalQueries.named("everything") == nil)
  }

  @Test func columnCountMatchesTheSelectedFields() {
    // The column list is the harness's contract with its scenarios, so it
    // has to keep step with the SQL beside it.
    #expect(JournalQueries.suggestions.columns.count == 8)
    #expect(JournalQueries.suggestions.sql.contains("feedback_at"))
    #expect(JournalQueries.calls.columns.contains("replayed"))
    #expect(JournalQueries.observations.columns.contains("reason"))
  }

  @Test func tableEscapesTabsAndNewlinesSoOneRowIsOneLine() {
    let table = JournalQueries.table(
      columns: ["id", "title"],
      rows: [["1", "two\tcolumns\nand a line"], ["2", "plain"]]
    )
    let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3)
    #expect(lines[1] == "1\ttwo\\tcolumns\\nand a line")
    #expect(lines[0] == "id\ttitle")
  }

  @Test func parseSplitsOnTheUnitSeparator() {
    let rows = JournalQueries.parse("1\u{1f}a\n2\u{1f}b\n")
    #expect(rows == [["1", "a"], ["2", "b"]])
  }
}
