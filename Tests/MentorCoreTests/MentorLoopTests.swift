import Foundation
import Testing
@testable import MentorCore

/// Drives `MentorLoop` end to end with a scripted client: sensing events in,
/// model calls out, suggestions and journal rows as the result.
@Suite struct MentorLoopTests {
    private struct Harness {
        let journal: Journal
        let client: ScriptedClaudeClient
        let keyStore: InMemoryKeyStore
        let loop: MentorLoop
        let input: AsyncStream<SensingEvent>.Continuation
        let output: AsyncStream<MentorEvent>

        init(settings: MentorSettings = MentorSettings(), key: String? = "sk-ant-test") async throws {
            journal = try Journal.inMemory()
            client = ScriptedClaudeClient()
            keyStore = InMemoryKeyStore(key: key)
            let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
            input = continuation
            loop = MentorLoop(settings: settings, journal: journal, client: client, keyStore: keyStore, events: stream)
            output = await loop.events()
            await loop.start()
            input.yield(.modeChanged(.watching))
        }

        /// Sends an observation and waits until the loop has gated it, made
        /// the expected number of calls, and has nothing in flight.
        func observe(_ observation: ActivityObservation, expectCalls: Int) async {
            input.yield(.observation(observation))
            for _ in 0..<250 {
                let status = await loop.currentStatus()
                if status.lastGate?.observationID == observation.id, status.inFlight == nil,
                   await client.sent.count >= expectCalls {
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        func drain(until predicate: (MentorEvent) -> Bool) async -> [MentorEvent] {
            var seen: [MentorEvent] = []
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let next = await withTaskGroup(of: MentorEvent?.self) { group in
                    group.addTask {
                        var iterator = output.makeAsyncIterator()
                        return await iterator.next()
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(500))
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                guard let next else { return seen }
                seen.append(next)
                if predicate(next) { return seen }
            }
            return seen
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static let yes = #"{"worth_a_look": true, "reason": "Repeated manual runs"}"#
    private static let no = #"{"worth_a_look": false, "reason": "Reading docs"}"#
    private static func suggestion(category: String = "shortcut", confidence: Double = 0.9) -> String {
        #"{"reason": "Saw it", "suggestion": {"title": "Use --filter", "body": "Run one suite.", "explanation": "swift test --filter Name", "category": "\#(category)", "confidence": \#(confidence)}}"#
    }

    private static let silence = #"{"reason": "Nothing stands out", "suggestion": null}"#

    @Test func triageRunsOnChangeMomentsOnlyAndReceivesTextOnly() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        let jpeg = Data(repeating: 0xFF, count: 100)
        await h.observe(Fixtures.observation(id: 1, at: Date(), reason: .floor, jpeg: jpeg), expectCalls: 0)
        #expect(await h.client.sent.isEmpty)
        let status = await h.loop.currentStatus()
        #expect(status.lastGate?.hold == .notAChangeMoment(.floor))

        await h.observe(Fixtures.observation(id: 2, at: Date(), reason: .focusChange, jpeg: jpeg), expectCalls: 1)
        let sent = await h.client.sent
        #expect(sent.count == 1)
        let request = try #require(sent.first?.request)
        #expect(request.model == "claude-haiku-4-5-20251001")
        #expect(request.system.first?.cacheControl == .ephemeral)
        #expect(request.system.first?.text == MentorPrompts.triageSystem)
        #expect(request.outputConfig?.format?.schema == MentorPrompts.triageSchema)
        #expect(request.outputConfig?.effort == nil)
        #expect(request.imageByteCount == 0)
        #expect(sent.first?.apiKey == "sk-ant-test")
        let after = await h.loop.currentStatus()
        #expect(after.lastTriage?.outcome == .quiet)
        #expect(after.lastMentorHold?.hold == .triageSaidNo(reason: "Reading docs"))
        #expect(after.callsThisHour == 1)
        #expect(after.spendThisHour > 0)
        let calls = try await h.journal.recentModelCalls(limit: 10)
        #expect(calls.count == 1)
        #expect(calls.first?.tier == .triage)
    }

    @Test func candidateTriggersMentorWithWindowAndThumbnail() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.suggestion(), model: "claude-opus-5", usage: Usage(inputTokens: 2000, outputTokens: 300, cacheCreationInputTokens: 700, cacheReadInputTokens: 0))
        let older = try await h.journal.record(Fixtures.observation(at: Date().addingTimeInterval(-60), window: "old.swift", text: "older screen"))
        _ = older
        let jpeg = Data(repeating: 0xFF, count: 100)
        let latest = try await h.journal.record(Fixtures.observation(at: Date(), text: "latest screen", jpeg: jpeg))
        await h.observe(latest, expectCalls: 2)

        let sent = await h.client.sent
        #expect(sent.count == 2)
        let mentor = try #require(sent.last?.request)
        #expect(mentor.model == "claude-opus-5")
        #expect(mentor.outputConfig?.effort == .medium)
        #expect(mentor.system.first?.text == MentorPrompts.mentorSystem)
        #expect(mentor.imageByteCount == 100)
        guard case .image(let mediaType, _) = mentor.messages[0].content[0] else {
            Issue.record("expected the image first")
            return
        }
        #expect(mediaType == "image/jpeg")
        guard case .text(let text) = mentor.messages[0].content[1] else {
            Issue.record("expected the text after the image")
            return
        }
        #expect(text.contains("older screen"))
        #expect(text.contains("latest screen"))
        #expect(text.contains("| latest"))

        let events = await h.drain { if case .suggestion = $0 { return true } else { return false } }
        guard case .suggestion(let suggestion)? = events.last else {
            Issue.record("expected a suggestion event")
            return
        }
        #expect(suggestion.id > 0)
        #expect(suggestion.title == "Use --filter")
        #expect(suggestion.category == .shortcut)
        #expect(suggestion.model == "claude-opus-5")
        #expect(suggestion.observationID == latest.id)
        #expect(try await h.journal.recentSuggestions(limit: 5).first?.id == suggestion.id)
        let journaled = try await h.journal.recentEvents(limit: 5)
        #expect(journaled.first?.kind == .suggested)
        let status = await h.loop.currentStatus()
        #expect(status.lastMentor?.outcome == .suggested)
        #expect(status.callsThisHour == 2)
        let expectedCost = PriceTable.defaults.cost(of: Usage(inputTokens: 2000, outputTokens: 300, cacheCreationInputTokens: 700, cacheReadInputTokens: 0), model: "claude-opus-5")!
        #expect(abs((status.lastMentor?.cost ?? 0) - expectedCost) < 1e-9)
    }

    @Test func perTierEffortReachesEachRequest() async throws {
        var settings = MentorSettings()
        settings.triageModel = "claude-sonnet-5"
        settings.triageEffort = .xhigh
        settings.mentorModel = "claude-fable-5-1"
        settings.mentorEffort = .high
        let h = try await Harness(settings: settings)
        await h.client.enqueue(json: Self.yes, model: "claude-sonnet-5")
        await h.client.enqueue(json: Self.silence, model: "claude-fable-5-1")
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 2)
        let sent = await h.client.sent
        #expect(sent[0].request.model == "claude-sonnet-5")
        #expect(sent[0].request.outputConfig?.effort == .xhigh)
        #expect(sent[1].request.model == "claude-fable-5-1")
        #expect(sent[1].request.outputConfig?.effort == .high)
        let json = String(decoding: try AnthropicClient.encoder.encode(sent[0].request), as: UTF8.self)
        #expect(json.contains(#""effort":"xhigh""#))
    }

