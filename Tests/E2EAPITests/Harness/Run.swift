#if E2EAPI
  import AthinaControlProtocol
  import AthinaE2E
  import CryptoKit
  import Foundation
  import Security
  import Synchronization
  import Testing

  /// One scenario of the API tier, run end to end: its own evidence directory and scratch
  /// home, a hermetic replay launched there and driven through its control API, and what the run
  /// leaves behind (docs/e2e.md).
  ///
  /// Every check a scenario makes goes through `check`, which logs it, keeps it for the result
  /// line, and fails the test at the check's own line when it does not hold, so a scenario goes
  /// on after a failed check and reports every one.
  final class Run {
    let scenario: String
    let configuration: Configuration
    /// The run's evidence directory.
    let evidence: URL
    let control: Control
    let app: AppProcess
    private let logFile: LogFile
    private var checks: [String] = []
    private var failedChecks = 0

    private init(
      scenario: String,
      configuration: Configuration,
      evidence: URL,
      control: Control,
      app: AppProcess,
      logFile: LogFile
    ) {
      self.scenario = scenario
      self.configuration = configuration
      self.evidence = evidence
      self.control = control
      self.app = app
      self.logFile = logFile
    }

    // MARK: - Running a scenario

    /// How long a scenario may run, once it has started, before its app is stopped and it fails.
    static let defaultTimeLimit: Duration = .seconds(180)

    /// Runs the scenario `name` against a new hermetic replay launched with `arguments` after
    /// its own, such as `["--open", "debug"]`, then checks the run showed nothing, keeps its
    /// evidence, writes its result line and takes it all down, whatever happened.
    ///
    /// No more scenarios run at once than the harness's `--jobs` allows; the wait for a turn is
    /// not part of the time limit.
    static func scenario(
      _ name: String,
      arguments: [String] = [],
      timeLimit: Duration = defaultTimeLimit,
      _ body: (Run) async throws -> Void
    ) async {
      let configuration = Configuration.current
      guard let app = configuration.app else {
        Issue.record(
          """
          The API tier runs through scripts/e2e/athina-e2e (make test-e2e), which builds the app \
          and its hermetic copy first and names it in ATHINA_E2E_HERMETIC_APP.
          """
        )
        return
      }
      await Turns.shared.take()
      do {
        try await perform(name, app, arguments, timeLimit, configuration, body)
      } catch {
        Issue.record("\(name) left no evidence: \(error)")
      }
      await Turns.shared.give()
    }

    private static func perform(
      _ name: String,
      _ app: URL,
      _ arguments: [String],
      _ timeLimit: Duration,
      _ configuration: Configuration,
      _ body: (Run) async throws -> Void
    ) async throws {
      let started = ContinuousClock.now
      let evidence = try newEvidenceDirectory(for: name, in: configuration.evidence)
      let logFile = LogFile(evidence.appendingPathComponent("log.txt"))
      let say: (String) -> Void = { line in
        let stamped = "\(LogFile.stamp()) [\(name)] \(line)"
        FileHandle.standardError.write(Data((stamped + "\n").utf8))
        logFile.append(stamped)
      }
      // While this is here, `athina-e2e clean` leaves the run alone.
      let running = evidence.appendingPathComponent(".running")
      try "\(getpid())\n".write(to: running, atomically: true, encoding: .utf8)
      say("=== \(name) (api tier)")
      say("evidence: \(evidence.path)")
      recordProvenance(of: app, configuration, in: evidence)

      let home = evidence.appendingPathComponent("home", isDirectory: true)
      var control: ControlDirectory?
      var launched: AppProcess?
      var watch: HermeticWatch?
      var run: Run?
      var failure: String?
      do {
        try seed(home, from: configuration.settings)
        let directory = try ControlDirectory.make()
        control = directory
        say("control directory \(directory.url.path)")
        var launchArguments = arguments
        if let scale = configuration.timeScale { launchArguments += ["--time-scale", scale] }
        // Hermetic (docs/e2e.md "Hermetic runs"), which --control alone is not.
        launchArguments += ["--control", directory.url.path, "--hermetic"]
        if configuration.showWindows { launchArguments.append("--show-windows") }
        let process = try await AppProcess.launch(
          app,
          home: home,
          arguments: launchArguments,
          configuration: configuration,
          evidence: evidence
        )
        launched = process
        let watching = HermeticWatch(pid: process.pid, evidence: evidence)
        watching.start()
        watch = watching
        say("launched Athina pid=\(process.pid) (replay, \(configuration.launch.rawValue))")
        say("journal at \(process.journal.path)")
        let scenario = Run(
          scenario: name,
          configuration: configuration,
          evidence: evidence,
          control: Control(
            directory: directory.url,
            secret: directory.secret,
            transcript: LogFile(evidence.appendingPathComponent("api.log"))
          ),
          app: process,
          logFile: logFile
        )
        run = scenario
        try await scenario.waitForControl()
        try await scenario.withTimeLimit(timeLimit) { try await body(scenario) }
        await scenario.hermeticChecks(watching)
      } catch {
        failure = "the scenario could not run to the end: \(error)"
        say("ERROR: \(error)")
        Issue.record("\(name) could not run to the end: \(error)")
      }

      watch?.stop()
      if let launched { writeJournalEvidence(launched.journal, in: evidence) }
      await launched?.stop()
      control?.remove()
      if !configuration.keepHome { try? FileManager.default.removeItem(at: home) }

      let failed = run?.failedChecks ?? 0
      let result = failure == nil && failed == 0 ? "pass" : "fail"
      let detail = failure ?? (failed == 0 ? "" : "\(failed) check(s) failed")
      say("=== \(name): \(result)")
      writeResult(
        ResultLine(
          scenario: name,
          result: result,
          seconds: Int((ContinuousClock.now - started).components.seconds),
          detail: detail,
          evidence: evidence.path,
          checks: run?.checks ?? []
        ),
        configuration
      )
      try? FileManager.default.removeItem(at: running)
    }

    /// Runs `body`, stopping the run's app when it runs past `limit`: every request after that
    /// finds no app to answer it, so the scenario ends there, and fails saying why.
    private func withTimeLimit(_ limit: Duration, _ body: () async throws -> Void) async throws {
      let pid = app.pid
      let expired = Expiry()
      let watchdog = Task {
        try await Task.sleep(for: limit)
        expired.mark()
        kill(pid, SIGKILL)
      }
      defer { watchdog.cancel() }
      do {
        try await body()
      } catch {
        guard expired.isMarked else { throw error }
        throw AppProcess.Failure("it ran past its time limit of \(limit), so its app was stopped")
      }
    }

    // MARK: - Checks

    /// One check, that `actual` is `expected`.
    ///
    /// Logged either way and kept for the result line; a failure is recorded at the caller's
    /// line without stopping the scenario.
    func check<Value: Equatable>(
      _ name: String,
      _ expected: Value,
      _ actual: Value,
      sourceLocation: SourceLocation = #_sourceLocation
    ) {
      let shown = Self.shown(actual)
      if expected == actual {
        log("  ok   \(name) = \(shown)")
        checks.append("ok \(name)=\(shown)")
      } else {
        let wanted = Self.shown(expected)
        log("  FAIL \(name): expected \(wanted), got \(shown)")
        checks.append("FAIL \(name): expected=\(wanted) actual=\(shown)")
        failedChecks += 1
        Issue.record("\(name): expected \(wanted), got \(shown)", sourceLocation: sourceLocation)
      }
    }

    /// A value as a check shows it: JSON as the app sent it, and nothing where there was none.
    private static func shown(_ value: Any) -> String {
      if let value = value as? ControlValue { return value.text }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .optional {
        guard let wrapped = mirror.children.first?.value else { return "nothing" }
        return shown(wrapped)
      }
      return String(describing: value)
    }

    /// Reads `read` until it gives `want`, for up to two seconds, and returns the last read:
    /// SwiftUI redraws a control a moment after the click that changed it has been handled.
    func settled<Value: Equatable>(
      _ want: Value,
      _ read: () async throws -> Value
    ) async throws -> Value {
      var got = try await read()
      for _ in 1..<20 {
        if got == want { break }
        try await Task.sleep(for: .milliseconds(100))
        got = try await read()
      }
      return got
    }

    func log(_ line: String) {
      let stamped = "\(LogFile.stamp()) [\(scenario)] \(line)"
      FileHandle.standardError.write(Data((stamped + "\n").utf8))
      logFile.append(stamped)
    }

    // MARK: - Pictures

    /// Takes a checkpoint (docs/ci.md "Checkpoints") of the window titled `window` at step `step`.
    ///
    /// It is drawn in light and in dark, as `<scenario>/<step>-light.png` and
    /// `<step>-dark.png` under the run's checkpoints folder, which CI compares with its approved
    /// baseline in `Tests/Checkpoints`.
    /// A window that shows what changes from run to run never gives the same picture twice, so
    /// a scenario keeps its picture as plain evidence with `picture` instead.
    func checkpoint(
      _ window: String,
      _ step: String,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      let folder = (configuration.checkpoints ?? evidence.appendingPathComponent("checkpoints"))
        .appendingPathComponent(scenario, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for appearance in ["light", "dark"] {
        let file = folder.appendingPathComponent("\(step)-\(appearance).png")
        // Settled, or it would not be the same picture on the next run. A window still moving
        // from the step before, which on a loaded machine can take longer than the snapshot
        // waits for, is taken again, over its unsettled picture; one that never holds still
        // fails every time.
        var settled = false
        for attempt in 1...3 where !settled {
          try? FileManager.default.removeItem(at: file)
          let reply = try await control.snapshot(window: window, path: file, appearance: appearance)
          settled = reply["settled"]?.bool ?? false
          if !settled { log("checkpoint \(step)-\(appearance), take \(attempt), had not settled") }
        }
        check(
          "checkpoint \(scenario)/\(step)-\(appearance) of \(window) is taken, settled",
          true,
          settled,
          sourceLocation: sourceLocation
        )
      }
    }

    /// A picture of the window titled `window` kept as evidence, `<name>.png`, for a window that
    /// shows what changes from run to run or moves on its own, so is no checkpoint.
    func picture(_ window: String, _ name: String) async throws {
      let file = evidence.appendingPathComponent("\(name).png")
      if try await !control.snapshot(window: window, path: file).ok {
        log("no picture of \(window)")
      }
    }

    // MARK: - Launch and the hermetic checks

    /// Waits until the app answers on its control socket.
    ///
    /// The app says on stderr why when it will not serve one, which ends the run with that
    /// reason.
    private func waitForControl() async throws {
      for attempt in 1...100 {
        if (try? await control.ping())?.ok == true {
          log("control API answering after \(Double(attempt) / 10)s")
          return
        }
        if let refusal = app.log().split(separator: "\n").first(where: {
          $0.hasPrefix("control API refused: ") || $0.hasPrefix("control API failed: ")
        }) {
          throw AppProcess.Failure(String(refusal))
        }
        guard app.isRunning else {
          throw AppProcess.Failure("Athina exited before its control API answered; see app.log")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw AppProcess.Failure("the control API never answered; see app.log and api.log")
    }

    /// The checks every run ends with, over what the hermetic watch saw: every look was made,
    /// none found Athina, and the bar was really read.
    private func hermeticChecks(_ watch: HermeticWatch) async {
      // A look at the bar takes seconds, longer than the shortest scenarios.
      for _ in 0..<100 where watch.barTally.looks == 0 || watch.windowTally.looks == 0 {
        try? await Task.sleep(for: .milliseconds(100))
      }
      // --show-windows leaves them on screen on purpose.
      if !configuration.showWindows {
        let windows = watch.windowTally
        check("the windows were looked at during the run", true, windows.looks > 0)
        check("looks at the windows during the run that failed", 0, windows.failed)
        check(
          "looks during the run that found an Athina window above the desktop picture",
          0,
          windows.found
        )
      }
      let bar = watch.barTally
      check("the bar was looked at during the run", true, bar.looks > 0)
      check("looks during the run that found an Athina item in the menu bar", 0, bar.found)
      check("looks at the bar that saw any app's item in it", true, bar.sawAnyItem > 0)
    }

    // MARK: - Evidence

    private static func newEvidenceDirectory(for name: String, in root: URL) throws -> URL {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let now = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: Date()
      )
      let stamp = String(
        format: "%04d%02d%02d-%02d%02d%02d",
        now.year ?? 0,
        now.month ?? 0,
        now.day ?? 0,
        now.hour ?? 0,
        now.minute ?? 0,
        now.second ?? 0
      )
      let base = root.appendingPathComponent("\(name)-\(stamp)")
      // A number after it when a copy of the same scenario started in the same second.
      for number in 1...100 {
        let directory = number == 1 ? base : URL(fileURLWithPath: "\(base.path)-\(number)")
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
          return directory
        } catch {
          guard FileManager.default.fileExists(atPath: directory.path) else { throw error }
        }
      }
      throw AppProcess.Failure("no free evidence directory beside \(base.path)")
    }

    /// A fresh home with the seeded settings: the owner's own apps excluded, so a replayed
    /// callout never lands on his work, and the triage gate at its 5 second floor.
    private static func seed(_ home: URL, from settings: URL) throws {
      let support = home.appendingPathComponent("Library/Application Support/athina")
      try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: settings,
        to: support.appendingPathComponent("settings.json")
      )
    }

    /// What was run, for whoever reads the evidence later.
    private static func recordProvenance(
      of app: URL,
      _ configuration: Configuration,
      in evidence: URL
    ) {
      func git(_ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", Configuration.repository.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
      }
      let binary = app.appendingPathComponent("Contents/MacOS/Athina")
      let digest = (try? Data(contentsOf: binary)).map {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined().prefix(16)
      }
      let modified = git(["status", "--porcelain"]).split(separator: "\n").count
      let lines = [
        "commit \(git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines))",
        "worktree \(modified) file(s) modified",
        "bundle \(configuration.bundle)",
        "hermetic copy \(app.path)",
        "app \(digest.map(String.init) ?? "unknown")",
        "fixtures \(configuration.fixtures.path)",
      ]
      try? (lines.joined(separator: "\n") + "\n")
        .write(to: evidence.appendingPathComponent("build.txt"), atomically: true, encoding: .utf8)
    }

    /// The journal as the harness's named queries print it, and a copy of it, taken through
    /// `sqlite3` since it is WAL.
    private static func writeJournalEvidence(_ journal: URL, in evidence: URL) {
      let database = JournalDatabase(path: journal.path)
      for name in ["suggestions", "calls", "follow-ups", "events", "observations"] {
        guard let query = JournalQueries.named(name), let table = try? database.table(query)
        else { continue }
        try? (table + "\n").write(
          to: evidence.appendingPathComponent("journal-\(name).tsv"),
          atomically: true,
          encoding: .utf8
        )
      }
      let backup = Process()
      backup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
      backup.arguments = [
        "-readonly", journal.path,
        ".backup '\(evidence.appendingPathComponent("journal.sqlite").path)'",
      ]
      backup.standardOutput = FileHandle.nullDevice
      backup.standardError = FileHandle.nullDevice
      if (try? backup.run()) != nil { backup.waitUntilExit() }
    }

    /// One scenario's result, as the real-screen tier prints one: the harness prints it and
    /// counts it with theirs.
    struct ResultLine: Encodable {
      let scenario: String
      let result: String
      let seconds: Int
      let detail: String
      let evidence: String
      let checks: [String]
    }

    private static func writeResult(_ line: ResultLine, _ configuration: Configuration) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard let data = try? encoder.encode(line) else { return }
      let text = String(decoding: data, as: UTF8.self) + "\n"
      try? text.write(
        to: URL(fileURLWithPath: line.evidence).appendingPathComponent("result.json"),
        atomically: true,
        encoding: .utf8
      )
      if let results = configuration.results {
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try? text.write(
          to: results.appendingPathComponent("\(line.scenario)-\(UUID().uuidString).json"),
          atomically: true,
          encoding: .utf8
        )
      }
    }
  }

  /// The run's control directory, where the app makes its socket.
  ///
  /// It is 0700, inside the per-user temporary directory (itself closed to everyone else) rather
  /// than the run's home, whose path is too long for a Unix socket, and holds the run's secret.
  struct ControlDirectory {
    let url: URL
    let secret: String

    static func make() throws -> ControlDirectory {
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
      let temporary =
        length > 0
        ? String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        : NSTemporaryDirectory()
      var template = Array(
        (URL(fileURLWithPath: temporary).appendingPathComponent("athina-ctl.XXXXXX").path)
          .utf8CString
      )
      guard let made = mkdtemp(&template) else {
        throw AppProcess.Failure("could not make a control directory")
      }
      let url = URL(fileURLWithPath: String(cString: made), isDirectory: true)
      chmod(url.path, 0o700)
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw AppProcess.Failure("could not make the control secret")
      }
      let secret = bytes.map { String(format: "%02x", $0) }.joined()
      let file = url.appendingPathComponent(ControlProtocol.secretName)
      guard
        FileManager.default.createFile(
          atPath: file.path,
          contents: Data((secret + "\n").utf8),
          attributes: [.posixPermissions: 0o600]
        )
      else { throw AppProcess.Failure("could not write the control secret") }
      return ControlDirectory(url: url, secret: secret)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
  }

  /// Whether a scenario ran past its time limit, set by its watchdog.
  final class Expiry: Sendable {
    private let marked = Atomic<Bool>(false)
    func mark() { marked.store(true, ordering: .relaxed) }
    var isMarked: Bool { marked.load(ordering: .relaxed) }
  }

  /// How many scenarios run at once: the harness's `--jobs`, one unless it asks for more.
  actor Turns {
    static let shared = Turns(Configuration.current.jobs)

    private let width: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ width: Int) { self.width = width }

    func take() async {
      if running < width {
        running += 1
        return
      }
      await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to the next scenario waiting, or frees it.
    func give() {
      if waiting.isEmpty {
        running -= 1
      } else {
        waiting.removeFirst().resume()
      }
    }
  }
#endif
