import Foundation
import Security

/// Where the Anthropic API key lives. The app uses the Keychain; tests use memory.
public protocol KeyStore: Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

public struct KeyStoreError: Error, CustomStringConvertible, Equatable, Sendable {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain \(operation): \(message)"
    }
}

/// A generic password item in the login keychain. The ad-hoc code signature's
/// bundle-identifier requirement (see `scripts/bundle.sh`) keeps the item
/// readable across rebuilds.
public struct KeychainKeyStore: KeyStore {
    public static let service = "com.ahcarpenter.mentor"
    public static let account = "anthropic-api-key"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeyStore.service,
            kSecAttrAccount as String: KeychainKeyStore.account,
        ]
    }

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
            insert[kSecAttrLabel as String] = "Mentor Anthropic API key"
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeyStoreError(status: addStatus, operation: "add") }
        default:
            throw KeyStoreError(status: status, operation: "update")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError(status: status, operation: "delete")
        }
    }
}

/// A key store that forgets on exit, for tests and snapshots.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() throws -> String? {
        lock.withLock { key }
    }

    public func save(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    public func delete() throws {
        lock.withLock { key = nil }
    }
}

/// Helpers that let the UI talk about a key without ever showing it.
public enum APIKey {
    /// Trims whitespace. Empty or internally spaced keys are rejected; the
    /// format is otherwise not checked so future key shapes keep working.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return trimmed
    }

    /// The only part of a key that is ever displayed or logged.
    public static func lastFour(_ key: String) -> String {
        String(key.suffix(4))
    }
}
