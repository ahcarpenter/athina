import Darwin
import Foundation
import Testing
@testable import MentorCore

/// A directory of this test's own, which nothing else in the run touches.
private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mentor-files-\(UUID().uuidString)", isDirectory: true)
}

/// A per-launch directory left behind by a replay that has quit, holding a
/// journal last written at `written`, and the retention window that launch ran
/// with when it recorded one.
@discardableResult
private func finishedLaunch(
    _ name: String, in support: URL, written: Date, recording window: TimeInterval? = nil
) throws -> URL {
    let files = LaunchFiles(
        arguments: ["Mentor", "--replay", "/f"],
        clientMode: .replay(directory: URL(fileURLWithPath: "/fixtures"), allowStale: false),
        supportDirectory: support,
        launchName: name
    )
    let manager = FileManager.default
    try manager.createDirectory(at: files.dataDirectory, withIntermediateDirectories: true)
    if let window {
        var settings = SensingSettings()
        settings.thumbnailRetention = window
        files.recordSettings(settings)
    }
    let journal = Journal.defaultURL(in: files.dataDirectory)
    try Data("captured screen".utf8).write(to: journal)
    try manager.setAttributes([.modificationDate: written], ofItemAtPath: journal.path)
    return files.dataDirectory
}

/// Where a launch keeps its journal and settings: the live files for a live
/// or recording launch, whatever flags it was given, and files of its own for
/// every replay, so replays running at once never share a journal or settings.
@Suite struct LaunchFilesTests {
    private let replay = ModelClientMode.replay(directory: URL(fileURLWithPath: "/fixtures"), allowStale: false)

    // MARK: Paths

    @Test func liveAndRecordingLaunchesKeepTheLiveFiles() {
        let support = URL(fileURLWithPath: "/support/mentor", isDirectory: true)
        for mode in [ModelClientMode.live, .record(directory: URL(fileURLWithPath: "/r"))] {
            let files = LaunchFiles(arguments: ["Mentor"], clientMode: mode, supportDirectory: support)
            #expect(files.dataDirectory == support)
            #expect(!files.isPerLaunch)
            #expect(files.settingsSource == support.appendingPathComponent("settings.json"))
            #expect(!files.settingsGiven)
            #expect(files.refusals.isEmpty)
        }
    }

    @Test func theFlagsAreRefusedOutsideAReplayAndTheLiveFilesStay() {
        let support = URL(fileURLWithPath: "/support/mentor", isDirectory: true)
        let data = LaunchFiles(arguments: ["Mentor", "--data-dir", "/tmp/lane"], clientMode: .live, supportDirectory: support)
        #expect(data.refusals == ["--data-dir applies only to --replay"])
        #expect(data.dataDirectory == support)
        let settings = LaunchFiles(arguments: ["Mentor", "--settings", "/tmp/s.json"], clientMode: .record(directory: URL(fileURLWithPath: "/r")), supportDirectory: support)
        #expect(settings.refusals == ["--settings applies only to --replay"])
        #expect(settings.settingsSource == support.appendingPathComponent("settings.json"))
        #expect(!settings.settingsGiven)
        let both = LaunchFiles(arguments: ["Mentor", "--data-dir", "/tmp/lane", "--settings", "/tmp/s.json"], clientMode: .live, supportDirectory: support)
        #expect(both.refusals == ["--data-dir and --settings apply only to --replay"])
        #expect(both.dataDirectory == support)
    }

