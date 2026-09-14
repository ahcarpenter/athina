import Foundation
import Testing
@testable import MentorCore

/// The mentor loop on a replay client: replays are journaled as replays, cost
/// nothing, never touch the key, and the committed fixture set carries the
/// whole path from triage to a suggestion and its feedback.
@Suite struct ReplayLoopTests {
    /// Counts reads, so a test can prove the keychain is never asked.
    private final class CountingKeyStore: KeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var loadCount: Int { lock.withLock { reads } }
        func load() throws -> String? {
            lock.withLock { reads += 1 }
            return nil
        }
        func save(_ key: String) throws {}
        func delete() throws {}
    }

    private struct Harness {
        let loop: MentorLoop
        let input: AsyncStream<SensingEvent>.Continuation
        let output: AsyncStream<MentorEvent>

        init(journal: Journal, client: any ClaudeClient, keyStore: any KeyStore = InMemoryKeyStore(), settings: MentorSettings = MentorSettings()) async {
            let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
            input = continuation
            loop = MentorLoop(settings: settings, journal: journal, client: client, keyStore: keyStore, events: stream)
            output = await loop.events()
            await loop.start()
            input.yield(.modeChanged(.watching))
        }

        /// Sends an observation and waits until the loop has gated it and
        /// finished every call it started for it.
        func observe(_ observation: ActivityObservation, calls: @Sendable () async -> Int, expectCalls: Int) async {
            input.yield(.observation(observation))
            for _ in 0..<250 {
                let status = await loop.currentStatus()
                if status.lastGate?.observationID == observation.id, status.inFlight == nil, await calls() >= expectCalls {
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        func nextSuggestion() async -> Suggestion? {
            let deadline = Date().addingTimeInterval(5)
            var iterator = output.makeAsyncIterator()
            while Date() < deadline {
                guard let event = await iterator.next() else { return nil }
                if case .suggestion(let suggestion) = event { return suggestion }
            }
            return nil
        }
    }

    private static func fixture(_ kind: String, _ json: String, model: String) -> ReplayClaudeClient.Entry {
        ReplayClaudeClient.Entry(name: "\(kind).json", fixture: CallFixture(
            identity: CallIdentity(kind: kind, promptVersion: MentorPrompts.version),
            recordedAt: Date(timeIntervalSince1970: 1_789_000_000),
            request: CallFixtureTests.request(),
            result: .success(MessagesResponse(
                id: "msg", model: model, stopReason: "end_turn",
                content: [ResponseBlock(type: "text", text: json)],
                usage: Usage(inputTokens: 5000, outputTokens: 800, cacheCreationInputTokens: 1200, cacheReadInputTokens: 0)
            )),
            latency: 2, cost: 0.03
        ))
    }

    private static let candidateAndSuggestion = [
        fixture("triage", #"{"worth_a_look": true, "reason": "Renaming files one at a time"}"#, model: "claude-haiku-4-5-20251001"),
        fixture("mentor", #"{"reason": "Manual renames", "suggestion": {"title": "Rename them in one go", "body": "Finder renames a selection at once.", "explanation": "Select the files, then File > Rename.", "category": "tool", "confidence": 0.9}}"#, model: "claude-sonnet-5"),
    ]

    // MARK: Journaling and spend

    private let settingsMentorModel = MentorSettings().mentorModel

    @Test func replayedCallsAreJournaledAsReplaysAndNeverBilled() async throws {
        let journal = try Journal.inMemory()
        let client = ReplayClaudeClient(entries: Self.candidateAndSuggestion)
        let keys = CountingKeyStore()
        let h = await Harness(journal: journal, client: client, keyStore: keys)

        // No key is saved, and none is needed.
        #expect(await h.loop.currentStatus().availability == .ready)
        await h.observe(Fixtures.observation(id: 1, at: Date()), calls: { await client.served.count }, expectCalls: 2)
        let suggestion = try #require(await h.nextSuggestion())
        #expect(suggestion.title == "Rename them in one go")
        #expect(suggestion.model == "claude-sonnet-5")

        let status = await h.loop.currentStatus()
        #expect(status.lastTriage?.outcome == .candidate)
        #expect(status.lastMentor?.outcome == .suggested)
        #expect(status.lastMentor?.replayed == true)
        // The log names the model that gave the recorded answer, not the one the settings ask for.
        #expect(status.lastMentor?.model == "claude-sonnet-5")
        #expect(settingsMentorModel != "claude-sonnet-5")
        #expect(status.spendThisHour == 0)
        #expect(status.callsThisHour == 0)
        #expect(status.cadenceMultiplier == 1)

        let calls = try await journal.recentModelCalls(limit: 10)
        #expect(calls.map(\.tier) == [.mentor, .triage])
        #expect(calls.allSatisfy { $0.replayed && $0.cost == 0 })
        // The recorded usage is kept, so the log still shows what the call read.
        #expect(calls.first?.usage.cacheCreationInputTokens == 1200)
        #expect(await client.served.map(\.call) == [
            CallIdentity(kind: "triage", promptVersion: MentorPrompts.version),
            CallIdentity(kind: "mentor", promptVersion: MentorPrompts.version),
        ])
        #expect(keys.loadCount == 0)
        #expect(await h.loop.hasAPIKey)

        // Test Connection in replay mode replays too, and still reads no key.
        #expect(await h.loop.testConnection() == .failure(.replay("no recorded test call to replay")))
        #expect(try await journal.recentModelCalls(limit: 1).first?.replayed == true)
        #expect(keys.loadCount == 0)
    }

    @Test func aReplayingLoopIgnoresLiveSpendAndTheCap() async throws {
        let journal = try Journal.inMemory()
        try await journal.record(ModelCallRecord(
            timestamp: Date(), tier: .mentor, model: "claude-opus-5", promptVersion: MentorPrompts.version,
            promptCharacters: 10, imageBytes: 0, usage: Usage(), cost: 5, latency: 1, outcome: .suggested, detail: "live"
        ))
        var settings = MentorSettings()
        settings.hourlySpendCap = 0.05
        let client = ReplayClaudeClient(entries: Self.candidateAndSuggestion)
        let h = await Harness(journal: journal, client: client, settings: settings)
        let before = await h.loop.currentStatus()
        #expect(before.availability == .ready)
        #expect(before.spendThisHour == 0)
        // The live call is not presented as this run's last mentor call.
        #expect(before.lastMentor == nil)

        await h.observe(Fixtures.observation(id: 1, at: Date()), calls: { await client.served.count }, expectCalls: 2)
        #expect(await client.served.count == 2)
        #expect(await h.loop.currentStatus().lastMentor?.outcome == .suggested)
    }

    @Test func aLiveLoopCountsOnlyLiveCallsTowardTheHour() async throws {
        let journal = try Journal.inMemory()
        try await journal.record(ModelCallRecord(
            timestamp: Date(), tier: .triage, model: "claude-haiku-4-5-20251001", promptVersion: MentorPrompts.version,
            promptCharacters: 10, imageBytes: 0, usage: Usage(inputTokens: 900), cost: 0, latency: 0.1, outcome: .quiet, detail: "replayed", replayed: true
        ))
        try await journal.record(ModelCallRecord(
            timestamp: Date(), tier: .triage, model: "claude-haiku-4-5-20251001", promptVersion: MentorPrompts.version,
            promptCharacters: 10, imageBytes: 0, usage: Usage(inputTokens: 900), cost: 0.001, latency: 0.1, outcome: .candidate, detail: "live"
        ))
        let h = await Harness(journal: journal, client: ScriptedClaudeClient(), keyStore: InMemoryKeyStore(key: "sk-ant-test"))
        let status = await h.loop.currentStatus()
        #expect(status.callsThisHour == 1)
        #expect(status.spendThisHour == 0.001)
        #expect(status.lastTriage?.detail == "live")
    }

    @Test func theReplayedFlagSurvivesTheJournal() async throws {
        let journal = try Journal.inMemory()
        let stored = try await journal.record(ModelCallRecord(
            timestamp: Date(timeIntervalSince1970: 1_789_000_000), tier: .mentor, model: "claude-sonnet-5", promptVersion: 4,
            promptCharacters: 1, imageBytes: 2, usage: Usage(inputTokens: 3), cost: 0, latency: 1, outcome: .nothingToSay, detail: nil, replayed: true
        ))
        #expect(try await journal.recentModelCalls(limit: 1) == [stored])
        #expect(try await journal.modelCalls(since: .distantPast).first?.replayed == true)
    }

    /// A journal written before the replayed column existed gains it, with
    /// every old call counted as live.
    @Test func anOlderJournalGainsTheReplayedColumn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("journal.sqlite")
        let old = try SQLiteConnection(path: url.path)
        try old.execute("""
            CREATE TABLE model_calls (
                id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, tier TEXT NOT NULL, model TEXT NOT NULL,
                prompt_version INTEGER NOT NULL, prompt_chars INTEGER NOT NULL, image_bytes INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL, cost REAL NOT NULL, latency REAL NOT NULL, outcome TEXT NOT NULL, detail TEXT
            );
            INSERT INTO model_calls (timestamp, tier, model, prompt_version, prompt_chars, image_bytes, input_tokens,
                output_tokens, cache_write_tokens, cache_read_tokens, cost, latency, outcome, detail)
            VALUES (1789000000, 'triage', 'claude-haiku-4-5-20251001', 4, 10, 0, 1, 1, 0, 0, 0.01, 1, 'quiet', 'old');
            """)
        let journal = try Journal(url: url)
        let calls = try await journal.recentModelCalls(limit: 5)
        #expect(calls.count == 1)
        #expect(calls.first?.replayed == false)
        #expect(calls.first?.detail == "old")
        _ = try Journal(url: url)
    }

    // MARK: The committed fixture set

    /// Set `MENTOR_ALLOW_STALE_FIXTURES=1` to run this against fixtures from an
    /// older prompt version while iterating on prompts, before recording anew.
    private static var allowStale: Bool {
        ProcessInfo.processInfo.environment["MENTOR_ALLOW_STALE_FIXTURES"] == "1"
    }

    static func committedFixturesDirectory() throws -> URL {
        try #require(Bundle.module.url(forResource: "Replay", withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test func theCommittedFixturesAreCurrentCoverEveryKindAndHoldNoKey() throws {
        let directory = try Self.committedFixturesDirectory()
        let loaded = try CallFixtureFiles.load(from: directory)
        let stale = loaded.filter { $0.fixture.identity.promptVersion != MentorPrompts.version }
        if !Self.allowStale {
            for entry in stale {
                Issue.record(Comment(rawValue: ReplayClaudeClient.staleMessage(
                    fixture: entry.name, recorded: entry.fixture.identity.promptVersion, current: MentorPrompts.version
                )))
            }
        }
        let kinds = Set(loaded.map(\.fixture.identity.kind))
        #expect(kinds.isSuperset(of: ModelTier.allCases.map(\.rawValue)), "every call kind needs a recording: \(kinds.sorted())")

        let triage = loaded.filter { $0.fixture.identity.kind == ModelTier.triage.rawValue }.compactMap { entry in
            (try? entry.fixture.result.get()).flatMap { MentorLoop.decode(TriageVerdict.self, from: $0) }
        }
        #expect(triage.contains { $0.worthALook }, "a triage recording must send the moment to the mentor")
        #expect(triage.contains { !$0.worthALook }, "a triage recording must pass on a moment")
        let mentor = loaded.filter { $0.fixture.identity.kind == ModelTier.mentor.rawValue }.compactMap { entry in
            (try? entry.fixture.result.get()).flatMap { MentorLoop.decode(MentorVerdict.self, from: $0) }
        }
        #expect(
            mentor.contains { ($0.suggestion?.confidence ?? 0) >= MentorSettings().minimumConfidence },
            "a mentor recording must carry a suggestion that is shown"
        )

        for entry in loaded {
            let text = try String(contentsOf: directory.appendingPathComponent(entry.name), encoding: .utf8)
            #expect(!text.contains("sk-ant-"), "\(entry.name) must not carry a key")
            #expect(!text.contains("\u{2014}"), "\(entry.name) must not carry an em dash")
        }
    }

    /// Every triage recording in turn, on the loop the app runs: a candidate
    /// reaches the mentor recording next in line, a shown suggestion takes
    /// feedback, and after the last recording the first answers again.
    @Test func theCommittedFixturesDriveTheWholeLoop() async throws {
        let directory = try Self.committedFixturesDirectory()
        let client = try ReplayClaudeClient.load(from: directory, allowStale: Self.allowStale)
        let journal = try Journal.inMemory()
        let settings = MentorSettings()
        let triageEntries = client.entries.filter { $0.fixture.identity.kind == ModelTier.triage.rawValue }
        let mentorEntries = client.entries.filter { $0.fixture.identity.kind == ModelTier.mentor.rawValue }
        try #require(!triageEntries.isEmpty && !mentorEntries.isEmpty)

        var nextMentor = 0
        var shown: [Suggestion] = []
        var lastHarness: Harness?
        // Every triage recording, then the first again: past the last
        // recording the cycle starts over.
        let walk = Array(triageEntries.enumerated()) + [(triageEntries.count, triageEntries[0])]
        for (index, entry) in walk {
            // A fresh loop per moment, on one journal and one client, so the
            // debounce never holds a moment and the cycle carries on.
            let h = await Harness(journal: journal, client: client, settings: settings)
            let verdict = try #require((try? entry.fixture.result.get()).flatMap { MentorLoop.decode(TriageVerdict.self, from: $0) })
            let before = await client.served.count
            let expected = before + (verdict.worthALook ? 2 : 1)
            await h.observe(
                Fixtures.observation(id: Int64(index + 1), at: Date(), window: "moment \(index)", text: "moment \(index)"),
                calls: { await client.served.count }, expectCalls: expected
            )
            let served = await client.served
            #expect(served.count == expected)
            #expect(served[before].fixtureName == entry.name)
            let status = await h.loop.currentStatus()
            #expect(status.lastTriage?.outcome == (verdict.worthALook ? .candidate : .quiet))
            #expect(status.lastTriage?.detail == verdict.reason.withPlainDashes)

            if verdict.worthALook {
                let mentorEntry = mentorEntries[nextMentor % mentorEntries.count]
                nextMentor += 1
                #expect(served[before + 1].fixtureName == mentorEntry.name)
                let reply = try #require((try? mentorEntry.fixture.result.get()).flatMap { MentorLoop.decode(MentorVerdict.self, from: $0) })
                if let payload = reply.suggestion, payload.confidence >= settings.minimumConfidence {
                    #expect(status.lastMentor?.outcome == .suggested)
                    let suggestion = try #require(await h.nextSuggestion())
                    #expect(suggestion.title == payload.title.withPlainDashes)
                    #expect(suggestion.body == payload.body.withPlainDashes)
                    #expect(suggestion.category == payload.category)
                    let answered = await h.loop.recordFeedback(suggestionID: suggestion.id, feedback: .tellMeMore)
                    #expect(answered?.feedback == .tellMeMore)
                    shown.append(suggestion)
                } else if reply.suggestion == nil {
                    #expect(status.lastMentor?.outcome == .nothingToSay)
                } else {
                    #expect(status.lastMentor?.outcome == .belowConfidence)
                }
            } else {
                #expect(status.lastMentorHold?.hold == .triageSaidNo(reason: verdict.reason.withPlainDashes))
            }
            if let previous = lastHarness { await previous.loop.stop() }
            lastHarness = h
        }
        #expect(!shown.isEmpty, "the committed fixtures must show at least one suggestion")
        let again = try #require(lastHarness)

        // Test Connection replays the recorded test call.
        let testEntry = try #require(client.entries.first { $0.fixture.identity.kind == ModelTier.test.rawValue })
        let testModel = try testEntry.fixture.result.get().model
        #expect(await again.loop.testConnection() == .success(testModel))

        let calls = try await journal.recentModelCalls(limit: 100)
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.replayed && $0.cost == 0 })
        let status = await again.loop.currentStatus()
        #expect(status.spendThisHour == 0)
        #expect(status.callsThisHour == 0)
        let history = try await journal.recentSuggestions(limit: 50)
        #expect(Set(history.map(\.id)) == Set(shown.map(\.id)))
        #expect(history.allSatisfy { $0.feedback == .tellMeMore })
        let events = try await journal.recentEvents(limit: 50)
        #expect(events.filter { $0.kind == .suggested }.count == shown.count)
        #expect(events.filter { $0.kind == .feedback }.count == shown.count)
    }
}
