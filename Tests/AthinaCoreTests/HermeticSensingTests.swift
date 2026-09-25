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

  /// A hermetic pipeline, started, on its own journal, with the Calculator
  /// excluded.
  func startedPipeline() async throws -> (
    SensingPipeline, Journal, AsyncStream<SensingEvent>.Iterator, URL
  ) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "athina-tests-\(UUID().uuidString)"
    )
    let journal = try Journal(url: directory.appendingPathComponent("journal.sqlite"))
    let clock = AdjustableClock(startingAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    var settings = SensingSettings()
    settings.excludedBundleIDs = ["com.apple.calculator"]
    let pipeline = SensingPipeline(
      settings: settings,
      journal: journal,
      tracker: FocusTracker(clock: clock),
      clock: clock,
      source: .hermetic
    )
    var events = await pipeline.events().makeAsyncIterator()
    await pipeline.start()
    _ = await read(&events, until: isMode(.watching))
    return (pipeline, journal, events, directory)
  }

  let notes = ScriptedObservation(
    appName: "TextEdit",
    bundleID: "com.apple.TextEdit",
    windowTitle: "notes.txt",
    text: "Reading notes\n\n  chapter one  \nchapter two"
  )

  @Test func aScriptedWindowIsJournaledAsACaptureOfItIs() async throws {
    let (pipeline, journal, _, directory) = try await startedPipeline()
    defer { try? FileManager.default.removeItem(at: directory) }

    guard case .kept(let first) = await pipeline.observe(notes) else {
      Issue.record("the first scripted window was not kept")
      return
    }
    #expect(first.reason == .focusChange)
    #expect(first.focus.appName == "TextEdit")
    #expect(first.focus.windowTitle == "notes.txt")
    #expect(first.focus.focusedValue == notes.text)
    #expect(first.textBlocks.map(\.text) == ["Reading notes", "chapter one", "chapter two"])
    #expect(first.frame.jpeg != nil)
    // Each line is where it was drawn, one under the other.
    let tops = first.textBlocks.map(\.imageRect.minY)
    #expect(tops == tops.sorted())
    #expect(first.textBlocks.allSatisfy { ScriptedObservation.display.contains($0.screenRect) })

    // The same window showing the same text again is a near duplicate.
    guard case .notKept = await pipeline.observe(notes) else {
      Issue.record("the same frame again was kept")
      return
    }
    // The same window with new text is kept as a capture after typing.
    var edited = notes
    edited.text += "\nchapter three"
    guard case .kept(let second) = await pipeline.observe(edited) else {
      Issue.record("the edited window was not kept")
      return
    }
    #expect(second.reason == .inputSettled)

    var plan = notes
    plan.windowTitle = "plan.txt"
    guard case .kept(let third) = await pipeline.observe(plan) else {
      Issue.record("another window was not kept")
      return
    }
    #expect(third.reason == .focusChange)
    await pipeline.stop()

    let kinds = try await journal.recentEvents(limit: 20).map(\.kind)
    #expect(kinds.filter { $0 == .appSwitch }.count == 1)
    #expect(kinds.filter { $0 == .windowSwitch }.count == 1)
    #expect(try await journal.recentObservations(limit: 10).count == 3)
  }

  @Test func anExcludedAppIsReadNoFurtherThanItsName() async throws {
    var (pipeline, journal, events, directory) = try await startedPipeline()
    defer { try? FileManager.default.removeItem(at: directory) }

    let calculator = ScriptedObservation(
      appName: "Calculator",
      bundleID: "com.apple.calculator",
      windowTitle: "Calculator",
      text: "42"
    )
    guard case .notKept = await pipeline.observe(calculator) else {
      Issue.record("an excluded app was captured")
      return
    }
    _ = await read(&events, until: isMode(.excluded))
    guard case .kept = await pipeline.observe(notes) else {
      Issue.record("the window after the excluded app was not kept")
      return
    }
    _ = await read(&events, until: isMode(.watching))
    await pipeline.stop()

    let journaled = try await journal.recentEvents(limit: 20)
    #expect(journaled.contains { $0.kind == .excluded && $0.appName == "Calculator" })
    let observations = try await journal.recentObservations(limit: 10)
    #expect(observations.map(\.focus.appName) == ["TextEdit"])
  }

  @Test func scriptedIdleCapturesNothingUntilInputComesBack() async throws {
    var (pipeline, journal, events, directory) = try await startedPipeline()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(await pipeline.setScriptedIdle(true))
    _ = await read(&events, until: isMode(.idle))
    guard case .notKept(let why) = await pipeline.observe(notes) else {
      Issue.record("a window was captured while idle")
      return
    }
    #expect(why.contains("idle"))
    #expect(await pipeline.setScriptedIdle(false))
    _ = await read(&events, until: isMode(.watching))
    guard case .kept = await pipeline.observe(notes) else {
      Issue.record("the window was not kept once input came back")
      return
    }
    await pipeline.stop()

    let kinds = try await journal.recentEvents(limit: 20).map(\.kind)
    #expect(kinds.contains(.idleStart))
    #expect(kinds.contains(.idleEnd))
  }

  @Test func aPipelineSensingTheRealMacTakesNoScript() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "athina-tests-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = AdjustableClock(startingAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    let pipeline = SensingPipeline(
      settings: SensingSettings(),
      journal: try Journal(url: directory.appendingPathComponent("journal.sqlite")),
      tracker: FocusTracker(clock: clock),
      clock: clock,
      source: .system
    )
    // Never started: a system pipeline refuses before it reads anything.
    #expect(await pipeline.observe(notes) == .notScripted)
    #expect(await pipeline.setScriptedIdle(true) == false)
  }
}
