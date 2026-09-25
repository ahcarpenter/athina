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
// and 2 when they cannot run.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("snapshot-diff: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func take(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { fail("\(flag) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let report = take("--report")
var shard: SnapshotShard?
if let text = take("--shard") {
    guard let parsed = SnapshotShard(parsing: text) else { fail("--shard takes k/\(SnapshotShard.count), not \(text)") }
    shard = parsed
}

guard arguments.count == 3, ["compare", "agree", "approve"].contains(arguments[0]) else {
    fail("usage: snapshot-diff compare|agree|approve <baseline or first render> <render> [--report <dir>] [--shard <k>/<n>]")
}
let command = arguments[0]
if command == "approve", shard != nil {
    fail("approve takes every shard's renders together, never one shard")
}
let baseline = URL(fileURLWithPath: arguments[1], isDirectory: true)
let actual = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard FileManager.default.fileExists(atPath: actual.path) else { fail("no render at \(actual.path)") }

let comparison: SnapshotComparison
do {
    comparison = try SnapshotComparison.compare(baseline: baseline, actual: actual, kind: command == "agree" ? .renders : .baselines, shard: shard)
} catch {
    fail("\(error)")
}

switch command {
case "approve":
    do {
        try comparison.approve(baseline: baseline, actual: actual)
    } catch {
        fail("\(error)")
    }
    for result in comparison.drift {
        let verb = result.status == .removed ? "removed" : (result.status == .added ? "added" : "updated")
        print("\(verb) \(result.name): \(result.status.summary(in: comparison.kind))")
    }
    print(comparison.drift.isEmpty
        ? "every snapshot already matches its baseline; nothing to approve"
        : "approved \(comparison.drift.count) of \(comparison.results.count) snapshots into \(baseline.path)")

default:
    if let report {
        do {
            try SnapshotReport.write(
                comparison, baseline: baseline, actual: actual,
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
        print("all \(comparison.results.count) snapshots match (tolerance \(comparison.tolerance)): \(identical) identical, largest channel difference \(largest)")
        exit(0)
    }
    print("\(comparison.drift.count) of \(comparison.results.count) snapshots \(comparison.kind.differ) (tolerance \(comparison.tolerance))"
        + (report.map { "; report at \($0)/index.html" } ?? ""))
    exit(1)
}
