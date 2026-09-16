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
/// - a new directory made for this launch alone inside `AppPaths.replayRoot`,
///   never one the caller names, so two replays never share a journal and a
///   faster clock in one never moves another's. The launch says which one it
///   made on the line it writes when it starts (`LaunchReport`), so a script
///   reads the path rather than dictating it.
/// - `--settings <path>`: starts from that settings file instead of the live
///   one; the file is read and never written, and one that is there but is
///   not settings stops the launch rather than quietly standing the live
///   settings in its place
///
/// Every replay starts from settings it reads and never writes, and keeps its
/// own `settings.json` in its data directory: the settings it started with,
/// recorded there as it starts (`recordSettings`), and anything it changes
/// afterwards. `--settings` on a live or recording launch is refused, like the
/// clock flags: the launch uses the live files and says why. The flag with no
/// value is refused the same way, and the replay keeps the live settings.
public struct LaunchFiles: Equatable, Sendable {
    public static let settingsFlag = "--settings"
    /// Finished per-launch directories a replay launch leaves in place, newest
    /// first, so a check can still read the journal of one that just quit and
    /// is still inside its own retention window.
    public static let keptFinishedLaunches = 10

    /// Holds the journal and the settings the launch saves. For a replay it is
    /// this launch's alone, which a later replay launch may remove once no
    /// running replay holds it.
    public var dataDirectory: URL
    /// The settings file the launch starts from.
    public var settingsSource: URL
    /// Whether `settingsSource` was asked for with `--settings`.
    public var settingsGiven: Bool
    /// Why a flag was not accepted, in the order they were found.
    public var refusals: [String]
    /// Why this launch must not start at all, set by `loadSettings` when the
    /// `--settings` file is there but is not settings. `claim` is what turns
    /// it into a refusal, so every reason a launch must not start leaves by
    /// the one door.
    public private(set) var unusableSettings: String?

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
        let settingsValue = value(after: LaunchFiles.settingsFlag)
        let liveSettings = SettingsStore.defaultURL(in: supportDirectory)
        refusals = []
        unusableSettings = nil
        settingsGiven = false
        settingsSource = liveSettings

        guard clientMode.isOffline else {
            dataDirectory = supportDirectory
            if settingsValue != nil {
                refusals.append("\(LaunchFiles.settingsFlag) applies only to \(ModelClientMode.replayFlag)")
            }
            return
        }

        dataDirectory = AppPaths.replayRoot(in: supportDirectory).appendingPathComponent(launchName, isDirectory: true)
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

