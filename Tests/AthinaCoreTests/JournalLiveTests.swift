import Foundation
import GRDB
import Testing

@testable import AthinaCore

/// The journal's live lists, which the History window, the call log and the
/// debug panel's timeline show: each is what the journal holds, from the
/// moment it is followed and after every write since.
@Suite(.timeLimit(.minutes(1))) struct JournalLiveTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  /// A journal file, so the lists read from a pool beside the writer as the
  /// app's do.
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("athina-tests-\(UUID().uuidString)")
      .appendingPathComponent("journal.sqlite")
  }

  private func call(at time: Date) -> ModelCallRecord {
    ModelCallRecord(
      timestamp: time,
      tier: .triage,
      model: "claude-haiku-4-5-20251001",
      promptVersion: 1,
      promptCharacters: 10,
      imageBytes: 0,
      usage: Usage(inputTokens: 1, outputTokens: 1),
      cost: 0.01,
      latency: 1,
      outcome: .quiet,
      detail: nil,
      replayed: true
    )
  }

  private func suggestion(at time: Date) -> Suggestion {
    Suggestion(
      timestamp: time,
      bundleID: "com.apple.dt.Xcode",
      appName: "Xcode",
      windowTitle: nil,
      category: .shortcut,
      title: "T",
      body: "B",
      explanation: "E",
      confidence: 0.8,
      observationID: nil,
      model: "m",
      promptVersion: 1
    )
  }

  /// Takes lists from `iterator` until one satisfies `done`, and returns it.
  private func firstList<Iterator: AsyncIteratorProtocol>(
    from iterator: inout Iterator,
    where done: (Iterator.Element) -> Bool
  ) async throws -> Iterator.Element? {
    while let list = try await iterator.next() {
      if done(list) { return list }
    }
    return nil
  }

  /// The startup list race, closed.
  ///
  /// A list loaded once at launch missed the rows journaled just after the
  /// load, which the stream had already handed to a list the load then
  /// replaced. A live list is loaded once too, and then lists every row
  /// written after, so none is missed.
  @Test func aListFollowedFromLaunchListsTheRowsJournaledJustAfter() async throws {
    let journal = try Journal(url: temporaryURL())
    var calls = journal.liveModelCalls(limit: 10).makeAsyncIterator()
    let atLaunch = try await calls.next()
    #expect(atLaunch == [])
    let loadedOnce = try await journal.recentModelCalls(limit: 10)

    let first = try await journal.record(call(at: now))
    let second = try await journal.record(call(at: now + 1))

    let live = try await firstList(from: &calls) { $0.count == 2 }
    #expect(live?.map(\.id) == [second.id, first.id])
    #expect(loadedOnce.isEmpty, "the load itself is not what lists them")
  }

  /// Rows journaled from another task while the list starts, as the loop and
  /// sensing journal while the app launches, are each listed once, newest
  /// first.
  @Test func rowsJournaledWhileTheListStartsAreEachListedOnce() async throws {
    let journal = try Journal(url: temporaryURL())
    let written = Task {
      var ids: [Int64] = []
      for i in 0..<20 { ids.append(try await journal.record(suggestion(at: now + Double(i))).id) }
      return ids
    }
    var suggestions = journal.liveSuggestions(limit: 50).makeAsyncIterator()
    let ids = try await written.value
    let live = try await firstList(from: &suggestions) { $0.count == ids.count }
    #expect(live?.map(\.id) == ids.reversed())
  }

  /// The timeline's list holds both kinds of row, once each and in the
  /// journal's order, and after Clear Journal holds only the cleared event,
  /// though the journal gives new rows the ids of the ones it deleted.
  @Test func theTimelineListsEachRowOnceAndEmptiesWithTheJournal() async throws {
    let journal = try Journal(url: temporaryURL())
    var entries = journal.liveEntries(limit: 10).makeAsyncIterator()
    #expect(try await entries.next() == [])

    try await journal.record(JournalEvent(timestamp: now, kind: .started))
    try await journal.record(JournalEvent(timestamp: now, kind: .permissionsChanged))
    try await journal.record(
      JournalEvent(timestamp: now + 1, kind: .appSwitch, appName: "Safari")
    )
    let started = try await firstList(from: &entries) { $0.count == 3 }
    #expect(started?.map(\.id) == ["e3", "e2", "e1"])

    try await journal.clear(at: now + 2)
    let cleared = try await firstList(from: &entries) { $0.count == 1 }
    guard case .event(let event) = cleared?.first else {
      Issue.record("expected the cleared event, got \(String(describing: cleared))")
      return
    }
    #expect(event.kind == .journalCleared)
  }

  /// The timeline's rows carry what the debug panel lists of an observation,
  /// counted by SQLite rather than decoded.
  @Test func theTimelineSummarizesAnObservation() async throws {
    let journal = try Journal.inMemory()
    let focus = FocusContext(
      timestamp: now,
      pid: 1,
      bundleID: "com.apple.TextEdit",
      appName: "TextEdit",
      windowTitle: "notes.txt"
    )
    let block = TextBlock(text: "hello", confidence: 1, imageRect: .zero, screenRect: .zero)
    let observation = ActivityObservation(
      timestamp: now,
      focus: focus,
      frame: FrameInfo(
        hash: PerceptualHash(words: [1, 2, 3, 4]),
        width: 10,
        height: 10,
        displayID: 1,
        screenRect: .zero,
        jpeg: nil
      ),
      textBlocks: [block, block, block],
      reason: .focusChange
    )
    let stored = try await journal.record(observation)
    #expect(
      try await journal.recentEntries(limit: 5) == [.observation(ObservationSummary(stored))]
    )
  }

  /// GRDB turns write-ahead logging on as it opens a journal file, and
  /// auto_vacuum only takes on a file with no table yet, so the order is
  /// checked on the file itself.
  @Test func aJournalFileLogsAheadAndVacuumsIncrementally() async throws {
    let url = temporaryURL()
    let journal = try Journal(url: url)
    try await journal.record(JournalEvent(timestamp: now, kind: .started))
    let (mode, vacuum) = try await DatabaseQueue(path: url.path).read { db in
      (
        try String.fetchOne(db, sql: "PRAGMA journal_mode"),
        try Int.fetchOne(db, sql: "PRAGMA auto_vacuum")
      )
    }
    #expect(mode == "wal")
    #expect(vacuum == 2, "2 is INCREMENTAL")
  }
}

