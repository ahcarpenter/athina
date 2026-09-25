import Foundation
import Testing

@testable import AthinaE2E

@Suite struct DriveArgumentsTests {
  @Test func parsesPositionalsAndOptions() throws {
    let invocation = try DriveArguments.parse(["click", "item", "1234", "--shot", "bar.png"])
    #expect(invocation.command == "click")
    #expect(invocation.positionals == ["item", "1234"])
    #expect(invocation.option("--shot") == "bar.png")
    #expect(try invocation.pid(1) == 1234)
  }

  @Test func parsesValuelessFlags() throws {
    let invocation = try DriveArguments.parse(["key", "53", "--cmd"])
    #expect(invocation.flag("--cmd"))
    #expect(!invocation.flag("--shift"))
    #expect(try invocation.number(0) == 53)
  }

  @Test func rejectsUnknownCommand() {
    #expect(throws: DriveUsageError.self) {
      try DriveArguments.parse(["quit-mentor"])
    }
  }

  @Test func rejectsUnknownOption() {
    #expect(throws: DriveUsageError.self) {
      try DriveArguments.parse(["toast", "1234", "--force"])
    }
  }

  @Test func rejectsOptionWithNoValue() {
    #expect(throws: DriveUsageError.self) {
      try DriveArguments.parse(["click", "item", "1234", "--shot"])
    }
  }

  @Test func rejectsWrongNumberOfArguments() {
    #expect(throws: DriveUsageError.self) { try DriveArguments.parse(["toast"]) }
    #expect(throws: DriveUsageError.self) { try DriveArguments.parse(["toast", "1", "2"]) }
  }

  @Test func rejectsArgumentsThatAreNotPids() throws {
    let invocation = try DriveArguments.parse(["toast", "0"])
    #expect(throws: DriveUsageError.self) { try invocation.pid(0) }
    let negative = try DriveArguments.parse(["toast", "-3"])
    #expect(throws: DriveUsageError.self) { try negative.pid(0) }
  }

  @Test func helpIsAUsageError() {
    #expect(throws: DriveUsageError.self) { try DriveArguments.parse(["--help"]) }
    #expect(throws: DriveUsageError.self) { try DriveArguments.parse([]) }
  }

  @Test func everyCommandDocumentsItself() {
    for command in DriveArguments.commands {
      #expect(!command.summary.isEmpty, "\(command.name) has no summary")
      #expect(command.minimum <= command.maximum, "\(command.name) has an impossible arity")
      #expect(DriveArguments.usage(for: command).contains(command.name))
    }
    #expect(Set(DriveArguments.commands.map(\.name)).count == DriveArguments.commands.count)
  }

  /// README "Drive helpers" lists every command with the argument shape the
  /// parser accepts, one row each, so the table cannot drift from the tool.
  @Test func readmeListsEveryCommand() throws {
    let readme = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AthinaE2ETests
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
    let accepted = DriveArguments.commands.map {
      [$0.name, $0.arguments].filter { !$0.isEmpty }.joined(separator: " ")
    }
    #expect(documented == accepted)
  }
}
