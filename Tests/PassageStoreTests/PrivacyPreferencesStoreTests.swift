import PassageCore
import PassageStore
import Foundation
import Testing

@Suite("Privacy preferences")
struct PrivacyPreferencesStoreTests {
    @Test("Defaults are private and normalized")
    func defaults() {
        let value = PrivacyPreferences.default
        #expect(value.excludedApplications.contains { $0.bundleIdentifier == "com.apple.Passwords" })
        #expect(value.hideCursor)
        #expect(value.captureFocusedWindowOnly)
        #expect(value.pauseAfterInactivityMinutes == 5)
        #expect(value.capturePolicy.inactivityPause == .seconds(300))
        #expect(value.retentionDays == 0)
        #expect(value.retentionPolicy.maximumAgeDays == nil)
        #expect(value.retentionPolicy.preserveTextAfterMediaExpiry)
    }

    @Test("Retention days normalize: 0 keeps forever, other values clamp to 1-365")
    func retentionNormalization() {
        #expect(PrivacyPreferences(retentionDays: 0).retentionDays == 0)
        #expect(PrivacyPreferences(retentionDays: -3).retentionDays == 1)
        #expect(PrivacyPreferences(retentionDays: 400).retentionDays == 365)
        #expect(PrivacyPreferences(retentionDays: 14).retentionPolicy.maximumAgeDays == 14)
        #expect(PrivacyPreferences(retentionDays: 0).retentionPolicy.maximumAgeDays == nil)
    }

    @Test("Domains and applications normalize and deduplicate")
    func normalization() {
        var value = PrivacyPreferences(excludedApplications: [], excludedDomains: [])
        value.addDomain(" https://WWW.Example.com/private ")
        value.addDomain("example.com")
        value.addApplication(ApplicationExclusion(bundleIdentifier: "app.secret", displayName: "Secret"))
        value.addApplication(ApplicationExclusion(bundleIdentifier: "app.secret", displayName: "Secret App"))
        #expect(value.excludedDomains == ["example.com"])
        #expect(value.excludedApplications == [ApplicationExclusion(bundleIdentifier: "app.secret", displayName: "Secret App")])
    }

    @Test("Round trip uses owner-only file permissions")
    func roundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-privacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let key = try VaultKey.testing(bytes: Data(repeating: 0x31, count: 32))
        let store = PrivacyPreferencesStore(paths: paths, vaultKey: key)
        var expected = PrivacyPreferences.default
        expected.retentionDays = 14
        expected.maximumStorageGigabytes = 8
        expected.addDomain("private.example")
        try await store.save(expected)

        let sealed = try Data(contentsOf: paths.privacyPreferences)
        #expect(sealed.starts(with: Data("CHRPRIV1".utf8)))
        #expect(!sealed.contains(Data("private.example".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.privacyPreferences.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #expect(protection == .completeUntilFirstUserAuthentication)

        let actual = try await store.load()
        #expect(actual == expected)
    }

    @Test("A wrong key cannot read exclusions")
    func wrongKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-privacy-wrong-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let firstKey = try VaultKey.testing(bytes: Data(repeating: 0x11, count: 32))
        let secondKey = try VaultKey.testing(bytes: Data(repeating: 0x22, count: 32))
        let writer = PrivacyPreferencesStore(paths: paths, vaultKey: firstKey)
        try await writer.save(.default)

        let reader = PrivacyPreferencesStore(paths: paths, vaultKey: secondKey)
        await #expect(throws: PrivacyPreferencesStoreError.self) {
            _ = try await reader.load()
        }
    }

    @Test("A protection migration failure is surfaced before preferences are read")
    func protectionFailureIsSurfaced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-privacy-protection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let key = try VaultKey.testing(bytes: Data(repeating: 0x53, count: 32))
        try await PrivacyPreferencesStore(paths: paths, vaultKey: key).save(.default)
        let bytesBeforeLoad = try Data(contentsOf: paths.privacyPreferences)
        let reader = PrivacyPreferencesStore(
            paths: paths,
            vaultKey: key,
            fileManager: ProtectionFailingFileManager()
        )

        do {
            _ = try await reader.load()
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: paths.privacyPreferences) == bytesBeforeLoad)
    }
}

private final class ProtectionFailingFileManager: FileManager, @unchecked Sendable {
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
