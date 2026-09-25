import Darwin
import Foundation
import Testing

@testable import AthinaCore

/// A directory of this test's own, which nothing else in the run touches.
private func scratch() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "athina-files-\(UUID().uuidString)",
    isDirectory: true
  )
}

/// A per-launch directory left behind by a replay that has quit, holding a
/// journal last written at `written`.
@discardableResult
private func finishedLaunch(_ name: String, in support: URL, written: Date) throws -> URL {
  let files = LaunchFiles(
    arguments: ["Athina", "--replay", "/f"],
    clientMode: .replay(directory: URL(fileURLWithPath: "/fixtures"), allowStale: false),
    supportDirectory: support,
    launchName: name
  )
  let manager = FileManager.default
  try manager.createDirectory(at: files.dataDirectory, withIntermediateDirectories: true)
  let journal = Journal.defaultURL(in: files.dataDirectory)
  try Data("captured screen".utf8).write(to: journal)
  try manager.setAttributes([.modificationDate: written], ofItemAtPath: journal.path)
  return files.dataDirectory
}

/// Where a launch keeps its journal and settings: the live files for a live
/// or recording launch, whatever flags it was given, and files of its own for
/// every replay, so replays running at once never share a journal or settings.
@Suite struct LaunchFilesTests {
  private let replay = ModelClientMode.replay(
    directory: URL(fileURLWithPath: "/fixtures"),
    allowStale: false
  )

  // MARK: Paths

  @Test func liveAndRecordingLaunchesKeepTheLiveFiles() {
    let support = URL(fileURLWithPath: "/support/athina", isDirectory: true)
    for mode in [ModelClientMode.live, .record(directory: URL(fileURLWithPath: "/r"))] {
      let files = LaunchFiles(arguments: ["Athina"], clientMode: mode, supportDirectory: support)
      #expect(files.dataDirectory == support)
      #expect(files.settingsSource == support.appendingPathComponent("settings.json"))
      #expect(!files.settingsGiven)
      #expect(files.refusals.isEmpty)
    }
  }

  @Test(arguments: [ModelClientMode.live, .record(directory: URL(fileURLWithPath: "/r"))])
  func theSettingsFlagIsRefusedOutsideAReplayAndTheLiveFilesStay(mode: ModelClientMode) {
    let support = URL(fileURLWithPath: "/support/athina", isDirectory: true)
    let files = LaunchFiles(
      arguments: ["Athina", "--settings", "/tmp/s.json"],
      clientMode: mode,
      supportDirectory: support
    )
    #expect(files.refusals == ["--settings applies only to --replay"])
    #expect(files.settingsSource == support.appendingPathComponent("settings.json"))
    #expect(!files.settingsGiven)
    #expect(files.dataDirectory == support)
  }

  /// With no flag every replay launch gets a directory of its own, named
  /// for its pid, inside the replay root.
  @Test func eachReplayLaunchGetsItsOwnDirectory() {
    let support = URL(fileURLWithPath: "/support/athina", isDirectory: true)
    let files = LaunchFiles(
      arguments: ["Athina", "--replay", "/fixtures"],
      clientMode: replay,
      supportDirectory: support,
      launchName: "launch-7-0123abcd"
    )
    #expect(
      files.dataDirectory
        == support.appendingPathComponent("replay/launch-7-0123abcd", isDirectory: true)
    )
    #expect(files.settingsSource == support.appendingPathComponent("settings.json"))
    #expect(files.refusals.isEmpty)

    let first = LaunchFiles(
      arguments: ["Athina", "--replay", "/fixtures"],
      clientMode: replay,
      supportDirectory: support
    )
    let second = LaunchFiles(
      arguments: ["Athina", "--replay", "/fixtures"],
      clientMode: replay,
      supportDirectory: support
    )
    #expect(first.dataDirectory != second.dataDirectory)
    #expect(LaunchFiles.isLaunchName(first.dataDirectory.lastPathComponent))
    #expect(first.dataDirectory.lastPathComponent.hasPrefix("launch-\(getpid())-"))

