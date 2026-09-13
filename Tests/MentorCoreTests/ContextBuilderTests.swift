import Foundation
import Testing
@testable import MentorCore

@Suite struct RollingWindowTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func windowIsOldestFirstWithinTimeAndTokenBudget() {
        let observations = (0..<10).map { i in
            Fixtures.observation(id: Int64(i + 1), at: t0 - Double(9 - i) * 60, window: "w\(i)", text: "screen \(i)\nline two of \(i)")
        }
        let window = RollingWindow.build(observations: observations.shuffled(), now: t0, duration: 300, tokenBudget: 10_000)
        // The newest is at t0; entries at t0 - 300 and newer qualify: ids 5...10.
        #expect(window.map(\.observationID) == [5, 6, 7, 8, 9, 10])
        #expect(window.last?.text == "screen 9\nline two of 9")
    }

    @Test func tokenBudgetDropsOldestEntriesFirst() {
        let long = String(repeating: "word ", count: 200) // ~1000 chars, ~250 tokens
        let observations = (0..<5).map { i in
            Fixtures.observation(id: Int64(i + 1), at: t0 - Double(4 - i) * 10, window: "w\(i)", text: long + "\(i)")
        }
        let window = RollingWindow.build(observations: observations, now: t0, duration: 3600, tokenBudget: 600)
        #expect(window.map(\.observationID) == [4, 5])
        #expect(window.allSatisfy { !$0.truncated })
    }

    @Test func newestAloneIsTruncatedToTheBudget() {
        let huge = String(repeating: "x", count: 10_000)
        let window = RollingWindow.build(observations: [Fixtures.observation(at: t0, text: huge)], now: t0, duration: 60, tokenBudget: 100)
        #expect(window.count == 1)
        #expect(window[0].truncated)
        #expect(window[0].text.count == 400)
    }

    @Test func nearDuplicateConsecutiveScreensCollapse() {
        let lines = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let observations = [
            Fixtures.observation(id: 1, at: t0 - 20, text: lines),
            Fixtures.observation(id: 2, at: t0 - 10, text: lines + "\nline 31"),
            Fixtures.observation(id: 3, at: t0, text: "something else entirely"),
        ]
        let window = RollingWindow.build(observations: observations, now: t0, duration: 3600, tokenBudget: 10_000)
        #expect(window.map(\.observationID) == [2, 3])
    }

    @Test func excludedObservationsNeverEnterTheWindow() {
        var excluded = Fixtures.observation(id: 1, at: t0 - 5, app: "1Password", bundleID: "com.1password.1password", text: "secret")
        excluded.focus.isExcluded = true
        let window = RollingWindow.build(observations: [excluded, Fixtures.observation(id: 2, at: t0)], now: t0, duration: 60, tokenBudget: 1000)
        #expect(window.map(\.observationID) == [2])
        #expect(RollingWindow.build(observations: [excluded], now: t0, duration: 60, tokenBudget: 1000).isEmpty)
    }
}

