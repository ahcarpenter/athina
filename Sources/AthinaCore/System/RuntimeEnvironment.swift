import Foundation
import Security

/// What kind of process this is, read once at launch: whether it runs in the
/// App Sandbox, and which app bundle, if any, it runs from.
///
/// One binary serves every build. The direct and development builds run
/// unsandboxed as `com.ahcarpenter.athina`; an App Store build is the same
/// binary signed with the `com.apple.security.app-sandbox` entitlement and a
/// bundle identifier of its own. Which one this is comes from the process's
/// own signature rather than a compile flag, so every build and every test
/// runs one code path, and a test builds either answer directly rather than
/// reading `current`.
///
/// A sandboxed process reaches only its container and, for reading, its own
/// bundle. `AppPaths` resolves inside the container by itself; what differs is
/// a path someone names on the command line, which `refusal(reading:for:)` and
/// `refusal(writing:for:)` turn away with the reason rather than leaving it to
/// fail later on a bare permission error.
public struct RuntimeEnvironment: Equatable, Sendable {
  /// The entitlement that puts a process in the App Sandbox.
  public static let sandboxEntitlement = "com.apple.security.app-sandbox"

  /// Whether the process carries `sandboxEntitlement`.
  public var isSandboxed: Bool
  /// The identifier of the app bundle the process runs from, or nil when it
  /// runs from none: `swift run`, and the test runner.
  public var bundleIdentifier: String?
  /// That app bundle, which a sandboxed process may read.
  public var bundleURL: URL?
  /// The container's home, which a sandboxed process may read and write, or
  /// nil when it is not sandboxed.
  public var containerURL: URL?

  public init(
    isSandboxed: Bool,
    bundleIdentifier: String? = nil,
    bundleURL: URL? = nil,
    containerURL: URL? = nil
  ) {
    self.isSandboxed = isSandboxed
    self.bundleIdentifier = bundleIdentifier
    self.bundleURL = bundleURL
    self.containerURL = containerURL
  }

  /// This process, read once.
  public static let current = RuntimeEnvironment.detect()

  /// Reads the process's own entitlement and main bundle.
  ///
  /// Only a bundle that is an app counts: the test runner has a main bundle and
  /// an identifier of its own, which must never become the preferences domain
  /// or the keychain service.
  static func detect(bundle: Bundle = .main) -> RuntimeEnvironment {
    let app = bundle.bundleURL.pathExtension == "app" ? bundle : nil
    let sandboxed = hasEntitlement(sandboxEntitlement)
    return RuntimeEnvironment(
      isSandboxed: sandboxed,
      bundleIdentifier: app?.bundleIdentifier,
      bundleURL: app?.bundleURL,
      // Inside the sandbox the home directory is the container's.
      containerURL: sandboxed ? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) : nil
    )
  }

  /// Whether this process's signature grants the boolean entitlement `name`.
  static func hasEntitlement(_ name: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? Bool == true
  }

  /// Why `flag` may not read `url` in this process, or nil when it may: a
  /// sandboxed process reads only inside its container and its own bundle.
  ///
  /// Always nil outside the sandbox.
  public func refusal(reading url: URL, for flag: String) -> String? {
    refusal(
      url,
      for: flag,
      verb: "read",
      within: [
        containerURL.map { ("its container", $0) }, bundleURL.map { ("its own bundle", $0) },
      ]
    )
  }

  /// Why `flag` may not write to `url` in this process, or nil when it may: a
  /// sandboxed process writes only inside its container, since its bundle is
  /// sealed by its signature.
  ///
  /// Always nil outside the sandbox.
  public func refusal(writing url: URL, for flag: String) -> String? {
    refusal(url, for: flag, verb: "write", within: [containerURL.map { ("its container", $0) }])
  }

  /// The reason comes first and the path last: the menu cuts a long line in
  /// the middle and the debug panel after a few lines, so a path in front
  /// would push the reason out of sight.
  private func refusal(
    _ url: URL,
    for flag: String,
    verb: String,
    within places: [(String, URL)?]
  ) -> String? {
    guard isSandboxed else { return nil }
    let places = places.compactMap { $0 }
    guard !places.contains(where: { AppPaths.isAt(url, orInside: $0.1) }) else { return nil }
    let reachable = places.isEmpty ? "its container" : places.map(\.0).joined(separator: " and ")
    return "\(flag): a sandboxed Athina can \(verb) only inside \(reachable), not \(url.path)"
  }
}
