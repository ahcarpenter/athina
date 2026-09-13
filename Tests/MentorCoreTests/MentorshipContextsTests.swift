import Foundation
import Testing
@testable import MentorCore

/// Settings validation and the placement a triage answer maps to. The gate that
/// enforces these lives in `MentorSchedulerTests`.
@Suite struct MentorshipContextsTests {
    // MARK: Settings validation

    @Test func validationTrimsNamesDropsBlanksAndKeepsTheFirstOfEachDuplicate() {
        var s = MentorSettings()
        s.contexts = [
            MentorshipContext(name: "  writing Swift  ", detail: "  the app itself  "),
            MentorshipContext(name: "   "),
            MentorshipContext(name: "Writing swift", detail: "a duplicate by name"),
            MentorshipContext(name: "reading docs"),
        ]
        let validated = s.validated()
        #expect(validated.contexts.map(\.name) == ["writing Swift", "reading docs"])
        #expect(validated.contexts.first?.detail == "the app itself")
        #expect(validated.validated() == validated)
    }

    @Test func validationCapsNameAndDetailLength() {
        var s = MentorSettings()
        s.contexts = [MentorshipContext(name: String(repeating: "a", count: 200), detail: String(repeating: "b", count: 900))]
        let validated = s.validated()
        #expect(validated.contexts.first?.name.count == MentorshipContext.maxNameLength)
        #expect(validated.contexts.first?.detail.count == MentorshipContext.maxDetailLength)
    }

    @Test func validationCapsTheNumberOfContexts() {
        var s = MentorSettings()
        s.contexts = (0..<40).map { MentorshipContext(name: "context \($0)") }
        #expect(s.validated().contexts.count == ContextRules.maxContexts)
    }

    /// The editor refuses exactly what `normalized` would drop, so a saved
    /// context never disappears without the user being told why.
    @Test func aDuplicateNameIsRefusedBeforeValidationCanDropIt() {
        let existing = [
            MentorshipContext(name: "writing Swift"),
            MentorshipContext(name: "reading docs"),
        ]
        // A new context claiming a name already in use.
        #expect(ContextRules.isDuplicateName("  Writing swift ", in: existing, excluding: nil))
        #expect(!ContextRules.isDuplicateName("planning sprints", in: existing, excluding: nil))
        // Renaming an existing context onto another's name.
        #expect(ContextRules.isDuplicateName("reading docs", in: existing, excluding: existing[0].id))
        // Editing a context without renaming it is not a duplicate of itself.
        #expect(!ContextRules.isDuplicateName("writing Swift", in: existing, excluding: existing[0].id))
        // An empty name is refused on its own, not as a duplicate.
        #expect(!ContextRules.isDuplicateName("   ", in: existing, excluding: nil))

        // What the editor prevents is real: validation would have dropped it.
        var s = MentorSettings()
        s.contexts = existing + [MentorshipContext(name: "Writing swift")]
        #expect(s.validated().contexts.count == existing.count)
    }

    /// What the editor caps as the user types must survive `normalized`
    /// untouched, so a saved name or detail is never cut after the fact.
    @Test func theEditorsCapIsWhatValidationWouldHaveKept() {
        let longName = String(repeating: "a", count: 200)
        let longDetail = String(repeating: "b", count: 900)
        let cappedName = ContextRules.capped(longName, to: MentorshipContext.maxNameLength)
        let cappedDetail = ContextRules.capped(longDetail, to: MentorshipContext.maxDetailLength)
        #expect(cappedName.count == MentorshipContext.maxNameLength)
        #expect(cappedDetail.count == MentorshipContext.maxDetailLength)

        var s = MentorSettings()
        s.contexts = [MentorshipContext(name: cappedName, detail: cappedDetail)]
        let validated = s.validated()
        #expect(validated.contexts.first?.name == cappedName)
        #expect(validated.contexts.first?.detail == cappedDetail)

        // Text already within the limit is left exactly as typed, spaces and all.
        #expect(ContextRules.capped("writing Swift ", to: MentorshipContext.maxNameLength) == "writing Swift ")
        #expect(ContextRules.capped("", to: MentorshipContext.maxNameLength) == "")
    }

    @Test func validationKeepsIdentitiesStableSoEditingDoesNotReshuffle() {
        var s = MentorSettings()
        let context = MentorshipContext(name: "writing Swift")
        s.contexts = [context]
        #expect(s.validated().contexts.first?.id == context.id)
    }

    @Test func settingsRoundTripThroughJSONAndOlderFilesTakeTheDefaults() throws {
        var s = MentorSettings()
        s.onlyMentorInsideContexts = true
        s.contexts = [MentorshipContext(name: "writing Swift", detail: "the app")]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(MentorSettings.self, from: data) == s)

        let old = try JSONDecoder().decode(MentorSettings.self, from: Data(#"{"enabled": true}"#.utf8))
        #expect(!old.onlyMentorInsideContexts)
        #expect(old.contexts.isEmpty)
    }

    // MARK: Placement

    private var declared: [MentorshipContext] {
        [
            MentorshipContext(name: "writing Swift"),
            MentorshipContext(name: "reading API documentation"),
        ]
    }

    private func settings(enforcing: Bool = true) -> MentorSettings {
        var s = MentorSettings()
        s.onlyMentorInsideContexts = enforcing
        s.contexts = declared
        return s.validated()
    }

    @Test func theSwitchOffMeansContextsGateNothing() {
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: nil, contextConfidence: 1)
        #expect(settings(enforcing: false).contextPlacement(triage: verdict) == .notEnforced)
    }

    @Test func aNamedContextAboveTheThresholdIsInside() {
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: "reading API documentation", contextConfidence: 0.7)
        let placement = settings().contextPlacement(triage: verdict)
        #expect(placement.contextName == "reading API documentation")
        #expect(placement.label == "inside \"reading API documentation\" (70% confident)")
    }

    @Test func aNamedContextBelowTheFixedThresholdIsOutside() {
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: "reading API documentation", contextConfidence: 0.4)
        let placement = settings().contextPlacement(triage: verdict)
        #expect(placement == .outside(.belowConfidence(name: "reading API documentation", confidence: 0.4)))
        #expect(placement.label.contains("60% needed"))
    }

    @Test func nullAnAbsentAnswerAndAnUndeclaredNameAreAllOutside() {
        let s = settings()
        let none = TriageVerdict(worthALook: true, reason: "x", context: nil, contextConfidence: 0.9)
        #expect(s.contextPlacement(triage: none) == .outside(.noMatch(reason: "")))
        // A reply that answered neither field: enforcement fails closed.
        let silent = TriageVerdict(worthALook: true, reason: "x")
        #expect(s.contextPlacement(triage: silent) == .outside(.unanswered))
        let invented = TriageVerdict(worthALook: true, reason: "x", context: "cooking", contextConfidence: 1)
        #expect(s.contextPlacement(triage: invented).isOutside)
    }

    @Test func anEnforcedButEmptyListPutsEverythingOutside() {
        var s = settings()
        s.contexts = []
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: "writing Swift", contextConfidence: 1)
        #expect(s.contextPlacement(triage: verdict) == .outside(.noContextsDeclared))
    }
}
