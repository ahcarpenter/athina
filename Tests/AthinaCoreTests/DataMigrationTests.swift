import Foundation
import Testing

@testable import AthinaCore

/// The move from the folder the app kept its files in while it was called
/// Mentor to the one Athina keeps them in. This is the owner's real journal,
/// settings, recordings and understanding, so every case is checked: a fresh
/// install, a move, a launch after one, both folders holding data, a replay
/// that got there first, a journal still open elsewhere, and a move that
/// failed or was interrupted partway. Every case runs in a throwaway
/// directory, never the real Application Support.
@Suite struct DataMigrationTests {
  private let manager = FileManager.default
  private let moved = ["journal.sqlite", "recordings", "settings.json"]

  /// A throwaway Application Support stand-in holding `old` and `new`.
  private func support() throws -> (root: URL, old: URL, new: URL) {
    let root = manager.temporaryDirectory.appendingPathComponent(
      "athina-migration-\(UUID().uuidString)",
      isDirectory: true
    )
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    return (
      root,
      root.appendingPathComponent(AppPaths.legacyDirectoryName, isDirectory: true),
      root.appendingPathComponent(AppPaths.directoryName, isDirectory: true)
    )
  }

  /// A real write-ahead-log journal holding `notes`, closed cleanly.
  private func writeJournal(at url: URL, notes: [String]) throws {
    let journal = try SQLiteConnection(path: url.path)
    try journal.execute("PRAGMA journal_mode = WAL")
    try journal.execute(
      "CREATE TABLE IF NOT EXISTS note (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"
    )
    for note in notes { try journal.run("INSERT INTO note (body) VALUES (?)", [.text(note)]) }
  }

  private func notes(in url: URL) throws -> [String] {
    try SQLiteConnection(path: url.path, create: false).query("SELECT body FROM note ORDER BY id") {
      $0.text(0) ?? ""
    }
  }

  /// What an owner who used Mentor has: a journal, settings, and recorded
  /// calls in their own directory.
  private func writeMentorData(
    at old: URL,
    notes: [String] = ["a morning's work", "an afternoon's"]
  ) throws {
    try manager.createDirectory(
      at: old.appendingPathComponent("recordings"),
      withIntermediateDirectories: true
    )
    try writeJournal(at: old.appendingPathComponent("journal.sqlite"), notes: notes)
    try Data(#"{"floorInterval": 9}"#.utf8).write(to: old.appendingPathComponent("settings.json"))
    try Data("a recorded call".utf8).write(
      to: old.appendingPathComponent("recordings/20260915T073409.003Z-mentor-2acd5cb1.json")
    )
  }

  private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  /// Every file under `directory` with its bytes, to say a folder is
  /// exactly what it was.
  private func everyByte(in directory: URL) throws -> [String: Data] {
    var found: [String: Data] = [:]
    for case let path as String in manager.enumerator(atPath: directory.path)! {
      var isDirectory: ObjCBool = false
      let url = directory.appendingPathComponent(path)
      guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
      else { continue }
      found[path] = try Data(contentsOf: url)
    }
    return found
  }

  @Test func aFreshInstallHasNothingToMove() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    #expect(DataMigration.run(from: files.old, to: files.new) == .nothingToMove)
    #expect(!manager.fileExists(atPath: files.new.path))
  }

  /// The journal, the settings and the recordings all arrive, and what
  /// Mentor left is still there afterwards, byte for byte.
  @Test func theFirstLaunchMovesTheJournalSettingsAndRecordings() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let before = try everyByte(in: files.old)

