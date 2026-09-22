import CryptoKit
import Foundation
import SQLite3

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
/// - the old directory, and a new one that holds nothing of the owner's: the
///   move. What the app itself puts in the new directory without anyone's
///   data being involved (`skipped`: a replay's per-launch directories, a lock
///   file) does not count as data, so a replay run before the first live
///   launch never stands in the way.
/// - both directories holding real data: refused, named in the log and in
///   Settings, because only the owner can say which of two sets of real data
///   is the one to keep. Merging or overwriting either could lose a day's
///   work silently. The launch carries on in the new directory.
///
/// The move holds SQLite's exclusive lock on the old journal from before the
/// first byte is read until the last file is in place. The journal is a
/// write-ahead-log database, which copied file by file under a writer can
/// come out torn, so it is copied by SQLite itself (`VACUUM INTO`), and when
/// the lock cannot be had, because Mentor or another copy of the app still
/// has the journal open, nothing is copied at all (`inUse`). Everything is
/// assembled in a staging directory beside the new one and checked there: the
/// journal by SQLite's integrity check and a row count of every table against
/// the original, every other file by SHA-256 digest. Only then is it put in
/// place, behind a record of the names being put there (`pendingName`), with
/// the marker written last.
///
/// A move that cannot be finished (`inUse`, `failed`) stops the launch, and
/// takes back whatever that attempt put in the new directory, and nothing
/// else, so the next launch simply tries again. One cut short by a crash
/// leaves the staging directory or the record, and the next launch takes back
/// exactly what the record names before it starts again: never a half-filled
/// directory the app would take for its own.
///
/// The old directory is left exactly as it is, even once the move is done, so
/// the copy the app no longer reads is still the owner's to look at or
/// remove.
///
/// A replay never runs this: its data directory is its own (`LaunchFiles`)
/// and nothing it does may reach the live files.
public enum DataMigration {
    /// Written inside the new directory as the last thing the move does, so
    /// its presence means a finished move rather than a directory that
    /// happens to exist.
    public static let markerName = "migrated-from-mentor.json"

    /// Written inside the new directory before anything is put there, naming
    /// what is about to be, and removed once the marker is written. Found on
    /// its own, it is the proof of which names an unfinished move created.
    static let pendingName = "migrating-from-mentor.json"

    /// Where the copy is assembled: beside the new directory, so putting it
    /// in place stays on one volume.
    static let stagingName = "athina.incoming"

    /// What is not worth moving, and is not the owner's data when found in
    /// the new directory: the per-launch replay directories, which are
    /// disposable and swept on their own, and either name of the lock file a
    /// running launch holds.
    static let skipped: Set<String> = ["replay", "mentor.pid", DataDirectoryLock.fileName, ".DS_Store"]

    /// The journal, which SQLite copies rather than the file manager.
    static var journalName: String { Journal.defaultURL().lastPathComponent }

    /// The journal's write-ahead log and its index. The copy SQLite makes is
    /// one whole file, so neither has anything to add to it.
    static var journalSidecars: Set<String> { ["\(journalName)-wal", "\(journalName)-shm"] }

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
        /// The old journal is open somewhere else, so it cannot be copied
        /// safely; nothing was changed under either name.
        case inUse(String)
        /// The move was attempted and could not be finished; nothing was
        /// changed under either name.
        case failed(String)

        /// A sentence for the log and for Settings, or nil when a launch has
        /// nothing to say about the move.
        public var note: String? {
            switch self {
            case .nothingToMove, .alreadyMoved: nil
            case .moved(let names): "Moved \(Plural.count(names.count, "item", "items")) from the folder Mentor used: \(names.joined(separator: ", "))."
            case .refused(let reason), .inUse(let reason), .failed(let reason): reason
            }
        }

        /// Whether the owner has to do something about it.
        public var needsAttention: Bool {
            switch self {
            case .refused, .inUse, .failed: true
            case .nothingToMove, .alreadyMoved, .moved: false
            }
        }

