import Foundation
import Testing
@testable import MentorCore

/// Rule matching, settings validation, and the placement a triage answer maps
/// to. The gate that enforces these lives in `MentorSchedulerTests`.
@Suite struct MentorshipContextsTests {
    private func focus(app: String = "Xcode", bundleID: String? = "com.apple.dt.Xcode", window: String? = "main.swift") -> FocusContext {
        FocusContext(pid: 42, bundleID: bundleID, appName: app, windowTitle: window)
    }

    // MARK: Rule matching

    @Test func appRulesMatchTheBundleIdentifierOrTheAppNameCaseInsensitively() {
        let byBundle = ContextRule(kind: .app, value: "com.apple.DT.xcode")
        let byName = ContextRule(kind: .app, value: "xcode")
        #expect(ContextRules.matches(byBundle, focus: focus()))
        #expect(ContextRules.matches(byName, focus: focus()))
        #expect(!ContextRules.matches(byBundle, focus: focus(app: "Safari", bundleID: "com.apple.Safari")))
        #expect(!ContextRules.matches(byName, focus: focus(app: "Safari", bundleID: "com.apple.Safari")))
    }

    @Test func anAppRuleDoesNotMatchAPrefixOfAnotherBundleIdentifier() {
        let rule = ContextRule(kind: .app, value: "com.apple.dt")
        #expect(!ContextRules.matches(rule, focus: focus()))
    }

    @Test func appRulesMatchAnAppWithoutABundleIdentifierByName() {
        let rule = ContextRule(kind: .app, value: "Some Helper")
        #expect(ContextRules.matches(rule, focus: focus(app: "Some Helper", bundleID: nil)))
    }

    @Test func siteRulesMatchADomainInTheWindowTitleAtItsBoundaries() {
        let rule = ContextRule(kind: .site, value: "github.com")
        #expect(ContextRules.matches(rule, focus: focus(window: "mentor - github.com/ahcarpenter")))
        #expect(ContextRules.matches(rule, focus: focus(window: "https://GITHUB.COM/x")))
        // A subdomain is still the site.
        #expect(ContextRules.matches(rule, focus: focus(window: "docs.github.com/en")))
        // A longer domain that merely ends in it is not.
        #expect(!ContextRules.matches(rule, focus: focus(window: "notgithub.com/x")))
        #expect(!ContextRules.matches(rule, focus: focus(window: "github.community")))
        #expect(!ContextRules.matches(rule, focus: focus(window: "mygithub.com-mirror.net")))
        #expect(!ContextRules.matches(rule, focus: focus(window: nil)))
        #expect(!ContextRules.matches(rule, focus: focus(window: "")))
    }

    @Test func siteRulesFindTheDomainAfterAFalseStart() {
        let rule = ContextRule(kind: .site, value: "swift.org")
        #expect(ContextRules.matches(rule, focus: focus(window: "notswift.org and swift.org")))
    }

    @Test func siteValuesAreNormalizedToABareDomain() {
        #expect(ContextRules.normalized("https://www.GitHub.com/a/b?c=1", kind: .site) == "github.com")
        #expect(ContextRules.normalized("  docs.swift.org.  ", kind: .site) == "docs.swift.org")
        #expect(ContextRules.normalized("localhost:3000", kind: .site) == "localhost")
        #expect(ContextRules.normalized("user@example.com", kind: .site) == "example.com")
        // App values keep their case, because a bundle identifier is shown as typed.
        #expect(ContextRules.normalized("  com.apple.dt.Xcode ", kind: .app) == "com.apple.dt.Xcode")
    }

    @Test func theFirstMatchingRuleDecides() {
        let rules = [
            ContextRule(kind: .site, value: "example.com"),
            ContextRule(kind: .app, value: "com.apple.dt.Xcode"),
        ]
        let match = ContextRules.alwaysOutsideRule(matching: focus(), rules: rules)
        #expect(match?.value == "com.apple.dt.Xcode")
        #expect(ContextRules.alwaysOutsideRule(matching: focus(app: "Notes", bundleID: "com.apple.Notes"), rules: rules) == nil)
    }

    @Test func pinnedContextReportsBothTheContextAndTheRuleThatMatched() {
        let contexts = [
            MentorshipContext(name: "reading", alwaysInside: [ContextRule(kind: .site, value: "developer.apple.com")]),
            MentorshipContext(name: "writing Swift", alwaysInside: [ContextRule(kind: .app, value: "com.apple.dt.Xcode")]),
        ]
        let pinned = ContextRules.pinnedContext(for: focus(), contexts: contexts)
        #expect(pinned?.context.name == "writing Swift")
        #expect(pinned?.rule.kind == .app)
        #expect(ContextRules.pinnedContext(for: focus(app: "Notes", bundleID: "com.apple.Notes"), contexts: contexts) == nil)
    }

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

    @Test func validationNormalizesRulesAndDropsDuplicatesAndBlanks() {
        var s = MentorSettings()
        s.alwaysOutside = [
            ContextRule(kind: .site, value: "https://www.Example.com/inbox"),
            ContextRule(kind: .site, value: "example.com"),
            ContextRule(kind: .app, value: "  "),
            ContextRule(kind: .app, value: "com.apple.MobileSMS"),
        ]
        let validated = s.validated()
        #expect(validated.alwaysOutside.map(\.value) == ["example.com", "com.apple.MobileSMS"])
    }

