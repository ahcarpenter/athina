// Built only with the UISnapshotsSmoke trait on (Package.swift), which `make ui-snapshots-smoke`
// turns on, so `make test` compiles none of this.
#if UISnapshotsSmoke
  import AppKit
  import SnapshotDiff
  import SnapshotTesting
  import Testing

  @testable import Athina

  /// The UI smoke test (README "UI snapshot smoke test"): every snapshot `--snapshot` renders,
  /// from the same specs and sample data, drawn inside this process by swift-snapshot-testing and
  /// compared with the reference image the CI runner recorded for it.
  ///
  /// It never records a reference. A missing one fails like a changed one, and the render that
  /// would replace it goes to `build/snapshots-smoke/references`, which CI uploads for
  /// `make snapshots-smoke-approve` to take. With `UI_SNAPSHOTS_SMOKE_SHARD` set to `k/n`, as each
  /// of CI's four runners sets it, it draws and checks only the snapshots `SnapshotShard` gives
  /// shard k, the same split `ui-snapshots` uses.
  @MainActor
  @Suite(.serialized, .snapshots(record: .never))
  struct UISnapshotsSmokeTests {
    /// Each pixel must be within 2 Delta E of the reference, the difference the human eye cannot
    /// see: anti-aliasing moves an edge's pixels by less, and any change a person would notice
    /// moves them by more.
    private static let strategy = Snapshotting<NSImage, NSImage>.image(perceptualPrecision: 0.98)

    /// The name swift-snapshot-testing gives every reference, before the snapshot's own name.
    private static let testName = "snapshot"

    private static let testsDirectory = URL(filePath: #filePath).deletingLastPathComponent()
    private static let root = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()

    /// Where swift-snapshot-testing keeps this file's references, its own default.
    private static let references = testsDirectory.appending(
      path: "__Snapshots__/UISnapshotsSmokeTests", directoryHint: .isDirectory)

    private static let output = root.appending(
      path: "build/snapshots-smoke", directoryHint: .isDirectory)

    /// The reference file of each snapshot, in both appearances.
    private static func referenceFiles(of specs: [Snapshots.Spec]) -> [String] {
      Snapshots.appearances.flatMap { appearance in
        specs.map { "\(testName).\($0.fileName(in: appearance)).png" }
      }
    }

    /// The shard this run checks, or nil for every snapshot. A value that is not a shard
    /// `SnapshotShard` accepts fails the run rather than checking some other set.
    private static func shard() throws -> SnapshotShard? {
      guard let value = ProcessInfo.processInfo.environment["UI_SNAPSHOTS_SMOKE_SHARD"],
        !value.isEmpty
      else { return nil }
      guard let shard = SnapshotShard(parsing: value) else {
        throw ShardError(value: value)
      }
      return shard
    }

    private struct ShardError: Error, CustomStringConvertible {
      let value: String
      var description: String {
        let count = SnapshotShard.count
        return "UI_SNAPSHOTS_SMOKE_SHARD is \(value), not k/\(count) with k from 1 to \(count)"
      }
    }

    init() {
      // What `scripts/snapshots.sh` gives `--snapshot`: every clock time and date reads the same
      // whatever the machine is set to. The runner's locale is already US English.
      NSTimeZone.default = TimeZone(identifier: "UTC")!
      // An app that owns windows, with no Dock icon, as the app itself is.
      NSApplication.shared.setActivationPolicy(.accessory)
      // A test process's bundle is the test runner's, so the marks come from the folder the app
      // bundle copies them from.
      MenuBarMarkImage.directory = Self.root.appending(
        path: "Resources/Mark", directoryHint: .isDirectory)
    }

    @Test func everySnapshotMatchesItsReference() async throws {
      let fileManager = FileManager.default
      // The set a run publishes for approving: the reference of every snapshot that matched and
      // the new render of every other one. It is filled beside its final place and moved there
      // only once every snapshot it draws has rendered, so an unfinished run never publishes a partial
      // set that approving would take for the whole one.
      let partial = Self.output.appending(path: "references-partial", directoryHint: .isDirectory)
      let approvable = Self.output.appending(path: "references", directoryHint: .isDirectory)
      let drift = Self.output.appending(path: "drift", directoryHint: .isDirectory)
      for directory in [partial, approvable, drift]
      where fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
      }
      try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)

      let shard = try Self.shard()
      let allSpecs = Snapshots.specs()
      if let mismatch = SnapshotShard.mismatch(with: allSpecs.map(\.name)) {
        Issue.record(Comment(rawValue: mismatch))
        return
      }
      let specs = allSpecs.filter { shard?.renders($0.name) ?? true }
      for appearance in Snapshots.appearances {
        for spec in specs {
          let name = spec.fileName(in: appearance)
          let file = "\(Self.testName).\(name).png"
          let bitmap = try await Snapshots.settledPicture(
            of: spec, in: appearance, capture: Self.capture)
          let image = NSImage(cgImage: try bitmap.cgImage(), size: .zero)
          let failure = verifySnapshot(
            of: image, as: Self.strategy, named: name, snapshotDirectory: Self.references.path,
            testName: Self.testName)
          guard let failure else {
            try fileManager.copyItem(
              at: Self.references.appending(path: file), to: partial.appending(path: file))
            continue
          }
          Issue.record(Comment(rawValue: failure))
          try Self.strategy.diffing.toData(image).write(to: partial.appending(path: file))
          try Self.writeDrift(
            of: image, from: Self.references.appending(path: file), to: drift.appending(path: name))
        }
      }
      try fileManager.moveItem(at: partial, to: approvable)
    }

    /// A reference no snapshot produces fails until it is deleted, as approving deletes it, so the
    /// references are only ever the ones the test compares. Each shard checks the files of its own
    /// snapshots, and one whose snapshot has no shard falls to the first.
    @Test func everyReferenceHasASnapshot() throws {
      let shard = try Self.shard()
      let expected = Set(Self.referenceFiles(of: Snapshots.specs()))
      let prefix = "\(Self.testName)."
      let present = try FileManager.default.contentsOfDirectory(atPath: Self.references.path)
        .filter { !$0.hasPrefix(".") }
        .filter { file in
          shard?.compares(
            file: file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file)
            ?? true
        }
      for file in present.sorted() where !expected.contains(file) {
        Issue.record("\(file) is the reference of no snapshot; delete it")
      }
    }

    /// The window drawn in this process by swift-snapshot-testing's view strategy, rather than
    /// captured from the window server as `--snapshot` does. It draws the window's frame view, the
    /// view under the content that paints the window's background, so the picture has the same
    /// backdrop, and it shows much of what sits on Liquid Glass, which the content view drawn on
    /// its own leaves out. Drawn in process, a view is drawn as its layers stand, so the first
    /// capture needs no wait.
    private static let capture = Snapshots.Capture(firstCaptureDelay: .zero) { window, hosting in
      let frameView = window.contentView?.superview ?? hosting
      let image = await withCheckedContinuation { continuation in
        Snapshotting<NSView, NSImage>.image.snapshot(frameView).run {
          continuation.resume(returning: $0)
        }
      }
      return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The reference, the new render and where they differ, one folder per drifted snapshot, as
    /// swift-snapshot-testing names them; only the render when there is no reference yet.
    private static func writeDrift(of image: NSImage, from reference: URL, to folder: URL) throws {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      guard let data = try? Data(contentsOf: reference) else {
        try strategy.diffing.toData(image).write(to: folder.appending(path: "failure.png"))
        return
      }
      let attachments = strategy.diffing.diffV2(strategy.diffing.fromData(data), image)?.1 ?? []
      for case .data(let data, let name) in attachments {
        try data.write(to: folder.appending(path: name))
      }
    }
  }
#endif
