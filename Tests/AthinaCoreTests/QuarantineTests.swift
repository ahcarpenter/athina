import Foundation
import Testing

/// scripts/quarantine.sh, through which `make test` and the end-to-end harness read the
/// quarantine list, `Tests/quarantine.json` (docs/testing.md "Quarantine"): the committed list
/// has to be well formed, an entry without an owner or an issue is refused, and the list names
/// its tests and scenarios as `swift test` and the harness take them.
@Suite struct QuarantineTests {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  private static let script = repository.appendingPathComponent("scripts/quarantine.sh")
  private static let committed = repository.appendingPathComponent("Tests/quarantine.json")

  private static let issue = "https://github.com/getathina/athina/issues/1"

  /// Runs the script on `list` with `arguments`, returning its status and standard output.
  private func run(_ list: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.script.path, "--list", list.path] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Runs the script on a list holding `entries`.
  private func run(entries: Any, _ arguments: String...) throws -> (status: Int32, output: String) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quarantine-\(UUID().uuidString.prefix(8)).json"
    )
    defer { try? FileManager.default.removeItem(at: file) }
    try JSONSerialization.data(withJSONObject: entries).write(to: file)
    return try run(file, arguments)
  }

  @Test func theCommittedListIsWellFormed() throws {
    #expect(try run(Self.committed, ["check"]).status == 0)
  }

  @Test func anEntryNeedsAnOwnerAnIssueAndExactlyOneName() throws {
    let good: [String: Any] = [
      "scenario": "toast-buttons", "owner": "ahcarpenter", "issue": Self.issue,
    ]
    #expect(try run(entries: [good], "check").status == 0)
    #expect(try run(entries: [good.merging(["reason": "why"]) { $1 }], "check").status == 0)
    for bad: [String: Any] in [
      good.filter { $0.key != "owner" },
      good.merging(["owner": ""]) { $1 },
      good.filter { $0.key != "issue" },
      good.merging(["issue": "#12"]) { $1 },
      good.filter { $0.key != "scenario" },
      good.merging(["test": "AthinaCoreTests.ToastCountdownTests"]) { $1 },
      good.merging(["retries": 3]) { $1 },
    ] {
      #expect(try run(entries: [good, bad], "check").status == 1, "\(bad)")
    }
    #expect(try run(entries: ["entries": [good]], "check").status == 1)
  }

  @Test func theTestsAreOnePatternAndNothingWhenNone() throws {
    #expect(try run(entries: [Any](), "tests") == (0, "\n"))
    let entries: [[String: Any]] = [
      ["test": "A.B/c", "owner": "o", "issue": Self.issue],
      ["scenario": "about-panel", "owner": "o", "issue": Self.issue],
      ["test": "D.E", "owner": "o", "issue": Self.issue],
    ]
    #expect(try run(entries: entries, "tests") == (0, "(A.B/c)|(D.E)\n"))
  }

  @Test func onlyAListedScenarioIsQuarantined() throws {
    let entries: [[String: Any]] = [
      ["scenario": "about-panel", "owner": "o", "issue": Self.issue],
      ["test": "A.B/c", "owner": "o", "issue": Self.issue],
    ]
    #expect(try run(entries: entries, "scenario", "about-panel").status == 0)
    #expect(try run(entries: entries, "scenario", "toast-buttons").status == 1)
    #expect(try run(entries: entries, "scenario", "A.B/c").status == 1)
  }
}
