import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts
import Testing

@testable import AthinaCore

@Suite struct SettingsStoreTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("athina-tests-\(UUID().uuidString)")
      .appendingPathComponent("settings.json")
  }

  @Test func missingFileYieldsDefaults() {
    let store = SettingsStore(url: temporaryURL())
    #expect(store.load() == SensingSettings())
  }

  @Test func roundTrip() throws {
    let store = SettingsStore(url: temporaryURL())
    var settings = SensingSettings()
    settings.floorInterval = 9
    settings.excludedBundleIDs = ["com.example.Secret"]
    settings.pauseShortcut = HotKey(keyCode: 1, modifiers: [.command, .shift])
    settings.ocrLevel = .accurate
    try store.save(settings)
    #expect(store.load() == settings)
  }

  @Test func corruptFileYieldsDefaults() throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{not json".utf8).write(to: url)
    #expect(SettingsStore(url: url).load() == SensingSettings())
  }

  @Test func missingKeysTakeDefaults() throws {
    let data = Data(#"{"floorInterval": 12}"#.utf8)
    let decoded = try SensingSettings(json: data)
    #expect(decoded.floorInterval == 12)
    #expect(decoded.idleThreshold == SensingSettings().idleThreshold)
    #expect(decoded.excludedBundleIDs == ExcludedApps.defaults)
  }

  /// A new install pauses on Control-Option-Command-P; the person can clear
  /// it, it stays cleared from one launch to the next, and recording one
  /// sets it again.
  @Test func thePauseShortcutClearsAndStaysCleared() throws {
    #expect(SensingSettings().pauseShortcut == .defaultPause)
    let store = SettingsStore(url: temporaryURL())
    var settings = SensingSettings()
    settings.pauseShortcut = nil
    try store.save(settings)
    #expect(store.load().pauseShortcut == nil)
    #expect(store.load() == settings)
    let chosen = HotKey(keyCode: 1, modifiers: [.control, .option])
    settings.pauseShortcut = chosen
    try store.save(settings)
    #expect(store.load().pauseShortcut == chosen)
  }

  /// Every earlier build reads `pauseHotKey` as a combination that is always
  /// set, and nothing else about it: a cleared shortcut keeps its last
  /// combination there, so an earlier build reads the file and pauses on
  /// that combination, and a file an earlier build wrote reads as set.
  @Test func anEarlierBuildReadsAClearedPauseShortcutAsItsLastCombination() throws {
    let chosen = HotKey(keyCode: 1, modifiers: [.control, .option])
    var settings = SensingSettings()
    settings.pauseShortcut = chosen
    settings.pauseShortcut = nil
    let file = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    let stored = try #require((file as? [String: Any])?["pauseHotKey"])
    let earlier = try JSONDecoder().decode(
      HotKey.self,
      from: JSONSerialization.data(withJSONObject: stored)
    )
    #expect(earlier == chosen)

    let written = Data(#"{"pauseHotKey": {"keyCode": 1, "modifiers": 3}}"#.utf8)
    #expect(try SensingSettings(json: written).pauseShortcut == chosen)
  }

  /// The debug panel is something the person turns on: a new install and a
  /// settings file written before the switch existed both start with it off,
  /// and turning it on is kept.
  @Test func theDebugPanelStartsOffAndKeepsBeingTurnedOn() throws {
    #expect(SensingSettings().showDebugPanel == false)
    let older = Data(#"{"floorInterval": 12, "mentor": {"enabled": true}}"#.utf8)
    #expect(try SensingSettings(json: older).showDebugPanel == false)
    let store = SettingsStore(url: temporaryURL())
    var settings = SensingSettings()
    settings.showDebugPanel = true
    try store.save(settings)
    #expect(store.load().showDebugPanel == true)
  }

  @Test func validationClampsOutOfRangeValues() throws {
    let data = Data(
      #"{"floorInterval": -5, "hashDistanceThreshold": 999, "maxFrameDimension": 10}"#.utf8
    )
    let decoded = try SensingSettings(json: data)
    #expect(decoded.floorInterval == 1)
    #expect(decoded.hashDistanceThreshold == PerceptualHash.bitCount)
    #expect(decoded.maxFrameDimension == 320)
  }

  @Test func textRetentionIsAtLeastThumbnailRetention() {
    var settings = SensingSettings()
    settings.thumbnailRetention = 6 * 3600
    settings.textRetention = 3600
    #expect(settings.validated().textRetention == 6 * 3600)
    settings.textRetention = 12 * 3600
    #expect(settings.validated().textRetention == 12 * 3600)
  }

  @Test func understandingSettingsHaveTheirDocumentedDefaults() {
    let d = MentorSettings()
    #expect(d.understandingModel == ModelCatalog.opus5.id)
    #expect(d.understandingEffort == .low)
    #expect(d.understandingRefreshInterval == 900)
    #expect(d.understandingIdleGap == 4 * 3600)
    #expect(d.effort(for: .understanding) == .low)
  }

  @Test func aMentorFileWrittenBeforeTheUnderstandingTakesItsDefaults() throws {
    // A settings file from the previous build has none of these keys.
    let data = Data(#"{"mentorModel": "claude-sonnet-5", "hourlySpendCap": 2}"#.utf8)
    let decoded = try MentorSettings(json: data)
    #expect(decoded.mentorModel == "claude-sonnet-5")
    #expect(decoded.hourlySpendCap == 2)
    #expect(decoded.understandingModel == MentorSettings().understandingModel)
    #expect(decoded.understandingRefreshInterval == MentorSettings().understandingRefreshInterval)
    #expect(decoded.understandingTokenBudget == MentorSettings().understandingTokenBudget)
    #expect(decoded.understandingIdleGap == MentorSettings().understandingIdleGap)
  }

  @Test func understandingSettingsRoundTripAndClamp() throws {
    var settings = MentorSettings()
    settings.understandingModel = ModelCatalog.haiku45.id
    settings.understandingEffort = .high
    settings.understandingRefreshInterval = 1800
    settings.understandingTokenBudget = 2000
    settings.understandingIdleGap = 8 * 3600
    let decoded = try MentorSettings(json: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    // Haiku rejects the effort parameter, so none is sent for that tier.
    #expect(decoded.effort(for: .understanding) == nil)

    let outOfRange = Data(
      #"""
      {"understandingTokenBudget": 99999, "understandingIdleGap": 5, "understandingModel": \#
      "not-a-model"}
      """#
      .utf8
    )
    let clamped = try MentorSettings(json: outOfRange)
    #expect(
      clamped.understandingTokenBudget == MentorSettings.understandingTokenBudgetRange.upperBound
    )
    #expect(clamped.understandingIdleGap == 600)
    #expect(clamped.understandingModel == MentorSettings().understandingModel)
  }
}

/// Settings read through their synthesized `Codable` laid over the defaults
/// (`SettingsSection`): every field is saved and read with no line of its
/// own, and a file an older build wrote keeps every value it holds.
@Suite struct SettingsSectionTests {
  private struct NotAnObject: Error {}

  /// Every field set away from its default, and valid as it stands.
  private var everyFieldChanged: SensingSettings {
    var s = SensingSettings()
    s.focusSettleDelay = 0.5
    s.inputSettleDelay = 2
    s.floorInterval = 9
    s.minCaptureInterval = 1
    s.idleThreshold = 120
    s.inputPollInterval = 0.25
    s.idlePollInterval = 3
    s.maxFrameDimension = 1024
    s.hashDistanceThreshold = 6
    s.thumbnailJPEGQuality = 0.7
    s.ocrLevel = .fast
    s.thumbnailRetention = 3 * 3600
    s.textRetention = 2 * 86400
    s.journalSizeCapBytes = 200 * 1024 * 1024
    s.retentionInterval = 300
    s.excludedBundleIDs = ["com.example.Secret"]
    // A cleared shortcut still keeps its last combination.
    s.pauseShortcut = HotKey(keyCode: 1, modifiers: [.command, .shift])
    s.pauseShortcut = nil
    s.showDebugPanel = true
    s.mentor.enabled = false
    s.mentor.triageModel = ModelCatalog.sonnet5.id
    s.mentor.mentorModel = ModelCatalog.fable51.id
    s.mentor.understandingModel = ModelCatalog.haiku45.id
    s.mentor.triageEffort = .high
    s.mentor.mentorEffort = .xhigh
    s.mentor.understandingEffort = .high
    s.mentor.triageMinInterval = 30
    s.mentor.mentorMinInterval = 300
    s.mentor.triageSimilarityThreshold = 0.8
    s.mentor.onlyMentorInsideContexts = true
    s.mentor.contexts = [
      MentorshipContext(
        id: UUID(uuidString: "6F1C2B0A-3D4E-4F5A-8B9C-0D1E2F3A4B5C")!,
        name: "writing Swift",
        detail: "the app"
      )
    ]
    s.mentor.mentorWindowDuration = 900
    s.mentor.mentorWindowTokenBudget = 8000
    s.mentor.sendThumbnail = false
    s.mentor.understandingRefreshInterval = 1800
    s.mentor.understandingTokenBudget = 2000
    s.mentor.understandingIdleGap = 8 * 3600
    s.mentor.minimumConfidence = 0.7
    s.mentor.toastTimeout = 30
    s.mentor.notNowSnooze = 7200
    s.mentor.showCallouts = false
    s.mentor.pushToTalkHotKey = HotKey(keyCode: 17, modifiers: [.control, .option, .command])
    s.mentor.hourlySpendCap = 2.5
    s.mentor.prices.checkedOn = "2026-09-20"
    s.mentor.prices.prices[ModelCatalog.opus5.id]?.inputPerMillion = 4
    s.mentor.neverRules = [
      NeverRule(
        bundleID: "com.a",
        appName: "A",
        category: .risk,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    ]
    s.mentor.snoozes = [
      Snooze(
        bundleID: "com.b",
        appName: "B",
        category: .tool,
        until: Date(timeIntervalSince1970: 1_700_003_600)
      )
    ]
    return s
  }

  private func object(_ value: some Encodable) throws -> [String: JSONValue] {
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    guard case .object(let fields) = json else { throw NotAnObject() }
    return fields
  }

  private func mentorObject(_ fields: [String: JSONValue]) throws -> [String: JSONValue] {
    guard case .object(let mentor)? = fields["mentor"] else { throw NotAnObject() }
    return mentor
  }

  private func data(_ fields: [String: JSONValue]) throws -> Data {
    try JSONEncoder().encode(JSONValue.object(fields))
  }

  /// The sample must leave no field at its default, or a field added later
  /// could be missing from it and from both tests below that read it.
  @Test func theSampleChangesEveryField() throws {
    let sample = everyFieldChanged
    #expect(sample.validated() == sample)
    let changed = try object(sample)
    let defaults = try object(SensingSettings())
    let changedMentor = try mentorObject(changed)
    let defaultMentor = try mentorObject(defaults)
    let unchanged = Set(changed.keys).union(defaults.keys).filter { changed[$0] == defaults[$0] }
    let unchangedMentor = Set(changedMentor.keys).union(defaultMentor.keys).filter {
      changedMentor[$0] == defaultMentor[$0]
    }
    let named = unchanged.sorted() + unchangedMentor.sorted().map { "mentor." + $0 }
    #expect(named.isEmpty, "set these in everyFieldChanged: \(named)")
  }

  @Test func everyFieldSurvivesASaveAndLoad() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("athina-tests-\(UUID().uuidString)")
      .appendingPathComponent("settings.json")
    let store = SettingsStore(url: url)
    try store.save(everyFieldChanged)
    #expect(store.load() == everyFieldChanged)
    #expect(try store.loadStrictly() == everyFieldChanged)
  }

  /// A file written before any one field existed: that field takes its
  /// default and every other value is kept, in both sections.
  @Test func anOlderFileKeepsEveryValueItHolds() throws {
    let full = try object(everyFieldChanged)
    let defaults = try object(SensingSettings())
    let mentor = try mentorObject(full)
    let defaultMentor = try mentorObject(defaults)
    var cases: [(missing: String, older: [String: JSONValue], expected: [String: JSONValue])] = []
    for key in full.keys {
      var older = full
      older[key] = nil
      var expected = full
      expected[key] = defaults[key]
      cases.append((key, older, expected))
    }
    for key in mentor.keys {
      var olderMentor = mentor
      olderMentor[key] = nil
      var expectedMentor = mentor
      expectedMentor[key] = defaultMentor[key]
      var older = full
      older["mentor"] = .object(olderMentor)
      var expected = full
      expected["mentor"] = .object(expectedMentor)
      cases.append(("mentor." + key, older, expected))
    }
    for (missing, older, expected) in cases.sorted(by: { $0.missing < $1.missing }) {
      let wanted = try JSONDecoder().decode(SensingSettings.self, from: data(expected))
      do {
        #expect(try SensingSettings(json: data(older)) == wanted, "a file without \(missing)")
      } catch {
        Issue.record("a file without \(missing) does not load: \(error)")
      }
    }
  }

  private struct Section: SettingsSection, Equatable {
    struct Inner: Codable, Equatable {
      var kept = 1
      var added = 2
    }
    var inner = Inner()
    var table = ["built-in": 1]
    var list = [1, 2]
    var optional: Int?
    var number = 3

    func validated() -> Section { self }
  }

  /// A struct inside takes its defaults key by key; a dictionary, an array
  /// and an optional come whole from the file; a null counts as missing; a
  /// value of the wrong type still fails.
  @Test func theFileIsLaidOverTheDefaultsDownToEachStruct() throws {
    let file = Data(
      #"""
      {"inner": {"kept": 5}, "table": {"mine": 7}, "list": [9], "optional": 4, "number": null, \#
      "unknown": true}
      """#
      .utf8
    )
    var expected = Section()
    expected.inner.kept = 5
    expected.table = ["mine": 7]
    expected.list = [9]
    expected.optional = 4
    #expect(try Section(json: file) == expected)
    #expect(try Section(json: Data("{}".utf8)) == Section())
    #expect(throws: DecodingError.self) { try Section(json: Data(#"{"number": "three"}"#.utf8)) }
    #expect(throws: DecodingError.self) { try Section(json: Data("[]".utf8)) }
  }

  /// A saved nil is a missing key, which reads back as the default, so an
  /// optional setting whose default is not nil could never be cleared.
  @Test func everyOptionalSettingDefaultsToNil() {
    func optionalsSet(in value: Any, at path: String) -> [String] {
      Mirror(reflecting: value).children.flatMap { child -> [String] in
        let name = path + (child.label ?? "?")
        let mirror = Mirror(reflecting: child.value)
        switch mirror.displayStyle {
        case .optional: return mirror.children.isEmpty ? [] : [name]
        case .struct: return optionalsSet(in: child.value, at: name + ".")
        default: return []
        }
      }
    }
    #expect(optionalsSet(in: SensingSettings(), at: "").isEmpty)
  }
}

@Suite struct ExcludedAppsTests {
  @Test func defaultsIncludeKeychainAccessAndPasswordManagers() {
    #expect(ExcludedApps.defaults.contains("com.apple.keychainaccess"))
    #expect(ExcludedApps.defaults.contains("com.1password.1password"))
    #expect(ExcludedApps.defaults.contains("com.bitwarden.desktop"))
  }

  @Test func matchingIsCaseInsensitive() {
    var settings = SensingSettings()
    settings.excludedBundleIDs = ["Com.Example.Vault"]
    #expect(settings.isExcluded(bundleID: "com.example.vault"))
    #expect(!settings.isExcluded(bundleID: "com.example.other"))
    #expect(!settings.isExcluded(bundleID: nil))
  }

  @Test func normalizationTrimsAndDeduplicates() {
    let ids = ExcludedApps.normalized([" com.a.b ", "", "com.A.B", "com.c.d"])
    #expect(ids == ["com.a.b", "com.c.d"])
  }
}

@Suite struct HotKeyTests {
  /// The modifiers every earlier build registered with Carbon for a stored
  /// shortcut, bit for bit.
  private func carbonModifiers(_ modifiers: HotKey.Modifiers) -> Int {
    var flags = 0
    if modifiers.contains(.command) { flags |= cmdKey }
    if modifiers.contains(.option) { flags |= optionKey }
    if modifiers.contains(.control) { flags |= controlKey }
    if modifiers.contains(.shift) { flags |= shiftKey }
    return flags
  }

  @Test func aSavedShortcutRegistersTheCombinationEarlierBuildsDid() throws {
    // Control-Option-Command-P as settings.json has always held it.
    let saved = try JSONDecoder().decode(
      HotKey.self,
      from: Data(#"{"keyCode": 35, "modifiers": 11}"#.utf8)
    )
    #expect(saved == .defaultPause)
    let pause = KeyboardShortcuts.Shortcut(.p, modifiers: [.control, .option, .command])
    #expect(saved.shortcut == pause)
    #expect(saved.shortcut.carbonKeyCode == kVK_ANSI_P)
    #expect(saved.shortcut.carbonModifiers == controlKey | optionKey | cmdKey)
  }

  @Test func everyStoredCombinationIsTheSameShortcutBothWays() {
    for bits in 0..<16 {
      let key = HotKey(keyCode: 17, modifiers: HotKey.Modifiers(rawValue: UInt32(bits)))
      #expect(key.shortcut.carbonKeyCode == 17)
      #expect(key.shortcut.carbonModifiers == carbonModifiers(key.modifiers))
      #expect(HotKey(key.shortcut) == key)
    }
  }

  @Test func theStoredFormIsTheOneEarlierBuildsWrote() throws {
    let key = HotKey(keyCode: 12, modifiers: [.option, .command])
    let data = try JSONEncoder().encode(key)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
    #expect(object == ["keyCode": 12, "modifiers": 10])
    #expect(try JSONDecoder().decode(HotKey.self, from: data) == key)
  }

  @Test func aShortcutWithFnIsNotStored() {
    #expect(HotKey(KeyboardShortcuts.Shortcut(.a, modifiers: [.command, .function])) == nil)
  }

  @Test func usabilityNeedsARealModifierOrAFunctionKey() {
    #expect(HotKey.defaultPause.isUsable)
    #expect(!HotKey(keyCode: 0, modifiers: [.shift]).isUsable)
    #expect(!HotKey(keyCode: 0, modifiers: []).isUsable)
    #expect(HotKey(keyCode: UInt32(kVK_F13), modifiers: []).isUsable)
    #expect(HotKey(keyCode: UInt32(kVK_F5), modifiers: [.shift]).isUsable)
  }

  @Test @MainActor func displayStringShowsModifiersAndKey() {
    let key = HotKey(keyCode: UInt32(kVK_F5), modifiers: [.control, .command])
    #expect(key.displayString == "⌃⌘F5")
  }
}

@Suite struct ProcessResourcesTests {
  @Test func usageIsCPUTimeOverWallTime() {
    let t0 = Date(timeIntervalSince1970: 100)
    let a = ProcessResourceSample(cpuSeconds: 10, wallTime: t0, footprintBytes: 1)
    let b = ProcessResourceSample(cpuSeconds: 10.5, wallTime: t0 + 2, footprintBytes: 2)
    let usage = ProcessResourceUsage.between(a, b)
    #expect(usage?.cpuPercent == 25)
    #expect(usage?.footprintBytes == 2)
    #expect(ProcessResourceUsage.between(a, a) == nil)
  }

  @Test func liveSampleIsPlausible() {
    let sample = ProcessResources.sample()
    #expect(sample.cpuSeconds >= 0)
    #expect(sample.footprintBytes > 1_000_000)
  }
}

@Suite struct FocusContextTests {
  @Test func summaryDescribesWindowFocusAndText() {
    let context = FocusContext(
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      pid: 1,
      bundleID: "com.apple.Safari",
      appName: "Safari",
      windowTitle: "Apple",
      focusedRole: "AXTextField",
      focusedTitle: "Search",
      focusedValue: "swift\nconcurrency",
      focusedValueLength: 17
    )
    #expect(
      context.summary
        == "Safari: window \"Apple\"; focus AXTextField \"Search\"; text \"swift⏎concurrency\""
    )
    #expect(context.windowSignature == "com.apple.Safari|Apple")
  }

  @Test func excludedAndUnavailableSummaries() {
    var context = FocusContext(
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      pid: 1,
      bundleID: "com.1password.1password",
      appName: "1Password",
      isExcluded: true
    )
    #expect(context.summary == "1Password (excluded, not read)")
    context.isExcluded = false
    context.accessibilityAvailable = false
    #expect(context.summary == "1Password (accessibility unavailable)")
  }
}

@Suite struct EventBroadcasterTests {
  @Test func everySubscriberReceivesEveryEvent() async {
    let broadcaster = EventBroadcaster<Int>()
    let a = await broadcaster.subscribe()
    let b = await broadcaster.subscribe()
    await broadcaster.send(1)
    await broadcaster.send(2)
    await broadcaster.finish()
    var seenA: [Int] = []
    for await value in a { seenA.append(value) }
    var seenB: [Int] = []
    for await value in b { seenB.append(value) }
    #expect(seenA == [1, 2])
    #expect(seenB == [1, 2])
  }
}
