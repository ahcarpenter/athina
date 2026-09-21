import Foundation

/// Moves the files the app kept under its old name to the ones it keeps now.
///
/// The app was Mentor, with the bundle identifier `com.ahcarpenter.mentor`,
/// so an owner who used it has a journal, settings, recorded calls and the
/// understanding inside that journal in
/// `~/Library/Application Support/mentor`. Athina keeps all of it in
/// `~/Library/Application Support/athina`. That data is the owner's own work,
/// so it is neither abandoned nor overwritten:
///
/// - nothing under the old name: nothing to move, which is a fresh install
///   and every launch after a move.
/// - the old directory alone: its contents are copied into a staging
///   directory beside the new one, compared file by file against what they
///   came from, and only then put in place with one rename. An interrupted
///   move therefore leaves either a staging directory, which the next launch
///   removes and starts again from, or a finished one: never a half-filled
///   directory the app would take for its own.
/// - both directories: refused, named in the log and in Settings, because
///   only the owner can say which of two sets of real data is the one to
///   keep. Merging or overwriting either could lose a day's work silently.
///
/// The old directory is left where it is, even once the move is done, so the
/// copy the app no longer reads is still the owner's to look at or remove.
///
/// A replay never runs this: its data directory is its own (`LaunchFiles`)
/// and nothing it does may reach the live files.
public enum DataMigration {
    /// Written inside the new directory as the last thing before the rename
    /// that puts it in place, so its presence means a finished move rather
    /// than a directory that happens to exist.
    public static let markerName = "migrated-from-mentor.json"

    /// Where the copy is assembled: beside the new directory, so the rename
    /// that finishes the move stays on one volume.
    static let stagingName = "athina.incoming"

    /// What is not worth moving: the per-launch replay directories, which are
    /// disposable and swept on their own, and either name of the lock file a
    /// running launch holds.
    static let skipped: Set<String> = ["replay", "mentor.pid", DataDirectoryLock.fileName, ".DS_Store"]

    /// What a launch found, and did.
    public enum Outcome: Equatable, Sendable {
        /// Nothing is there under the old name.
        case nothingToMove
        /// The move already happened; the marker says so.
        case alreadyMoved
        /// The names moved across, in the order they were copied.
        case moved([String])
        /// Both directories hold data, so the owner has to say which to keep.
        case refused(String)
        /// The move was attempted and could not be finished; nothing was
        /// changed under either name.
        case failed(String)

        /// A sentence for the log and for Settings, or nil when a launch has
        /// nothing to say about the move.
        public var note: String? {
            switch self {
            case .nothingToMove, .alreadyMoved: nil
            case .moved(let names): "Moved \(Plural.count(names.count, "item", "items")) from the folder Mentor used: \(names.joined(separator: ", "))."
            case .refused(let reason), .failed(let reason): reason
            }
        }

        /// Whether the owner has to do something about it.
        public var needsAttention: Bool {
            switch self {
            case .refused, .failed: true
            case .nothingToMove, .alreadyMoved, .moved: false
            }
        }
    }

    /// What the marker holds: where the files came from and when, so the move
    /// can be read back long afterwards.
    public struct Marker: Codable, Equatable, Sendable {
        public var from: String
        public var at: Date
        public var moved: [String]

        public init(from: String, at: Date, moved: [String]) {
            self.from = from
            self.at = at
            self.moved = moved
        }
    }

