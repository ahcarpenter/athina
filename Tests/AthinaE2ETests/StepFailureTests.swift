import Foundation
import Testing

/// How a scenario that stops early names where it stopped (`step` and `die`
/// in `scripts/e2e/lib/harness.sh`).
@Suite struct StepFailureTests {
  private static let library = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaE2ETests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
    .appendingPathComponent("scripts/e2e/lib/harness.sh").path

  /// Runs `body` with the harness sourced and returns its status and what it logged.
  private func run(_ body: String) throws -> (status: Int32, log: String) {
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "set -euo pipefail\nsource '\(Self.library)'\n\(body)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let log = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, log)
  }

  @Test func aStopInsideAStepNamesTheStep() throws {
    let finished = try run("step '5 empty menu bar click'; die 'the control API never answered'")
    #expect(finished.status == 1)
    #expect(
      finished.log.contains("ERROR: step 5 empty menu bar click: the control API never answered")
    )
  }

  @Test func aStopOutsideAnyStepSaysOnlyWhatWentWrong() throws {
    let finished = try run("die 'could not build athina-drive'")
    #expect(finished.status == 1)
    #expect(finished.log.contains("ERROR: could not build athina-drive"))
    #expect(!finished.log.contains("step"))
  }
}
