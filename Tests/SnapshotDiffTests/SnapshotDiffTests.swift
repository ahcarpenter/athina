import Foundation
import Testing

@testable import SnapshotDiff

@Suite struct PixelDiffTests {
  private let white = Bitmap(width: 4, height: 3, fill: (255, 255, 255, 255))

  @Test func identicalBitmapsMatch() {
    let diff = PixelDiff.compare(white, white, tolerance: 0)
    #expect(diff.matches)
    #expect(diff.largestDelta == 0)
    #expect(diff.changedBounds == nil)
  }

  @Test func aDifferenceWithinTheToleranceIsAntiAliasingNotChange() {
    var after = white
    after[1, 1] = (253, 255, 255, 255)
    let diff = PixelDiff.compare(white, after, tolerance: 2)
    #expect(diff.matches)
    #expect(diff.largestDelta == 2)
  }

  @Test func onePixelBeyondTheToleranceIsAChange() {
    var after = white
    after[3, 2] = (252, 255, 255, 255)
    let diff = PixelDiff.compare(white, after, tolerance: 2)
    #expect(diff.changedPixels == 1)
    #expect(diff.largestDelta == 3)
    #expect(diff.changedBounds == PixelRect(x: 3, y: 2, width: 1, height: 1))
  }

  @Test func theBoundsHoldEveryChangedPixel() {
    var after = white
    after[0, 1] = (0, 0, 0, 255)
    after[2, 2] = (0, 0, 0, 255)
    let diff = PixelDiff.compare(white, after, tolerance: 2)
    #expect(diff.changedPixels == 2)
    #expect(diff.changedBounds == PixelRect(x: 0, y: 1, width: 3, height: 2))
  }

  @Test func theDefaultToleranceTakesGlassNoiseButNotAMovedEdge() {
    let tolerance = SnapshotComparison.defaultTolerance
    // The runner draws a dark switch's glass knob up to 5 of 255 apart.
    var glass = white
    glass[2, 1] = (250, 250, 250, 255)
    #expect(PixelDiff.compare(white, glass, tolerance: tolerance).matches)
    // An edge one pixel over swaps a dark pixel for a light one.
    var moved = white
    moved[2, 1] = (40, 40, 40, 255)
    #expect(!PixelDiff.compare(white, moved, tolerance: tolerance).matches)
  }

  @Test func anAlphaChangeCounts() {
    var after = white
    after[0, 0] = (255, 255, 255, 200)
    #expect(!PixelDiff.compare(white, after, tolerance: 2).matches)
  }

  @Test func theHighlightPaintsChangedPixelsRedAndFadesTheRest() {
    let black = Bitmap(width: 2, height: 1, fill: (0, 0, 0, 255))
    var after = black
    after[1, 0] = (255, 255, 255, 255)
    let highlight = PixelDiff.highlight(black, after, tolerance: 2)
    #expect(highlight[1, 0] == (255, 0, 0, 255))
    // Black faded to a quarter of its contrast over white.
    let pale = highlight[0, 0]
    #expect(pale.0 == 192 && pale.1 == 192 && pale.2 == 192 && pale.3 == 255)
  }
}

