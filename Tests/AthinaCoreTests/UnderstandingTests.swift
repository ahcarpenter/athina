import Foundation
import Testing

@testable import AthinaCore

/// The understanding record itself: how it decodes what the model writes, how
/// it stays inside its budget, how it renders into a prompt, and when it expires.
@Suite struct UnderstandingTests {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func sample(goals: Int = 2, timeline: Int = 3) -> Understanding {
    Understanding(
      goals: (0..<goals).map {
        Understanding.Goal(
          goal: "goal \($0)",
          evidence: "evidence \($0)",
          confidence: 0.9 - Double($0) / 10
        )
      },
      timeline: (0..<timeline).map { "happened \($0)" },
      mentorHistory: ["said something, they answered not now"],
      openConcerns: ["a concern"]
    )
  }

  // MARK: Encoding

  @Test func decodesWhatTheModelWritesWithSnakeCaseKeys() throws {
    let json = """
      {"goals": [{"goal": "ship the feature", "evidence": "two hours in the same file", \
      "confidence": 0.8}],
       "timeline": ["opened the editor"], "mentor_history": ["suggested a filter"], \
      "open_concerns": ["no tests yet"]}
      """
    let decoded = try JSONDecoder().decode(Understanding.self, from: Data(json.utf8))
    #expect(decoded.goals.count == 1)
    #expect(decoded.goals.first?.goal == "ship the feature")
    #expect(decoded.goals.first?.confidence == 0.8)
    #expect(decoded.timeline == ["opened the editor"])
    #expect(decoded.mentorHistory == ["suggested a filter"])
    #expect(decoded.openConcerns == ["no tests yet"])
  }

