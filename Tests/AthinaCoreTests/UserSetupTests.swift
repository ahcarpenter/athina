import Foundation
import Testing

@testable import AthinaCore

/// Athina never writes to anyone's Claude Code, Codex or OpenCode setup.
///
/// That covers their settings, credentials, skills, plugins, MCP servers,
/// hooks, agents and prompts. It calls each provider's API with a key the
/// person pastes into Settings, so it has no reason to go near them.
///
/// Every place Athina writes lies inside its own Application Support folder
/// and outside those tools' folders, and its keychain items are its own, so a
/// change that starts reaching for one fails here first.
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
    let supportPath = support.standardizedFileURL.path
    for url in [
      support,
      SettingsStore.defaultURL(),
      Journal.defaultURL(in: support),
      CallFixtureFiles.defaultRecordingDirectory(),
      AppPaths.replayRoot(),
    ] {
      let path = url.standardizedFileURL.path
      #expect(!isInsideASetup(url), "\(path)")
      #expect(path == supportPath || path.hasPrefix(supportPath + "/"), "\(path)")
      #expect(path.contains("/Library/Application Support/"), "\(path)")
    }
  }

  @Test func athinasKeysAreItsOwnKeychainItems() {
    #expect(KeychainKeyStore.service == AppPaths.keychainService)
    #expect(KeychainKeyStore.service.hasPrefix("com.ahcarpenter."))
    let accounts = ModelProvider.allCases.map(\.keychainAccount)
    #expect(Set(accounts).count == accounts.count)
    #expect(accounts.allSatisfy { $0.hasSuffix("-api-key") })
  }
}
