import Foundation
import Testing

/// scripts/check-ruleset.sh, which CI's lint job runs to catch the rules
/// GitHub enforces on main drifting from `.github/rulesets/main.json`: it has
/// to pass on GitHub's answer for the committed ruleset, however that answer
/// orders things, and fail on any difference in what is enforced.
@Suite struct RulesetCheckTests {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  private static let script = repository.appendingPathComponent("scripts/check-ruleset.sh")
  private static let ruleset = repository.appendingPathComponent(".github/rulesets/main.json")

  /// The rules of the committed ruleset as `rules/branches/main` answers
  /// with them: each rule with where it came from, the checks and rules
  /// reversed so order cannot matter.
  private func answer() throws -> [[String: Any]] {
    let data = try Data(contentsOf: Self.ruleset)
    let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rules = try #require(file["rules"] as? [[String: Any]])
    return rules.reversed().map { rule in
      var rule = rule
      if var parameters = rule["parameters"] as? [String: Any],
        let checks = parameters["required_status_checks"] as? [[String: Any]]
      {
        parameters["required_status_checks"] = Array(checks.reversed())
        rule["parameters"] = parameters
      }
      rule["ruleset_source_type"] = "Repository"
      rule["ruleset_source"] = "ahcarpenter/athina"
      rule["ruleset_id"] = 23_971_698
      return rule
    }
  }

  private func requiredChecks(in answer: [[String: Any]]) throws -> [[String: Any]] {
    let rule = try #require(answer.first { $0["type"] as? String == "required_status_checks" })
    let parameters = try #require(rule["parameters"] as? [String: Any])
    return try #require(parameters["required_status_checks"] as? [[String: Any]])
  }

  private func withRequiredChecks(
    _ answer: [[String: Any]],
    _ change: ([[String: Any]]) -> [[String: Any]]
  ) throws -> [[String: Any]] {
    let checks = change(try requiredChecks(in: answer))
    return answer.map { rule in
      guard rule["type"] as? String == "required_status_checks",
        var parameters = rule["parameters"] as? [String: Any]
      else { return rule }
      var rule = rule
      parameters["required_status_checks"] = checks
      rule["parameters"] = parameters
      return rule
    }
  }

  private func check(_ answer: Any) throws -> Int32 {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ruleset-\(UUID().uuidString.prefix(8)).json"
    )
    defer { try? FileManager.default.removeItem(at: file) }
    try JSONSerialization.data(withJSONObject: answer).write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.script.path, file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @Test func theCommittedRulesetInAnyOrderPasses() throws {
    #expect(try check(try answer()) == 0)
  }

  @Test func aRequiredCheckGitHubDoesNotEnforceFails() throws {
    let answer = try withRequiredChecks(try answer()) { checks in
      checks.filter { $0["context"] as? String != "lint" }
    }
    #expect(try check(answer) == 1)
  }

  @Test func aRequiredCheckOnlyGitHubEnforcesFails() throws {
    let answer = try withRequiredChecks(try answer()) { checks in
      checks + [["context": "archive", "integration_id": 15368]]
    }
    #expect(try check(answer) == 1)
  }

  /// A commit status of the same name must not stand in for the check.
  @Test func aCheckFromAnotherIntegrationFails() throws {
    let answer = try withRequiredChecks(try answer()) { checks in
      checks.map { check in
        var check = check
        if check["context"] as? String == "build-and-test" { check["integration_id"] = nil }
        return check
      }
    }
    #expect(try check(answer) == 1)
  }

  @Test func aRuleGitHubDoesNotEnforceFails() throws {
    let answer = try answer().filter { $0["type"] as? String != "non_fast_forward" }
    #expect(try check(answer) == 1)
  }

  /// A ruleset switched off or set to evaluate only applies no rules at all.
  @Test func noRulesFail() throws {
    #expect(try check([Any]()) == 1)
  }

  @Test func anAnswerThatIsNotRulesCannotBeRead() throws {
    #expect(try check(["message": "Not Found"]) == 2)
  }
}
