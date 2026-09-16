import Darwin
import Foundation
import Testing
@testable import MentorCore

/// Where a launch keeps its journal and settings: the live files for a live
/// or recording launch, whatever flags it was given, and files of its own for
/// every replay, so replays running at once never share a journal or settings.
@Suite struct LaunchFilesTests {
    private let replay = ModelClientMode.replay(directory: URL(fileURLWithPath: "/fixtures"), allowStale: false)

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mentor-files-\(UUID().uuidString)", isDirectory: true)
    }

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
        let root = Self.scratch()
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

    /// A settings file that is missing or is not settings is refused, and the
    /// replay starts from the live settings, so excluded apps stay excluded,
    /// rather than from the defaults a silent fallback would give.
    @Test(arguments: ["missing", "garbage"])
    func anUnusableSettingsFileIsRefusedAndTheReplayStartsFromTheLiveSettings(kind: String) throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        var live = SensingSettings()
        live.excludedBundleIDs.append("com.apple.MobileSMS")
        try SettingsStore(url: SettingsStore.defaultURL(in: support)).save(live)
        let given = root.appendingPathComponent("given.json")
        if kind == "garbage" { try Data("not settings".utf8).write(to: given) }

        var files = LaunchFiles(arguments: ["Mentor", "--replay", "/f", "--settings", given.path], clientMode: replay, supportDirectory: support)
        let settings = files.loadSettings(supportDirectory: support)
        #expect(settings.isExcluded(bundleID: "com.apple.MobileSMS"))
        #expect(files.refusals.count == 1)
        #expect(files.refusals.first?.hasPrefix("--settings could not use \(given.path)") == true)
        #expect(!files.settingsGiven)
        #expect(files.settingsSource == SettingsStore.defaultURL(in: support))
    }

    // MARK: Holding a data directory

    @Test func aDataDirectoryIsHeldByOneProcessAtATimeAndLetGoOnRelease() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock: DataDirectoryLock? = try DataDirectoryLock.acquire(in: directory, pid: 4242)
        let pidFile = directory.appendingPathComponent(DataDirectoryLock.fileName)
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "4242\n")
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
        var files = LaunchFiles(arguments: ["Mentor"], clientMode: .live, supportDirectory: Self.scratch())
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
        let support = Self.scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let lane = support.appendingPathComponent("lane", isDirectory: true)
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

    /// A replay that makes its own directory still starts, and the claim
    /// gives it the lock that keeps it its own.
    @Test func aReplayWithNoDataDirectoryTakesItsOwnAndStarts() {
        let support = Self.scratch()
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
        let support = Self.scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = AppPaths.replayRoot(in: support)
        let manager = FileManager.default
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        var names: [String] = []
        for index in 0..<5 {
            let name = String(format: "launch-%d-%08x", 100 + index, index)
            let url = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try manager.setAttributes([.creationDate: base + Double(index) * 60], ofItemAtPath: url.path)
            names.append(name)
        }
        // The oldest is still running, and a directory someone named is left alone.
        let running = try DataDirectoryLock.acquire(in: root.appendingPathComponent(names[0], isDirectory: true), pid: 100)
        try manager.createDirectory(at: root.appendingPathComponent("my-lane", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("journal.sqlite"))

        LaunchFiles.pruneFinishedLaunches(in: root, keeping: 2)
        let left = Set(try manager.contentsOfDirectory(atPath: root.path))
        #expect(left == [names[0], names[3], names[4], "my-lane", "journal.sqlite"])
        _ = running
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
        let url = directory.appendingPathComponent("reply.json")
        let now = Date(timeIntervalSince1970: 1_789_473_600)

        let moved = ClockRemote.Reply(moved: true, by: 7200, movedAhead: 9000, now: now, pid: 4242)
        try ClockRemote.answer(moved, at: url)
        #expect(try ClockRemote.Reply.decode(Data(contentsOf: url)) == moved)
        #expect(moved.summary.contains("pid 4242 moved its clock ahead 2h, 2h 30m in all"))

        let refused = ClockRemote.Reply(moved: false, reason: "this launch has no replay clock", movedAhead: 0, now: now, pid: 7)
        try ClockRemote.answer(refused, at: url)
        let read = try ClockRemote.Reply.decode(Data(contentsOf: url))
        #expect(read == refused)
        #expect(read.summary == "pid 7 refused: this launch has no replay clock")

        // A request that named no file is answered nowhere, and says so by not throwing.
        try ClockRemote.answer(moved, at: nil)
    }

    @Test func aRequestWithNoIntervalIsRefused() {
        #expect(ClockRemote.seconds(from: nil) == .failure(ClockRemote.Refusal(reason: "no interval in the request")))
        #expect(ClockRemote.seconds(from: [:]) == .failure(ClockRemote.Refusal(reason: "no interval in the request")))
        #expect(ClockRemote.seconds(from: [ClockRemote.intervalKey: 900]) == .failure(ClockRemote.Refusal(reason: "no interval in the request")))
    }
}
