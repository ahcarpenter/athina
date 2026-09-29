import Foundation
import Testing

@testable import AthinaCore

/// Nothing is sensed and nothing is sent before the person allows it: the
/// stored answer, the sensing mode it forces, every scheduler gate, and the
/// loop itself with a scripted client.
@Suite(.timeLimit(.minutes(1))) struct ConsentTests {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: The stored answer

  @Test func onlyAllowToTheCurrentDisclosureOrALaterOneGrants() {
    #expect(!Consent.grants(nil))
    #expect(!Consent.grants(Consent(answer: .declined, at: t0)))
    #expect(Consent.grants(Consent(answer: .allowed, at: t0)))
    #expect(
      Consent.grants(
        Consent(answer: .allowed, at: t0, disclosureVersion: Consent.disclosureVersion + 1)
      )
    )
    #expect(
      !Consent.grants(
        Consent(answer: .allowed, at: t0, disclosureVersion: Consent.disclosureVersion - 1)
      )
    )
    #expect(
      !Consent.grants(
        Consent(answer: .declined, at: t0, disclosureVersion: Consent.disclosureVersion + 1)
      )
    )
  }

  @Test func settingsFromBeforeTheWindowExistedHaveNoConsent() throws {
    let settings = try SensingSettings(json: Data(#"{"idleThreshold": 120}"#.utf8))
    #expect(settings.consent == nil)
    #expect(!settings.hasConsent)
    #expect(settings.idleThreshold == 120)
    #expect(!SensingSettings().hasConsent)
  }

  @Test func theAnswerRoundTripsThroughTheSettingsFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "consent-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
    var settings = SensingSettings()
    settings.consent = Consent(answer: .allowed, at: t0)
    try store.save(settings)
    #expect(store.load().consent == settings.consent)
    #expect(store.load().hasConsent)

    settings.consent = Consent(answer: .declined, at: t0 + 60)
    try store.save(settings)
    #expect(store.load().consent == Consent(answer: .declined, at: t0 + 60))
    #expect(!store.load().hasConsent)
  }

  @Test func anUnreadableAnswerCountsAsNone() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "consent-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    let json =
      #"{"idleThreshold": 120, "consent": {"answer": "maybe", "at": 0, "disclosureVersion": 1}}"#
    try Data(json.utf8).write(to: url)
    // A settings file that cannot be read loads as the defaults, which
    // carry no answer, so the window asks again.
    #expect(!SettingsStore(url: url).load().hasConsent)
  }

  @Test func thePrivacyPolicyLinksToThePublishedDocument() {
    #expect(
      Consent.privacyPolicyURL.absoluteString
        == "https://github.com/getathina/athina/blob/main/docs/privacy.md"
    )
  }

  /// The end-to-end harness starts every existing scenario from these
  /// settings, so they must carry an Allow the app accepts; a disclosure
  /// version bump fails here until the seed is bumped with it.
  @Test func theEndToEndSeedSettingsGrantConsent() throws {
    let seed = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts/e2e/lib/settings.json")
    let settings = try SettingsStore(url: seed).loadStrictly()
    #expect(settings.hasConsent)
  }

  // MARK: The sensing mode

  private static let permissionCases: [PermissionStatus] = [
    PermissionStatus(screenRecording: true, accessibility: true),
    PermissionStatus(screenRecording: true, accessibility: false),
    PermissionStatus(screenRecording: false, accessibility: true),
    PermissionStatus(screenRecording: false, accessibility: false),
  ]

  @Test func withoutConsentNothingElseCanLetACaptureThrough() {
    for permissions in Self.permissionCases {
      for paused in [false, true] {
        for excluded in [false, true] {
          for idle in [false, true] {
            let mode = SensingMode.resolve(
              consented: false,
              paused: paused,
              permissions: permissions,
              frontmostExcluded: excluded,
              idle: idle
            )
            #expect(mode == .waitingForConsent)
            #expect(!mode.capturesFrames)
            #expect(!mode.isActive)
          }
        }
      }
    }
  }

  @Test func withConsentTheModeIsDecidedAsBefore() {
    func mode(
      paused: Bool = false,
      _ permissions: PermissionStatus,
      excluded: Bool = false,
      idle: Bool = false
    ) -> SensingMode {
      SensingMode.resolve(
        consented: true,
        paused: paused,
        permissions: permissions,
        frontmostExcluded: excluded,
        idle: idle
      )
    }
    let both = PermissionStatus(screenRecording: true, accessibility: true)
    #expect(mode(both) == .watching)
    #expect(mode(PermissionStatus(screenRecording: true, accessibility: false)) == .screenOnly)
    #expect(
      mode(PermissionStatus(screenRecording: false, accessibility: true)) == .accessibilityOnly
    )
    #expect(
      mode(PermissionStatus(screenRecording: false, accessibility: false)) == .waitingForPermissions
    )
    #expect(mode(paused: true, both, excluded: true, idle: true) == .paused)
    #expect(
      mode(PermissionStatus(screenRecording: false, accessibility: false), excluded: true)
        == .waitingForPermissions
    )
    #expect(mode(both, excluded: true, idle: true) == .excluded)
    #expect(mode(both, idle: true) == .idle)
  }

  @Test func waitingForConsentShowsTheShutMark() {
    for availability in [MentorStatus.Availability.ready, .noAPIKey, .noConsent] {
      #expect(
        MenuBarMark.resolve(mode: .waitingForConsent, availability: availability, offline: false)
          == .paused
      )
    }
    // A withdrawal reaches the loop before the pipeline's mode catches up.
    #expect(
      MenuBarMark.resolve(mode: .watching, availability: .noConsent, offline: false) == .paused
    )
  }

  // MARK: The gates

  private func conditions(
    consented: Bool,
    mode: SensingMode = .watching,
    inFlight: Bool = false
  ) -> MentorScheduler.Conditions {
    MentorScheduler.Conditions(
      mode: mode,
      consented: consented,
      hasAPIKey: true,
      callInFlight: inFlight,
      nextHourStart: t0 + 3600
    )
  }

  @Test func everyGateHoldsWithoutConsentWhateverTheModeSays() {
    let scheduler = MentorScheduler(settings: MentorSettings())
    let observation = Fixtures.observation(at: t0)
    for mode in SensingMode.allCases {
      let without = conditions(consented: false, mode: mode)
      #expect(scheduler.availabilityHold(conditions: without) == .noConsent)
      #expect(
        scheduler.triageGate(for: observation, conditions: without, now: t0) == .hold(.noConsent)
      )
      #expect(scheduler.followUpGate(conditions: without) == .hold(.noConsent))
      #expect(
        scheduler.followUpGate(conditions: conditions(consented: false, mode: mode, inFlight: true))
          == .hold(.noConsent)
      )
      #expect(
        scheduler.refreshGate(
          conditions: without,
          context: nil,
          period: RefreshPeriod(startedAt: t0 - 3600, activeUse: 3600, countedAt: t0),
          lastActivityAt: t0,
          now: t0
        ) == .hold(.unavailable(.noConsent))
      )
      #expect(
        scheduler.mentorGate(
          triage: TriageVerdict(worthALook: true, reason: "x"),
          context: .notEnforced,
          conditions: without,
          now: t0
        ) == .hold(.noConsent)
      )
      #expect(scheduler.publishGate(madeAt: t0, conditions: without, now: t0) == .withdrawn)
    }
    #expect(MentorScheduler.callGate(consented: false) == .noConsent)
    #expect(MentorScheduler.callGate(consented: true) == nil)
  }

  @Test func waitingForConsentHoldsEvenIfTheLoopThinksItHasConsent() {
    let scheduler = MentorScheduler(settings: MentorSettings())
    #expect(
      scheduler.availabilityHold(conditions: conditions(consented: true, mode: .waitingForConsent))
        == .noConsent
    )
  }

  @Test func withConsentTheGatesRunAsBefore() {
    let scheduler = MentorScheduler(settings: MentorSettings())
    let with = conditions(consented: true)
    #expect(
      scheduler.triageGate(for: Fixtures.observation(at: t0), conditions: with, now: t0) == .run
    )
    #expect(scheduler.followUpGate(conditions: with) == .run)
    #expect(
      scheduler.mentorGate(
        triage: TriageVerdict(worthALook: true, reason: "x"),
        context: .notEnforced,
        conditions: with,
        now: t0
      ) == .run
    )
    #expect(scheduler.publishGate(madeAt: t0, conditions: with, now: t0) == .show)
  }

  // MARK: The loop

  private static let yes = #"{"worth_a_look": true, "reason": "Repeated manual runs"}"#
  private static let suggestion =
    #"{"reason": "Saw it", "suggestion": {"title": "Use --filter", "body": "Run one suite.", "explanation": "swift test --filter Name", "category": "shortcut", "confidence": 0.9, "judged_goal": null}, "updated_understanding": null}"#

  private func journaledSuggestion(_ h: MentorLoopTests.Harness) async throws -> Suggestion {
    try await h.journal.record(
      Suggestion(
        timestamp: h.clock.date,
        bundleID: "com.apple.dt.Xcode",
        appName: "Xcode",
        windowTitle: "main.swift",
        category: .shortcut,
        title: "Use --filter",
        body: "Run one suite.",
        explanation: "swift test --filter Name",
        confidence: 0.9,
        observationID: nil,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version
      )
    )
  }

  @Test func aLoopWithoutConsentSendsNothingByAnyPath() async throws {
    let h = try await MentorLoopTests.Harness(consented: false)
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion)
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 0)
    let status = await h.loop.currentStatus()
    #expect(status.availability == .noConsent)
    #expect(status.lastGate?.hold == .noConsent)
    #expect(status.lastRefreshHold?.hold == .unavailable(.noConsent))

    let followUp = try #require(
      await h.loop.askFollowUp(about: try await journaledSuggestion(h), question: "why")
    )
    #expect(followUp.answer == nil)
    #expect(followUp.error == MentorScheduler.Hold.noConsent.label)

    #expect(
      await h.loop.testConnection() == .failure(.notSent(MentorScheduler.Hold.noConsent.label))
    )
    #expect(await h.client.sent.isEmpty)
    #expect(try await h.journal.recentModelCalls(limit: 10).isEmpty)
  }

  @Test func allowingLetsTheNextChangeMomentThrough() async throws {
    let h = try await MentorLoopTests.Harness(consented: false)
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion)
    await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 0)
    await h.loop.setConsented(true)
    #expect(await h.loop.currentStatus().availability == .ready)
    await h.observe(
      Fixtures.observation(id: 2, at: h.clock.date, window: "b", text: "b"),
      expectCalls: 2
    )
    #expect(await h.client.sent.map(\.call.kind) == ["triage", "mentor"])
  }

  /// Withdrawn while triage is on the network: that call cannot be taken
  /// back, but the mentor tier it would have led to never runs.
  @Test func withdrawingDuringTriageStopsTheMentorCall() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.setDelay(.milliseconds(400))
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion)
    h.input.yield(.observation(Fixtures.observation(id: 1, at: h.clock.date)))
    await h.clock.waitForSleepers()
    #expect(await h.loop.currentStatus().inFlight == .triage)

    await h.loop.setConsented(false)
    h.clock.advance(by: .milliseconds(400))
    await h.waitUntil { $0.lastMentorHold != nil && $0.inFlight == nil }
    #expect(await h.loop.currentStatus().lastMentorHold?.hold == .noConsent)
    #expect(await h.client.sent.map(\.call.kind) == ["triage"])
  }

  /// Withdrawn while the mentor call is on the network: its suggestion is
  /// journaled as never seen and never reaches the screen.
  @Test func aSuggestionFinishedAfterWithdrawalIsNeverShown() async throws {
    let h = try await MentorLoopTests.Harness()
    await h.client.setDelay(.milliseconds(400))
    await h.client.enqueue(json: Self.yes)
    await h.client.enqueue(json: Self.suggestion)
    h.input.yield(.observation(Fixtures.observation(id: 1, at: h.clock.date)))
    await h.clock.waitForSleepers()
    h.clock.advance(by: .milliseconds(400))
    await h.waitUntil { $0.inFlight == .mentor }
    await h.clock.waitForSleepers()

    await h.loop.setConsented(false)
    h.clock.advance(by: .milliseconds(400))
    let events = await h.drain { if case .feedback = $0 { return true } else { return false } }
    #expect(!events.contains { if case .suggestion = $0 { return true } else { return false } })
    guard case .feedback(let expired)? = events.last else {
      Issue.record("expected the suggestion to expire unseen")
      return
    }
    #expect(expired.feedback == .expiredUnseen)
    #expect(try await h.journal.recentSuggestions(limit: 1).first?.feedback == .expiredUnseen)
  }
}
