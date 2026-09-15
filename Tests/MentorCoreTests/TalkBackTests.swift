import Foundation
import Testing
@testable import MentorCore

@Suite struct TranscriptMatcherTests {
    @Test(arguments: [
        ("Tell me more.", SuggestionFeedback.tellMeMore),
        ("okay, tell me more please", .tellMeMore),
        ("MORE", .tellMeMore),
        ("Hey Mentor, go on.", .tellMeMore),
        ("elaborate", .tellMeMore),
        ("not now", .notNow),
        ("No thanks", .notNow),
        ("later", .notNow),
        ("Not right now, thanks.", .notNow),
        ("skip it", .notNow),
        ("never for this", .never),
        ("Never again!", .never),
        ("don\u{2019}t show this again", .never),
        ("stop suggesting this", .never),
        ("never mind", .dismissed),
        ("close it", .dismissed),
        ("got it", .dismissed),
    ])
    func wholeUtterancesMatchTheAnswers(transcript: String, feedback: SuggestionFeedback) {
        #expect(TranscriptMatcher.match(transcript) == .answer(feedback))
    }

    @Test(arguments: [
        "tell me more about the flag",
        "why is that better?",
        "not now I'm busy",
        "never for this file, but keep the rest",
        "which line do you mean",
    ])
    func anythingElseIsAQuestionKeptVerbatim(transcript: String) {
        #expect(TranscriptMatcher.match("  \(transcript) \n") == .question(transcript))
    }

    @Test(arguments: ["", "   ", "um", "please", "okay thanks", "...", "\n"])
    func nothingUsableIsNil(transcript: String) {
        #expect(TranscriptMatcher.match(transcript) == nil)
    }

    @Test func fillersAreTrimmedFromTheEndsOnly() {
        #expect(TranscriptMatcher.trimmed(["please", "not", "now", "please"]) == ["not", "now"])
        // "now" is a filler on the left only, so "not now" survives.
        #expect(TranscriptMatcher.trimmed(["now", "not", "now"]) == ["not", "now"])
        #expect(TranscriptMatcher.normalized("Don\u{2019}t, show-this... AGAIN!") == ["don't", "show", "this", "again"])
    }
}

@Suite struct TalkBackStateTests {
    /// The captain's ask after the live voice check: the toast is never
    /// hidden while voice input is active.
    @Test func theToastStaysUpWhileTheUserIsTalkingBack() {
        #expect(!TalkBackState.idle.keepsToastUp)
        #expect(TalkBackState.listening(partial: "").keepsToastUp)
        #expect(TalkBackState.listening(partial: "which line").keepsToastUp)
        #expect(TalkBackState.waiting(question: "which line do you mean").keepsToastUp)
        #expect(TalkBackState.thinking(question: "which line do you mean").keepsToastUp)
    }

    /// A new question may start when nothing is in progress or when one is
    /// only waiting its turn, never over a recording or a call in flight.
    @Test func aQuestionMayReplaceOneWaitingItsTurnButNotOneBeingAsked() {
        #expect(TalkBackState.idle.acceptsAQuestion)
        #expect(TalkBackState.waiting(question: "q").acceptsAQuestion)
        #expect(!TalkBackState.listening(partial: "").acceptsAQuestion)
        #expect(!TalkBackState.thinking(question: "q").acceptsAQuestion)
    }
}

@Suite struct ClockFormatTests {
    @Test func timesAre24HourWhateverTheLocalePrefers() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 14
        components.hour = 15
        components.minute = 23
        components.second = 6
        let afternoon = Calendar.current.date(from: components)!
        #expect(ClockFormat.time(afternoon) == "15:23:06")
        #expect(ClockFormat.dayAndTime(afternoon) == "Sep 14 at 15:23")
        #expect(PromptBuilder.triageMessage(observation: Fixtures.observation(at: afternoon), recentEvents: [], now: afternoon).hasPrefix("Time: 15:23:06\n"))
    }
}

