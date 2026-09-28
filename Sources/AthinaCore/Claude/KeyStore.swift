import Foundation
import Security

/// Where each provider's API key lives.
///
/// The app uses the Keychain; tests use memory.
public protocol KeyStore: Sendable {
  /// Returns the saved key for `provider`, or nil when there is none.
  func load(for provider: ModelProvider) throws -> String?
  /// Saves `key` for `provider`, replacing any other.
  func save(_ key: String, for provider: ModelProvider) throws
  /// Deletes the key for `provider`; one that is not there is not an error.
  func delete(for provider: ModelProvider) throws
}

extension KeyStore {
  /// The Anthropic key.
  public func load() throws -> String? { try load(for: .anthropic) }
  /// Saves `key` as the Anthropic key.
  public func save(_ key: String) throws { try save(key, for: .anthropic) }
  /// Deletes the Anthropic key.
  public func delete() throws { try delete(for: .anthropic) }

  /// `load(for:)` on a background queue.
  ///
  /// The keychain can block on its own prompt for as long as the user takes to
  /// answer it, and neither the main thread nor an actor's executor should wait
  /// on that.
  public func loadInBackground(
    for provider: ModelProvider = .anthropic
  ) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try load(for: provider) })
      }
    }
  }
}

/// A keychain call that failed.
public struct KeyStoreError: Error, CustomStringConvertible, Equatable, Sendable {
  /// The status the Security framework returned.
  public let status: OSStatus
  /// The operation that failed: `read`, `add`, `update`, or `delete`.
  public let operation: String

  /// The failure as one line: `keychain`, the operation, and the system's
  /// message for the status.
  public var description: String {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return "keychain \(operation): \(message)"
  }
}

/// Generic password items in the login keychain, one per provider, all under
/// the service `AppPaths` names.
///
/// The keychain trusts a non-Apple-signed app by the hash of its binary, not by
/// the designated requirement that keeps the TCC grants, so the first read
/// after an ad-hoc rebuild shows the system's keychain prompt once; Always
/// Allow adds that build to the item's list (docs/releasing.md, "Code signing").
public struct KeychainKeyStore: KeyStore {
  /// The service Athina's key is saved under: the running app's bundle
  /// identifier.
  public static let service = AppPaths.keychainService
  /// The account name of the Anthropic key's item, the same under every
  /// service; each other provider has its own (`ModelProvider.keychainAccount`).
  public static let account = ModelProvider.anthropic.keychainAccount

  /// Which item this store reads and writes.
  public let service: String

  /// Creates a store for the item under `service`.
  public init(service: String = KeychainKeyStore.service) {
    self.service = service
  }

  private func baseQuery(_ provider: ModelProvider) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.keychainAccount,
    ]
  }

  /// Returns the saved key for `provider`, or nil when there is none.
  ///
  /// The first read after a rebuild can wait on the system's keychain prompt.
  ///
  /// - Throws: `KeyStoreError` for any failure but a missing item.
  public func load(for provider: ModelProvider) throws -> String? {
    var query = baseQuery(provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    case errSecItemNotFound:
      return nil
    default:
      throw KeyStoreError(status: status, operation: "read")
    }
  }

  /// Saves `key` for `provider`, replacing the item's key or adding the item
  /// when there is none.
  ///
  /// - Throws: `KeyStoreError` when the keychain refuses the update or the add.
  public func save(_ key: String, for provider: ModelProvider) throws {
    let data = Data(key.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery(provider) as CFDictionary, update as CFDictionary)
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var insert = baseQuery(provider)
      insert[kSecValueData as String] = data
      insert[kSecAttrLabel as String] = "Athina \(provider.name) API key"
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeyStoreError(status: addStatus, operation: "add")
      }
    default:
      throw KeyStoreError(status: status, operation: "update")
    }
  }

  /// Deletes the item for `provider`; one that is not there is not an error.
  ///
  /// - Throws: `KeyStoreError` when the keychain refuses the delete.
  public func delete(for provider: ModelProvider) throws {
    let status = SecItemDelete(baseQuery(provider) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeyStoreError(status: status, operation: "delete")
    }
  }
}

/// A key store that forgets on exit, for tests and snapshots.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [ModelProvider: String]

  /// Creates a store holding `key` as the Anthropic key, or none.
  public init(key: String? = nil) {
    keys = key.map { [.anthropic: $0] } ?? [:]
  }

  /// Creates a store holding these keys.
  public init(keys: [ModelProvider: String]) {
    self.keys = keys
  }

  /// Returns the key held for `provider`, or nil.
  public func load(for provider: ModelProvider) throws -> String? {
    lock.withLock { keys[provider] }
  }

  /// Holds `key` for `provider` in place of any other.
  public func save(_ key: String, for provider: ModelProvider) throws {
    lock.withLock { keys[provider] = key }
  }

  /// Forgets the key for `provider`.
  public func delete(for provider: ModelProvider) throws {
    _ = lock.withLock { keys.removeValue(forKey: provider) }
  }
}

/// Helpers that let the UI talk about a key without ever showing it.
public enum APIKey {
  /// Trims whitespace.
  ///
  /// Empty or internally spaced keys are rejected; the format is otherwise not
  /// checked so future key shapes keep working.
  public static func normalized(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
      return nil
    }
    return trimmed
  }

  /// The only part of a key that is ever displayed or logged.
  public static func lastFour(_ key: String) -> String {
    String(key.suffix(4))
  }
}
