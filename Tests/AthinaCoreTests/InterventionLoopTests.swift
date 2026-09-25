import Foundation
import Testing

@testable import AthinaCore

/// The mentor loop's part in callouts and talking back: a region on a
/// suggestion, and a follow-up question as a journaled, priced model call.
@Suite(.timeLimit(.minutes(1))) struct InterventionLoopTests {
  private static let yes = #"{"worth_a_look": true, "reason": "Repeated manual runs"}"#
  private static let no = #"{"worth_a_look": false, "reason": "Reading docs"}"#

  private static func suggestion(region: String) -> String {
    #"{"reason": "Saw it", "suggestion": {"title": "Use --filter", "body": "Run one suite.", "explanation": "swift test --filter Name", "category": "shortcut", "confidence": 0.9, "region": \#(region)}}"#
  }

  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private static let inside =
    #"{"x": 100, "y": 50, "width": 200, "height": 40, "note": "this \#u{2014} command"}"#
  private static let outside = #"{"x": 1200, "y": 50, "width": 200, "height": 40, "note": "x"}"#

  private func journaledSuggestion(_ h: MentorLoopTests.Harness) async throws -> Suggestion {
    try await h.journal.record(
      Suggestion(
        timestamp: h.clock.date,
        bundleID: "com.apple.dt.Xcode",
        appName: "Xcode",
        windowTitle: "main.swift",
        category: .shortcut,
        title: "Use --filter",
        body: "Run one suite.",
        explanation: "swift test --filter Name",
        confidence: 0.9,
        observationID: nil,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version
      )
    )
  }

  @Test func aRegionInsideTheFrameReachesTheSuggestionAndTheJournal() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion(region: Self.inside), model: "claude-opus-5")
    let latest = try await h.journal.record(
      Fixtures.observation(at: h.clock.date, jpeg: Data(repeating: 1, count: 40))
    )
    await h.observe(latest, expectCalls: 2)

    guard case .text(let text) = (await h.client.sent.last?.request.messages[0].content.last) else {
      Issue.record("expected the mentor text")
      return
    }
    #expect(text.contains("1280 by 800 pixels; a region, if you give one, is in those pixels."))
    let events = await h.drain { if case .suggestion = $0 { return true } else { return false } }
    guard case .suggestion(let shown)? = events.last else {
      Issue.record("expected a suggestion event")
      return
    }
    let expected = CalloutRegion(
      rect: CGRect(x: 100, y: 50, width: 200, height: 40),
      note: "this - command"
    )
    #expect(shown.region == expected)
    #expect(try await h.journal.suggestion(id: shown.id)?.region == expected)
  }

  @Test func aRegionOutsideTheFrameIsDroppedFromTheSuggestion() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion(region: Self.outside))
    await h.observe(
      Fixtures.observation(id: 1, at: h.clock.date, jpeg: Data(repeating: 1, count: 40)),
      expectCalls: 2
    )
    let events = await h.drain { if case .suggestion = $0 { return true } else { return false } }
    guard case .suggestion(let shown)? = events.last else {
      Issue.record("expected a suggestion event")
      return
    }
    #expect(shown.region == nil)
    #expect(shown.title == "Use --filter")
  }

  @Test func aRegionWithoutAnImageIsDroppedAndTheModelIsToldToLeaveItNull() async throws {
    var settings = MentorSettings()
    settings.sendThumbnail = false
    let h = try await MentorLoopTests.Harness(settings: settings)
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion(region: Self.inside))
    await h.observe(
      Fixtures.observation(id: 1, at: h.clock.date, jpeg: Data(repeating: 1, count: 40)),
      expectCalls: 2
    )
    guard case .text(let text) = (await h.client.sent.last?.request.messages[0].content.last) else {
      Issue.record("expected the mentor text")
      return
    }
    #expect(text.contains("No screenshot is attached, so leave region null."))
    let events = await h.drain { if case .suggestion = $0 { return true } else { return false } }
    guard case .suggestion(let shown)? = events.last else {
      Issue.record("expected a suggestion event")
      return
    }
    #expect(shown.region == nil)
  }

  @Test func aFollowUpIsAnsweredOnTheMentorModelJournaledAndCounted() async throws {
    var settings = MentorSettings()
    settings.mentorModel = "claude-sonnet-5"
    settings.mentorEffort = .high
    let h = try await MentorLoopTests.Harness(settings: settings)
    // One observation first, so the mode event has been consumed.
    await h.client.enqueue(json: Self.no)
    let observation = try await h.journal.record(
      Fixtures.observation(at: h.clock.date, text: "$ swift test\nall passed")
    )
    await h.observe(observation, expectCalls: 1)
    var suggestion = try await journaledSuggestion(h)
    suggestion.observationID = observation.id
    let earlier = try await h.journal.record(
      FollowUp(
        suggestionID: suggestion.id,
        timestamp: t0 - 30,
        question: "which suite",
        answer: "That one.",
        model: "m",
        promptVersion: 5
      )
    )
    await h.client.enqueue(
      json: #"{"answer": "Yes \#u{2014} tag them and filter on the tag."}"#,
      model: "claude-sonnet-5",
      usage: Usage(
        inputTokens: 900,
        outputTokens: 80,
        cacheCreationInputTokens: 0,
        cacheReadInputTokens: 300
      )
    )
    let before = await h.loop.currentStatus()

    let followUp = try #require(
      await h.loop.askFollowUp(about: suggestion, question: "does that work with tags", at: t0)
    )
    #expect(followUp.id > 0)
    #expect(followUp.timestamp == t0)
    #expect(followUp.suggestionID == suggestion.id)
    #expect(followUp.question == "does that work with tags")
    #expect(followUp.answer == "Yes - tag them and filter on the tag.")
    #expect(followUp.error == nil)
    #expect(followUp.model == "claude-sonnet-5")
    #expect(followUp.promptVersion == MentorPrompts.version)

    let request = try #require(await h.client.sent.last?.request)
    #expect(request.model == "claude-sonnet-5")
    #expect(request.maxTokens == MentorLoop.followUpMaxTokens)
    #expect(request.system.first?.text == MentorPrompts.followUpSystem)
    #expect(request.system.first?.cacheControl == .ephemeral)
    #expect(request.outputConfig?.format?.schema == MentorPrompts.followUpSchema)
    #expect(request.outputConfig?.effort == .high)
    #expect(request.imageByteCount == 0)
    guard case .text(let text) = request.messages[0].content[0] else {
      Issue.record("expected text")
      return
    }
    #expect(text.contains("Title: Use --filter"))
    #expect(text.contains("all passed"))
    #expect(text.contains("User: which suite\nYou: That one."))
    #expect(text.hasSuffix("\"does that work with tags\""))

    #expect(try await h.journal.followUps(suggestionID: suggestion.id) == [earlier, followUp])
    let call = try #require(try await h.journal.recentModelCalls(limit: 1).first)
    #expect(call.tier == .followUp)
    #expect(call.outcome == .answered)
    #expect(call.detail == "Yes - tag them and filter on the tag.")
    #expect(call.usage.inputTokens == 900)
    let expectedCost = PriceTable.defaults.cost(of: call.usage, model: "claude-sonnet-5")!
    #expect(abs(call.cost - expectedCost) < 1e-9)
    let after = await h.loop.currentStatus()
    #expect(after.callsThisHour == before.callsThisHour + 1)
    #expect(after.spendThisHour > before.spendThisHour)
    #expect(try await h.journal.recentEvents(limit: 1).first?.kind == .talkBack)
    #expect(
      try await h.journal.recentEvents(limit: 1).first?.detail == "\"does that work with tags\""
    )
    let events = await h.drain { if case .followUp = $0 { return true } else { return false } }
    guard case .followUp(let published)? = events.last else {
      Issue.record("expected a follow-up event")
      return
    }
    #expect(published == followUp)
  }

  @Test func aHeldFollowUpIsJournaledWithTheReasonAndNeverSent() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.enqueue(json: Self.no)
    await h.observe(Fixtures.observation(at: h.clock.date), expectCalls: 1)
    let suggestion = try await journaledSuggestion(h)
    h.input.yield(.modeChanged(.paused))
    // Wait for the pause to be consumed: a later observation is held for it.
    await h.observe(
      Fixtures.observation(id: 2, at: h.clock.date, window: "b", text: "b"),
      expectCalls: 1
    )
    #expect(await h.loop.currentStatus().lastGate?.hold == .paused)

    let followUp = try #require(
      await h.loop.askFollowUp(about: suggestion, question: "why", at: t0)
    )
    #expect(followUp.answer == nil)
    #expect(followUp.error == "paused")
    #expect(await h.client.sent.count == 1)
    #expect(try await h.journal.followUps(suggestionID: suggestion.id) == [followUp])
    #expect(try await h.journal.recentEvents(limit: 1).first?.detail == "\"why\" (paused)")
    #expect(try await h.journal.recentModelCalls(limit: 5).count == 1)
  }

  @Test func aFailedFollowUpCallIsRecordedAsAnError() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.enqueue(json: Self.no)
    await h.observe(Fixtures.observation(at: h.clock.date), expectCalls: 1)
    let suggestion = try await journaledSuggestion(h)
    await h.client.enqueue(
      .failure(.api(status: 529, type: "overloaded_error", message: "Overloaded"))
    )
    let failed = try #require(await h.loop.askFollowUp(about: suggestion, question: "why"))
    #expect(failed.error == "overloaded_error (HTTP 529): Overloaded")
    #expect(try await h.journal.recentModelCalls(limit: 1).first?.outcome == .error)

    await h.client.enqueue(json: "not json")
    let garbage = try #require(await h.loop.askFollowUp(about: suggestion, question: "again"))
    #expect(garbage.error == "could not parse the follow-up reply")

    await h.client.enqueue(json: #"{"answer": " \n "}"#)
    let empty = try #require(await h.loop.askFollowUp(about: suggestion, question: "once more"))
    #expect(empty.answer == nil)
    #expect(empty.error == "the follow-up reply had an empty answer")
    #expect(try await h.journal.recentModelCalls(limit: 1).first?.outcome == .error)
    #expect(
      try await h.journal.recentEvents(limit: 1).first?.detail
        == "\"once more\" (the follow-up reply had an empty answer)"
    )
    #expect(try await h.journal.followUps(suggestionID: suggestion.id).count == 3)
  }

  private func isSuggestion(_ event: MentorEvent) -> Bool {
    if case .suggestion = event { return true } else { return false }
  }

  /// The captain's sequence: S1 is up and being talked to, S2 arrives from
  /// a mentor call that was already under way, the answer lands. S2 never
  /// replaces S1 while it is up; it is shown once S1 is closed, which is
  /// when the app tells the loop the exchange ended.
  @Test func aSuggestionThatArrivesMidExchangeWaitsUntilTheTalkedToToastCloses() async throws {
    let h = try await MentorLoopTests.Harness()
    let s1 = try await journaledSuggestion(h)
    await h.loop.setTalkingBack(true)

    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion(region: "null"))
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 2)
    let s2 = try #require(try await h.journal.recentSuggestions(limit: 1).first)
    #expect(s2.id != s1.id)
    #expect(s2.title == "Use --filter")

    await h.client.enqueue(json: #"{"answer": "Line 12."}"#)
    let followUp = try #require(await h.loop.askFollowUp(about: s1, question: "which line", at: t0))
    #expect(followUp.answer == "Line 12.")

    #expect(try await h.journal.suggestion(id: s2.id)?.feedback == nil)

    await h.loop.setTalkingBack(false)
    // One pass over everything published: S2 appears once, and only after the answer did.
    let events = await h.drain(until: isSuggestion)
    let answered = events.firstIndex {
      if case .followUp = $0 { return true } else { return false }
    }
    let shownAt = events.firstIndex(where: isSuggestion)
    #expect(events.filter(isSuggestion).count == 1)
    guard let answered, let shownAt, case .suggestion(let shown) = events[shownAt] else {
      Issue.record("expected the answer, then the held suggestion once the exchange ended")
      return
    }
    #expect(answered < shownAt)
    #expect(shown.id == s2.id)
    #expect(try await h.journal.suggestion(id: s2.id)?.feedback == nil)
  }

  @Test func aHeldSuggestionThatOutlivedTheExchangeExpiresUnseen() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.loop.setTalkingBack(true)
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion(region: "null"))
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 2)
    let held = try #require(try await h.journal.recentSuggestions(limit: 1).first)

    // The exchange outlasts the staleness bound before the toast closes.
    h.clock.advance(by: .seconds(MentorScheduler.maxObservationAge + 1))
    await h.loop.setTalkingBack(false)
    let events = await h.drain { if case .feedback = $0 { return true } else { return false } }
    #expect(!events.contains(where: isSuggestion))
    guard case .feedback(let expired)? = events.last else {
      Issue.record("expected the held suggestion to expire")
      return
    }
    #expect(expired.id == held.id)
    #expect(expired.feedback == .expiredUnseen)
    #expect(try await h.journal.suggestion(id: held.id)?.feedback == .expiredUnseen)
    #expect(
      try await h.journal.recentEvents(limit: 1).first?.detail
        == "Expired, never shown: Use --filter"
    )
  }

  @Test func pausingExpiresAHeldSuggestionInsteadOfShowingIt() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.loop.setTalkingBack(true)
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion(region: "null"))
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 2)
    let held = try #require(try await h.journal.recentSuggestions(limit: 1).first)

    h.input.yield(.modeChanged(.paused))
    let events = await h.drain { if case .feedback = $0 { return true } else { return false } }
    #expect(!events.contains(where: isSuggestion))
    guard case .feedback(let expired)? = events.last else {
      Issue.record("expected the held suggestion to expire on pause")
      return
    }
    #expect(expired.id == held.id)
    #expect(expired.feedback == .expiredUnseen)
    #expect(
      try await h.journal.recentEvents(limit: 1).first?.detail
        == "Expired, never shown: Use --filter"
    )
    // Nothing is left to show when the talked-to toast closes.
    await h.loop.setTalkingBack(false)
    #expect(try await h.journal.suggestion(id: held.id)?.feedback == .expiredUnseen)
  }

  /// A question released while a call is in flight is not refused: it waits
  /// for that call to return, is then asked, and is journaled as an error
  /// only if its own call fails.
  @Test func aQuestionAskedDuringACallWaitsForItAndIsThenAnswered() async throws {
    let h = try await MentorLoopTests.Harness()
    let suggestion = try await journaledSuggestion(h)
    await h.client.setDelay(.milliseconds(400))
    await h.client.enqueue(json: Self.no)
    await h.client.enqueue(json: #"{"answer": "After the call."}"#)
    h.input.yield(.observation(Fixtures.observation(id: 1, at: h.clock.date)))
    // Triage is held in flight until the clock moves past its delay.
    await h.clock.waitForSleepers()
    #expect(await h.loop.currentStatus().inFlight == .triage)

    let asked = Task { await h.loop.askFollowUp(about: suggestion, question: "which line", at: t0) }
    await h.waitUntil { $0.pendingFollowUp != nil }
    let pending = try #require(await h.loop.currentStatus().pendingFollowUp)
    #expect(pending.question == "which line")
    #expect(pending.suggestionID == suggestion.id)
    #expect(pending.since == t0)
    #expect(await h.client.sent.map(\.call.kind) == ["triage"])

    // Triage returns, and the question it held is asked.
    h.clock.advance(by: .milliseconds(400))
    await h.clock.waitForSleepers()
    #expect(await h.client.sent.map(\.call.kind) == ["triage", "followUp"])
    h.clock.advance(by: .milliseconds(400))
    let followUp = try #require(await asked.value)
    #expect(followUp.answer == "After the call.")
    #expect(followUp.error == nil)
    #expect(await h.client.sent.map(\.call.kind) == ["triage", "followUp"])
    #expect(await h.loop.currentStatus().pendingFollowUp == nil)
    #expect(try await h.journal.followUps(suggestionID: suggestion.id) == [followUp])
    #expect(try await h.journal.recentModelCalls(limit: 2).allSatisfy { $0.outcome != .error })
  }

  @Test func aNewerWaitingQuestionReplacesTheOlderAndAWithdrawnOneIsDropped() async throws {
    let h = try await MentorLoopTests.Harness()
    let suggestion = try await journaledSuggestion(h)
    await h.client.setDelay(.milliseconds(400))
    await h.client.enqueue(json: Self.no)
    h.input.yield(.observation(Fixtures.observation(id: 1, at: h.clock.date)))
    await h.clock.waitForSleepers()

    let older = Task { await h.loop.askFollowUp(about: suggestion, question: "first", at: t0) }
    await h.waitUntil { $0.pendingFollowUp?.question == "first" }
    let newer = Task { await h.loop.askFollowUp(about: suggestion, question: "second", at: t0 + 1) }
    #expect(await older.value == nil)
    await h.waitUntil { $0.pendingFollowUp?.question == "second" }
    #expect(await h.loop.currentStatus().pendingFollowUp?.question == "second")

    await h.loop.withdrawFollowUp()
    #expect(await newer.value == nil)
    #expect(await h.loop.currentStatus().pendingFollowUp == nil)
    h.clock.advance(by: .milliseconds(400))
    await h.waitUntil { $0.inFlight == nil && $0.lastTriage != nil }
    #expect(await h.client.sent.map(\.call.kind) == ["triage"])
    #expect(try await h.journal.followUps(suggestionID: suggestion.id).isEmpty)
    #expect(try await h.journal.recentEvents(limit: 5).allSatisfy { $0.kind != .talkBack })
  }

  /// Recorded live on 2026-09-14: Sonnet 5 answered a real risk with every
  /// text field empty. Such a reply is logged as an error and never shown.
  @Test func aSuggestionWithNoWordsIsLoggedAndNeverShown() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(
      json:
        #"{"reason": "rm -rf on an empty variable", "suggestion": {"title": "", "body": " ", "explanation": "", "category": "risk", "confidence": 0.9, "region": null}}"#
    )
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 2)
    let status = await h.loop.currentStatus()
    #expect(status.lastMentor?.outcome == .error)
    #expect(
      status.lastMentor?.detail
        == "the mentor reply had a risk suggestion with an empty title or body"
    )
    #expect(try await h.journal.recentSuggestions(limit: 5).isEmpty)
    #expect(try await h.journal.recentEvents(limit: 5).allSatisfy { $0.kind != .suggested })
    #expect(
      MentorVerdict.Payload(title: "T", body: "", explanation: "", category: .risk, confidence: 1)
        .isBlank
    )
    #expect(
      !MentorVerdict.Payload(title: "T", body: "B", explanation: "", category: .risk, confidence: 1)
        .isBlank
    )
  }

  @Test func theCalloutFlagIsPersistedThroughTheLoop() async throws {
    let h = try await MentorLoopTests.Harness()
    let suggestion = try await journaledSuggestion(h)
    #expect(suggestion.calloutShown == false)
    let shown = await h.loop.noteCalloutShown(suggestionID: suggestion.id)
    #expect(shown?.calloutShown == true)
    #expect(try await h.journal.suggestion(id: suggestion.id)?.calloutShown == true)
    #expect(await h.loop.noteCalloutShown(suggestionID: 404) == nil)
  }
}

