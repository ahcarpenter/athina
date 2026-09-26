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
    settings.pauseHotKey = HotKey(keyCode: 1, modifiers: [.command, .shift])
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
    let decoded = try JSONDecoder().decode(SensingSettings.self, from: data)
    #expect(decoded.floorInterval == 12)
    #expect(decoded.idleThreshold == SensingSettings().idleThreshold)
    #expect(decoded.excludedBundleIDs == ExcludedApps.defaults)
  }

  /// A new install pauses on Control-Option-Command-P; the person can clear
  /// it, it stays cleared from one launch to the next, and recording one
  /// sets it again.
  @Test func thePauseShortcutClearsAndStaysCleared() throws {
    #expect(SensingSettings().pauseHotKey == .defaultPause)
    let store = SettingsStore(url: temporaryURL())
    var settings = SensingSettings()
    settings.pauseHotKey = nil
    try store.save(settings)
    #expect(store.load().pauseHotKey == nil)
    #expect(store.load() == settings)
    let chosen = HotKey(keyCode: 1, modifiers: [.control, .option])
    settings.pauseHotKey = chosen
    try store.save(settings)
    #expect(store.load().pauseHotKey == chosen)
  }

  /// Every earlier build reads `pauseHotKey` as a combination that is always
  /// set, and nothing else about it: a cleared shortcut keeps its last
  /// combination there, so an earlier build reads the file and pauses on
  /// that combination, and a file an earlier build wrote reads as set.
  @Test func anEarlierBuildReadsAClearedPauseShortcutAsItsLastCombination() throws {
    let chosen = HotKey(keyCode: 1, modifiers: [.control, .option])
    var settings = SensingSettings()
    settings.pauseHotKey = chosen
    settings.pauseHotKey = nil
    let file = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    let stored = try #require((file as? [String: Any])?["pauseHotKey"])
    let earlier = try JSONDecoder().decode(
      HotKey.self,
      from: JSONSerialization.data(withJSONObject: stored)
    )
    #expect(earlier == chosen)

    let written = Data(#"{"pauseHotKey": {"keyCode": 1, "modifiers": 3}}"#.utf8)
    #expect(try JSONDecoder().decode(SensingSettings.self, from: written).pauseHotKey == chosen)
  }

  /// The debug panel is something the person turns on: a new install and a
  /// settings file written before the switch existed both start with it off,
  /// and turning it on is kept.
  @Test func theDebugPanelStartsOffAndKeepsBeingTurnedOn() throws {
    #expect(SensingSettings().showDebugPanel == false)
    let older = Data(#"{"floorInterval": 12, "mentor": {"enabled": true}}"#.utf8)
    #expect(try JSONDecoder().decode(SensingSettings.self, from: older).showDebugPanel == false)
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
    let decoded = try JSONDecoder().decode(SensingSettings.self, from: data)
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
    let decoded = try JSONDecoder().decode(MentorSettings.self, from: data)
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
    let decoded = try JSONDecoder().decode(
      MentorSettings.self,
      from: try JSONEncoder().encode(settings)
    )
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
    let clamped = try JSONDecoder().decode(MentorSettings.self, from: outOfRange)
    #expect(
      clamped.understandingTokenBudget == MentorSettings.understandingTokenBudgetRange.upperBound
    )
    #expect(clamped.understandingIdleGap == 600)
    #expect(clamped.understandingModel == MentorSettings().understandingModel)
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
