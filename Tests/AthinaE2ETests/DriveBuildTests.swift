import Foundation
import Testing

/// When and how the harness rebuilds athina-drive (`sources_newer_than_build`
/// and `ensure_drive` in `scripts/e2e/lib/harness.sh`), on files of each
/// test's own with explicit modification times and a stand-in `swift`, so no
/// test waits on the clock or touches a real build.
@Suite struct DriveBuildTests {
    private static let library = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AthinaE2ETests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("scripts/e2e/lib/harness.sh").path

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("athina-drive-build-\(UUID().uuidString)", isDirectory: true)

    private var product: URL { directory.appendingPathComponent("athina-drive") }
    private var stamp: URL { directory.appendingPathComponent("athina-drive.built") }
    private var sources: URL { directory.appendingPathComponent("Sources", isDirectory: true) }
    private var source: URL { sources.appendingPathComponent("Drive.swift") }

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Makes `url` at `base` plus `seconds`, executable when it is the product.
    private func make(_ url: URL, at seconds: Double) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        var attributes: [FileAttributeKey: Any] = [.modificationDate: base.addingTimeInterval(seconds)]
        if url == product { attributes[.posixPermissions] = 0o755 }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Starts bash on `body` with the harness sourced, the product, the stamp
    /// and the sources as `$1` to `$3`, and `environment` over its own.
    private func bash(_ body: String, environment: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "set -euo pipefail\nsource '\(Self.library)'\n\(body)",
            "bash", product.path, stamp.path, sources.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Whether the harness would build athina-drive now.
    private func needsBuild() throws -> Bool {
        let process = try bash("sources_newer_than_build \"$@\"")
        process.waitUntilExit()
        #expect([0, 1].contains(process.terminationStatus))
        return process.terminationStatus == 0
    }

    @Test func aMissingProductIsBuilt() throws {
        try make(stamp, at: 10)
        try make(source, at: 0)
        #expect(try needsBuild())
    }

    @Test func aProductWithNoStampIsBuilt() throws {
        try make(product, at: 10)
        try make(source, at: 0)
        #expect(try needsBuild())
    }

    @Test func anUpToDateProductIsNotBuilt() throws {
        try make(stamp, at: 10)
        try make(product, at: 20)
        try make(source, at: 0)
        #expect(try !needsBuild())
    }

    /// SwiftPM does not relink when a touched source compiles to the same
    /// thing, so the product stays older than it; the stamp says it was built.
    @Test func aTouchOnlyEditBuildsOnce() throws {
        try make(product, at: 0)
        try make(source, at: 10)
        try make(stamp, at: 20)
        #expect(try !needsBuild())
    }

    /// A source saved after a build started may have missed it.
    @Test func aSourceSavedAfterTheBuildIsBuiltAgain() throws {
        try make(stamp, at: 10)
        try make(product, at: 30)
        try make(source, at: 40)
        #expect(try needsBuild())
    }

    /// Even when the link that ends the build comes after the save.
    @Test func aSourceSavedDuringTheBuildIsBuiltAgain() throws {
        try make(stamp, at: 10)
        try make(source, at: 20)
        try make(product, at: 30)
        #expect(try needsBuild())
    }

    /// Two runs in one checkout, such as `run` and `doctor`, can build at once.
    @Test func overlappingBuildsBothSucceed() throws {
        #expect(try ensureDrive(times: 2, status: 0) == [0, 0])
        #expect(try stamps() == [stamp.lastPathComponent])
    }

    /// A failed build brought nothing up to date, so the last stamp stands.
    @Test func aFailedBuildKeepsTheLastStamp() throws {
        try make(stamp, at: 10)
        #expect(try ensureDrive(times: 1, status: 1) == [1])
        #expect(try stamps() == [stamp.lastPathComponent])
        let modified = try FileManager.default.attributesOfItem(atPath: stamp.path)[.modificationDate]
        #expect(modified as? Date == base.addingTimeInterval(10))
    }

    /// Runs the harness's `ensure_drive` on this test's files `times` times at
    /// once, with no product so each builds, and a stand-in `swift` that exits
    /// with `status` once every build has started, so the builds always
    /// overlap. Returns each run's exit status.
    private func ensureDrive(times: Int, status: Int32) throws -> [Int32] {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let started = directory.appendingPathComponent("started", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: started, withIntermediateDirectories: true)
        let swift = bin.appendingPathComponent("swift")
        try """
            #!/bin/bash
            touch "$STARTED/$$"
            for _ in $(seq 500); do
                [ "$(ls "$STARTED" | wc -l)" -ge \(times) ] && break
                sleep 0.01
            done
            exit \(status)
            """.write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let runs = try (0..<times).map { _ in
            try bash(
                "RUN_DIR=\nROOT=\"$(dirname \"$1\")\" DRIVE=\"$1\" DRIVE_BUILT=\"$2\"\nensure_drive",
                environment: ["PATH": "\(bin.path):/usr/bin:/bin", "STARTED": started.path])
        }
        return runs.map { run in
            run.waitUntilExit()
            return run.terminationStatus
        }
    }

    /// The stamp and any temporary one a build left beside it.
    private func stamps() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(stamp.lastPathComponent) }
            .sorted()
    }
}