@Suite struct PromptBuilderTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func triageMessageContainsOnlyTextFields() {
        let observation = Fixtures.observation(at: t0, text: "hello\nworld", jpeg: Data([1, 2, 3]))
        let events = [JournalEvent(timestamp: t0 - 30, kind: .appSwitch, appName: "Xcode", detail: "from Safari")]
        let message = PromptBuilder.triageMessage(observation: observation, recentEvents: events, now: t0)
        #expect(message.contains("App: Xcode (com.apple.dt.Xcode)"))
        #expect(message.contains("Window: main.swift"))
        #expect(message.contains("Trigger: focus change"))
        #expect(message.contains("Accessibility: Xcode: window \"main.swift\"; focus AXTextArea; text \"let x = 1\""))
        #expect(message.contains("- 30s ago: app switch Xcode (from Safari)"))
        #expect(message.hasSuffix("hello\nworld"))
    }

    @Test func triageTextIsCutAtTheLimit() {
        let observation = Fixtures.observation(at: t0, text: String(repeating: "a", count: 8000))
        let message = PromptBuilder.triageMessage(observation: observation, recentEvents: [], now: t0)
        #expect(message.contains("first \(PromptBuilder.triageTextLimit) characters"))
        #expect(message.count < 8000)
    }

    @Test func mentorMessageMarksLatestAndListsSuppressedCategories() {
        let older = Fixtures.observation(id: 1, at: t0 - 60, window: "a.swift", text: "older text")
        let latest = Fixtures.observation(id: 2, at: t0, window: "b.swift", text: "latest text")
        let window = RollingWindow.build(observations: [older, latest], now: t0, duration: 600, tokenBudget: 1000)
        let message = PromptBuilder.mentorMessage(
            window: window, latest: latest, recentEvents: [], suppressed: [.shortcut, .tool], includesImage: true, now: t0
        )
        #expect(message.contains("Suppressed categories for this app (do not raise these): shortcut, tool."))
        #expect(message.contains("The attached image is the latest screen."))
        #expect(message.contains("| \"a.swift\" | focus change\n"))
        #expect(message.contains("| \"b.swift\" | focus change | latest\n"))
        let olderIndex = message.range(of: "older text")!.lowerBound
        let latestIndex = message.range(of: "latest text")!.lowerBound
        #expect(olderIndex < latestIndex)
        #expect(message.contains("- none in the last 10 minutes"))

        let textOnly = PromptBuilder.mentorMessage(window: window, latest: latest, recentEvents: [], suppressed: [], includesImage: false, now: t0)
        #expect(textOnly.contains("Suppressed categories for this app: none."))
        #expect(!textOnly.contains("attached image"))
    }

    @Test func eventSummaryKeepsTheMostRecentInsideTheWindow() {
        var events: [JournalEvent] = []
        for i in 0..<20 {
            events.append(JournalEvent(timestamp: t0 - Double(i) * 30, kind: .windowSwitch, appName: "App", detail: "w\(i)"))
        }
        events.append(JournalEvent(timestamp: t0 - 3600, kind: .started))
        let summary = PromptBuilder.eventSummary(events, now: t0)
        let lines = summary.split(separator: "\n")
        #expect(lines.count == PromptBuilder.eventLimit)
        #expect(lines.first!.contains("w11"))
        #expect(lines.last!.contains("w0"))
        #expect(!summary.contains("started"))
    }

    /// The context question is asked in the cached system prompt, never in the
    /// per-call message, so the cached prefix is the same for every call.
    @Test func theTriageMessageNeverCarriesAContextPlacement() {
        let asked = PromptBuilder.triageMessage(observation: Fixtures.observation(at: t0), recentEvents: [], now: t0)
        #expect(!asked.contains("Context:"))
    }

    @Test func theMentorMessageNamesTheContextTheMomentWasPlacedIn() {
        let latest = Fixtures.observation(at: t0, text: "latest text")
        let window = RollingWindow.build(observations: [latest], now: t0, duration: 600, tokenBudget: 6000)
        let context = MentorshipContext(name: "writing Swift", detail: "the Mentor app itself")
        let message = PromptBuilder.mentorMessage(
            window: window, latest: latest, recentEvents: [], suppressed: [],
            includesImage: false, context: context, now: t0
        )
        #expect(message.contains("mentored while writing Swift (the Mentor app itself)"))
        #expect(message.contains("placed in that context"))

        let without = PromptBuilder.mentorMessage(
            window: window, latest: latest, recentEvents: [], suppressed: [], includesImage: false, now: t0
        )
        #expect(!without.contains("placed in that context"))
    }

    @Test func tokenEstimateRoundsUp() {
        #expect(TokenEstimate.tokens(in: "") == 0)
        #expect(TokenEstimate.tokens(in: "abcd") == 1)
        #expect(TokenEstimate.tokens(in: "abcde") == 2)
    }
}