    let outcome = DataMigration.run(from: files.old, to: files.new)
    #expect(outcome == .moved(moved))
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")) == [
        "a morning's work", "an afternoon's",
      ]
    )
    #expect(try text(files.new.appendingPathComponent("settings.json")) == #"{"floorInterval": 9}"#)
    #expect(
      try text(
        files.new.appendingPathComponent("recordings/20260915T073409.003Z-mentor-2acd5cb1.json")
      ) == "a recorded call"
    )

    // Nothing of the owner's was removed or altered: the old copy is whole.
    #expect(try everyByte(in: files.old) == before)

    let marker = try JSONDecoder.marker.decode(
      DataMigration.Marker.self,
      from: Data(contentsOf: files.new.appendingPathComponent(DataMigration.markerName))
    )
    #expect(marker.from == files.old.path)
    #expect(marker.moved == moved)
    #expect(outcome.note?.contains("journal.sqlite") == true)
    #expect(outcome.needsAttention == false)
    #expect(outcome.stopsLaunch == false)
    #expect(
      !manager.fileExists(atPath: files.new.appendingPathComponent(DataMigration.pendingName).path)
    )
    #expect(
      !manager.fileExists(atPath: files.root.appendingPathComponent(DataMigration.stagingName).path)
    )
  }

  /// The app itself opens what arrived, as the journal it is.
  @Test func theMovedJournalOpensAsAJournal() async throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try manager.createDirectory(at: files.old, withIntermediateDirectories: true)
    _ = try Journal(url: files.old.appendingPathComponent("journal.sqlite"))

    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(["journal.sqlite"]))
    let journal = try Journal(url: files.new.appendingPathComponent("journal.sqlite"))
    #expect(try await journal.recentSuggestions(limit: 5).isEmpty)
  }

  /// Mentor did not quit cleanly, so its last writes are still in the
  /// write-ahead log. They arrive with the rest, and the log is left as it
  /// was found rather than folded into the old database.
  @Test func writesStillInTheWriteAheadLogAreMovedAndTheLogIsLeftAlone() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    let live = files.root.appendingPathComponent("live", isDirectory: true)
    try manager.createDirectory(at: live, withIntermediateDirectories: true)
    try manager.createDirectory(at: files.old, withIntermediateDirectories: true)
    // Copied while the writer is still open and idle, which is what a
    // crash leaves behind: a database with its log beside it.
    let writer = try SQLiteConnection(path: live.appendingPathComponent("journal.sqlite").path)
    try writer.execute("PRAGMA journal_mode = WAL")
    try writer.execute("CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
    try writer.run("INSERT INTO note (body) VALUES (?)", [.text("only in the log")])
    for name in ["journal.sqlite", "journal.sqlite-wal"] {
      try manager.copyItem(
        at: live.appendingPathComponent(name),
        to: files.old.appendingPathComponent(name)
      )
    }
    let before = try everyByte(in: files.old)
    #expect(before["journal.sqlite-wal"]?.isEmpty == false)

    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(["journal.sqlite"]))
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")) == ["only in the log"]
    )
    #expect(try everyByte(in: files.old) == before)
    withExtendedLifetime(writer) {}
  }

  /// Per-launch replay directories are the app's own throwaway files, so
  /// they stay behind rather than being copied into the new folder.
  @Test func theReplayDirectoriesAreNotMoved() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    try manager.createDirectory(
      at: files.old.appendingPathComponent("replay/launch-1-abcdef12"),
      withIntermediateDirectories: true
    )
    try Data("replay journal".utf8).write(
      to: files.old.appendingPathComponent("replay/launch-1-abcdef12/journal.sqlite")
    )
    try Data("4242".utf8).write(to: files.old.appendingPathComponent("mentor.pid"))

    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(!manager.fileExists(atPath: files.new.appendingPathComponent("replay").path))
    #expect(!manager.fileExists(atPath: files.new.appendingPathComponent("mentor.pid").path))
  }

  /// Every launch after the move finds the marker and leaves both folders
  /// alone, however much the old one still holds.
  @Test func aLaterLaunchMovesNothingAgain() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    #expect(DataMigration.run(from: files.old, to: files.new).needsAttention == false)

    // The app has been running under the new name since.
    try writeJournal(
      at: files.new.appendingPathComponent("journal.sqlite"),
      notes: ["written as Athina"]
    )
    let again = DataMigration.run(from: files.old, to: files.new)
    #expect(again == .alreadyMoved)
    #expect(again.note == nil)
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")).last == "written as Athina"
    )
  }

  /// A replay run before the first live launch leaves its per-launch
  /// directory in the new folder. That is the app's own, not the owner's
  /// data, so the move goes ahead around it and the replay keeps its files.
  @Test func aReplayThatRanFirstDoesNotStandInTheWay() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let replay = AppPaths.replayRoot(in: files.new).appendingPathComponent(
      "launch-7-0badcafe",
      isDirectory: true
    )
    try manager.createDirectory(at: replay, withIntermediateDirectories: true)
    try Data("a replay's journal".utf8).write(to: replay.appendingPathComponent("journal.sqlite"))
    try Data("7".utf8).write(to: files.new.appendingPathComponent(DataDirectoryLock.fileName))

    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")) == [
        "a morning's work", "an afternoon's",
      ]
    )
    #expect(try text(files.new.appendingPathComponent("settings.json")) == #"{"floorInterval": 9}"#)
    #expect(try text(replay.appendingPathComponent("journal.sqlite")) == "a replay's journal")
    #expect(DataMigration.run(from: files.old, to: files.new) == .alreadyMoved)
  }

  /// Two folders of real data are never merged or overwritten: the launch
  /// says so, naming what it found, and uses the new one, and both are left
  /// exactly as they were.
  @Test func bothFoldersHoldingDataIsRefusedAndSaidOutLoud() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    try manager.createDirectory(at: files.new, withIntermediateDirectories: true)
    try writeJournal(
      at: files.new.appendingPathComponent("journal.sqlite"),
      notes: ["athina's own"]
    )
    let before = (old: try everyByte(in: files.old), new: try everyByte(in: files.new))

    let outcome = DataMigration.run(from: files.old, to: files.new)
    guard case .refused(let reason) = outcome else {
      Issue.record("two folders of data must be refused, got \(outcome)")
      return
    }
    #expect(reason.contains(files.old.path))
    #expect(reason.contains(files.new.path))
    #expect(reason.contains("journal.sqlite"))
    #expect(outcome.needsAttention)
    #expect(outcome.stopsLaunch == false)
    #expect(outcome.note == reason)
    #expect(try everyByte(in: files.new) == before.new)
    #expect(try everyByte(in: files.old) == before.old)
  }

  /// Mentor, or another copy of the app, still has the old journal open, so
  /// a copy made now could miss what it writes next. Nothing is copied, the
  /// launch stops, and the next one, with the journal closed, moves it all.
  @Test func aJournalStillOpenElsewhereStopsTheLaunchAndTheNextOneMoves() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    var mentor: SQLiteConnection? = try SQLiteConnection(
      path: files.old.appendingPathComponent("journal.sqlite").path
    )
    #expect(try mentor?.scalarInt("SELECT count(*) FROM note") == 2)

    let outcome = DataMigration.run(from: files.old, to: files.new)
    guard case .inUse(let reason) = outcome else {
      Issue.record("a journal open elsewhere must stop the move, got \(outcome)")
      return
    }
    #expect(reason.contains(files.old.appendingPathComponent("journal.sqlite").path))
    #expect(outcome.stopsLaunch)
    #expect(outcome.needsAttention)
    #expect(!manager.fileExists(atPath: files.new.path))
    #expect(
      !manager.fileExists(atPath: files.root.appendingPathComponent(DataMigration.stagingName).path)
    )

    // Still Mentor's to write, and what it writes next is not lost.
    try mentor?.run("INSERT INTO note (body) VALUES (?)", [.text("written while Athina waited")])
    mentor = nil
    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")).last
        == "written while Athina waited"
    )
  }

  /// A move that fails stops the launch and leaves nothing behind, so the
  /// next launch, with the cause gone, simply moves everything.
  @Test func aMoveThatFailsOnceSucceedsOnTheNextLaunch() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let unreadable = files.old.appendingPathComponent("settings.json")
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }

    let outcome = DataMigration.run(from: files.old, to: files.new)
    guard case .failed(let reason) = outcome else {
      Issue.record("a file that cannot be read must fail the move, got \(outcome)")
      return
    }
    #expect(reason.contains(files.old.path))
    // The system's description of the failure already ends in a period,
    // and the sentence that follows it says the way out.
    #expect(!reason.contains(".."))
    #expect(reason.contains("move that folder somewhere else"))
    #expect(outcome.stopsLaunch)
    #expect(!manager.fileExists(atPath: files.new.path))
    #expect(
      !manager.fileExists(atPath: files.root.appendingPathComponent(DataMigration.stagingName).path)
    )

    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(try text(files.new.appendingPathComponent("settings.json")) == #"{"floorInterval": 9}"#)
  }

  /// The same when the new folder was already there with a replay in it and
  /// cannot be written to: the failed attempt takes nothing of the replay's
  /// and leaves nothing of its own, and the next launch moves everything.
  @Test func aMoveThatFailsPuttingFilesInPlaceLeavesTheNewFolderAsItWas() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let replay = AppPaths.replayRoot(in: files.new).appendingPathComponent(
      "launch-7-0badcafe",
      isDirectory: true
    )
    try manager.createDirectory(at: replay, withIntermediateDirectories: true)
    try Data("a replay's journal".utf8).write(to: replay.appendingPathComponent("journal.sqlite"))
    let before = try everyByte(in: files.new)
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.new.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.new.path) }

    let outcome = DataMigration.run(from: files.old, to: files.new)
    guard case .failed = outcome else {
      Issue.record("a folder that cannot be written to must fail the move, got \(outcome)")
      return
    }
    #expect(outcome.stopsLaunch)
    #expect(try everyByte(in: files.new) == before)
    #expect(try manager.contentsOfDirectory(atPath: files.new.path) == ["replay"])

    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.new.path)
    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(
      try everyByte(in: files.new)["replay/launch-7-0badcafe/journal.sqlite"]
        == Data("a replay's journal".utf8)
    )
  }

  /// A move that was interrupted while it was still copying leaves a
  /// staging directory and nothing in the new folder, so the next launch
  /// throws the half copy away and starts again rather than adopting it.
  @Test func aMoveInterruptedWhileCopyingIsStartedAgain() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let staging = files.root.appendingPathComponent(DataMigration.stagingName, isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("half a journal".utf8).write(to: staging.appendingPathComponent("journal.sqlite"))

    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")) == [
        "a morning's work", "an afternoon's",
      ]
    )
    #expect(!manager.fileExists(atPath: staging.path))
  }

  /// A move that was interrupted while putting files in place leaves its
  /// record of the names it was putting there. The next launch takes out
  /// exactly those, keeps what it did not put there, and starts again.
  @Test func aMoveInterruptedWhilePuttingFilesInPlaceIsStartedAgain() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let replay = AppPaths.replayRoot(in: files.new).appendingPathComponent(
      "launch-7-0badcafe",
      isDirectory: true
    )
    try manager.createDirectory(at: replay, withIntermediateDirectories: true)
    try Data("half a journal".utf8).write(to: files.new.appendingPathComponent("journal.sqlite"))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(DataMigration.Marker(from: files.old.path, at: Date(), moved: moved))
      .write(to: files.new.appendingPathComponent(DataMigration.pendingName))

    #expect(DataMigration.run(from: files.old, to: files.new) == .moved(moved))
    #expect(
      try notes(in: files.new.appendingPathComponent("journal.sqlite")) == [
        "a morning's work", "an afternoon's",
      ]
    )
    #expect(manager.fileExists(atPath: replay.path))
    #expect(
      !manager.fileExists(atPath: files.new.appendingPathComponent(DataMigration.pendingName).path)
    )
  }

  /// The check that stands between a copy and putting it in place: a file
  /// that did not arrive, or arrived the same size with other contents, is
  /// a difference, and a faithful copy is not.
  @Test func theCopyIsComparedWithWhatItCameFromByContent() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let copy = files.root.appendingPathComponent("copy", isDirectory: true)
    try manager.copyItem(at: files.old, to: copy)
    #expect(
      try DataMigration.firstDifference(between: files.old, and: copy, manager: manager) == nil
    )

    try manager.removeItem(at: copy.appendingPathComponent("settings.json"))
    #expect(
      try DataMigration.firstDifference(between: files.old, and: copy, manager: manager)
        == "settings.json was not copied"
    )

    try Data(#"{"floorInterval": 7}"#.utf8).write(to: copy.appendingPathComponent("settings.json"))
    let altered = try DataMigration.firstDifference(between: files.old, and: copy, manager: manager)
    #expect(altered?.hasPrefix("settings.json is not what was copied") == true)
  }

  /// A description that ends in a period is left as it is, and one that does
  /// not is given one, so what follows never reads as a double period.
  @Test func aFailureReadsOnAsOneSentence() {
    #expect(
      DataMigration.sentence("The file could not be opened.") == "The file could not be opened."
    )
    #expect(
      DataMigration.sentence("SQLite error 14: unable to open database file")
        == "SQLite error 14: unable to open database file."
    )
    #expect(DataMigration.sentence("disk full \n") == "disk full.")
  }

  /// The journal SQLite copied is held to the original row for row: a copy
  /// that lost a row is a difference.
  @Test func aJournalCopyThatLostARowIsADifference() throws {
    let files = try support()
    defer { try? manager.removeItem(at: files.root) }
    try writeMentorData(at: files.old)
    let copy = files.root.appendingPathComponent("copy", isDirectory: true)
    try manager.copyItem(at: files.old, to: copy)
    let original = try SQLiteConnection(
      path: files.old.appendingPathComponent("journal.sqlite").path,
      create: false
    )
    #expect(
      try DataMigration.firstDifference(
        between: files.old,
        and: copy,
        journal: original,
        manager: manager
      ) == nil
    )

    try SQLiteConnection(path: copy.appendingPathComponent("journal.sqlite").path, create: false)
      .run("DELETE FROM note WHERE id = 1")
    let short = try DataMigration.firstDifference(
      between: files.old,
      and: copy,
      journal: original,
      manager: manager
    )
    #expect(short == "the copied journal's note came out 1 rows, not 2")
  }
}

