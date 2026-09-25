import AthinaCore
import Foundation
import Testing

@testable import AthinaE2E

/// The harness reads the journal from the outside, so a column renamed in the
/// app would break every scenario with no test failing.
///
/// These run each query against a journal `Journal` itself just created and
/// migrated.
@Suite struct JournalDatabaseTests {
  private func temporaryJournal() throws -> (Journal, JournalDatabase) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("athina-e2e-tests-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("journal.sqlite")
    let journal = try Journal(url: url)
    return (journal, JournalDatabase(path: url.path))
  }

  @Test func everyQueryRunsAgainstARealJournal() throws {
    let (journal, database) = try temporaryJournal()
    withExtendedLifetime(journal) {}
    for query in JournalQueries.all {
      let table = try database.table(query)
      let header = try #require(
        table.split(separator: "\n", omittingEmptySubsequences: false).first
      )
      #expect(header.components(separatedBy: "\t") == query.columns, "\(query.name) header")
    }
  }

  @Test func aRecordedObservationComesBackThroughTheQuery() async throws {
    let (journal, database) = try temporaryJournal()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let focus = FocusContext(
      timestamp: now,
      pid: 1,
      bundleID: "com.apple.TextEdit",
      appName: "TextEdit",
      windowTitle: "notes.txt",
      focusedRole: "AXTextArea",
      focusedValue: "x",
      focusedValueLength: 1
    )
    let frame = FrameInfo(
      hash: PerceptualHash(words: [1, 2, 3, 4]),
      width: 100,
      height: 100,
      displayID: 1,
      screenRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      jpeg: Data()
    )
    _ = try await journal.record(
      ActivityObservation(
        timestamp: now,
        focus: focus,
        frame: frame,
        textBlocks: [],
        reason: .focusChange
      )
    )

    let rows = try database.rows(JournalQueries.observations.sql)
    #expect(rows.count == 1)
    #expect(rows[0][2] == "TextEdit")
    #expect(rows[0][3] == "notes.txt")
    #expect(rows[0][4] == CaptureReason.focusChange.rawValue)
  }

  @Test func captureRaceReadsSwitchesAndCapturesFromTheJournal() async throws {
    let (journal, database) = try temporaryJournal()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let focus = FocusContext(
      timestamp: start,
      pid: 1,
      bundleID: "com.apple.TextEdit",
      appName: "TextEdit",
      windowTitle: nil,
      focusedRole: nil,
      focusedValue: nil,
      focusedValueLength: 0
    )
    let frame = FrameInfo(
      hash: PerceptualHash(words: [1, 2, 3, 4]),
      width: 100,
      height: 100,
      displayID: 1,
      screenRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      jpeg: Data()
    )
    try await journal.record(
      JournalEvent(timestamp: start, kind: .windowSwitch, appName: "TextEdit")
    )
    _ = try await journal.record(
      ActivityObservation(
        timestamp: start + 10,
        focus: focus,
        frame: frame,
        textBlocks: [],
        reason: .focusChange
      )
    )
    try await journal.record(
      JournalEvent(timestamp: start + 20, kind: .windowSwitch, appName: "TextEdit")
    )
    _ = try await journal.record(
      ActivityObservation(
        timestamp: start + 30,
        focus: focus,
        frame: frame,
        textBlocks: [],
        reason: .floor
      )
    )

    let (table, report) = try database.captureRace()
    #expect(report.kept == 1)
    #expect(report.dropped == 1)
    #expect(table.contains("kept"))
    #expect(table.contains("dropped"))
  }

  @Test func aMissingJournalIsAnError() {
    let database = JournalDatabase(path: "/nowhere/journal.sqlite")
    #expect(throws: JournalDatabase.Failure.self) { try database.rows("select 1") }
  }
}
