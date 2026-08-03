import PassageCore
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaStoreError: Error, LocalizedError, Sendable {
    case invalidRelativePath
    case fileTooLarge
    case invalidEnvelope
    case unsupportedEnvelopeVersion(UInt8)
    case authenticationFailed
    case conflictingAsset

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "Passage refused a media path outside its private vault."
        case .fileTooLarge:
            "The encrypted media item exceeds Passage's safety limit."
        case .invalidEnvelope:
            "The encrypted media item has an invalid header."
        case .unsupportedEnvelopeVersion(let version):
            "This media item uses unsupported encryption format version \(version)."
        case .authenticationFailed:
            "The media item could not be authenticated. It may be damaged or use a different vault key."
        case .conflictingAsset:
            "An existing media asset did not match the content Passage was asked to store."
        }
    }
}

/// The durable paths produced by one media write and the subset that write owns.
///
/// Content-addressed blobs may already belong to another frame. Callers must use
/// `MediaStore.rollback(_:)` so a failed frame only removes newly created blobs.
public struct MediaWriteReceipt: Sendable, Equatable {
    public let imagePath: String
    public let thumbnailPath: String?
    public let createdPaths: [String]

    init(imagePath: String, thumbnailPath: String?, createdPaths: [String]) {
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.createdPaths = createdPaths
    }
}

private final class MediaStoreRevocationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    func revoke() {
        lock.withLock { revoked = true }
    }

    func check() throws {
        guard lock.withLock({ !revoked }) else { throw CancellationError() }
    }
}

