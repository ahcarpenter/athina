import ArgumentParser
import Foundation
import SnapshotDiff

// Compares UI snapshot renders against the approved baselines, checks that two
// renders of one build agree, and approves a drift (README "UI snapshot
// baselines"). scripts/snapshots.sh is how CI and a person call it.
//
//   snapshot-diff compare <baseline> <render> [--report <dir>] [--shard <k>/<n>]
//   snapshot-diff agree <first render> <second render> [--report <dir>] [--shard <k>/<n>]
//   snapshot-diff approve <baseline> <render>
//
// --shard compares only the snapshots CI shard k of n renders (SnapshotShard).
// compare and agree exit 0 when every snapshot matches, 1 when any differs,
// and 2 when they cannot run, a command line that does not parse included.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("snapshot-diff: \(message)\n".utf8))
  exit(2)
}

struct SnapshotDiffCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "snapshot-diff",
    abstract: "Compare UI snapshot renders with the approved baselines, and approve a drift.",
    discussion: """
      compare and agree exit 0 when every snapshot matches, 1 when any differs, and 2 when \
      they cannot run.
      """,
    subcommands: [Compare.self, Agree.self, Approve.self]
  )
}

/// What compare and agree take besides their two folders.
struct ReportOptions: ParsableArguments {
  @Option(help: ArgumentHelp("Write an HTML report of the drift here.", valueName: "dir"))
  var report: String?

  @Option(
    help: ArgumentHelp(
      "Compare only the snapshots CI shard k of n renders.",
      valueName: "k/n"
    ),
    transform: { text in
      guard let shard = SnapshotShard(parsing: text) else {
        throw ValidationError("--shard takes k/\(SnapshotShard.count), not \(text)")
      }
      return shard
    }
  )
  var shard: SnapshotShard?
}

struct Compare: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Compare a render with the approved baselines."
  )

  @Argument(help: "The approved baselines.") var baseline: String
  @Argument(help: "The new render.") var render: String
  @OptionGroup var options: ReportOptions

  func run() {
    check(kind: .baselines, baseline: baseline, render: render, options: options)
  }
}

struct Agree: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check that two renders of one build are the same pictures."
  )

  @Argument(help: "The first render.") var first: String
  @Argument(help: "The second render.") var second: String
  @OptionGroup var options: ReportOptions

  func run() {
    check(kind: .renders, baseline: first, render: second, options: options)
  }
}

struct Approve: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Take a render's drift into the baselines, every shard's renders together."
  )

  @Argument(help: "The approved baselines.") var baseline: String
  @Argument(help: "The render to approve.") var render: String

  func run() {
    let (comparison, baseline, actual) = compare(
      kind: .baselines,
      baseline: baseline,
      render: render,
      shard: nil
    )
    do {
      try comparison.approve(baseline: baseline, actual: actual)
    } catch {
      fail("\(error)")
    }
    for result in comparison.drift {
      let verb =
        result.status == .removed ? "removed" : (result.status == .added ? "added" : "updated")
      print("\(verb) \(result.name): \(result.status.summary(in: comparison.kind))")
    }
    print(
      comparison.drift.isEmpty
        ? "every snapshot already matches its baseline; nothing to approve"
        : """
        approved \(comparison.drift.count) of \(comparison.results.count) snapshots into \
        \(baseline.path)
        """
    )
  }
}

/// The comparison of `render` with `baseline`, and the two folders.
func compare(
  kind: SnapshotComparison.Kind,
  baseline: String,
  render: String,
  shard: SnapshotShard?
) -> (SnapshotComparison, URL, URL) {
  let baseline = URL(fileURLWithPath: baseline, isDirectory: true)
  let actual = URL(fileURLWithPath: render, isDirectory: true)
  guard FileManager.default.fileExists(atPath: actual.path) else {
    fail("no render at \(actual.path)")
  }
  do {
    let comparison = try SnapshotComparison.compare(
      baseline: baseline,
      actual: actual,
      kind: kind,
      shard: shard
    )
    return (comparison, baseline, actual)
  } catch {
    fail("\(error)")
  }
}

/// compare and agree: prints the drift, writes the report, and exits 0 when
/// every snapshot matches and 1 when any differs.
func check(
  kind: SnapshotComparison.Kind,
  baseline: String,
  render: String,
  options: ReportOptions
) -> Never {
  let (comparison, baseline, actual) = compare(
    kind: kind,
    baseline: baseline,
    render: render,
    shard: options.shard
  )
  if let report = options.report {
    do {
      try SnapshotReport.write(
        comparison,
        baseline: baseline,
        actual: actual,
        to: URL(fileURLWithPath: report, isDirectory: true)
      )
    } catch {
      fail("\(error)")
    }
  }
  let annotate = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
  for result in comparison.drift {
    let summary = result.status.summary(in: comparison.kind)
    print("\(result.name): \(summary)")
    if annotate {
      print("::error title=\(comparison.kind.problem)::\(result.name): \(summary)")
    }
  }
  if comparison.matches {
    let deltas = comparison.results.compactMap { result -> Int? in
      if case .unchanged(let diff) = result.status { return diff.largestDelta }
      return nil
    }
    let identical = deltas.filter { $0 == 0 }.count
    let largest = deltas.max() ?? 0
    print(
      """
      all \(comparison.results.count) snapshots match (tolerance \(comparison.tolerance)): \
      \(identical) identical, largest channel difference \(largest)
      """
    )
    exit(0)
  }
  print(
    """
    \(comparison.drift.count) of \(comparison.results.count) snapshots \
    \(comparison.kind.differ) (tolerance \(comparison.tolerance))
    """
      + (options.report.map { "; report at \($0)/index.html" } ?? "")
  )
  exit(1)
}

// A command line that does not parse exits 2, not swift-argument-parser's
// 64, since 1 already means a drift; help exits 0.
do {
  var command = try SnapshotDiffCommand.parseAsRoot()
  try command.run()
} catch {
  if SnapshotDiffCommand.exitCode(for: error) == .success {
    SnapshotDiffCommand.exit(withError: error)
  }
  FileHandle.standardError.write(Data((SnapshotDiffCommand.fullMessage(for: error) + "\n").utf8))
  exit(2)
}
