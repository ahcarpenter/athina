import Foundation
import Testing

/// When the harness rebuilds the app (`sources_newer_than_build` in
/// `scripts/e2e/lib/harness.sh`, and the stamp `scripts/bundle.sh` writes), on
/// files of each test's own with explicit modification times and a stand-in
/// `swift`, so no test waits on the clock or touches a real build.
@Suite struct BuildStampTests {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaE2ETests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  private static let library = repository.appendingPathComponent("scripts/e2e/lib/harness.sh").path
  private static let bundler = repository.appendingPathComponent("scripts/bundle.sh").path

  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("athina-build-stamp-\(UUID().uuidString)", isDirectory: true)

  private var sources: URL { directory.appendingPathComponent("Sources", isDirectory: true) }
  private var source: URL { sources.appendingPathComponent("Athina.swift") }

  /// What the stand-in `swift` builds for scripts/bundle.sh, and where the bundle lands.
  private var binary: URL { directory.appendingPathComponent("bin-path/Athina") }
  private var out: URL { directory.appendingPathComponent("out", isDirectory: true) }
  private var app: URL { out.appendingPathComponent("Athina.app/Contents/MacOS/Athina") }
  private var appStamp: URL { out.appendingPathComponent("Athina.app.built") }

  private let base = Date(timeIntervalSince1970: 1_790_000_000)

  /// Makes `url` at `base` plus `seconds`, executable when it is a product.
  private func make(_ url: URL, at seconds: Double) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data())
    var attributes: [FileAttributeKey: Any] = [.modificationDate: base.addingTimeInterval(seconds)]
    if [app, binary].contains(url) { attributes[.posixPermissions] = 0o755 }
    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
  }

  /// Starts bash on `arguments`, with `environment` over its own.
  private func bash(_ arguments: [String], environment: [String: String] = [:]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  /// Starts bash on `body` with the harness sourced and `arguments` as `$@`.
  private func harness(_ body: String, _ arguments: [String]) throws -> Process {
    try bash(["-c", "set -euo pipefail\nsource '\(Self.library)'\n\(body)", "bash"] + arguments)
  }

  /// Puts a stand-in `swift` running `script` first on a path, and returns that path.
  private func standIn(_ script: String) throws -> String {
    let bin = directory.appendingPathComponent("stand-in", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let swift = bin.appendingPathComponent("swift")
    try "#!/bin/bash\n\(script)\n".write(to: swift, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
    return "\(bin.path):/usr/bin:/bin"
  }

  /// Whether the harness would build `product`, last built as `stamp` says, now.
  private func needsBuild(_ product: URL, _ stamp: URL) throws -> Bool {
    let process = try harness(
      "sources_newer_than_build \"$@\"",
      [product.path, stamp.path, sources.path]
    )
    process.waitUntilExit()
    #expect([0, 1].contains(process.terminationStatus))
    return process.terminationStatus == 0
  }

  @Test func aMissingAppIsBuilt() throws {
    try make(appStamp, at: 10)
    try make(source, at: 0)
    #expect(try needsBuild(app, appStamp))
  }

  @Test func anAppWithNoStampIsBuilt() throws {
    try make(app, at: 10)
    try make(source, at: 0)
    #expect(try needsBuild(app, appStamp))
  }

  @Test func anUpToDateAppIsNotBuilt() throws {
    try make(appStamp, at: 10)
    try make(app, at: 20)
    try make(source, at: 0)
    #expect(try !needsBuild(app, appStamp))
  }

  /// SwiftPM does not relink when a touched source compiles to the same
  /// thing, so the binary stays older than it; the stamp says it was built.
  @Test func aTouchOnlyEditBuildsOnce() throws {
    try make(app, at: 0)
    try make(source, at: 10)
    try make(appStamp, at: 20)
    #expect(try !needsBuild(app, appStamp))
  }

  /// A source saved after a build started may have missed it.
  @Test func aSourceSavedAfterTheBuildIsBuiltAgain() throws {
    try make(appStamp, at: 10)
    try make(app, at: 30)
    try make(source, at: 40)
    #expect(try needsBuild(app, appStamp))
  }

  /// Even when the bundle that ends the build lands after the save.
  @Test func aSourceSavedDuringTheBuildIsBuiltAgain() throws {
    try make(appStamp, at: 10)
    try make(source, at: 20)
    try make(app, at: 30)
    #expect(try needsBuild(app, appStamp))
  }

  /// scripts/bundle.sh stamps the app when its build starts, so a source
  /// saved during it is built again, though the bundle lands after the save.
  @Test func aSourceSavedDuringTheAppBuildIsBuiltAgain() throws {
    try make(source, at: 0)
    #expect(try bundle(status: 0, saving: source) == 0)
    #expect(try stamps(beside: appStamp) == [appStamp.lastPathComponent])
    #expect(try needsBuild(app, appStamp))
  }

  /// Any build of the bundle counts, `make build` as much as the harness's own.
  @Test func anAppBuiltAfterTheLastSaveIsNotBuiltAgain() throws {
    try make(source, at: 0)
    #expect(try bundle(status: 0) == 0)
    #expect(try !needsBuild(app, appStamp))
  }

  @Test func aFailedAppBuildKeepsTheLastStamp() throws {
    try make(appStamp, at: 10)
    #expect(try bundle(status: 1) == 1)
    #expect(try stamps(beside: appStamp) == [appStamp.lastPathComponent])
    #expect(try modified(appStamp) == base.addingTimeInterval(10))
  }

  /// Runs scripts/bundle.sh, unsigned, into this test's directory, with a
  /// stand-in `swift` whose build saves `saving` when given and exits with
  /// `status`.
  ///
  /// Returns bundle.sh's exit status.
  private func bundle(status: Int32, saving: URL? = nil) throws -> Int32 {
    try make(binary, at: 0)
    let path = try standIn(
      """
      case " $* " in
      *" --show-bin-path "*) echo '\(binary.deletingLastPathComponent().path)' ;;
      *) \(saving.map { "touch '\($0.path)'; " } ?? "")exit \(status) ;;
      esac
      """
    )
    let process = try bash(
      [Self.bundler, "release", "--out", out.path, "--no-sign"],
      environment: ["PATH": path]
    )
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// The stamp and any temporary one a build left beside it.
  private func stamps(beside stamp: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: stamp.deletingLastPathComponent().path)
      .filter { $0.hasPrefix(stamp.lastPathComponent) }
      .sorted()
  }

  private func modified(_ url: URL) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }
}
