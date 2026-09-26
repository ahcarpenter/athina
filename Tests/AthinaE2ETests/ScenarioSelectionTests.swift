import Foundation
import Testing

/// Which scenarios `run` runs (`scenarios_to_run` in
/// `scripts/e2e/lib/harness.sh`): those named, or every one, kept to the tier
/// `--tier` asks for.
///
/// Each test reads a scenario directory of its own, holding stand-ins that
/// only name their tier, through the stock `/bin/bash`.
@Suite struct ScenarioSelectionTests {
  private static let library = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaE2ETests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
    .appendingPathComponent("scripts/e2e/lib/harness.sh").path

  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("athina-scenario-selection-\(UUID().uuidString)", isDirectory: true)

  private struct Chosen {
    let status: Int32
    let names: [String]
    let errors: String
  }

  /// Two API-tier stand-ins and two on the real screen, one of which names no
  /// tier, as a scenario from before the tiers does.
  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tiers = ["api-one": "api", "api-two": "api", "screen-one": "screen", "untiered": nil]
    for (name, tier) in tiers {
      let body = "SCENARIO_SUMMARY=\"\(name)\"\n" + (tier.map { "SCENARIO_TIER=\($0)\n" } ?? "")
      try body.write(
        to: directory.appendingPathComponent("\(name).sh"),
        atomically: true,
        encoding: .utf8
      )
    }
  }

  private func choose(_ tier: String, _ names: [String] = []) throws -> Chosen {
    let output = directory.appendingPathComponent("output-\(UUID().uuidString).txt")
    let errors = directory.appendingPathComponent("errors-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments =
      [
        "-c",
        """
        set -euo pipefail
        source '\(Self.library)'
        SCENARIO_DIR='\(directory.path)'
        scenarios_to_run "$@"
        """,
        "bash", tier,
      ] + names
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: errors)
    try process.run()
    process.waitUntilExit()
    let chosen = try String(contentsOf: output, encoding: .utf8)
    return Chosen(
      status: process.terminationStatus,
      names: chosen.split(separator: "\n").map(String.init),
      errors: try String(contentsOf: errors, encoding: .utf8)
    )
  }

  // MARK: Every scenario

  @Test(arguments: [[], ["all"]])
  func everyScenarioOfTheAPITier(names: [String]) throws {
    #expect(try choose("api", names).names == ["api-one", "api-two"])
  }

  /// A scenario that names no tier is on the real screen.
  @Test func everyScenarioOfTheScreenTier() throws {
    #expect(try choose("screen").names == ["screen-one", "untiered"])
  }

  @Test(arguments: [[], ["all"]])
  func everyScenarioOfBothTiers(names: [String]) throws {
    #expect(try choose("all", names).names == ["api-one", "api-two", "screen-one", "untiered"])
  }

  // MARK: Named scenarios

  @Test func namedScenariosKeepTheirOrder() throws {
    #expect(try choose("all", ["untiered", "api-two"]).names == ["untiered", "api-two"])
  }

  @Test func namedScenariosAreKeptToTheTier() throws {
    #expect(try choose("api", ["screen-one", "api-two"]).names == ["api-two"])
  }

  @Test func noneOnTheTierStops() throws {
    let chosen = try choose("api", ["screen-one"])
    #expect(chosen.status == 1)
    #expect(chosen.names.isEmpty)
    #expect(chosen.errors.contains("none of those scenarios is on the api tier"))
  }

  /// Even when the others are on the tier, so a mistyped name is never
  /// quietly dropped.
  @Test func anUnknownNameStops() throws {
    let chosen = try choose("all", ["api-one", "missing"])
    #expect(chosen.status == 1)
    #expect(chosen.names.isEmpty)
    #expect(chosen.errors.contains("no scenario named missing"))
  }
}
