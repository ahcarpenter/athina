import Foundation

/// One of the CI runners each UI snapshot gate, `ui-snapshots` and
/// `ui-snapshots-smoke`, is split across: each renders and compares only the
/// snapshots `assignment` gives it, and a gate passes only when every shard
/// does (docs/ci.md "UI snapshot baselines" and "UI snapshot smoke test").
public struct SnapshotShard: Equatable, Sendable, CustomStringConvertible {
  /// How many runners each gate is split across.
  ///
  /// Each workflow passes its matrix size with each shard, so a matrix of
  /// another size fails every shard rather than leaving some snapshots
  /// unchecked.
  public static let count = 4

  /// Which shard renders each snapshot, by the name `Snapshots.swift` gives it,
  /// both appearances together.
  ///
  /// Fixed rather than hashed so the shards stay even: every render costs about
  /// the same, the few large windows (the debug panel, the Models pane, the
  /// callout) are spread out, and each shard gets nine or ten. A snapshot with
  /// no entry fails the render and an entry with no snapshot fails it too, so
  /// the table always names exactly the snapshots there are.
  public static let assignment: [String: Int] = [
    "permissions": 1,
    "debug-panel": 1,
    "debug-panel-replay": 1,
    "understanding-card": 1,
    "settings-general": 1,
    "settings-context-editor": 1,
    "settings-understanding": 1,
    "settings-advanced": 1,
    "toast": 1,
    "toast-answered": 1,

    "debug-panel-calls": 2,
    "callout": 2,
    "understanding-card-empty": 2,
    "settings-contexts": 2,
    "settings-context-editor-duplicate": 2,
    "settings-models": 2,
    "settings-understanding-empty": 2,
    "settings-advanced-on": 2,
    "toast-expanded": 2,
    "toast-note": 2,

    "debug-panel-empty": 3,
    "understanding-card-paused": 3,
    "settings-contexts-empty": 3,
    "settings-status-messages": 3,
    "settings-models-empty": 3,
    "settings-capture": 3,
    "history": 3,
    "toast-listening": 3,
    "menu-bar-marks": 3,

    "debug-panel-calls-replay": 4,
    "understanding-card-refreshing": 4,
    "understanding-card-failed": 4,
    "settings-contexts-at-cap": 4,
    "settings-journal": 4,
    "settings-privacy": 4,
    "history-empty": 4,
    "toast-thinking": 4,
    "settings-models-replay": 4,
  ]

  /// 1 through `count`.
  public let index: Int

  /// Creates shard `index`, or nil unless it is 1 through `count`.
  public init?(index: Int) {
    guard (1...Self.count).contains(index) else { return nil }
    self.index = index
  }

  /// Reads `k/n`, the form the workflow passes: shard k of n runners.
  ///
  /// Nil unless n is `count` and k is one of them.
  public init?(parsing text: String) {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let index = Int(parts[0]),
      let total = Int(parts[1]),
      total == Self.count
    else { return nil }
    self.init(index: index)
  }

  /// Reads `k/n`, the form `init(parsing:)` reads, such as `2/4`.
  public var description: String { "\(index)/\(Self.count)" }

  /// Whether this shard renders the snapshot named `name`.
  public func renders(_ name: String) -> Bool {
    Self.assignment[name] == index
  }

  /// Whether this shard compares the file `file`, a render or a baseline such
  /// as `settings-general-light.png`.
  ///
  /// A file whose snapshot has no shard, such as the baseline of a snapshot
  /// since removed, falls to the first, so it is still reported rather than
  /// never looked at.
  public func compares(file: String) -> Bool {
    (Self.assignment[Self.snapshotName(ofFile: file)] ?? 1) == index
  }

  /// The snapshot a file is a render of: its name without the extension and
  /// the appearance, `settings-general` for `settings-general-light.png`.
  public static func snapshotName(ofFile file: String) -> String {
    let name = (file as NSString).deletingPathExtension
    for suffix in ["-light", "-dark"] where name.hasSuffix(suffix) {
      return String(name.dropLast(suffix.count))
    }
    return name
  }

  /// Why `names`, every snapshot the renderer has, does not match the
  /// table, or nil when every one has a shard and every entry a snapshot.
  public static func mismatch(with names: [String]) -> String? {
    let unassigned = names.filter { assignment[$0] == nil }
    let stale = Set(assignment.keys).subtracting(names).sorted()
    var problems: [String] = []
    if !unassigned.isEmpty {
      problems.append(
        "no shard for \(unassigned.joined(separator: ", ")); add each to SnapshotShard.assignment"
      )
    }
    if !stale.isEmpty {
      problems.append(
        """
        SnapshotShard.assignment names \(stale.joined(separator: ", ")), which no snapshot \
        renders; remove each
        """
      )
    }
    return problems.isEmpty ? nil : problems.joined(separator: "; ")
  }
}