    /// With no flag every replay launch gets a directory of its own, named
    /// for its pid, inside the replay root.
    @Test func eachReplayLaunchGetsItsOwnDirectory() {
        let support = URL(fileURLWithPath: "/support/mentor", isDirectory: true)
        let files = LaunchFiles(arguments: ["Mentor", "--replay", "/fixtures"], clientMode: replay, supportDirectory: support, launchName: "launch-7-0123abcd")
        #expect(files.dataDirectory == support.appendingPathComponent("replay/launch-7-0123abcd", isDirectory: true))
        #expect(files.isPerLaunch)
        #expect(files.settingsSource == support.appendingPathComponent("settings.json"))
        #expect(files.refusals.isEmpty)

        let first = LaunchFiles(arguments: ["Mentor", "--replay", "/fixtures"], clientMode: replay, supportDirectory: support)
        let second = LaunchFiles(arguments: ["Mentor", "--replay", "/fixtures"], clientMode: replay, supportDirectory: support)
        #expect(first.dataDirectory != second.dataDirectory)
        #expect(LaunchFiles.isLaunchName(first.dataDirectory.lastPathComponent))
        #expect(first.dataDirectory.lastPathComponent.hasPrefix("launch-\(getpid())-"))

        let refused = LaunchFiles(arguments: ["Mentor", "--record", "--replay", "/f"], clientMode: .invalid("--record and --replay cannot be combined"), supportDirectory: support)
        #expect(refused.isPerLaunch)
        #expect(refused.dataDirectory.deletingLastPathComponent() == AppPaths.replayRoot(in: support))
    }

    @Test func aGivenDataDirectoryAndSettingsFileAreUsedAsGiven() {
        let files = LaunchFiles(
            arguments: ["Mentor", "--replay", "/f", "--data-dir", "~/lanes/a", "--settings", "/tmp/check/../settings.json"],
            clientMode: replay, supportDirectory: URL(fileURLWithPath: "/support/mentor")
        )
        #expect(files.dataDirectory == URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("lanes/a", isDirectory: true))
        #expect(!files.isPerLaunch)
        #expect(files.settingsSource.path == "/tmp/settings.json")
        #expect(files.settingsGiven)
        #expect(files.store.url == files.dataDirectory.appendingPathComponent("settings.json"))
        #expect(files.refusals.isEmpty)
    }

    @Test(arguments: [["--data-dir"], ["--data-dir", "--settings"], ["--data-dir", ""]])
    func aDataDirectoryFlagWithNoValueIsRefusedAndTheLaunchGetsItsOwn(flag: [String]) {
        let files = LaunchFiles(arguments: ["Mentor", "--replay", "/f"] + flag, clientMode: replay, supportDirectory: URL(fileURLWithPath: "/s"))
        #expect(files.refusals.first == "--data-dir needs a directory")
        #expect(files.isPerLaunch)
    }

    @Test func aSettingsFlagWithNoValueIsRefusedAndTheLiveSettingsStay() {
        let files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--settings"], clientMode: replay, supportDirectory: URL(fileURLWithPath: "/s"))
        #expect(files.refusals == ["--settings needs a settings file"])
        #expect(!files.settingsGiven)
        #expect(files.settingsSource.path == "/s/settings.json")
    }

    // MARK: Settings

    /// A replay started from a settings file of its own reads it and never
    /// writes it, and the live settings file is not read at all.
    @Test func aReplayStartsFromAGivenSettingsFileAndNeverWritesIt() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        var live = SensingSettings()
        live.excludedBundleIDs.append("com.apple.MobileSMS")
        try SettingsStore(url: SettingsStore.defaultURL(in: support)).save(live)
        let liveBytes = try Data(contentsOf: SettingsStore.defaultURL(in: support))

        var check = SensingSettings()
        check.excludedBundleIDs.append("com.github.wez.wezterm")
        check.idleThreshold = 900
        let checkURL = root.appendingPathComponent("check-settings.json")
        try SettingsStore(url: checkURL).save(check)
        let checkBytes = try Data(contentsOf: checkURL)

        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--settings", checkURL.path], clientMode: replay, supportDirectory: support)
        var settings = files.loadSettings(supportDirectory: support)
        #expect(settings == check.validated())
        #expect(files.refusals.isEmpty)

