import Foundation

/// Loads and saves `SensingSettings` as a JSON file.
public struct SettingsStore: Sendable {
  /// The settings file this store reads and writes.
  public let url: URL

  /// Creates a store for the settings file at `url`, which need not exist
  /// yet.
  public init(url: URL) {
    self.url = url
  }

  /// `~/Library/Application Support/athina/settings.json`, or the same file
  /// in another data directory (see `LaunchFiles`).
  public static func defaultURL(in directory: URL = AppPaths.supportDirectory()) -> URL {
    directory.appendingPathComponent("settings.json")
  }

  /// Returns defaults when the file is missing or unreadable, so a corrupt
  /// file never prevents the app from starting.
  public func load() -> SensingSettings {
    guard let data = try? Data(contentsOf: url) else { return SensingSettings() }
    do {
      return try SensingSettings(json: data)
    } catch {
      return SensingSettings()
    }
  }

  /// The settings in the file, or the error when it is missing, unreadable,
  /// or not settings, for a file someone asked for by name.
  public func loadStrictly() throws -> SensingSettings {
    try SensingSettings(json: Data(contentsOf: url))
  }

  /// Writes `settings`, validated, to the file atomically as sorted,
  /// pretty-printed JSON, creating its directory if it is missing.
  public func save(_ settings: SensingSettings) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(settings.validated())
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }
}

/// Where Athina keeps its files.
public enum AppPaths {
  /// The application support directory's name.
  ///
  /// The app was called Mentor and kept its files under `mentor`;
  /// `DataMigration` moves what is there to this one on the first launch under
  /// the new name.
  public static let directoryName = "athina"
  /// The name the app kept its files under before it was renamed.
  public static let legacyDirectoryName = "mentor"
  /// The bundle identifier of the direct and development builds, and the one
  /// a process running from no app bundle (`swift run`, tests) goes by.
  public static let defaultBundleIdentifier = "com.ahcarpenter.athina"
  /// The identifier the app had before it was renamed.
  public static let legacyBundleIdentifier = "com.ahcarpenter.mentor"

  /// The running app's bundle identifier, so a copy signed under another
  /// one (the end-to-end harness's hermetic copy, docs/e2e.md) keeps its
  /// preferences and its API key apart.
  public static let bundleIdentifier = bundleIdentifier(of: .main)

  /// The identifier of `bundle` when it is an app, or
  /// `defaultBundleIdentifier` when it is not: `swift run`, and the test
  /// runner, whose bundle has an identifier of its own that must never become
  /// the preferences domain or the keychain service.
  static func bundleIdentifier(of bundle: Bundle) -> String {
    guard bundle.bundleURL.pathExtension == "app" else { return defaultBundleIdentifier }
    return bundle.bundleIdentifier ?? defaultBundleIdentifier
  }

  /// Where the preferences live: the bundle identifier, which is the domain
  /// `UserDefaults.standard` uses in an app bundle.
  public static var preferencesDomain: String { bundleIdentifier }

  /// The service the API key's keychain item is saved under.
  public static var keychainService: String { bundleIdentifier }

  /// The live data directory, `athina` in Application Support, which holds
  /// the journal and settings.
  public static func supportDirectory() -> URL {
    applicationSupport().appendingPathComponent(directoryName, isDirectory: true)
  }

  /// Where the app kept its files before it was renamed, which is what
  /// `DataMigration` moves across.
  public static func legacySupportDirectory() -> URL {
    applicationSupport().appendingPathComponent(legacyDirectoryName, isDirectory: true)
  }

  private static func applicationSupport() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support"
      )
  }

  /// Where replays keep the data directory each launch makes (see
  /// `LaunchFiles`): `replay` inside the support directory.
  public static func replayRoot(in supportDirectory: URL = supportDirectory()) -> URL {
    supportDirectory.appendingPathComponent("replay", isDirectory: true)
  }
}
