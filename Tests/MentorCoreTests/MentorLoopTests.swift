import Foundation
import Testing
@testable import MentorCore

/// Drives `MentorLoop` end to end with a scripted client: sensing events in,
/// model calls out, suggestions and journal rows as the result.
@Suite struct MentorLoopTests {
    struct Harness {
        let journal: Journal
        let client: ScriptedClaudeClient
        let keyStore: InMemoryKeyStore
        let loop: MentorLoop
        let input: AsyncStream<SensingEvent>.Continuation
        let output: AsyncStream<MentorEvent>

        /// `screens`, then `understanding`, when given, are journaled before the
        /// loop starts, so the loop seeds from them exactly as it would after a
        /// relaunch. The screens get ids 1, 2, and so on, in order.
        init(
            settings: MentorSettings = MentorSettings(),
            key: String? = "sk-ant-test",
            screens: [ActivityObservation] = [],
            understanding: UnderstandingRecord? = nil
        ) async throws {
            let journal = try Journal.inMemory()
            for screen in screens { try await journal.record(screen) }
            if let understanding { try await journal.record(understanding) }
            await self.init(settings: settings, key: key, journal: journal, client: ScriptedClaudeClient())
        }

        /// A loop over a journal and client that already exist, as a relaunch finds them.
        init(
            settings: MentorSettings = MentorSettings(),
            key: String? = "sk-ant-test",
            journal: Journal,
            client: ScriptedClaudeClient
        ) async {
            self.journal = journal
            self.client = client
            keyStore = InMemoryKeyStore(key: key)
            let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
            input = continuation
            loop = MentorLoop(
                settings: settings, journal: journal, client: client, keyStore: keyStore, events: stream,
                calendar: MentorLoopTests.middayCalendar
            )
            output = await loop.events()
            await loop.start()
            input.yield(.modeChanged(.watching))
        }

        /// Sends an observation and waits until the loop has gated it through
        /// both the triage and the refresh gate, made the expected number of
        /// calls, and has nothing in flight.
        func observe(_ observation: ActivityObservation, expectCalls: Int) async {
            let sentAt = Date()
            input.yield(.observation(observation))
            for _ in 0..<250 {
                let status = await loop.currentStatus()
                if status.lastGate?.observationID == observation.id, status.inFlight == nil,
                   Self.refreshGateRan(status, since: sentAt),
                   await client.sent.count >= expectCalls {
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        /// Polls the loop's status until `condition` holds, for up to five seconds.
        func waitUntil(_ condition: (MentorStatus) -> Bool) async {
            for _ in 0..<250 {
                if condition(await loop.currentStatus()) { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        /// The refresh gate runs last for every observation, so a hold or a
        /// call of its own since the observation was sent means the loop has
        /// finished with it.
        private static func refreshGateRan(_ status: MentorStatus, since sentAt: Date) -> Bool {
            if let hold = status.lastRefreshHold, hold.at >= sentAt { return true }
            if let call = status.lastRefresh, call.timestamp >= sentAt { return true }
            return false
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

    /// A calendar in which this instant is noon, so a record written any test
    /// age ago is still on today's date whatever the wall clock says.
    private static var middayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        let secondsIntoUTCDay = Int(Date().timeIntervalSince1970) % 86400
        calendar.timeZone = TimeZone(secondsFromGMT: 43200 - secondsIntoUTCDay) ?? .current
        return calendar
    }

    private static let yes = #"{"worth_a_look": true, "reason": "Repeated manual runs"}"#
    private static let no = #"{"worth_a_look": false, "reason": "Reading docs"}"#
    private static func suggestion(
        category: String = "shortcut",
        confidence: Double = 0.9,
        judgedGoal: String? = nil,
        understanding: String = Self.understandingJSON
    ) -> String {
        let goal = judgedGoal.map { "\"\($0)\"" } ?? "null"
        return #"{"reason": "Saw it", "suggestion": {"title": "Use --filter", "body": "Run one suite.", "explanation": "swift test --filter Name", "category": "\#(category)", "confidence": \#(confidence), "judged_goal": \#(goal)}, "updated_understanding": \#(understanding)}"#
    }

    private static let understandingJSON = """
    {"goals": [{"goal": "ship the mentor loop", "evidence": "two hours in the same files", "confidence": 0.8}], \
    "timeline": ["opened the editor"], "mentor_history": ["said use --filter"], "open_concerns": ["no tests yet"]}
    """

    private static let silence = #"{"reason": "Nothing stands out", "suggestion": null, "updated_understanding": \#(Self.understandingJSON)}"#

    /// A mentor reply that carries no understanding at all, as an older prompt
    /// version or a stubborn model might.
    private static let silenceWithoutUnderstanding = #"{"reason": "Nothing stands out", "suggestion": null}"#

    private static let refresh = #"{"reason": "Goal firmed up", "understanding": \#(Self.understandingJSON)}"#

    /// A record already in the journal, `age` seconds old, as a relaunch or an
    /// earlier mentor call would have left it, covering the observations
    /// through `coveredThrough`.
    private static func existing(
        age: TimeInterval, goal: String = "ship the mentor loop", coveredThrough: Int64? = nil
    ) -> UnderstandingRecord {
        UnderstandingRecord.first(
            content: Understanding(
                goals: [Understanding.Goal(goal: goal, evidence: "two hours in the same files", confidence: 0.8)],
                timeline: ["opened the editor"]
            ),
            at: Date().addingTimeInterval(-age), model: "claude-opus-5", source: .periodic,
            cost: 0.02, promptVersion: MentorPrompts.version, coveredThroughObservationID: coveredThrough
        )
    }

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
        #expect(request.system.first?.text == MentorPrompts.triageSystem(contexts: []))
        #expect(request.outputConfig?.format?.schema == MentorPrompts.triageSchema(contexts: []))
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

    // MARK: Mentorship contexts

    private static func triage(_ worth: Bool, context: String?) -> String {
        let name = context.map { "\"\($0)\"" } ?? "null"
        return #"{"worth_a_look": \#(worth), "reason": "Repeated manual runs", "context": \#(name)}"#
    }

    private static func enforcing(
        contexts: [MentorshipContext] = [MentorshipContext(name: "writing Swift")]
    ) -> MentorSettings {
        var settings = MentorSettings()
        settings.onlyMentorInsideContexts = true
        settings.contexts = contexts
        return settings
    }

    @Test func declaredContextsRideAlongWithTriageAndOpenTheMentorTier() async throws {
        let contexts = [
            MentorshipContext(name: "writing Swift", detail: "the Mentor app itself"),
            MentorshipContext(name: "drafting documents"),
        ]
        let h = try await Harness(settings: Self.enforcing(contexts: contexts))
        await h.client.enqueue(json: Self.triage(true, context: "writing Swift"))
        await h.client.enqueue(json: Self.suggestion())
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 2)

        let triage = try #require(await h.client.sent.first?.request)
        // No extra call: the same triage request carries the question.
        #expect(await h.client.sent.count == 2)
        #expect(triage.system.first?.text == MentorPrompts.triageSystem(contexts: contexts))
        #expect(triage.system.first?.cacheControl == .ephemeral)
        #expect(triage.system.first?.text.contains("- \"drafting documents\"") == true)
        #expect(triage.outputConfig?.format?.schema == MentorPrompts.triageSchema(contexts: contexts))

        guard case .text(let mentorText) = (await h.client.sent.last?.request.messages[0].content.last) else {
            Issue.record("expected text in the mentor message")
            return
        }
        #expect(mentorText.contains("mentored while writing Swift"))

        let status = await h.loop.currentStatus()
        #expect(status.lastTriage?.outcome == .candidate)
        #expect(status.lastContext?.placement.contextName == "writing Swift")
        #expect(status.lastMentor?.outcome == .suggested)
    }

    @Test func outOfContextStopsAtTriageAndIsRecordedAsSuch() async throws {
        let h = try await Harness(settings: Self.enforcing())
        await h.client.enqueue(json: Self.triage(true, context: nil))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)

        // Triage ran, the mentor tier never did, and nothing was shown.
        #expect(await h.client.sent.count == 1)
        let status = await h.loop.currentStatus()
        #expect(status.lastTriage?.outcome == .outOfContext)
        #expect(status.lastMentorHold?.hold == .outOfContext(.noMatch(reason: "")))
        #expect(status.lastMentor == nil)
        #expect(try await h.journal.recentSuggestions(limit: 5).isEmpty)
        let calls = try await h.journal.recentModelCalls(limit: 5)
        #expect(calls.count == 1)
        #expect(calls.first?.outcome == .outOfContext)
    }

    @Test func anUndeclaredContextNameIsOutOfContext() async throws {
        let h = try await Harness(settings: Self.enforcing())
        await h.client.enqueue(json: Self.triage(true, context: "cooking"))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)
        #expect(await h.client.sent.count == 1)
        let status = await h.loop.currentStatus()
        #expect(status.lastTriage?.outcome == .outOfContext)
        #expect(status.lastMentorHold?.hold == .outOfContext(
            .noMatch(reason: "triage answered \"cooking\", which is not declared")
        ))
    }

    @Test func enforcingWithNoContextDeclaredMakesNoModelCallAtAll() async throws {
        let h = try await Harness(settings: Self.enforcing(contexts: []))
        await h.client.enqueue(json: Self.triage(true, context: nil))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 0)
        #expect(await h.client.sent.isEmpty)
        let status = await h.loop.currentStatus()
        #expect(status.lastGate?.hold == .noContextsDeclared)
        #expect(status.lastContext?.placement == .outside(.noContextsDeclared))
        #expect(status.lastRefreshHold?.hold == .unavailable(.noContextsDeclared))
    }

