import ArgumentParser
import Foundation
import Testing

@testable import AthinaDrive

@Suite struct CommandLineTests {
  private func parse(_ arguments: [String]) throws -> ParsableCommand {
    try AthinaDrive.parseAsRoot(arguments)
  }

  /// The exit code a command line that does not parse would end with.
  private func exitCode(_ arguments: [String]) -> Int32 {
    do {
      _ = try parse(arguments)
      return 0
    } catch {
      return AthinaDrive.exitCode(for: error).rawValue
    }
  }

  @Test func parsesArgumentsAndOptions() throws {
    let click = try #require(
      try parse(["click", "item", "1234", "--shot", "bar.png"]) as? Click.Item
    )
    #expect(click.pid.value == 1234)
    #expect(click.shot == "bar.png")
  }

  @Test func parsesValuelessFlags() throws {
    let key = try #require(try parse(["key", "53", "--cmd"]) as? Key)
    #expect(key.keycode == 53)
    #expect(key.cmd)
    #expect(!key.shift)
  }

  /// A window on a display left of the main one has negative coordinates,
  /// which the scenarios pass as they read them.
  @Test func takesNegativeNumbersAsCoordinates() throws {
    let click = try #require(
      try parse(["click", "window", "12", "-840", "-3.5", "--shot", "a.png"]) as? Click.Window
    )
    #expect(try Words.numbers(click.words, ["x", "y"]) == [-840, -3.5])
    #expect(click.shot == "a.png")
    let region = try #require(
      try parse(["shot", "region", "-160", "0", "420", "33", "b.png"]) as? Shot.Region
    )
    #expect(try region.region() == ("-160,0,420,33", "b.png"))
  }

  /// Titles, matches and values are taken as written: empty, or starting
  /// with a dash.
  @Test func takesTextAsWritten() throws {
    let ax = try #require(
      try parse(["ax", "12", "set", "AXScrollBar", "", "-1", "--scope", "Privacy"]) as? AX
    )
    #expect(ax.action == .set)
    #expect(try ax.terms() == ["AXScrollBar", "", "-1"])
    #expect(ax.scope == "Privacy")
    let raise = try #require(try parse(["raise", "12", "-draft"]) as? Raise)
    #expect(raise.words == ["-draft"])
    let journal = try #require(try parse(["journal", "-", "queries"]) as? Journal)
    #expect(journal.db == "-")
  }

  @Test func refusesWhatItCannotRunWithExit64() {
    for arguments in [
      ["quit-mentor"],
      ["toast", "1234", "--force"],
      ["click", "item", "1234", "--shot"],
      ["toast"],
      ["toast", "1", "2"],
      ["toast", "0"],
      ["toast", "-3"],
      ["click", "at", "1"],
      ["click", "at", "1", "2", "3"],
      ["click", "at", "1", "north"],
      ["click", "at", "1", "2", "--shots", "a.png"],
      ["ax", "12", "blink"],
      ["ax", "12", "dump", "AXButton"],
      ["ax", "12", "set", "AXTextField", "Name"],
      ["raise", "12", "Settings", "--scop", "x"],
      ["close", "12"],
      ["menupick", "12", "Answer Suggestion"],
      ["tap", "pid"],
      ["shot", "region", "0", "0", "10", "b.png"],
      ["api", "ping", "timeout"],
    ] {
      #expect(exitCode(arguments) == 64, "\(arguments)")
    }
  }

  @Test func helpExitsZero() {
    #expect(exitCode(["--help"]) == 0)
    #expect(exitCode(["click", "--help"]) == 0)
  }

  @Test func everyCommandDocumentsItself() {
    for leaf in AthinaDrive.leaves {
      #expect(!leaf.configuration.abstract.isEmpty, "\(leaf) has no abstract")
      #expect(AthinaDrive.usageString(for: leaf).hasPrefix("athina-drive "), "\(leaf)")
    }
  }

  /// README "Drive helpers" lists every command with the arguments it takes,
  /// one row each, so the table cannot drift from the tool.
  @Test func readmeListsEveryCommand() throws {
    let readme = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AthinaDriveTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the repository
      .appendingPathComponent("README.md")
    let text = try String(contentsOf: readme, encoding: .utf8)
    let section =
      try #require(text.components(separatedBy: "### Drive helpers").dropFirst().first)
      .components(separatedBy: "\n### ").first ?? ""
    let documented = section.split(separator: "\n")
      .filter { $0.hasPrefix("| `") }
      .compactMap { row in
        row.split(separator: "`", maxSplits: 2).dropFirst().first.map(String.init)
      }
      .map { $0.replacingOccurrences(of: "\\|", with: "|") }
    #expect(documented == AthinaDrive.leaves.map(Self.synopsis))
  }

  /// A command's usage without the tool's name or its options, as the
  /// README's table writes it.
  static func synopsis(_ leaf: ParsableCommand.Type) -> String {
    AthinaDrive.usageString(for: leaf)
      .replacingOccurrences(of: #"^athina-drive "#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #" \[--[^\]]*\]"#, with: "", options: .regularExpression)
  }
}