    @Test func validationCapsTheListsAndClampsTheConfidence() {
        var s = MentorSettings()
        s.contexts = (0..<40).map { MentorshipContext(name: "context \($0)") }
        s.alwaysOutside = (0..<50).map { ContextRule(kind: .site, value: "site\($0).com") }
        s.contextConfidence = 4
        var low = s
        low.contextConfidence = -1
        #expect(s.validated().contexts.count == ContextRules.maxContexts)
        #expect(s.validated().alwaysOutside.count == ContextRules.maxRulesPerList)
        #expect(s.validated().contextConfidence == 1)
        #expect(low.validated().contextConfidence == 0)
    }

    @Test func validationKeepsIdentitiesStableSoEditingDoesNotReshuffle() {
        var s = MentorSettings()
        let context = MentorshipContext(name: "writing Swift", alwaysInside: [ContextRule(kind: .app, value: "com.apple.dt.Xcode")])
        s.contexts = [context]
        let validated = s.validated()
        #expect(validated.contexts.first?.id == context.id)
        #expect(validated.contexts.first?.alwaysInside.first?.id == context.alwaysInside[0].id)
    }

    @Test func settingsRoundTripThroughJSONAndOlderFilesTakeTheDefaults() throws {
        var s = MentorSettings()
        s.onlyMentorInsideContexts = true
        s.contextConfidence = 0.75
        s.contexts = [MentorshipContext(name: "writing Swift", detail: "the app", alwaysInside: [ContextRule(kind: .app, value: "com.apple.dt.Xcode")])]
        s.alwaysOutside = [ContextRule(kind: .site, value: "mail.google.com")]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(MentorSettings.self, from: data) == s)

        let old = try JSONDecoder().decode(MentorSettings.self, from: Data(#"{"enabled": true}"#.utf8))
        #expect(!old.onlyMentorInsideContexts)
        #expect(old.contexts.isEmpty)
        #expect(old.alwaysOutside.isEmpty)
        #expect(old.contextConfidence == MentorSettings().contextConfidence)
    }

    // MARK: Placement

    private var declared: [MentorshipContext] {
        [
            MentorshipContext(name: "writing Swift", alwaysInside: [ContextRule(kind: .app, value: "com.apple.dt.Xcode")]),
            MentorshipContext(name: "reading API documentation"),
        ]
    }

    private func settings(enforcing: Bool = true, threshold: Double = 0.6) -> MentorSettings {
        var s = MentorSettings()
        s.onlyMentorInsideContexts = enforcing
        s.contexts = declared
        s.contextConfidence = threshold
        return s.validated()
    }

    @Test func theSwitchOffMeansContextsGateNothing() {
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: nil, contextConfidence: 1)
        #expect(settings(enforcing: false).contextPlacement(for: focus(), triage: verdict) == .notEnforced)
    }

    @Test func aNamedContextAboveTheThresholdIsInside() {
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: "reading API documentation", contextConfidence: 0.7)
        let placement = settings().contextPlacement(for: focus(app: "Safari", bundleID: "com.apple.Safari"), triage: verdict)
        #expect(placement.contextName == "reading API documentation")
        #expect(placement.label == "inside \"reading API documentation\" (70% confident)")
    }

    @Test func aNamedContextBelowTheThresholdIsOutside() {
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: "reading API documentation", contextConfidence: 0.4)
        let placement = settings().contextPlacement(for: focus(app: "Safari", bundleID: "com.apple.Safari"), triage: verdict)
        #expect(placement == .outside(.belowConfidence(name: "reading API documentation", confidence: 0.4, threshold: 0.6)))
    }

    @Test func nullAnAbsentAnswerAndAnUndeclaredNameAreAllOutside() {
        let s = settings()
        let safari = focus(app: "Safari", bundleID: "com.apple.Safari")
        let none = TriageVerdict(worthALook: true, reason: "x", context: nil, contextConfidence: 0.9)
        #expect(s.contextPlacement(for: safari, triage: none) == .outside(.noMatch(reason: "")))
        // A reply that answered neither field: enforcement fails closed.
        let silent = TriageVerdict(worthALook: true, reason: "x")
        #expect(s.contextPlacement(for: safari, triage: silent) == .outside(.unanswered))
        let invented = TriageVerdict(worthALook: true, reason: "x", context: "cooking", contextConfidence: 1)
        #expect(s.contextPlacement(for: safari, triage: invented).isOutside)
    }

    @Test func anEnforcedButEmptyListPutsEverythingOutside() {
        var s = settings()
        s.contexts = []
        let verdict = TriageVerdict(worthALook: true, reason: "x", context: "writing Swift", contextConfidence: 1)
        #expect(s.contextPlacement(for: focus(), triage: verdict) == .outside(.noContextsDeclared))
    }

    @Test func anAlwaysInsideRuleWinsOverWhateverTriageAnswered() {
        let s = settings()
        let wrong = TriageVerdict(worthALook: true, reason: "x", context: "reading API documentation", contextConfidence: 0.1)
        let placement = s.contextPlacement(for: focus(), triage: wrong)
        #expect(placement.contextName == "writing Swift")
        #expect(placement.label == "inside \"writing Swift\" (app com.apple.dt.xcode is always inside it)")
    }

    @Test func anAlwaysInsideRuleIsIgnoredWhileTheSwitchIsOff() {
        #expect(settings(enforcing: false).pinnedContext(for: focus()) == nil)
    }

    @Test func anAlwaysOutsideRuleIsFoundWhetherOrNotTheSwitchIsOn() {
        var on = settings()
        on.alwaysOutside = [ContextRule(kind: .app, value: "com.apple.dt.Xcode")]
        var off = on
        off.onlyMentorInsideContexts = false
        #expect(on.alwaysOutsideRule(matching: focus())?.kind == .app)
        #expect(off.alwaysOutsideRule(matching: focus())?.kind == .app)
        #expect(off.alwaysOutsideRule(matching: focus(app: "Notes", bundleID: "com.apple.Notes")) == nil)
    }
}