/// The committed replay fixtures carry this phase's two new paths: a mentor
/// reply whose region places a callout, and a follow-up answer. Both run
/// through the loop the app runs, from recordings, with no network and no spend.
@Suite(.timeLimit(.minutes(1))) struct ReplayInterventionTests {
  /// The frame size the recorded mentor request told the model about.
  static func recordedFrameSize(of request: MessagesRequest) -> (width: Int, height: Int)? {
    for message in request.messages {
      for block in message.content {
        guard case .text(let text) = block,
          let match = text.firstMatch(of: /latest screen, (\d+) by (\d+) pixels/),
          let width = Int(match.1), let height = Int(match.2)
        else { continue }
        return (width, height)
      }
    }
    return nil
  }

  private struct RegionFixture {
    var triage: ReplayClaudeClient.Entry
    var mentor: ReplayClaudeClient.Entry
    var payload: MentorVerdict.Payload
    var region: MentorVerdict.Payload.Region
    var frame: (width: Int, height: Int)
  }

  /// The first shown mentor recording with a region, the triage recording
  /// that sent a moment to the mentor, and the frame the region is in.
  private static func regionFixture(in entries: [ReplayClaudeClient.Entry]) throws -> RegionFixture
  {
    let triage = try #require(
      entries.first { entry in
        entry.fixture.identity.kind == ModelTier.triage.rawValue
          && ((try? entry.fixture.result.get()).flatMap {
            MentorLoop.decode(TriageVerdict.self, from: $0)
          }?.worthALook ?? false)
      },
      "a triage recording must send a moment to the mentor"
    )
    for entry in entries where entry.fixture.identity.kind == ModelTier.mentor.rawValue {
      guard let response = try? entry.fixture.result.get(),
        let verdict = MentorLoop.decode(MentorVerdict.self, from: response),
        let payload = verdict.suggestion, payload.confidence >= MentorSettings().minimumConfidence,
        let region = payload.region,
        let frame = recordedFrameSize(of: entry.fixture.request)
      else { continue }
      return RegionFixture(
        triage: triage,
        mentor: entry,
        payload: payload,
        region: region,
        frame: frame
      )
    }
    throw MissingFixture(
      description:
        "a shown mentor recording must carry a region, recorded from a request that states its frame size"
    )
  }

  private struct MissingFixture: Error, CustomStringConvertible {
    var description: String
  }

  @Test func theCommittedFixturesCarryARegionInsideItsFrameAndAFollowUpAnswer() throws {
    let client = try ReplayClaudeClient.load(from: try ReplayLoopTests.committedFixturesDirectory())
    let fixture = try Self.regionFixture(in: client.entries)
    let frame = FrameInfo(
      hash: PerceptualHash(words: [0, 0, 0, 0]),
      width: fixture.frame.width,
      height: fixture.frame.height,
      displayID: 1,
      screenRect: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      jpeg: nil
    )
    #expect(
      CalloutAnchor.screenRect(for: fixture.region.rect, in: frame) != nil,
      "the recorded region must lie inside the recorded frame"
    )
    #expect(!fixture.region.note.trimmingCharacters(in: .whitespaces).isEmpty)

    let answers = client.entries.filter { $0.fixture.identity.kind == ModelTier.followUp.rawValue }
      .compactMap { entry in
        (try? entry.fixture.result.get()).flatMap {
          MentorLoop.decode(FollowUpReply.self, from: $0)
        }
      }
    #expect(answers.contains { !$0.answer.isEmpty }, "a follow-up recording must carry an answer")
  }

  @Test func aReplayedRegionPlacesACalloutAndAReplayedFollowUpIsAnswered() async throws {
    let committed = try ReplayClaudeClient.load(
      from: try ReplayLoopTests.committedFixturesDirectory()
    )
    let fixture = try Self.regionFixture(in: committed.entries)
    let followUps = committed.entries.filter {
      $0.fixture.identity.kind == ModelTier.followUp.rawValue
    }
    let recordedAnswer = try #require(
      followUps.first.flatMap {
        (try? $0.fixture.result.get()).flatMap { MentorLoop.decode(FollowUpReply.self, from: $0) }
      }
    )
    // Only what this path needs, in the order it needs it.
    let client = ReplayClaudeClient(entries: [fixture.triage, fixture.mentor] + followUps)

    let journal = try Journal.inMemory()
    let clock = AdjustableClock(startingAt: MentorLoopTests.Harness.start)
    let (stream, input) = AsyncStream<SensingEvent>.makeStream()
    let loop = MentorLoop(
      settings: MentorSettings(),
      journal: journal,
      client: client,
      keyStore: InMemoryKeyStore(),
      events: stream,
      clock: clock,
      calendar: MentorLoopTests.calendar
    )
    let output = await loop.events()
    await loop.start()
    input.yield(.modeChanged(.watching))

    // A screen like the recorded one: the display the frame shows, the
    // window filling it, and the screenshot sent to the mentor tier.
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    var observation = try await journal.record(
      Fixtures.observation(at: clock.date, jpeg: Data(repeating: 1, count: 64))
    )
    observation.frame.width = fixture.frame.width
    observation.frame.height = fixture.frame.height
    observation.frame.screenRect = display
    observation.focus.windowFrame = display
    input.yield(.observation(observation))

    var shown: Suggestion?
    for await event in output {
      if case .suggestion(let suggestion) = event {
        shown = suggestion
        break
      }
    }
    let suggestion = try #require(shown)
    let expectedRegion = CalloutRegion(
      rect: fixture.region.rect,
      note: fixture.region.note.withPlainDashes.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    #expect(suggestion.title == fixture.payload.title.withPlainDashes)
    #expect(suggestion.region == expectedRegion)
    #expect(try await journal.suggestion(id: suggestion.id)?.region == expectedRegion)

    // The replayed region places a callout on this screen exactly where it maps.
    let live = CalloutAnchor.Live(
      frontmostPID: observation.focus.pid,
      focus: observation.focus,
      displays: [DisplayBounds(id: 1, bounds: display)],
      now: clock.date
    )
    let placement = try CalloutAnchor.resolve(expectedRegion, for: observation, live: live).get()
    #expect(
      placement.screenRect
        == CalloutAnchor.screenRect(for: expectedRegion.rect, in: observation.frame)
    )
    #expect(placement.note == expectedRegion.note)

    // A follow-up about it is answered from the recording, journaled as a replay, and never billed.
    // A whole-second time, so the journal round trip compares equal.
    let followUp = try #require(
      await loop.askFollowUp(
        about: suggestion,
        question: "which line do you mean",
        at: Date(timeIntervalSince1970: 1_789_000_000)
      )
    )
    #expect(
      followUp.answer
        == recordedAnswer.answer.withPlainDashes.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    #expect(followUp.error == nil)
    let call = try #require(try await journal.recentModelCalls(limit: 1).first)
    #expect(call.tier == .followUp)
    #expect(call.outcome == .answered)
    #expect(call.replayed)
    #expect(call.cost == 0)
    #expect(await client.served.map(\.call.kind) == ["triage", "mentor", "followUp"])
    #expect(await loop.currentStatus().spendThisHour == 0)
    #expect(try await journal.followUps(suggestionID: suggestion.id) == [followUp])
    await loop.stop()
  }
}
