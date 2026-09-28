import Foundation
import Testing

/// scripts/docs-only.sh, which CI's changes job asks about every pull request.
///
/// A pull request touching only documentation skips the build, the end-to-end
/// tier and the screenshots (docs/ci.md "Docs-only pull requests"). A wrong true lets
/// a change merge untested, so every doc something reads counts as code, and
/// anything it cannot decide runs everything.
@Suite struct DocsOnlyTests {
  private static let script = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
    .appendingPathComponent("scripts/docs-only.sh")

  private func docsOnly(_ paths: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.script.path, "-"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(paths.joined(separator: "\n").utf8))
    try input.fileHandleForWriting.close()
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @Test(arguments: [
    ["docs/ci.md"],
    ["CONTRIBUTING.md", "AGENTS.md", "SECURITY.md"],
    ["docs/design.md", "docs/images/window.png"],
  ])
  func documentationIsDocsOnly(_ paths: [String]) throws {
    #expect(try docsOnly(paths) == "true")
  }

  /// README.md, whose icon MarkAssetTests checks; the release notes, which
  /// scripts/release.sh reads; and a Markdown file beside code, such as the
  /// replay fixtures' README the test bundle copies.
  @Test(arguments: [
    ["README.md"],
    ["docs/release-notes/1.0.md"],
    ["Tests/AthinaCoreTests/Fixtures/Replay/README.md"],
    [".github/pull_request_template.md"],
  ])
  func aDocSomethingReadsIsCode(_ paths: [String]) throws {
    #expect(try docsOnly(paths) == "false")
  }

  @Test func anyCodeMakesTheWholeChangeCode() throws {
    #expect(try docsOnly(["docs/ci.md", "Sources/AthinaCore/Mentor/Prompts.swift"]) == "false")
    #expect(try docsOnly(["CONTRIBUTING.md", ".github/workflows/ci.yml"]) == "false")
  }

  @Test func noChangeRunsEverything() throws {
    #expect(try docsOnly([]) == "false")
  }
}