        settings.idleThreshold = 120
        try files.store.save(settings)
        #expect(files.store.url != checkURL)
        #expect(try Data(contentsOf: checkURL) == checkBytes)
        #expect(try Data(contentsOf: SettingsStore.defaultURL(in: support)) == liveBytes)
    }

    /// `--settings` is read and never written, so the one file it may not name
    /// is the one this launch saves its own settings to: the launch records
    /// them there as it starts and again when it quits, so the next run of the
    /// same check would start from whatever the last one changed.
    @Test func aSettingsFileInsideTheDataDirectoryRefusesToStart() throws {
        let support = scratch()
        let lane = scratch()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: lane)
        }
        // Owner-only, so it is the settings file that decides this launch.
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var check = SensingSettings()
        check.idleThreshold = 900
        let given = SettingsStore.defaultURL(in: lane)
        try SettingsStore(url: given).save(check)
        let bytes = try Data(contentsOf: given)

        var files = LaunchFiles(
            arguments: ["Mentor", "--replay", "/f", "--data-dir", lane.path, "--settings", given.path],
            clientMode: replay, supportDirectory: support
        )
        guard case .refusedToStart(let reason) = files.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("a replay was allowed to start from the file it writes")
            return
        }
        #expect(reason.contains(LaunchFiles.settingsFlag))
        #expect(reason.contains(given.path))
        #expect(files.refusals == [reason])
        // The launch never ran, so the file it was given is exactly as it was.
        #expect(try Data(contentsOf: given) == bytes)
        #expect(!FileManager.default.fileExists(atPath: lane.appendingPathComponent(DataDirectoryLock.fileName).path))
    }

    /// A settings file that is not there at all is refused, and the replay
    /// starts from the live settings, so excluded apps stay excluded, rather
    /// than from the defaults a silent fallback would give.
    @Test func aSettingsFileThatIsNotThereLeavesTheReplayOnTheLiveSettings() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        var live = SensingSettings()
        live.excludedBundleIDs.append("com.apple.MobileSMS")
        try SettingsStore(url: SettingsStore.defaultURL(in: support)).save(live)
        let given = root.appendingPathComponent("given.json")

        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--settings", given.path], clientMode: replay, supportDirectory: support)
        let settings = files.loadSettings(supportDirectory: support)
        #expect(settings.isExcluded(bundleID: "com.apple.MobileSMS"))
        #expect(files.refusals.count == 1)
        #expect(files.refusals.first?.hasPrefix("--settings could not use \(given.path)") == true)
        #expect(!files.settingsGiven)
        #expect(files.settingsSource == SettingsStore.defaultURL(in: support))
        // It still starts: the live settings are a base a replay may run on.
        guard case .held(let lock) = files.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("a replay was refused over a settings file that was not there")
            return
        }
        _ = lock
    }

    /// A settings file that is there but is not settings stops the launch. A
    /// check names a file it generated; if that file came out truncated, a
    /// replay that carried on would run on the owner's live thresholds,
    /// contexts and retention and could report a pass on settings it never
    /// chose, which is the one silent success left in these flags.
    @Test(arguments: ["not settings at all", "{\"idleThreshold\": ", ""])
    func aSettingsFileThatIsNotSettingsRefusesToStart(content: String) throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        var live = SensingSettings()
        live.excludedBundleIDs.append("com.apple.MobileSMS")
        try SettingsStore(url: SettingsStore.defaultURL(in: support)).save(live)
        let liveBytes = try Data(contentsOf: SettingsStore.defaultURL(in: support))
        let given = root.appendingPathComponent("given.json")
        try Data(content.utf8).write(to: given)

        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--settings", given.path], clientMode: replay, supportDirectory: support)
        _ = files.loadSettings(supportDirectory: support)
        guard case .refusedToStart(let reason) = files.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("a replay started from a file that is not settings")
            return
        }
        #expect(reason.hasPrefix("--settings could not use \(given.path)"))
        #expect(files.unusableSettings == reason)
        #expect(files.refusals == [reason])
        // Nothing of the refused launch reached the live settings or the disk.
        #expect(try Data(contentsOf: SettingsStore.defaultURL(in: support)) == liveBytes)
        #expect(try Data(contentsOf: given) == Data(content.utf8))
        #expect(!FileManager.default.fileExists(atPath: AppPaths.replayRoot(in: support).path))
    }

    // MARK: Holding a data directory

    @Test func aDataDirectoryIsHeldByOneProcessAtATimeAndLetGoOnRelease() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock: DataDirectoryLock? = try DataDirectoryLock.acquire(in: directory, pid: 4242)
        let pidFile = directory.appendingPathComponent(DataDirectoryLock.fileName)
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "4242\n")
        // The hold is taken before the journal opens, so it is what makes the
        // directory owner-only that the privacy model promises.
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o700)
        // flock holds per open file, so a second open in this process is refused like another process would be.
        #expect(throws: DataDirectoryLock.Failure.inUse(pid: 4242)) { try DataDirectoryLock.acquire(in: directory, pid: 99) }
        #expect(throws: DataDirectoryLock.Failure.inUse(pid: 4242)) { try DataDirectoryLock.acquire(in: directory, pid: nil) }
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "4242\n")
        _ = lock
        lock = nil

        // A check leaves the pid as it was.
        _ = try DataDirectoryLock.acquire(in: directory, pid: nil)
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "4242\n")
        let next = try DataDirectoryLock.acquire(in: directory, pid: 7)
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "7\n")
        _ = next
    }

    @Test func aLiveLaunchHoldsNothing() {
        var files = LaunchFiles(arguments: ["Mentor"], clientMode: .live, supportDirectory: scratch())
        guard case .notNeeded = files.claim(clientMode: .live) else {
            Issue.record("a live launch claimed a directory")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: files.dataDirectory.path))
    }

    /// A replay given a directory another replay holds does not start at all,
    /// and never quietly writes somewhere else: the flag exists so the caller
    /// knows which journal to read, and the harness reads exactly that path.
    @Test func aReplayGivenADirectoryAnotherReplayHoldsRefusesToStart() {
        let support = scratch()
        let lanes = scratch()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: lanes)
        }
        let lane = lanes.appendingPathComponent("lane", isDirectory: true)
        let arguments = ["Mentor", "--replay", "/f", "--data-dir", lane.path]

        var first = LaunchFiles(arguments: arguments, clientMode: replay, supportDirectory: support)
        guard case .held(let lock) = first.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("the first replay did not take its directory")
            return
        }
        #expect(first.dataDirectory == lane)
        #expect(first.refusals.isEmpty)

        var second = LaunchFiles(arguments: arguments, clientMode: replay, supportDirectory: support)
        guard case .refusedToStart(let reason) = second.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("the second replay was allowed to start")
            return
        }
        #expect(reason == "--data-dir \(lane.path) is in use by another Mentor (pid \(getpid()))")
        #expect(second.dataDirectory == lane)
        #expect(!second.isPerLaunch)
        #expect(second.refusals == [reason])
        // Nothing of the second launch reached the directory the first holds.
        #expect(try! FileManager.default.contentsOfDirectory(atPath: lane.path) == [DataDirectoryLock.fileName])
        #expect(!FileManager.default.fileExists(atPath: AppPaths.replayRoot(in: support).path))
        _ = lock
    }

    /// Nothing a replay does may reach the live journal or the live settings,
    /// so the one directory `--data-dir` may never name is the live data
    /// folder, however it is spelled. The replay root inside it is what
    /// replays are for, so a lane under it still starts.
    /// A journal holds thumbnails and recognized text from the real screen, so
    /// it never goes in a directory anyone but its owner can reach into. A
    /// directory the operator named is never chmodded, since it can be a home
    /// or a folder shared on purpose: the launch stops instead and says so.
    @Test(arguments: [0o750, 0o705, 0o755, 0o770, 0o707])
    func aReplayGivenADataDirectoryOthersCanReachRefusesToStart(mode: Int) throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let lane = root.appendingPathComponent("lane", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: lane, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: lane.path)

        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--data-dir", lane.path], clientMode: replay, supportDirectory: support)
        guard case .refusedToStart(let reason) = files.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("a replay was allowed to write its journal into a \(String(mode, radix: 8)) directory")
            return
        }
        #expect(reason.contains(lane.path))
        #expect(reason.contains(String(format: "%03o", mode)))
        #expect(files.refusals == [reason])
        // The refused launch neither wrote in it nor changed what it found.
        #expect(try manager.contentsOfDirectory(atPath: lane.path).isEmpty)
        let after = try #require(manager.attributesOfItem(atPath: lane.path)[.posixPermissions] as? NSNumber)
        #expect(after.int16Value == Int16(mode))
    }

    /// The owner-only cases: a directory that is already owner-only is used as
    /// it is, and one that is not there yet is made owner-only here.
    @Test func aDataDirectoryThatIsOwnerOnlyOrNotThereYetStarts() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let manager = FileManager.default
        let existing = root.appendingPathComponent("existing", isDirectory: true)
        try manager.createDirectory(at: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)

        for lane in [existing, fresh] {
            var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--data-dir", lane.path], clientMode: replay, supportDirectory: support)
            guard case .held(let lock) = files.claim(clientMode: replay, supportDirectory: support) else {
                Issue.record("a replay was refused the owner-only directory \(lane.path)")
                continue
            }
            let mode = try #require(manager.attributesOfItem(atPath: lane.path)[.posixPermissions] as? NSNumber)
            #expect(mode.int16Value == 0o700)
            _ = lock
        }
    }

    @Test func aReplayGivenTheLiveDataFolderRefusesToStart() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("mentor", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked-mentor", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: support)

        func claimed(_ path: String) -> LaunchFiles.Claim {
            var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--data-dir", path], clientMode: replay, supportDirectory: support)
            return files.claim(clientMode: replay, supportDirectory: support)
        }

        // The folder itself, spelled four ways, and something inside it.
        for path in [
            support.path,
            support.path + "/",
            support.path.uppercased(),
            linked.path,
            support.appendingPathComponent("recordings").path,
            linked.appendingPathComponent("recordings").path,
        ] {
            guard case .refusedToStart(let reason) = claimed(path) else {
                Issue.record("a replay was allowed to use \(path)")
                continue
            }
            #expect(reason.contains(LaunchFiles.dataDirectoryFlag))
            #expect(reason.contains(support.path))
        }
        // Nothing of any refused launch reached the live folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)

        // The replay root and a lane under it are what a replay's files are for,
        // and are how scripts/e2e names the directory it reads.
        for path in [AppPaths.replayRoot(in: support).path, AppPaths.replayRoot(in: support).appendingPathComponent("lane-a").path] {
            guard case .held(let lock) = claimed(path) else {
                Issue.record("a replay was refused \(path)")
                continue
            }
            _ = lock
        }
    }

    /// A replay that makes its own directory still starts, and the claim
    /// gives it the lock that keeps it its own.
    @Test func aReplayWithNoDataDirectoryTakesItsOwnAndStarts() {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f"], clientMode: replay, supportDirectory: support)
        guard case .held(let lock) = files.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("a per-launch replay did not take its directory")
            return
        }
        #expect(files.refusals.isEmpty)
        #expect(FileManager.default.fileExists(atPath: files.dataDirectory.appendingPathComponent(DataDirectoryLock.fileName).path))
        _ = lock
    }

    /// A replay launch removes finished per-launch directories past the
    /// newest few, and never one a running replay holds or anything else.
    @Test func finishedLaunchesPastTheNewestFewArePruned() throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        var names: [String] = []
        for index in 0..<5 {
            let name = String(format: "launch-%d-%08x", 100 + index, index)
            try finishedLaunch(name, in: support, written: base + Double(index) * 60)
            names.append(name)
        }
        // The oldest is still running, and a directory someone named is left alone.
        let running = try DataDirectoryLock.acquire(in: root.appendingPathComponent(names[0], isDirectory: true), pid: 100)
        try manager.createDirectory(at: root.appendingPathComponent("my-lane", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("journal.sqlite"))

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: 2, now: base + 300)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        #expect(left == [names[0], names[3], names[4], "my-lane", "journal.sqlite"])
        _ = running
    }

    /// A finished replay's journal is never opened again, so retention can
    /// never age the thumbnails and recognized text it captured from the real
    /// screen: a directory past the retention window goes even when the count
    /// alone would have kept it, and one a running replay holds still does not.
    @Test func finishedLaunchesPastTheRetentionWindowArePruned() throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let ages: [TimeInterval] = [7 * 3600, 5 * 3600, 30 * 86400]
        var names: [String] = []
        for (index, age) in ages.enumerated() {
            let name = String(format: "launch-%d-%08x", 200 + index, index)
            try finishedLaunch(name, in: support, written: now - age)
            names.append(name)
        }
        // The oldest of all is still running, so nothing may touch it.
        let running = try DataDirectoryLock.acquire(in: root.appendingPathComponent(names[2], isDirectory: true), pid: 200)

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        #expect(left == [names[1], names[2]])
        _ = running
    }

    /// Whose retention applies never depends on which lane starts next: each
    /// finished directory is swept by the window recorded in it by the launch
    /// that captured its screen content, and one that recorded none by the
    /// documented default.
    @Test func eachFinishedLaunchIsPrunedByItsOwnRecordedWindow() throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)

        // A day since it was last written: gone under an hour's window, kept
        // under a week's.
        try finishedLaunch("launch-301-0000000a", in: support, written: now - 86400, recording: 3600)
        try finishedLaunch("launch-302-0000000b", in: support, written: now - 86400, recording: 7 * 86400)
        // No record of its own, so the documented 6 hour default applies.
        try finishedLaunch("launch-303-0000000c", in: support, written: now - 86400)
        try finishedLaunch("launch-304-0000000d", in: support, written: now - 3600)

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        #expect(left == ["launch-302-0000000b", "launch-304-0000000d"])
    }

    /// How long a finished directory has held its captures is how long ago its
    /// journal was last written, not how long ago the directory was made: a
    /// lane that ran all day and quit a moment ago is one of the newest
    /// finished launches and stays readable, which is what keeping them is for.
    @Test func aLaneThatRanAllDayAndJustQuitIsStillReadable() throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)

        // Both ran nine hours, past the six hour default window. One was quit
        // five minutes ago, the other nine hours ago.
        let justQuit = try finishedLaunch("launch-401-0000000a", in: support, written: now - 300)
        let longGone = try finishedLaunch("launch-402-0000000b", in: support, written: now - 9 * 3600)
        for url in [justQuit, longGone] {
            try manager.setAttributes([.creationDate: now - 9 * 3600], ofItemAtPath: url.path)
        }

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        #expect(left == ["launch-401-0000000a"])
    }

    /// The journal every replay shared before replays had a directory each
    /// holds captures of the real screen and is never opened again, so nothing
    /// ages it in place: a replay launch sweeps it once it has gone unwritten
    /// for longer than the window recorded beside it, and leaves it alone
    /// while it is still inside that window.
    @Test(arguments: [(TimeInterval(86400), false), (TimeInterval(3600), true)])
    func theSharedReplayJournalIsSweptOnceItIsPastItsWindow(age: TimeInterval, survives: Bool) throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        var settings = SensingSettings()
        settings.thumbnailRetention = 6 * 3600
        try SettingsStore(url: SettingsStore.defaultURL(in: root)).save(settings)
        let journal = Journal.defaultURL(in: root)
        for name in [journal.lastPathComponent, journal.lastPathComponent + "-wal"] {
            let url = root.appendingPathComponent(name)
            try Data("captured screen".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: now - age], ofItemAtPath: url.path)
        }

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        if survives {
            #expect(left == ["journal.sqlite", "journal.sqlite-wal", "settings.json"])
        } else {
            #expect(left.isEmpty)
        }
    }

    /// The builds that wrote that shared journal took no hold on it, so one of
    /// them running from another checkout is invisible to the sweep, and in WAL
    /// mode its writes land in `-wal` and `-shm` without touching the journal.
    /// Those two therefore hold the sweep off while either was written inside
    /// the window, and stop holding it off once both are past it: Mentor never
    /// closes its connection, so SQLite leaves both behind on every quit, and
    /// a sweep that skipped merely because `-shm` is there would never run.
    @Test(arguments: [
        (TimeInterval(60), true),
        (TimeInterval(30 * 86400), false),
    ])
    func theSharedReplayJournalWaitsOnItsSidecarsOnlyWhileTheyAreFresh(sidecarAge: TimeInterval, survives: Bool) throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        // The journal itself is long past the six hour default window, so only
        // the sidecars decide.
        let journal = Journal.defaultURL(in: root)
        try Data("captured screen".utf8).write(to: journal)
        try manager.setAttributes([.modificationDate: now - 30 * 86400], ofItemAtPath: journal.path)
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: journal.path + suffix)
            try Data("captured screen".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: now - sidecarAge], ofItemAtPath: url.path)
        }

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        if survives {
            #expect(left == ["journal.sqlite", "journal.sqlite-wal", "journal.sqlite-shm"])
        } else {
            #expect(left.isEmpty)
        }
    }

    /// A write in WAL mode lands in `-wal` without touching the journal, so a
    /// journal that looks long unwritten beside a `-wal` written moments ago is
    /// one a build is still using, and nothing is removed.
    @Test func theSharedReplayJournalIsLeftAloneWhileItsWalWasJustWritten() throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let journal = Journal.defaultURL(in: root)
        try Data("captured screen".utf8).write(to: journal)
        try manager.setAttributes([.modificationDate: now - 30 * 86400], ofItemAtPath: journal.path)
        let wal = URL(fileURLWithPath: journal.path + "-wal")
        try Data("captured screen".utf8).write(to: wal)
        try manager.setAttributes([.modificationDate: now - 60], ofItemAtPath: wal.path)

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        #expect(Set(try manager.contentsOfDirectory(atPath: root.path))
            == ["journal.sqlite", "journal.sqlite-wal"])
    }

    /// The end-to-end harness hands a replay the replay root itself as its
    /// `--data-dir`, so while a replay holds it those files are its own and the
    /// sweep must not touch them, however old they look.
    @Test func theSharedReplayJournalIsLeftAloneWhileAReplayHoldsTheRoot() throws {
        let support = scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_789_000_000)

        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--data-dir", root.path], clientMode: replay, supportDirectory: support)
        guard case .held(let lock) = files.claim(clientMode: replay, supportDirectory: support) else {
            Issue.record("a replay was refused the replay root")
            return
        }
        let journal = Journal.defaultURL(in: root)
        try Data("captured screen".utf8).write(to: journal)
        try manager.setAttributes([.modificationDate: now - 365 * 86400], ofItemAtPath: journal.path)

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: LaunchFiles.keptFinishedLaunches, now: now)
        #expect(manager.fileExists(atPath: journal.path))
        _ = lock
    }
}

