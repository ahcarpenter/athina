import Foundation
import Testing

/// When the harness rebuilds athina-drive (`sources_newer_than_build` in
/// `scripts/e2e/lib/harness.sh`), on files of each test's own with explicit
/// modification times, so no test waits on the clock or touches a real build.
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

    /// Whether the harness would build athina-drive now.
    private func needsBuild() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "set -euo pipefail\nsource '\(Self.library)'\nsources_newer_than_build \"$@\"",
            "bash", product.path, stamp.path, sources.path,
        ]
        try process.run()
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
    @Test func aSourceSavedAfterTheBuildStartedIsBuiltAgain() throws {
        try make(stamp, at: 10)
        try make(product, at: 30)
        try make(source, at: 40)
        #expect(try needsBuild())
    }

    @Test func aSourceNewerThanTheStampButNotTheProductIsNotBuilt() throws {
        try make(stamp, at: 10)
        try make(source, at: 20)
        try make(product, at: 30)
        #expect(try !needsBuild())
    }
}
