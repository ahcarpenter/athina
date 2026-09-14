import Foundation
import Testing
@testable import MentorCore

/// The mentor loop's part in callouts and talking back: a region on a
/// suggestion, and a follow-up question as a journaled, priced model call.
@Suite struct InterventionLoopTests {
    private static let yes = #"{"worth_a_look": true, "reason": "Repeated manual runs"}"#
    private static let no = #"{"worth_a_look": false, "reason": "Reading docs"}"#

    private static func suggestion(region: String) -> String {
        #"{"reason": "Saw it", "suggestion": {"title": "Use --filter", "body": "Run one suite.", "explanation": "swift test --filter Name", "category": "shortcut", "confidence": 0.9, "region": \#(region)}}"#
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static let inside = #"{"x": 100, "y": 50, "width": 200, "height": 40, "note": "this \#u{2014} command"}"#
    private static let outside = #"{"x": 1200, "y": 50, "width": 200, "height": 40, "note": "x"}"#

    private func journaledSuggestion(_ h: MentorLoopTests.Harness) async throws -> Suggestion {
        try await h.journal.record(Suggestion(
            timestamp: Date(), bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "main.swift", category: .shortcut,
            title: "Use --filter", body: "Run one suite.", explanation: "swift test --filter Name", confidence: 0.9,
            observationID: nil, model: "claude-opus-5", promptVersion: MentorPrompts.version
        ))
    }

    @Test func aRegionInsideTheFrameReachesTheSuggestionAndTheJournal() async throws {
        let h = try await MentorLoopTests.Harness()
        await h.client.enqueue(json: Self.yes)
        await h.client.enqueue(json: Self.suggestion(region: Self.inside), model: "claude-opus-5")
        let latest = try await h.journal.record(Fixtures.observation(at: Date(), jpeg: Data(repeating: 1, count: 40)))
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
        let expected = CalloutRegion(rect: CGRect(x: 100, y: 50, width: 200, height: 40), note: "this - command")
        #expect(shown.region == expected)
        #expect(try await h.journal.suggestion(id: shown.id)?.region == expected)
    }

    @Test func aRegionOutsideTheFrameIsDroppedFromTheSuggestion() async throws {
        let h = try await MentorLoopTests.Harness()
        await h.client.enqueue(json: Self.yes)
        await h.client.enqueue(json: Self.suggestion(region: Self.outside))
        await h.observe(Fixtures.observation(id: 1, at: Date(), jpeg: Data(repeating: 1, count: 40)), expectCalls: 2)
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
        await h.observe(Fixtures.observation(id: 1, at: Date(), jpeg: Data(repeating: 1, count: 40)), expectCalls: 2)
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
        let observation = try await h.journal.record(Fixtures.observation(at: Date(), text: "$ swift test\nall passed"))
        await h.observe(observation, expectCalls: 1)
        var suggestion = try await journaledSuggestion(h)
        suggestion.observationID = observation.id
        let earlier = try await h.journal.record(FollowUp(suggestionID: suggestion.id, timestamp: t0 - 30, question: "which suite", answer: "That one.", model: "m", promptVersion: 5))
        await h.client.enqueue(
            json: #"{"answer": "Yes \#u{2014} tag them and filter on the tag."}"#, model: "claude-sonnet-5",
            usage: Usage(inputTokens: 900, outputTokens: 80, cacheCreationInputTokens: 0, cacheReadInputTokens: 300)
        )
        let before = await h.loop.currentStatus()

        let followUp = await h.loop.askFollowUp(about: suggestion, question: "does that work with tags", at: t0)
        #expect(followUp.id > 0)
        #expect(followUp.timestamp == t0)
        #expect(followUp.suggestionID == suggestion.id)
        #expect(followUp.question == "does that work with tags")
        #expect(followUp.answer == "Yes - tag them and filter on the tag.")
        #expect(followUp.error == nil)
        #expect(followUp.model == "claude-sonnet-5")
        #expect(followUp.promptVersion == MentorPrompts.version)
        #expect(!followUp.spoken)

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
        #expect(try await h.journal.recentEvents(limit: 1).first?.detail == "\"does that work with tags\"")
        let events = await h.drain { if case .followUp = $0 { return true } else { return false } }
        guard case .followUp(let published)? = events.last else {
            Issue.record("expected a follow-up event")
            return
        }
        #expect(published == followUp)
        #expect(await h.loop.noteFollowUpSpoken(id: followUp.id)?.spoken == true)
    }

    @Test func aHeldFollowUpIsJournaledWithTheReasonAndNeverSent() async throws {
        let h = try await MentorLoopTests.Harness()
        await h.client.enqueue(json: Self.no)
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 1)
        let suggestion = try await journaledSuggestion(h)
        h.input.yield(.modeChanged(.paused))
        // Wait for the pause to be consumed: a later observation is held for it.
        await h.observe(Fixtures.observation(id: 2, at: Date(), window: "b", text: "b"), expectCalls: 1)
        #expect(await h.loop.currentStatus().lastGate?.hold == .paused)

        let followUp = await h.loop.askFollowUp(about: suggestion, question: "why", at: t0)
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
        await h.observe(Fixtures.observation(at: Date()), expectCalls: 1)
        let suggestion = try await journaledSuggestion(h)
        await h.client.enqueue(.failure(.api(status: 529, type: "overloaded_error", message: "Overloaded")))
        let failed = await h.loop.askFollowUp(about: suggestion, question: "why")
        #expect(failed.error == "overloaded_error (HTTP 529): Overloaded")
        #expect(try await h.journal.recentModelCalls(limit: 1).first?.outcome == .error)

        await h.client.enqueue(json: "not json")
        let garbage = await h.loop.askFollowUp(about: suggestion, question: "again")
        #expect(garbage.error == "could not parse the follow-up reply")
        #expect(try await h.journal.followUps(suggestionID: suggestion.id).count == 2)
    }

    @Test func deliveryFlagsArePersistedThroughTheLoop() async throws {
        let h = try await MentorLoopTests.Harness()
        let suggestion = try await journaledSuggestion(h)
        let shown = await h.loop.noteDelivery(suggestionID: suggestion.id, calloutShown: true)
        #expect(shown?.calloutShown == true)
        #expect(shown?.spoken == false)
        let spoken = await h.loop.noteDelivery(suggestionID: suggestion.id, spoken: true)
        #expect(spoken?.calloutShown == true)
        #expect(spoken?.spoken == true)
        #expect(await h.loop.noteDelivery(suggestionID: 404, spoken: true) == nil)
    }
}
