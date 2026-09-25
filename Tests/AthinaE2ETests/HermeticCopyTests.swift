import Foundation
import Testing

/// The API tier's copy of the app (`ensure_e2e_app` in `scripts/e2e/lib/harness.sh`).
///
/// It is the same binary under an identifier of its own, so a hermetic run's
/// preferences are never the owner's, signed so it runs, and made again only
/// when the binary it was made from changes. Each test works on a checkout of
/// its own with a small real bundle.
@Suite struct HermeticCopyTests {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaE2ETests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  private static let library = repository.appendingPathComponent("scripts/e2e/lib/harness.sh").path
  private static let entitlements = repository.appendingPathComponent(
    "Resources/Athina.entitlements"
  )

  private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("athina-hermetic-copy-\(UUID().uuidString)", isDirectory: true)

  private var app: URL { root.appendingPathComponent("build/Athina.app", isDirectory: true) }
  private var binary: URL { app.appendingPathComponent("Contents/MacOS/Athina") }
  private var copy: URL { root.appendingPathComponent("build/e2e/Athina.app", isDirectory: true) }

  /// A bundle of the development identifier around a copy of a system tool.
  private func bundle() throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: binary.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: root.appendingPathComponent("Resources"),
      withIntermediateDirectories: true
    )
    try fileManager.copyItem(
      at: Self.entitlements,
      to: root.appendingPathComponent("Resources/Athina.entitlements")
    )
    try fileManager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.ahcarpenter.athina", "CFBundleExecutable": "Athina",
      "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
  }

  /// Runs `ensure_e2e_app` on this test's checkout and returns its status.
  @discardableResult
  private func ensureCopy() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      "-c",
      """
      set -euo pipefail
      source '\(Self.library)'
      RUN_DIR= ROOT='\(root.path)' APP='\(app.path)' APP_BINARY='\(binary.path)'
      E2E_APP='\(copy.path)' E2E_BINARY='\(copy.path)/Contents/MacOS/Athina'
      ensure_e2e_app
      """,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func identifier(of bundle: URL) throws -> String? {
    let info = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
      format: nil
    )
    return (info as? [String: Any])?["CFBundleIdentifier"] as? String
  }

  @Test func theCopyHasAnIdentifierOfItsOwnAndIsSignedForIt() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try bundle()
    #expect(try ensureCopy() == 0)
    #expect(try identifier(of: copy) == "com.ahcarpenter.athina.e2e")
    #expect(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path]).0 == 0)
    let (_, requirement) = try run(
      "/usr/bin/codesign",
      ["--display", "--requirements", "-", copy.path]
    )
    #expect(requirement.contains(#"identifier "com.ahcarpenter.athina.e2e""#))
    // The development bundle it was made from is left as it was.
    #expect(try identifier(of: app) == "com.ahcarpenter.athina")
  }

  @Test func theCopyIsMadeAgainOnlyWhenTheBinaryChanges() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try bundle()
    try ensureCopy()
    let marker = copy.appendingPathComponent("Contents/Resources-kept")
    try Data().write(to: marker)
    try ensureCopy()
    #expect(FileManager.default.fileExists(atPath: marker.path))

    try FileManager.default.removeItem(at: binary)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: binary)
    #expect(try ensureCopy() == 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}
