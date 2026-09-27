import Foundation
import Testing

/// Which scenarios `run` runs (`scenarios_to_run` in
/// `scripts/e2e/lib/harness.sh`): those named, or every one, kept to the tier
/// `--tier` asks for; and what `list` says each one proves.
///
/// A real-screen scenario is a script, and an API-tier one a Swift Testing
/// test named as the scenario (Tests/E2EAPITests). Each test reads directories
/// of its own, holding stand-ins of both, through the stock `/bin/bash`.
@Suite struct ScenarioSelectionTests {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaE2ETests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  private static let library = repository.appendingPathComponent("scripts/e2e/lib/harness.sh").path

  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("athina-scenario-selection-\(UUID().uuidString)", isDirectory: true)
  private var scripts: URL { directory.appendingPathComponent("scripts", isDirectory: true) }
  private var tests: URL { directory.appendingPathComponent("tests", isDirectory: true) }

  private struct Output {
    let status: Int32
    let lines: [String]
    let errors: String
  }

  /// Two scenarios on the real screen, and two on the API tier, each shaped
  /// as the formatter leaves a scenario: in an extension, its doc comment's
  /// first paragraph running over two lines, an attribute of its own between
  /// the comment and the function, and another test in the file that is no
  /// scenario.
  init() throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: tests, withIntermediateDirectories: true)
    for name in ["screen-one", "screen-two"] {
      try "SCENARIO_SUMMARY=\"what \(name) proves\"\n".write(
        to: scripts.appendingPathComponent("\(name).sh"),
        atomically: true,
        encoding: .utf8
      )
    }
    try """
    #if E2EAPI
      extension Scenarios {
        /// What api-one proves, over
        /// two lines.
        ///
        /// How it proves it, which the summary leaves out.
        @Test func `api-one`() async {}

        /// What api-two proves.
        @available(macOS 26, *)
        @Test func `api-two`() async {
        }
      }

      /// A helper, and no scenario.
      func helper() {}
    #endif

    """.write(
      to: tests.appendingPathComponent("Stand-ins.swift"),
      atomically: true,
      encoding: .utf8
    )
  }

  /// Runs `body` with the harness sourced over the stand-ins, or over the
  /// repository's own scenarios when `ownScenarios` is set.
  private func harness(_ body: String, ownScenarios: Bool = false) throws -> Output {
    let output = directory.appendingPathComponent("output-\(UUID().uuidString).txt")
    let errors = directory.appendingPathComponent("errors-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      "-c",
      """
      set -euo pipefail
      source '\(Self.library)'
      \(ownScenarios ? "" : "SCENARIO_DIR='\(scripts.path)'; API_SCENARIO_DIR='\(tests.path)'")
      \(body)
      """,
    ]
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: errors)
    try process.run()
    process.waitUntilExit()
    return Output(
      status: process.terminationStatus,
      lines: try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(
        String.init
      ),
      errors: try String(contentsOf: errors, encoding: .utf8)
    )
  }

  private func choose(_ tier: String, _ names: [String] = []) throws -> Output {
    try harness(
      "scenarios_to_run \(([tier] + names).map { "'\($0)'" }.joined(separator: " "))"
    )
  }

  // MARK: Every scenario

  @Test(arguments: [[], ["all"]])
  func everyScenarioOfTheAPITier(names: [String]) throws {
    #expect(try choose("api", names).lines == ["api-one", "api-two"])
  }

  @Test func everyScenarioOfTheScreenTier() throws {
    #expect(try choose("screen").lines == ["screen-one", "screen-two"])
  }

  @Test(arguments: [[], ["all"]])
  func everyScenarioOfBothTiers(names: [String]) throws {
    #expect(
      try choose("all", names).lines == ["api-one", "api-two", "screen-one", "screen-two"]
    )
  }

  // MARK: Named scenarios

  @Test func namedScenariosKeepTheirOrder() throws {
    #expect(try choose("all", ["screen-two", "api-two"]).lines == ["screen-two", "api-two"])
  }

  @Test func namedScenariosAreKeptToTheTier() throws {
    #expect(try choose("api", ["screen-one", "api-two"]).lines == ["api-two"])
  }

  @Test func noneOnTheTierStops() throws {
    let chosen = try choose("api", ["screen-one"])
    #expect(chosen.status == 1)
    #expect(chosen.lines.isEmpty)
    #expect(chosen.errors.contains("none of those scenarios is on the api tier"))
  }

  /// Even when the others are on the tier, so a mistyped name is never
  /// quietly dropped.
  @Test func anUnknownNameStops() throws {
    let chosen = try choose("all", ["api-one", "missing"])
    #expect(chosen.status == 1)
    #expect(chosen.lines.isEmpty)
    #expect(chosen.errors.contains("no scenario named missing"))
  }

  // MARK: What each proves

  @Test func aScriptSaysWhatItProvesInItsSummary() throws {
    #expect(try harness("scenario_summary_of screen-two").lines == ["what screen-two proves"])
  }

  /// The first paragraph of the test's doc comment, its lines joined.
  @Test(arguments: [
    ("api-one", "What api-one proves, over two lines."),
    ("api-two", "What api-two proves."),
  ])
  func aTestSaysWhatItProvesInItsDocComment(name: String, summary: String) throws {
    #expect(try harness("scenario_summary_of \(name)").lines == [summary])
  }

  /// So `list` never shows one of them without what it proves, however the
  /// formatter lays a test out.
  @Test func everyAPITierScenarioOfTheRepositorySaysWhatItProves() throws {
    let found = try harness("api_scenarios", ownScenarios: true)
    #expect(found.status == 0)
    #expect(!found.lines.isEmpty)
    for line in found.lines {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      #expect(fields.count == 2 && !fields[0].isEmpty && fields[1].count > 20, "\(line)")
    }
  }
}
