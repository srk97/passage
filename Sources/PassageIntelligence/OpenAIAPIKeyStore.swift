import Foundation
import Security

public enum OpenAIAPIKeyStoreError: Error, LocalizedError, Sendable {
    case invalidAPIKey
    case malformedKeychainItem
    case keychainFailure(operation: String, status: OSStatus, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "The OpenAI API key is empty or malformed."
        case .malformedKeychainItem:
            "The saved OpenAI API key is not valid UTF-8 text."
        case .keychainFailure(let operation, let status, let message):
            "Keychain \(operation) failed (\(status)): \(message)"
        }
    }
}

/// Explicit storage for the opt-in provider credential.
///
/// This type never consults process environment, user defaults, configuration
/// files, or Passage's vault root. The generic-password item is service-scoped,
/// non-synchronizing, and only accessible while this device is unlocked.
public struct OpenAIAPIKeyStore: Sendable {
    public let service: String
    public let account: String

    public init(
        service: String = "app.chronicle.session-intelligence.openai",
        account: String = "responses-api-key-v1"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 16_384,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let bytes = normalized.data(using: .utf8) else {
            throw OpenAIAPIKeyStoreError.invalidAPIKey
        }

        let attributes: [String: Any] = [
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = baseQuery
            attributes.forEach { addition[$0.key] = $0.value }
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw Self.keychainError(operation: "save", status: status)
        }
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw Self.keychainError(operation: "load", status: status)
        }
        guard let bytes = result as? Data,
              let apiKey = String(data: bytes, encoding: .utf8),
              !apiKey.isEmpty else {
            throw OpenAIAPIKeyStoreError.malformedKeychainItem
        }
        return apiKey
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.keychainError(operation: "delete", status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func keychainError(
        operation: String,
        status: OSStatus
    ) -> OpenAIAPIKeyStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Unknown Keychain error"
        return .keychainFailure(operation: operation, status: status, message: message)
    }
}
