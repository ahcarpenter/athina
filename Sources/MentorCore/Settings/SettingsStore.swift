import Foundation

/// Loads and saves `SensingSettings` as a JSON file.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/mentor/settings.json`
    public static func defaultURL() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("settings.json")
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
}
