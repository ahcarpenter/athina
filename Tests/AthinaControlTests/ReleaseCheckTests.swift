import Foundation
import Testing

@testable import AthinaControlProtocol

/// scripts/check-no-control-api.sh, which a release runs on its binary: it has
/// to find the control API wherever a build carries it, and only there.
@Suite struct ReleaseCheckTests {
  static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaControlTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  static let script = repository.appendingPathComponent("scripts/check-no-control-api.sh")

  func check(_ contents: Data) throws -> Int32 {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "check-\(UUID().uuidString.prefix(8))"
    )
    defer { try? FileManager.default.removeItem(at: file) }
    try contents.write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.script.path, file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @Test func aBinaryCarryingTheAPIFails() throws {
    var binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01])
    binary.append(Data(ControlProtocol.name.utf8))
    binary.append(contentsOf: [0x00, 0xFF, 0x10])
    #expect(try check(binary) == 1)
  }

  @Test func aBinaryWithoutItPasses() throws {
    var binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01])
    binary.append(Data("com.ahcarpenter.athina and the --control flag's own refusal".utf8))
    #expect(try check(binary) == 0)
  }
}