/// Moving a replay's clock from another process.
@Suite struct ClockRemoteTests {
    @Test func onlyAReplayListens() {
        #expect(ClockRemote.listens(in: .replay(scale: 60, ahead: 0)))
        #expect(ClockRemote.listens(in: .replay(scale: 1, ahead: 0, refusal: "--time-scale needs a number from 1 to 100")))
        #expect(!ClockRemote.listens(in: .system))
        #expect(!ClockRemote.listens(in: .refused("--time-scale applies only to --replay")))
        #expect(ClockRemote.object(for: 4242) == "4242")
    }

    @Test func aRequestTakesTheIntervalsTheAdvanceFieldTakes() {
        #expect(ClockRemote.seconds(from: [ClockRemote.intervalKey: "15m"]) == .success(900))
        #expect(ClockRemote.seconds(from: [ClockRemote.intervalKey: "1d12h"]) == .success(129_600))
    }

    @Test(arguments: ["soon", "0", "-5m", "31d", ""])
    func aRequestWithNoUsableIntervalIsRefused(text: String) {
        guard case .failure = ClockRemote.seconds(from: [ClockRemote.intervalKey: text]) else {
            Issue.record("accepted \(text)")
            return
        }
    }

    /// A request names a file to answer at, so a script can tell a clock that
    /// moved from a post nobody heard. A relative path is not resolved: the
    /// app's working directory is `/` when it was started with `open`.
    @Test func aRequestCarriesWhereToAnswer() {
        #expect(ClockRemote.replyURL(from: [ClockRemote.replyKey: "/tmp/reply.json"])?.path == "/tmp/reply.json")
        #expect(ClockRemote.replyURL(from: [ClockRemote.intervalKey: "15m"]) == nil)
        #expect(ClockRemote.replyURL(from: [ClockRemote.replyKey: "reply.json"]) == nil)
        #expect(ClockRemote.replyURL(from: nil) == nil)
    }

