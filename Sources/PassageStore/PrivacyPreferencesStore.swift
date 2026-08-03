import PassageCore
import CryptoKit
import Foundation

public enum PrivacyPreferencesStoreError: Error, LocalizedError, Sendable {
    case invalidEnvelope
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            "Passage's encrypted privacy preferences are not in a recognized format."
        case .authenticationFailed:
            "Passage could not authenticate its privacy preferences."
        }
    }
}

public actor PrivacyPreferencesStore {
    private static let magic = Data("CHRPRIV1".utf8)
    private static let keyContext = "primary-preferences-v1"

    private let url: URL
    private let vaultKey: VaultKey
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        paths: PassagePaths,
        vaultKey: VaultKey,
        fileManager: FileManager = .default
    ) {
        url = paths.privacyPreferences
        self.vaultKey = vaultKey
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func load() throws -> PrivacyPreferences {
        guard fileManager.fileExists(atPath: url.path) else { return .default }
        try PassageFileProtection.prepareForBackgroundAccess(
            at: url,
            fileManager: fileManager
        )
        let stored = try Data(contentsOf: url, options: [.mappedIfSafe])

        let plaintext: Data
        if stored.starts(with: Self.magic) {
            plaintext = try open(stored)
        } else {
            // One-time migration from the prototype's owner-only JSON sidecar.
            // A valid legacy value is atomically replaced by a sealed envelope
            // before it is returned to the application.
            var legacy = try decoder.decode(PrivacyPreferences.self, from: stored)
            legacy.normalize()
            try save(legacy)
            return legacy
        }

        var preferences = try decoder.decode(PrivacyPreferences.self, from: plaintext)
        preferences.normalize()
        return preferences
    }

    public func save(_ value: PrivacyPreferences) throws {
        var normalized = value
        normalized.normalize()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )

        let plaintext = try encoder.encode(normalized)
        let combined = try vaultKey.withDerivedKeyBytes(
            for: .privacyPreferences,
            context: Self.keyContext
        ) { keyBytes in
            let key = SymmetricKey(data: keyBytes)
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.magic)
            guard let combined = box.combined else {
                throw PrivacyPreferencesStoreError.invalidEnvelope
            }
            return combined
        }
        try (Self.magic + combined).write(
            to: url,
            options: PassageFileProtection.atomicWritingOptions
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func open(_ stored: Data) throws -> Data {
        let minimumEnvelopeSize = Self.magic.count + 12 + 16
        guard stored.count >= minimumEnvelopeSize else {
            throw PrivacyPreferencesStoreError.invalidEnvelope
        }
        let combined = stored.dropFirst(Self.magic.count)
        do {
            return try vaultKey.withDerivedKeyBytes(
                for: .privacyPreferences,
                context: Self.keyContext
            ) { keyBytes in
                let key = SymmetricKey(data: keyBytes)
                let box = try AES.GCM.SealedBox(combined: combined)
                return try AES.GCM.open(box, using: key, authenticating: Self.magic)
            }
        } catch {
            throw PrivacyPreferencesStoreError.authenticationFailed
        }
    }
}
