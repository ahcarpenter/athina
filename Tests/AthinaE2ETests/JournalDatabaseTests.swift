import Foundation
import AthinaCore
import Testing
@testable import AthinaE2E

/// The harness reads the journal from the outside, so a column renamed in the
/// app would break every scenario with no test failing. These run each query
/// against a journal `Journal` itself just created and migrated.
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
            let header = try #require(table.split(separator: "\n", omittingEmptySubsequences: false).first)
            #expect(header.components(separatedBy: "\t") == query.columns, "\(query.name) header")
        }
    }

    @Test func aRecordedObservationComesBackThroughTheQuery() async throws {
        let (journal, database) = try temporaryJournal()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let focus = FocusContext(
            timestamp: now, pid: 1, bundleID: "com.apple.TextEdit", appName: "TextEdit",
            windowTitle: "notes.txt", focusedRole: "AXTextArea", focusedValue: "x", focusedValueLength: 1
        )
        let frame = FrameInfo(
            hash: PerceptualHash(words: [1, 2, 3, 4]), width: 100, height: 100, displayID: 1,
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 100), jpeg: Data()
        )
        _ = try await journal.record(ActivityObservation(
            timestamp: now, focus: focus, frame: frame, textBlocks: [], reason: .focusChange
        ))

        let rows = try database.rows(JournalQueries.observations.sql)
        #expect(rows.count == 1)
        #expect(rows[0][2] == "TextEdit")
        #expect(rows[0][3] == "notes.txt")
        #expect(rows[0][4] == CaptureReason.focusChange.rawValue)
    }

    /// Which recognizer heard an answer or a question is what the speech
    /// scenarios check, so it has to come back under the column they read.
    @Test func whoHeardAnExchangeComesBackThroughTheQueries() async throws {
        let (journal, database) = try temporaryJournal()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let suggestion = try await journal.record(Suggestion(
            timestamp: now, bundleID: nil, appName: "TextEdit", windowTitle: nil, category: .shortcut,
            title: "t", body: "b", explanation: "e", confidence: 1, observationID: nil, model: "m", promptVersion: 1
        ))
        let whisper = TranscriptOrigin.heard(backend: .whisper, model: "whisper-base.en")
        _ = try await journal.updateFeedback(suggestionID: suggestion.id, feedback: .tellMeMore, at: now + 90, heardBy: whisper)
        let analyzer = TranscriptOrigin.heard(backend: .speechAnalyzer, model: "SpeechTranscriber en_US")
        _ = try await journal.record(FollowUp(
            suggestionID: suggestion.id, timestamp: now + 100, question: "why", answer: "Because.", model: "m", promptVersion: 1, heardBy: analyzer
        ))
        _ = try await journal.record(FollowUp(
            suggestionID: suggestion.id, timestamp: now + 110, question: "and then", error: "offline", model: "m", promptVersion: 1, heardBy: .typed
        ))

        func named(_ query: JournalQuery) throws -> [[String: String]] {
            try database.rows(query.sql).map { Dictionary(uniqueKeysWithValues: zip(query.columns, $0)) }
        }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let suggestions = try named(JournalQueries.suggestions)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?["feedback"] == SuggestionFeedback.tellMeMore.rawValue)
        #expect(suggestions.first?["feedback_at"] == local.string(from: now + 90))
        #expect(suggestions.first?["heard_by"] == SpeechBackendID.whisper.rawValue)

        let followUps = try named(JournalQueries.followUps)
        #expect(followUps.map { $0["question"] } == ["why", "and then"])
        #expect(followUps.map { $0["heard_by"] } == [SpeechBackendID.speechAnalyzer.rawValue, "typed"])
        #expect(followUps.map { $0["heard_by_model"] } == ["SpeechTranscriber en_US", "-"])
        #expect(followUps.map { $0["answer"] } == ["Because.", "-"])
        #expect(followUps.map { $0["error"] } == ["-", "offline"])
    }

    @Test func captureRaceReadsSwitchesAndCapturesFromTheJournal() async throws {
        let (journal, database) = try temporaryJournal()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let focus = FocusContext(
            timestamp: start, pid: 1, bundleID: "com.apple.TextEdit", appName: "TextEdit",
            windowTitle: nil, focusedRole: nil, focusedValue: nil, focusedValueLength: 0
        )
        let frame = FrameInfo(
            hash: PerceptualHash(words: [1, 2, 3, 4]), width: 100, height: 100, displayID: 1,
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 100), jpeg: Data()
        )
        try await journal.record(JournalEvent(timestamp: start, kind: .windowSwitch, appName: "TextEdit"))
        _ = try await journal.record(ActivityObservation(
            timestamp: start + 10, focus: focus, frame: frame, textBlocks: [], reason: .focusChange
        ))
        try await journal.record(JournalEvent(timestamp: start + 20, kind: .windowSwitch, appName: "TextEdit"))
        _ = try await journal.record(ActivityObservation(
            timestamp: start + 30, focus: focus, frame: frame, textBlocks: [], reason: .floor
        ))

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