@Suite struct SnapshotComparisonTests {
  private let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "snapshot-diff-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func directory(_ name: String, _ images: [String: Bitmap]) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (file, bitmap) in images {
      try bitmap.writePNG(to: url.appendingPathComponent(file))
    }
    return url
  }

  private static let grey = Bitmap(width: 3, height: 2, fill: (128, 128, 128, 255))
  private static let darker = Bitmap(width: 3, height: 2, fill: (100, 128, 128, 255))
  private static let wide = Bitmap(width: 4, height: 2, fill: (128, 128, 128, 255))
  private static let nearlyGrey = Bitmap(width: 3, height: 2, fill: (129, 128, 128, 255))

  @Test func aPNGSurvivesTheRoundTrip() throws {
    let url = root.appendingPathComponent("round-trip.png")
    try Self.darker.writePNG(to: url)
    #expect(try Bitmap(contentsOf: url) == Self.darker)
  }

  @Test func everySnapshotIsSortedIntoWhatBecameOfIt() throws {
    let baseline = try directory(
      "baseline",
      [
        "same-light.png": Self.grey,
        "tolerated-light.png": Self.grey,
        "changed-light.png": Self.grey,
        "resized-light.png": Self.grey,
        "removed-light.png": Self.grey,
      ]
    )
    let actual = try directory(
      "actual",
      [
        "same-light.png": Self.grey,
        "tolerated-light.png": Self.nearlyGrey,
        "changed-light.png": Self.darker,
        "resized-light.png": Self.wide,
        "added-light.png": Self.grey,
      ]
    )
    let comparison = try SnapshotComparison.compare(
      baseline: baseline,
      actual: actual,
      tolerance: 2
    )
    let statuses = Dictionary(uniqueKeysWithValues: comparison.results.map { ($0.name, $0.status) })

    #expect(
      statuses["same-light"]
        == .unchanged(PixelDiff(changedPixels: 0, largestDelta: 0, changedBounds: nil))
    )
    #expect(
      statuses["tolerated-light"]
        == .unchanged(PixelDiff(changedPixels: 0, largestDelta: 1, changedBounds: nil))
    )
    #expect(
      statuses["changed-light"]
        == .changed(
          PixelDiff(
            changedPixels: 6,
            largestDelta: 28,
            changedBounds: PixelRect(x: 0, y: 0, width: 3, height: 2)
          )
        )
    )
    #expect(
      statuses["resized-light"]
        == .resized(from: PixelSize(width: 3, height: 2), to: PixelSize(width: 4, height: 2))
    )
    #expect(statuses["added-light"] == .added)
    #expect(statuses["removed-light"] == .removed)
    #expect(
      comparison.drift.map(\.name) == [
        "added-light", "changed-light", "removed-light", "resized-light",
      ]
    )
    #expect(!comparison.matches)
  }

  @Test func aMissingBaselineDirectoryMakesEverySnapshotNew() throws {
    let actual = try directory("actual", ["toast-light.png": Self.grey])
    let comparison = try SnapshotComparison.compare(
      baseline: root.appendingPathComponent("none"),
      actual: actual
    )
    #expect(comparison.results == [SnapshotResult(file: "toast-light.png", status: .added)])
  }

  @Test func approvingTakesTheDriftAndLeavesTheRest() throws {
    let baseline = try directory(
      "baseline",
      [
        "tolerated-light.png": Self.grey,
        "changed-light.png": Self.grey,
        "removed-light.png": Self.grey,
      ]
    )
    let actual = try directory(
      "actual",
      [
        "tolerated-light.png": Self.nearlyGrey,
        "changed-light.png": Self.darker,
        "added-light.png": Self.wide,
      ]
    )
    let tolerated = baseline.appendingPathComponent("tolerated-light.png")
    let before = try Data(contentsOf: tolerated)

    try SnapshotComparison.compare(baseline: baseline, actual: actual).approve(
      baseline: baseline,
      actual: actual
    )

    #expect(
      try SnapshotComparison.pngs(in: baseline) == [
        "added-light.png", "changed-light.png", "tolerated-light.png",
      ]
    )
    #expect(
      try Bitmap(contentsOf: baseline.appendingPathComponent("changed-light.png")) == Self.darker
    )
    #expect(try Bitmap(contentsOf: baseline.appendingPathComponent("added-light.png")) == Self.wide)
    // Within the tolerance, so its file is not touched.
    #expect(try Data(contentsOf: tolerated) == before)
    #expect(try SnapshotComparison.compare(baseline: baseline, actual: actual).matches)
  }

  @Test func theReportHoldsBeforeAfterAndDifferenceForEachDrift() throws {
    let baseline = try directory(
      "baseline",
      ["changed-light.png": Self.grey, "removed-light.png": Self.grey]
    )
    let actual = try directory(
      "actual",
      ["changed-light.png": Self.darker, "added-light.png": Self.grey]
    )
    let comparison = try SnapshotComparison.compare(baseline: baseline, actual: actual)
    let report = root.appendingPathComponent("report", isDirectory: true)
    try SnapshotReport.write(comparison, baseline: baseline, actual: actual, to: report)

    func exists(_ path: String) -> Bool {
      FileManager.default.fileExists(atPath: report.appendingPathComponent(path).path)
    }
    #expect(
      exists("changed-light/before.png") && exists("changed-light/after.png")
        && exists("changed-light/diff.png")
    )
    #expect(
      exists("added-light/after.png") && !exists("added-light/before.png")
        && !exists("added-light/diff.png")
    )
    #expect(exists("removed-light/before.png") && !exists("removed-light/after.png"))
    let html = try String(contentsOf: report.appendingPathComponent("index.html"), encoding: .utf8)
    #expect(html.contains("<h1>UI snapshots against the approved baselines</h1>"))
    #expect(html.contains("Before (approved)") && html.contains("After (this render)"))
    #expect(html.contains("changed-light/diff.png"))
    let markdown = try String(
      contentsOf: report.appendingPathComponent("summary.md"),
      encoding: .utf8
    )
    #expect(markdown.contains("3 of 3 snapshots drifted"))
    #expect(markdown.contains("| `removed-light` | no longer rendered, baseline still committed |"))
  }

  @Test func twoRendersThatDifferAreReportedAsRendersNotAsBaselines() throws {
    let first = try directory(
      "first",
      ["changed-light.png": Self.grey, "first-only-light.png": Self.grey]
    )
    let second = try directory(
      "second",
      ["changed-light.png": Self.darker, "second-only-light.png": Self.grey]
    )
    let comparison = try SnapshotComparison.compare(baseline: first, actual: second, kind: .renders)
    let report = root.appendingPathComponent("determinism", isDirectory: true)
    try SnapshotReport.write(comparison, baseline: first, actual: second, to: report)

    let html = try String(contentsOf: report.appendingPathComponent("index.html"), encoding: .utf8)
    let markdown = try String(
      contentsOf: report.appendingPathComponent("summary.md"),
      encoding: .utf8
    )
    #expect(html.contains("<h1>Two renders of one build</h1>"))
    #expect(html.contains("First render") && html.contains("Second render"))
    #expect(markdown.contains("3 of 3 snapshots differ between the two renders"))
    #expect(markdown.contains("| `first-only-light` | only in the first render |"))
    #expect(markdown.contains("| `second-only-light` | only in the second render |"))
    for text in [html, markdown] {
      #expect(!text.contains("approved") && !text.contains("baseline"))
    }
  }

  @Test func aShardComparesOnlyItsOwnSnapshotsAndTheUnassigned() throws {
    // toast is shard 1's, callout shard 2's, and gone has no shard, so it
    // falls to the first: a removed snapshot's baseline is still reported.
    let baseline = try directory(
      "baseline",
      [
        "toast-light.png": Self.grey, "callout-light.png": Self.grey, "gone-dark.png": Self.grey,
      ]
    )
    let actual = try directory(
      "actual",
      ["toast-light.png": Self.grey, "callout-light.png": Self.darker]
    )
    let first = try SnapshotComparison.compare(
      baseline: baseline,
      actual: actual,
      shard: SnapshotShard(index: 1)
    )
    #expect(first.results.map(\.name) == ["gone-dark", "toast-light"])
    #expect(first.drift.map(\.status) == [.removed])
    let second = try SnapshotComparison.compare(
      baseline: baseline,
      actual: actual,
      shard: SnapshotShard(index: 2)
    )
    #expect(second.results.map(\.name) == ["callout-light"])
    #expect(!second.matches)
    let third = try SnapshotComparison.compare(
      baseline: baseline,
      actual: actual,
      shard: SnapshotShard(index: 3)
    )
    #expect(third.results.isEmpty)
  }

  @Test func aMatchingSetSaysSo() throws {
    let baseline = try directory("baseline", ["toast-dark.png": Self.grey])
    let comparison = try SnapshotComparison.compare(baseline: baseline, actual: baseline)
    #expect(comparison.matches)
    #expect(SnapshotReport.markdown(comparison).contains("All 1 snapshots match their baselines"))
    let renders = try SnapshotComparison.compare(
      baseline: baseline,
      actual: baseline,
      kind: .renders
    )
    #expect(
      SnapshotReport.markdown(renders).contains(
        "All 1 snapshots are the same picture in both renders"
      )
    )
  }
}

