import Foundation
import Testing

@testable import AthinaCore

/// Athina never writes to anyone's Claude Code, Codex or OpenCode setup.
///
/// That covers their settings, credentials, skills, plugins, MCP servers,
/// hooks, agents and prompts. It calls each provider's API with a key the
/// person pastes into Settings, so it has no reason to go near them.
///
/// Every place Athina writes lies outside those folders, its keychain items
/// are its own, and no source file names any of them, so a change that starts
/// reaching for one fails here first.
@Suite struct UserSetupTests {
  /// The folders the three tools keep their setup in, under `home`.
  static func setupFolders(home: URL) -> [String] {
    [
      ".claude", ".claude.json", ".codex", ".opencode", ".config/claude", ".config/codex",
      ".config/opencode", ".local/share/opencode", ".local/state/opencode",
    ].map { home.appendingPathComponent($0).standardizedFileURL.path }
  }

  private func isInsideASetup(_ url: URL) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let path = url.standardizedFileURL.path
    return UserSetupTests.setupFolders(home: home).contains { folder in
      path == folder || path.hasPrefix(folder + "/")
    }
  }

  @Test func everyPlaceAthinaWritesIsItsOwn() {
    let support = AppPaths.supportDirectory()
    for url in [
      support,
      SettingsStore.defaultURL(),
      Journal.defaultURL(in: support),
      CallFixtureFiles.defaultRecordingDirectory(),
      AppPaths.replayRoot(),
    ] {
      #expect(!isInsideASetup(url), "\(url.path)")
      #expect(url.path.contains("/Library/Application Support/"), "\(url.path)")
    }
  }

  @Test func athinasKeysAreItsOwnKeychainItems() {
    #expect(KeychainKeyStore.service == AppPaths.keychainService)
    #expect(KeychainKeyStore.service.hasPrefix("com.ahcarpenter."))
    let accounts = ModelProvider.allCases.map(\.keychainAccount)
    #expect(Set(accounts).count == accounts.count)
    #expect(accounts.allSatisfy { $0.hasSuffix("-api-key") })
  }

  @Test func noSourceNamesAToolsSetup() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources")
    let names = [
      "/.claude", "\".claude", ".claude.json", "/.codex", "\".codex", "/.opencode",
      "\".opencode", "config/claude", "config/codex", "config/opencode", "share/opencode",
      "auth.json", "Claude Code-credentials",
    ]
    var naming: [String] = []
    let walker = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    )
    for case let url as URL in walker where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      if let name = names.first(where: text.contains) {
        naming.append("\(url.path.dropFirst(sources.path.count + 1)) names \(name)")
      }
    }
    #expect(naming.isEmpty, "no source may name a tool's own setup: \(naming)")
  }
}
