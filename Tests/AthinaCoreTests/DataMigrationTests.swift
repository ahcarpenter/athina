import Foundation
import Testing
@testable import AthinaCore

/// The move from the folder the app kept its files in while it was called
/// Mentor to the one Athina keeps them in. This is the owner's real journal,
/// settings, recordings and understanding, so every case is checked: a fresh
/// install, a move, a launch after one, both folders holding data, and a move
/// that was interrupted partway.
@Suite struct DataMigrationTests {
    private let manager = FileManager.default

    /// A throwaway Application Support stand-in holding `old` and `new`.
    private func support() throws -> (root: URL, old: URL, new: URL) {
        let root = manager.temporaryDirectory.appendingPathComponent("athina-migration-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent(AppPaths.legacyDirectoryName, isDirectory: true),
            root.appendingPathComponent(AppPaths.directoryName, isDirectory: true)
        )
    }

    /// What an owner who used Mentor has: a journal with its write-ahead log,
    /// settings, and recorded calls in their own directory.
    private func writeMentorData(at old: URL, journal: String = "journal bytes") throws {
        try manager.createDirectory(at: old.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        try Data(journal.utf8).write(to: old.appendingPathComponent("journal.sqlite"))
        try Data("wal bytes".utf8).write(to: old.appendingPathComponent("journal.sqlite-wal"))
        try Data(#"{"floorInterval": 9}"#.utf8).write(to: old.appendingPathComponent("settings.json"))
        try Data("a recorded call".utf8).write(to: old.appendingPathComponent("recordings/20260915T073409.003Z-mentor-2acd5cb1.json"))
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aFreshInstallHasNothingToMove() throws {
        let files = try support()
        defer { try? manager.removeItem(at: files.root) }
        #expect(DataMigration.run(from: files.old, to: files.new) == .nothingToMove)
        #expect(!manager.fileExists(atPath: files.new.path))
    }

    /// The journal, its write-ahead log, the settings and the recordings all
    /// arrive, byte for byte, and what Mentor left is still there afterwards.
    @Test func theFirstLaunchMovesTheJournalSettingsAndRecordings() throws {
        let files = try support()
        defer { try? manager.removeItem(at: files.root) }
        try writeMentorData(at: files.old)

        let outcome = DataMigration.run(from: files.old, to: files.new)
        #expect(outcome == .moved(["journal.sqlite", "journal.sqlite-wal", "recordings", "settings.json"]))
        #expect(try text(files.new.appendingPathComponent("journal.sqlite")) == "journal bytes")
        #expect(try text(files.new.appendingPathComponent("journal.sqlite-wal")) == "wal bytes")
        #expect(try text(files.new.appendingPathComponent("settings.json")) == #"{"floorInterval": 9}"#)
        #expect(try text(files.new.appendingPathComponent("recordings/20260915T073409.003Z-mentor-2acd5cb1.json")) == "a recorded call")

        // Nothing of the owner's was removed: the old copy is still whole.
        #expect(try text(files.old.appendingPathComponent("journal.sqlite")) == "journal bytes")
        #expect(try text(files.old.appendingPathComponent("settings.json")) == #"{"floorInterval": 9}"#)

        let marker = try JSONDecoder.marker.decode(
            DataMigration.Marker.self, from: Data(contentsOf: files.new.appendingPathComponent(DataMigration.markerName))
        )
        #expect(marker.from == files.old.path)
        #expect(marker.moved.contains("journal.sqlite"))
        #expect(outcome.note?.contains("journal.sqlite") == true)
        #expect(outcome.needsAttention == false)
    }

    /// Per-launch replay directories are the app's own throwaway files, so
    /// they stay behind rather than being copied into the new folder.
    @Test func theReplayDirectoriesAreNotMoved() throws {
        let files = try support()
        defer { try? manager.removeItem(at: files.root) }
        try writeMentorData(at: files.old)
        try manager.createDirectory(at: files.old.appendingPathComponent("replay/launch-1-abcdef12"), withIntermediateDirectories: true)
        try Data("replay journal".utf8).write(to: files.old.appendingPathComponent("replay/launch-1-abcdef12/journal.sqlite"))
        try Data("4242".utf8).write(to: files.old.appendingPathComponent("mentor.pid"))

        #expect(DataMigration.run(from: files.old, to: files.new) == .moved(["journal.sqlite", "journal.sqlite-wal", "recordings", "settings.json"]))
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
        try Data("newer journal".utf8).write(to: files.new.appendingPathComponent("journal.sqlite"))
        let again = DataMigration.run(from: files.old, to: files.new)
        #expect(again == .alreadyMoved)
        #expect(again.note == nil)
        #expect(try text(files.new.appendingPathComponent("journal.sqlite")) == "newer journal")
    }

    /// Two folders of real data are never merged or overwritten: the launch
    /// says so and uses the new one, and both are left exactly as they were.
    @Test func bothFoldersHoldingDataIsRefusedAndSaidOutLoud() throws {
        let files = try support()
        defer { try? manager.removeItem(at: files.root) }
        try writeMentorData(at: files.old)
        try manager.createDirectory(at: files.new, withIntermediateDirectories: true)
        try Data("athina journal".utf8).write(to: files.new.appendingPathComponent("journal.sqlite"))

        let outcome = DataMigration.run(from: files.old, to: files.new)
        guard case .refused(let reason) = outcome else {
            Issue.record("two folders of data must be refused, got \(outcome)")
            return
        }
        #expect(reason.contains(files.old.path))
        #expect(reason.contains(files.new.path))
        #expect(outcome.needsAttention)
        #expect(outcome.note == reason)
        #expect(try text(files.new.appendingPathComponent("journal.sqlite")) == "athina journal")
        #expect(try text(files.old.appendingPathComponent("journal.sqlite")) == "journal bytes")
        #expect(!manager.fileExists(atPath: files.new.appendingPathComponent(DataMigration.markerName).path))
    }

    /// A move that was interrupted partway leaves a staging directory and no
    /// new folder at all, so the next launch throws the half copy away and
    /// starts again rather than adopting it.
    @Test func aMoveInterruptedPartwayIsStartedAgain() throws {
        let files = try support()
        defer { try? manager.removeItem(at: files.root) }
        try writeMentorData(at: files.old)
        let staging = files.root.appendingPathComponent(DataMigration.stagingName, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("half a journal".utf8).write(to: staging.appendingPathComponent("journal.sqlite"))

        #expect(DataMigration.run(from: files.old, to: files.new) == .moved(["journal.sqlite", "journal.sqlite-wal", "recordings", "settings.json"]))
        #expect(try text(files.new.appendingPathComponent("journal.sqlite")) == "journal bytes")
        #expect(!manager.fileExists(atPath: staging.path))
    }

    /// The check that stands between a copy and the rename that puts it in
    /// place: a file that did not arrive, or arrived a different size, is a
    /// difference, and a faithful copy is not.
    @Test func theCopyIsComparedWithWhatItCameFrom() throws {
        let files = try support()
        defer { try? manager.removeItem(at: files.root) }
        try writeMentorData(at: files.old)
        let copy = files.root.appendingPathComponent("copy", isDirectory: true)
        try manager.copyItem(at: files.old, to: copy)
        #expect(DataMigration.firstDifference(between: files.old, and: copy, manager: manager) == nil)

        try manager.removeItem(at: copy.appendingPathComponent("settings.json"))
        #expect(DataMigration.firstDifference(between: files.old, and: copy, manager: manager) == "settings.json was not copied")

        try Data("short".utf8).write(to: copy.appendingPathComponent("settings.json"))
        let truncated = DataMigration.firstDifference(between: files.old, and: copy, manager: manager)
        #expect(truncated?.hasPrefix("settings.json came out 5 bytes") == true)
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

    @Test func nothingUnderTheOldNameMovesNothing() {
        let defaults = UserDefaults.standard
        let names = domains()
        defer { clear(names, in: defaults) }
        #expect(PreferencesMigration.run(from: names.old, to: names.new, in: defaults) == .nothingToMove)
        #expect(defaults.persistentDomain(forName: names.new) == nil)
    }

    @Test func theFirstLaunchCopiesTheOldPreferences() {
        let defaults = UserDefaults.standard
        let names = domains()
        defer { clear(names, in: defaults) }
        defaults.setPersistentDomain(["settingsPane": "models", "NSWindow Frame DebugPanel": "40 40 1180 860 0 0 1512 944 "], forName: names.old)

        #expect(PreferencesMigration.run(from: names.old, to: names.new, in: defaults) == .copied(["NSWindow Frame DebugPanel", "settingsPane"]))
        #expect(defaults.persistentDomain(forName: names.new)?["settingsPane"] as? String == "models")
        // The old domain is left alone, like the old folder.
        #expect(defaults.persistentDomain(forName: names.old)?["settingsPane"] as? String == "models")
    }

    /// Preferences the app has already written under the new name are never
    /// overwritten by older ones.
    @Test func preferencesAlreadyUnderTheNewNameAreKept() {
        let defaults = UserDefaults.standard
        let names = domains()
        defer { clear(names, in: defaults) }
        defaults.setPersistentDomain(["settingsPane": "models"], forName: names.old)
        defaults.setPersistentDomain(["settingsPane": "journal"], forName: names.new)

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
        #expect(KeychainKeyStore(service: KeychainKeyStore.legacyService).service == KeychainKeyStore.legacyService)
        #expect(KeychainKeyStore.account == "anthropic-api-key")
    }

    @Test func noKeyUnderTheOldNameCopiesNothing() throws {
        let defaults = defaults()
        defer { clear(defaults) }
        let new = InMemoryKeyStore()
        #expect(KeyMigration.run(from: InMemoryKeyStore(), to: new, recordingIn: defaults.store) == .nothingToMove)
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
