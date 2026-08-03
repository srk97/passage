@testable import PassageVisualModel
import PassageCore
import Foundation
import Testing

@Suite("Active visual model selection", .serialized)
struct VisualModelSelectionStoreTests {
    @Test("A hash-pinned reference round trips through one atomic owner-only file")
    func roundTripAndReplace() async throws {
        let fixture = SelectionFixture()
        let store = VisualModelSelectionStore(fileURL: fixture.file)
        let first = Self.reference(identifier: "pe-s16", hashScalar: "a")
        let second = Self.reference(identifier: "pe-t16", hashScalar: "b")

        try await store.save(first)
        try Self.expectPermissions(fixture.root, 0o700)
        try Self.expectPermissions(fixture.file, 0o600)
        try Self.expectBackgroundProtection(fixture.file)
        #expect(try await store.load() == first)

        try await store.save(second)
        try Self.expectPermissions(fixture.file, 0o600)
        try Self.expectBackgroundProtection(fixture.file)
        #expect(try await store.load() == second)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                == [VisualModelSelectionStore.filename]
        )
    }

    @Test("Missing and cleared preferences mean there is no active model")
    func missingAndClear() async throws {
        let fixture = SelectionFixture()
        let store = VisualModelSelectionStore(fileURL: fixture.file)

        #expect(try await store.load() == nil)
        #expect(!(try await store.clear()))
        try await store.save(Self.reference())
        #expect(try await store.clear())
        #expect(try await store.load() == nil)
        #expect(!(try await store.clear()))
    }

    @Test("Loads surface protection migration failures without changing the preference")
    func protectionFailureIsSurfaced() async throws {
        let fixture = SelectionFixture()
        let writer = VisualModelSelectionStore(fileURL: fixture.file)
        try await writer.save(Self.reference())
        let bytesBeforeLoad = try Data(contentsOf: fixture.file)
        let reader = VisualModelSelectionStore(
            fileURL: fixture.file,
            fileManager: SelectionProtectionFailingFileManager()
        )

        do {
            _ = try await reader.load()
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: fixture.file) == bytesBeforeLoad)
    }

    @Test("Malformed, truncated, and checksum-tampered preferences fail closed")
    func corruptionFailsClosed() async throws {
        let fixture = SelectionFixture()
        let store = VisualModelSelectionStore(fileURL: fixture.file)

        try await store.save(Self.reference())
        try Self.overwriteOwnerOnly(Data("{\"formatVersion\":".utf8), at: fixture.file)
        await Self.expectError(.corruptPreference) {
            _ = try await store.load()
        }

        try await store.save(Self.reference(identifier: "pe-s16"))
        let stored = try Data(contentsOf: fixture.file)
        let text = try #require(String(data: stored, encoding: .utf8))
        #expect(text.contains("pe-s16"))
        let tampered = text.replacingOccurrences(of: "pe-s16", with: "pe-x16")
        try Self.overwriteOwnerOnly(Data(tampered.utf8), at: fixture.file)
        await Self.expectError(.corruptPreference) {
            _ = try await store.load()
        }

        try Self.overwriteOwnerOnly(
            Data(repeating: 0x41, count: VisualModelSelectionStore.maximumStoredBytes + 1),
            at: fixture.file
        )
        await Self.expectError(.preferenceTooLarge) {
            _ = try await store.load()
        }
    }

    @Test("Over-permissive files and symbolic links are never followed")
    func unsafeLocationsFailClosed() async throws {
        let fixture = SelectionFixture()
        let store = VisualModelSelectionStore(fileURL: fixture.file)
        try await store.save(Self.reference())

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.file.path
        )
        await Self.expectError(.unsafeLocation) {
            _ = try await store.load()
        }
        // Clear remains a recovery path even when the preference mode itself
        // is corrupt; it still validates the private parent and exact file type.
        #expect(try await store.clear())
        let external = fixture.root.appendingPathComponent("outside.json")
        try Data("must survive".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.file,
            withDestinationURL: external
        )
        await Self.expectError(.unsafeLocation) {
            _ = try await store.load()
        }
        #expect(try await store.clear())
        #expect(try Data(contentsOf: external) == Data("must survive".utf8))
    }

    @Test("Invalid identity components are rejected before any file is created")
    func invalidReferencesAreRejected() async {
        let fixture = SelectionFixture()
        let store = VisualModelSelectionStore(fileURL: fixture.file)
        let invalid = VisualModelPackReference(
            identifier: "../escape",
            revision: "v1",
            manifestSHA256: String(repeating: "A", count: 64)
        )

        await Self.expectError(.invalidReference) {
            try await store.save(invalid)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    private static func reference(
        identifier: String = "pe-s16",
        hashScalar: Character = "a"
    ) -> VisualModelPackReference {
        VisualModelPackReference(
            identifier: identifier,
            revision: "coreml-w8-v1",
            manifestSHA256: String(repeating: hashScalar, count: 64)
        )
    }

    private static func overwriteOwnerOnly(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func expectPermissions(_ url: URL, _ expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == expected)
    }

    private static func expectBackgroundProtection(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(
            attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
    }

    private static func expectError(
        _ expected: VisualModelSelectionStoreError,
        performing operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected visual model selection failure: \(expected)")
        } catch let error as VisualModelSelectionStoreError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private final class SelectionProtectionFailingFileManager: FileManager, @unchecked Sendable {
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

private final class SelectionFixture {
    let root: URL
    let file: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-visual-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        file = root.appendingPathComponent(
            VisualModelSelectionStore.filename,
            isDirectory: false
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