    let refused = LaunchFiles(
      arguments: ["Athina", "--record", "--replay", "/f"],
      clientMode: .invalid("--record and --replay cannot be combined"),
      supportDirectory: support
    )
    #expect(refused.dataDirectory.deletingLastPathComponent() == AppPaths.replayRoot(in: support))
  }

  /// A given settings file is used as given, and the replay still keeps a
  /// directory of its own, which nothing outside the app ever names.
  @Test func aGivenSettingsFileIsUsedAsGivenAndTheReplayKeepsItsOwnDirectory() {
    let support = URL(fileURLWithPath: "/support/athina", isDirectory: true)
    let files = LaunchFiles(
      arguments: ["Athina", "--replay", "/f", "--settings", "/tmp/check/../settings.json"],
      clientMode: replay,
      supportDirectory: support,
      launchName: "launch-7-0123abcd"
    )
    #expect(files.settingsSource.path == "/tmp/settings.json")
    #expect(files.settingsGiven)
    #expect(
      files.dataDirectory
        == AppPaths.replayRoot(in: support).appendingPathComponent(
          "launch-7-0123abcd",
          isDirectory: true
        )
    )
    #expect(files.store.url == files.dataDirectory.appendingPathComponent("settings.json"))
    #expect(files.refusals.isEmpty)
  }

  @Test func aSettingsFlagWithNoValueIsRefusedAndTheLiveSettingsStay() {
    let files = LaunchFiles(
      arguments: ["Athina", "--replay", "/f", "--settings"],
      clientMode: replay,
      supportDirectory: URL(fileURLWithPath: "/s")
    )
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

    var files = LaunchFiles(
      arguments: ["Athina", "--replay", "/f", "--settings", checkURL.path],
      clientMode: replay,
      supportDirectory: support
    )
    var settings = files.loadSettings(supportDirectory: support)
    #expect(settings == check.validated())
    #expect(files.refusals.isEmpty)

    settings.idleThreshold = 120
    try files.store.save(settings)
    #expect(files.store.url != checkURL)
    #expect(try Data(contentsOf: checkURL) == checkBytes)
    #expect(try Data(contentsOf: SettingsStore.defaultURL(in: support)) == liveBytes)
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

    var files = LaunchFiles(
      arguments: ["Athina", "--replay", "/f", "--settings", given.path],
      clientMode: replay,
      supportDirectory: support
    )
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

  /// A settings file that is there but is not settings stops the launch.
  ///
  /// A check names a file it generated; if that file came out truncated, a
  /// replay that carried on would run on the owner's live thresholds, contexts
  /// and retention and could report a pass on settings it never chose, which is
  /// the one silent success left in these flags.
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

    var files = LaunchFiles(
      arguments: ["Athina", "--replay", "/f", "--settings", given.path],
      clientMode: replay,
      supportDirectory: support
    )
    _ = files.loadSettings(supportDirectory: support)
    guard
      case .refusedToStart(let reason) = files.claim(clientMode: replay, supportDirectory: support)
    else {
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
    let mode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.int16Value == 0o700)
    // flock holds per open file, so a second open in this process is refused like another process would be.
    #expect(throws: DataDirectoryLock.Failure.inUse(pid: 4242)) {
      try DataDirectoryLock.acquire(in: directory, pid: 99)
    }
    #expect(throws: DataDirectoryLock.Failure.inUse(pid: 4242)) {
      try DataDirectoryLock.acquire(in: directory, pid: nil)
    }
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
    var files = LaunchFiles(arguments: ["Athina"], clientMode: .live, supportDirectory: scratch())
    guard case .notNeeded = files.claim(clientMode: .live) else {
      Issue.record("a live launch claimed a directory")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: files.dataDirectory.path))
  }

  /// A replay that makes its own directory still starts, and the claim
  /// gives it the lock that keeps it its own.
  @Test func aReplayWithNoDataDirectoryTakesItsOwnAndStarts() {
    let support = scratch()
    defer { try? FileManager.default.removeItem(at: support) }
    var files = LaunchFiles(
      arguments: ["Athina", "--replay", "/f"],
      clientMode: replay,
      supportDirectory: support
    )
    guard case .held(let lock) = files.claim(clientMode: replay, supportDirectory: support) else {
      Issue.record("a per-launch replay did not take its directory")
      return
    }
    #expect(files.refusals.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: files.dataDirectory.appendingPathComponent(DataDirectoryLock.fileName).path
      )
    )
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
    let running = try DataDirectoryLock.acquire(
      in: root.appendingPathComponent(names[0], isDirectory: true),
      pid: 100
    )
    try manager.createDirectory(
      at: root.appendingPathComponent("my-lane", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data().write(to: root.appendingPathComponent("journal.sqlite"))

    LaunchFiles.pruneFinishedLaunches(in: root, keeping: 2, window: 6 * 3600, now: base + 300)
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
    let running = try DataDirectoryLock.acquire(
      in: root.appendingPathComponent(names[2], isDirectory: true),
      pid: 200
    )

    LaunchFiles.pruneFinishedLaunches(
      in: root,
      keeping: LaunchFiles.keptFinishedLaunches,
      window: 6 * 3600,
      now: now
    )
    let left = Set(try manager.contentsOfDirectory(atPath: root.path))
    #expect(left == [names[1], names[2]])
    _ = running
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

    LaunchFiles.pruneFinishedLaunches(
      in: root,
      keeping: LaunchFiles.keptFinishedLaunches,
      window: 6 * 3600,
      now: now
    )
    let left = Set(try manager.contentsOfDirectory(atPath: root.path))
    #expect(left == ["launch-401-0000000a"])
  }

  /// A journal writes into its `-wal` file and changes the journal file itself
  /// only when it is made and at a checkpoint, and a replay that quits leaves
  /// its writes there.
  ///
  /// A lane whose writes all landed in the `-wal` is dated by them: it stays
  /// inside the window its journal file alone is past, and it is newer than a
  /// lane last written an hour ago. A read-only read of a finished lane
  /// rewrites its `-shm` file and nothing else, so a lane last written nine
  /// hours ago and read that way a moment ago is still past the window, and
  /// never pushes out a lane written since.
  @Test func aLaneWhoseWritesAreAllInTheWalSurvivesTheSweepAndAReadOnlyReadExtendsNone()
    async throws
  {
    let support = scratch()
    defer { try? FileManager.default.removeItem(at: support) }
    let root = AppPaths.replayRoot(in: support)
    let manager = FileManager.default
    let now = Date()

    let written = root.appendingPathComponent("launch-501-0000000c", isDirectory: true)
    let writtenURL = Journal.defaultURL(in: written)
    let writtenJournal = try Journal(url: writtenURL)
    try await writtenJournal.record(Fixtures.observation(at: now))
    try manager.setAttributes([.modificationDate: now - 9 * 3600], ofItemAtPath: writtenURL.path)
    #expect(manager.fileExists(atPath: writtenURL.path + "-wal"))

    let read = root.appendingPathComponent("launch-503-0000000e", isDirectory: true)
    let readURL = Journal.defaultURL(in: read)
    let readJournal = try Journal(url: readURL)
    try await readJournal.record(Fixtures.observation(at: now - 9 * 3600))
    for suffix in ["", "-wal"] {
      try manager.setAttributes(
        [.modificationDate: now - 9 * 3600],
        ofItemAtPath: readURL.path + suffix
      )
    }
    // Where a read-only read of the finished journal leaves its mark.
    try manager.setAttributes([.modificationDate: now], ofItemAtPath: readURL.path + "-shm")

    try finishedLaunch("launch-502-0000000d", in: support, written: now - 3600)

    withExtendedLifetime((writtenJournal, readJournal)) {
      LaunchFiles.pruneFinishedLaunches(in: root, keeping: 2, window: 6 * 3600, now: now)
    }
    let left = Set(try manager.contentsOfDirectory(atPath: root.path))
    #expect(left == [written.lastPathComponent, "launch-502-0000000d"])
  }

}

