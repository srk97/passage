import CryptoKit
import Foundation
import Security

/// Stable domains for keys derived from Passage's vault root.
///
/// Keeping these purposes distinct prevents a key used by one storage layer from
/// being reused by another, even though they share a single root in Keychain.
public enum VaultKeyPurpose: String, Sendable {
    case databaseIndex = "app.chronicle.vault/sqlcipher-index/v1"
    case frameMedia = "app.chronicle.vault/frame-media/v1"
    case thumbnailMedia = "app.chronicle.vault/thumbnail-media/v1"
    case mediaAssetIdentifier = "app.chronicle.vault/media-asset-identifier/v1"
    case privacyPreferences = "app.chronicle.vault/privacy-preferences/v1"
    case sessionIntelligenceCache = "app.chronicle.vault/session-intelligence-cache/v1"
    case sessionQuestionCache = "app.chronicle.vault/session-question-cache/v1"
    case sessionIntelligenceSafetyIdentifier = "app.chronicle.vault/session-intelligence-safety-id/v1"
}

public enum VaultKeyError: Error, LocalizedError, Sendable {
    case invalidKeyLength(Int)
    case keyNotFound
    case keychainFailure(operation: String, status: OSStatus, message: String)
    case malformedKeychainItem
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let count):
            "A Passage vault root must be exactly 32 bytes; received \(count)."
        case .keyNotFound:
            "Passage's vault key does not exist. Open Passage before using this tool."
        case .keychainFailure(let operation, let status, let message):
            "Keychain \(operation) failed (\(status)): \(message)"
        case .malformedKeychainItem:
            "Passage's Keychain item is present but is not a valid 256-bit vault root."
        case .randomGenerationFailed(let status):
            "Secure random generation failed with status \(status)."
        }
    }
}

/// An opaque 256-bit root key.
///
/// The type intentionally has no Codable, printable, equality, or raw-data API.
/// Callers can only use purpose-separated derived bytes within a non-escaping
/// closure. This keeps the root itself out of logs, preferences, and database
/// bindings.
public struct VaultKey: Sendable {
    public static let byteCount = 32

    private static let derivationSalt = Data("app.chronicle.vault/hkdf-sha256/v1".utf8)
    private let root: SymmetricKey

    private init(validatedBytes: Data) {
        root = SymmetricKey(data: validatedBytes)
    }

    /// Creates a deterministic in-memory key for tests and ephemeral tools.
    /// Production code should load the root from `KeychainVaultKeyStore`.
    public static func testing(bytes: Data) throws -> VaultKey {
        guard bytes.count == byteCount else {
            throw VaultKeyError.invalidKeyLength(bytes.count)
        }
        return VaultKey(validatedBytes: bytes)
    }

    /// Supplies an HKDF-SHA256 subkey only for the duration of `body`.
    ///
    /// `context` can identify an individual encrypted object, such as a frame ID.
    /// The purpose is always included first, so equal context strings in different
    /// storage layers still produce unrelated keys.
    public func withDerivedKeyBytes<Result>(
        for purpose: VaultKeyPurpose,
        context: String = "",
        outputByteCount: Int = 32,
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        precondition(outputByteCount > 0, "Derived keys must contain at least one byte.")
        var info = Data(purpose.rawValue.utf8)
        if !context.isEmpty {
            info.append(0)
            info.append(contentsOf: context.utf8)
        }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root,
            salt: Self.derivationSalt,
            info: info,
            outputByteCount: outputByteCount
        )
        return try derived.withUnsafeBytes(body)
    }

    /// Returns a stable, device-local pseudonymous identifier suitable for an
    /// API `safety_identifier`. A dedicated HKDF domain prevents reuse of cache,
    /// database, or media key material. Hashing the derived secret before
    /// encoding means the value disclosed to a provider is not itself a subkey.
    public func sessionIntelligenceSafetyIdentifier() -> String {
        withDerivedKeyBytes(
            for: .sessionIntelligenceSafetyIdentifier,
            context: "openai-responses/v1"
        ) { secret in
            SHA256.hash(data: Data(secret))
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }
}

/// Loads Passage's one vault root from the macOS Keychain.
///
/// Builds carrying an authorized application-identifier entitlement use the
/// data-protection Keychain. Builds without that entitlement fall back to the
/// login Keychain while retaining device-only, when-unlocked, non-synchronizing
/// protection.
public struct KeychainVaultKeyStore: Sendable {
    private enum Backend {
        case dataProtection
        case login
    }

    public let service: String
    public let account: String

