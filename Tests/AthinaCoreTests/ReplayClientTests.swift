import Foundation
import Testing

@testable import AthinaCore

/// Recording, replaying, and choosing between them at launch, at the client
/// level. `ReplayLoopTests` runs the whole loop on top of these.
@Suite(.timeLimit(.minutes(1))) struct ReplayClientTests {
  private static func response(
    _ text: String,
    model: String = "claude-haiku-4-5-20251001",
    usage: Usage = Usage(inputTokens: 900, outputTokens: 30)
  ) -> MessagesResponse {
    MessagesResponse(
      id: "msg_\(text.count)",
      model: model,
      stopReason: "end_turn",
      content: [ResponseBlock(type: "text", text: text)],
      usage: usage
    )
  }

  private static func entry(
    _ name: String,
    kind: String,
    version: Int = MentorPrompts.version,
    result: Result<MessagesResponse, ClaudeClientError>,
    latency: TimeInterval = 1
  ) -> ReplayClaudeClient.Entry {
    var fixture = CallFixtureTests.fixture(
      kind: kind,
      promptVersion: version,
      request: CallFixtureTests.request(),
      result: result
    )
    fixture.latency = latency
    return ReplayClaudeClient.Entry(name: name, fixture: fixture)
  }

  private static func identity(_ kind: String, version: Int = MentorPrompts.version) -> CallIdentity
  {
    CallIdentity(kind: kind, promptVersion: version)
  }

  /// A request that shares nothing with the recorded one.
  private static let unrelatedRequest = MessagesRequest(
    model: "claude-opus-5",
    maxTokens: 10,
    system: [],
    messages: [Message(role: .user, content: [.text("a screen no fixture has seen")])]
  )

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "athina-replay-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  // MARK: Recording

  /// The clock a recording runs on. On real time the two calls below are
  /// often less than a millisecond apart, the precision a file name shows,
  /// but only now and then fall in the same one; a test clock that never
  /// moves reads the same instant for both, every time.
  enum RecordingClock: CaseIterable, Sendable {
    case system, standing

    func make() -> any AthinaClock {
      switch self {
      case .system: SystemClock()
      case .standing: AdjustableClock(startingAt: Date(timeIntervalSince1970: 1_789_000_000))
      }
    }
  }

  @Test(arguments: RecordingClock.allCases)
  func theRecorderWritesEveryCallAndPassesTheResultThrough(on clock: RecordingClock) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inner = ScriptedClaudeClient()
    await inner.enqueue(
      json: #"{"worth_a_look": true, "reason": "r"}"#,
      model: "claude-haiku-4-5-20251001",
      usage: Usage(inputTokens: 1000, outputTokens: 40)
    )
    await inner.enqueue(
      .failure(.api(status: 529, type: "overloaded_error", message: "Overloaded"))
    )
    let recorder = RecordingClaudeClient(
      wrapping: inner,
      directory: directory,
      prices: .defaults,
      clock: clock.make()
    )
    #expect(!recorder.isReplay)

    let request = CallFixtureTests.request(text: "key on screen: \(CallFixtureTests.realisticKey)")
    let answer = try await recorder.send(
      request,
      call: Self.identity("triage"),
      apiKey: CallFixtureTests.realisticKey,
      timeout: 30
    )
    #expect(answer.model == "claude-haiku-4-5-20251001")
    await #expect(
      throws: ClaudeClientError.api(status: 529, type: "overloaded_error", message: "Overloaded")
    ) {
      try await recorder.send(
        Self.unrelatedRequest,
        call: Self.identity("mentor"),
        apiKey: CallFixtureTests.realisticKey,
        timeout: 30
      )
    }
    // The wrapped client saw the call exactly as the loop sent it.
    #expect(await inner.sent.first?.request == request)
    #expect(await inner.sent.first?.apiKey == CallFixtureTests.realisticKey)

    let written = await recorder.written
    #expect(written.count == 2)
    let loaded = try CallFixtureFiles.load(from: directory)
    #expect(loaded.map(\.fixture.identity) == [Self.identity("triage"), Self.identity("mentor")])
    let triage = loaded[0].fixture
    #expect(triage.result == .success(answer))
    #expect(triage.model == request.model)
    #expect(triage.latency >= 0)
    let expectedCost = try #require(
      PriceTable.defaults.cost(of: Usage(inputTokens: 1000, outputTokens: 40), model: request.model)
    )
    #expect(abs(triage.cost - expectedCost) < 1e-12)
    #expect(
      loaded[1].fixture.result
        == .failure(.api(status: 529, type: "overloaded_error", message: "Overloaded"))
    )
    #expect(loaded[1].fixture.cost == 0)

    for url in written {
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(!text.contains(CallFixtureTests.realisticKey))
    }
  }

  // MARK: Replay

  @Test func callsAreMatchedByKindAndCycleInOrder() async throws {
    let client = ReplayClaudeClient(entries: [
      Self.entry("1-triage", kind: "triage", result: .success(Self.response("triage one"))),
      Self.entry(
        "2-mentor",
        kind: "mentor",
        result: .success(Self.response("mentor one", model: "claude-sonnet-5"))
      ),
      Self.entry("3-triage", kind: "triage", result: .success(Self.response("triage two"))),
      Self.entry(
        "4-mentor",
        kind: "mentor",
        result: .success(Self.response("mentor two", model: "claude-sonnet-5"))
      ),
      Self.entry(
        "5-understanding",
        kind: "understanding",
        result: .success(Self.response("a kind this build has never heard of"))
      ),
    ])
    #expect(client.isReplay)
    var answers: [String] = []
    for kind in [
      "triage", "triage", "mentor", "triage", "mentor", "mentor", "understanding", "understanding",
    ] {
      answers.append(
        try await client.send(
          Self.unrelatedRequest,
          call: Self.identity(kind),
          apiKey: "",
          timeout: 1
        ).text
      )
    }
    #expect(
      answers == [
        "triage one", "triage two", "mentor one", "triage one", "mentor two", "mentor one",
        "a kind this build has never heard of", "a kind this build has never heard of",
      ]
    )
    let served = await client.served
    #expect(
      served.map(\.fixtureName) == [
        "1-triage", "3-triage", "2-mentor", "1-triage", "4-mentor", "2-mentor", "5-understanding",
        "5-understanding",
      ]
    )
    #expect(served.first?.request == Self.unrelatedRequest)
  }

  @Test func aKindWithNoRecordingIsRefused() async throws {
    let client = ReplayClaudeClient(entries: [
      Self.entry("t", kind: "triage", result: .success(Self.response("{}")))
    ])
    await #expect(throws: ClaudeClientError.replay("no recorded test call to replay")) {
      try await client.send(
        Self.unrelatedRequest,
        call: Self.identity("test"),
        apiKey: "",
        timeout: 1
      )
    }
  }

  @Test func recordedErrorsAreReplayedAsErrors() async throws {
    let client = ReplayClaudeClient(entries: [
      Self.entry(
        "t",
        kind: "triage",
        result: .failure(.api(status: 529, type: "overloaded_error", message: "Overloaded"))
      )
    ])
    await #expect(
      throws: ClaudeClientError.api(status: 529, type: "overloaded_error", message: "Overloaded")
    ) {
      try await client.send(
        Self.unrelatedRequest,
        call: Self.identity("triage"),
        apiKey: "",
        timeout: 1
      )
    }
  }

  @Test func aStaleFixtureIsRefusedNamingItAndBothVersions() async throws {
    let entries = [
      Self.entry(
        "20260101T000000.000Z-mentor-old.json",
        kind: "mentor",
        version: MentorPrompts.version - 1,
        result: .success(Self.response("old"))
      ),
      Self.entry(
        "20260914T000000.000Z-mentor-new.json",
        kind: "mentor",
        result: .success(Self.response("new"))
      ),
    ]
    let strict = ReplayClaudeClient(entries: entries)
    let message = ReplayClaudeClient.staleMessage(
      fixture: "20260101T000000.000Z-mentor-old.json",
      recorded: MentorPrompts.version - 1,
      current: MentorPrompts.version
    )
    #expect(message.contains("20260101T000000.000Z-mentor-old.json"))
    #expect(message.contains("prompt version \(MentorPrompts.version - 1)"))
    #expect(message.contains("current prompt version is \(MentorPrompts.version)"))
    #expect(message.contains(ModelClientMode.allowStaleFlag))
    #expect(message.contains("ALLOW_STALE=1"))
    #expect(message.contains("make record"))
    await #expect(throws: ClaudeClientError.replay(message)) {
      try await strict.send(
        Self.unrelatedRequest,
        call: Self.identity("mentor"),
        apiKey: "",
        timeout: 1
      )
    }
    // The refusal takes its turn: the current fixture after it still answers.
    #expect(
      try await strict.send(
        Self.unrelatedRequest,
        call: Self.identity("mentor"),
        apiKey: "",
        timeout: 1
      ).text == "new"
    )

    let lenient = ReplayClaudeClient(entries: entries, allowStale: true)
    #expect(
      try await lenient.send(
        Self.unrelatedRequest,
        call: Self.identity("mentor"),
        apiKey: "",
        timeout: 1
      ).text == "old"
    )

    let summary = strict.summary(
      directory: URL(fileURLWithPath: "/fixtures"),
      promptVersion: MentorPrompts.version
    )
    #expect(summary.total == 2)
    #expect(summary.staleCount == 1)
    #expect(summary.staleVersions == [MentorPrompts.version - 1])
    #expect(!summary.allowStale)
  }

  /// On a test clock: an immediate replay never waits on it, a recorded one
  /// answers exactly when the clock reaches the recorded latency, and the
  /// call's timeout caps that wait.
  @Test func recordedLatencyIsWaitedOutOnlyWhenAsked() async throws {
    let entries = [
      Self.entry("t", kind: "triage", result: .success(Self.response("{}")), latency: 20)
    ]
    let clock = AdjustableClock(startingAt: Date(timeIntervalSince1970: 1_789_000_000))
    _ = try await ReplayClaudeClient(entries: entries, clock: clock)
      .send(Self.unrelatedRequest, call: Self.identity("triage"), apiKey: "", timeout: 30)
    #expect(clock.sleeperCount == 0)

    let recorded = ReplayClaudeClient(entries: entries, latency: .recorded, clock: clock)
    let answer = Task {
      try await recorded.send(
        Self.unrelatedRequest,
        call: Self.identity("triage"),
        apiKey: "",
        timeout: 30
      )
    }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(19))
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(1))
    #expect(try await answer.value.text == "{}")

    let capped = ReplayClaudeClient(entries: entries, latency: .recorded, clock: clock)
    let cut = Task {
      try await capped.send(
        Self.unrelatedRequest,
        call: Self.identity("triage"),
        apiKey: "",
        timeout: 5
      )
    }
    await clock.waitForSleepers()
    clock.advance(by: .seconds(5))
    #expect(try await cut.value.text == "{}")
  }

  @Test func aReplayThatCannotStartRefusesEveryCall() async throws {
    let client = ReplayClaudeClient.unavailable("no recorded calls in /nowhere")
    #expect(client.isReplay)
    await #expect(throws: ClaudeClientError.replay("no recorded calls in /nowhere")) {
      try await client.send(
        Self.unrelatedRequest,
        call: Self.identity("triage"),
        apiKey: "",
        timeout: 1
      )
    }
    #expect(
      client.summary(directory: URL(fileURLWithPath: "/nowhere"), promptVersion: 1)
        .unavailableReason == "no recorded calls in /nowhere"
    )
  }

  @Test func loadingReadsADirectoryAndRefusesAnEmptyOne() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(throws: ReplayLoadError.empty(directory.path)) {
      try ReplayClaudeClient.load(from: directory)
    }
    try CallFixtureFiles.write(
      CallFixtureTests.fixture(kind: "triage"),
      to: directory,
      redacting: ""
    )
    try CallFixtureFiles.write(
      CallFixtureTests.fixture(kind: "mentor", at: Date(timeIntervalSince1970: 1_789_000_100)),
      to: directory,
      redacting: ""
    )
    let client = try ReplayClaudeClient.load(from: directory, allowStale: true, latency: .recorded)
    #expect(client.entries.map(\.fixture.identity.kind) == ["triage", "mentor"])
    #expect(client.allowStale)
    #expect(client.latency == .recorded)
    let summary = client.summary(directory: directory, promptVersion: MentorPrompts.version)
    #expect(summary.kindsDescription == "1 triage, 1 mentor")
    #expect(summary.staleCount == 0)
  }

  @Test func kindsAreListedInTierOrderThenByName() {
    let summary = ReplaySummary(
      directory: URL(fileURLWithPath: "/f"),
      countsByKind: ["test": 1, "zeta": 2, "mentor": 3, "alpha": 1, "triage": 4],
      promptVersion: 1
    )
    #expect(summary.kindsDescription == "4 triage, 3 mentor, 1 test, 1 alpha, 2 zeta")
    #expect(summary.total == 11)
  }

  // MARK: Choosing a client at launch

  @Test(arguments: [
    ([String](), ModelClientMode.live),
    (["--open", "debug"], .live),
    (
      ["--replay", "/fixtures"],
      .replay(directory: URL(fileURLWithPath: "/fixtures", isDirectory: true), allowStale: false)
    ),
    (
      ["--replay", "/fixtures", "--allow-stale-fixtures"],
      .replay(directory: URL(fileURLWithPath: "/fixtures", isDirectory: true), allowStale: true)
    ),
    (
      ["--allow-stale-fixtures", "--replay", "/a/../fixtures/", "--open", "debug"],
      .replay(directory: URL(fileURLWithPath: "/fixtures", isDirectory: true), allowStale: true)
    ),
    (["--record"], .record(directory: URL(fileURLWithPath: "/default", isDirectory: true))),
    (
      ["--record", "--open", "debug"],
      .record(directory: URL(fileURLWithPath: "/default", isDirectory: true))
    ),
    (
      ["--record", "/tmp/rec"],
      .record(directory: URL(fileURLWithPath: "/tmp/rec", isDirectory: true))
    ),
    (
      ["--record", "round-2", "--open", "debug"],
      .record(directory: URL(fileURLWithPath: "/default/round-2", isDirectory: true))
    ),
    (
      ["--record", "./a/../b"],
      .record(directory: URL(fileURLWithPath: "/default/b", isDirectory: true))
    ),
    (["--replay"], .invalid("--replay needs the directory of fixtures to replay")),
    (
      ["--replay", "--open", "debug"],
      .invalid("--replay needs the directory of fixtures to replay")
    ),
    (["--record", "--replay", "/fixtures"], .invalid("--record and --replay cannot be combined")),
    (
      ["--record", "--allow-stale-fixtures"],
      .invalid("--allow-stale-fixtures applies only to --replay")
    ),
    (["--allow-stale-fixtures"], .invalid("--allow-stale-fixtures applies only to --replay")),
  ])
  func launchFlagsChooseTheMode(arguments: [String], expected: ModelClientMode) {
    let mode = ModelClientMode(
      arguments: ["Athina"] + arguments,
      defaultRecordingDirectory: URL(fileURLWithPath: "/default", isDirectory: true)
    )
    #expect(mode == expected)
  }

  @Test func aRelativeOrTildePathIsMadeAbsolute() {
    let home = ModelClientMode(arguments: ["Athina", "--replay", "~/fixtures"])
    #expect(
      home
        == .replay(
          directory: URL(fileURLWithPath: NSHomeDirectory() + "/fixtures", isDirectory: true)
            .standardizedFileURL,
          allowStale: false
        )
    )
    let recordHome = ModelClientMode(
      arguments: ["Athina", "--record", "~/rec"],
      defaultRecordingDirectory: URL(fileURLWithPath: "/default", isDirectory: true)
    )
    #expect(
      recordHome
        == .record(
          directory: URL(fileURLWithPath: NSHomeDirectory() + "/rec", isDirectory: true)
            .standardizedFileURL
        )
    )
    guard
      case .replay(let relative, _) = ModelClientMode(arguments: [
        "Athina", "--replay", "Fixtures/Replay",
      ])
    else {
      Issue.record("expected a replay")
      return
    }
    #expect(relative.path == FileManager.default.currentDirectoryPath + "/Fixtures/Replay")
  }

  @Test func eachModeGetsItsClient() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CallFixtureFiles.write(
      CallFixtureTests.fixture(kind: "triage"),
      to: directory,
      redacting: ""
    )
    let live: @Sendable () -> any ClaudeClient = { ScriptedClaudeClient() }

    let plain = ModelClientMode.live.makeClient(prices: .defaults, live: live)
    #expect(plain.client is ScriptedClaudeClient)
    #expect(plain.replay == nil)
    #expect(ModelClientMode.live.makeClient(prices: .defaults).client is AnthropicClient)
    #expect(!ModelClientMode.live.isOffline)

    let recording = ModelClientMode.record(directory: directory).makeClient(
      prices: .defaults,
      live: live
    )
    let recorder = try #require(recording.client as? RecordingClaudeClient)
    #expect(recorder.directory == directory)
    #expect(!recorder.isReplay)
    #expect(recording.recordingUnavailableReason == nil)
    #expect(!ModelClientMode.record(directory: directory).isOffline)

    let replaying = ModelClientMode.replay(directory: directory, allowStale: true).makeClient(
      prices: .defaults,
      latency: .immediate,
      live: live
    )
    let replay = try #require(replaying.client as? ReplayClaudeClient)
    #expect(replay.entries.count == 1)
    #expect(replay.allowStale)
    #expect(replay.latency == .immediate)
    #expect(replay.unavailableReason == nil)
    #expect(replaying.replay?.countsByKind == ["triage": 1])
    #expect(ModelClientMode.replay(directory: directory, allowStale: false).isOffline)
    // Unless a launch asks otherwise, a replay waits out what was recorded.
    let lifelike = ModelClientMode.replay(directory: directory, allowStale: false).makeClient(
      prices: .defaults,
      live: live
    )
    #expect((lifelike.client as? ReplayClaudeClient)?.latency == .recorded)

    let missing = directory.appendingPathComponent("missing")
    let broken = ModelClientMode.replay(directory: missing, allowStale: false).makeClient(
      prices: .defaults,
      live: live
    )
    let refusing = try #require(broken.client as? ReplayClaudeClient)
    #expect(refusing.unavailableReason?.contains("cannot read the fixture directory") == true)
    #expect(broken.replay?.unavailableReason == refusing.unavailableReason)

    let invalid = ModelClientMode.invalid("--record and --replay cannot be combined").makeClient(
      prices: .defaults,
      live: live
    )
    #expect(
      (invalid.client as? ReplayClaudeClient)?.unavailableReason
        == "--record and --replay cannot be combined"
    )
    #expect(invalid.client.isReplay)
    #expect(ModelClientMode.invalid("x").isOffline)
  }

  /// A recording that could write nothing must spend nothing: every call is
  /// refused with the reason and the live client never sees one. The
  /// refusing client is not a replay.
  @Test(arguments: ["existing", "existing/missing"])
  func aRecordingThatCannotWriteRefusesEveryCall(subpath: String) async throws {
    let parent = temporaryDirectory()
    let manager = FileManager.default
    defer {
      try? manager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: parent.appendingPathComponent("existing").path
      )
      try? manager.removeItem(at: parent)
    }
    try manager.createDirectory(
      at: parent.appendingPathComponent("existing"),
      withIntermediateDirectories: true
    )
    try manager.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: parent.appendingPathComponent("existing").path
    )
    let directory = parent.appendingPathComponent(subpath, isDirectory: true)
    let inner = ScriptedClaudeClient()
    await inner.enqueue(json: "{}")

    let setup = ModelClientMode.record(directory: directory).makeClient(
      prices: .defaults,
      live: { inner }
    )
    let reason = try #require(setup.recordingUnavailableReason)
    #expect(reason.hasPrefix("cannot record to \(directory.path): "))
    #expect(!setup.client.isReplay)
    await #expect(throws: ClaudeClientError.notSent(reason)) {
      try await setup.client.send(
        Self.unrelatedRequest,
        call: Self.identity("triage"),
        apiKey: CallFixtureTests.realisticKey,
        timeout: 1
      )
    }
    #expect(await inner.sent.isEmpty)
    #expect(
      try manager.contentsOfDirectory(atPath: parent.appendingPathComponent("existing").path)
        .isEmpty
    )
  }
}