@Suite struct FollowUpPromptTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private var suggestion: Suggestion {
        Suggestion(
            id: 9, timestamp: t0 - 45, bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "main.swift",
            category: .shortcut, title: "Use --filter", body: "Run one suite.", explanation: "swift test --filter Name runs one suite.",
            confidence: 0.85, observationID: 3, model: "claude-opus-5", promptVersion: MentorPrompts.version,
            region: CalloutRegion(rect: CGRect(x: 1, y: 2, width: 30, height: 4), note: "this command")
        )
    }

    @Test func theMessageCarriesTheSuggestionTheScreenTheExchangeAndTheQuestion() {
        let earlier = FollowUp(
            id: 1, suggestionID: 9, timestamp: t0 - 20, question: "which suite", answer: "CaptureSchedulerTests.",
            model: "m", promptVersion: 1
        )
        let held = FollowUp(id: 2, suggestionID: 9, timestamp: t0 - 10, question: "and one test", error: "paused", model: "m", promptVersion: 1)
        let message = PromptBuilder.followUpMessage(
            suggestion: suggestion, screenText: "$ swift test\nall 145 passed", exchange: [earlier, held],
            question: "does that work with tags", now: t0
        )
        #expect(message.contains("Your suggestion, made 45s ago in Xcode, window \"main.swift\" (shortcut, confidence 85%):"))
        #expect(message.contains("Title: Use --filter"))
        #expect(message.contains("Body: Run one suite."))
        #expect(message.contains("Explanation: swift test --filter Name runs one suite."))
        #expect(message.contains("You pointed at a spot on screen with the note \"this command\"."))
        #expect(message.contains("Recognized text of the screen the suggestion was made from (top to bottom):\n$ swift test\nall 145 passed"))
        #expect(message.contains("Earlier in this exchange:\nUser: which suite\nYou: CaptureSchedulerTests.\nUser: and one test\nYou: (no answer: paused)"))
        #expect(message.hasSuffix("The user now says, spoken and transcribed on their Mac: \"does that work with tags\""))
    }

    @Test func aMissingScreenAndAnEmptyExchangeAreSaidPlainly() {
        var plain = suggestion
        plain.region = nil
        let message = PromptBuilder.followUpMessage(suggestion: plain, screenText: nil, exchange: [], question: "why", now: t0)
        #expect(message.contains("The screen the suggestion was made from is no longer available."))
        #expect(!message.contains("Earlier in this exchange"))
        #expect(!message.contains("You pointed at"))
    }

    @Test func screenTextIsCutLikeTriagesIs() {
        let long = String(repeating: "x", count: PromptBuilder.triageTextLimit + 50)
        let message = PromptBuilder.followUpMessage(suggestion: suggestion, screenText: long, exchange: [], question: "q", now: t0)
        #expect(message.contains("first \(PromptBuilder.triageTextLimit) characters"))
        #expect(!message.contains(long))
    }
}

@Suite struct FollowUpGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func conditions(mode: SensingMode = .watching, key: Bool = true, inFlight: Bool = false, spend: Double = 0) -> MentorScheduler.Conditions {
        MentorScheduler.Conditions(mode: mode, hasAPIKey: key, callInFlight: inFlight, spendFraction: spend, nextHourStart: t0 + 3600)
    }

    @Test func onlyAvailabilityHoldsAQuestionAndAnInFlightCallMakesItWait() {
        var scheduler = MentorScheduler(settings: MentorSettings())
        #expect(scheduler.followUpGate(conditions: conditions()) == .run)
        // No debounce: a question right after a mentor call still runs.
        scheduler.noteMentorStarted(now: t0)
        scheduler.noteTriageStarted(observation: Fixtures.observation(at: t0), now: t0)
        #expect(scheduler.followUpGate(conditions: conditions()) == .run)
        #expect(scheduler.followUpGate(conditions: conditions(mode: .paused)) == .hold(.paused))
        #expect(scheduler.followUpGate(conditions: conditions(mode: .idle)) == .hold(.idle))
        #expect(scheduler.followUpGate(conditions: conditions(mode: .excluded)) == .hold(.excludedApp))
        #expect(scheduler.followUpGate(conditions: conditions(key: false)) == .hold(.noAPIKey))
        #expect(scheduler.followUpGate(conditions: conditions(inFlight: true)) == .wait)
        #expect(scheduler.followUpGate(conditions: conditions(mode: .paused, inFlight: true)) == .hold(.paused))
        #expect(scheduler.followUpGate(conditions: conditions(spend: 1)) == .hold(.spendCapReached(until: t0 + 3600)))
        var off = MentorSettings()
        off.enabled = false
        #expect(MentorScheduler(settings: off).followUpGate(conditions: conditions()) == .hold(.disabled))
    }
}