@Suite struct SnapshotShardTests {
  /// The approved baselines, one per snapshot and appearance.
  private static let baselines = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Snapshots",
      isDirectory: true
    )

  @Test func theTableNamesExactlyTheSnapshotsThatHaveBaselines() throws {
    let files = try SnapshotComparison.pngs(in: Self.baselines)
    #expect(!files.isEmpty)
    let names = Set(files.map(SnapshotShard.snapshotName(ofFile:)))
    #expect(SnapshotShard.mismatch(with: names.sorted()) == nil)
  }

  @Test func everyFileIsComparedByExactlyOneShard() throws {
    let files = try SnapshotComparison.pngs(in: Self.baselines) + ["removed-long-ago-light.png"]
    let shards = (1...SnapshotShard.count).compactMap(SnapshotShard.init(index:))
    #expect(shards.count == SnapshotShard.count)
    for file in files {
      #expect(shards.filter { $0.compares(file: file) }.count == 1, "\(file)")
    }
  }

  @Test func theShardsStayEven() {
    let sizes = Dictionary(grouping: SnapshotShard.assignment.values, by: { $0 }).mapValues(\.count)
    #expect(Set(sizes.keys) == Set(1...SnapshotShard.count))
    #expect(sizes.values.max()! - sizes.values.min()! <= 1)
  }

  @Test func aShardIsReadAsKOfTheRunnerCount() {
    #expect(SnapshotShard(parsing: "1/4") == SnapshotShard(index: 1))
    #expect(SnapshotShard(parsing: "4/4")?.description == "4/4")
    for text in ["0/4", "5/4", "2/3", "2/5", "2", "2/", "/4", "a/4", "1/4/4"] {
      #expect(SnapshotShard(parsing: text) == nil, "\(text)")
    }
  }

  @Test func aFileIsNamedForItsSnapshotWithoutTheAppearance() {
    #expect(SnapshotShard.snapshotName(ofFile: "settings-general-light.png") == "settings-general")
    #expect(
      SnapshotShard.snapshotName(ofFile: "debug-panel-calls-replay-dark.png")
        == "debug-panel-calls-replay"
    )
    #expect(SnapshotShard.snapshotName(ofFile: "menu-bar-marks.png") == "menu-bar-marks")
  }

  @Test func aSnapshotWithoutAShardAndAShardWithoutASnapshotBothFail() {
    var names = Array(SnapshotShard.assignment.keys)
    #expect(SnapshotShard.mismatch(with: names) == nil)
    names.removeAll { $0 == "toast" }
    names.append("toast-brand-new")
    let mismatch = SnapshotShard.mismatch(with: names)
    #expect(mismatch?.contains("no shard for toast-brand-new") == true)
    #expect(mismatch?.contains("names toast, which no snapshot renders") == true)
  }
}
