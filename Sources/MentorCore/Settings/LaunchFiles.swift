import Darwin
import Foundation

/// Where a launch keeps its journal and settings, and the settings file it
/// starts from, chosen once at launch from the command line.
///
/// Live and recording launches use the support directory itself and start
/// from its settings file, as they always have. A replay, and a replay that
/// was refused (`ModelClientMode.isOffline`), keeps files of its own so that
/// nothing it does reaches the live journal, the live settings, or another
/// replay:
///
/// - with no flag, a new directory made for this launch alone inside
///   `AppPaths.replayRoot`, so two replays never share a journal and a
///   faster clock in one never moves another's
/// - `--data-dir <path>`: that directory; a relaunch with the same one
///   carries on from its journal, clock included
/// - `--settings <path>`: starts from that settings file instead of the live
///   one; the file is read and never written
///
/// Every replay starts from settings it reads and never writes, and keeps its
/// own `settings.json` in its data directory: the settings it started with,
/// recorded there as it starts (`recordSettings`), and anything it changes
/// afterwards. Either flag on a live or recording launch is refused, like the
/// clock flags: the launch uses the live files and says why. A flag with no
/// value is refused the same way, and the replay keeps its own per-launch
/// directory or the live settings.
public struct LaunchFiles: Equatable, Sendable {
    public static let dataDirectoryFlag = "--data-dir"
    public static let settingsFlag = "--settings"
    /// Finished per-launch directories a replay launch leaves in place, newest
    /// first, so a check can still read the journal of one that just quit and
    /// is still inside its own retention window.
    public static let keptFinishedLaunches = 10

    /// Holds the journal and the settings the launch saves.
    public var dataDirectory: URL
    /// True for a directory made for this launch alone, which a later replay
    /// launch may remove once no running replay holds it.
    public var isPerLaunch: Bool
    /// The settings file the launch starts from.
    public var settingsSource: URL
    /// Whether `settingsSource` was asked for with `--settings`.
    public var settingsGiven: Bool
    /// Why a flag was not accepted, in the order they were found.
    public var refusals: [String]

    public init(
        arguments: [String],
        clientMode: ModelClientMode,
        supportDirectory: URL = AppPaths.supportDirectory(),
        launchName: String = LaunchFiles.launchName()
    ) {
        func value(after flag: String) -> String?? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            guard index + 1 < arguments.count else { return .some(nil) }
            let next = arguments[index + 1]
            return next.hasPrefix("--") || next.isEmpty ? .some(nil) : .some(next)
        }
        let dataValue = value(after: LaunchFiles.dataDirectoryFlag)
        let settingsValue = value(after: LaunchFiles.settingsFlag)
        let liveSettings = SettingsStore.defaultURL(in: supportDirectory)
        refusals = []
        settingsGiven = false
        settingsSource = liveSettings

        guard clientMode.isOffline else {
            dataDirectory = supportDirectory
            isPerLaunch = false
            let given = [dataValue.map { _ in LaunchFiles.dataDirectoryFlag }, settingsValue.map { _ in LaunchFiles.settingsFlag }].compactMap { $0 }
            if !given.isEmpty {
                refusals.append("\(given.joined(separator: " and ")) \(given.count == 1 ? "applies" : "apply") only to \(ModelClientMode.replayFlag)")
            }
            return
        }