  @Test func roundTripsThroughItsOwnEncoding() throws {
    let original = sample()
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(Understanding.self, from: data) == original)
  }

  @Test func decodesARecordThatOmitsFields() throws {
    let decoded = try JSONDecoder().decode(Understanding.self, from: Data(#"{"goals": []}"#.utf8))
    #expect(decoded.isEmpty)
    #expect(decoded.timeline.isEmpty)
  }

  @Test func decodeDropsBlanksAndSortsGoalsStrongestFirst() throws {
    let json = """
      {"goals": [{"goal": "weak", "evidence": "", "confidence": 0.2},
                 {"goal": "strong", "evidence": "e", "confidence": 0.9},
                 {"goal": "   ", "evidence": "e", "confidence": 0.5}],
       "timeline": ["kept", "  ", ""], "mentor_history": [], "open_concerns": []}
      """
    let decoded = try JSONDecoder().decode(Understanding.self, from: Data(json.utf8))
    #expect(decoded.goals.map(\.goal) == ["strong", "weak"])
    #expect(decoded.primaryGoal?.goal == "strong")
    #expect(decoded.timeline == ["kept"])
  }

  /// A goal's text is its identity in the debug panel, so two goals with
  /// the same text collapse into the stronger one.
  @Test func normalizedDropsDuplicateGoalsKeepingTheStrongest() {
    let understanding = Understanding(goals: [
      Understanding.Goal(goal: "ship it", evidence: "weak", confidence: 0.3),
      Understanding.Goal(goal: "ship it ", evidence: "strong", confidence: 0.9),
      Understanding.Goal(goal: "other", evidence: "e", confidence: 0.5),
    ]).normalized()
    #expect(understanding.goals.map(\.goal) == ["ship it", "other"])
    #expect(understanding.goals.first?.evidence == "strong")
    #expect(Set(understanding.goals.map(\.id)).count == understanding.goals.count)
  }

  @Test func decodeClampsConfidenceAndReplacesEmDashes() throws {
    let json = """
      {"goals": [{"goal": "ship \u{2014} soon", "evidence": "a \u{2013} b", "confidence": 4}],
       "timeline": ["did \u{2014} something"], "mentor_history": [], "open_concerns": []}
      """
    let decoded = try JSONDecoder().decode(Understanding.self, from: Data(json.utf8))
    let goal = try #require(decoded.goals.first)
    #expect(goal.confidence == 1)
    #expect(!goal.goal.contains("\u{2014}"))
    #expect(!goal.evidence.contains("\u{2013}"))
    #expect(!decoded.timeline[0].contains("\u{2014}"))
  }

  @Test func recordRoundTripsThroughJSONWithItsVersioning() throws {
    let record = UnderstandingRecord.first(
      content: sample(),
      at: t0,
      model: "claude-opus-5",
      source: .periodic,
      cost: 0.03,
      promptVersion: MentorPrompts.version
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(UnderstandingRecord.self, from: data)
    #expect(decoded == record)
    #expect(decoded.promptVersion == MentorPrompts.version)
    #expect(decoded.revision == 1)
  }

  // MARK: Revisions

  @Test func revisionsCarryTheRunForwardAndAccumulateCost() {
    let first = UnderstandingRecord.first(
      content: sample(),
      at: t0,
      model: "claude-opus-5",
      source: .periodic,
      cost: 0.03,
      promptVersion: 4
    )
    let second = first.next(
      content: sample(goals: 1),
      at: t0.addingTimeInterval(900),
      model: "claude-opus-5",
      source: .mentorCall,
      cost: 0,
      promptVersion: 4
    )
    #expect(second.revision == 2)
    #expect(second.startedAt == first.startedAt)
    #expect(second.cost == 0)
    #expect(second.cumulativeCost == 0.03)

    let third = second.next(
      content: sample(),
      at: t0.addingTimeInterval(1800),
      model: "claude-opus-5",
      source: .periodic,
      cost: 0.02,
      promptVersion: 4
    )
    #expect(third.revision == 3)
    #expect(third.cumulativeCost == 0.05)
  }

  // MARK: Bounding

  @Test func boundingTrimsTheOldestTimelineEntriesFirst() {
    let full = Understanding(
      goals: [Understanding.Goal(goal: "the goal", evidence: "why", confidence: 0.8)],
      timeline: (0..<40).map { "a reasonably long thing that happened, number \($0)" },
      mentorHistory: ["said one thing"],
      openConcerns: ["one concern"]
    )
    let bounded = full.bounded(toTokens: 120)
    #expect(bounded.estimatedTokens <= 120)
    #expect(bounded.goals.count == 1)
    // What survives is the newest end of the timeline, not the oldest.
    #expect(bounded.timeline.count < full.timeline.count)
    #expect(bounded.timeline.last == full.timeline.last)
  }

  @Test func boundingKeepsTheStrongestGoalEvenAtATinyBudget() {
    let bounded = sample(goals: 4, timeline: 30).bounded(toTokens: 1)
    #expect(bounded.goals.count == 1)
    #expect(bounded.goals.first?.goal == "goal 0")
  }

  @Test func boundingLeavesARecordAlreadyInsideTheBudgetAlone() {
    let small = sample(goals: 1, timeline: 1)
    #expect(small.bounded(toTokens: 4000) == small.normalized())
  }

  /// The top of the size limit's range must fit a refresh reply with its
  /// thinking, and leave a mentor reply room for its thinking and a
  /// suggestion beside the record.
  @Test func theTopOfTheBudgetRangeFitsBothReplies() throws {
    let top = MentorSettings.understandingTokenBudgetRange.upperBound
    let oversized = Understanding(
      goals: (0..<8).map {
        Understanding.Goal(
          goal: "goal \($0) " + String(repeating: "word ", count: 20),
          evidence: String(repeating: "seen ", count: 20),
          confidence: 0.5
        )
      },
      timeline: (0..<200).map { "step \($0): " + String(repeating: "did a thing ", count: 8) },
      mentorHistory: (0..<40).map { "said \($0) " + String(repeating: "and ", count: 10) },
      openConcerns: (0..<20).map { "concern \($0) " + String(repeating: "watch ", count: 10) }
    )
    let record = oversized.bounded(toTokens: top)
    #expect(record.estimatedTokens > top - 100)
    #expect(record.estimatedTokens <= top)
    // What the model has to emit: the record as JSON plus a reason sentence.
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    let replyTokens = TokenEstimate.tokens(in: json) + 60
    #expect(
      replyTokens + MentorLoop.thinkingAllowance <= MentorLoop.understandingMaxTokens(for: top)
    )
    let suggestionTokens = 400
    #expect(
      replyTokens + suggestionTokens + MentorLoop.thinkingAllowance <= MentorLoop.mentorMaxTokens
    )
    // And each call is given long enough for a reply that size, inside
    // the client's cap on a whole call.
    for maxTokens in [MentorLoop.understandingMaxTokens(for: top), MentorLoop.mentorMaxTokens] {
      let timeout = MentorLoop.timeout(forReplyOf: maxTokens)
      #expect(timeout * MentorLoop.outputTokensPerSecond >= Double(maxTokens))
      #expect(timeout <= AnthropicClient.resourceTimeout)
    }
  }

  @Test func defaultBudgetHoldsARealisticRecord() {
    let realistic = Understanding(
      goals: [
        Understanding.Goal(
          goal: "Get the capture path fast enough to leave running all day",
          evidence: "Two hours in SensingPipeline.swift and repeated make measure runs.",
          confidence: 0.84
        ),
        Understanding.Goal(
          goal: "Keep the loop's spend under a dollar an hour",
          evidence: "The spend cap was edited twice.",
          confidence: 0.5
        ),
      ],
      timeline: (0..<8).map {
        "Step \($0): a sentence about what happened, roughly this long in practice."
      },
      mentorHistory: (0..<3).map { "Suggested thing \($0); they answered not now." },
      openConcerns: [
        "The size-cap sweep can delete today's text.", "No measurement of the OCR step yet.",
      ]
    )
    #expect(realistic.estimatedTokens <= MentorSettings().understandingTokenBudget)
  }

  // MARK: Rendering

  @Test func promptBlockNamesEverySectionItHas() {
    let block = sample().promptBlock
    #expect(block.contains("working toward"))
    #expect(block.contains("goal 0"))
    #expect(block.contains("evidence: evidence 0"))
    #expect(block.contains("90%"))
    #expect(block.contains("happened 0"))
    #expect(block.contains("they answered not now"))
    #expect(block.contains("a concern"))
    #expect(!block.contains("\u{2014}"))
  }

  @Test func promptBlockOmitsEmptySections() {
    let onlyGoals = Understanding(goals: [
      Understanding.Goal(goal: "g", evidence: "e", confidence: 0.5)
    ])
    let block = onlyGoals.promptBlock
    #expect(block.contains("working toward"))
    #expect(!block.contains("Open concerns"))
    #expect(!block.contains("What has happened"))
  }

  @Test func understandingBlockCarriesTheRecordWithoutACacheMarker() {
    let record = UnderstandingRecord.first(
      content: sample(),
      at: t0,
      model: "m",
      source: .periodic,
      cost: 0,
      promptVersion: 4
    )
    let block = MentorPrompts.understandingBlock(record)
    #expect(block.text.contains(record.content.promptBlock))
    #expect(block.cacheControl == nil)
  }

  @Test func paragraphIsOneCompactLineForTriage() {
    let paragraph = sample().paragraph
    #expect(paragraph.contains("goal 0"))
    #expect(paragraph.contains("Open concerns"))
    #expect(!paragraph.contains("\n"))
    #expect(paragraph.count < 400)
  }

  @Test func paragraphSaysSoWhenNoGoalIsKnown() {
    #expect(Understanding().paragraph.contains("No goal"))
  }

  // MARK: Expiry

  /// A calendar in which `t0` is noon, so the idle-gap cases stay on one day
  /// whatever time zone the tests run in.
  private var middayCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    let secondsIntoUTCDay = Int(t0.timeIntervalSince1970) % 86400
    calendar.timeZone = TimeZone(secondsFromGMT: 43200 - secondsIntoUTCDay) ?? .current
    return calendar
  }

  @Test func staysCurrentWhileActivityIsRecentAndTheDayIsTheSame() {
    #expect(
      UnderstandingExpiry.of(
        writtenAt: t0,
        now: t0.addingTimeInterval(3600),
        idleGap: 4 * 3600,
        lastActivityAt: nil,
        calendar: middayCalendar
      ) == nil
    )
  }

  /// The gap is measured from the user's last activity, so steady work with
  /// no mentor call to rewrite the record never expires it.
  @Test func staysCurrentWhileTheUserKeepsWorkingLongAfterTheLastWrite() {
    let now = t0.addingTimeInterval(5 * 3600)
    #expect(
      UnderstandingExpiry.of(
        writtenAt: t0,
        now: now,
        idleGap: 4 * 3600,
        lastActivityAt: now.addingTimeInterval(-60),
        calendar: middayCalendar
      ) == nil
    )
  }

  @Test func expiresAfterTheIdleGapSinceTheLastActivity() {
    let lastActive = t0.addingTimeInterval(3600)
    let expiry = UnderstandingExpiry.of(
      writtenAt: t0,
      now: lastActive.addingTimeInterval(4 * 3600 + 1),
      idleGap: 4 * 3600,
      lastActivityAt: lastActive,
      calendar: middayCalendar
    )
    #expect(expiry == .idleGap(4 * 3600))
  }

  /// With nothing observed since the write, as after a relaunch, the gap
  /// runs from the write itself; activity before the write does not count.
  @Test func expiresAfterTheIdleGapSinceTheWriteWhenNothingWasObservedAfterIt() {
    let now = t0.addingTimeInterval(4 * 3600 + 1)
    #expect(
      UnderstandingExpiry.of(
        writtenAt: t0,
        now: now,
        idleGap: 4 * 3600,
        lastActivityAt: nil,
        calendar: middayCalendar
      ) == .idleGap(4 * 3600)
    )
    #expect(
      UnderstandingExpiry.of(
        writtenAt: t0,
        now: now,
        idleGap: 4 * 3600,
        lastActivityAt: t0.addingTimeInterval(-600),
        calendar: middayCalendar
      ) == .idleGap(4 * 3600)
    )
  }

  @Test func expiresAtANewDayEvenInsideTheIdleGap() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    // 23:30 UTC, then 00:10 the next day: forty minutes apart, different days.
    let lateNight = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 23, minute: 30))
    )
    let afterMidnight = lateNight.addingTimeInterval(40 * 60)
    #expect(
      UnderstandingExpiry.of(
        writtenAt: lateNight,
        now: afterMidnight,
        idleGap: 4 * 3600,
        lastActivityAt: afterMidnight,
        calendar: calendar
      ) == .newDay
    )
  }

  // MARK: Categories

  @Test func onlyTheThreeGoalKindsJudgeAgainstAGoal() {
    let judging = SuggestionCategory.allCases.filter(\.judgesAgainstGoal)
    #expect(Set(judging) == [.wontAchieveGoal, .lessEfficient, .unwantedSideEffect])
  }

  @Test func everyCategoryIsInTheMentorSchemaEnum() throws {
    guard case .object(let schema) = MentorPrompts.mentorSchema,
      case .object(let properties)? = schema["properties"],
      case .object(let suggestion)? = properties["suggestion"],
      case .array(let branches)? = suggestion["anyOf"],
      case .object(let payload) = branches[1],
      case .object(let payloadProperties)? = payload["properties"],
      case .object(let category)? = payloadProperties["category"],
      case .array(let values)? = category["enum"]
    else {
      Issue.record("the mentor schema no longer has a category enum where expected")
      return
    }
    let names = values.compactMap { value -> String? in
      if case .string(let name) = value { return name }
      return nil
    }
    #expect(Set(names) == Set(SuggestionCategory.allCases.map(\.rawValue)))
  }
}
