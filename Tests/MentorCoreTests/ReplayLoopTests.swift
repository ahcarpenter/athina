import Foundation
import Testing
@testable import MentorCore

/// The mentor loop on a replay client: replays are journaled as replays, cost
/// nothing, never touch the key or the live files, and the committed fixture
/// set carries the whole path from triage to a suggestion and its feedback,
/// the understanding each mentor reply rewrites, and a periodic refresh.
@Suite(.timeLimit(.minutes(1))) struct ReplayLoopTests {
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
        let clock: AdjustableClock
        let loop: MentorLoop
        let input: AsyncStream<SensingEvent>.Continuation
        let output: AsyncStream<MentorEvent>
        /// Everything the loop publishes, for waiting on its state without polling.
        private let updates: AsyncStream<MentorEvent>

        /// On a test clock started at noon on the UTC calendar the loop is
        /// given, so an understanding written moments ago is never expired by
        /// a day turning over mid-test.
        init(
            journal: Journal, client: any ClaudeClient, keyStore: any KeyStore = InMemoryKeyStore(), settings: MentorSettings = MentorSettings(),
            clock: AdjustableClock = AdjustableClock(startingAt: MentorLoopTests.Harness.start)
        ) async {
            self.clock = clock
            let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
            input = continuation
            loop = MentorLoop(
                settings: settings, journal: journal, client: client, keyStore: keyStore, events: stream,
                clock: clock, calendar: MentorLoopTests.calendar
            )
            output = await loop.events()
            updates = await loop.events()
            await loop.start()
            input.yield(.modeChanged(.watching))
            await waitUntil { $0.mode == .watching }
        }

        /// Sends an observation a millisecond after whatever came before it
        /// and waits, on the events the loop publishes, until it has gated it
        /// through the refresh gate, which runs last, and finished every call
        /// it started for it.
        func observe(_ observation: ActivityObservation, calls: @Sendable () async -> Int, expectCalls: Int) async {
            clock.advance(by: .milliseconds(1))
            let sentAt = clock.date
            input.yield(.observation(observation))
            await waitUntil { status in
                status.lastGate?.observationID == observation.id && status.inFlight == nil
                    && MentorLoopTests.Harness.refreshGateRan(status, since: sentAt)
            } calls: {
                await calls() >= expectCalls
            }
        }

        /// Waits until `condition` holds of the loop's status and `calls`
        /// does, checking again after every event the loop publishes.
        func waitUntil(_ condition: (MentorStatus) -> Bool, calls: () async -> Bool = { true }) async {
            var events = updates.makeAsyncIterator()
            while true {
                if condition(await loop.currentStatus()), await calls() { return }
                guard await events.next() != nil else { return }
            }
        }

        /// The next suggestion the loop publishes.
        func nextSuggestion() async -> Suggestion? {
            for await event in output {
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
        await h.observe(Fixtures.observation(id: 1, at: h.clock.date), calls: { await client.served.count }, expectCalls: 2)
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

    /// A recording that cannot write refuses its calls, but it is not a
    /// replay: without a key the loop waits for one, and with a key each
    /// refused call is journaled as a live error that cost nothing.
    @Test func aRefusedRecordingIsNotAReplay() async throws {
        let client = RefusingClaudeClient(reason: "cannot record to /recordings: permission denied")
        #expect(!client.isReplay)

        let keyless = await Harness(journal: try Journal.inMemory(), client: client, keyStore: InMemoryKeyStore())
        #expect(await keyless.loop.currentStatus().availability == .noAPIKey)
        #expect(await keyless.loop.hasAPIKey == false)
        await keyless.loop.stop()

        let journal = try Journal.inMemory()
        let h = await Harness(journal: journal, client: client, keyStore: InMemoryKeyStore(key: "sk-ant-test"))
        #expect(await h.loop.currentStatus().availability == .ready)
        #expect(await h.loop.testConnection() == .failure(.notSent(client.reason)))
        let call = try #require(try await journal.recentModelCalls(limit: 1).first)
        #expect(!call.replayed)
        #expect(call.outcome == .error)
        #expect(call.cost == 0)
        #expect(call.detail == ClaudeClientError.notSent(client.reason).description)
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

    // MARK: Isolation from the live files

    /// A replay starts from the live settings and saves only to its own
    /// journal and settings file, so a whole replayed session, down to a Never
    /// for this, leaves the live files exactly as they were.
    @Test func aReplaySessionLeavesTheLiveJournalAndSettingsByteIdentical() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let live = AppPaths.dataDirectory(for: .live, supportDirectory: support)
        #expect(live == support)
        #expect(AppPaths.dataDirectory(for: .record(directory: support.appendingPathComponent("recordings")), supportDirectory: support) == live)

        // A lived-in live app: settings of its own, and a journal holding a call.
        var liveSettings = SensingSettings()
        liveSettings.mentor.hourlySpendCap = 3
        liveSettings.mentor.neverRules = [NeverRule(
            bundleID: "com.apple.TextEdit", appName: "TextEdit", category: .tool, createdAt: Date(timeIntervalSince1970: 1_789_000_000)
        )]
        try SettingsStore(url: SettingsStore.defaultURL(in: live)).save(liveSettings)
        let liveJournal = try Journal(url: Journal.defaultURL(in: live))
        try await liveJournal.record(ModelCallRecord(
            timestamp: MentorLoopTests.Harness.start, tier: .triage, model: "claude-haiku-4-5-20251001", promptVersion: MentorPrompts.version,
            promptCharacters: 10, imageBytes: 0, usage: Usage(inputTokens: 900), cost: 0.001, latency: 0.1, outcome: .candidate, detail: "live"
        ))
        let before = try Self.files(in: live)
        #expect(before["settings.json"] != nil && before["journal.sqlite"] != nil)

        let replayMode = ModelClientMode.replay(directory: URL(fileURLWithPath: "/fixtures"), allowStale: false)
        let replay = AppPaths.dataDirectory(for: replayMode, supportDirectory: support)
        #expect(replay != live)
        #expect(AppPaths.dataDirectory(for: .invalid("--record and --replay cannot be combined"), supportDirectory: support) == replay)

        let launch = SettingsStore.forLaunch(replayMode, supportDirectory: support)
        let store = launch.store
        var settings = launch.settings
        #expect(store.url == SettingsStore.defaultURL(in: replay))
        #expect(settings.mentor.hourlySpendCap == 3)
        let journal = try Journal(url: Journal.defaultURL(in: replay))
        let client = ReplayClaudeClient(entries: Self.candidateAndSuggestion)
        let h = await Harness(journal: journal, client: client, settings: settings.mentor)
        await h.observe(Fixtures.observation(id: 1, at: h.clock.date), calls: { await client.served.count }, expectCalls: 2)
        let suggestion = try #require(await h.nextSuggestion())
        #expect(await h.loop.recordFeedback(suggestionID: suggestion.id, feedback: .never)?.feedback == .never)
        settings.mentor.neverRules = SuppressionRules.adding(
            NeverRule(bundleID: suggestion.bundleID, appName: suggestion.appName, category: suggestion.category, createdAt: h.clock.date),
            to: settings.mentor.neverRules
        )
        try store.save(settings)
        await h.loop.stop()

        #expect(try await journal.recentSuggestions(limit: 5).map(\.feedback) == [.never])
        #expect(store.load().mentor.neverRules.count == 2)
        #expect(try Self.files(in: live) == before)
        #expect(try await liveJournal.recentSuggestions(limit: 5).isEmpty)
    }

    /// Every replay launch starts from the live settings, read and never
    /// written, so an app the user excluded stays excluded while replaying,
    /// whatever an earlier replay saved to its own file. With no live
    /// settings a replay starts from the defaults.
    @Test func aReplayStartsEveryLaunchFromTheLiveSettingsSoExcludedAppsStayExcluded() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let replayMode = ModelClientMode.replay(directory: URL(fileURLWithPath: "/fixtures"), allowStale: false)
        let messages = "com.apple.MobileSMS"

        let first = SettingsStore.forLaunch(replayMode, supportDirectory: support)
        #expect(first.settings == SensingSettings())
        #expect(!first.settings.isExcluded(bundleID: messages))

        var liveSettings = SensingSettings()
        liveSettings.excludedBundleIDs.append(messages)
        liveSettings.thumbnailRetention = 3600
        let liveStore = SettingsStore(url: SettingsStore.defaultURL(in: support))
        try liveStore.save(liveSettings)
        let liveBytes = try Data(contentsOf: liveStore.url)

        let launch = SettingsStore.forLaunch(replayMode, supportDirectory: support)
        #expect(launch.settings.isExcluded(bundleID: messages))
        #expect(launch.settings.thumbnailRetention == 3600)

        // A replay that drops the exclusion saves only to its own file, and
        // the next replay launch is excluded again.
        var edited = launch.settings
        edited.excludedBundleIDs.removeAll { $0 == messages }
        try launch.store.save(edited)
        #expect(launch.store.url != liveStore.url)
        #expect(!launch.store.load().isExcluded(bundleID: messages))
        #expect(SettingsStore.forLaunch(replayMode, supportDirectory: support).settings.isExcluded(bundleID: messages))
        #expect(SettingsStore.forLaunch(.invalid("--replay needs the directory of fixtures to replay"), supportDirectory: support).settings.isExcluded(bundleID: messages))
        #expect(try Data(contentsOf: liveStore.url) == liveBytes)
    }

    /// Every regular file directly inside `directory`, by name.
    private static func files(in directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[name] = try Data(contentsOf: url)
        }
        return files
    }

    // MARK: The committed fixture set

    static func committedFixturesDirectory() throws -> URL {
        try #require(Bundle.module.url(forResource: "Replay", withExtension: nil, subdirectory: "Fixtures"))
    }

    /// Fails the run, naming each fixture recorded with another prompt version
    /// than `current` and each tier with no fixture, unless the set is
    /// current. Returns whether it is.
    @discardableResult
    static func expectCurrent(_ loaded: [(name: String, fixture: CallFixture)], current: Int = MentorPrompts.version) -> Bool {
        let stale = loaded.filter { $0.fixture.identity.promptVersion != current }.map { entry in
            "\(entry.name) is stale: recorded with prompt version \(entry.fixture.identity.promptVersion), the current prompt version is \(current)"
        }
        let kinds = Set(loaded.map(\.fixture.identity.kind))
        let uncovered = ModelTier.allCases.map(\.rawValue).filter { !kinds.contains($0) }.map { "tier \($0) has no fixture" }
        let findings = stale + uncovered
        guard !findings.isEmpty else { return true }
        let report = [
            "The committed fixtures are not current. Re-record them live with make record in this same change, as README.md, The committed fixtures, describes:",
        ] + findings.map { "- \($0)" }
        Issue.record(Comment(rawValue: report.joined(separator: "\n")))
        return false
    }

    /// What `make fixture-status` runs. When a prompt or schema change bumps
    /// the prompt version, or a call kind is added, the committed set is
    /// recorded again live in the same change, so this passes.
    @Test func theCommittedFixturesAreCurrent() throws {
        let loaded = try CallFixtureFiles.load(from: try Self.committedFixturesDirectory())
        if Self.expectCurrent(loaded) {
            print("The committed fixtures are current: \(Plural.count(loaded.count, "fixture", "fixtures")) recorded with prompt version \(MentorPrompts.version), and every tier has one.")
        }
    }

    /// The check fails a run on a stale or incomplete set, naming the stale
    /// fixture with both versions and the tier with no fixture, and passes a
    /// current, complete one.
    @Test func aStaleOrIncompleteFixtureSetFailsTheCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try CallFixtureFiles.write(CallFixtureTests.fixture(kind: ModelTier.triage.rawValue, promptVersion: MentorPrompts.version - 1), to: directory, redacting: "")
        try CallFixtureFiles.write(CallFixtureTests.fixture(kind: ModelTier.mentor.rawValue), to: directory, redacting: "")
        let loaded = try CallFixtureFiles.load(from: directory)
        let staleName = try #require(loaded.first { $0.fixture.identity.kind == ModelTier.triage.rawValue }).name

        withKnownIssue {
            #expect(!Self.expectCurrent(loaded))
        } matching: { issue in
            let text = issue.comments.map(\.rawValue).joined(separator: "\n")
            return text.contains("- \(staleName) is stale: recorded with prompt version \(MentorPrompts.version - 1), the current prompt version is \(MentorPrompts.version)")
                && text.contains("- tier \(ModelTier.test.rawValue) has no fixture")
                && !text.contains("tier \(ModelTier.mentor.rawValue) has no fixture")
                && text.contains("make record")
        }

        let complete = ModelTier.allCases.map { tier in
            (name: "\(tier.rawValue).json", fixture: CallFixtureTests.fixture(kind: tier.rawValue))
        }
        #expect(Self.expectCurrent(complete))
    }

    @Test func theCommittedFixturesCarryEveryPathAndHoldNoKey() throws {
        let directory = try Self.committedFixturesDirectory()
        let loaded = try CallFixtureFiles.load(from: directory)
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
        #expect(
            mentor.allSatisfy { $0.updatedUnderstanding.map { !$0.isEmpty } ?? false },
            "every mentor recording must rewrite the understanding"
        )
        let refreshEntries = loaded.filter { $0.fixture.identity.kind == ModelTier.understanding.rawValue }
        let refreshes = refreshEntries.compactMap { entry in
            (try? entry.fixture.result.get()).flatMap { MentorLoop.decode(UnderstandingVerdict.self, from: $0) }
        }
        #expect(!refreshes.isEmpty && refreshes.count == refreshEntries.count, "every understanding recording must decode as a refresh")
        #expect(refreshes.allSatisfy { $0.understanding.primaryGoal != nil }, "an understanding recording must infer a goal")

        for entry in loaded {
            let text = try String(contentsOf: directory.appendingPathComponent(entry.name), encoding: .utf8)
            #expect(!text.contains("sk-ant-"), "\(entry.name) must not carry a key")
            #expect(!text.contains("\u{2014}"), "\(entry.name) must not carry an em dash")
        }
    }

    /// Every triage recording in turn, on the loop the app runs: a candidate
    /// reaches the mentor recording next in line, a shown suggestion takes
    /// feedback, and after the last recording the first answers again. The
    /// replay is strict, as the app's is: a stale fixture is refused.
    @Test func theCommittedFixturesDriveTheWholeLoop() async throws {
        let directory = try Self.committedFixturesDirectory()
        let client = try ReplayClaudeClient.load(from: directory, allowStale: false)
        let journal = try Journal.inMemory()
        let settings = MentorSettings()
        let triageEntries = client.entries.filter { $0.fixture.identity.kind == ModelTier.triage.rawValue }
        let mentorEntries = client.entries.filter { $0.fixture.identity.kind == ModelTier.mentor.rawValue }
        try #require(!triageEntries.isEmpty && !mentorEntries.isEmpty)

        var nextMentor = 0
        var shown: [Suggestion] = []
        var lastHarness: Harness?
        let clock = AdjustableClock(startingAt: MentorLoopTests.Harness.start)
        // Every triage recording, then the first again: past the last
        // recording the cycle starts over.
        let walk = Array(triageEntries.enumerated()) + [(triageEntries.count, triageEntries[0])]
        for (index, entry) in walk {
            // A fresh loop per moment, on one journal and one client, so the
            // debounce never holds a moment and the cycle carries on.
            let h = await Harness(journal: journal, client: client, settings: settings, clock: clock)
            let verdict = try #require((try? entry.fixture.result.get()).flatMap { MentorLoop.decode(TriageVerdict.self, from: $0) })
            let standing = await h.loop.currentUnderstanding()
            let before = await client.served.count
            let expected = before + (verdict.worthALook ? 2 : 1)
            await h.observe(
                Fixtures.observation(id: Int64(index + 1), at: clock.date, window: "moment \(index)", text: "moment \(index)"),
                calls: { await client.served.count }, expectCalls: expected
            )
            let served = await client.served
            try #require(served.count == expected)
            #expect(served[before].fixtureName == entry.name)
            let status = await h.loop.currentStatus()
            #expect(status.lastTriage?.outcome == (verdict.worthALook ? .candidate : .quiet))
            #expect(status.lastTriage?.detail == verdict.reason.withPlainDashes)

            if verdict.worthALook {
                let mentorEntry = mentorEntries[nextMentor % mentorEntries.count]
                nextMentor += 1
                #expect(served[before + 1].fixtureName == mentorEntry.name)
                let reply = try #require((try? mentorEntry.fixture.result.get()).flatMap { MentorLoop.decode(MentorVerdict.self, from: $0) })
                // The reply rewrote the understanding on the way past, for free.
                let rewritten = try #require(await h.loop.currentUnderstanding())
                #expect(rewritten.revision == (standing?.revision ?? 0) + 1)
                #expect(rewritten.source == .mentorCall)
                #expect(rewritten.cost == 0)
                let goalWasStanding = standing?.content.primaryGoal != nil
                if let payload = reply.suggestion, payload.confidence >= settings.minimumConfidence,
                   payload.category.judgesAgainstGoal, !goalWasStanding {
                    // A goal kind with no goal to judge against is never shown.
                    #expect(status.lastMentor?.outcome == .suppressed)
                } else if let payload = reply.suggestion, payload.confidence >= settings.minimumConfidence {
                    try #require(status.lastMentor?.outcome == .suggested)
                    let suggestion = try #require(await h.nextSuggestion())
                    #expect(suggestion.title == payload.title.withPlainDashes)
                    #expect(suggestion.body == payload.body.withPlainDashes)
                    #expect(suggestion.category == payload.category)
                    #expect((suggestion.judgedGoal != nil) == payload.category.judgesAgainstGoal)
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
        let history = try await journal.recentSuggestions(limit: 50)
        #expect(Set(history.map(\.id)) == Set(shown.map(\.id)))
        #expect(history.allSatisfy { $0.feedback == .tellMeMore })
        let events = try await journal.recentEvents(limit: 50)
        #expect(events.filter { $0.kind == .suggested }.count == shown.count)
        #expect(events.filter { $0.kind == .feedback }.count == shown.count)
    }

    /// The periodic refresh on the loop the app runs, answered by the
    /// committed understanding recording: a whole interval with no mentor call
    /// buys one call of the `understanding` kind, and its reply becomes the
    /// next revision, replayed, never billed, and never counted as spend.
    @Test func theCommittedUnderstandingFixtureRefreshesTheRecord() async throws {
        let directory = try Self.committedFixturesDirectory()
        let client = try ReplayClaudeClient.load(from: directory, allowStale: false)
        let entry = try #require(client.entries.first { $0.fixture.identity.kind == ModelTier.understanding.rawValue })
        let verdict = try #require((try? entry.fixture.result.get()).flatMap { MentorLoop.decode(UnderstandingVerdict.self, from: $0) })

        var settings = MentorSettings()
        settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
        // A record written longer ago than the interval, with work all the way
        // since, so the refresh is due.
        let journal = try Journal.inMemory()
        let activeUse = settings.understandingRefreshInterval + 60
        let clock = AdjustableClock(startingAt: MentorLoopTests.Harness.start)
        let written = try await journal.record(UnderstandingRecord.first(
            content: Understanding(
                goals: [Understanding.Goal(goal: "rename the trip photos", evidence: "a list of mv commands", confidence: 0.7)],
                timeline: ["opened the rename list"]
            ),
            at: clock.date.addingTimeInterval(-activeUse),
            model: "claude-sonnet-5", source: .mentorCall, cost: 0, promptVersion: MentorPrompts.version
        ))
        try await journal.storeRefreshPeriod(RefreshPeriod(
            startedAt: written.updatedAt, activeUse: activeUse, countedAt: written.updatedAt.addingTimeInterval(activeUse)
        ))
        let h = await Harness(journal: journal, client: client, settings: settings, clock: clock)

        // The floor cadence is not a change moment, so triage holds and only
        // the refresh gate can make a call.
        await h.observe(
            Fixtures.observation(id: 1, at: clock.date, reason: .floor),
            calls: { await client.served.count }, expectCalls: 1
        )

        let served = await client.served
        #expect(served.map(\.call) == [CallIdentity(kind: ModelTier.understanding.rawValue, promptVersion: MentorPrompts.version)])
        #expect(served.first?.fixtureName == entry.name)
        let status = await h.loop.currentStatus()
        #expect(status.lastGate?.hold == .notAChangeMoment(.floor))
        let call = try #require(status.lastRefresh)
        #expect(call.tier == .understanding)
        #expect(call.outcome == .refreshed)
        #expect(call.detail == verdict.reason.withPlainDashes)
        #expect(call.replayed && call.cost == 0)
        #expect(call.model == (try entry.fixture.result.get()).model)
        #expect(status.spendThisHour == 0)
        #expect(status.callsThisHour == 0)

        let record = try #require(await h.loop.currentUnderstanding())
        #expect(record.revision == 2)
        #expect(record.source == .periodic)
        #expect(record.cost == 0 && record.cumulativeCost == 0)
        #expect(record.content == verdict.understanding.bounded(toTokens: settings.understandingTokenBudget))
        #expect(try await journal.recentModelCalls(limit: 5).map(\.tier) == [.understanding])
    }
}
