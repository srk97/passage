import PassageCore
import CryptoKit
import Foundation

public enum VisualModelSelectionStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidReference
    case corruptPreference
    case preferenceTooLarge
    case unsafeLocation
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidReference:
            "The selected visual model reference is invalid."
        case .corruptPreference:
            "Passage could not verify the selected visual model preference."
        case .preferenceTooLarge:
            "The selected visual model preference exceeds Passage's safety limit."
        case .unsafeLocation:
            "Passage refused an unsafe visual model preference file."
        case .writeFailed:
            "Passage could not save the selected visual model preference."
        }
    }
}

/// Persists only an immutable, hash-pinned pack reference. Model paths and
/// weights never enter this preference file; `VisualModelPackStore.resolve(_:)`
/// remains the authority that validates and returns installed model URLs.
public actor VisualModelSelectionStore {
    public static let filename = "active-visual-model.json"
    public static let maximumStoredBytes = 16 * 1_024

    private static let formatVersion = 1
    private static let checksumDomain = Data("chronicle.visual-model-selection.v1\0".utf8)

    private let url: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.url = fileURL.standardizedFileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public static func live(fileManager: FileManager = .default) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(
            fileURL: applicationSupport
                .appendingPathComponent("Chronicle", isDirectory: true)
                .appendingPathComponent(Self.filename, isDirectory: false)
        )
    }

    /// Missing means no active pack. Malformed, tampered, oversized, symlinked,
    /// or over-permissive files throw and never produce a fallback reference.
    public func load() throws -> VisualModelPackReference? {
        let isSymlink = Self.isSymbolicLink(url, fileManager: fileManager)
        guard isSymlink || fileManager.fileExists(atPath: url.path) else { return nil }
        try requireSafeParentDirectory()
        try requireSafePreferenceFile()
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw VisualModelSelectionStoreError.corruptPreference
        }
        guard size.intValue <= Self.maximumStoredBytes else {
            throw VisualModelSelectionStoreError.preferenceTooLarge
        }
        let data: Data
        do {
            try PassageFileProtection.prepareForBackgroundAccess(
                at: url,
                fileManager: fileManager
            )
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as PassageFileProtectionError {
            throw error
        } catch {
            throw VisualModelSelectionStoreError.corruptPreference
        }
        guard data.count <= Self.maximumStoredBytes,
              let stored = try? decoder.decode(StoredSelection.self, from: data),
              stored.formatVersion == Self.formatVersion,
              try Self.validated(stored.reference),
              stored.checksum == (try checksum(for: stored.reference)) else {
            throw VisualModelSelectionStoreError.corruptPreference
        }
        return stored.reference
    }

    public func save(_ reference: VisualModelPackReference) throws {
        do {
            guard try Self.validated(reference) else {
                throw VisualModelSelectionStoreError.invalidReference
            }
        } catch is VisualModelSelectionStoreError {
            throw VisualModelSelectionStoreError.invalidReference
        } catch {
            throw VisualModelSelectionStoreError.invalidReference
        }
        try prepareParentDirectory()
        if fileManager.fileExists(atPath: url.path) {
            try requireSafePreferenceFile()
        } else if Self.isSymbolicLink(url, fileManager: fileManager) {
            throw VisualModelSelectionStoreError.unsafeLocation
        }

        let stored = StoredSelection(
            formatVersion: Self.formatVersion,
            reference: reference,
            checksum: try checksum(for: reference)
        )
        let data: Data
        do {
            data = try encoder.encode(stored)
        } catch {
            throw VisualModelSelectionStoreError.writeFailed
        }
        guard data.count <= Self.maximumStoredBytes else {
            throw VisualModelSelectionStoreError.preferenceTooLarge
        }
        do {
            try data.write(to: url, options: PassageFileProtection.atomicWritingOptions)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            try requireSafePreferenceFile()
        } catch let error as VisualModelSelectionStoreError {
            throw error
        } catch {
            throw VisualModelSelectionStoreError.writeFailed
        }
    }

    /// Clearing is an exact unlink of this one preference. A dangling symlink is
    /// removed as a link and is never followed. Returns whether anything existed.
    @discardableResult
    public func clear() throws -> Bool {
        let isSymlink = Self.isSymbolicLink(url, fileManager: fileManager)
        guard isSymlink || fileManager.fileExists(atPath: url.path) else { return false }
        try requireSafeParentDirectory()
        if !isSymlink {
            // Clearing is the recovery path for a corrupt or accidentally
            // over-permissive preference, so only its file type—not contents
            // or mode—must validate before the exact unlink.
            try requireSafePreferenceFile(requiresOwnerOnlyPermissions: false)
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            throw VisualModelSelectionStoreError.writeFailed
        }
    }

    private func checksum(for reference: VisualModelPackReference) throws -> String {
        var payload = Self.checksumDomain
        payload.append(try encoder.encode(reference))
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func validated(_ reference: VisualModelPackReference) throws -> Bool {
        let identifier = try VisualModelPackStore.validatedPathComponent(
            reference.identifier,
            field: "identifier"
        )
        let revision = try VisualModelPackStore.validatedPathComponent(
            reference.revision,
            field: "revision"
        )
        let hash = try VisualModelPackStore.validatedSHA256(reference.manifestSHA256)
        return identifier == reference.identifier
            && revision == reference.revision
            && hash == reference.manifestSHA256
    }

    private func prepareParentDirectory() throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path != "/",
              parent.path != fileManager.homeDirectoryForCurrentUser.path else {
            throw VisualModelSelectionStoreError.unsafeLocation
        }
        if fileManager.fileExists(atPath: parent.path) {
            try requireSafeParentDirectory()
        } else {
            do {
                try fileManager.createDirectory(
                    at: parent,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw VisualModelSelectionStoreError.writeFailed
            }
        }
        try requirePermissions(parent, expected: 0o700)
    }

    private func requireSafeParentDirectory() throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let values = try parent.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              parent.resolvingSymlinksInPath().path == parent.path else {
            throw VisualModelSelectionStoreError.unsafeLocation
        }
        try requirePermissions(parent, expected: 0o700)
    }

    private func requireSafePreferenceFile(
        requiresOwnerOnlyPermissions: Bool = true
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path == url.path else {
            throw VisualModelSelectionStoreError.unsafeLocation
        }
        if requiresOwnerOnlyPermissions {
            try requirePermissions(url, expected: 0o600)
        }
    }

    private func requirePermissions(_ url: URL, expected: Int) throws {
        guard let permissions = try fileManager.attributesOfItem(atPath: url.path)[
            .posixPermissions
        ] as? NSNumber,
              permissions.intValue & 0o777 == expected else {
            throw VisualModelSelectionStoreError.unsafeLocation
        }
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private struct StoredSelection: Codable, Sendable {
    var formatVersion: Int
    var reference: VisualModelPackReference
    var checksum: String
}