/// The preferences the app kept under its old bundle identifier: the Settings
/// pane last open and the window frames.
@Suite struct PreferencesMigrationTests {
  /// Throwaway domain names, so a test never touches the app's own
  /// preferences or another test's.
  private func domains() -> (old: String, new: String) {
    let run = UUID().uuidString
    return ("com.ahcarpenter.athina.test.old-\(run)", "com.ahcarpenter.athina.test.new-\(run)")
  }

  private func clear(_ names: (old: String, new: String), in defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: names.old)
    defaults.removePersistentDomain(forName: names.new)
  }

  /// A fresh install has nothing to copy, and its first live launch still
  /// settles the matter: preferences that turn up under the old name later
  /// never overwrite what the app has written since.
  @Test func nothingUnderTheOldNameMovesNothingThenOrLater() {
    let defaults = UserDefaults.standard
    let names = domains()
    defer { clear(names, in: defaults) }
    #expect(
      PreferencesMigration.run(from: names.old, to: names.new, in: defaults) == .nothingToMove
    )
    #expect(defaults.persistentDomain(forName: names.new)?["settingsPane"] == nil)

    defaults.setPersistentDomain(
      ["settingsPane": "journal", PreferencesMigration.doneKey: true],
      forName: names.new
    )
    defaults.setPersistentDomain(["settingsPane": "models"], forName: names.old)
    #expect(PreferencesMigration.run(from: names.old, to: names.new, in: defaults) == .alreadyThere)
    #expect(defaults.persistentDomain(forName: names.new)?["settingsPane"] as? String == "journal")
  }

  @Test func theFirstLaunchCopiesTheOldPreferences() {
    let defaults = UserDefaults.standard
    let names = domains()
    defer { clear(names, in: defaults) }
    defaults.setPersistentDomain(
      ["settingsPane": "models", "NSWindow Frame DebugPanel": "40 40 1180 860 0 0 1512 944 "],
      forName: names.old
    )

    #expect(
      PreferencesMigration.run(from: names.old, to: names.new, in: defaults)
        == .copied(["NSWindow Frame DebugPanel", "settingsPane"])
    )
    #expect(defaults.persistentDomain(forName: names.new)?["settingsPane"] as? String == "models")
    // The old domain is left alone, like the old folder.
    #expect(defaults.persistentDomain(forName: names.old)?["settingsPane"] as? String == "models")
    #expect(defaults.persistentDomain(forName: names.old)?[PreferencesMigration.doneKey] == nil)
  }

  /// A replay shares the new domain and can run before the first live
  /// launch. What it left there is not the owner's, so the owner's
  /// preferences still arrive, over it.
  @Test func whatAReplayWroteFirstDoesNotKeepTheOwnersPreferencesOut() {
    let defaults = UserDefaults.standard
    let names = domains()
    defer { clear(names, in: defaults) }
    defaults.setPersistentDomain(
      ["settingsPane": "models", "NSWindow Frame History": "10 10 900 600 0 0 1512 944 "],
      forName: names.old
    )
    defaults.setPersistentDomain(
      ["settingsPane": "journal", "NSWindow Frame DebugPanel": "40 40 1180 860 0 0 1512 944 "],
      forName: names.new
    )

    #expect(
      PreferencesMigration.run(from: names.old, to: names.new, in: defaults)
        == .copied(["NSWindow Frame History", "settingsPane"])
    )
    let settled = defaults.persistentDomain(forName: names.new)
    #expect(settled?["settingsPane"] as? String == "models")
    #expect(settled?["NSWindow Frame History"] as? String == "10 10 900 600 0 0 1512 944 ")
    #expect(settled?["NSWindow Frame DebugPanel"] as? String == "40 40 1180 860 0 0 1512 944 ")
  }

  /// Preferences the app has written under the new name since its first
  /// live launch are never overwritten by older ones.
  @Test func preferencesWrittenSinceTheFirstLiveLaunchAreKept() {
    let defaults = UserDefaults.standard
    let names = domains()
    defer { clear(names, in: defaults) }
    defaults.setPersistentDomain(["settingsPane": "models"], forName: names.old)
    #expect(
      PreferencesMigration.run(from: names.old, to: names.new, in: defaults)
        == .copied(["settingsPane"])
    )

    var current = defaults.persistentDomain(forName: names.new) ?? [:]
    current["settingsPane"] = "journal"
    defaults.setPersistentDomain(current, forName: names.new)
    #expect(PreferencesMigration.run(from: names.old, to: names.new, in: defaults) == .alreadyThere)
    #expect(defaults.persistentDomain(forName: names.new)?["settingsPane"] as? String == "journal")
  }
}

