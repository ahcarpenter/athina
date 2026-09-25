import Foundation

/// What became of one snapshot between the approved set and a new render.
public enum SnapshotStatus: Equatable, Sendable {
    /// Every pixel within the tolerance of its baseline.
    case unchanged(PixelDiff)
    /// Some pixels moved further than the tolerance.
    case changed(PixelDiff)
    /// Rendered at another size, so no pixel lines up with its baseline.
    case resized(from: PixelSize, to: PixelSize)
    /// Rendered, with no approved baseline yet.
    case added
    /// An approved baseline the renderer no longer produces.
    case removed

    public var isDrift: Bool {
        if case .unchanged = self { return false }
        return true
    }

    /// A few words for a log line or a table cell.
    public var summary: String {
        switch self {
        case .unchanged(let diff):
            diff.largestDelta == 0 ? "identical" : "within tolerance (largest channel difference \(diff.largestDelta))"
        case .changed(let diff):
            "\(diff.changedPixels) \(diff.changedPixels == 1 ? "pixel" : "pixels") changed in \(diff.changedBounds.map(String.init(describing:)) ?? "none"), largest channel difference \(diff.largestDelta)"
        case .resized(let from, let to):
            "size changed from \(from) to \(to)"
        case .added:
            "new, no approved baseline"
        case .removed:
            "no longer rendered, baseline still committed"
        }
    }
}

public struct SnapshotResult: Equatable, Sendable {
    /// The file name, `settings-general-light.png`.
    public let file: String
    public let status: SnapshotStatus

    public init(file: String, status: SnapshotStatus) {
        self.file = file
        self.status = status
    }

    /// The file name without its extension, which names the snapshot.
    public var name: String { (file as NSString).deletingPathExtension }
}

/// The approved set against a new render: every PNG in either directory, by name.
public struct SnapshotComparison: Sendable {
    /// Channel differences up to 6 of 255 are not change. That covers the
    /// shading an anti-aliased edge can pick up and the window server's glass,
    /// which on the CI runner draws a dark switch's knob one of two ways from
    /// one window to the next, up to 5 of 255 apart in a few dozen pixels. A
    /// person sees neither, and anything a person would see, a shifted edge, a
    /// new colour, a moved line, moves some channel much further.
    public static let defaultTolerance = 6

    public let results: [SnapshotResult]
    public let tolerance: Int
    /// Whether a render a whole multiple of its baseline's size, such as a
    /// Retina Mac's 2x beside the runner's 1x, was scaled down to it first.
    public let matchesScale: Bool

    public var drift: [SnapshotResult] { results.filter(\.status.isDrift) }
    public var matches: Bool { drift.isEmpty }

    public static func compare(baseline: URL, actual: URL, tolerance: Int = defaultTolerance, matchingScale: Bool = false) throws -> SnapshotComparison {
        let before = try pngs(in: baseline)
        let after = try pngs(in: actual)
        var results: [SnapshotResult] = []
        for file in Set(before).union(after).sorted() {
            switch (before.contains(file), after.contains(file)) {
            case (false, _):
                results.append(SnapshotResult(file: file, status: .added))
            case (_, false):
                results.append(SnapshotResult(file: file, status: .removed))
            default:
                let old = try Bitmap(contentsOf: baseline.appendingPathComponent(file))
                let new = try render(of: file, in: actual, beside: old, matchingScale: matchingScale)
                results.append(SnapshotResult(file: file, status: status(old, new, tolerance: tolerance)))
            }
        }
        return SnapshotComparison(results: results, tolerance: tolerance, matchesScale: matchingScale)
    }

    /// A render as it is compared: scaled down to its baseline's size first
    /// when asked to and it is a whole multiple of it.
    static func render(of file: String, in actual: URL, beside baseline: Bitmap, matchingScale: Bool) throws -> Bitmap {
        let new = try Bitmap(contentsOf: actual.appendingPathComponent(file))
        guard matchingScale, let factor = new.scaleFactor(over: baseline.size), factor > 1 else { return new }
        return new.downsampled(by: factor)
    }

    public static func status(_ before: Bitmap, _ after: Bitmap, tolerance: Int) -> SnapshotStatus {
        guard before.size == after.size else { return .resized(from: before.size, to: after.size) }
        let diff = PixelDiff.compare(before, after, tolerance: tolerance)
        return diff.matches ? .unchanged(diff) : .changed(diff)
    }

    /// The PNG file names directly inside `directory`; none when it does not exist.
    static func pngs(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.lowercased().hasSuffix(".png") }
            .sorted()
    }

    /// Makes the approved set match the render wherever it drifted: a changed,
    /// resized or new snapshot's render becomes its baseline and a removed
    /// snapshot's baseline is deleted. A snapshot within the tolerance keeps
    /// its baseline, so approving never churns files nobody changed.
    public func approve(baseline: URL, actual: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: baseline, withIntermediateDirectories: true)
        for result in drift {
            let target = baseline.appendingPathComponent(result.file)
            if files.fileExists(atPath: target.path) {
                try files.removeItem(at: target)
            }
            if result.status != .removed {
                try files.copyItem(at: actual.appendingPathComponent(result.file), to: target)
            }
        }
    }
}