/// The one line a launch writes for whoever started it, which
/// `scripts/launch.sh` turns into a pid file or a reported failure.
@Suite struct LaunchReportTests {
  /// A lane whose journal did not open never starts its sensing pipeline and
  /// never positions its replay clock, so it journals nothing and answers no
  /// check: it is a failed launch, not a started one, however well the rest
  /// of the launch went.
  @Test func aJournalThatWillNotOpenIsAFailedLaunchNotAStartedOne() {
    let lane = URL(fileURLWithPath: "/lanes/a", isDirectory: true)
    let failed = LaunchReport(
      pid: 4242,
      dataDirectory: lane,
      journalError: "Could not open the journal at /lanes/a/journal.sqlite: disk I/O error"
    )
    #expect(
      failed
        == .didNotStart("Could not open the journal at /lanes/a/journal.sqlite: disk I/O error")
    )
    // Literally, the way the started line below is. `scripts/launch.sh`
    // carries this same text by hand on the other side of a language
    // boundary, and an assertion against the constant would hold for any
    // spelling, including one the launcher would no longer recognize.
    #expect(
      failed.line
        == "Athina did not start: Could not open the journal at /lanes/a/journal.sqlite: disk I/O error\n"
    )
    #expect(failed.line.hasPrefix(LaunchReport.didNotStartMarker))

    let up = LaunchReport(pid: 4242, dataDirectory: lane, journalError: nil)
    #expect(up == .started(pid: 4242, dataDirectory: lane))
    #expect(up.line == "Athina started: pid 4242 in /lanes/a\n")
  }

  /// The started line ends in the data directory and nothing follows it, so a
  /// reader takes everything past the first ` in ` and needs no quoting: that
  /// is how `scripts/launch.sh` and the end-to-end harness learn where the
  /// journal is now that nothing can name it beforehand.
  @Test(arguments: [
    "/lanes/a", "/Users/x/My Lanes/replay/launch-7-0123abcd", "/x/in the middle/lane",
  ])
  func theStartedLineCarriesTheDataDirectoryWhateverItsPathLooksLike(path: String) {
    let line = LaunchReport.started(
      pid: 7,
      dataDirectory: URL(fileURLWithPath: path, isDirectory: true)
    ).line
    #expect(line == "Athina started: pid 7 in \(path)\n")
    // What the shell does: everything past the first " in ".
    let read = line.dropLast().range(of: " in ").map { String(line.dropLast()[$0.upperBound...]) }
    #expect(read == path)
  }

  /// Every line ends in a newline of its own, since a launcher reads them as
  /// they arrive rather than waiting for the process to end.
  @Test func everyReportIsOneWholeLine() {
    for report in [
      LaunchReport.started(pid: 7, dataDirectory: URL(fileURLWithPath: "/lanes/b")),
      .didNotStart("a reason"),
    ] {
      #expect(report.line.hasSuffix("\n"))
      #expect(report.line.dropLast().contains("\n") == false)
    }
  }
}

