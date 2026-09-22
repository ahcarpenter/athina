import Foundation
import Testing
@testable import AthinaCore

@Suite struct KeyStoreTests {
    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryKeyStore()
        #expect(try store.load() == nil)
        try store.save("sk-ant-test-1234")
        #expect(try store.load() == "sk-ant-test-1234")
        try store.save("sk-ant-test-5678")
        #expect(try store.load() == "sk-ant-test-5678")
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }

    @Test func keysAreNormalizedAndOnlyTheTailIsShown() {
        #expect(APIKey.normalized("  sk-ant-abc \n") == "sk-ant-abc")
        #expect(APIKey.normalized("") == nil)
        #expect(APIKey.normalized("   ") == nil)
        #expect(APIKey.normalized("sk-ant abc") == nil)
        #expect(APIKey.lastFour("sk-ant-api03-abcdefWXYZ") == "WXYZ")
        #expect(APIKey.lastFour("ab") == "ab")
    }

    @Test func keychainErrorsDescribeTheOperation() {
        let error = KeyStoreError(status: -25300, operation: "read")
        #expect(error.description.hasPrefix("keychain read: "))
    }
}

@Suite struct MentorSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let s = MentorSettings()
        #expect(s.triageModel == "claude-haiku-4-5-20251001")
        #expect(s.mentorModel == "claude-opus-5")
        #expect(s.mentorEffort == .medium)
        #expect(s.triageEffort == .low)
        #expect(s.effort(for: .triage) == nil)
        #expect(s.effort(for: .mentor) == .medium)
        #expect(Effort.allCases.contains(.xhigh))
        #expect(ModelCatalog.triageChoices.contains { $0.supportsEffort })
        #expect(s.triageMinInterval == 20)
        #expect(s.mentorMinInterval == 120)
        #expect(s.hourlySpendCap == 1)
        #expect(s.toastTimeout == 60)
        #expect(s.sendThumbnail)
        #expect(s.enabled)
        #expect(ModelCatalog.mentorChoices.map(\.id).contains("claude-fable-5-1"))
    }

    @Test func missingKeysTakeDefaultsAndBadModelsFallBack() throws {
        let data = Data(#"{"mentor": {"mentorModel": "claude-haiku-4-5-20251001", "triageMinInterval": 1, "hourlySpendCap": 5000}}"#.utf8)
        let decoded = try JSONDecoder().decode(SensingSettings.self, from: data)
        #expect(decoded.mentor.mentorModel == "claude-opus-5")
        #expect(decoded.mentor.triageMinInterval == 5)
        #expect(decoded.mentor.hourlySpendCap == 1000)
        #expect(decoded.mentor.mentorMinInterval == 120)
        #expect(decoded.floorInterval == SensingSettings().floorInterval)
    }

    @Test func settingsFileRoundTripsMentorSection() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("athina-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        var settings = SensingSettings()
        settings.mentor.mentorModel = "claude-fable-5-1"
        settings.mentor.triageModel = "claude-sonnet-5"
        settings.mentor.triageEffort = .xhigh
        settings.mentor.sendThumbnail = false
        settings.mentor.neverRules = [NeverRule(bundleID: "com.a", appName: "A", category: .risk, createdAt: Date(timeIntervalSince1970: 1_700_000_000))]
        settings.mentor.prices.prices["claude-opus-5"]?.inputPerMillion = 4
        try store.save(settings)
        let loaded = store.load()
        #expect(loaded == settings)
        #expect(loaded.mentor.prices.prices["claude-opus-5"]?.inputPerMillion == 4)
        #expect(loaded.mentor.effort(for: .triage) == .xhigh)
    }

    @Test func oldSettingsFilesWithoutMentorSectionStillLoad() throws {
        let data = Data(#"{"floorInterval": 7, "excludedBundleIDs": ["com.x"]}"#.utf8)
        let decoded = try JSONDecoder().decode(SensingSettings.self, from: data)
        #expect(decoded.floorInterval == 7)
        #expect(decoded.mentor == MentorSettings())
    }
}
