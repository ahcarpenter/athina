import AthinaControlProtocol
import Foundation
import Testing

/// Which bundle may skip the API tier (`ensure_app` in
/// `scripts/e2e/lib/harness.sh`): only one ATHINA_E2E_APP names, such as a
/// release build. The harness's own bundle is the development one, so when it
/// carries no control API it is rebuilt with it, never skipped. Each test runs
/// on a checkout of its own, with a stand-in scripts/bundle.sh that lands a
/// bundle carrying the control API and the real release check.
@Suite struct ControlAPIBundleTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AthinaE2ETests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the repository
    private static let library = repository.appendingPathComponent("scripts/e2e/lib/harness.sh").path
    private static let releaseCheck = repository.appendingPathComponent("scripts/check-no-control-api.sh")

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("athina-control-bundle-\(UUID().uuidString)", isDirectory: true)

    private var app: URL { root.appendingPathComponent("build/Athina.app", isDirectory: true) }
    private var binary: URL { app.appendingPathComponent("Contents/MacOS/Athina") }
    private var stamp: URL { root.appendingPathComponent("build/Athina.app.built") }
    private var source: URL { root.appendingPathComponent("Sources/App.swift") }
    /// One line per stand-in scripts/bundle.sh run, with its arguments.
    private var builds: URL { root.appendingPathComponent("builds") }

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// A checkout whose bundle, built after its last source was saved, runs
    /// `program`, carrying the control API or not.
    private func checkout(controlAPI: Bool, program: String = "exit 0") throws {
        let fileManager = FileManager.default
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: scripts.appendingPathComponent("check-no-control-api.sh"), withDestinationURL: Self.releaseCheck)
        let bundler = scripts.appendingPathComponent("bundle.sh")
        try """
            #!/bin/bash
            echo "$*" >>'\(builds.path)'
            printf '%s' '\(ControlProtocol.name)' >'\(binary.path)'
            """.write(to: bundler, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundler.path)

        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = "#!/bin/bash\n# \(controlAPI ? ControlProtocol.name : "a release build")\n\(program)\n"
        try contents.write(to: binary, atomically: true, encoding: .utf8)
        try Data().write(to: source)
        try Data().write(to: stamp)
        for (url, seconds) in [(source, 0.0), (stamp, 10), (binary, 20)] {
            var attributes: [FileAttributeKey: Any] = [.modificationDate: base.addingTimeInterval(seconds)]
            if url == binary { attributes[.posixPermissions] = 0o755 }
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }

    /// Runs the harness's `ensure_app` on this test's checkout, with
    /// ATHINA_E2E_APP naming its bundle when `named`. Returns the exit status
    /// and the CONTROL_API it left.
    private func ensureApp(named: Bool = false) throws -> (status: Int32, controlAPI: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            set -euo pipefail
            source '\(Self.library)'
            RUN_DIR= ROOT='\(root.path)' APP='\(app.path)' APP_BINARY='\(binary.path)' APP_BUILT='\(stamp.path)'
            E2E_APP='\(root.path)/build/e2e/Athina.app' E2E_BINARY='\(root.path)/build/e2e/Athina.app/Contents/MacOS/Athina'
            # Which bundle runs is what is tested here, not the hermetic copy
            # made from it, which needs a bundle codesign takes.
            ensure_e2e_app() { :; }
            ensure_app
            printf '%s' "$CONTROL_API"
            """,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ATHINA_E2E_APP"] = named ? app.path : nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func buildCount() -> Int {
        guard let text = try? String(contentsOf: builds, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    @Test func theDevelopmentBundleWithTheAPIRunsTheAPITier() throws {
        try checkout(controlAPI: true)
        let result = try ensureApp()
        #expect(result.status == 0)
        #expect(result.controlAPI == "yes")
        #expect(buildCount() == 0)
    }

    /// As after `scripts/bundle.sh --no-control`, which lands in build/ too.
    @Test func theDevelopmentBundleWithoutTheAPIIsRebuiltWithIt() throws {
        try checkout(controlAPI: false)
        let result = try ensureApp()
        #expect(result.status == 0)
        #expect(result.controlAPI == "yes")
        #expect(buildCount() == 1)
        #expect(try !String(contentsOf: builds, encoding: .utf8).contains("--no-control"))
        #expect(try String(contentsOf: binary, encoding: .utf8).contains(ControlProtocol.name))
    }

    /// scripts/bundle.sh deletes the bundle first, so it is never rebuilt
    /// under something running from it; the run stops rather than skip.
    @Test func theDevelopmentBundleWithoutTheAPIStopsTheRunWhileItRuns() throws {
        try checkout(controlAPI: false, program: "sleep 30")
        let running = Process()
        running.executableURL = binary
        running.standardOutput = FileHandle.nullDevice
        running.standardError = FileHandle.nullDevice
        try running.run()
        defer {
            running.terminate()
            running.waitUntilExit()
        }
        let result = try ensureApp()
        #expect(result.status == 1)
        #expect(result.controlAPI.isEmpty)
        #expect(buildCount() == 0)
    }

    @Test func aNamedBundleWithoutTheAPISkipsTheAPITier() throws {
        try checkout(controlAPI: false)
        let result = try ensureApp(named: true)
        #expect(result.status == 0)
        #expect(result.controlAPI == "no")
        #expect(buildCount() == 0)
    }

    @Test func aNamedBundleWithTheAPIRunsTheAPITier() throws {
        try checkout(controlAPI: true)
        let result = try ensureApp(named: true)
        #expect(result.status == 0)
        #expect(result.controlAPI == "yes")
        #expect(buildCount() == 0)
    }
}
