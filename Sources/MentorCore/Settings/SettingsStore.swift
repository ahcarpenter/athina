import Foundation

/// Loads and saves `SensingSettings` as a JSON file.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/mentor/settings.json`, or the same file
    /// in another data directory (see `AppPaths.dataDirectory(for:)`).
    public static func defaultURL(in directory: URL = AppPaths.supportDirectory()) -> URL {
        directory.appendingPathComponent("settings.json")
    }

    /// The store a launch in `mode` saves to, in its data directory
    /// (`AppPaths.dataDirectory(for:)`), and the settings it starts from.
    /// Every launch starts from the live settings file, which a replay reads
    /// and never writes, or from the defaults when there is none: a replay
    /// keeps the user's excluded apps, retention, and sensing choices, and
    /// what it changes is saved only to its own file.
    public static func forLaunch(_ mode: ModelClientMode, supportDirectory: URL = AppPaths.supportDirectory()) -> (store: SettingsStore, settings: SensingSettings) {
        let store = SettingsStore(url: defaultURL(in: AppPaths.dataDirectory(for: mode, supportDirectory: supportDirectory)))
        return (store, SettingsStore(url: defaultURL(in: supportDirectory)).load())
    }

    /// Returns defaults when the file is missing or unreadable, so a corrupt
    /// file never prevents the app from starting.
    public func load() -> SensingSettings {
        guard let data = try? Data(contentsOf: url) else { return SensingSettings() }
        do {
            return try JSONDecoder().decode(SensingSettings.self, from: data).validated()
        } catch {
            return SensingSettings()
        }
    }

    public func save(_ settings: SensingSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.validated())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// Where Mentor keeps its files.
public enum AppPaths {
    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("mentor", isDirectory: true)
    }

    /// Where the journal and settings live for a launch in `mode`. A replay,
    /// and a replay that was refused, keeps its own in `replay` inside the
    /// support directory, so nothing it does reaches the live journal, the
    /// live settings, or later live prompts. Live and recording launches use
    /// the support directory itself.
    public static func dataDirectory(for mode: ModelClientMode, supportDirectory: URL = supportDirectory()) -> URL {
        mode.isOffline ? supportDirectory.appendingPathComponent("replay", isDirectory: true) : supportDirectory
    }
}
