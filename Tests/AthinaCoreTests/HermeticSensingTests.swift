import Foundation
import Testing

@testable import AthinaCore

/// A hermetic run's pipeline (`SensingSource.hermetic`) senses nothing real,
/// but is otherwise the pipeline a person's copy runs: it journals its start
/// and stop, watches with nothing to capture, and pauses when asked.
@Suite struct HermeticSensingTests {
  /// Reads events until one `until` accepts, and returns every one read.
  func read(
    _ events: inout AsyncStream<SensingEvent>.Iterator,
    until done: (SensingEvent) -> Bool
  ) async -> [SensingEvent] {
    var seen: [SensingEvent] = []
    while let event = await events.next() {
      seen.append(event)
      if done(event) { break }
    }
    return seen
  }

  func isMode(_ mode: SensingMode) -> (SensingEvent) -> Bool {
    { event in
      if case .modeChanged(mode) = event { return true }
      return false
    }
  }

  @Test func aHermeticPipelineWatchesWithNothingRealToSense() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "athina-tests-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try Journal(url: directory.appendingPathComponent("journal.sqlite"))
    let clock = AdjustableClock(startingAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    let pipeline = SensingPipeline(
      settings: SensingSettings(),
      journal: journal,
      tracker: FocusTracker(clock: clock),
      clock: clock,
      source: .hermetic
    )
    var events = await pipeline.events().makeAsyncIterator()

    await pipeline.start()
    // Every permission reads as granted and the person as present, with no
    // app in front and nothing captured, so it watches.
    var seen = await read(&events, until: isMode(.watching))
    await pipeline.setPaused(true)
    seen += await read(&events, until: isMode(.paused))
    await pipeline.stop()
    seen += await read(&events) { _ in false }

    let sensed = seen.filter { event in
      switch event {
      case .observation, .focusChanged: true
      case .modeChanged, .event, .cadence: false
      }
    }
    #expect(sensed.isEmpty)
    let kinds = try await journal.recentEvents(limit: 10).map(\.kind)
    #expect(Set(kinds) == [.started, .paused, .stopped])
  }
}