@Suite struct InterventionSettingsTests {
    @Test func defaultsAreCalloutsOnAndNoTalkBackKey() throws {
        let settings = MentorSettings()
        #expect(settings.showCallouts)
        #expect(settings.pushToTalkHotKey == nil)
        let decoded = try JSONDecoder().decode(MentorSettings.self, from: Data(#"{"enabled": true}"#.utf8))
        #expect(decoded.showCallouts)
        #expect(decoded.pushToTalkHotKey == nil)
    }

    @Test func theTalkBackKeyRoundTripsAndIsClearedWhenUnusable() throws {
        var settings = SensingSettings()
        settings.mentor.pushToTalkHotKey = HotKey(keyCode: 17, modifiers: [.control, .option, .command])
        settings.mentor.showCallouts = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SensingSettings.self, from: data)
        #expect(decoded == settings)

        var shiftOnly = settings
        shiftOnly.mentor.pushToTalkHotKey = HotKey(keyCode: 17, modifiers: [.shift])
        #expect(shiftOnly.validated().mentor.pushToTalkHotKey == nil)
        #expect(MentorSettings().validated().pushToTalkHotKey == nil)
    }

    @Test func theTalkBackKeyMayNotBeThePauseKey() throws {
        var settings = SensingSettings()
        settings.mentor.pushToTalkHotKey = settings.pauseHotKey
        #expect(settings.validated().mentor.pushToTalkHotKey == nil)
        #expect(settings.validated().pauseHotKey == HotKey.defaultPause)
        let json = #"{"pauseHotKey": {"keyCode": 17, "modifiers": 9}, "mentor": {"pushToTalkHotKey": {"keyCode": 17, "modifiers": 9}}}"#
        let decoded = try JSONDecoder().decode(SensingSettings.self, from: Data(json.utf8))
        #expect(decoded.pauseHotKey == HotKey(keyCode: 17, modifiers: [.control, .command]))
        #expect(decoded.mentor.pushToTalkHotKey == nil)
    }
}

@Suite struct RegionDecodingTests {
    @Test func aMentorVerdictDecodesWithAndWithoutARegion() throws {
        let with = try JSONDecoder().decode(MentorVerdict.self, from: Data(#"""
        {"reason": "r", "suggestion": {"title": "T", "body": "B", "explanation": "E", "category": "tool", "confidence": 0.7,
         "region": {"x": 12.5, "y": 40, "width": 300, "height": 22, "note": "this flag"}}}
        """#.utf8))
        #expect(with.suggestion?.region == MentorVerdict.Payload.Region(x: 12.5, y: 40, width: 300, height: 22, note: "this flag"))
        #expect(with.suggestion?.region?.rect == CGRect(x: 12.5, y: 40, width: 300, height: 22))

        let null = try JSONDecoder().decode(MentorVerdict.self, from: Data(#"""
        {"reason": "r", "suggestion": {"title": "T", "body": "B", "explanation": "E", "category": "tool", "confidence": 0.7, "region": null}}
        """#.utf8))
        #expect(null.suggestion?.region == nil)
        #expect(null.suggestion?.title == "T")

        let older = try JSONDecoder().decode(MentorVerdict.self, from: Data(#"""
        {"reason": "r", "suggestion": {"title": "T", "body": "B", "explanation": "E", "category": "tool", "confidence": 0.7}}
        """#.utf8))
        #expect(older.suggestion?.region == nil)

        let silence = try JSONDecoder().decode(MentorVerdict.self, from: Data(#"{"reason": "quiet", "suggestion": null}"#.utf8))
        #expect(silence.suggestion == nil)
    }

    @Test func theMentorSchemaAsksForARegionAndTheFollowUpSchemaForAnAnswer() throws {
        guard case .object(let root) = MentorPrompts.mentorSchema,
              case .object(let suggestion)? = root["properties"],
              case .array(let options)? = (suggestion["suggestion"].flatMap { if case .object(let s) = $0 { return s["anyOf"] } else { return nil } }),
              case .object(let payload) = options[1],
              case .object(let properties)? = payload["properties"],
              case .array(let required)? = payload["required"]
        else {
            Issue.record("unexpected schema shape")
            return
        }
        #expect(properties["region"] == MentorPrompts.regionSchema)
        #expect(required.contains(.string("region")))
        #expect(MentorPrompts.followUpSchema == [
            "type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"], "additionalProperties": false,
        ])
        #expect(try JSONDecoder().decode(FollowUpReply.self, from: Data(#"{"answer": "Yes."}"#.utf8)) == FollowUpReply(answer: "Yes."))
        #expect(MentorPrompts.version >= 5)
    }
}

@Suite struct JournalInterventionTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func suggestion(region: CalloutRegion? = nil) -> Suggestion {
        Suggestion(
            timestamp: t0, bundleID: "com.a", appName: "A", windowTitle: "W", category: .tool,
            title: "T", body: "B", explanation: "E", confidence: 0.8, observationID: 5, model: "m", promptVersion: 5, region: region
        )
    }

    @Test func aSuggestionRoundTripsItsRegionAndCalloutFlag() async throws {
        let journal = try Journal.inMemory()
        let region = CalloutRegion(rect: CGRect(x: 10, y: 20, width: 300, height: 24), note: "this flag")
        let stored = try await journal.record(suggestion(region: region))
        let fetched = try #require(try await journal.suggestion(id: stored.id))
        #expect(fetched.region == region)
        #expect(!fetched.calloutShown)

        let shown = try await journal.noteCalloutShown(suggestionID: stored.id)
        #expect(shown?.calloutShown == true)
        #expect(try await journal.noteCalloutShown(suggestionID: 404) == nil)
        let plain = try await journal.record(suggestion())
        #expect(try await journal.suggestion(id: plain.id)?.region == nil)
    }

    @Test func followUpsRoundTripInOrder() async throws {
        let journal = try Journal.inMemory()
        let s = try await journal.record(suggestion())
        let first = try await journal.record(FollowUp(suggestionID: s.id, timestamp: t0 + 10, question: "why", answer: "Because.", model: "m", promptVersion: 5))
        let second = try await journal.record(FollowUp(suggestionID: s.id, timestamp: t0 + 20, question: "and", error: "paused", model: "m", promptVersion: 5))
        let other = try await journal.record(FollowUp(suggestionID: s.id + 1, timestamp: t0 + 30, question: "x", answer: "y", model: "m", promptVersion: 5))
        #expect(first.id > 0 && second.id > first.id)
        #expect(try await journal.followUps(suggestionID: s.id) == [first, second])
        #expect(try await journal.recentFollowUps(limit: 10) == [other, second, first])
    }

    @Test func followUpsExpireWithTextAndGoWithClear() async throws {
        let journal = try Journal.inMemory()
        try await journal.record(FollowUp(suggestionID: 1, timestamp: t0 - 10 * 86400, question: "old", answer: "a", model: "m", promptVersion: 5))
        try await journal.record(FollowUp(suggestionID: 1, timestamp: t0 - 60, question: "new", answer: "a", model: "m", promptVersion: 5))
        let result = try await journal.applyRetention(RetentionPolicy(thumbnailMaxAge: 3600, textMaxAge: 7 * 86400, sizeCapBytes: 1 << 30), now: t0)
        #expect(result.followUpsDeleted == 1)
        #expect(result.deletedAnything)
        #expect(try await journal.recentFollowUps(limit: 10).map(\.question) == ["new"])
        try await journal.clear()
        #expect(try await journal.recentFollowUps(limit: 10).isEmpty)
    }

    /// A journal written before this phase has no region, callout, or
    /// follow-up columns; opening it adds them without touching the rows.
    @Test func anOlderJournalGainsTheNewColumnsOnOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let db = try SQLiteConnection(path: url.path)
            try db.execute("""
                CREATE TABLE suggestions (
                    id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, bundle_id TEXT, app_name TEXT NOT NULL, window_title TEXT,
                    category TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, explanation TEXT NOT NULL,
                    confidence REAL NOT NULL, observation_id INTEGER, model TEXT NOT NULL, prompt_version INTEGER NOT NULL,
                    feedback TEXT, feedback_at REAL
                );
                INSERT INTO suggestions (timestamp, app_name, category, title, body, explanation, confidence, model, prompt_version)
                VALUES (1700000000, 'A', 'tool', 'old', 'b', 'e', 0.5, 'm', 4);
                """)
        }
        let journal = try Journal(url: url)
        let old = try #require(try await journal.recentSuggestions(limit: 5).first)
        #expect(old.title == "old")
        #expect(old.region == nil)
        #expect(!old.calloutShown)
        let updated = try await journal.noteCalloutShown(suggestionID: old.id)
        #expect(updated?.calloutShown == true)
        let region = CalloutRegion(rect: CGRect(x: 1, y: 1, width: 10, height: 10), note: "n")
        let fresh = try await journal.record(suggestion(region: region))
        #expect(try await journal.suggestion(id: fresh.id)?.region == region)
        try await journal.record(FollowUp(suggestionID: fresh.id, timestamp: t0, question: "q", answer: "a", model: "m", promptVersion: 5))
        #expect(try await journal.followUps(suggestionID: fresh.id).count == 1)
    }
}