    public init(
        service: String = "app.chronicle.vault",
        account: String = "primary-v1"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> VaultKey {
        // Querying the data-protection backend from an ad-hoc executable can
        // stall before macOS reports errSecMissingEntitlement. Detect that
        // entitlement state up front so local builds open the vault immediately.
        guard Self.hasDataProtectionKeychainIdentity else {
            return try loadOrCreateLoginKey()
        }
        do {
            if let bytes = try loadBytes(from: .dataProtection) {
                return try VaultKey.testing(bytes: bytes)
            }

            // Preserve a vault first created by an ad-hoc local build. Once a
            // signed build can use the data-protection Keychain, seed it with
            // the same root so the existing encrypted history remains readable.
            if let legacyBytes = try loadBytes(from: .login) {
                do {
                    try add(legacyBytes, to: .dataProtection)
                    return try VaultKey.testing(bytes: legacyBytes)
                } catch let error as VaultKeyError {
                    if case .keychainFailure(_, let status, _) = error,
                       status == errSecDuplicateItem,
                       let existing = try loadBytes(from: .dataProtection) {
                        return try VaultKey.testing(bytes: existing)
                    }
                    throw error
                }
            }

            let bytes = try Self.secureRandomBytes(count: VaultKey.byteCount)
            do {
                try add(bytes, to: .dataProtection)
                return try VaultKey.testing(bytes: bytes)
            } catch let error as VaultKeyError {
                // Another Passage process may have won the create race.
                if case .keychainFailure(_, let status, _) = error,
                   status == errSecDuplicateItem,
                   let existing = try loadBytes(from: .dataProtection) {
                    return try VaultKey.testing(bytes: existing)
                }
                throw error
            }
        } catch {
            guard Self.isMissingEntitlement(error) else { throw error }
            return try loadOrCreateLoginKey()
        }
    }

    /// Loads Passage's existing vault root without creating or migrating any
    /// Keychain item. Read-only diagnostics use this API so a missing or
    /// inaccessible vault can never be mistaken for a new, empty vault.
    public func loadExisting() throws -> VaultKey {
        guard Self.hasDataProtectionKeychainIdentity else {
            guard let bytes = try loadBytes(from: .login) else {
                throw VaultKeyError.keyNotFound
            }
            return try VaultKey.testing(bytes: bytes)
        }

        do {
            if let bytes = try loadBytes(from: .dataProtection) {
                return try VaultKey.testing(bytes: bytes)
            }
        } catch {
            guard Self.isMissingEntitlement(error) else { throw error }
        }

        if let bytes = try loadBytes(from: .login) {
            return try VaultKey.testing(bytes: bytes)
        }
        throw VaultKeyError.keyNotFound
    }

    private func loadOrCreateLoginKey() throws -> VaultKey {
        if let bytes = try loadBytes(from: .login) {
            return try VaultKey.testing(bytes: bytes)
        }
        let bytes = try Self.secureRandomBytes(count: VaultKey.byteCount)
        do {
            try add(bytes, to: .login)
            return try VaultKey.testing(bytes: bytes)
        } catch let error as VaultKeyError {
            if case .keychainFailure(_, let status, _) = error,
               status == errSecDuplicateItem,
               let existing = try loadBytes(from: .login) {
                return try VaultKey.testing(bytes: existing)
            }
            throw error
        }
    }

    private func loadBytes(from backend: Backend) throws -> Data? {
        var query = baseQuery(for: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Self.keychainError(operation: "read", status: status)
        }
        guard let data = result as? Data, data.count == VaultKey.byteCount else {
            throw VaultKeyError.malformedKeychainItem
        }
        return data
    }

    private func add(_ bytes: Data, to backend: Backend) throws {
        var query = baseQuery(for: backend)
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Self.keychainError(operation: "create", status: status)
        }
    }

    private func baseQuery(for backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VaultKeyError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }

    private static func keychainError(operation: String, status: OSStatus) -> VaultKeyError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Unknown Keychain error"
        return .keychainFailure(operation: operation, status: status, message: message)
    }

    private static func isMissingEntitlement(_ error: Error) -> Bool {
        guard let vaultError = error as? VaultKeyError,
              case .keychainFailure(_, let status, _) = vaultError else {
            return false
        }
        return status == errSecMissingEntitlement
    }

    private static var hasDataProtectionKeychainIdentity: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let names = [
            "application-identifier",
            "com.apple.application-identifier",
            "keychain-access-groups",
        ]
        return names.contains { name in
            SecTaskCopyValueForEntitlement(task, name as CFString, nil) != nil
        }
    }
}
