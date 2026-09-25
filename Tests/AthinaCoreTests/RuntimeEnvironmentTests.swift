import Foundation
import Testing

@testable import AthinaCore

/// A directory of this test's own, which nothing else in the run touches,
/// with every symlink in its path resolved, as the gates compare paths.
private func scratch() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "athina-runtime-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url.resolvingSymlinksInPath()
}

/// A sandboxed process as the App Store build would be one, with its
/// container and its bundle under `root`.
private func sandboxed(in root: URL) -> RuntimeEnvironment {
  RuntimeEnvironment(
    isSandboxed: true,
    bundleIdentifier: "com.ahcarpenter.athina.appstore",
    bundleURL: root.appendingPathComponent("Athina.app", isDirectory: true),
    containerURL: root.appendingPathComponent(
      "Containers/com.ahcarpenter.athina.appstore/Data",
      isDirectory: true
    )
  )
}

/// The same paths, run unsandboxed, as the direct and development builds are.
private func unsandboxed(in root: URL) -> RuntimeEnvironment {
  RuntimeEnvironment(
    isSandboxed: false,
    bundleIdentifier: "com.ahcarpenter.athina",
    bundleURL: root.appendingPathComponent("Athina.app", isDirectory: true)
  )
}

/// Whether the process is sandboxed, and what that changes: the ids an App
/// Store build keeps apart under its own bundle identifier, the moves from
/// Mentor it skips, and the development flags that may name only a path it
/// can reach. Unsandboxed, every one of them is exactly what it was.
@Suite struct RuntimeEnvironmentTests {
  // MARK: This process

  /// The test runner carries no sandbox entitlement and runs from no app
  /// bundle, like `swift run`, so it resolves today's ids.
  @Test func theTestRunnerIsUnsandboxedAndGoesByTheDefaultIdentifier() {
    #expect(!RuntimeEnvironment.current.isSandboxed)
    #expect(!RuntimeEnvironment.hasEntitlement(RuntimeEnvironment.sandboxEntitlement))
    #expect(RuntimeEnvironment.current.bundleIdentifier == nil)
    #expect(RuntimeEnvironment.current.containerURL == nil)
    #expect(AppPaths.bundleIdentifier == "com.ahcarpenter.athina")
    #expect(AppPaths.preferencesDomain == "com.ahcarpenter.athina")
    #expect(AppPaths.keychainService == "com.ahcarpenter.athina")
    #expect(KeychainKeyStore.service == "com.ahcarpenter.athina")
  }

  // MARK: Identity

  /// The identifier comes from the app bundle the process runs from, so the
  /// direct build keeps `com.ahcarpenter.athina` and an App Store build its own.
  @Test(arguments: ["com.ahcarpenter.athina", "com.ahcarpenter.athina.appstore"])
  func anAppBundleNamesItsOwnIdentifier(identifier: String) throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Athina.app", isDirectory: true)
    try writeInfo(identifier: identifier, in: app)

    let environment = RuntimeEnvironment.detect(bundle: try #require(Bundle(url: app)))
    #expect(environment.bundleIdentifier == identifier)
    #expect(environment.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath())
    #expect(AppPaths.bundleIdentifier(in: environment) == identifier)
  }

  /// A bundle that is not an app, the test runner's among them, never lends
  /// its identifier to the preferences domain or the keychain service.
  @Test func aBundleThatIsNotAnAppFallsBackToTheDefault() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("Runner.xctest", isDirectory: true)
    try writeInfo(identifier: "com.apple.dt.xctest.tool", in: tool)

