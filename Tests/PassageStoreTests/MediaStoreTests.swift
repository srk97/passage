import PassageCore
@testable import PassageStore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("Encrypted media store")
struct MediaStoreTests {
    @Test("Media is opaque, authenticated, date-free, and owner-only")
    func encryptedRoundTrip() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let id = FrameID(rawValue: "visible-frame-id")
        let paths = try await store.write(
            image: Self.testImage(),
            id: id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(paths.imagePath.hasSuffix(".bin"))
        #expect(paths.imagePath.contains("/v2/"))
        #expect(!paths.imagePath.contains(id.rawValue))
        #expect(!paths.imagePath.contains("2023"))
        let encryptedURL = fixture.paths.root.appendingPathComponent(paths.imagePath)
        let encrypted = try Data(contentsOf: encryptedURL)
        #expect(encrypted.prefix(8) == Data("CHRMEDIA".utf8))
        #expect(encrypted[8] == 2)
        #expect(encrypted.prefix(2) != Data([0xff, 0xd8]))

        let attributes = try FileManager.default.attributesOfItem(atPath: encryptedURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(
            attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )

        let decrypted = try await store.read(relativePath: paths.imagePath)
        #expect(CGImageSourceCreateWithData(decrypted as CFData, nil) != nil)
    }

    @Test("Session revocation synchronously blocks later plaintext reads")
    func revocationBlocksReads() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let receipt = try await store.write(
            image: Self.testImage(),
            id: FrameID(rawValue: "revoked-media"),
            capturedAt: .now
        )

        store.revoke()

        await #expect(throws: CancellationError.self) {
            _ = try await store.read(relativePath: receipt.imagePath)
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.root.appendingPathComponent(receipt.imagePath).path
        ))
    }

    @Test("Equal images share keyed assets across frame IDs")
    func contentAddressedDeduplication() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let image = Self.testImage()

        let first = try await store.write(
            image: image,
            id: FrameID(rawValue: "first-frame"),
            capturedAt: .now
        )
        let second = try await store.write(
            image: image,
            id: FrameID(rawValue: "second-frame"),
            capturedAt: .now.addingTimeInterval(1)
        )

        #expect(first.imagePath == second.imagePath)
        #expect(first.thumbnailPath == second.thumbnailPath)
        #expect(first.createdPaths.count == 2)
        #expect(second.createdPaths.isEmpty)

        await store.rollback(second)
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.root.appendingPathComponent(first.imagePath).path
        ))
    }

    @Test("A one-pixel change produces different asset identifiers")
    func contentChangeProducesDifferentPaths() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let first = try await store.write(
            image: Self.testImage(),
            id: FrameID(rawValue: "original"),
            capturedAt: .now
        )
        let changed = try await store.write(
            image: Self.testImage(changingOnePixel: true),
            id: FrameID(rawValue: "changed"),
            capturedAt: .now
        )

        #expect(first.imagePath != changed.imagePath)
        #expect(first.thumbnailPath != changed.thumbnailPath)
    }

    @Test("Asset identifiers are unrelated across vault keys")
    func vaultKeysProduceDifferentPaths() async throws {
        let fixture = try MediaFixture()
        let otherKey = try VaultKey.testing(bytes: Data(repeating: 0x24, count: 32))
        let firstStore = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let secondStore = MediaStore(paths: fixture.paths, vaultKey: otherKey)
        let image = Self.testImage()

        let first = try await firstStore.write(
            image: image,
            id: FrameID(rawValue: "first-vault"),
            capturedAt: .now
        )
        let second = try await secondStore.write(
            image: image,
            id: FrameID(rawValue: "second-vault"),
            capturedAt: .now
        )

        #expect(first.imagePath != second.imagePath)
        #expect(first.thumbnailPath != second.thumbnailPath)
    }

    @Test("A tampered preexisting asset is authenticated and never overwritten")
    func tamperedPreexistingAssetRefusesOverwrite() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let image = Self.testImage()
        let first = try await store.write(
            image: image,
            id: FrameID(rawValue: "first-write"),
            capturedAt: .now
        )
        let url = fixture.paths.root.appendingPathComponent(first.imagePath)
        var tampered = try Data(contentsOf: url)
        tampered[tampered.count - 1] ^= 0x80
        try tampered.write(to: url, options: .atomic)

        await #expect(throws: MediaStoreError.self) {
            _ = try await store.write(
                image: image,
                id: FrameID(rawValue: "retry"),
                capturedAt: .now
            )
        }
        #expect(try Data(contentsOf: url) == tampered)
    }

    @Test("Full-size pixels are preserved and thumbnails fit a 384-pixel edge")
    func representationDimensions() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let receipt = try await store.write(
            image: Self.testImage(width: 1_024, height: 512),
            id: FrameID(rawValue: "dimensions"),
            capturedAt: .now
        )

        let fullData = try await store.read(relativePath: receipt.imagePath)
        let fullImage = try #require(Self.decode(fullData))
        #expect(fullImage.width == 1_024)
        #expect(fullImage.height == 512)

        let thumbnailPath = try #require(receipt.thumbnailPath)
        let thumbnailData = try await store.read(relativePath: thumbnailPath)
        let thumbnail = try #require(Self.decode(thumbnailData))
        #expect(thumbnail.width == 384)
        #expect(thumbnail.height == 192)
    }

    @Test("Stored full frames are bounded to the maximum stored dimension with preserved aspect")
    func oversizedCaptureIsBoundedForStorage() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let receipt = try await store.write(
            image: Self.testImage(width: 5_120, height: 2_880),
            id: FrameID(rawValue: "oversized"),
            capturedAt: .now
        )

        let fullData = try await store.read(relativePath: receipt.imagePath)
        let fullImage = try #require(Self.decode(fullData))
        #expect(fullImage.width == MediaStore.maximumStoredDimension)
        #expect(fullImage.height == MediaStore.maximumStoredDimension * 2_880 / 5_120)
    }

    @Test("Wrong keys and tampering never yield pixels")
    func authentication() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let paths = try await store.write(
            image: Self.testImage(),
            id: FrameID(rawValue: "auth-frame"),
            capturedAt: .now
        )

        let wrongKey = try VaultKey.testing(bytes: Data(repeating: 0x99, count: 32))
        let wrongStore = MediaStore(paths: fixture.paths, vaultKey: wrongKey)
        await #expect(throws: MediaStoreError.self) {
            _ = try await wrongStore.read(relativePath: paths.imagePath)
        }

        let url = fixture.paths.root.appendingPathComponent(paths.imagePath)
        var tampered = try Data(contentsOf: url)
        tampered[tampered.count - 1] ^= 0x01
        try tampered.write(to: url)
        await #expect(throws: MediaStoreError.self) {
            _ = try await store.read(relativePath: paths.imagePath)
        }
    }

    @Test("Traversal paths are rejected")
    func traversal() async throws {
        let fixture = try MediaFixture()
        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        await #expect(throws: MediaStoreError.self) {
            _ = try await store.read(relativePath: "../../outside.jpg")
        }
    }

    @Test("Reads surface protection migration failures without changing ciphertext")
    func readProtectionFailureIsSurfaced() async throws {
        let fixture = try MediaFixture()
        let writer = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        let paths = try await writer.write(
            image: Self.testImage(),
            id: FrameID(rawValue: "protected-read"),
            capturedAt: .now
        )
        let url = fixture.paths.root.appendingPathComponent(paths.imagePath)
        let bytesBeforeRead = try Data(contentsOf: url)
        let reader = MediaStore(
            paths: fixture.paths,
            vaultKey: fixture.key,
            fileManager: MediaProtectionFailingFileManager()
        )

        do {
            _ = try await reader.read(relativePath: paths.imagePath)
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: url) == bytesBeforeRead)
    }

    @Test("Legacy JPEGs are encrypted in place and migration resumes safely")
    func legacyMigration() async throws {
        let fixture = try MediaFixture()
        let legacyDirectory = fixture.paths.media.appendingPathComponent("2026/07/28", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyURL = legacyDirectory.appendingPathComponent("legacy-frame.jpg")
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0xff, 0xd9])
        try jpeg.write(to: legacyURL)

        let store = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        #expect(try await store.migrateLegacyPlaintext() == 1)
        #expect(try await store.migrateLegacyPlaintext() == 0)
        let stored = try Data(contentsOf: legacyURL)
        #expect(stored.starts(with: Data("CHRMEDIA".utf8)))
        #expect(stored[8] == 1)
        #expect(try await store.read(relativePath: "Media/2026/07/28/legacy-frame.jpg") == jpeg)
    }

    @Test("Legacy migration surfaces protection failures before replacing plaintext")
    func legacyMigrationProtectionFailureIsSurfaced() async throws {
        let fixture = try MediaFixture()
        let legacyDirectory = fixture.paths.media.appendingPathComponent(
            "2026/07/30",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyURL = legacyDirectory.appendingPathComponent("protected-migration.jpg")
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0xaa, 0xbb, 0xff, 0xd9])
        try jpeg.write(to: legacyURL)
        let store = MediaStore(
            paths: fixture.paths,
            vaultKey: fixture.key,
            fileManager: MediaProtectionFailingFileManager()
        )

        do {
            _ = try await store.migrateLegacyPlaintext()
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: legacyURL) == jpeg)
    }

    @Test("Canceled legacy migration never replaces a file after its read")
    func legacyMigrationCancellationBeforeWrite() async throws {
        let fixture = try MediaFixture()
        let legacyDirectory = fixture.paths.media.appendingPathComponent(
            "2026/07/29",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyURL = legacyDirectory.appendingPathComponent("cancel-before-write.jpg")
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x10, 0x20, 0xff, 0xd9])
        try jpeg.write(to: legacyURL)
        let probe = MigrationCheckpointProbe(cancelAt: 5)
        let store = MediaStore(
            paths: fixture.paths,
            vaultKey: fixture.key,
            migrationCheckpoint: { try probe.checkpoint() }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await store.migrateLegacyPlaintext()
        }

        #expect(try Data(contentsOf: legacyURL) == jpeg)
        #expect(probe.count == 5)
        let resumedStore = MediaStore(paths: fixture.paths, vaultKey: fixture.key)
        #expect(try await resumedStore.migrateLegacyPlaintext() == 1)
        #expect(try Data(contentsOf: legacyURL).starts(with: Data("CHRMEDIA".utf8)))
    }

    private static func testImage(
        width: Int = 8,
        height: Int = 8,
        changingOnePixel: Bool = false
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.32, green: 0.18, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if changingOnePixel {
            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return context.makeImage()!
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private final class MediaProtectionFailingFileManager: FileManager, @unchecked Sendable {
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

private final class MigrationCheckpointProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAt: Int
    private var checkpointCount = 0

    init(cancelAt: Int) {
        self.cancelAt = cancelAt
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkpointCount
    }

    func checkpoint() throws {
        lock.lock()
        checkpointCount += 1
        let shouldCancel = checkpointCount == cancelAt
        lock.unlock()
        if shouldCancel { throw CancellationError() }
    }
}

private final class MediaFixture {
    let root: URL
    let paths: PassagePaths
    let key: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-media-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        try paths.createDirectories()
        key = try VaultKey.testing(bytes: Data(repeating: 0x42, count: 32))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