        if let dataValue, let path = dataValue {
            dataDirectory = ModelClientMode.url(forPath: path)
            isPerLaunch = false
        } else {
            dataDirectory = AppPaths.replayRoot(in: supportDirectory).appendingPathComponent(launchName, isDirectory: true)
            isPerLaunch = true
            if dataValue != nil {
                refusals.append("\(LaunchFiles.dataDirectoryFlag) needs a directory")
            }
        }
        if let settingsValue {
            if let path = settingsValue {
                settingsSource = ModelClientMode.url(forPath: path).standardizedFileURL
                settingsGiven = true
            } else {
                refusals.append("\(LaunchFiles.settingsFlag) needs a settings file")
            }
        }
    }

    /// Where the launch saves its settings.
    public var store: SettingsStore {
        SettingsStore(url: SettingsStore.defaultURL(in: dataDirectory))
    }

    /// The settings the launch starts from. A `--settings` file that cannot
    /// be read or decoded is refused, and the replay starts from the live
    /// settings instead, so the apps the user excluded stay excluded; the
    /// defaults stand in only when there is no live settings file either.
    public mutating func loadSettings(supportDirectory: URL = AppPaths.supportDirectory()) -> SensingSettings {
        guard settingsGiven else { return SettingsStore(url: settingsSource).load() }
        do {
            return try SettingsStore(url: settingsSource).loadStrictly()
        } catch {
            refusals.append("\(LaunchFiles.settingsFlag) could not use \(settingsSource.path): \(error.localizedDescription)")
            settingsSource = SettingsStore.defaultURL(in: supportDirectory)
            settingsGiven = false
            return SettingsStore(url: settingsSource).load()
        }
    }

    /// What claiming the data directory gave this launch.
    public enum Claim {
        /// A live or recording launch, which holds nothing.
        case notNeeded
        /// The replay holds its directory for as long as the lock lives.
        case held(DataDirectoryLock)
        /// The launch must not start, and why.
        case refusedToStart(String)
    }

    /// Makes the replay's data directory its own for as long as the lock in
    /// the returned claim lives; a live or recording launch holds nothing.
    ///
    /// A `--data-dir` another running replay holds refuses the launch rather
    /// than quietly using a different directory: the flag exists so that the
    /// caller knows where the journal is, and the end-to-end harness reads
    /// exactly the path it passed, so a replay writing somewhere else would
    /// leave a check reading a stale journal and reporting a pass that never
    /// happened. Every replay launch, whether it makes its own directory or
    /// was given one, sweeps the finished per-launch directories as it starts
    /// (`pruneFinishedLaunches`).
    ///
    /// A `--data-dir` in the live data folder is refused for the same reason:
    /// the folder holds the live journal and the live settings, and a replay
    /// given it would write its replayed suggestions, feedback and clock-ahead
    /// rows into them, while a live Mentor may be running against the same two
    /// files. The replay root inside it is the one place there that is for a
    /// replay's files, so a lane under it is allowed.
    public mutating func claim(
        clientMode: ModelClientMode,
        supportDirectory: URL = AppPaths.supportDirectory()
    ) -> Claim {
        guard clientMode.isOffline else { return .notNeeded }
        if !isPerLaunch,
           AppPaths.isAt(dataDirectory, orInside: supportDirectory),
           !AppPaths.isAt(dataDirectory, orInside: AppPaths.replayRoot(in: supportDirectory)) {
            let reason = "\(LaunchFiles.dataDirectoryFlag) \(dataDirectory.path) is the live data folder \(supportDirectory.path), or inside it, which a replay may not use: nothing a replay does may reach the live journal or the live settings"
            refusals.append(reason)
            return .refusedToStart(reason)
        }
        do {
            let lock = try DataDirectoryLock.acquire(in: dataDirectory)
            // A directory's age is filesystem wall-clock, one of the system
            // measurements that stay real however fast a replay clock runs.
            LaunchFiles.pruneFinishedLaunches(
                in: AppPaths.replayRoot(in: supportDirectory),
                keeping: LaunchFiles.keptFinishedLaunches,
                now: Date()
            )
            return .held(lock)
        } catch DataDirectoryLock.Failure.inUse(let pid) {
            let holder = pid.map { "pid \($0)" } ?? "another process"
            let reason = "\(LaunchFiles.dataDirectoryFlag) \(dataDirectory.path) is in use by another Mentor (\(holder))"
            refusals.append(reason)
            return .refusedToStart(reason)
        } catch {
            let reason = "could not hold \(dataDirectory.path) for this replay: \(error)"
            refusals.append(reason)
            return .refusedToStart(reason)
        }
    }

    /// Writes the settings this launch runs with into its own data directory,
    /// as soon as the directory is its own, so that a later replay launch
    /// sweeps this directory by the retention window it actually ran with.
    /// Only a launch holding its directory may call this: a live launch's
    /// store is the live settings file, and a refused replay's directory
    /// belongs to the replay that holds it.
    public func recordSettings(_ settings: SensingSettings) {
        try? store.save(settings)
    }

    /// A per-launch directory's name: this process's id, then eight random
    /// hex digits, so a script can find its replay's files by pid.
    public static func launchName(pid: Int32 = getpid()) -> String {
        "launch-\(pid)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func isLaunchName(_ name: String) -> Bool {
        name.wholeMatch(of: /launch-[0-9]+-[0-9a-f]{8}/) != nil
    }

    /// Removes the per-launch directories in `root` that no running replay
    /// holds: those past the newest `keeping` by creation date, and those whose
    /// own recorded thumbnail retention window has run out by `now`. A replay
    /// senses the real screen, and its journal is never opened again once it
    /// quits, so retention can never age the thumbnails and recognized text
    /// inside it and the whole directory goes at that window instead. The
    /// window is each directory's own (`recordSettings`), never the sweeping
    /// launch's, so a check with settings of its own never governs how long
    /// another run's captured screen content is kept; a directory that records
    /// none is swept at the default window. The journal replays shared before
    /// they had a directory each goes the same way (`sweepSharedReplay`);
    /// anything else in `root` is left alone.
    public static func pruneFinishedLaunches(in root: URL, keeping: Int, now: Date) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        var finished: [(url: URL, created: Date, expired: Bool, lock: DataDirectoryLock)] = []
        for name in names where isLaunchName(name) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let lock = try? DataDirectoryLock.acquire(in: url, pid: nil, create: false) else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let window = SettingsStore(url: SettingsStore.defaultURL(in: url)).load().thumbnailRetention
            finished.append((url, created, created < now.addingTimeInterval(-window), lock))
        }
        for (index, entry) in finished.sorted(by: { $0.created > $1.created }).enumerated()
        where index >= keeping || entry.expired {
            try? manager.removeItem(at: entry.url)
        }
        sweepSharedReplay(in: root, now: now)
    }

    /// Removes the journal every replay shared before replays had a directory
    /// each, which sat directly in `root`, once everything in it is past the
    /// window the `settings.json` beside it recorded. Nothing opens that
    /// journal any more, so retention can no longer age its thumbnails and
    /// recognized text in place either, and an upgrade would otherwise leave
    /// captures of the real screen on disk with nothing to expire them.
    ///
    /// The age is when the journal was last written, not when it was made: it
    /// bounds how new anything inside can be, where the creation date would
    /// delete content still inside its window. A replay given `root` itself as
    /// its `--data-dir` holds it, and then these are its own files rather than
    /// a leftover, so the hold is taken before anything is removed.
    private static func sweepSharedReplay(in root: URL, now: Date) {
        let manager = FileManager.default
        let journal = Journal.defaultURL(in: root)
        let settings = SettingsStore.defaultURL(in: root)
        guard manager.fileExists(atPath: journal.path) else { return }
        let window = SettingsStore(url: settings).load().thumbnailRetention
        let written = (try? journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard written < now.addingTimeInterval(-window) else { return }
        guard let lock = try? DataDirectoryLock.acquire(in: root, pid: nil, create: false) else { return }
        let sidecars = ["-shm", "-wal"].map { journal.lastPathComponent + $0 }
        for name in [journal.lastPathComponent] + sidecars + [settings.lastPathComponent, DataDirectoryLock.fileName] {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
        _ = lock
    }
}

/// An exclusive hold on a replay's data directory for the life of the process:
/// an advisory `flock` on `mentor.pid` inside it, which holds the pid. The
/// system lets go of it when the process exits, however it exits, so a crash
/// never leaves a directory held.
public final class DataDirectoryLock: @unchecked Sendable {
    public static let fileName = "mentor.pid"

    public enum Failure: Error, Equatable {
        /// Another process holds it; its pid when the file names one.
        case inUse(pid: Int32?)
        case system(String)
    }

    public let url: URL
    private let descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Takes the hold, creating the directory unless `create` is false, and
    /// writes `pid` into the file; a nil `pid` only checks that no one holds
    /// it and leaves the file as it was.
    ///
    /// The directory is made owner-only, like the journal directory it holds:
    /// this runs before `Journal` opens, so it is what decides the mode.
    public static func acquire(in directory: URL, pid: Int32? = getpid(), create: Bool = true) throws -> DataDirectoryLock {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let url = directory.appendingPathComponent(fileName)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure.system("cannot open \(url.path): \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            let holder = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(descriptor)
            if reason == EWOULDBLOCK { throw Failure.inUse(pid: holder) }
            throw Failure.system("cannot lock \(url.path): \(String(cString: strerror(reason)))")
        }
        guard let pid else { return DataDirectoryLock(url: url, descriptor: descriptor) }
        let text = Array("\(pid)\n".utf8)
        guard ftruncate(descriptor, 0) == 0, pwrite(descriptor, text, text.count, 0) == text.count else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw Failure.system("cannot write \(url.path): \(reason)")
        }
        return DataDirectoryLock(url: url, descriptor: descriptor)
    }
}
