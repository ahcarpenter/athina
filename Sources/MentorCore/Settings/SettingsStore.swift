import Foundation

/// Loads and saves `SensingSettings` as a JSON file.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/mentor/settings.json`, or the same file
    /// in another data directory (see `LaunchFiles`).
    public static func defaultURL(in directory: URL = AppPaths.supportDirectory()) -> URL {
        directory.appendingPathComponent("settings.json")
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

    /// The settings in the file, or the error when it is missing, unreadable,
    /// or not settings, for a file someone asked for by name.
    public func loadStrictly() throws -> SensingSettings {
        try JSONDecoder().decode(SensingSettings.self, from: Data(contentsOf: url)).validated()
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

    /// Where replays keep their data directories when not given one (see
    /// `LaunchFiles`): `replay` inside the support directory.
    public static func replayRoot(in supportDirectory: URL = supportDirectory()) -> URL {
        supportDirectory.appendingPathComponent("replay", isDirectory: true)
    }
}