        /// Whether this launch must not go on: the owner's data is still
        /// under the old name, so running would start an empty journal in its
        /// place. The next launch tries the move again.
        public var stopsLaunch: Bool {
            switch self {
            case .inUse, .failed: true
            case .nothingToMove, .alreadyMoved, .moved, .refused: false
            }
        }
    }

    /// What the marker holds: where the files came from and when, so the move
    /// can be read back long afterwards. The record of a move under way
    /// (`pendingName`) holds the same.
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
        let untouched = "What Mentor kept in \(old.path) is untouched, and the next launch tries the move again. "
            + "If this keeps happening, move that folder somewhere else and Athina starts with an empty journal, "
            + "leaving that copy intact where you put it."
        if manager.fileExists(atPath: new.appendingPathComponent(markerName).path) {
            try? manager.removeItem(at: new.appendingPathComponent(pendingName))
            return .alreadyMoved
        }
        do {
            try takeBackUnfinishedMove(in: new, manager: manager)
        } catch {
            return .failed("Could not clear the unfinished move in \(new.path): \(sentence(error.localizedDescription)) \(untouched)")
        }
        let found = ownersData(in: new, manager: manager)
        guard found.isEmpty else {
            return .refused(
                "\(new.path) already holds \(found.joined(separator: ", ")), and \(old.path) holds what Mentor kept, so both hold "
                    + "data. Athina is using \(new.lastPathComponent) and has left \(old.lastPathComponent) untouched. "
                    + "Keep the one you want and move the other away."
            )
        }

        let journal = old.appendingPathComponent(journalName)
        var source: SQLiteConnection?
        if manager.fileExists(atPath: journal.path) {
            do {
                source = try lockedJournal(at: journal, manager: manager)
            } catch let error as SQLiteError where error.code & 0xff == SQLITE_BUSY {
                return .inUse(
                    "Could not move \(old.path) to \(new.path): \(journal.path) is open in Mentor or another copy of the app. "
                        + "Quit it, then open Athina again. \(untouched)"
                )
            } catch {
                return .failed("Could not move \(old.path) to \(new.path): \(journal.path) would not open: \(sentence(String(describing: error))) \(untouched)")
            }
        }
        // The lock goes when the connection does, so it is kept until the
        // last file is in place.
        return withExtendedLifetime(source) {
            let staging = new.deletingLastPathComponent().appendingPathComponent(stagingName, isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            do {
                let names = try stage(old, in: staging, journal: source, manager: manager)
                if let difference = try firstDifference(between: old, and: staging, journal: source, manager: manager) {
                    return .failed("Could not copy \(old.path) to \(new.path): \(difference). \(untouched)")
                }
                try place(names, from: staging, in: new, marker: Marker(from: old.path, at: now, moved: names), manager: manager)
                return .moved(names)
            } catch {
                let reason = (error as? SQLiteError)?.description ?? error.localizedDescription
                return .failed("Could not move \(old.path) to \(new.path): \(sentence(reason)) \(untouched)")
            }
        }
    }

    /// `text` as one sentence, whether or not it already ended in a period,
    /// so an error's description reads on into the next sentence cleanly.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    /// The names in `directory` that are somebody's data rather than what the
    /// app leaves there on its own (`skipped`). Empty when it is not there.
    static func ownersData(in directory: URL, manager: FileManager) -> [String] {
        ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !skipped.contains($0) }
            .sorted()
    }

    /// Takes out what a move that never finished put into `new`: exactly the
    /// names its record lists, then the record. Nothing when there is none.
    private static func takeBackUnfinishedMove(in new: URL, manager: FileManager) throws {
        let pending = new.appendingPathComponent(pendingName)
        guard manager.fileExists(atPath: pending.path) else { return }
        let record = try decoder.decode(Marker.self, from: Data(contentsOf: pending))
        for name in record.moved where isPlainName(name) {
            let url = new.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        try manager.removeItem(at: pending)
    }

    /// One path component, so a record can never name anything outside the
    /// directory it was written in.
    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// Opens the old journal holding SQLite's exclusive lock, which it keeps
    /// until the connection goes. Any other connection to the file, even an
    /// idle one, holds a shared lock in write-ahead-log mode, so this throws
    /// `SQLITE_BUSY` while another copy of the app has the journal open.
    ///
    /// The journal is only read, and stays byte for byte what it was: in
    /// exclusive mode the log's index lives in memory rather than in `-shm`,
    /// and a log that was there beforehand (Mentor did not quit cleanly) is
    /// left as found rather than folded into the database on close.
    private static func lockedJournal(at url: URL, manager: FileManager) throws -> SQLiteConnection {
        let hadLog = manager.fileExists(atPath: url.path + "-wal")
        let connection = try SQLiteConnection(path: url.path, create: false)
        if hadLog { try connection.keepWriteAheadLogOnClose() }
        // Another copy of the app holding the journal is not about to let go,
        // so the launch says so promptly rather than sitting on the wait a
        // journal gives its own writers.
        try connection.execute("PRAGMA busy_timeout = 500")
        try connection.execute("PRAGMA locking_mode = EXCLUSIVE")
        _ = try connection.scalarInt("SELECT count(*) FROM sqlite_master")
        return connection
    }

    /// Assembles the copy in `staging`, thrown away first if an earlier
    /// attempt left one. Returns the names copied, in order.
    private static func stage(_ old: URL, in staging: URL, journal: SQLiteConnection?, manager: FileManager) throws -> [String] {
        if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = try manager.contentsOfDirectory(atPath: old.path)
            .filter { !skipped.contains($0) && !journalSidecars.contains($0) }
            .sorted()
        for name in names {
            let target = staging.appendingPathComponent(name)
            if name == journalName, let journal {
                try journal.execute("VACUUM INTO '\(target.path.replacingOccurrences(of: "'", with: "''"))'")
            } else {
                try manager.copyItem(at: old.appendingPathComponent(name), to: target)
            }
        }
        return names
    }

    /// Puts the staged names into `new`, which holds nothing of the owner's,
    /// behind the record that names them. Whatever goes wrong, what this call
    /// put there is taken out again, and the directory too when this call
    /// made it, so a failed move leaves `new` as it was found.
    private static func place(_ names: [String], from staging: URL, in new: URL, marker: Marker, manager: FileManager) throws {
        let madeDirectory = !manager.fileExists(atPath: new.path)
        let pending = new.appendingPathComponent(pendingName)
        var placed: [URL] = []
        do {
            if madeDirectory {
                try manager.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let record = try encoder.encode(marker)
            try record.write(to: pending, options: .atomic)
            for name in names {
                let target = new.appendingPathComponent(name)
                try manager.moveItem(at: staging.appendingPathComponent(name), to: target)
                placed.append(target)
            }
            try record.write(to: new.appendingPathComponent(markerName), options: .atomic)
            try? manager.removeItem(at: pending)
        } catch {
            for url in placed { try? manager.removeItem(at: url) }
            try? manager.removeItem(at: pending)
            if madeDirectory, (try? manager.contentsOfDirectory(atPath: new.path))?.isEmpty == true {
                try? manager.removeItem(at: new)
            }
            throw error
        }
    }

    /// The first way the copy differs from what it was copied from: a missing
    /// or extra path, a file whose SHA-256 digest is not the original's, or a
    /// journal that fails SQLite's integrity check or holds another number of
    /// rows. Nil when the copy is faithful. `journal` is the open original;
    /// without it the journal is compared like any other file.
    static func firstDifference(
        between source: URL, and copy: URL, journal: SQLiteConnection? = nil, manager: FileManager
    ) throws -> String? {
        let ownCheck: Set<String> = journal == nil ? [] : [journalName]
        let left = contents(of: source, leavingOut: journalSidecars.union(ownCheck), manager: manager)
        let right = contents(of: copy, leavingOut: journalSidecars.union(ownCheck), manager: manager)
        for (path, original) in left.sorted(by: { $0.key < $1.key }) {
            guard let copied = right[path] else { return "\(path) was not copied" }
            guard original != .unreadable else { return "\(path) could not be read" }
            guard copied == original else { return "\(path) is not what was copied: its contents differ" }
        }
        for path in right.keys.sorted() where left[path] == nil {
            return "\(path) is in the copy but not in \(source.lastPathComponent)"
        }
        guard let journal else { return nil }
        return try journalDifference(between: journal, and: copy.appendingPathComponent(journalName))
    }

    /// How the journal SQLite copied differs from the original: it fails the
    /// integrity check, or a table is missing, extra, or another length.
    private static func journalDifference(between original: SQLiteConnection, and copyURL: URL) throws -> String? {
        let copy = try SQLiteConnection(path: copyURL.path, create: false)
        let verdict = try copy.query("PRAGMA integrity_check") { $0.text(0) ?? "" }
        guard verdict == ["ok"] else {
            return "the copied journal fails SQLite's integrity check (\(verdict.first ?? "no verdict"))"
        }
        let listing = "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        let tables = try original.query(listing) { $0.text(0) ?? "" }
        let copied = try copy.query(listing) { $0.text(0) ?? "" }
        guard copied == tables else {
            return "the copied journal does not hold the same tables"
        }
        for table in tables {
            let count = "SELECT count(*) FROM \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
            let (was, came) = (try original.scalarInt(count), try copy.scalarInt(count))
            guard was == came else { return "the copied journal's \(table) came out \(came) rows, not \(was)" }
        }
        return nil
    }

    private enum Entry: Equatable {
        case directory
        case file(SHA256.Digest)
        case unreadable
    }

    /// Every path under `directory` relative to it, with what is there. The
    /// names the move skips are left out at any depth, and `leavingOut` at
    /// the top.
    private static func contents(of directory: URL, leavingOut: Set<String>, manager: FileManager) -> [String: Entry] {
        guard let walk = manager.enumerator(atPath: directory.path) else { return [:] }
        var found: [String: Entry] = [:]
        for case let path as String in walk {
            guard !leavingOut.contains(path) else { continue }
            guard !path.split(separator: "/").contains(where: { skipped.contains(String($0)) }) else { continue }
            let url = directory.appendingPathComponent(path)
            if isDirectory(url, manager) {
                found[path] = .directory
            } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                found[path] = .file(SHA256.hash(data: data))
            } else {
                found[path] = .unreadable
            }
        }
        return found
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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
/// Once, on the first live launch, which records that it has been settled
/// (`doneKey`); preferences written under the new name after that are never
/// overwritten. A replay shares the new domain, never runs this, and may well
/// run before that first live launch, so what is found there without the
/// record is only what a replay left: the owner's preferences are laid over
/// it rather than turned away by it. The old domain is left as it is, like
/// the old directory (`DataMigration`).
public enum PreferencesMigration {
    /// Set in the new domain by the first live launch, whether or not there
    /// was anything to copy.
    public static let doneKey = "preferencesSettledFromMentor"

    public enum Outcome: Equatable, Sendable {
        /// The old domain holds nothing, which is a fresh install.
        case nothingToMove
        /// A live launch has settled this before; the new domain is its own.
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
        var current = defaults.persistentDomain(forName: new) ?? [:]
        guard current[doneKey] as? Bool != true else { return .alreadyThere }
        let existing = defaults.persistentDomain(forName: old) ?? [:]
        current.merge(existing) { _, owners in owners }
        current[doneKey] = true
        defaults.setPersistentDomain(current, forName: new)
        return existing.isEmpty ? .nothingToMove : .copied(existing.keys.sorted())
    }
}
