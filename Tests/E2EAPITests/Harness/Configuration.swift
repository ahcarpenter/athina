// Built only with the E2EAPI trait on (Package.swift), which scripts/e2e/athina-e2e turns on
// for the API tier, so `make test` compiles none of this.
#if E2EAPI
  import Foundation

  /// What a run of the API tier was asked for, as `scripts/e2e/athina-e2e run` hands it over
  /// in the environment (docs/e2e.md).
  ///
  /// The harness builds the development bundle and its hermetic copy before it runs these
  /// tests, since a test run cannot build the package it is part of, so a run started any other
  /// way than through it has no copy to launch and fails, saying so.
  struct Configuration: Sendable {
    /// How the app is started: exec'd under `sandbox-exec`, or opened through LaunchServices,
    /// as CI does (docs/ci.md "Checkpoints").
    enum Launch: String, Sendable {
      case sandbox
      case open
    }

    /// The repository these tests are part of.
    static let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Harness
      .deletingLastPathComponent()  // E2EAPITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the repository

    /// The one configuration of this test run.
    static let current = Configuration(ProcessInfo.processInfo.environment)

    /// The hermetic copy of the app under its own identifier (docs/e2e.md "Hermetic runs"), or nil
    /// when the tests were not started by the harness.
    let app: URL?
    /// The bundle the copy was made from, for the run's provenance.
    let bundle: String
    /// The fixtures every call is answered from.
    let fixtures: URL
    /// The settings every run starts from, shared with the real-screen tier.
    let settings: URL
    /// The sandbox profile a run is launched under, before its paths are filled in.
    let sandboxProfile: URL
    /// Where each run's evidence directory goes.
    let evidence: URL
    /// Where checkpoints go, each scenario's in a folder named after it; each run's own
    /// evidence when nil.
    let checkpoints: URL?
    /// Where each scenario's result line goes, for the harness to print and count.
    let results: URL?
    /// How the app is started.
    let launch: Launch
    /// Whether the app's windows stay where they open rather than below the desktop picture.
    let showWindows: Bool
    /// Whether a run's scratch home is kept to look inside it.
    let keepHome: Bool
    /// How many times faster than real time the replay's clock runs, when it is scaled.
    let timeScale: String?
    /// How many scenarios run at once.
    let jobs: Int

    init(_ environment: [String: String]) {
      func path(_ key: String) -> URL? {
        environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      }
      let root = Self.repository
      app = path("ATHINA_E2E_HERMETIC_APP")
      bundle = environment["ATHINA_E2E_BUNDLE"] ?? "unknown"
      fixtures = root.appendingPathComponent("Tests/AthinaCoreTests/Fixtures/Replay")
      settings = root.appendingPathComponent("scripts/e2e/lib/settings.json")
      sandboxProfile = root.appendingPathComponent("scripts/e2e/lib/isolate.sb")
      evidence =
        path("ATHINA_E2E_OUT")
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/athina-e2e/runs")
      checkpoints = path("ATHINA_E2E_CHECKPOINTS")
      results = path("ATHINA_E2E_RESULTS")
      launch = Launch(rawValue: environment["ATHINA_E2E_LAUNCH"] ?? "") ?? .sandbox
      showWindows = environment["ATHINA_E2E_SHOW_WINDOWS"] == "1"
      keepHome = environment["ATHINA_E2E_KEEP_HOME"] == "1"
      timeScale = environment["ATHINA_E2E_TIME_SCALE"].flatMap { $0.isEmpty ? nil : $0 }
      jobs = max(1, Int(environment["ATHINA_E2E_JOBS"] ?? "") ?? 1)
    }

    /// The owner's real data, which every run is kept away from: where the app keeps it now,
    /// and the folder it kept while it was called Mentor, which stays on the owner's Mac.
    static let liveData = [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/athina"),
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mentor"),
    ]
  }
#endif