    let environment = RuntimeEnvironment.detect(bundle: try #require(Bundle(url: tool)))
    #expect(environment.bundleIdentifier == nil)
    #expect(environment.bundleURL == nil)
    #expect(AppPaths.bundleIdentifier(in: environment) == AppPaths.defaultBundleIdentifier)
    #expect(
      AppPaths.bundleIdentifier(in: RuntimeEnvironment(isSandboxed: true))
        == AppPaths.defaultBundleIdentifier
    )
  }

  // MARK: Moves from Mentor

  @Test func theMovesFromMentorAreSkippedOnlyWhenSandboxed() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DataMigration.skipReason(in: unsandboxed(in: root)) == nil)
    #expect(DataMigration.skipReason(in: RuntimeEnvironment(isSandboxed: false)) == nil)
    let reason = try #require(DataMigration.skipReason(in: sandboxed(in: root)))
    #expect(reason.contains("App Sandbox"))
    #expect(!reason.contains("\n"))
  }

  // MARK: Paths a flag names

  /// Sandboxed, a flag reads inside the container or the bundle and writes
  /// inside the container only; anywhere else is refused, naming the flag,
  /// the path, and where it could have been.
  @Test func aSandboxedFlagReachesOnlyItsContainerAndItsBundle() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = sandboxed(in: root)
    let container = try #require(environment.containerURL)
    let bundle = try #require(environment.bundleURL)

    let inContainer = container.appendingPathComponent("tmp/fixtures", isDirectory: true)
    #expect(environment.refusal(reading: inContainer, for: "--replay") == nil)
    #expect(environment.refusal(writing: inContainer, for: "--snapshot") == nil)
    #expect(environment.refusal(writing: container, for: "--snapshot") == nil)

    let inBundle = bundle.appendingPathComponent(
      "Contents/Resources/ReplayFixtures",
      isDirectory: true
    )
    #expect(environment.refusal(reading: inBundle, for: "--replay") == nil)
    let sealed = try #require(environment.refusal(writing: inBundle, for: "--record"))
    #expect(
      sealed
        == "--record: a sandboxed Athina can write only inside its container, not \(inBundle.path)"
    )

    let outside = root.appendingPathComponent("elsewhere/settings.json")
    let read = try #require(environment.refusal(reading: outside, for: "--settings"))
    #expect(
      read
        == "--settings: a sandboxed Athina can read only inside its container and its own bundle, not \(outside.path)"
    )
    #expect(environment.refusal(writing: outside, for: "--snapshot") != nil)
  }

  /// The path is judged as the file system resolves it, so neither `..`
  /// nor a link inside the container is a way out of it.
  @Test func aSandboxedFlagCannotSpellItsWayOut() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = sandboxed(in: root)
    let container = try #require(environment.containerURL)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: container.appendingPathComponent("Desktop"),
      withDestinationURL: outside
    )

    #expect(
      environment.refusal(
        writing: URL(fileURLWithPath: container.path + "/../../escape"),
        for: "--snapshot"
      ) != nil
    )
    #expect(
      environment.refusal(
        writing: container.appendingPathComponent("Desktop/shots"),
        for: "--snapshot"
      ) != nil
    )
    #expect(
      environment.refusal(
        reading: container.appendingPathComponent("Desktop/settings.json"),
        for: "--settings"
      ) != nil
    )
  }

  /// Unsandboxed, no path is ever refused on these grounds.
  @Test func anUnsandboxedFlagMayNameAnyPath() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for environment in [unsandboxed(in: root), RuntimeEnvironment(isSandboxed: false)] {
      for path in ["/tmp/fixtures", "/", root.appendingPathComponent("Athina.app").path] {
        #expect(environment.refusal(reading: URL(fileURLWithPath: path), for: "--replay") == nil)
        #expect(environment.refusal(writing: URL(fileURLWithPath: path), for: "--snapshot") == nil)
      }
    }
  }

  // MARK: --replay and --record

  @Test func aSandboxedReplayOutsideItsReachIsRefused() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = sandboxed(in: root)
    let outside = root.appendingPathComponent("fixtures", isDirectory: true)
    let mode = ModelClientMode(
      arguments: ["Athina", "--replay", outside.path],
      environment: environment
    )
    guard case .invalid(let reason) = mode else {
      Issue.record("expected a refusal, got \(mode)")
      return
    }
    #expect(
      reason
        == "--replay: a sandboxed Athina can read only inside its container and its own bundle, not \(outside.path)"
    )
    #expect(mode.isOffline)

    let bundled = try #require(environment.bundleURL).appendingPathComponent(
      "Contents/Resources/ReplayFixtures",
      isDirectory: true
    )
    #expect(
      ModelClientMode(arguments: ["Athina", "--replay", bundled.path], environment: environment)
        == .replay(directory: bundled.standardizedFileURL, allowStale: false)
    )
    #expect(
      ModelClientMode(
        arguments: ["Athina", "--replay", outside.path],
        environment: unsandboxed(in: root)
      )
        == .replay(directory: outside.standardizedFileURL, allowStale: false)
    )
  }

  @Test func aSandboxedRecordingOutsideItsContainerIsRefused() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = sandboxed(in: root)
    let recordings = try #require(environment.containerURL).appendingPathComponent(
      "Library/Application Support/athina/recordings",
      isDirectory: true
    )
    let outside = root.appendingPathComponent("recordings", isDirectory: true)

    let refused = ModelClientMode(
      arguments: ["Athina", "--record", outside.path],
      defaultRecordingDirectory: recordings,
      environment: environment
    )
    guard case .invalid(let reason) = refused else {
      Issue.record("expected a refusal, got \(refused)")
      return
    }
    #expect(
      reason
        == "--record: a sandboxed Athina can write only inside its container, not \(outside.path)"
    )

    // The default, and a name taken inside it, are in the container.
    #expect(
      ModelClientMode(
        arguments: ["Athina", "--record"],
        defaultRecordingDirectory: recordings,
        environment: environment
      ) == .record(directory: recordings)
    )
    #expect(
      ModelClientMode(
        arguments: ["Athina", "--record", "today"],
        defaultRecordingDirectory: recordings,
        environment: environment
      )
        == .record(
          directory: recordings.appendingPathComponent("today", isDirectory: true)
            .standardizedFileURL
        )
    )
    #expect(
      ModelClientMode(
        arguments: ["Athina", "--record", outside.path],
        defaultRecordingDirectory: recordings,
        environment: unsandboxed(in: root)
      )
        == .record(directory: outside.standardizedFileURL)
    )
  }

  // MARK: --settings

  /// A settings file the sandbox cannot read stops the replay rather than
  /// letting it run on settings nobody named, whether or not it is there.
  @Test func aSandboxedSettingsFileOutsideItsReachStopsTheLaunch() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = sandboxed(in: root)
    let container = try #require(environment.containerURL)
    let support = container.appendingPathComponent(
      "Library/Application Support/athina",
      isDirectory: true
    )
    let replay = ModelClientMode.replay(
      directory: container.appendingPathComponent("fixtures"),
      allowStale: false
    )
    let outside = root.appendingPathComponent("settings.json")
    try SettingsStore(url: outside).save(SensingSettings())

    var files = LaunchFiles(
      arguments: ["Athina", "--replay", "x", "--settings", outside.path],
      clientMode: replay,
      supportDirectory: support,
      launchName: "launch-1-0000abcd",
      environment: environment
    )
    #expect(!files.settingsGiven)
    #expect(files.settingsSource == SettingsStore.defaultURL(in: support))
    let reason =
      "--settings: a sandboxed Athina can read only inside its container and its own bundle, not \(outside.path)"
    #expect(files.refusals == [reason])
    _ = files.loadSettings(supportDirectory: support)
    guard
      case .refusedToStart(let refusal) = files.claim(clientMode: replay, supportDirectory: support)
    else {
      Issue.record("expected the launch to stop")
      return
    }
    #expect(refusal == reason)
    #expect(!FileManager.default.fileExists(atPath: files.dataDirectory.path))
  }

  @Test func aSettingsFileItCanReachIsUsed() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let sandbox = sandboxed(in: root)
    let replay = ModelClientMode.replay(
      directory: root.appendingPathComponent("fixtures"),
      allowStale: false
    )
    let inContainer = try #require(sandbox.containerURL).appendingPathComponent("tmp/settings.json")
    let outside = root.appendingPathComponent("settings.json")
    for (environment, source) in [(sandbox, inContainer), (unsandboxed(in: root), outside)] {
      let files = LaunchFiles(
        arguments: ["Athina", "--replay", "x", "--settings", source.path],
        clientMode: replay,
        supportDirectory: root.appendingPathComponent("support"),
        launchName: "launch-1-0000abcd",
        environment: environment
      )
      #expect(files.settingsGiven)
      #expect(files.settingsSource.path == source.path)
      #expect(files.refusals.isEmpty)
    }
  }

  // MARK: The clock remote

  /// A sandboxed replay answers a clock request only inside its container,
  /// and says why when the request named somewhere else, without moving the
  /// clock for a request it cannot answer.
  @Test func aSandboxedReplayAnswersTheClockOnlyInsideItsContainer() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = sandboxed(in: root)
    let container = try #require(environment.containerURL)
    let temporary = container.appendingPathComponent("tmp", isDirectory: true)
    let support = container.appendingPathComponent(
      "Library/Application Support/athina",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let reply = ClockRemote.Reply(
      moved: true,
      movedAhead: 900,
      now: Date(timeIntervalSince1970: 1_789_473_600),
      pid: 11
    )

    // The shell's temporary directory, outside the container.
    let shells = root.appendingPathComponent("T", isDirectory: true)
    try FileManager.default.createDirectory(at: shells, withIntermediateDirectories: true)
    let outside = shells.appendingPathComponent("athina-clock-abcd1234")
    #expect(
      throws: ClockRemote.Refusal(
        reason:
          "the clock request: a sandboxed Athina can write only inside its container, not \(outside.path)"
      )
    ) {
      try ClockRemote.answer(
        .success(900),
        at: outside,
        temporaryDirectory: shells,
        supportDirectory: support,
        environment: environment
      ) { _ in
        Issue.record("moved the clock for a request it cannot answer")
        return reply
      }
    }
    #expect(!FileManager.default.fileExists(atPath: outside.path))

    // Unsandboxed, the same request is answered there, as it always was.
    try ClockRemote.answer(
      .success(900),
      at: outside,
      temporaryDirectory: shells,
      supportDirectory: support,
      environment: unsandboxed(in: root)
    ) { _ in reply }
    #expect(try ClockRemote.Reply.decode(Data(contentsOf: outside)) == reply)

    // Inside the container's own temporary directory it is answered.
    let inside = temporary.appendingPathComponent("athina-clock-efgh5678")
    try ClockRemote.answer(
      .success(900),
      at: inside,
      temporaryDirectory: temporary,
      supportDirectory: support,
      environment: environment
    ) { _ in reply }
    #expect(try ClockRemote.Reply.decode(Data(contentsOf: inside)) == reply)
  }

  private func writeInfo(identifier: String, in bundle: URL) throws {
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
  }
}
