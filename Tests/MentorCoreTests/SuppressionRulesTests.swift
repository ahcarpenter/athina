import Foundation
import Testing
@testable import MentorCore

@Suite struct SuppressionRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func neverRuleMatchesAppAndCategoryCaseInsensitively() {
        let rule = NeverRule(bundleID: "com.apple.dt.Xcode", appName: "Xcode", category: .shortcut, createdAt: t0)
        let reason = SuppressionRules.reason(for: .shortcut, bundleID: "COM.APPLE.DT.XCODE", neverRules: [rule], snoozes: [], now: t0)
        #expect(reason == .never(rule))
        #expect(SuppressionRules.reason(for: .workflow, bundleID: "com.apple.dt.Xcode", neverRules: [rule], snoozes: [], now: t0) == nil)
        #expect(SuppressionRules.reason(for: .shortcut, bundleID: "com.apple.Safari", neverRules: [rule], snoozes: [], now: t0) == nil)
        #expect(SuppressionRules.reason(for: .shortcut, bundleID: nil, neverRules: [rule], snoozes: [], now: t0) == nil)
    }

    @Test func appsWithoutBundleIDMatchOnlyRulesWithoutOne() {
        let rule = NeverRule(bundleID: nil, appName: "Mystery", category: .tool, createdAt: t0)
        #expect(SuppressionRules.reason(for: .tool, bundleID: nil, neverRules: [rule], snoozes: [], now: t0) == .never(rule))
        #expect(SuppressionRules.reason(for: .tool, bundleID: "com.x.y", neverRules: [rule], snoozes: [], now: t0) == nil)
    }

    @Test func snoozeExpiresAndNeverWins() {
        let snooze = Snooze(bundleID: "com.apple.Safari", appName: "Safari", category: .tool, until: t0 + 3600)
        #expect(SuppressionRules.reason(for: .tool, bundleID: "com.apple.Safari", neverRules: [], snoozes: [snooze], now: t0) == .snoozed(until: t0 + 3600))
        #expect(SuppressionRules.reason(for: .tool, bundleID: "com.apple.Safari", neverRules: [], snoozes: [snooze], now: t0 + 3600) == nil)
        let never = NeverRule(bundleID: "com.apple.Safari", appName: "Safari", category: .tool, createdAt: t0)
        #expect(SuppressionRules.reason(for: .tool, bundleID: "com.apple.Safari", neverRules: [never], snoozes: [snooze], now: t0) == .never(never))
    }

    @Test func addingReplacesSameAppAndCategory() {
        let a = NeverRule(bundleID: "com.a", appName: "A", category: .risk, createdAt: t0)
        let b = NeverRule(bundleID: "COM.A", appName: "A", category: .risk, createdAt: t0 + 10)
        let c = NeverRule(bundleID: "com.a", appName: "A", category: .tool, createdAt: t0 + 20)
        let rules = SuppressionRules.adding(c, to: SuppressionRules.adding(b, to: [a]))
        #expect(rules == [b, c])

        let s1 = Snooze(bundleID: "com.a", appName: "A", category: .risk, until: t0 + 10)
        let s2 = Snooze(bundleID: "com.a", appName: "A", category: .risk, until: t0 + 100)
        let expired = Snooze(bundleID: "com.b", appName: "B", category: .risk, until: t0 - 1)
        #expect(SuppressionRules.adding(s2, to: [s1, expired], now: t0) == [s2])
    }

    @Test func suppressedCategoriesListsEverythingBlocked() {
        let never = NeverRule(bundleID: "com.a", appName: "A", category: .shortcut, createdAt: t0)
        let snooze = Snooze(bundleID: "com.a", appName: "A", category: .workflow, until: t0 + 60)
        let categories = SuppressionRules.suppressedCategories(bundleID: "com.a", neverRules: [never], snoozes: [snooze], now: t0)
        #expect(categories == [.shortcut, .workflow])
        #expect(SuppressionRules.suppressedCategories(bundleID: "com.b", neverRules: [never], snoozes: [snooze], now: t0).isEmpty)
    }

    @Test func settingsValidationDeduplicatesNeverRulesKeepingTheNewest() {
        var settings = MentorSettings()
        let old = NeverRule(bundleID: "com.a", appName: "A", category: .risk, createdAt: t0)
        let new = NeverRule(bundleID: "com.a", appName: "A", category: .risk, createdAt: t0 + 5)
        settings.neverRules = [old, new]
        #expect(settings.validated().neverRules == [new])
    }
}