    /// The answer is written whole or not at all, and says what the clock did,
    /// so the waiting script never reads half a file and never has to guess.
    @Test func anAnswerRoundTripsThroughTheFileItNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let support = scratch()
        let url = directory.appendingPathComponent("reply.json")
        let now = Date(timeIntervalSince1970: 1_789_473_600)

        let moved = ClockRemote.Reply(moved: true, movedAhead: 9000, now: now, pid: 4242)
        try ClockRemote.answer(moved, at: url, temporaryDirectory: directory, supportDirectory: support)
        #expect(try ClockRemote.Reply.decode(Data(contentsOf: url)) == moved)

        let refused = ClockRemote.Reply(moved: false, reason: "this launch has no replay clock", movedAhead: 0, now: now, pid: 7)
        let second = directory.appendingPathComponent("second.json")
        try ClockRemote.answer(refused, at: second, temporaryDirectory: directory, supportDirectory: support)
        #expect(try ClockRemote.Reply.decode(Data(contentsOf: second)) == refused)

        // A request that named no file is answered nowhere, and says so by not throwing.
        try ClockRemote.answer(moved, at: nil, temporaryDirectory: directory, supportDirectory: support)
    }

    /// Nothing authenticates the channel, so a request must never be able to
    /// make the replay create or replace a file of the sender's choosing: the
    /// answer goes to a new file in the temporary directory or nowhere.
    @Test func aRequestIsNotAnsweredWhereItCouldClobberAFile() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let support = root.appendingPathComponent("mentor", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let reply = ClockRemote.Reply(moved: true, movedAhead: 900, now: Date(timeIntervalSince1970: 1_789_473_600), pid: 11)

        func answer(at url: URL) throws {
            try ClockRemote.answer(reply, at: url, temporaryDirectory: temporary, supportDirectory: support)
        }

        // The live settings, named outright and by a path that only resolves there.
        let settings = SettingsStore.defaultURL(in: support)
        try Data("{\"idleThreshold\":900}".utf8).write(to: settings)
        #expect(throws: ClockRemote.Refusal.self) { try answer(at: settings) }
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("aimed"), withDestinationURL: settings)
        #expect(throws: ClockRemote.Refusal.self) { try answer(at: temporary.appendingPathComponent("aimed")) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{\"idleThreshold\":900}")

        // Anywhere else outside the temporary directory, and a file that is already there.
        #expect(throws: ClockRemote.Refusal.self) { try answer(at: root.appendingPathComponent("elsewhere.json")) }
        let taken = temporary.appendingPathComponent("taken.json")
        try Data("mine".utf8).write(to: taken)
        #expect(throws: ClockRemote.Refusal.self) { try answer(at: taken) }
        #expect(try String(contentsOf: taken, encoding: .utf8) == "mine")

        // The fresh path under the temporary directory that advance-clock.sh names.
        let fresh = temporary.appendingPathComponent("mentor-clock-abcd1234")
        try answer(at: fresh)
        #expect(try ClockRemote.Reply.decode(Data(contentsOf: fresh)) == reply)
    }

    @Test func aRequestWithNoIntervalIsRefused() {
        #expect(ClockRemote.seconds(from: nil) == .failure(ClockRemote.Refusal(reason: "no interval in the request")))
        #expect(ClockRemote.seconds(from: [:]) == .failure(ClockRemote.Refusal(reason: "no interval in the request")))
        #expect(ClockRemote.seconds(from: [ClockRemote.intervalKey: 900]) == .failure(ClockRemote.Refusal(reason: "no interval in the request")))
    }
}