    @Test func thumbnailIsWithheldWhenTheSettingIsOff() async throws {
        var settings = MentorSettings()
        settings.sendThumbnail = false
        let h = try await Harness(settings: settings)
        await h.client.enqueue(json: Self.yes)
        await h.client.enqueue(json: Self.silence)
        await h.observe(Fixtures.observation(id: 1, at: Date(), jpeg: Data(repeating: 1, count: 50)), expectCalls: 2)
        let mentor = try #require(await h.client.sent.last?.request)
        #expect(mentor.imageByteCount == 0)
        #expect(mentor.messages[0].content.count == 1)
        let status = await h.loop.currentStatus()
        #expect(status.lastMentor?.outcome == .nothingToSay)
        #expect(try await h.journal.recentSuggestions(limit: 5).isEmpty)
    }

    @Test func lowConfidenceSuggestionsAreLoggedNotShown() async throws {
        var settings = MentorSettings()
        settings.minimumConfidence = 0.7
        let h = try await Harness(settings: settings)
        await h.client.enqueue(json: Self.yes)
        await h.client.enqueue(json: Self.suggestion(confidence: 0.5))
        await h.observe(Fixtures.observation(id: 1, at: Date(), text: "one"), expectCalls: 2)
        let status = await h.loop.currentStatus()
        #expect(status.lastMentor?.outcome == .belowConfidence)
        #expect(status.lastMentor?.detail == "Use --filter (confidence 50%)")
        #expect(try await h.journal.recentSuggestions(limit: 5).isEmpty)
    }

