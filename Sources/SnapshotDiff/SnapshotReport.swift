import Foundation

/// What a reviewer looks at when snapshots differ: for each one, its two
/// images and where they differ, at real size, in a folder CI uploads, with a
/// page that shows them side by side and a Markdown table for the job summary.
public enum SnapshotReport {
  /// Writes `index.html`, `summary.md`, and a folder per drifted snapshot
  /// holding `before.png`, `after.png` and, when both have one size,
  /// `diff.png`.
  ///
  /// Replaces whatever `directory` held.
  public static func write(
    _ comparison: SnapshotComparison,
    baseline: URL,
    actual: URL,
    to directory: URL
  ) throws {
    let files = FileManager.default
    if files.fileExists(atPath: directory.path) {
      try files.removeItem(at: directory)
    }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for result in comparison.drift {
      let folder = directory.appendingPathComponent(result.name, isDirectory: true)
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      let before = baseline.appendingPathComponent(result.file)
      let after = actual.appendingPathComponent(result.file)
      if result.status != .added {
        try files.copyItem(at: before, to: folder.appendingPathComponent("before.png"))
      }
      if result.status != .removed {
        try files.copyItem(at: after, to: folder.appendingPathComponent("after.png"))
      }
      if case .changed = result.status {
        try PixelDiff.highlight(
          Bitmap(contentsOf: before),
          Bitmap(contentsOf: after),
          tolerance: comparison.tolerance
        )
        .writePNG(to: folder.appendingPathComponent("diff.png"))
      }
    }
    try html(comparison).write(
      to: directory.appendingPathComponent("index.html"),
      atomically: true,
      encoding: .utf8
    )
    try markdown(comparison).write(
      to: directory.appendingPathComponent("summary.md"),
      atomically: true,
      encoding: .utf8
    )
  }

  public static func markdown(_ comparison: SnapshotComparison) -> String {
    let kind = comparison.kind
    var lines = ["### \(kind.heading)", ""]
    let drift = comparison.drift
    if drift.isEmpty {
      lines.append(
        """
        All \(comparison.results.count) snapshots \(kind.agree) (tolerance \
        \(comparison.tolerance) of 255 per channel).
        """
      )
      return lines.joined(separator: "\n") + "\n"
    }
    lines.append(
      """
      \(drift.count) of \(comparison.results.count) snapshots \(kind.differ) (tolerance \
      \(comparison.tolerance) of 255 per channel). Each one's two images and their \
      difference are in the report artifact.
      """
    )
    lines.append("")
    lines.append("| Snapshot | What changed |")
    lines.append("| --- | --- |")
    for result in drift {
      lines.append("| `\(result.name)` | \(result.status.summary(in: kind)) |")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func html(_ comparison: SnapshotComparison) -> String {
    let kind = comparison.kind
    let drift = comparison.drift
    var body = "<h1>\(escape(kind.heading))</h1>\n"
    if drift.isEmpty {
      body += "<p>All \(comparison.results.count) snapshots \(kind.agree).</p>\n"
    } else {
      body +=
        """
        <p>\(drift.count) of \(comparison.results.count) snapshots \(kind.differ), tolerance \
        \(comparison.tolerance) of 255 per channel. Changed pixels are red in the difference \
        image.</p>\n
        """
    }
    for result in drift {
      let name = escape(result.name)
      body +=
        """
        <section>\n<h2>\(name)</h2>\n<p>\(escape(result.status.summary(in: kind)))</p>\n<div \
        class=\"row\">\n
        """
      var columns: [(String, String)] = []
      if result.status != .added { columns.append((kind.captions.before, "before.png")) }
      if result.status != .removed { columns.append((kind.captions.after, "after.png")) }
      if case .changed = result.status { columns.append(("Difference", "diff.png")) }
      for (title, file) in columns {
        body +=
          """
          <figure><figcaption>\(title)</figcaption><img src=\"\(name)/\(file)\" \
          alt=\"\(name) \(title)\"></figure>\n
          """
      }
      body += "</div>\n</section>\n"
    }
    return """
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Snapshot report</title>
      <style>
      :root { color-scheme: light dark; --checker: #8883; }
      body { font: 14px -apple-system, system-ui, sans-serif; margin: 24px; }
      section { margin: 32px 0; }
      h2 { font: 600 15px ui-monospace, monospace; }
      .row { display: flex; gap: 16px; align-items: flex-start; overflow-x: auto; }
      figure { margin: 0; }
      figcaption { font-size: 12px; opacity: .7; margin-bottom: 4px; }
      /* Real size: one image pixel to one CSS pixel, never smoothed. */
      img { display: block; image-rendering: pixelated; max-width: none; outline: 1px solid \
      var(--checker); }
      </style>
      </head>
      <body>
      \(body)</body>
      </html>

      """
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