/// Carrying the Anthropic API key from the item the app saved while it was
/// called Mentor. Every case runs against in-memory stores and a throwaway
/// preferences domain: no test reads or writes the login keychain, and no
/// assertion here names a key's value.
@Suite struct KeyMigrationTests {
  /// A preferences domain of this test's own, so nothing it records reaches
  /// the app's own preferences or another test's.
  private func defaults() -> (store: UserDefaults, name: String) {
    let name = "com.ahcarpenter.athina.test.key-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
  }

  private func clear(_ defaults: (store: UserDefaults, name: String)) {
    defaults.store.removePersistentDomain(forName: defaults.name)
  }

  /// The item is named by service and account, and the old name is the one
  /// the app had.
  @Test func theItemIsTheAppsOwnServiceAndTheOldOneIsMentors() {
    #expect(KeychainKeyStore.service == "com.ahcarpenter.athina")
    #expect(KeychainKeyStore.legacyService == "com.ahcarpenter.mentor")
    #expect(KeychainKeyStore().service == KeychainKeyStore.service)
    #expect(
      KeychainKeyStore(service: KeychainKeyStore.legacyService).service
        == KeychainKeyStore.legacyService
    )
    #expect(KeychainKeyStore.account == "anthropic-api-key")
  }

  @Test func noKeyUnderTheOldNameCopiesNothing() throws {
    let defaults = defaults()
    defer { clear(defaults) }
    let new = InMemoryKeyStore()
    #expect(
      KeyMigration.run(from: InMemoryKeyStore(), to: new, recordingIn: defaults.store)
        == .nothingToMove
    )
    #expect(try new.load() == nil)
    #expect(defaults.store.bool(forKey: KeyMigration.doneKey) == false)
  }

  /// The key arrives under the new name, reads back from there, and the old
  /// item is left exactly as it was.
  @Test func theKeyIsCopiedAndTheOldItemIsLeftInPlace() throws {
    let defaults = defaults()
    defer { clear(defaults) }
    let old = InMemoryKeyStore(key: "sk-ant-not-a-real-key-0000")
    let new = InMemoryKeyStore()

    #expect(KeyMigration.run(from: old, to: new, recordingIn: defaults.store) == .copied)
    #expect(try new.load() != nil)
    #expect(try new.load() == old.load())
    #expect(try old.load() != nil)
    #expect(defaults.store.bool(forKey: KeyMigration.doneKey))
  }

  /// A key already saved under the new name is never overwritten.
  @Test func aKeyAlreadyUnderTheNewNameIsKept() throws {
    let defaults = defaults()
    defer { clear(defaults) }
    let old = InMemoryKeyStore(key: "sk-ant-not-a-real-key-0000")
    let new = InMemoryKeyStore(key: "sk-ant-also-not-real-1111")
    let kept = try new.load()

    #expect(KeyMigration.run(from: old, to: new, recordingIn: defaults.store) == .alreadyThere)
    #expect(try new.load() == kept)
    #expect(try new.load() != old.load())
  }

  /// A key the owner deleted in Settings is never brought back from the
  /// item left behind under the old name.
  @Test func aDeletedKeyIsNotCopiedBack() throws {
    let defaults = defaults()
    defer { clear(defaults) }
    let old = InMemoryKeyStore(key: "sk-ant-not-a-real-key-0000")
    let new = InMemoryKeyStore()
    #expect(KeyMigration.run(from: old, to: new, recordingIn: defaults.store) == .copied)

    try new.delete()
    #expect(KeyMigration.run(from: old, to: new, recordingIn: defaults.store) == .alreadyThere)
    #expect(try new.load() == nil)
  }

  /// Nothing the copy says carries the key, whatever happens.
  @Test func nothingItSaysCarriesTheKey() throws {
    let defaults = defaults()
    defer { clear(defaults) }
    let secret = "sk-ant-not-a-real-key-0000"
    let old = InMemoryKeyStore(key: secret)
    let outcome = KeyMigration.run(from: old, to: InMemoryKeyStore(), recordingIn: defaults.store)
    #expect(outcome == .copied)
    #expect(outcome.note?.contains(secret) == false)
    #expect(outcome.note?.contains(KeychainKeyStore.service) == true)
  }
}

extension JSONDecoder {
  /// Reads what `DataMigration` writes into its marker.
  static var marker: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
