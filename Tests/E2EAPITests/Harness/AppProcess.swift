#if E2EAPI
  import Darwin
  import Foundation

  /// The run's Athina: launched replay only, answered at once, hermetic, in a scratch home, and
  /// stopped by the pid it reported, never by name (README "Hermetic runs").
  ///
  /// Where the run's journal is, is the app's to say: a replay makes a directory per launch
  /// and names it on the line it writes as it starts, which the harness reads rather than
  /// dictating a path (README "Replays side by side").
  final class AppProcess {
    let pid: Int32
    /// The journal of this launch.
    let journal: URL
    /// Set when the harness started the process itself, under `sandbox-exec`.
    private let process: Process?
    /// The files the app writes its output to.
    let output: [URL]

    private init(pid: Int32, journal: URL, process: Process?, output: [URL]) {
      self.pid = pid
      self.journal = journal
      self.process = process
      self.output = output
    }

    struct Failure: Error, CustomStringConvertible {
      let description: String
      init(_ description: String) { self.description = description }
    }

    /// Whether the app is still running.
    var isRunning: Bool {
      if let process { return process.isRunning }
      return kill(pid, 0) == 0
    }

    /// Everything the app has written so far.
    func log() -> String {
      output.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// Launches the hermetic copy `app` in `home` with `arguments` after the replay's own, and
    /// waits for the line that says where its journal is.
    ///
    /// Every launch replays with `--replay-latency immediate`, so no recorded latency is waited
    /// out, and draws dates, times, numbers and scroll bars in UTC and US English, as the UI
    /// snapshots do, whatever this Mac is set to, so its checkpoints read the same on every run.
    /// The `-Name value` pairs go before the scenario's own arguments: AppKit pairs each argument
    /// that starts with a dash with the one after it, so behind a flag that takes no value, such
    /// as `--hermetic`, a pair would be read out of step and the settings it names never applied.
    /// Athina has AppKit open nothing left over as a document (`LaunchArguments`), so that no
    /// longer costs the launch its windows, but the pairs still have to come first.
    static func launch(
      _ app: URL,
      home: URL,
      arguments: [String],
      configuration: Configuration,
      evidence: URL
    ) async throws -> AppProcess {
      let all =
        [
          "--replay", configuration.fixtures.path, "--replay-latency", "immediate",
          "-AppleLocale", "en_US", "-AppleLanguages", "(en-US)", "-AppleICUForce24HourTime", "NO",
          "-AppleShowScrollBars", "Always",
        ] + arguments
      switch configuration.launch {
      case .sandbox:
        return try await launchSandboxed(app, home: home, arguments: all, configuration, evidence)
      case .open:
        return try await launchOpened(app, home: home, arguments: all, evidence: evidence)
      }
    }

    /// Exec'd under `sandbox-exec`, whose profile denies the owner's real data and all outbound
    /// network, so no run can reach live data or make a live call.
    private static func launchSandboxed(
      _ app: URL,
      home: URL,
      arguments: [String],
      _ configuration: Configuration,
      _ evidence: URL
    ) async throws -> AppProcess {
      let profile = evidence.appendingPathComponent("isolate.sb")
      let template = try String(contentsOf: configuration.sandboxProfile, encoding: .utf8)
      try template
        .replacingOccurrences(of: "__LIVE_SUPPORT__", with: Configuration.liveData[0].path)
        .replacingOccurrences(of: "__LEGACY_SUPPORT__", with: Configuration.liveData[1].path)
        .write(to: profile, atomically: true, encoding: .utf8)
      let log = evidence.appendingPathComponent("app.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let handle = try FileHandle(forWritingTo: log)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments =
        ["-f", profile.path, app.appendingPathComponent("Contents/MacOS/Athina").path] + arguments
      var environment = ProcessInfo.processInfo.environment
      environment["TZ"] = "UTC"
      environment["CFFIXED_USER_HOME"] = home.path
      environment["HOME"] = home.path
      process.environment = environment
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      try? handle.close()
      let pid = process.processIdentifier
      let started = try await startedLine(in: [log], pid: pid) { process.isRunning }
      return AppProcess(pid: pid, journal: started.journal, process: process, output: [log])
    }

    /// Opened through LaunchServices (`--launch open`), for the CI runner.
    ///
    /// A process exec'd from a job step inherits the grants the runner image gives the step's
    /// shell, Accessibility among them, so the app would run trusted and the run could never
    /// catch a change that made the API tier need a grant it does not have on a Mac; opened, it
    /// is its own responsible process, as untrusted as it is on the owner's Mac. `open` gives no
    /// pid and runs the app outside the sandbox, so the pid comes from the line the app writes
    /// as it starts, and this is refused on a Mac with Athina data of its own. `open` hands the
    /// app's output to two files, and on the runner the app's stderr lines, that one among them,
    /// land in the stdout one, so both are read.
    private static func launchOpened(
      _ app: URL,
      home: URL,
      arguments: [String],
      evidence: URL
    ) async throws -> AppProcess {
      if let data = Configuration.liveData.first(where: {
        FileManager.default.fileExists(atPath: $0.path)
      }) {
        throw Failure(
          """
          --launch open runs the app outside the sandbox, so it is only for a machine with no \
          Athina data, such as a CI runner; this one has \(data.path)
          """
        )
      }
      let log = evidence.appendingPathComponent("app.log")
      let stdout = evidence.appendingPathComponent("app-stdout.log")
      let open = Process()
      open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      open.arguments =
        [
          "-n", "-g", "--env", "CFFIXED_USER_HOME=\(home.path)", "--env", "HOME=\(home.path)",
          "--env", "TZ=UTC", "--stdout", stdout.path, "--stderr", log.path, app.path, "--args",
        ] + arguments
      try open.run()
      while open.isRunning { try await Task.sleep(for: .milliseconds(100)) }
      guard open.terminationStatus == 0 else { throw Failure("open could not launch \(app.path)") }
      let started = try await startedLine(in: [log, stdout], pid: nil) { true }
      return AppProcess(
        pid: started.pid,
        journal: started.journal,
        process: nil,
        output: [log, stdout]
      )
    }

    /// Waits up to 45 seconds for `Athina started: pid <pid> in <directory>`, of `pid` when that
    /// is given, so a relaunch in the same home never reads the last one's.
    private static func startedLine(
      in files: [URL],
      pid: Int32?,
      running: () -> Bool
    ) async throws -> (pid: Int32, journal: URL) {
      let prefix = pid.map { "Athina started: pid \($0) in " } ?? "Athina started: pid "
      for _ in 0..<90 {
        let lines = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
          .flatMap { $0.split(separator: "\n") }
        if let line = lines.first(where: { $0.hasPrefix(prefix) }),
          let range = line.range(of: " in ")
        {
          let number = line.dropFirst("Athina started: pid ".count).prefix { $0.isNumber }
          if let started = Int32(number) {
            let directory = String(line[range.upperBound...])
            return (
              started, URL(fileURLWithPath: directory).appendingPathComponent("journal.sqlite")
            )
          }
        }
        guard running() else { throw Failure("Athina exited during launch; see app.log") }
        try await Task.sleep(for: .milliseconds(500))
      }
      throw Failure("Athina never said where it keeps its journal; see app.log")
    }

    /// Stops the app: asked to quit, then, after 5 seconds, killed.
    func stop() async {
      guard isRunning else { return }
      kill(pid, SIGTERM)
      for _ in 0..<20 {
        guard isRunning else { return }
        try? await Task.sleep(for: .milliseconds(250))
      }
      kill(pid, SIGKILL)
    }
  }
#endif