    @Test func beingInsideAContextStillLeavesTriagesOwnJudgementInCharge() async throws {
        let h = try await Harness(settings: Self.enforcing())
        await h.client.enqueue(json: Self.triage(false, context: "writing Swift"))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)
        let status = await h.loop.currentStatus()
        #expect(status.lastTriage?.outcome == .quiet)
        #expect(status.lastContext?.placement.contextName == "writing Swift")
        #expect(status.lastMentorHold?.hold == .triageSaidNo(reason: "Repeated manual runs"))
    }

    @Test func withTheSwitchOffNothingAboutContextsReachesTheRequestOrTheRecord() async throws {
        var settings = MentorSettings()
        settings.contexts = [MentorshipContext(name: "writing Swift")]
        let h = try await Harness(settings: settings)
        await h.client.enqueue(json: Self.no)
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)
        let triage = try #require(await h.client.sent.first?.request)
        #expect(triage.system.first?.text == MentorPrompts.triageBase)
        #expect(triage.outputConfig?.format?.schema == MentorPrompts.triageSchema(contexts: []))
        let status = await h.loop.currentStatus()
        #expect(status.lastContext?.placement == .notEnforced)
        // Nor the refresh gate, which is held only as not yet due.
        guard case .notDue = status.lastRefreshHold?.hold ?? .callInFlight else {
            Issue.record("expected the refresh to be held as not due, not by the contexts")
            return
        }
    }

    /// The understanding stands behind the context boundary as well: a due
    /// refresh waits while the last verdict put the frontmost app outside.
    @Test func anOutOfContextMomentNeverBuysARefresh() async throws {
        var settings = Self.enforcing()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        await h.client.enqueue(json: Self.triage(true, context: nil))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)

        // Triage ran and nothing else did: not the mentor tier, not a refresh.
        #expect(await h.client.sent.count == 1)
        let status = await h.loop.currentStatus()
        #expect(status.lastMentorHold?.hold == .outOfContext(.noMatch(reason: "")))
        #expect(status.lastRefreshHold?.hold == .outOfContext(.noMatch(reason: "")))
        #expect(status.lastRefresh == nil)
        #expect(await h.loop.currentUnderstanding()?.revision == 1)
    }

    @Test func aDueRefreshRunsInsideAContextAndWaitsForAnAppTriageHasNotPlaced() async throws {
        var settings = Self.enforcing()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        // Inside, with triage passing: no mentor call carries the record, so
        // the refresh of its own runs as it would with the switch off.
        await h.client.enqueue(json: Self.triage(false, context: "writing Swift"))
        await h.client.enqueue(json: Self.refresh, model: "claude-opus-5")
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 2)
        #expect(await h.client.sent.count == 2)
        #expect(await h.loop.currentStatus().lastRefreshHold == nil)
        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.revision == 2)
        #expect(record.source == .periodic)

        // Another app comes to the front before triage can place it: the
        // refresh waits for that verdict rather than trusting the last app's.
        await h.observe(Fixtures.observation(id: 2, at: Date(), app: "Safari", bundleID: "com.apple.Safari", window: "Docs"), expectCalls: 2)
        #expect(await h.client.sent.count == 2)
        #expect(await h.loop.currentStatus().lastRefreshHold?.hold == .notPlacedInAContext)
    }

    @Test func editingTheContextListDropsTheRecordedVerdict() async throws {
        let settings = Self.enforcing()
        let h = try await Harness(settings: settings)
        await h.client.enqueue(json: Self.triage(false, context: "writing Swift"))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)
        #expect(await h.loop.currentStatus().lastContext?.placement.contextName == "writing Swift")

        var unrelated = settings
        unrelated.toastTimeout = 90
        await h.loop.updateSettings(unrelated)
        #expect(await h.loop.currentStatus().lastContext?.placement.contextName == "writing Swift")

        var edited = unrelated
        edited.contexts = [MentorshipContext(name: "drafting documents")]
        await h.loop.updateSettings(edited)
        #expect(await h.loop.currentStatus().lastContext == nil)
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

    /// The history a relaunched app loads must carry the expiry recorded for a
    /// toast that was still up at quit, not a nil that reads as still showing.
    @Test func expiryRecordedAtQuitIsInHistoryAfterRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("journal.sqlite")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let id: Int64
        do {
            let journal = try Journal(url: url)
            let (stream, _) = AsyncStream<SensingEvent>.makeStream()
            let loop = MentorLoop(
                settings: MentorSettings(), journal: journal, client: ScriptedClaudeClient(),
                keyStore: InMemoryKeyStore(key: "sk-ant-test"), events: stream
            )
            let stored = try await journal.record(Suggestion(
                timestamp: now, bundleID: "com.a", appName: "A", windowTitle: nil, category: .workflow,
                title: "T", body: "B", explanation: "E", confidence: 0.8, observationID: nil, model: "m", promptVersion: 1
            ))
            id = stored.id
            #expect(await loop.recordFeedback(suggestionID: id, feedback: .expired, at: now + 30)?.feedback == .expired)
            await loop.stop()
        }
        let relaunched = try Journal(url: url)
        let history = try await relaunched.recentSuggestions(limit: 10)
        #expect(history.map(\.id) == [id])
        #expect(history.first?.feedback == .expired)
        #expect(history.first?.feedbackAt == now + 30)
        #expect(try await relaunched.recentEvents(limit: 1).first?.detail == "Expired: T")
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

    // MARK: Understanding

    @Test func aMentorCallCarriesTheUnderstandingForwardForFree() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)

        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.revision == 1)
        #expect(record.source == .mentorCall)
        // The mentor call was already paid for, so the refresh rode along free.
        #expect(record.cost == 0)
        #expect(record.cumulativeCost == 0)
        #expect(record.content.primaryGoal?.goal == "ship the mentor loop")
        #expect(record.promptVersion == MentorPrompts.version)

        // And it is in the journal, so a relaunch finds it.
        let stored = try #require(try await h.journal.latestUnderstanding())
        #expect(stored.content == record.content)
        #expect(stored.revision == 1)

        // No call of the understanding tier was made: the refresh was free.
        let calls = try await h.journal.recentModelCalls(limit: 10)
        #expect(!calls.contains { $0.tier == .understanding })
        #expect(await h.loop.currentStatus().understanding?.revision == 1)
    }

    @Test func anExistingUnderstandingGoesToMentorAsItsOwnUncachedSystemBlock() async throws {
        let h = try await Harness(understanding: Self.existing(age: 60))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)

        let sent = await h.client.sent
        let mentor = try #require(sent.last?.request)
        #expect(mentor.system.count == 2)
        #expect(mentor.system[0].text == MentorPrompts.mentorSystem)
        // The prompt keeps its cache marker; the block after it changes on
        // every mentor call, so it carries none.
        #expect(mentor.system[0].cacheControl == .ephemeral)
        #expect(mentor.system[1].cacheControl == nil)
        #expect(mentor.system[1].text.contains("ship the mentor loop"))
        #expect(mentor.system[1].text.contains("revision 1"))
        guard case .text(let mentorText) = mentor.messages[0].content.last else {
            Issue.record("expected the mentor message text")
            return
        }
        #expect(mentorText.contains("standing understanding is the block above"))

        // Triage got the compact paragraph in its user message, not a block.
        let triage = try #require(sent.first?.request)
        #expect(triage.system.count == 1)
        guard case .text(let triageText) = triage.messages[0].content[0] else {
            Issue.record("expected triage to send text")
            return
        }
        #expect(triageText.contains("Standing understanding: The user appears to be working toward: ship the mentor loop"))
    }

    @Test func thereIsNoUnderstandingBlockOrParagraphBeforeOneExists() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)

        let sent = await h.client.sent
        let triage = try #require(sent.first?.request)
        guard case .text(let triageText) = triage.messages[0].content[0] else {
            Issue.record("expected triage to send text")
            return
        }
        #expect(triageText.contains("Standing understanding: none yet"))

        let mentor = try #require(sent.last?.request)
        #expect(mentor.system.count == 1)
        guard case .text(let mentorText) = mentor.messages[0].content.last else {
            Issue.record("expected the mentor message text")
            return
        }
        #expect(mentorText.contains("no standing understanding yet"))
        #expect(mentorText.contains("do not raise the three goal categories"))
    }

    @Test func aMentorReplyWithoutAnUnderstandingLeavesTheRecordAlone() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silenceWithoutUnderstanding, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        #expect(await h.loop.currentUnderstanding() == nil)
        #expect(await h.loop.currentStatus().lastMentor?.outcome == .nothingToSay)
    }

    /// The suggestion is what the user came for, so a malformed understanding
    /// must not take it down with it.
    @Test func aMalformedUnderstandingStillDeliversTheSuggestion() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(
            json: #"{"reason": "r", "suggestion": {"title": "Use --filter", "body": "b", "explanation": "e", "category": "shortcut", "confidence": 0.9, "judged_goal": null}, "updated_understanding": "not an object"}"#,
            model: "claude-opus-5"
        )
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        #expect(await h.loop.currentStatus().lastMentor?.outcome == .suggested)
        #expect(await h.loop.currentUnderstanding() == nil)
    }

    @Test func aPeriodicRefreshRunsWhenNoMentorCallHasAndCountsAgainstSpend() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        // A record older than the interval, so this stretch of work has had no
        // mentor call to carry it and a refresh of its own is due.
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.refresh, model: "claude-opus-5", usage: Usage(inputTokens: 3000, outputTokens: 500))
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 2)

        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.source == .periodic)
        #expect(record.revision == 2)
        #expect(record.cost > 0)
        // The earlier revision's cost carries forward into the running total.
        #expect(record.cumulativeCost == 0.02 + record.cost)

        let refreshCall = try #require(try await h.journal.recentModelCalls(limit: 10).first { $0.tier == .understanding })
        #expect(refreshCall.outcome == .refreshed)
        #expect(refreshCall.detail == "Goal firmed up")
        #expect(refreshCall.imageBytes == 0)
        #expect(refreshCall.cost > 0)

        // It is priced into the hour like every other call.
        let status = await h.loop.currentStatus()
        #expect(status.spendThisHour >= refreshCall.cost)
        #expect(status.callsThisHour == 2)
        #expect(status.lastRefresh?.tier == .understanding)
        #expect(status.understanding?.revision == 2)

        // A refresh is text only, on its own prompt and schema.
        let sent = try #require(await h.client.sent.last?.request)
        #expect(sent.system.first?.text == MentorPrompts.understandingSystem)
        #expect(sent.outputConfig?.format?.schema == MentorPrompts.understandingRefreshSchema)
        #expect(sent.outputConfig?.effort == .low)
        #expect(sent.imageByteCount == 0)
        // And it is given as long as a reply of that size can take.
        #expect(await h.client.sent.last?.timeout == MentorLoop.timeout(forReplyOf: sent.maxTokens))
    }

    /// Work before a break longer than the interval but shorter than the idle
    /// gap is still folded in: a refresh reads everything since the record was
    /// written, not a window around the present.
    @Test func aRefreshAfterABreakStillReadsTheWorkBeforeIt() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        // Written 72 minutes ago; twelve minutes of work followed, then an hour away.
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 72 * 60))
        for minute in 1...12 {
            try await h.journal.record(Fixtures.observation(
                at: Date().addingTimeInterval(Double(-72 * 60 + minute * 60)),
                window: "prebreak-\(minute).swift", text: "prebreak work screen \(minute)"
            ))
        }
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.refresh, model: "claude-opus-5")
        await h.observe(Fixtures.observation(at: Date(), text: "back at the desk"), expectCalls: 2)
        guard case .text(let message)? = await h.client.sent.last?.request.messages[0].content.last else {
            Issue.record("expected a text refresh message")
            return
        }
        #expect(message.contains("prebreak work screen 1\n") || message.contains("prebreak work screen 1 "))
        #expect(message.contains("prebreak work screen 12"))
        #expect(!message.contains("left out"))
    }

    /// A mentor call rewrites the record, so its window takes every screen
    /// journaled after the ones the record's last write read, rather than
    /// stopping at the mentor window.
    @Test func aMentorCallReadsEveryScreenSinceTheRecordWasWritten() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.upperBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 14 * 60, coveredThrough: 0))
        try await h.journal.record(Fixtures.observation(
            at: Date().addingTimeInterval(-13 * 60), window: "early.swift", text: "work just after the record was written"
        ))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date(), text: "the screen now")), expectCalls: 2)
        guard case .text(let message)? = await h.client.sent.last?.request.messages[0].content.last else {
            Issue.record("expected a text mentor message")
            return
        }
        #expect(message.contains("work just after the record was written"))
        #expect(message.contains("the screen now"))
        #expect(!message.contains("left out"))
        #expect(await h.loop.currentUnderstanding()?.revision == 2)
    }

    /// The mentor window also holds screens the record's last write already
    /// read. When the budget leaves some of those out they are still in the
    /// record, so only the ones journaled after them are counted as left out.
    @Test func aMentorCallCountsOnlyTheScreensTheRecordDoesNotCoverAsLeftOut() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.upperBound
        settings.mentorWindowTokenBudget = 500
        let dense = String(repeating: "word ", count: 200)
        let covered = (0..<5).map { i in
            Fixtures.observation(
                at: Date().addingTimeInterval(-300 + Double(i) * 20), window: "before\(i).swift", text: "before \(i) \(dense)"
            )
        }
        let h = try await Harness(
            settings: settings, screens: covered, understanding: Self.existing(age: 120, coveredThrough: 5)
        )
        for i in 0..<5 {
            try await h.journal.record(Fixtures.observation(
                at: Date().addingTimeInterval(-100 + Double(i) * 15), window: "after\(i).swift", text: "after \(i) \(dense)"
            ))
        }
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date(), text: "the screen now")), expectCalls: 2)
        guard case .text(let message)? = await h.client.sent.last?.request.messages[0].content.last else {
            Issue.record("expected a text mentor message")
            return
        }
        // The screen now and the newest before it fit; of the nine older
        // screens left out, the record's last write already read five.
        #expect(message.contains("after 4 word"))
        #expect(!message.contains("after 3 word"))
        #expect(message.contains("4 older screens from this period"))
    }

    /// Relaunches over the same journal and client and runs one mentor call,
    /// returning the text of its message.
    private func mentorMessageAfterRelaunch(_ h: Harness) async throws -> String? {
        await h.loop.stop()
        let relaunched = await Harness(journal: h.journal, client: h.client)
        await h.client.setDelay(.zero)
        let sentBefore = await h.client.sent.count
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await relaunched.observe(
            try await h.journal.record(Fixtures.observation(at: Date(), text: "the screen now")), expectCalls: sentBefore + 2
        )
        guard case .text(let message)? = await h.client.sent.last?.request.messages[0].content.last else { return nil }
        return message
    }

    /// A screen whose capture started before a mentor call read the journal,
    /// but that was journaled after it, is not in that call's window. The
    /// cursor the call stores stops at what it read, so the next window, here
    /// after a relaunch, takes the screen however old its timestamp.
    @Test func aScreenJournaledAfterAMentorCallReadTheJournalIsInTheNextWindow() async throws {
        let h = try await Harness(understanding: Self.existing(age: 60, coveredThrough: 0))
        await h.client.setDelay(.milliseconds(300))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        let read = try await h.journal.record(Fixtures.observation(at: Date()))
        h.input.yield(.observation(read))
        await h.waitUntil { $0.inFlight == .mentor }
        #expect(await h.loop.currentStatus().inFlight == .mentor)
        let late = try await h.journal.record(Fixtures.observation(
            at: Date().addingTimeInterval(-3600), window: "late.swift", text: "captured early, journaled late"
        ))
        await h.waitUntil { $0.lastMentor != nil && $0.inFlight == nil }

        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.revision == 2)
        #expect(record.coveredThroughObservationID == read.id)
        #expect(late.id > read.id)
        let message = try #require(try await mentorMessageAfterRelaunch(h))
        #expect(message.contains("captured early, journaled late"))
    }

    /// The same for a periodic refresh.
    @Test func aScreenJournaledAfterARefreshReadTheJournalIsInTheNextWindow() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400, coveredThrough: 0))
        await h.client.setDelay(.milliseconds(300))
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.refresh, model: "claude-opus-5")
        let read = try await h.journal.record(Fixtures.observation(at: Date()))
        h.input.yield(.observation(read))
        await h.waitUntil { $0.inFlight == .understanding }
        #expect(await h.loop.currentStatus().inFlight == .understanding)
        let late = try await h.journal.record(Fixtures.observation(
            at: Date().addingTimeInterval(-3600), window: "late.swift", text: "captured early, journaled late"
        ))
        await h.waitUntil { $0.lastRefresh != nil && $0.inFlight == nil }

        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.revision == 2)
        #expect(record.source == .periodic)
        #expect(record.coveredThroughObservationID == read.id)
        #expect(late.id > read.id)
        let message = try #require(try await mentorMessageAfterRelaunch(h))
        #expect(message.contains("captured early, journaled late"))
    }

    /// Clearing the journal starts observation ids over, so a cursor from
    /// before it would hide every new screen; one past the largest id left is
    /// treated as covering nothing.
    @Test func aCursorPastTheNewestObservationCoversNothing() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400, coveredThrough: 5000))
        try await h.journal.record(Fixtures.observation(
            at: Date().addingTimeInterval(-60), window: "fresh.swift", text: "work after the ids started over"
        ))
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.refresh, model: "claude-opus-5")
        let now = try await h.journal.record(Fixtures.observation(at: Date()))
        await h.observe(now, expectCalls: 2)
        guard case .text(let message)? = await h.client.sent.last?.request.messages[0].content.last else {
            Issue.record("expected a text refresh message")
            return
        }
        #expect(message.contains("work after the ids started over"))
        #expect(await h.loop.currentUnderstanding()?.coveredThroughObservationID == now.id)
    }

    /// A period with more screens than one journal read returns still tells
    /// the model how many were left out in all.
    @Test func aRefreshCountsTheScreensBeyondTheLookbackAsLeftOut() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        let total = MentorLoop.windowLookback + 5
        for i in 0..<total {
            try await h.journal.record(Fixtures.observation(
                at: Date().addingTimeInterval(-390 + Double(i)), window: "w\(i).swift", text: "screen \(i)"
            ))
        }
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.refresh, model: "claude-opus-5")
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 2)
        guard case .text(let message)? = await h.client.sent.last?.request.messages[0].content.last else {
            Issue.record("expected a text refresh message")
            return
        }
        // Forty entries fit; everything older, read or not, is counted.
        #expect(message.contains("\(total - 40) older screens"))
    }

    /// A refresh that fails is not tried again on the next observation: the
    /// attempt starts the interval over, as the other tiers' calls do.
    @Test func aFailedRefreshWaitsAWholeIntervalBeforeTryingAgain() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(.failure(.api(status: 529, type: "overloaded_error", message: "Overloaded")))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 2)
        #expect(await h.loop.currentStatus().lastRefresh?.outcome == .error)
        #expect(await h.loop.currentUnderstanding()?.revision == 1)

        // The record is as overdue as before, but the attempt was just made.
        await h.observe(Fixtures.observation(id: 2, at: Date(), window: "other.swift"), expectCalls: 2)
        #expect(await h.client.sent.count == 2)
        guard case .notDue = await h.loop.currentStatus().lastRefreshHold?.hold ?? .callInFlight else {
            Issue.record("expected the failed refresh to hold the gate for a whole interval")
            return
        }
    }

    @Test func aRefreshReplyWithNoUnderstandingIsAnErrorAndChangesNothing() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(
            json: #"{"reason": "Nothing known", "understanding": {"goals": [], "timeline": [], "mentor_history": [], "open_concerns": []}}"#,
            model: "claude-opus-5"
        )
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 2)
        let status = await h.loop.currentStatus()
        #expect(status.lastRefresh?.outcome == .error)
        #expect(status.lastRefresh?.detail == "the refresh reply carried no understanding")
        #expect(await h.loop.currentUnderstanding()?.revision == 1)
    }

    @Test func noRefreshCallIsMadeBeforeTheIntervalHasPassed() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 1)
        #expect(await h.client.sent.count == 1)
        guard case .notDue = await h.loop.currentStatus().lastRefreshHold?.hold ?? .callInFlight else {
            Issue.record("expected the refresh to be held as not due")
            return
        }
        #expect(await h.loop.currentUnderstanding() == nil)
    }

    @Test func aDueRefreshStillDoesNotRunWhilePausedOrIdle() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        // Due, exactly as in the test above, but the session is not available.
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        h.input.yield(.modeChanged(.paused))
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 0)
        #expect(await h.client.sent.isEmpty)
        #expect(await h.loop.currentStatus().lastRefreshHold?.hold == .unavailable(.paused))

        h.input.yield(.modeChanged(.idle))
        await h.observe(Fixtures.observation(id: 2, at: Date(), window: "other.swift"), expectCalls: 0)
        #expect(await h.client.sent.isEmpty)
        #expect(await h.loop.currentStatus().lastRefreshHold?.hold == .unavailable(.idle))
        // Nothing was spent and the record is untouched.
        #expect(await h.loop.currentUnderstanding()?.revision == 1)
    }

    /// Runs one mentor call against an existing understanding and returns the
    /// suggestion it produced, for the per-kind cases below.
    private func suggest(category: String, judgedGoal: String?) async throws -> Suggestion? {
        let h = try await Harness(understanding: Self.existing(age: 60))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.suggestion(category: category, judgedGoal: judgedGoal), model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        let events = await h.drain { if case .suggestion = $0 { return true } else { return false } }
        guard case .suggestion(let suggestion)? = events.last else { return nil }
        // Everything shown is journaled with it.
        #expect(try await h.journal.suggestion(id: suggestion.id)?.judgedGoal == suggestion.judgedGoal)
        return suggestion
    }

    @Test(arguments: [
        ("wont_achieve_goal", SuggestionCategory.wontAchieveGoal),
        ("less_efficient", .lessEfficient),
        ("unwanted_side_effect", .unwantedSideEffect),
    ])
    func eachGoalKindArrivesWithTheGoalItWasJudgedAgainst(raw: String, category: SuggestionCategory) async throws {
        let suggestion = try #require(try await suggest(category: raw, judgedGoal: "ship the mentor loop"))
        #expect(suggestion.category == category)
        #expect(suggestion.category.judgesAgainstGoal)
        #expect(suggestion.judgedGoal == "ship the mentor loop")
    }

    @Test func aGoalKindWithNoNamedGoalFallsBackToTheStrongestOne() async throws {
        let suggestion = try #require(try await suggest(category: "less_efficient", judgedGoal: nil))
        #expect(suggestion.judgedGoal == "ship the mentor loop")
    }

    /// The fallback is the goal the model was shown, not the one it put first
    /// in the record it wrote back in the same reply.
    @Test func theFallbackGoalIsTheOneTheModelWasShownNotTheOneItRewrote() async throws {
        let rewritten = """
        {"goals": [{"goal": "rewrite the sensing pipeline", "evidence": "new", "confidence": 0.9}, \
        {"goal": "ship the mentor loop", "evidence": "old", "confidence": 0.6}], \
        "timeline": [], "mentor_history": [], "open_concerns": []}
        """
        let h = try await Harness(understanding: Self.existing(age: 60))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(
            json: Self.suggestion(category: "less_efficient", judgedGoal: nil, understanding: rewritten),
            model: "claude-opus-5"
        )
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        let events = await h.drain { if case .suggestion = $0 { return true } else { return false } }
        guard case .suggestion(let suggestion)? = events.last else {
            Issue.record("expected a suggestion")
            return
        }
        #expect(suggestion.judgedGoal == "ship the mentor loop")
        #expect(await h.loop.currentUnderstanding()?.content.primaryGoal?.goal == "rewrite the sensing pipeline")
    }

    @Test func anOrdinaryCategoryRecordsNoJudgedGoalEvenWhenTheModelNamesOne() async throws {
        let suggestion = try #require(try await suggest(category: "shortcut", judgedGoal: "ship the mentor loop"))
        #expect(suggestion.category == .shortcut)
        #expect(suggestion.judgedGoal == nil)
    }

    @Test func neverForThisSuppressesTheOneGoalKindItWasSetFor() async throws {
        var settings = MentorSettings()
        settings.neverRules = [NeverRule(
            bundleID: "com.apple.dt.Xcode", appName: "Xcode", category: .wontAchieveGoal, createdAt: Date()
        )]
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 60))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.suggestion(category: "wont_achieve_goal", judgedGoal: "g"), model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        #expect(await h.loop.currentStatus().lastMentor?.outcome == .suppressed)
        // And the model was told not to raise it in the first place.
        guard case .text(let mentorText)? = await h.client.sent.last?.request.messages[0].content.last else {
            Issue.record("expected the mentor message text")
            return
        }
        #expect(mentorText.contains("wont_achieve_goal"))
    }

    @Test func neverForOneGoalKindLeavesItsSiblingsAlone() async throws {
        var settings = MentorSettings()
        settings.neverRules = [NeverRule(
            bundleID: "com.apple.dt.Xcode", appName: "Xcode", category: .wontAchieveGoal, createdAt: Date()
        )]
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 60))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.suggestion(category: "less_efficient", judgedGoal: "g"), model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        #expect(await h.loop.currentStatus().lastMentor?.outcome == .suggested)
    }

    /// A goal kind needs a goal to be judged against, so one raised on a
    /// request that carried no understanding, or one with no goal in it, is
    /// dropped like a suppressed category and journaled with why.
    @Test(arguments: [false, true])
    func aGoalKindRaisedWithNoGoalToJudgeAgainstIsDroppedAndJournaled(recordWithoutGoals: Bool) async throws {
        let goalless = UnderstandingRecord.first(
            content: Understanding(timeline: ["opened the editor"]), at: Date().addingTimeInterval(-60),
            model: "claude-opus-5", source: .periodic, cost: 0, promptVersion: MentorPrompts.version
        )
        let h = try await Harness(understanding: recordWithoutGoals ? goalless : nil)
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(
            json: Self.suggestion(category: "wont_achieve_goal", judgedGoal: "get the release out"), model: "claude-opus-5"
        )
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)

        #expect(await h.loop.currentStatus().lastMentor?.outcome == .suppressed)
        let call = try #require(try await h.journal.recentModelCalls(limit: 5).first { $0.tier == .mentor })
        #expect(call.outcome == .suppressed)
        #expect(call.detail == "Use --filter (no goal to judge against)")
        #expect(try await h.journal.recentSuggestions(limit: 5).isEmpty)
        #expect(!(try await h.journal.recentEvents(limit: 10)).contains { $0.kind == .suggested })
    }

    /// The menu's goal line is hidden while nothing can work a goal out: with
    /// Mentor off or without a key. A reached spend cap only delays it.
    @Test func onlyAMentorThatIsOnAndHasAKeyFormsAnUnderstanding() async throws {
        #expect(await (try Harness()).loop.currentStatus().availability.formsUnderstanding)
        #expect(await !(try Harness(key: nil)).loop.currentStatus().availability.formsUnderstanding)
        var off = MentorSettings()
        off.enabled = false
        #expect(await !(try Harness(settings: off)).loop.currentStatus().availability.formsUnderstanding)
        #expect(MentorStatus.Availability.capReached(until: Date()).formsUnderstanding)
    }

    /// Reset pressed while a mentor call is in flight: the reply's rewritten
    /// record describes what was just forgotten, so it is not stored.
    @Test func aResetDuringAMentorCallIsNotUndoneByItsReply() async throws {
        let h = try await Harness(understanding: Self.existing(age: 60))
        await h.client.setDelay(.milliseconds(400))
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        h.input.yield(.observation(Fixtures.observation(at: Date())))
        var waited = 0
        while await h.loop.currentStatus().inFlight != .mentor, waited < 250 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(await h.loop.currentStatus().inFlight == .mentor)

        await h.loop.resetUnderstanding()
        while await h.loop.currentStatus().inFlight != nil, waited < 500 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(await h.loop.currentStatus().lastMentor?.outcome == .nothingToSay)
        #expect(await h.loop.currentUnderstanding() == nil)
        #expect(try await h.journal.latestUnderstanding() == nil)
    }

    @Test func resetForgetsTheUnderstandingAndJournalsIt() async throws {
        let h = try await Harness()
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: Self.silence, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)
        #expect(await h.loop.currentUnderstanding() != nil)

        await h.loop.resetUnderstanding()
        #expect(await h.loop.currentUnderstanding() == nil)
        #expect(await h.loop.currentStatus().understanding == nil)
        #expect(try await h.journal.latestUnderstanding() == nil)
        let events = try await h.journal.recentEvents(limit: 10)
        #expect(events.contains { $0.kind == .understanding && ($0.detail ?? "").contains("reset") })
    }

    /// After a reset the next stretch gets a whole interval for a mentor call
    /// to write the record for free, rather than buying a refresh at once.
    @Test func resetStartsAFreshRefreshPeriodInsteadOfSpendingImmediately() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 400))
        await h.loop.resetUnderstanding()
        #expect(await h.loop.currentUnderstanding() == nil)

        // The record was long overdue, but the reset cleared the period with it,
        // so the next observation triages and nothing refreshes.
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 1)
        #expect(await h.client.sent.count == 1)
        #expect(!(try await h.journal.recentModelCalls(limit: 10)).contains { $0.tier == .understanding })
        guard case .notDue = await h.loop.currentStatus().lastRefreshHold?.hold ?? .callInFlight else {
            Issue.record("expected a fresh period after the reset, not an immediate refresh")
            return
        }
    }

    /// The record expires on an observation, not at launch, and the stretch
    /// after it still gets a whole interval before any refresh of its own.
    @Test func anExpiryOnAnObservationStartsAFreshRefreshPeriodInsteadOfSpendingImmediately() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        // Current at launch: well inside the default idle gap.
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 1200))
        #expect(await h.loop.currentUnderstanding() != nil)
        // Shrinking the gap below the record's age makes the next observation expire it.
        settings.understandingIdleGap = 600
        await h.loop.updateSettings(settings)

        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 1)
        #expect(await h.loop.currentUnderstanding() == nil)
        let events = try await h.journal.recentEvents(limit: 10)
        #expect(events.contains { $0.kind == .understanding && ($0.detail ?? "").contains("expired") })
        // Long overdue by the old record's clock, but that record is gone and
        // this observation started a new period, so nothing refreshes.
        #expect(await h.client.sent.count == 1)
        #expect(!(try await h.journal.recentModelCalls(limit: 10)).contains { $0.tier == .understanding })
        guard case .notDue = await h.loop.currentStatus().lastRefreshHold?.hold ?? .callInFlight else {
            Issue.record("expected a fresh period after the expiry, not an immediate refresh")
            return
        }
    }

    /// A record that expired from the idle gap while running stays expired
    /// after a relaunch, even though the activity that expired it is now the
    /// journal's newest observation and would otherwise make it look current.
    @Test func anIdleExpiryWhileRunningIsNotUndoneByARelaunch() async throws {
        var settings = MentorSettings()
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 1200))
        settings.understandingIdleGap = 600
        await h.loop.updateSettings(settings)
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 1)
        #expect(await h.loop.currentUnderstanding() == nil)

        await h.loop.stop()
        let relaunched = await Harness(settings: settings, journal: h.journal, client: h.client)
        #expect(await relaunched.loop.currentUnderstanding() == nil)
        #expect(await relaunched.loop.currentStatus().understanding == nil)
        let expiries = try await h.journal.recentEvents(limit: 20).filter {
            $0.kind == .understanding && ($0.detail ?? "").contains("expired")
        }
        #expect(expiries.count == 1)
    }

    /// The idle gap runs from the user's last activity, not from the record's
    /// last write, so steady work with no mentor call keeps the record alive.
    @Test func steadyActivityKeepsTheUnderstandingPastTheIdleGapSinceItsLastWrite() async throws {
        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.upperBound
        let h = try await Harness(settings: settings, understanding: Self.existing(age: 1200))
        await h.client.enqueue(json: Self.no, model: "claude-haiku-4-5-20251001")
        await h.observe(Fixtures.observation(id: 1, at: Date()), expectCalls: 1)
        // The record is now older than the gap, but the user was active a moment ago.
        settings.understandingIdleGap = 600
        await h.loop.updateSettings(settings)
        await h.observe(Fixtures.observation(id: 2, at: Date(), window: "other.swift"), expectCalls: 1)
        #expect(await h.loop.currentUnderstanding()?.revision == 1)
        #expect(!(try await h.journal.recentEvents(limit: 10)).contains { $0.kind == .understanding })
    }

    /// At launch the journal's newest observation stands in for the activity
    /// this run has not seen, so a record older than the gap survives when
    /// the user was active recently and expires when they were not.
    @Test(arguments: [(60.0, true), (5000.0, false)])
    func atLaunchTheIdleGapRunsFromTheJournalsNewestObservation(observationAge: Double, kept: Bool) async throws {
        var settings = MentorSettings()
        settings.understandingIdleGap = 600
        let h = try await Harness(settings: settings)
        try await h.journal.record(UnderstandingRecord.first(
            content: Understanding(goals: [Understanding.Goal(goal: "carried over", evidence: "e", confidence: 0.9)]),
            at: Date().addingTimeInterval(-7200), model: "claude-opus-5", source: .periodic,
            cost: 0.01, promptVersion: MentorPrompts.version
        ))
        try await h.journal.record(Fixtures.observation(at: Date().addingTimeInterval(-observationAge)))
        let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
        let loop = MentorLoop(
            settings: settings, journal: h.journal, client: h.client, keyStore: h.keyStore, events: stream,
            calendar: Self.middayCalendar
        )
        await loop.start()
        continuation.yield(.modeChanged(.watching))
        #expect((await loop.currentUnderstanding() != nil) == kept)
        let events = try await h.journal.recentEvents(limit: 10)
        #expect(events.contains { $0.kind == .understanding && ($0.detail ?? "").contains("expired") } == !kept)
        await loop.stop()
    }

    @Test func anExpiredUnderstandingIsDroppedAndJournaledAtLaunch() async throws {
        var settings = MentorSettings()
        settings.understandingIdleGap = 600
        let h = try await Harness(settings: settings)
        // Store a record last written well beyond the idle gap.
        try await h.journal.record(UnderstandingRecord.first(
            content: Understanding(goals: [Understanding.Goal(goal: "stale goal", evidence: "e", confidence: 0.9)]),
            at: Date().addingTimeInterval(-7200), model: "claude-opus-5", source: .periodic,
            cost: 0.01, promptVersion: MentorPrompts.version
        ))
        // A fresh loop over the same journal seeds from it and expires it.
        let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
        let loop = MentorLoop(
            settings: settings, journal: h.journal, client: h.client, keyStore: h.keyStore, events: stream,
            calendar: Self.middayCalendar
        )
        await loop.start()
        continuation.yield(.modeChanged(.watching))
        #expect(await loop.currentUnderstanding() == nil)
        let events = try await h.journal.recentEvents(limit: 10)
        #expect(events.contains { $0.kind == .understanding && ($0.detail ?? "").contains("expired") })
        await loop.stop()
    }

    @Test func anUnexpiredUnderstandingSurvivesARelaunch() async throws {
        let h = try await Harness()
        let content = Understanding(goals: [Understanding.Goal(goal: "carried over", evidence: "e", confidence: 0.9)])
        try await h.journal.record(UnderstandingRecord.first(
            content: content, at: Date().addingTimeInterval(-60), model: "claude-opus-5",
            source: .periodic, cost: 0.01, promptVersion: MentorPrompts.version
        ))
        let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
        let loop = MentorLoop(
            settings: MentorSettings(), journal: h.journal, client: h.client, keyStore: h.keyStore, events: stream,
            calendar: Self.middayCalendar
        )
        await loop.start()
        continuation.yield(.modeChanged(.watching))
        let record = try #require(await loop.currentUnderstanding())
        #expect(record.content.primaryGoal?.goal == "carried over")
        #expect(record.cumulativeCost == 0.01)
        await loop.stop()
    }

    @Test func anOversizedUnderstandingIsTrimmedToTheBudgetBeforeItIsStored() async throws {
        var settings = MentorSettings()
        settings.understandingTokenBudget = 200
        let h = try await Harness(settings: settings)
        let long = (0..<60).map { "\"a fairly long sentence about step \($0) of the work in progress\"" }.joined(separator: ", ")
        let big = """
        {"goals": [{"goal": "the one goal", "evidence": "e", "confidence": 0.9}], \
        "timeline": [\(long)], "mentor_history": [], "open_concerns": []}
        """
        await h.client.enqueue(json: Self.yes, model: "claude-haiku-4-5-20251001")
        await h.client.enqueue(json: #"{"reason": "r", "suggestion": null, "updated_understanding": \#(big)}"#, model: "claude-opus-5")
        await h.observe(try await h.journal.record(Fixtures.observation(at: Date())), expectCalls: 2)

        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.content.estimatedTokens <= 200)
        #expect(record.content.primaryGoal?.goal == "the one goal")
        #expect(record.content.timeline.count < 60)
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

    @Test func understandingRevisionsRoundTripAndAreClearedWithTheJournal() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = Understanding(
            goals: [Understanding.Goal(goal: "ship it", evidence: "hours in one file", confidence: 0.8)],
            timeline: ["opened the editor"], mentorHistory: ["said use --filter"], openConcerns: ["no tests"]
        )
        let first = try await journal.record(UnderstandingRecord.first(
            content: content, at: now, model: "claude-opus-5", source: .periodic, cost: 0.03, promptVersion: 4
        ))
        #expect(first.id > 0)
        #expect(try await journal.latestUnderstanding() == first)

        // A second revision becomes the current one, with the cursor its call
        // read through; the first stays as trail.
        let second = try await journal.record(first.next(
            content: content, at: now + 900, model: "claude-opus-5", source: .mentorCall, cost: 0, promptVersion: 4,
            coveredThroughObservationID: 57
        ))
        #expect(try await journal.latestUnderstanding() == second)
        #expect(try await journal.latestUnderstanding()?.revision == 2)
        // Retention that reaches only the first revision still finds it there.
        let trimmed = try await journal.applyRetention(
            RetentionPolicy(thumbnailMaxAge: 600, textMaxAge: 600, sizeCapBytes: 1 << 30), now: now + 901
        )
        #expect(trimmed.understandingDeleted == 1)
        #expect(try await journal.latestUnderstanding() == second)

        try await journal.clear()
        #expect(try await journal.latestUnderstanding() == nil)
    }

    @Test func resetForgetsEveryRevisionWithoutTouchingTheRestOfTheJournal() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await journal.record(UnderstandingRecord.first(
            content: Understanding(goals: [Understanding.Goal(goal: "g", evidence: "e", confidence: 1)]),
            at: now, model: "m", source: .periodic, cost: 0, promptVersion: 4
        ))
        try await journal.record(Suggestion(
            timestamp: now, bundleID: nil, appName: "A", windowTitle: nil, category: .shortcut,
            title: "kept", body: "", explanation: "", confidence: 1, observationID: nil, model: "m", promptVersion: 4
        ))
        try await journal.clearUnderstanding()
        #expect(try await journal.latestUnderstanding() == nil)
        #expect(try await journal.recentSuggestions(limit: 5).count == 1)
    }

    /// An expiry journaled after a revision keeps that revision from being
    /// current, and a revision written after the expiry is current again.
    @Test func aRevisionIsNotCurrentOnceAnExpiryFollowsIt() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = Understanding(goals: [Understanding.Goal(goal: "g", evidence: "e", confidence: 1)])
        let earlier = try await journal.record(UnderstandingRecord.first(
            content: content, at: now - 900, model: "m", source: .periodic, cost: 0, promptVersion: 4
        ))
        let expired = try await journal.record(earlier.next(
            content: content, at: now, model: "m", source: .mentorCall, cost: 0, promptVersion: 4
        ))
        // Unrelated events do not end it.
        try await journal.record(JournalEvent(timestamp: now + 5, kind: .appSwitch))
        #expect(try await journal.latestUnderstanding() == expired)
        try await journal.record(JournalEvent(
            timestamp: now + 10, kind: .understanding, detail: "expired after revision 1: no activity for 10m"
        ))
        // Neither it nor the revision before it comes back.
        #expect(try await journal.latestUnderstanding() == nil)

        let fresh = try await journal.record(UnderstandingRecord.first(
            content: content, at: now + 20, model: "m", source: .mentorCall, cost: 0, promptVersion: 4
        ))
        #expect(try await journal.latestUnderstanding() == fresh)
    }

    @Test func understandingExpiresWithTextRetention() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = Understanding(goals: [Understanding.Goal(goal: "g", evidence: "e", confidence: 1)])
        try await journal.record(UnderstandingRecord.first(
            content: content, at: now - 10 * 86400, model: "m", source: .periodic, cost: 0, promptVersion: 4
        ))
        let recent = try await journal.record(UnderstandingRecord.first(
            content: content, at: now - 60, model: "m", source: .periodic, cost: 0, promptVersion: 4
        ))
        let result = try await journal.applyRetention(
            RetentionPolicy(thumbnailMaxAge: 3600, textMaxAge: 7 * 86400, sizeCapBytes: 1 << 30), now: now
        )
        #expect(result.understandingDeleted == 1)
        #expect(result.deletedAnything)
        #expect(try await journal.latestUnderstanding() == recent)
    }

    /// A journal written by the previous build has a `suggestions` table with
    /// no `judged_goal` column, and `CREATE TABLE IF NOT EXISTS` leaves it
    /// alone, so opening it must add the column rather than fail every read.
    @Test func opensAJournalWrittenBeforeTheJudgedGoalColumnExisted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mentor-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // The phase-two schema, without judged_goal and without understanding.
        let old = try SQLiteConnection(path: url.path)
        try old.execute("""
            CREATE TABLE suggestions (
                id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, bundle_id TEXT, app_name TEXT NOT NULL,
                window_title TEXT, category TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
                explanation TEXT NOT NULL, confidence REAL NOT NULL, observation_id INTEGER,
                model TEXT NOT NULL, prompt_version INTEGER NOT NULL, feedback TEXT, feedback_at REAL
            );
            INSERT INTO suggestions (timestamp, app_name, category, title, body, explanation, confidence, model, prompt_version)
            VALUES (1700000000, 'Xcode', 'shortcut', 'old one', 'b', 'e', 0.9, 'm', 3);
            """)

        let journal = try Journal(url: url)
        // The row from the old schema still reads, with no goal.
        let existing = try await journal.recentSuggestions(limit: 5)
        #expect(existing.count == 1)
        #expect(existing.first?.title == "old one")
        #expect(existing.first?.judgedGoal == nil)

        // And new rows can use the column that was just added.
        let stored = try await journal.record(Suggestion(
            timestamp: Date(), bundleID: nil, appName: "Xcode", windowTitle: nil, category: .lessEfficient,
            title: "new one", body: "b", explanation: "e", confidence: 0.8, judgedGoal: "the goal",
            observationID: nil, model: "m", promptVersion: MentorPrompts.version
        ))
        #expect(try await journal.suggestion(id: stored.id)?.judgedGoal == "the goal")
        // The understanding table was created on the same open.
        #expect(try await journal.latestUnderstanding() == nil)

        // Opening it a second time must not try to add the column again.
        let reopened = try Journal(url: url)
        #expect(try await reopened.recentSuggestions(limit: 5).count == 2)
    }

    /// A journal written by an earlier build of the understanding has no
    /// cursor column; its revisions still read, with no cursor, and new ones
    /// store theirs.
    @Test func opensAJournalWrittenBeforeTheCursorColumnExisted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mentor-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try SQLiteConnection(path: url.path)
        try old.execute("""
            CREATE TABLE understanding (
                id INTEGER PRIMARY KEY, updated_at REAL NOT NULL, started_at REAL NOT NULL,
                revision INTEGER NOT NULL, schema_version INTEGER NOT NULL, prompt_version INTEGER NOT NULL,
                model TEXT NOT NULL, source TEXT NOT NULL, cost REAL NOT NULL, cumulative_cost REAL NOT NULL,
                content_json TEXT NOT NULL
            );
            INSERT INTO understanding (updated_at, started_at, revision, schema_version, prompt_version, model,
                source, cost, cumulative_cost, content_json)
            VALUES (1700000000, 1700000000, 1, 1, 6, 'm', 'periodic', 0, 0, '{"goals": [], "timeline": ["old"]}');
            """)

        let journal = try Journal(url: url)
        let existing = try #require(try await journal.latestUnderstanding())
        #expect(existing.content.timeline == ["old"])
        #expect(existing.coveredThroughObservationID == nil)

        let next = try await journal.record(existing.next(
            content: existing.content, at: existing.updatedAt + 60, model: "m", source: .mentorCall,
            cost: 0, promptVersion: MentorPrompts.version, coveredThroughObservationID: 42
        ))
        #expect(try await Journal(url: url).latestUnderstanding() == next)
    }

    @Test func aSuggestionsJudgedGoalSurvivesTheJournal() async throws {
        let journal = try Journal.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = try await journal.record(Suggestion(
            timestamp: now, bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: nil,
            category: .unwantedSideEffect, title: "t", body: "b", explanation: "e", confidence: 0.8,
            judgedGoal: "ship the release", observationID: nil, model: "m", promptVersion: 4
        ))
        #expect(try await journal.suggestion(id: stored.id)?.judgedGoal == "ship the release")
        #expect(try await journal.suggestion(id: stored.id)?.category == .unwantedSideEffect)
        // A suggestion from before the column existed reads back as nil.
        let plain = try await journal.record(Suggestion(
            timestamp: now, bundleID: nil, appName: "A", windowTitle: nil, category: .shortcut,
            title: "t", body: "b", explanation: "e", confidence: 1, observationID: nil, model: "m", promptVersion: 4
        ))
        #expect(try await journal.suggestion(id: plain.id)?.judgedGoal == nil)
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