/// Moving a replay's clock from another process.
@Suite struct ClockRemoteTests {
  @Test func onlyAReplayListens() {
    #expect(ClockRemote.listens(in: .replay(scale: 60, ahead: 0)))
    #expect(
      ClockRemote.listens(
        in: .replay(scale: 1, ahead: 0, refusal: "--time-scale needs a number from 1 to 100")
      )
    )
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
  /// moved from a post nobody heard.
  ///
  /// A relative path is not resolved: the app's working directory is `/` when
  /// it was started with `open`.
  @Test func aRequestCarriesWhereToAnswer() {
    #expect(
      ClockRemote.replyURL(from: [ClockRemote.replyKey: "/tmp/reply.json"])?.path
        == "/tmp/reply.json"
    )
    #expect(ClockRemote.replyURL(from: [ClockRemote.intervalKey: "15m"]) == nil)
    #expect(ClockRemote.replyURL(from: [ClockRemote.replyKey: "reply.json"]) == nil)
    #expect(ClockRemote.replyURL(from: nil) == nil)
  }

  /// The answer says what the clock did, so the waiting script never has to
  /// guess, and a request with nowhere to answer moves nothing.
  @Test func anAnswerRoundTripsThroughTheFileItNames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "athina-clock-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let support = scratch()
    let url = directory.appendingPathComponent("reply.json")
    let now = Date(timeIntervalSince1970: 1_789_473_600)

    let moved = ClockRemote.Reply(moved: true, movedAhead: 9000, now: now, pid: 4242)
    try ClockRemote.answer(
      .success(9000),
      at: url,
      temporaryDirectory: directory,
      supportDirectory: support
    ) { request in
      #expect(request == .success(9000))
      return moved
    }
    #expect(try ClockRemote.Reply.decode(Data(contentsOf: url)) == moved)

    let interval = ClockRemote.Refusal(
      reason: "\"soon\" is not an interval such as 15m, 2h, or 1d, up to 30d"
    )
    let refused = ClockRemote.Reply(
      moved: false,
      reason: interval.reason,
      movedAhead: 0,
      now: now,
      pid: 7
    )
    let second = directory.appendingPathComponent("second.json")
    try ClockRemote.answer(
      .failure(interval),
      at: second,
      temporaryDirectory: directory,
      supportDirectory: support
    ) { request in
      #expect(request == .failure(interval))
      return refused
    }
    #expect(try ClockRemote.Reply.decode(Data(contentsOf: second)) == refused)

    // A request that named no file cannot be answered, so it is refused
    // before the clock moves.
    #expect(throws: ClockRemote.Refusal(reason: "no absolute replyTo path in the request")) {
      try ClockRemote.answer(
        .success(9000),
        at: nil,
        temporaryDirectory: directory,
        supportDirectory: support
      ) { _ in
        Issue.record("moved the clock for a request that named nowhere to answer")
        return moved
      }
    }
  }

  /// Nothing authenticates the channel, so a request must never be able to make
  /// the replay create or replace a file of the sender's choosing: the answer
  /// goes to a new file in the temporary directory or nowhere.
  ///
  /// A request refused that way moves nothing, so a script that retries after
  /// getting no answer never moves the clock twice.
  @Test func aRequestIsNotAnsweredWhereItCouldClobberAFile() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let temporary = root.appendingPathComponent("tmp", isDirectory: true)
    let support = root.appendingPathComponent("mentor", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let reply = ClockRemote.Reply(
      moved: true,
      movedAhead: 900,
      now: Date(timeIntervalSince1970: 1_789_473_600),
      pid: 11
    )

    func answer(at url: URL) throws {
      try ClockRemote.answer(
        .success(900),
        at: url,
        temporaryDirectory: temporary,
        supportDirectory: support
      ) { _ in reply }
    }
    func refused(at url: URL) {
      #expect(throws: ClockRemote.Refusal.self) {
        try ClockRemote.answer(
          .success(900),
          at: url,
          temporaryDirectory: temporary,
          supportDirectory: support
        ) { _ in
          Issue.record("moved the clock for a request it cannot answer at \(url.path)")
          return reply
        }
      }
    }

    // The live settings, named outright and by a path that only resolves there.
    let settings = SettingsStore.defaultURL(in: support)
    try Data("{\"idleThreshold\":900}".utf8).write(to: settings)
    refused(at: settings)
    try FileManager.default.createSymbolicLink(
      at: temporary.appendingPathComponent("aimed"),
      withDestinationURL: settings
    )
    refused(at: temporary.appendingPathComponent("aimed"))
    #expect(try String(contentsOf: settings, encoding: .utf8) == "{\"idleThreshold\":900}")

    // A link out of the temporary directory, stepped back through with `..`:
    // folding `..` away first reads a path inside the temporary directory,
    // while the kernel follows the link before the `..` and lands in the
    // live data folder. The check and the write have to be one path.
    let inner = support.appendingPathComponent("replay", isDirectory: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: temporary.appendingPathComponent("out"),
      withDestinationURL: inner
    )
    try answer(at: URL(fileURLWithPath: temporary.path + "/out/../walked.json"))
    #expect(
      !FileManager.default.fileExists(atPath: support.appendingPathComponent("walked.json").path)
    )
    #expect(
      FileManager.default.fileExists(atPath: temporary.appendingPathComponent("walked.json").path)
    )

    // Anywhere else outside the temporary directory, and a file that is already there.
    refused(at: root.appendingPathComponent("elsewhere.json"))
    let taken = temporary.appendingPathComponent("taken.json")
    try Data("mine".utf8).write(to: taken)
    refused(at: taken)
    #expect(try String(contentsOf: taken, encoding: .utf8) == "mine")

    // The fresh path under the temporary directory that advance-clock.sh names.
    let fresh = temporary.appendingPathComponent("athina-clock-abcd1234")
    try answer(at: fresh)
    #expect(try ClockRemote.Reply.decode(Data(contentsOf: fresh)) == reply)
  }

  @Test func aRequestWithNoIntervalIsRefused() {
    #expect(
      ClockRemote.seconds(from: nil)
        == .failure(ClockRemote.Refusal(reason: "no interval in the request"))
    )
    #expect(
      ClockRemote.seconds(from: [:])
        == .failure(ClockRemote.Refusal(reason: "no interval in the request"))
    )
    #expect(
      ClockRemote.seconds(from: [ClockRemote.intervalKey: 900])
        == .failure(ClockRemote.Refusal(reason: "no interval in the request"))
    )
  }
}