    @Test func suppressedCategoriesAreToldToTheModelAndDroppedIfRaisedAnyway() async throws {
        var settings = MentorSettings()
        settings.neverRules = [NeverRule(bundleID: "com.apple.dt.Xcode", appName: "Xcode", category: .tool, createdAt: Date())]
        let h = try await Harness(settings: settings)
        await h.client.enqueue(json: Self.yes)
        await h.client.enqueue(json: Self.suggestion(category: "tool", confidence: 0.95))
        await h.observe(Fixtures.observation(id: 1, at: Date(), text: "one"), expectCalls: 2)
        let status = await h.loop.currentStatus()
        #expect(status.lastMentor?.outcome == .suppressed)
        let mentorRequest = try #require(await h.client.sent.last?.request)
        guard case .text(let text) = mentorRequest.messages[0].content.last else {
            Issue.record("expected text")
            return
        }
        #expect(text.contains("do not raise these): tool."))
        #expect(try await h.journal.recentSuggestions(limit: 5).isEmpty)
    }

    @Test func nothingIsSentWithoutAKeyAndKeyChangesAreNoticed() async throws {
        let h = try await Harness(key: nil)
        await h.client.enqueue(json: Self.no)
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 0)
        #expect(await h.client.sent.isEmpty)
        let status = await h.loop.currentStatus()
        #expect(status.availability == .noAPIKey)
        #expect(status.lastGate?.hold == .noAPIKey)

        try h.keyStore.save("sk-ant-new")
        await h.loop.apiKeyChanged()
        #expect(await h.loop.currentStatus().availability == .ready)
        await h.observe(Fixtures.observation(id: 2, at: Date(), window: "b", text: "b"), expectCalls: 1)
        #expect(await h.client.sent.first?.apiKey == "sk-ant-new")
    }

    @Test func spendCapStopsCallsAndSeedsFromTheJournal() async throws {
        var settings = MentorSettings()
        settings.hourlySpendCap = 0.05
        let journal = try Journal.inMemory()
        try await journal.record(ModelCallRecord(
            timestamp: Date(), tier: .mentor, model: "claude-fable-5-1", promptVersion: 1, promptCharacters: 10, imageBytes: 0,
            usage: Usage(), cost: 0.06, latency: 1, outcome: .suggested, detail: nil
        ))
        let client = ScriptedClaudeClient()
        let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
        let loop = MentorLoop(settings: settings, journal: journal, client: client, keyStore: InMemoryKeyStore(key: "k"), events: stream)
        await loop.start()
        continuation.yield(.modeChanged(.watching))
        let status = await loop.currentStatus()
        #expect(status.spendThisHour == 0.06)
        if case .capReached = status.availability {} else { Issue.record("expected the cap to be reached") }
        continuation.yield(.observation(Fixtures.observation(id: 1, at: Date())))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await client.sent.isEmpty)
        if case .spendCapReached = await loop.currentStatus().lastGate?.hold {} else { Issue.record("expected a spend cap hold") }
    }

    @Test(arguments: [
        (Result<MessagesResponse, ClaudeClientError>.failure(.api(status: 529, type: "overloaded_error", message: "Overloaded")), ModelCallOutcome.error, "overloaded_error (HTTP 529): Overloaded"),
        (.success(MessagesResponse(id: "r", model: "m", stopReason: "refusal", content: [], usage: Usage())), .refused, "the API declined this request"),
        (.success(MessagesResponse(id: "g", model: "m", stopReason: "end_turn", content: [ResponseBlock(type: "text", text: "not json")], usage: Usage())), .error, "could not parse the triage reply"),
        (.success(MessagesResponse(id: "t", model: "m", stopReason: "max_tokens", content: [ResponseBlock(type: "text", text: "{\"worth")], usage: Usage())), .truncated, "could not parse the triage reply"),
    ])
    func errorsRefusalsAndGarbageAreRecordedNotShown(response: Result<MessagesResponse, ClaudeClientError>, outcome: ModelCallOutcome, detail: String) async throws {
        let h = try await Harness()
        await h.client.enqueue(response)
        await h.observe(Fixtures.observation(id: 1, at: Date(), text: "one"), expectCalls: 1)
        let status = await h.loop.currentStatus()
        #expect(status.lastTriage?.outcome == outcome)
        #expect(status.lastTriage?.detail == detail)
        #expect(status.lastMentor == nil)
        let calls = try await h.journal.recentModelCalls(limit: 10)
        #expect(calls.count == 1)
        #expect(calls.first?.outcome == outcome)
    }

    @Test func feedbackIsJournaledAndPublished() async throws {
        let h = try await Harness()
        let stored = try await h.journal.record(Suggestion(
            timestamp: Date(), bundleID: "com.a", appName: "A", windowTitle: nil, category: .workflow,
            title: "T", body: "B", explanation: "E", confidence: 0.8, observationID: nil, model: "m", promptVersion: 1
        ))
        let updated = await h.loop.recordFeedback(suggestionID: stored.id, feedback: .never)
        #expect(updated?.feedback == .never)
        #expect(updated?.feedbackAt != nil)
        #expect(try await h.journal.suggestion(id: stored.id)?.feedback == .never)
        let events = try await h.journal.recentEvents(limit: 3)
        #expect(events.first?.kind == .feedback)
        #expect(events.first?.detail == "Never for this: T")
        #expect(await h.loop.recordFeedback(suggestionID: 9999, feedback: .notNow) == nil)
    }

    @Test func testConnectionReportsModelOrError() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: "OK", model: "claude-haiku-4-5-20251001")
        #expect(await h.loop.testConnection() == .success("claude-haiku-4-5-20251001"))
        await h.client.enqueue(.failure(.api(status: 401, type: "authentication_error", message: "invalid x-api-key")))
        #expect(await h.loop.testConnection() == .failure(.api(status: 401, type: "authentication_error", message: "invalid x-api-key")))
        let request = try #require(await h.client.sent.first?.request)
        #expect(request.maxTokens == 16)
        #expect(request.system.isEmpty)
        let calls = try await h.journal.recentModelCalls(limit: 5)
        #expect(calls.map(\.outcome) == [.error, .ok])
        #expect(calls.allSatisfy { $0.tier == .test })
        let keyless = try await Harness(key: nil)
        #expect(await keyless.loop.testConnection() == .failure(.transport("no API key saved")))
    }
}

