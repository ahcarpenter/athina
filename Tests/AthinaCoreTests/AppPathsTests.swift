import Foundation
import Testing

@testable import AthinaCore

/// A directory of this test's own, which nothing else in the run touches.
private func scratch() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "athina-paths-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// The ids Athina goes by: its app bundle's identifier, which is also the
/// preferences domain and the keychain service.
@Suite struct AppPathsTests {
  /// The test runner runs from no app bundle, like `swift run`, so it goes by
  /// the default identifier.
  @Test func theTestRunnerGoesByTheDefaultIdentifier() {
    #expect(AppPaths.bundleIdentifier == "com.ahcarpenter.athina")
    #expect(AppPaths.preferencesDomain == "com.ahcarpenter.athina")
    #expect(AppPaths.keychainService == "com.ahcarpenter.athina")
    #expect(KeychainKeyStore.service == "com.ahcarpenter.athina")
    #expect(KeychainKeyStore().service == KeychainKeyStore.service)
    #expect(KeychainKeyStore.account == "anthropic-api-key")
  }

  /// The identifier comes from the app bundle the process runs from, so the
  /// direct build keeps `com.ahcarpenter.athina` and the end-to-end harness's
  /// hermetic copy its own.
  @Test(arguments: ["com.ahcarpenter.athina", "com.ahcarpenter.athina.e2e"])
  func anAppBundleNamesItsOwnIdentifier(identifier: String) throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Athina.app", isDirectory: true)
    try writeInfo(identifier: identifier, in: app)

    #expect(AppPaths.bundleIdentifier(of: try #require(Bundle(url: app))) == identifier)
  }

  /// A bundle that is not an app, the test runner's among them, never lends
  /// its identifier to the preferences domain or the keychain service.
  @Test func aBundleThatIsNotAnAppFallsBackToTheDefault() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("Runner.xctest", isDirectory: true)
    try writeInfo(identifier: "com.apple.dt.xctest.tool", in: tool)

    #expect(
      AppPaths.bundleIdentifier(of: try #require(Bundle(url: tool)))
        == AppPaths.defaultBundleIdentifier
    )
  }

  private func writeInfo(identifier: String, in bundle: URL) throws {
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
  }
}
