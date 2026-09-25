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

  /// The running app's bundle identifier, so a build signed under another
  /// one (the App Store build) keeps its preferences and its API key apart.
  public static var bundleIdentifier: String { bundleIdentifier(in: .current) }

  /// The bundle identifier in `environment`: its app bundle's, or
  /// `defaultBundleIdentifier` when it runs from none.
  public static func bundleIdentifier(in environment: RuntimeEnvironment) -> String {
    environment.bundleIdentifier ?? defaultBundleIdentifier
  }

  /// Where the preferences live: the bundle identifier, which is the domain
  /// `UserDefaults.standard` uses in an app bundle.
  public static var preferencesDomain: String { bundleIdentifier }

  /// The service the API key's keychain item is saved under.
  public static var keychainService: String { bundleIdentifier }

  /// The live data directory, `athina` in Application Support (inside its
  /// container for a sandboxed build), which holds the journal and settings.
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

  /// True when `url` names `directory` itself or something inside it, as the
  /// file system sees it rather than as it was spelled: symlinks resolved, a
  /// trailing slash and `..` normalized, and case ignored, since the boot
  /// volume is case-insensitive by default.
  ///
  /// Used where a path someone else chose must be kept out of somewhere
  /// (`ClockRemote.answer`), so spelling it differently is never a way in.
  public static func isAt(_ url: URL, orInside directory: URL) -> Bool {
    let subject = resolvedPath(url)
    let parent = resolvedPath(directory)
    if subject.compare(parent, options: .caseInsensitive) == .orderedSame { return true }
    return subject.range(of: parent + "/", options: [.caseInsensitive, .anchored]) != nil
  }

  /// `url` with every symlink in it resolved. `resolvingSymlinksInPath`
  /// gives up on a path that does not exist yet, which a reply file usually
  /// is, so the deepest part that does exist is resolved and the rest put
  /// back on.
  static func resolvedPath(_ url: URL) -> String {
    var missing: [String] = []
    var existing = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: existing.path) {
      let parent = existing.deletingLastPathComponent().standardizedFileURL
      guard parent.path != existing.path else { break }
      missing.append(existing.lastPathComponent)
      existing = parent
    }
    var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
    for component in missing.reversed() {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL.path
  }
}