/// Encrypted screenshot and thumbnail storage.
///
/// Full-size images are bounded to `maximumStoredDimension` on their longest
/// edge, prefer HEIC, and fall back to JPEG when the system encoder is
/// unavailable. Thumbnails stay JPEG for fast list decoding. Both are encoded
/// in memory, sealed with a per-object AES-256-GCM key, and only then written to
/// an opaque, date-free path. V2 paths use a vault-keyed content identifier so
/// equal encoded assets share one authenticated blob without revealing equality
/// across vaults. V1 frame-ID-bound envelopes remain readable for compatibility.
public actor MediaStore {
    private enum Kind: UInt8 {
        case frame = 1
        case thumbnail = 2

        var purpose: VaultKeyPurpose {
            switch self {
            case .frame: .frameMedia
            case .thumbnail: .thumbnailMedia
            }
        }

        var directoryName: String {
            switch self {
            case .frame: "Media"
            case .thumbnail: "Thumbnails"
            }
        }
    }

    private static let magic = Data("CHRMEDIA".utf8)
    private static let legacyEnvelopeVersion: UInt8 = 1
    private static let contentAddressedEnvelopeVersion: UInt8 = 2
    private static let maximumEncryptedFileBytes = 128 * 1_024 * 1_024

    private let paths: PassagePaths
    private let vaultKey: VaultKey
    private let fileManager: FileManager
    private let migrationCheckpoint: (@Sendable () throws -> Void)?
    private nonisolated let revocationGate = MediaStoreRevocationGate()

    public init(
        paths: PassagePaths,
        vaultKey: VaultKey,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.vaultKey = vaultKey
        self.fileManager = fileManager
        migrationCheckpoint = nil
    }

    /// Synchronously closes this session's media-read capability. In-flight
    /// reads check again after authentication/decryption, before plaintext can
    /// cross the actor boundary.
    public nonisolated func revoke() {
        revocationGate.revoke()
    }

    /// Test seam for proving cancellation at a precise migration boundary.
    /// Production always uses the public initializer and Task cancellation.
    init(
        paths: PassagePaths,
        vaultKey: VaultKey,
        fileManager: FileManager = .default,
        migrationCheckpoint: @escaping @Sendable () throws -> Void
    ) {
        self.paths = paths
        self.vaultKey = vaultKey
        self.fileManager = fileManager
        self.migrationCheckpoint = migrationCheckpoint
    }

    public func write(
        image: CGImage,
        id: FrameID,
        capturedAt: Date,
        quality: Double = 0.62
    ) throws -> MediaWriteReceipt {
        // Frame identity and capture time belong in the encrypted index. Asset
        // identity is derived only from the encoded representation and its kind.
        _ = (id, capturedAt)
        var createdPaths: [String] = []
        let imageData = try Self.encodeFullSize(image, quality: quality)
        let imageWrite = try writeIfAbsent(imageData, kind: .frame)
        if imageWrite.created {
            createdPaths.append(imageWrite.relativePath)
        }

        do {
            let thumbnailPath: String?
            if let thumbnail = Self.thumbnail(from: image, maximumDimension: 384) {
                let thumbnailData = try Self.encodeJPEG(thumbnail, quality: 0.55)
                let thumbnailWrite = try writeIfAbsent(thumbnailData, kind: .thumbnail)
                thumbnailPath = thumbnailWrite.relativePath
                if thumbnailWrite.created {
                    createdPaths.append(thumbnailWrite.relativePath)
                }
            } else {
                thumbnailPath = nil
            }
            return MediaWriteReceipt(
                imagePath: imageWrite.relativePath,
                thumbnailPath: thumbnailPath,
                createdPaths: createdPaths
            )
        } catch {
            delete(relativePaths: createdPaths)
            throw error
        }
    }

    /// Returns authenticated, decrypted image bytes for one visible item.
    public func read(relativePath: String) throws -> Data {
        try Task.checkCancellation()
        try revocationGate.check()
        let url = try safeExistingURL(for: relativePath)
        let envelope = try loadEnvelope(at: url)
        try Task.checkCancellation()
        try revocationGate.check()
        let plaintext = try open(envelope)
        try Task.checkCancellation()
        try revocationGate.check()
        return plaintext
    }

    public func delete(relativePaths: [String]) {
        for relativePath in relativePaths {
            guard let url = try? safeExistingURL(for: relativePath) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Removes only blobs first created by the corresponding write attempt.
    public func rollback(_ receipt: MediaWriteReceipt) {
        delete(relativePaths: receipt.createdPaths)
    }

    /// Seals JPEGs written by the pre-encryption prototype in place.
    ///
    /// Keeping the relative path stable lets the already-migrated encrypted
    /// index continue to reference each item. New captures always use opaque
    /// `.bin` paths; this compatibility pass exists only to eliminate legacy
    /// plaintext and is safe to resume after interruption.
    @discardableResult
    public func migrateLegacyPlaintext() throws -> Int {
        try checkMigrationCancellation()
        var migrated = 0
        let canonicalRoot = paths.root.standardizedFileURL.resolvingSymlinksInPath()
        for (root, kind) in [(paths.media, Kind.frame), (paths.thumbnails, Kind.thumbnail)] {
            try checkMigrationCancellation()
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                try checkMigrationCancellation()
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
                guard Self.isInside(canonicalFile, root: canonicalRoot) else {
                    throw MediaStoreError.invalidRelativePath
                }
                let relativePath = String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
                let safeURL = try safeExistingURL(for: relativePath)
                try PassageFileProtection.prepareForBackgroundAccess(
                    at: safeURL,
                    fileManager: fileManager
                )
                try checkMigrationCancellation()
                let plaintext = try Data(contentsOf: safeURL, options: [.mappedIfSafe])
                if plaintext.starts(with: Self.magic) { continue }
                guard plaintext.count <= Self.maximumEncryptedFileBytes else {
                    throw MediaStoreError.fileTooLarge
                }
                let rawID = safeURL.deletingPathExtension().lastPathComponent
                guard !rawID.isEmpty else { throw MediaStoreError.invalidEnvelope }
                let sealed = try sealLegacy(
                    plaintext,
                    id: FrameID(rawValue: rawID),
                    kind: kind
                )
                try checkMigrationCancellation()
                try sealed.write(
                    to: safeURL,
                    options: PassageFileProtection.atomicWritingOptions
                )
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: safeURL.path)
                migrated += 1
            }
        }
        return migrated
    }

    private func checkMigrationCancellation() throws {
        try Task.checkCancellation()
        try migrationCheckpoint?()
    }

    private func writeIfAbsent(
        _ plaintext: Data,
        kind: Kind
    ) throws -> (relativePath: String, created: Bool) {
        let assetIdentifier = contentIdentifier(for: plaintext, kind: kind)
        let relativePath = Self.relativePath(
            forAssetIdentifier: assetIdentifier,
            kind: kind
        )
        let url = try safeDestinationURL(for: relativePath)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let envelope = try sealContentAddressed(
            plaintext,
            assetIdentifier: assetIdentifier,
            kind: kind
        )
        let temporaryURL = directory.appendingPathComponent(
            ".passage-media-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try envelope.write(
            to: temporaryURL,
            options: PassageFileProtection.atomicWritingOptions
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        // A hard link publishes the already-complete temporary inode in one
        // filesystem operation and fails with EEXIST instead of replacing an
        // asset another writer won the race to create.
        let publishStatus = temporaryURL.path.withCString { temporaryPath in
            url.path.withCString { destinationPath in
                Darwin.link(temporaryPath, destinationPath)
            }
        }
        guard publishStatus == 0 else {
            let publishError = errno
            guard publishError == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: publishError) ?? .EIO)
            }
            try verifyExistingAsset(
                relativePath: relativePath,
                plaintext: plaintext,
                assetIdentifier: assetIdentifier,
                kind: kind
            )
            return (relativePath, false)
        }
        return (relativePath, true)
    }

    private func verifyExistingAsset(
        relativePath: String,
        plaintext: Data,
        assetIdentifier: String,
        kind: Kind
    ) throws {
        let url = try safeExistingURL(for: relativePath)
        let envelope = try loadEnvelope(at: url)
        let parsed = try Self.parseHeader(envelope)
        guard parsed.version == Self.contentAddressedEnvelopeVersion,
              parsed.kind == kind,
              parsed.context == assetIdentifier else {
            throw MediaStoreError.conflictingAsset
        }
        guard try open(envelope) == plaintext else {
            throw MediaStoreError.conflictingAsset
        }
    }

    private func loadEnvelope(at url: URL) throws -> Data {
        try PassageFileProtection.prepareForBackgroundAccess(at: url, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumEncryptedFileBytes {
            throw MediaStoreError.fileTooLarge
        }
        let envelope = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard envelope.count <= Self.maximumEncryptedFileBytes else {
            throw MediaStoreError.fileTooLarge
        }
        return envelope
    }

    private func sealLegacy(_ plaintext: Data, id: FrameID, kind: Kind) throws -> Data {
        try seal(
            plaintext,
            context: id.rawValue,
            kind: kind,
            version: Self.legacyEnvelopeVersion
        )
    }

    private func sealContentAddressed(
        _ plaintext: Data,
        assetIdentifier: String,
        kind: Kind
    ) throws -> Data {
        try seal(
            plaintext,
            context: assetIdentifier,
            kind: kind,
            version: Self.contentAddressedEnvelopeVersion
        )
    }

    private func seal(
        _ plaintext: Data,
        context: String,
        kind: Kind,
        version: UInt8
    ) throws -> Data {
        let header = try Self.header(version: version, context: context, kind: kind)
        let combined = try vaultKey.withDerivedKeyBytes(
            for: kind.purpose,
            context: context
        ) { keyBytes in
            let key = SymmetricKey(data: keyBytes)
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
            guard let combined = box.combined else {
                throw MediaStoreError.invalidEnvelope
            }
            return combined
        }
        return header + combined
    }

    private func open(_ envelope: Data) throws -> Data {
        let parsed = try Self.parseHeader(envelope)
        let combined = envelope.subdata(in: parsed.header.count..<envelope.count)
        do {
            return try vaultKey.withDerivedKeyBytes(
                for: parsed.kind.purpose,
                context: parsed.context
            ) { keyBytes in
                let key = SymmetricKey(data: keyBytes)
                let box = try AES.GCM.SealedBox(combined: combined)
                return try AES.GCM.open(box, using: key, authenticating: parsed.header)
            }
        } catch is MediaStoreError {
            throw MediaStoreError.invalidEnvelope
        } catch {
            throw MediaStoreError.authenticationFailed
        }
    }

    private static func header(version: UInt8, context: String, kind: Kind) throws -> Data {
        let contextBytes = Data(context.utf8)
        guard !contextBytes.isEmpty, contextBytes.count <= Int(UInt16.max) else {
            throw MediaStoreError.invalidEnvelope
        }
        var header = magic
        header.append(version)
        header.append(kind.rawValue)
        var length = UInt16(contextBytes.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(contextBytes)
        return header
    }

    private static func parseHeader(
        _ envelope: Data
    ) throws -> (header: Data, version: UInt8, context: String, kind: Kind) {
        let fixedLength = magic.count + 1 + 1 + 2
        let minimumCombinedLength = 12 + 16 // AES-GCM nonce and tag, allowing empty ciphertext.
        guard envelope.count >= fixedLength + 1 + minimumCombinedLength,
              envelope.prefix(magic.count) == magic else {
            throw MediaStoreError.invalidEnvelope
        }

        let version = envelope[magic.count]
        guard version == legacyEnvelopeVersion || version == contentAddressedEnvelopeVersion else {
            throw MediaStoreError.unsupportedEnvelopeVersion(version)
        }
        guard let kind = Kind(rawValue: envelope[magic.count + 1]) else {
            throw MediaStoreError.invalidEnvelope
        }
        let lengthOffset = magic.count + 2
        let idLength = Int(envelope[lengthOffset]) << 8 | Int(envelope[lengthOffset + 1])
        let headerLength = fixedLength + idLength
        guard idLength > 0,
              headerLength + minimumCombinedLength <= envelope.count,
              let context = String(data: envelope[fixedLength..<headerLength], encoding: .utf8) else {
            throw MediaStoreError.invalidEnvelope
        }
        if version == contentAddressedEnvelopeVersion {
            let identifierBytes = context.utf8
            guard identifierBytes.count == 64,
                  identifierBytes.allSatisfy({ byte in
                      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                  }) else {
                throw MediaStoreError.invalidEnvelope
            }
        }
        return (Data(envelope[..<headerLength]), version, context, kind)
    }

    private func contentIdentifier(for plaintext: Data, kind: Kind) -> String {
        vaultKey.withDerivedKeyBytes(for: .mediaAssetIdentifier) { keyBytes in
            var authenticator = HMAC<SHA256>(key: SymmetricKey(data: keyBytes))
            authenticator.update(data: Data([kind.rawValue]))
            authenticator.update(data: plaintext)
            return authenticator.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private static func relativePath(forAssetIdentifier identifier: String, kind: Kind) -> String {
        let shard = String(identifier.prefix(2))
        return "\(kind.directoryName)/v2/\(shard)/\(identifier).bin"
    }

    private func safeDestinationURL(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else { throw MediaStoreError.invalidRelativePath }
        let root = paths.root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = paths.root.appendingPathComponent(relativePath).standardizedFileURL
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard Self.isInside(parent, root: root) else { throw MediaStoreError.invalidRelativePath }
        return candidate
    }

    private func safeExistingURL(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else { throw MediaStoreError.invalidRelativePath }
        let root = paths.root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = paths.root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isInside(candidate, root: root) else { throw MediaStoreError.invalidRelativePath }
        return candidate
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        try encode(image, typeIdentifier: UTType.jpeg.identifier, quality: quality)
    }

    /// Longest stored edge for the retained full-size evidence image.
    ///
    /// Live OCR, fingerprinting, and privacy checks all run on the original
    /// in-memory snapshot before storage, so this bounds only what is kept
    /// on disk. 2,560 px keeps a Retina laptop window near its native scale
    /// while roughly halving media growth from very large captures; the
    /// stored-image OCR repair path sees proportionally smaller glyphs only
    /// for captures wider than this cap.
    static let maximumStoredDimension = 2_560

    private static func encodeFullSize(_ image: CGImage, quality: Double) throws -> Data {
        let bounded = downscaledForStorage(
            image,
            maximumDimension: maximumStoredDimension
        ) ?? image
        if let heic = try? encode(
            bounded,
            typeIdentifier: UTType.heic.identifier,
            quality: min(quality, 0.50)
        ) {
            return heic
        }
        return try encodeJPEG(bounded, quality: quality)
    }

    /// Returns nil when the image already fits, or when resampling fails —
    /// storage then falls back to the original rather than losing the frame.
    private static func downscaledForStorage(
        _ image: CGImage,
        maximumDimension: Int
    ) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maximumDimension else { return nil }
        let scale = Double(maximumDimension) / Double(longestEdge)
        let width = max(Int(Double(image.width) * scale), 1)
        let height = max(Int(Double(image.height) * scale), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(
        _ image: CGImage,
        typeIdentifier: String,
        quality: Double
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw PassageError.imageEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PassageError.imageEncodingFailed
        }
        return data as Data
    }

    private static func thumbnail(from image: CGImage, maximumDimension: Int) -> CGImage? {
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        let width = max(Int(Double(image.width) * scale), 1)
        let height = max(Int(Double(image.height) * scale), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
