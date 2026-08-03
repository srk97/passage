import PassageCore
import PassageStore
import CryptoKit
import Foundation

/// A small encrypted cache for provider output. Cache identity includes both the
/// stable activity-session ID and the exact bounded-content fingerprint, so any
/// source change is a miss rather than stale intelligence.
public actor SessionIntelligenceCache {
    private static let magic = Data("CHRINTEL".utf8)
    private static let version: UInt8 = 1
    private static let maximumEntryBytes = 512 * 1_024

    private let directory: URL
    private let vaultKey: VaultKey
    private let fileManager: FileManager

    public init(
        paths: PassagePaths,
        vaultKey: VaultKey,
        fileManager: FileManager = .default
    ) {
        directory = paths.sessionIntelligenceCache
        self.vaultKey = vaultKey
        self.fileManager = fileManager
    }

    public func load(
        activitySessionID: ActivitySessionID,
        contentFingerprint: String
    ) throws -> SessionEnrichment? {
        let identity = try Self.cacheIdentity(
            activitySessionID: activitySessionID,
            contentFingerprint: contentFingerprint
        )
        let url = directory.appendingPathComponent(identity + ".bin", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let byteCount = attributes[.size] as? NSNumber,
           byteCount.intValue > Self.maximumEntryBytes {
            throw SessionIntelligenceError.cacheCorrupted
        }
        try PassageFileProtection.prepareForBackgroundAccess(at: url, fileManager: fileManager)
        let envelope = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard envelope.count <= Self.maximumEntryBytes,
              envelope.count > Self.magic.count + 1,
              envelope.starts(with: Self.magic),
              envelope[Self.magic.count] == Self.version else {
            throw SessionIntelligenceError.cacheCorrupted
        }

        let headerLength = Self.magic.count + 1
        let header = Data(envelope[..<headerLength])
        let combined = Data(envelope[headerLength...])
        let associatedData = header + Data(identity.utf8)
        let plaintext: Data
        do {
            plaintext = try vaultKey.withDerivedKeyBytes(
                for: .sessionIntelligenceCache,
                context: identity
            ) { keyBytes in
                let key = SymmetricKey(data: keyBytes)
                let sealed = try AES.GCM.SealedBox(combined: combined)
                return try AES.GCM.open(sealed, using: key, authenticating: associatedData)
            }
        } catch {
            throw SessionIntelligenceError.cacheAuthenticationFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let enrichment = try? decoder.decode(SessionEnrichment.self, from: plaintext) else {
            throw SessionIntelligenceError.cacheCorrupted
        }
        guard enrichment.activitySessionID == activitySessionID,
              enrichment.contentFingerprint == contentFingerprint else {
            return nil
        }
        return enrichment
    }

    public func store(_ enrichment: SessionEnrichment) throws {
        let identity = try Self.cacheIdentity(
            activitySessionID: enrichment.activitySessionID,
            contentFingerprint: enrichment.contentFingerprint
        )
        try ensureDirectory()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(enrichment)
        guard plaintext.count <= Self.maximumEntryBytes / 2 else {
            throw SessionIntelligenceError.cacheCorrupted
        }

        var header = Self.magic
        header.append(Self.version)
        let associatedData = header + Data(identity.utf8)
        let combined = try vaultKey.withDerivedKeyBytes(
            for: .sessionIntelligenceCache,
            context: identity
        ) { keyBytes in
            let key = SymmetricKey(data: keyBytes)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
            guard let combined = sealed.combined else {
                throw SessionIntelligenceError.cacheCorrupted
            }
            return combined
        }
        let envelope = header + combined
        let url = directory.appendingPathComponent(identity + ".bin", isDirectory: false)
        try envelope.write(to: url, options: PassageFileProtection.atomicWritingOptions)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove(
        activitySessionID: ActivitySessionID,
        contentFingerprint: String
    ) throws {
        let identity = try Self.cacheIdentity(
            activitySessionID: activitySessionID,
            contentFingerprint: contentFingerprint
        )
        let url = directory.appendingPathComponent(identity + ".bin", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Removes every derived session summary while leaving the encrypted frame
    /// index, media, preferences, and any sibling file under Passage's root
    /// untouched. The actor and fixed PassagePaths child make the scope exact.
    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            try ensureDirectory()
            return
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SessionIntelligenceError.cacheCorrupted
        }
        try fileManager.removeItem(at: directory)
        try ensureDirectory()
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func cacheIdentity(
        activitySessionID: ActivitySessionID,
        contentFingerprint: String
    ) throws -> String {
        guard !activitySessionID.rawValue.isEmpty,
              activitySessionID.rawValue.utf8.count <= SessionIntelligenceInput.maximumIdentifierUTF8Bytes,
              !contentFingerprint.isEmpty,
              contentFingerprint.utf8.count <= 128 else {
            throw SessionIntelligenceError.cacheCorrupted
        }
        var identity = Data(activitySessionID.rawValue.utf8)
        identity.append(0)
        identity.append(contentsOf: contentFingerprint.utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}
