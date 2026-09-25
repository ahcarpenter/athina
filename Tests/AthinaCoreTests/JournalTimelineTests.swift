import CoreGraphics
import Foundation
import Testing

@testable import AthinaCore

@Suite struct JournalTimelineTests {
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  private func event(
    _ id: Int64,
    _ kind: JournalEvent.Kind,
    at offset: TimeInterval = 0
  ) -> JournalEntry {
    .event(
      JournalEvent(
        id: id,
        timestamp: start.addingTimeInterval(offset),
        kind: kind,
        appName: kind == .appSwitch ? "TextEdit" : nil
      )
    )
  }

  private func observation(_ id: Int64, at offset: TimeInterval) -> JournalEntry {
    let time = start.addingTimeInterval(offset)
    let focus = FocusContext(
      timestamp: time,
      pid: 7,
      bundleID: "com.apple.TextEdit",
      appName: "TextEdit"
    )
    let frame = FrameInfo(
      hash: PerceptualHash(words: [1, 2, 3, 4]),
      width: 10,
      height: 10,
      displayID: 1,
      screenRect: CGRect(x: 0, y: 0, width: 10, height: 10),
      jpeg: nil
    )
    return .observation(
      ActivityObservation(
        id: id,
        timestamp: time,
        focus: focus,
        frame: frame,
        textBlocks: [],
        reason: .inputSettled
      )
    )
  }

  /// What a launch journals as sensing starts: Started, the frontmost app and
  /// the permissions, all in one instant.
  ///
  /// AppState loads the timeline before `pipeline.start()`, so at launch these
  /// reach it on the stream alone.
  private var startup: [JournalEntry] {
    [event(1, .started), event(2, .appSwitch), event(3, .permissionsChanged)]
  }

  private func ids(_ timeline: JournalTimeline) -> [String] {
    timeline.entries.map(\.id)
  }

  // A load that overlaps the stream, as the reload after Clear Journal can:
  // the stream buffered rows, the load read some of them back, and then the
  // buffered rows were delivered. At launch the load runs first instead.
  @Test func startupRowsAppearOnceWhenTheStreamDeliversThemAfterTheLoad() {
    var timeline = JournalTimeline(limit: 300)
    timeline.merge([event(2, .appSwitch), event(1, .started)])
    for entry in startup { timeline.insert(entry) }
    timeline.insert(observation(1, at: 0.03))
    #expect(ids(timeline) == ["o1", "e3", "e2", "e1"])
  }

  @Test func startupRowsAppearOnceWhenTheLoadFinishesAfterTheStream() {
    var timeline = JournalTimeline(limit: 300)
    for entry in startup { timeline.insert(entry) }
    timeline.insert(observation(1, at: 0.03))
    timeline.merge([observation(1, at: 0.03)] + startup.reversed())
    #expect(ids(timeline) == ["o1", "e3", "e2", "e1"])
  }

  // Rows journaled while the load is still reading reach the stream first
  // and are newer than anything the load returns.
  @Test func rowsThatArriveWhileTheJournalLoadsKeepTheirPlace() {
    var timeline = JournalTimeline(limit: 300)
    timeline.insert(event(1, .started))
    timeline.insert(observation(1, at: 2))
    timeline.insert(event(4, .idleStart, at: 3))
    timeline.merge([event(1, .started)])
    #expect(ids(timeline) == ["e4", "o1", "e1"])
  }

  // Two rows of one kind can be journaled in one instant; the one stored
  // later is the newer, as the journal itself orders them.
  @Test func orderMatchesTheJournalForRowsInOneInstant() async throws {
    let journal = try Journal.inMemory()
    for kind in [JournalEvent.Kind.started, .appSwitch, .permissionsChanged] {
      _ = try await journal.record(JournalEvent(timestamp: start, kind: kind))
    }
    let loaded = try await journal.recentEntries(limit: 10)
    var timeline = JournalTimeline(limit: 10)
    for entry in loaded.reversed() { timeline.insert(entry) }
    #expect(ids(timeline) == loaded.map(\.id))
    #expect(ids(timeline) == ["e3", "e2", "e1"])
  }

  @Test func distinctRowsAreAllKept() {
    var timeline = JournalTimeline(limit: 300)
    timeline.merge([event(1, .started), event(5, .started, at: 60)])
    timeline.insert(event(6, .appSwitch, at: 61))
    #expect(ids(timeline) == ["e6", "e5", "e1"])
  }

  // Retention deleted every row while the person was away, so the journal
  // gave the next rows the ids of rows the timeline still holds.
  @Test func aRowUnderAReusedIdReplacesTheLeftoverFromTheStream() {
    var timeline = JournalTimeline(limit: 300)
    timeline.merge(startup + [observation(1, at: 1)])
    timeline.insert(event(1, .retention, at: 3600))
    timeline.insert(event(2, .idleEnd, at: 3601))
    timeline.insert(observation(1, at: 3602))
    #expect(
      timeline.entries == [
        observation(1, at: 3602),
        event(2, .idleEnd, at: 3601),
        event(1, .retention, at: 3600),
        event(3, .permissionsChanged),
      ]
    )
  }

  // A clear empties the journal, and a row from before it can still reach
  // the timeline from the stream before the journal is read back.
  @Test func aRowUnderAReusedIdReplacesTheLeftoverFromTheJournal() {
    var timeline = JournalTimeline(limit: 300)
    timeline.insert(event(1, .appSwitch, at: -60))
    timeline.merge([observation(1, at: 1), event(1, .journalCleared)])
    #expect(timeline.entries == [observation(1, at: 1), event(1, .journalCleared)])
  }

  // A row the journal failed to store carries no id of its own, so two of
  // them are two rows rather than one row seen twice.
  @Test func rowsTheJournalCouldNotStoreAreNeverMerged() {
    var timeline = JournalTimeline(limit: 300)
    timeline.insert(event(0, .appSwitch, at: 1))
    timeline.insert(event(0, .appSwitch, at: 2))
    #expect(timeline.entries.count == 2)
  }

  @Test func keepsOnlyTheNewestRowsUpToTheLimit() {
    var timeline = JournalTimeline(limit: 2)
    timeline.merge([event(1, .started), event(2, .appSwitch, at: 1)])
    timeline.insert(event(3, .idleStart, at: 2))
    #expect(ids(timeline) == ["e3", "e2"])
    timeline.merge([event(1, .started)])
    #expect(ids(timeline) == ["e3", "e2"])
  }
}
