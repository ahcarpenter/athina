import Foundation
import Security

/// Where the Anthropic API key lives.
///
/// The app uses the Keychain; tests use memory.
public protocol KeyStore: Sendable {
  func load() throws -> String?
  func save(_ key: String) throws
  func delete() throws
}

extension KeyStore {
  /// `load()` on a background queue.
  ///
  /// The keychain can block on its own prompt for as long as the user takes to
  /// answer it, and neither the main thread nor an actor's executor should wait
  /// on that.
  public func loadInBackground() async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try load() })
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

/// A generic password item in the login keychain.
///
/// The keychain trusts a non-Apple-signed app by the hash of its binary, not by
/// the designated requirement that keeps the TCC grants, so the first read
/// after an ad-hoc rebuild shows the system's keychain prompt once; Always
/// Allow adds that build to the item's list (README, "Code signing").
public struct KeychainKeyStore: KeyStore {
  /// The service Athina's key is saved under: the running app's bundle
  /// identifier.
  public static let service = AppPaths.keychainService
  /// The service the item was saved under while the app was called Mentor.
  /// `KeyMigration` copies that item to the one above on the first launch.
  public static let legacyService = AppPaths.legacyBundleIdentifier
  /// The account name of the key's item, the same under every service.
  public static let account = "anthropic-api-key"

  /// Which item this store reads and writes.
  ///
  /// Only `KeyMigration` names anything but the default.
  public let service: String

  /// Creates a store for the item under `service`.
  public init(service: String = KeychainKeyStore.service) {
    self.service = service
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: KeychainKeyStore.account,
    ]
  }

  /// Returns the saved key, or nil when there is none.
  ///
  /// The first read after a rebuild can wait on the system's keychain prompt.
  ///
  /// - Throws: `KeyStoreError` for any failure but a missing item.
  public func load() throws -> String? {
    var query = baseQuery
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

  /// Saves `key`, replacing the item's key or adding the item when there is
  /// none.
  ///
  /// - Throws: `KeyStoreError` when the keychain refuses the update or the add.
  public func save(_ key: String) throws {
    let data = Data(key.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var insert = baseQuery
      insert[kSecValueData as String] = data
      insert[kSecAttrLabel as String] = "Athina Anthropic API key"
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeyStoreError(status: addStatus, operation: "add")
      }
    default:
      throw KeyStoreError(status: status, operation: "update")
    }
  }

  /// Deletes the item; one that is not there is not an error.
  ///
  /// - Throws: `KeyStoreError` when the keychain refuses the delete.
  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeyStoreError(status: status, operation: "delete")
    }
  }
}

/// Carries the Anthropic API key from the keychain item the app saved while
/// it was called Mentor to the one Athina saves.
///
/// Shaped like the move of the owner's files (`DataMigration`): the key is
/// copied to the new item, read back from there, and only then is the copy
/// called done. The old item is left exactly as it was, so a key is never
/// lost to a half-finished copy; an item under the new service is never
/// overwritten, since only the owner can say which key is the one to use.
///
/// The key itself never leaves this type: no outcome, error, or log line
/// carries it.
public enum KeyMigration {
  /// Remembers that the copy has been made, so a key the owner has since
  /// deleted in Settings is never brought back from the item left behind.
  public static let doneKey = "apiKeyCopiedFromMentor"

  /// What one run of the copy did.
  public enum Outcome: Equatable, Sendable {
    /// No key was saved under the old name.
    case nothingToMove
    /// Nothing to do: a key is already saved under the new name, or this
    /// copy has already been made once. Neither is overwritten.
    case alreadyThere
    /// The key was copied and reads back from the new item.
    case copied
    /// The copy could not be finished. The old item is untouched.
    case failed(String)

    /// A sentence for the log, or nil when there was nothing to do.
    public var note: String? {
      switch self {
      case .nothingToMove, .alreadyThere: nil
      case .copied:
        "Copied the API key saved under \(KeychainKeyStore.legacyService) to \(KeychainKeyStore.service); the old item is untouched."
      case .failed(let reason): reason
      }
    }
  }

  /// Copies the key, once.
  ///
  /// Safe to call on every launch, and does nothing at all when there is
  /// nothing to copy.
  ///
  /// Reads the keychain, which on the first launch of a newly signed build
  /// can put up the system's access prompt, so this belongs off the main
  /// thread like every other key read.
  public static func run(
    from old: any KeyStore = KeychainKeyStore(service: KeychainKeyStore.legacyService),
    to new: any KeyStore = KeychainKeyStore(),
    recordingIn defaults: UserDefaults = .standard
  ) -> Outcome {
    guard !defaults.bool(forKey: doneKey) else { return .alreadyThere }
    do {
      guard try new.load() == nil else {
        defaults.set(true, forKey: doneKey)
        return .alreadyThere
      }
      guard let key = try old.load() else { return .nothingToMove }
      try new.save(key)
      guard try new.load() == key else {
        return .failed(
          "The API key did not read back from \(KeychainKeyStore.service). The key saved under \(KeychainKeyStore.legacyService) is untouched; paste it into Settings > Models."
        )
      }
      defaults.set(true, forKey: doneKey)
      return .copied
    } catch {
      return .failed(
        "Could not copy the API key from \(KeychainKeyStore.legacyService) to \(KeychainKeyStore.service): \(DataMigration.sentence(String(describing: error))) The old item is untouched."
      )
    }
  }
}

/// A key store that forgets on exit, for tests and snapshots.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: String?

  /// Creates a store holding `key`, or none.
  public init(key: String? = nil) {
    self.key = key
  }

  /// Returns the key held, or nil.
  public func load() throws -> String? {
    lock.withLock { key }
  }

  /// Holds `key` in place of any other.
  public func save(_ key: String) throws {
    lock.withLock { self.key = key }
  }

  /// Forgets the key.
  public func delete() throws {
    lock.withLock { key = nil }
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