    /// Moves what is under the old name to the new one, once. Safe to call on
    /// every launch: it does nothing at all unless there is something to move.
    public static func run(
        from old: URL = AppPaths.legacySupportDirectory(),
        to new: URL = AppPaths.supportDirectory(),
        now: Date = Date(),
        fileManager manager: FileManager = .default
    ) -> Outcome {
        guard isDirectory(old, manager), old.standardizedFileURL != new.standardizedFileURL else {
            return .nothingToMove
        }
        if manager.fileExists(atPath: new.path) {
            guard !manager.fileExists(atPath: new.appendingPathComponent(markerName).path) else { return .alreadyMoved }
            return .refused(
                "\(new.path) and \(old.path) both hold data. Athina is using \(new.lastPathComponent) and has left "
                    + "\(old.lastPathComponent), the folder Mentor used, untouched. Keep the one you want and move the other away."
            )
        }
        let staging = new.deletingLastPathComponent().appendingPathComponent(stagingName, isDirectory: true)
        do {
            if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
            try manager.createDirectory(
                at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let names = try manager.contentsOfDirectory(atPath: old.path)
                .filter { !skipped.contains($0) }
                .sorted()
            for name in names {
                try manager.copyItem(at: old.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            if let difference = firstDifference(between: old, and: staging, manager: manager) {
                try? manager.removeItem(at: staging)
                return .failed("Could not copy \(old.path) to \(new.path): \(difference). Nothing was changed.")
            }
            let marker = Marker(from: old.path, at: now, moved: names)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(marker).write(to: staging.appendingPathComponent(markerName), options: .atomic)
            try manager.moveItem(at: staging, to: new)
            return .moved(names)
        } catch {
            try? manager.removeItem(at: staging)
            return .failed("Could not move \(old.path) to \(new.path): \(error.localizedDescription). Nothing was changed.")
        }
    }

    /// The first way the copy differs from what it was copied from: a missing
    /// or extra path, or a file of another size. Nil when the two hold the
    /// same files. What the marker adds is not there yet, since it is written
    /// after this.
    static func firstDifference(between source: URL, and copy: URL, manager: FileManager) -> String? {
        let left = contents(of: source, manager: manager)
        let right = contents(of: copy, manager: manager)
        for (path, size) in left.sorted(by: { $0.key < $1.key }) {
            guard let copied = right[path] else { return "\(path) was not copied" }
            guard copied == size else { return "\(path) came out \(copied) bytes, not \(size)" }
        }
        for path in right.keys.sorted() where left[path] == nil {
            return "\(path) is in the copy but not in \(source.lastPathComponent)"
        }
        return nil
    }

    /// Every file under `directory` by its path relative to it, with its size;
    /// a directory has size -1, so one standing in for a file is a difference.
    /// The names the move skips are left out of both sides.
    private static func contents(of directory: URL, manager: FileManager) -> [String: Int64] {
        guard let walk = manager.enumerator(atPath: directory.path) else { return [:] }
        var found: [String: Int64] = [:]
        for case let path as String in walk {
            guard !path.split(separator: "/").contains(where: { skipped.contains(String($0)) }) else { continue }
            let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent(path).path)
            let isDirectory = attributes?[.type] as? FileAttributeType == .typeDirectory
            found[path] = isDirectory ? -1 : (attributes?[.size] as? NSNumber)?.int64Value ?? -2
        }
        return found
    }

    private static func isDirectory(_ url: URL, _ manager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return manager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

/// Moves the preferences the app kept under its old bundle identifier to the
/// one it has now: the Settings pane last open and the window frames, which
/// live in `com.ahcarpenter.mentor` rather than in the journal directory.
///
/// Only into a domain that holds nothing of its own, so preferences the app
/// has already written are never overwritten. The old domain is left as it is,
/// like the old directory (`DataMigration`).
public enum PreferencesMigration {
    public enum Outcome: Equatable, Sendable {
        /// The old domain holds nothing, which is a fresh install and every
        /// launch after a move.
        case nothingToMove
        /// The new domain already holds preferences of its own.
        case alreadyThere
        /// The keys copied across.
        case copied([String])
    }

    @discardableResult
    public static func run(
        from old: String = AppPaths.legacyBundleIdentifier,
        to new: String = AppPaths.bundleIdentifier,
        in defaults: UserDefaults = .standard
    ) -> Outcome {
        guard let existing = defaults.persistentDomain(forName: old), !existing.isEmpty else { return .nothingToMove }
        if let current = defaults.persistentDomain(forName: new), !current.isEmpty { return .alreadyThere }
        defaults.setPersistentDomain(existing, forName: new)
        return .copied(existing.keys.sorted())
    }
}