@Suite struct JournalMentorTests {
    @Test func suggestionsAndCallsRoundTripAndClear() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = try await journal.record(Suggestion(
            timestamp: now, bundleID: "com.a", appName: "A", windowTitle: "W", category: .risk,
            title: "T", body: "B", explanation: "E", confidence: 0.75, observationID: 12, model: "claude-opus-5", promptVersion: 3
        ))
        let fetched = try #require(try await journal.suggestion(id: stored.id))
        #expect(fetched == stored)
        #expect(fetched.feedback == nil)
        let updated = try await journal.updateFeedback(suggestionID: stored.id, feedback: .tellMeMore, at: now + 5)
        #expect(updated?.feedback == .tellMeMore)
        #expect(updated?.feedbackAt == now + 5)
        #expect(try await journal.updateFeedback(suggestionID: 404, feedback: .notNow, at: now) == nil)

        let call = try await journal.record(ModelCallRecord(
            timestamp: now, tier: .mentor, model: "claude-opus-5", promptVersion: 3, promptCharacters: 1234, imageBytes: 55,
            usage: Usage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4),
            cost: 0.0123, latency: 4.5, outcome: .nothingToSay, detail: "quiet"
        ))
        #expect(try await journal.recentModelCalls(limit: 5) == [call])
        #expect(try await journal.modelCalls(since: now + 1).isEmpty)
        #expect(try await journal.modelCalls(since: now) == [call])

        try await journal.clear()
        #expect(try await journal.recentSuggestions(limit: 5).isEmpty)
        #expect(try await journal.recentModelCalls(limit: 5).isEmpty)
    }

    @Test func retentionExpiresSuggestionsAndCallsWithText() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await journal.record(Suggestion(
            timestamp: now - 10 * 86400, bundleID: nil, appName: "A", windowTitle: nil, category: .other,
            title: "old", body: "", explanation: "", confidence: 1, observationID: nil, model: "m", promptVersion: 1
        ))
        try await journal.record(ModelCallRecord(
            timestamp: now - 60, tier: .triage, model: "m", promptVersion: 1, promptCharacters: 1, imageBytes: 0,
            usage: Usage(), cost: 0, latency: 0, outcome: .quiet, detail: nil
        ))
        let result = try await journal.applyRetention(RetentionPolicy(thumbnailMaxAge: 3600, textMaxAge: 7 * 86400, sizeCapBytes: 1 << 30), now: now)
        #expect(result.suggestionsDeleted == 1)
        #expect(result.modelCallsDeleted == 0)
        #expect(result.deletedAnything)
    }
}