/// The rule feedback keeps to, which the journal holds so feedback sent from
/// the toast and the History window at once cannot break it.
@Suite struct FeedbackRuleTests {
  @Test func aNonAnswerReplacesNothingAndTellMeMoreIsRecordedOnce() {
    for feedback in SuggestionFeedback.allCases {
      #expect(feedback.replaces(nil), "\(feedback) is recorded on a suggestion with none")
    }
    for existing in SuggestionFeedback.allCases {
      #expect(!SuggestionFeedback.expired.replaces(existing))
      #expect(!SuggestionFeedback.expiredUnseen.replaces(existing))
      #expect(!SuggestionFeedback.dismissed.replaces(existing))
      #expect(SuggestionFeedback.notNow.replaces(existing))
      #expect(SuggestionFeedback.never.replaces(existing))
      #expect(SuggestionFeedback.tellMeMore.replaces(existing) == (existing != .tellMeMore))
    }
  }

  @Test func theJournalKeepsAnAnswerAFeedbackSentLaterWouldBreak() async throws {
    let journal = try Journal.inMemory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stored = try await journal.record(
      Suggestion(
        timestamp: now,
        bundleID: nil,
        appName: "Xcode",
        windowTitle: nil,
        category: .shortcut,
        title: "T",
        body: "B",
        explanation: "E",
        confidence: 0.8,
        observationID: nil,
        model: "m",
        promptVersion: 1
      )
    )
    let id = stored.id
    #expect(
      try await journal.updateFeedback(suggestionID: id, feedback: .notNow, at: now)?.feedback
        == .notNow
    )
    #expect(
      try await journal.updateFeedback(suggestionID: id, feedback: .dismissed, at: now + 1) == nil
    )
    #expect(
      try await journal.updateFeedback(suggestionID: id, feedback: .tellMeMore, at: now + 2)?
        .feedback == .tellMeMore
    )
    #expect(
      try await journal.updateFeedback(suggestionID: id, feedback: .tellMeMore, at: now + 3) == nil
    )
    let kept = try #require(try await journal.suggestion(id: id))
    #expect(kept.feedback == .tellMeMore)
    #expect(kept.feedbackAt == now + 2)
  }
}