    /// The settings the launch starts from. Must be called before `claim`,
    /// which is where a file that refuses the launch is reported.
    ///
    /// A `--settings` file that is there but is not settings stops the launch:
    /// a check names a file it generated, and if that file came out truncated
    /// the replay would otherwise run on the owner's live thresholds,
    /// contexts and retention and report a pass on settings it never chose.
    /// A file that is not there at all is a different mistake, and the replay
    /// starts from the live settings so the apps the user excluded stay
    /// excluded; the defaults stand in only when there is no live settings
    /// file either.
    public mutating func loadSettings(supportDirectory: URL = AppPaths.supportDirectory()) -> SensingSettings {
        guard settingsGiven else { return SettingsStore(url: settingsSource).load() }
        do {
            return try SettingsStore(url: settingsSource).loadStrictly()
        } catch {
            let reason = "\(LaunchFiles.settingsFlag) could not use \(settingsSource.path): \(error.localizedDescription)"
            refusals.append(reason)
            if FileManager.default.fileExists(atPath: settingsSource.path) {
                unusableSettings = reason
            }
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
    /// The directory is this launch's own and is made here, owner-only, so
    /// there is nothing to judge about where it is or who can reach it.
    /// Every replay launch sweeps the finished per-launch directories as it
    /// starts (`pruneFinishedLaunches`).
    ///
    /// A `--settings` file that is there but is not settings refuses the
    /// launch, on the reason `loadSettings` left behind, so a check whose
    /// generated settings came out unreadable stops rather than running on
    /// settings it never chose.
    public mutating func claim(
        clientMode: ModelClientMode,
        supportDirectory: URL = AppPaths.supportDirectory()
    ) -> Claim {
        guard clientMode.isOffline else { return .notNeeded }
        if let unusableSettings {
            return .refusedToStart(unusableSettings)
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
    /// holds: those past the newest `keeping`, and those whose own recorded
    /// thumbnail retention window has run out by `now`. A replay senses the
    /// real screen, and its journal is never opened again once it quits, so
    /// retention can never age the thumbnails and recognized text inside it
    /// and the whole directory goes at that window instead. The window is each
    /// directory's own (`recordSettings`), never the sweeping launch's, so a
    /// check with settings of its own never governs how long another run's
    /// captured screen content is kept; a directory that records none is swept
    /// at the default window. The journal replays shared before they had a
    /// directory each goes the same way (`sweepSharedReplay`); anything else in
    /// `root` is left alone.
    ///
    /// Newest, and expired, are both measured by `lastWritten`, so a lane that
    /// ran all day and quit a moment ago is still one of the newest and is
    /// still readable. Its creation date would say it was older than its own
    /// window and take it away the instant it quit, which is the opposite of
    /// what `keptFinishedLaunches` is for.
    public static func pruneFinishedLaunches(in root: URL, keeping: Int, now: Date) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        var finished: [(url: URL, written: Date, expired: Bool, lock: DataDirectoryLock)] = []
        for name in names where isLaunchName(name) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let lock = try? DataDirectoryLock.acquire(in: url, pid: nil, create: false) else { continue }
            let written = lastWritten(Journal.defaultURL(in: url))
            let window = SettingsStore(url: SettingsStore.defaultURL(in: url)).load().thumbnailRetention
            finished.append((url, written, written < now.addingTimeInterval(-window), lock))
        }
        for (index, entry) in finished.sorted(by: { $0.written > $1.written }).enumerated()
        where index >= keeping || entry.expired {
            try? manager.removeItem(at: entry.url)
        }
        sweepSharedReplay(in: root, now: now)
    }

    /// When a replay's journal was last written, which bounds how new anything
    /// inside it can be. `.distantPast` when there is none to read, so a
    /// directory holding no journal at all is swept rather than kept forever,
    /// and a sidecar that is not there counts as long past rather than recent.
    private static func lastWritten(_ journal: URL) -> Date {
        (try? journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Removes the journal every replay shared before replays had a directory
    /// each, which sat directly in `root`, once everything in it is past the
    /// window the `settings.json` beside it recorded. Nothing opens that
    /// journal any more, so retention can no longer age its thumbnails and
    /// recognized text in place either, and an upgrade would otherwise leave
    /// captures of the real screen on disk with nothing to expire them.
    ///
    /// The age is `lastWritten`, not when the journal was made: it bounds how
    /// new anything inside can be, where the creation date would delete
    /// content still inside its window.
    ///
    /// A hold is not enough on its own here, because the builds that wrote
    /// this journal took none: one of them may be running from another
    /// checkout on this Mac right now with the journal open, and a Mac that
    /// slept would leave it looking untouched for longer than the window. So
    /// the `-wal` and `-shm` files beside it have to be past the window too.
    /// In WAL mode a write lands in `-wal` without touching the journal, and
    /// `-shm` is rewritten alongside it, so those two are what say a build is
    /// still using this journal. Their absence says the same thing: Mentor
    /// never closes its connection, so SQLite leaves both behind on every
    /// quit, and asking only whether `-shm` is there would skip for ever.
    private static func sweepSharedReplay(in root: URL, now: Date) {
        let manager = FileManager.default
        let journal = Journal.defaultURL(in: root)
        let settings = SettingsStore.defaultURL(in: root)
        guard manager.fileExists(atPath: journal.path) else { return }
        let window = SettingsStore(url: settings).load().thumbnailRetention
        let expired = now.addingTimeInterval(-window)
        let sidecars = ["-wal", "-shm"].map { URL(fileURLWithPath: journal.path + $0) }
        guard ([journal] + sidecars).allSatisfy({ lastWritten($0) < expired }) else { return }
        for url in [journal] + sidecars + [settings] {
            try? manager.removeItem(at: url)
        }
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
    /// this runs before `Journal` opens, and a replay's directory is always
    /// one this launch is making, so it is what decides the mode.
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

/// What a launch tells whoever started it, on the one line `scripts/launch.sh`
/// waits for before it writes a pid file. Every reason a lane is not up has to
/// arrive here rather than look like one, which is why the journal is part of
/// the question: a lane whose journal did not open never starts its sensing
/// pipeline, never positions its replay clock, and journals no event, so a
/// check that took its pid would wait on a lane that can never answer.
///
/// `started` goes to stdout and `didNotStart` to stderr, both unbuffered,
/// since stdout to a file is not line buffered.
public enum LaunchReport: Equatable, Sendable {
    case started(pid: Int32, dataDirectory: URL)
    case didNotStart(String)

    /// How the app says a lane is not up. `scripts/launch.sh` waits on this,
    /// so it is the app's own word rather than merely something on stderr,
    /// which carries framework diagnostics too.
    public static let didNotStartMarker = "Mentor did not start: "

    /// What a launch is once `AppState.start` has returned: up, unless the
    /// journal it has to write is unopenable.
    public init(pid: Int32, dataDirectory: URL, journalError: String?) {
        self = journalError.map { .didNotStart($0) } ?? .started(pid: pid, dataDirectory: dataDirectory)
    }

    /// The line itself, newline included. The started line ends in the data
    /// directory this launch made, and nothing follows it, so a reader takes
    /// everything past the first ` in ` and needs no quoting however the path
    /// is spelled. That is how a script learns where the journal is now that
    /// nothing can name it beforehand.
    public var line: String {
        switch self {
        case .started(let pid, let directory): "Mentor started: pid \(pid) in \(directory.path)\n"
        case .didNotStart(let reason): "\(LaunchReport.didNotStartMarker)\(reason)\n"
        }
    }
}
