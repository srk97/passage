import PassageCore
@testable import PassageIntelligence
import PassageStore
import CryptoKit
import Foundation
import Testing

@Suite("Encrypted session intelligence cache")
struct SessionIntelligenceCacheTests {
    @Test("Round trips ciphertext and misses when source fingerprint changes")
    func encryptedRoundTripAndStaleMiss() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = SessionIntelligenceCache(paths: fixture.paths, vaultKey: fixture.key)
        let value = Self.enrichment(fingerprint: "fingerprint-current")

        try await cache.store(value)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.sessionIntelligenceCache,
            includingPropertiesForKeys: nil
        )
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(!file.lastPathComponent.contains(value.activitySessionID.rawValue))
        #expect(!file.lastPathComponent.contains(value.contentFingerprint))
        let ciphertext = try Data(contentsOf: file)
        #expect(ciphertext.range(of: Data(value.summary.text.utf8)) == nil)
        #expect(ciphertext.range(of: Data(value.whereLeftOff.text.utf8)) == nil)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber).intValue & 0o777
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(
                atPath: fixture.paths.sessionIntelligenceCache.path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        #expect(
            fileAttributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )

        let loaded = try await cache.load(
            activitySessionID: value.activitySessionID,
            contentFingerprint: value.contentFingerprint
        )
        #expect(loaded == value)
        let stale = try await cache.load(
            activitySessionID: value.activitySessionID,
            contentFingerprint: "fingerprint-stale"
        )
        #expect(stale == nil)
    }

    @Test("A different vault root cannot authenticate a cache entry")
    func wrongKeyFailsAuthentication() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let value = Self.enrichment(fingerprint: "fingerprint-auth")
        try await SessionIntelligenceCache(paths: fixture.paths, vaultKey: fixture.key).store(value)
        let otherKey = try VaultKey.testing(bytes: Data(repeating: 0x99, count: VaultKey.byteCount))
        let otherCache = SessionIntelligenceCache(paths: fixture.paths, vaultKey: otherKey)

        do {
            _ = try await otherCache.load(
                activitySessionID: value.activitySessionID,
                contentFingerprint: value.contentFingerprint
            )
            Issue.record("Expected cache authentication to fail")
        } catch let error as SessionIntelligenceError {
            #expect(error == .cacheAuthenticationFailed)
        }
    }

    @Test("Loads surface protection migration failures without changing ciphertext")
    func protectionFailureIsSurfaced() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let value = Self.enrichment(fingerprint: "fingerprint-protection")
        try await SessionIntelligenceCache(paths: fixture.paths, vaultKey: fixture.key).store(value)
        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.paths.sessionIntelligenceCache,
                includingPropertiesForKeys: nil
            ).first
        )
        let bytesBeforeLoad = try Data(contentsOf: file)
        let reader = SessionIntelligenceCache(
            paths: fixture.paths,
            vaultKey: fixture.key,
            fileManager: IntelligenceProtectionFailingFileManager()
        )

        do {
            _ = try await reader.load(
                activitySessionID: value.activitySessionID,
                contentFingerprint: value.contentFingerprint
            )
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: file) == bytesBeforeLoad)
    }

    @Test("Remove all clears only the fixed cache directory")
    func removeAllIsScoped() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let cache = SessionIntelligenceCache(paths: fixture.paths, vaultKey: fixture.key)
        let first = Self.enrichment(fingerprint: "fingerprint-first")
        let second = Self.enrichment(fingerprint: "fingerprint-second")
        try await cache.store(first)
        try await cache.store(second)

        try FileManager.default.createDirectory(at: fixture.paths.root, withIntermediateDirectories: true)
        let sibling = fixture.paths.root.appendingPathComponent("must-survive.txt")
        try Data("not derived intelligence".utf8).write(to: sibling, options: .atomic)

        try await cache.removeAll()

        #expect(try await cache.load(
            activitySessionID: first.activitySessionID,
            contentFingerprint: first.contentFingerprint
        ) == nil)
        #expect(try await cache.load(
            activitySessionID: second.activitySessionID,
            contentFingerprint: second.contentFingerprint
        ) == nil)
        #expect(try Data(contentsOf: sibling) == Data("not derived intelligence".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.sessionIntelligenceCache,
            includingPropertiesForKeys: nil
        )
        #expect(remaining.isEmpty)
    }

    @Test("Safety identifiers are stable, pseudonymous, and purpose separated")
    func safetyIdentifier() throws {
        let key = try VaultKey.testing(bytes: Data(repeating: 0x41, count: VaultKey.byteCount))
        let other = try VaultKey.testing(bytes: Data(repeating: 0x42, count: VaultKey.byteCount))
        let identifier = key.sessionIntelligenceSafetyIdentifier()
        let cacheMaterialDigest = key.withDerivedKeyBytes(for: .sessionIntelligenceCache) {
            Data(SHA256.hash(data: Data($0))).map { String(format: "%02x", $0) }.joined()
        }

        #expect(identifier == key.sessionIntelligenceSafetyIdentifier())
        #expect(identifier != other.sessionIntelligenceSafetyIdentifier())
        #expect(identifier != cacheMaterialDigest)
        #expect(identifier.count == 64)
        #expect(identifier.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("Empty API keys fail before any Keychain operation")
    func invalidAPIKey() {
        #expect(throws: OpenAIAPIKeyStoreError.self) {
            try OpenAIAPIKeyStore(service: "app.passage.tests.\(UUID().uuidString)").save(" \n ")
        }
    }

    private static func enrichment(fingerprint: String) -> SessionEnrichment {
        let first = FrameID(rawValue: "source-one")
        let second = FrameID(rawValue: "source-two")
        return SessionEnrichment(
            activitySessionID: ActivitySessionID(rawValue: "private-session-id"),
            title: SessionIntelligenceClaim(text: "Launch planning", sourceFrameIDs: [first]),
            summary: SessionIntelligenceClaim(
                text: "Secret summary that must only occur in ciphertext.",
                sourceFrameIDs: [first, second]
            ),
            whereLeftOff: SessionIntelligenceClaim(
                text: "Private stopping point that must not be plaintext.",
                sourceFrameIDs: [second]
            ),
            nextActions: [
                SessionIntelligenceNextAction(text: "Finish checklist", sourceFrameIDs: [second]),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "openai-responses",
            model: "gpt-5.6-luna",
            contentFingerprint: fingerprint
        )
    }
}

private final class IntelligenceProtectionFailingFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        if attributes[.protectionKey] != nil {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileReadNoPermission.rawValue
            )
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class CacheFixture {
    let root: URL
    let paths: PassagePaths
    let key: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-intelligence-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        key = try VaultKey.testing(bytes: Data(repeating: 0x41, count: VaultKey.byteCount))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
