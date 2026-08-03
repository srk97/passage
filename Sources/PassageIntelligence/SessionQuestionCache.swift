import PassageCore
import PassageStore
import CryptoKit
import Foundation

/// A purpose-separated encrypted cache for explicit session questions.
///
/// The filename is a hash of the already content-addressed request identity.
/// Question text, answer text, source citations, and all answer metadata exist
/// only inside the authenticated AES-GCM envelope.
public actor SessionQuestionCache {
    private static let magic = Data("CHRASKQ".utf8)
    private static let version: UInt8 = 1
    private static let maximumEntryBytes = 512 * 1_024
    private static let maximumPlaintextBytes = 256 * 1_024

    private let directory: URL
    private let vaultKey: VaultKey
    private let fileManager: FileManager

    public init(
        paths: PassagePaths,
        vaultKey: VaultKey,
        fileManager: FileManager = .default
    ) {
        directory = paths.sessionQuestionCache
        self.vaultKey = vaultKey
        self.fileManager = fileManager
    }

    public func load(for input: SessionQuestionInput) throws -> SessionQuestionAnswer? {
        try load(requestFingerprint: input.requestFingerprint)
    }

    public func load(requestFingerprint: String) throws -> SessionQuestionAnswer? {
        let identity = try Self.cacheIdentity(requestFingerprint: requestFingerprint)
        let url = directory.appendingPathComponent(identity + ".bin", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try validateRegularFile(at: url)

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
                for: .sessionQuestionCache,
                context: identity
            ) { keyBytes in
                let key = SymmetricKey(data: keyBytes)
                let sealed = try AES.GCM.SealedBox(combined: combined)
                return try AES.GCM.open(sealed, using: key, authenticating: associatedData)
            }
        } catch {
            throw SessionIntelligenceError.cacheAuthenticationFailed
        }
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw SessionIntelligenceError.cacheCorrupted
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let answer = try? decoder.decode(SessionQuestionAnswer.self, from: plaintext) else {
            throw SessionIntelligenceError.cacheCorrupted
        }
        try Self.validate(answer, requestFingerprint: requestFingerprint)
        return answer
    }

    public func store(_ answer: SessionQuestionAnswer) throws {
        try Self.validate(answer, requestFingerprint: answer.requestFingerprint)
        let identity = try Self.cacheIdentity(requestFingerprint: answer.requestFingerprint)
        try ensureDirectory()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(answer)
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw SessionIntelligenceError.cacheCorrupted
        }

        var header = Self.magic
        header.append(Self.version)
        let associatedData = header + Data(identity.utf8)
        let combined = try vaultKey.withDerivedKeyBytes(
            for: .sessionQuestionCache,
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
        guard envelope.count <= Self.maximumEntryBytes else {
            throw SessionIntelligenceError.cacheCorrupted
        }

        let url = directory.appendingPathComponent(identity + ".bin", isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try validateRegularFile(at: url)
        }
        try envelope.write(to: url, options: PassageFileProtection.atomicWritingOptions)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove(for input: SessionQuestionInput) throws {
        try remove(requestFingerprint: input.requestFingerprint)
    }

    public func remove(requestFingerprint: String) throws {
        let identity = try Self.cacheIdentity(requestFingerprint: requestFingerprint)
        let url = directory.appendingPathComponent(identity + ".bin", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try validateRegularFile(at: url)
        try fileManager.removeItem(at: url)
    }

    /// Clears only explicit-question answers, leaving session briefs, encrypted
    /// frames, media, preferences, and sibling Passage files untouched.
    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            try ensureDirectory()
            return
        }
        try validateDirectory()
        try fileManager.removeItem(at: directory)
        try ensureDirectory()
    }

    private func ensureDirectory() throws {
        if fileManager.fileExists(atPath: directory.path) {
            try validateDirectory()
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func validateDirectory() throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SessionIntelligenceError.cacheCorrupted
        }
    }

    private func validateRegularFile(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SessionIntelligenceError.cacheCorrupted
        }
    }

    private static func cacheIdentity(requestFingerprint: String) throws -> String {
        guard requestFingerprint.count == 64,
              requestFingerprint.utf8.count == 64,
              requestFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw SessionIntelligenceError.cacheCorrupted
        }
        var identity = Data("chronicle-session-question-cache/v1".utf8)
        identity.append(0)
        identity.append(contentsOf: requestFingerprint.utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(
        _ answer: SessionQuestionAnswer,
        requestFingerprint: String
    ) throws {
        guard answer.requestFingerprint == requestFingerprint,
              !answer.activitySessionID.rawValue.isEmpty,
              answer.activitySessionID.rawValue.utf8.count <= SessionIntelligenceInput.maximumIdentifierUTF8Bytes,
              !answer.question.isEmpty,
              answer.question.utf8.count <= SessionQuestionInput.maximumQuestionUTF8Bytes,
              isFingerprint(answer.contentFingerprint),
              isFingerprint(answer.questionFingerprint),
              !answer.provider.isEmpty,
              !answer.model.isEmpty,
              answer.provider.utf8.count <= SessionQuestionInput.maximumProviderIdentifierUTF8Bytes,
              answer.model.utf8.count <= SessionQuestionInput.maximumProviderIdentifierUTF8Bytes,
              (1...SessionQuestionInput.maximumSourceCount).contains(answer.evidenceMomentCount),
              answer.evidenceTextUTF8ByteCount > 0,
              answer.question.utf8.count + answer.evidenceTextUTF8ByteCount
                <= SessionQuestionInput.maximumTotalTextUTF8Bytes,
              answer.evidenceThrough != nil else {
            throw SessionIntelligenceError.cacheCorrupted
        }

        switch answer.status {
        case .answered:
            guard (1...SessionQuestionAnswer.maximumClaimCount).contains(answer.claims.count) else {
                throw SessionIntelligenceError.cacheCorrupted
            }
        case .insufficientEvidence:
            guard answer.claims.isEmpty else {
                throw SessionIntelligenceError.cacheCorrupted
            }
        }
        for claim in answer.claims {
            guard !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  claim.text.utf8.count <= 800,
                  (1...6).contains(claim.sourceFrameIDs.count),
                  claim.sourceFrameIDs.allSatisfy({
                      !$0.rawValue.isEmpty
                          && $0.rawValue.utf8.count
                              <= SessionIntelligenceInput.maximumIdentifierUTF8Bytes
                  }) else {
                throw SessionIntelligenceError.cacheCorrupted
            }
        }
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.count == 64
            && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
