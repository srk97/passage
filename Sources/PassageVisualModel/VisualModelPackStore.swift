import PassageCore
import CryptoKit
import Foundation

public enum VisualModelPackError: Error, LocalizedError, Equatable, Sendable {
    case sourceUnavailable
    case sourceContainsSymbolicLink
    case manifestTooLarge
    case manifestHashMismatch
    case invalidManifest(String)
    case unsupportedFormatVersion(Int)
    case invalidArtifact(String)
    case invalidArtifactRole(String)
    case artifactSizeMismatch(String)
    case artifactHashMismatch(String)
    case packTooLarge
    case installedPackConflict
    case packNotInstalled
    case unsafeInstalledPack
    case installationFailed
    case removalFailed

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The downloaded visual model pack is unavailable."
        case .sourceContainsSymbolicLink:
            "The visual model pack contains an unsafe symbolic link."
        case .manifestTooLarge:
            "The visual model manifest exceeds Passage's safety limit."
        case .manifestHashMismatch:
            "The visual model manifest does not match its expected fingerprint."
        case .invalidManifest:
            "The visual model manifest is invalid."
        case .unsupportedFormatVersion(let version):
            "Visual model manifest version \(version) is not supported."
        case .invalidArtifact:
            "A visual model artifact has invalid metadata or a path outside its pack."
        case .invalidArtifactRole:
            "The visual model does not contain exactly one artifact for the requested role."
        case .artifactSizeMismatch:
            "A visual model artifact does not match its declared size."
        case .artifactHashMismatch:
            "A visual model artifact does not match its declared fingerprint."
        case .packTooLarge:
            "The visual model pack exceeds Passage's safety limit."
        case .installedPackConflict:
            "A different visual model pack already uses this identifier and revision."
        case .packNotInstalled:
            "The selected visual model pack is not installed."
        case .unsafeInstalledPack:
            "The installed visual model pack failed Passage's local safety checks."
        case .installationFailed:
            "Passage could not install the visual model pack."
        case .removalFailed:
            "Passage could not remove the visual model pack."
        }
    }
}

/// Owns explicitly supplied model packs. It intentionally has no downloader or
/// network dependency: a separate consented surface must obtain a directory and
/// a pinned manifest SHA-256 before calling `install`.
public actor VisualModelPackStore {
    public static let manifestFilename = "manifest.json"
    public static let maximumManifestBytes = 1 * 1_024 * 1_024
    /// The finalized v1 PE S16 Core ML pack declares 118,182,009 bytes. A 512 MiB
    /// ceiling leaves more than 4x headroom for compiler/runtime variation and
    /// an unquantized v1 rebuild, while preventing a malformed manifest from
    /// reserving tens of gigabytes for a small dual encoder.
    public static let maximumPackBytes: Int64 = 512 * 1_024 * 1_024

    private static let receiptFilename = ".chronicle-install.json"
    private static let maximumReceiptBytes = 16 * 1_024
    private static let stagingPrefix = ".install-"
    private static let removalPrefix = ".removed-"
    private static let copyChunkBytes = 1 * 1_024 * 1_024

    private enum FileProtectionPreparation {
        case externalReadOnlySource
        case immutableSignedBundle
        case passageOwned
    }

    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func live(fileManager: FileManager = .default) throws -> VisualModelPackStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return VisualModelPackStore(
            rootDirectory: applicationSupport
                .appendingPathComponent("Chronicle", isDirectory: true)
                .appendingPathComponent("VisualModelPacks", isDirectory: true)
        )
    }

    /// Installs one already-downloaded pack after verifying the externally
    /// pinned raw-manifest hash and every declared file. Existing identical
    /// installations are idempotent; a different pack never gets overwritten.
    @discardableResult
    public func install(
        from sourceDirectory: URL,
        expectedManifestSHA256: String
    ) throws -> InstalledVisualModelPack {
        let expectedHash = try Self.validatedSHA256(expectedManifestSHA256)
        let sourceRoot = try safeSourceRoot(sourceDirectory)
        let manifestURL = try safeSourceNamedFile(
            Self.manifestFilename,
            sourceRoot: sourceRoot
        )
        let manifestData = try boundedData(
            at: manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            sourceError: .sourceUnavailable,
            fileProtection: .externalReadOnlySource
        )
        let manifestHash = Self.sha256Hex(manifestData)
        guard manifestHash == expectedHash else {
            throw VisualModelPackError.manifestHashMismatch
        }
        let manifest = try decodeAndValidateManifest(manifestData)
        try prepareRoot()
        let destination = packDirectory(
            identifier: manifest.identifier,
            revision: manifest.revision
        )

        if fileManager.fileExists(atPath: destination.path) {
            do {
                return try validatePack(at: destination, expectedManifestSHA256: expectedHash)
            } catch let error as PassageFileProtectionError {
                throw error
            } catch {
                throw VisualModelPackError.installedPackConflict
            }
        }

        let staging = rootDirectory.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try createOwnerOnlyDirectory(staging)
        var stagingExists = true
        defer {
            if stagingExists {
                try? fileManager.removeItem(at: staging)
            }
        }

        let stagedManifest = staging.appendingPathComponent(Self.manifestFilename)
        try writeOwnerOnly(manifestData, to: stagedManifest)

        let uniqueArtifacts = try Self.uniqueArtifactsByPath(manifest.artifacts)
        for artifact in uniqueArtifacts {
            let source = try safeSourceArtifact(
                relativePath: artifact.relativePath,
                sourceRoot: sourceRoot
            )
            let destination = staging.appendingPathComponent(
                artifact.relativePath,
                isDirectory: false
            )
            try createOwnerOnlyHierarchy(
                through: destination.deletingLastPathComponent(),
                beneath: staging
            )
            try copyAndVerify(artifact, from: source, to: destination)
        }

        let receipt = InstallReceipt(
            formatVersion: 1,
            manifestSHA256: expectedHash,
            installedAt: Date()
        )
        let receiptEncoder = JSONEncoder()
        receiptEncoder.outputFormatting = [.sortedKeys]
        try writeOwnerOnly(
            try receiptEncoder.encode(receipt),
            to: staging.appendingPathComponent(Self.receiptFilename)
        )

        _ = try validatePack(at: staging, expectedManifestSHA256: expectedHash)
        let familyDirectory = destination.deletingLastPathComponent()
        try createOwnerOnlyDirectory(familyDirectory)
        do {
            try fileManager.moveItem(at: staging, to: destination)
            stagingExists = false
        } catch {
            // A second store instance may have completed the same installation.
            if let installed = try? validatePack(
                at: destination,
                expectedManifestSHA256: expectedHash
            ) {
                return installed
            }
            throw VisualModelPackError.installationFailed
        }
        return InstalledVisualModelPack(
            manifest: manifest,
            manifestSHA256: expectedHash,
            directoryURL: destination
        )
    }

    /// Resolves a persisted active-pack reference only after revalidating its
    /// pinned manifest and all artifacts. Callers then use `imageEncoderURL` and
    /// `textEncoderURL`; filenames are never guessed or accepted from UI input.
    public func resolve(
        _ reference: VisualModelPackReference
    ) throws -> InstalledVisualModelPack {
        try prepareRoot()
        let identifier = try Self.validatedPathComponent(
            reference.identifier,
            field: "identifier"
        )
        let revision = try Self.validatedPathComponent(reference.revision, field: "revision")
        let expectedHash = try Self.validatedSHA256(reference.manifestSHA256)
        let destination = packDirectory(identifier: identifier, revision: revision)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw VisualModelPackError.packNotInstalled
        }
        let installed = try validatePack(
            at: destination,
            expectedManifestSHA256: expectedHash
        )
        guard installed.manifest.identifier == identifier,
              installed.manifest.revision == revision else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        return installed
    }

    /// Verifies a model pack already sealed inside Passage's signed bundle.
    /// This performs the same pinned-manifest, artifact, traversal, symlink,
    /// size, hash, and undeclared-content checks as installation, but it never
    /// writes an install receipt or duplicates the pack into Application Support.
    public func verifyBundledPack(
        at directory: URL,
        expectedManifestSHA256: String
    ) throws -> InstalledVisualModelPack {
        let expectedHash = try Self.validatedSHA256(expectedManifestSHA256)
        let packRoot = try safeSourceRoot(directory)
        let manifestURL = try safeSourceNamedFile(
            Self.manifestFilename,
            sourceRoot: packRoot
        )
        let manifestData = try boundedData(
            at: manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            sourceError: .sourceUnavailable,
            fileProtection: .immutableSignedBundle
        )
        let manifestHash = Self.sha256Hex(manifestData)
        guard manifestHash == expectedHash else {
            throw VisualModelPackError.manifestHashMismatch
        }
        let manifest = try decodeAndValidateManifest(manifestData)

        for artifact in try Self.uniqueArtifactsByPath(manifest.artifacts) {
            let url = try safeSourceArtifact(
                relativePath: artifact.relativePath,
                sourceRoot: packRoot
            )
            let measured = try measureAndHash(url, maximumBytes: artifact.byteCount)
            guard measured.byteCount == artifact.byteCount else {
                throw VisualModelPackError.artifactSizeMismatch(artifact.relativePath)
            }
            guard measured.sha256 == artifact.sha256 else {
                throw VisualModelPackError.artifactHashMismatch(artifact.relativePath)
            }
        }
        try validateNoUndeclaredContent(
            in: packRoot,
            manifest: manifest,
            includesInstallReceipt: false,
            requiresOwnerOnlyDirectories: false
        )
        return InstalledVisualModelPack(
            manifest: manifest,
            manifestSHA256: manifestHash,
            directoryURL: packRoot
        )
    }

    /// Makes a pack unavailable with an atomic rename before deleting its files.
    /// No identifier, revision, or wildcard supplied by a caller reaches a broad
    /// recursive path.
    @discardableResult
    public func remove(identifier: String, revision: String) throws -> Bool {
        try prepareRoot()
        let identifier = try Self.validatedPathComponent(identifier, field: "identifier")
        let revision = try Self.validatedPathComponent(revision, field: "revision")
        let destination = packDirectory(identifier: identifier, revision: revision)
        guard fileManager.fileExists(atPath: destination.path) else { return false }
        guard try isRealDirectory(destination) else {
            throw VisualModelPackError.unsafeInstalledPack
        }

        let removed = rootDirectory.appendingPathComponent(
            Self.removalPrefix + UUID().uuidString,
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: destination, to: removed)
            try fileManager.removeItem(at: removed)
            try removeDirectoryIfEmpty(destination.deletingLastPathComponent())
            return true
        } catch {
            throw VisualModelPackError.removalFailed
        }
    }

    public nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareRoot() throws {
        guard rootDirectory.path != "/",
              rootDirectory.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        try createOwnerOnlyDirectory(rootDirectory)
        let values = try rootDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              rootDirectory.resolvingSymlinksInPath().path == rootDirectory.path else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        try requirePermissions(rootDirectory, expected: 0o700)
    }

    private func validatePack(
        at directory: URL,
        expectedManifestSHA256: String
    ) throws -> InstalledVisualModelPack {
        guard try isRealDirectory(directory) else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        try requirePermissions(directory, expected: 0o700)

        let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
        try requireRegularOwnerOnlyFile(manifestURL)
        let manifestData = try boundedData(
            at: manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            sourceError: .unsafeInstalledPack,
            fileProtection: .passageOwned
        )
        let manifestHash = Self.sha256Hex(manifestData)
        guard manifestHash == expectedManifestSHA256 else {
            throw VisualModelPackError.manifestHashMismatch
        }
        let manifest = try decodeAndValidateManifest(manifestData)

        let receiptURL = directory.appendingPathComponent(Self.receiptFilename)
        try requireRegularOwnerOnlyFile(receiptURL)
        let receiptData = try boundedData(
            at: receiptURL,
            maximumBytes: Self.maximumReceiptBytes,
            sourceError: .unsafeInstalledPack,
            fileProtection: .passageOwned
        )
        guard let receipt = try? JSONDecoder().decode(InstallReceipt.self, from: receiptData),
              receipt.formatVersion == 1,
              receipt.manifestSHA256 == expectedManifestSHA256 else {
            throw VisualModelPackError.unsafeInstalledPack
        }

        let artifacts = try Self.uniqueArtifactsByPath(manifest.artifacts)
        for artifact in artifacts {
            let url = try safeInstalledArtifact(
                relativePath: artifact.relativePath,
                packRoot: directory
            )
            try requireRegularOwnerOnlyFile(url)
            let measured = try measureAndHash(url, maximumBytes: artifact.byteCount)
            guard measured.byteCount == artifact.byteCount else {
                throw VisualModelPackError.artifactSizeMismatch(artifact.relativePath)
            }
            guard measured.sha256 == artifact.sha256 else {
                throw VisualModelPackError.artifactHashMismatch(artifact.relativePath)
            }
        }
        try validateNoUndeclaredContent(
            in: directory,
            manifest: manifest,
            includesInstallReceipt: true,
            requiresOwnerOnlyDirectories: true
        )
        return InstalledVisualModelPack(
            manifest: manifest,
            manifestSHA256: manifestHash,
            directoryURL: directory
        )
    }

    private func decodeAndValidateManifest(_ data: Data) throws -> VisualModelPackManifest {
        let manifest: VisualModelPackManifest
        do {
            manifest = try JSONDecoder().decode(VisualModelPackManifest.self, from: data)
        } catch {
            throw VisualModelPackError.invalidManifest("decoding")
        }
        try Self.validate(manifest)
        return manifest
    }

    private static func validate(_ manifest: VisualModelPackManifest) throws {
        guard manifest.formatVersion == VisualModelPackManifest.currentFormatVersion else {
            throw VisualModelPackError.unsupportedFormatVersion(manifest.formatVersion)
        }
        _ = try validatedPathComponent(manifest.identifier, field: "identifier")
        _ = try validatedPathComponent(manifest.revision, field: "revision")
        for value in [
            manifest.model.displayName,
            manifest.model.provider,
            manifest.model.architecture,
            manifest.model.preprocessingRevision,
            manifest.license.name,
            manifest.license.notice,
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else {
                throw VisualModelPackError.invalidManifest("metadata")
            }
        }
        if let sourceURL = manifest.license.sourceURL {
            guard sourceURL.scheme?.lowercased() == "https", sourceURL.host != nil else {
                throw VisualModelPackError.invalidManifest("license URL")
            }
        }
        if let parameterCount = manifest.model.parameterCount, parameterCount <= 0 {
            throw VisualModelPackError.invalidManifest("parameter count")
        }
        guard (1...NormalizedVisualEmbedding.maximumDimension)
            .contains(manifest.model.embeddingDimension),
              (1...16_384).contains(manifest.model.imageInputWidth),
              (1...16_384).contains(manifest.model.imageInputHeight),
              (1...65_536).contains(manifest.model.maximumTextTokens) else {
            throw VisualModelPackError.invalidManifest("model dimensions")
        }
        let imagePath = try validatedRelativePath(manifest.model.imageEncoderPath)
        let textPath = try validatedRelativePath(manifest.model.textEncoderPath)
        guard !manifest.artifacts.isEmpty, manifest.artifacts.count <= 4_096 else {
            throw VisualModelPackError.invalidManifest("artifact count")
        }

        var totalBytes: Int64 = 0
        var seenRolePaths = Set<String>()
        var artifactsByPath: [String: VisualModelArtifact] = [:]
        for artifact in manifest.artifacts {
            let path = try validatedRelativePath(artifact.relativePath)
            let role = artifact.role.rawValue
            guard !role.isEmpty, role.utf8.count <= 128,
                  role.unicodeScalars.allSatisfy({ isAllowedTokenScalar($0, allowsPlus: false) }),
                  artifact.byteCount > 0 else {
                throw VisualModelPackError.invalidArtifact(path)
            }
            let hash = try validatedSHA256(artifact.sha256)
            guard hash == artifact.sha256 else {
                throw VisualModelPackError.invalidArtifact(path)
            }
            let rolePath = role + "\u{0}" + path
            guard seenRolePaths.insert(rolePath).inserted else {
                throw VisualModelPackError.invalidArtifact(path)
            }
            if let existing = artifactsByPath[path] {
                guard existing.byteCount == artifact.byteCount,
                      existing.sha256 == artifact.sha256 else {
                    throw VisualModelPackError.invalidArtifact(path)
                }
            } else {
                artifactsByPath[path] = artifact
                let addition = totalBytes.addingReportingOverflow(artifact.byteCount)
                guard !addition.overflow, addition.partialValue <= maximumPackBytes else {
                    throw VisualModelPackError.packTooLarge
                }
                totalBytes = addition.partialValue
            }
        }
        guard entryPointExists(imagePath, artifacts: Array(artifactsByPath.values)),
              entryPointExists(textPath, artifacts: Array(artifactsByPath.values)) else {
            throw VisualModelPackError.invalidManifest("model entry point")
        }
    }

    private static func entryPointExists(
        _ entryPoint: String,
        artifacts: [VisualModelArtifact]
    ) -> Bool {
        artifacts.contains {
            $0.relativePath == entryPoint || $0.relativePath.hasPrefix(entryPoint + "/")
        }
    }

    private static func uniqueArtifactsByPath(
        _ artifacts: [VisualModelArtifact]
    ) throws -> [VisualModelArtifact] {
        var seen = Set<String>()
        return artifacts.filter { seen.insert($0.relativePath).inserted }
    }

    private func safeSourceRoot(_ source: URL) throws -> URL {
        let standardized = source.standardizedFileURL
        let values = try? standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw VisualModelPackError.sourceUnavailable
        }
        let resolved = standardized.resolvingSymlinksInPath()
        guard resolved.path == standardized.path else {
            throw VisualModelPackError.sourceContainsSymbolicLink
        }
        return resolved
    }

    private func safeSourceArtifact(relativePath: String, sourceRoot: URL) throws -> URL {
        let path = try Self.validatedRelativePath(relativePath)
        let candidate = sourceRoot.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard Self.isInside(resolved, root: sourceRoot), resolved.path == candidate.path else {
            throw VisualModelPackError.sourceContainsSymbolicLink
        }
        let values = try? resolved.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw VisualModelPackError.sourceUnavailable
        }
        return resolved
    }

    private func safeSourceNamedFile(_ name: String, sourceRoot: URL) throws -> URL {
        let candidate = sourceRoot.appendingPathComponent(name).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard Self.isInside(resolved, root: sourceRoot), resolved.path == candidate.path else {
            throw VisualModelPackError.sourceContainsSymbolicLink
        }
        let values = try? resolved.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw VisualModelPackError.sourceUnavailable
        }
        return resolved
    }

    private func safeInstalledArtifact(relativePath: String, packRoot: URL) throws -> URL {
        let path = try Self.validatedRelativePath(relativePath)
        let candidate = packRoot.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard Self.isInside(resolved, root: packRoot), resolved.path == candidate.path else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        return resolved
    }

    private func copyAndVerify(
        _ artifact: VisualModelArtifact,
        from source: URL,
        to destination: URL
    ) throws {
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw VisualModelPackError.installationFailed
        }

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try input.read(upToCount: Self.copyChunkBytes), !chunk.isEmpty {
            let addition = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !addition.overflow, addition.partialValue <= artifact.byteCount else {
                throw VisualModelPackError.artifactSizeMismatch(artifact.relativePath)
            }
            byteCount = addition.partialValue
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        guard byteCount == artifact.byteCount else {
            throw VisualModelPackError.artifactSizeMismatch(artifact.relativePath)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == artifact.sha256 else {
            throw VisualModelPackError.artifactHashMismatch(artifact.relativePath)
        }
        try requirePermissions(destination, expected: 0o600)
    }

    private func measureAndHash(
        _ url: URL,
        maximumBytes: Int64
    ) throws -> (byteCount: Int64, sha256: String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try input.read(upToCount: Self.copyChunkBytes), !chunk.isEmpty {
            let addition = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !addition.overflow, addition.partialValue <= maximumBytes else {
                throw VisualModelPackError.artifactSizeMismatch(url.lastPathComponent)
            }
            byteCount = addition.partialValue
            hasher.update(data: chunk)
        }
        return (
            byteCount,
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func validateNoUndeclaredContent(
        in directory: URL,
        manifest: VisualModelPackManifest,
        includesInstallReceipt: Bool,
        requiresOwnerOnlyDirectories: Bool
    ) throws {
        var declaredFileList = manifest.artifacts.map(\.relativePath)
        declaredFileList.append(Self.manifestFilename)
        if includesInstallReceipt {
            declaredFileList.append(Self.receiptFilename)
        }
        let declaredFiles = Set(declaredFileList)
        var declaredDirectories = Set<String>()
        for file in declaredFiles {
            var components = file.split(separator: "/").map(String.init)
            _ = components.popLast()
            while !components.isEmpty {
                declaredDirectories.insert(components.joined(separator: "/"))
                _ = components.popLast()
            }
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        let rootPath = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw VisualModelPackError.unsafeInstalledPack
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else {
                throw VisualModelPackError.unsafeInstalledPack
            }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if values.isDirectory == true {
                guard declaredDirectories.contains(relative) else {
                    throw VisualModelPackError.unsafeInstalledPack
                }
                if requiresOwnerOnlyDirectories {
                    try requirePermissions(url, expected: 0o700)
                }
            } else if values.isRegularFile == true {
                guard declaredFiles.contains(relative) else {
                    throw VisualModelPackError.unsafeInstalledPack
                }
            } else {
                throw VisualModelPackError.unsafeInstalledPack
            }
        }
    }

    private func boundedData(
        at url: URL,
        maximumBytes: Int,
        sourceError: VisualModelPackError,
        fileProtection: FileProtectionPreparation
    ) throws -> Data {
        switch fileProtection {
        case .externalReadOnlySource:
            break
        case .immutableSignedBundle:
            PassageFileProtection
                .prepareImmutableBundleResourceForBackgroundAccessBestEffort(
                    at: url,
                    fileManager: fileManager
                )
        case .passageOwned:
            try PassageFileProtection.prepareForBackgroundAccess(
                at: url,
                fileManager: fileManager
            )
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= 0 else { throw sourceError }
        guard size.intValue <= maximumBytes else {
            throw maximumBytes == Self.maximumManifestBytes
                ? VisualModelPackError.manifestTooLarge
                : sourceError
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumBytes else { throw sourceError }
            return data
        } catch let error as VisualModelPackError {
            throw error
        } catch {
            throw sourceError
        }
    }

    private func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: PassageFileProtection.atomicWritingOptions)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func createOwnerOnlyDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  url.standardizedFileURL.resolvingSymlinksInPath().path
                    == url.standardizedFileURL.path else {
                throw VisualModelPackError.unsafeInstalledPack
            }
            try requirePermissions(url, expected: 0o700)
            return
        }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try requirePermissions(url, expected: 0o700)
        } catch let error as VisualModelPackError {
            throw error
        } catch {
            throw VisualModelPackError.installationFailed
        }
    }

    private func createOwnerOnlyHierarchy(through leaf: URL, beneath root: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedLeaf = leaf.standardizedFileURL
        guard standardizedLeaf == standardizedRoot
                || Self.isInside(standardizedLeaf, root: standardizedRoot) else {
            throw VisualModelPackError.installationFailed
        }
        if standardizedLeaf == standardizedRoot { return }
        let relative = String(
            standardizedLeaf.path.dropFirst(standardizedRoot.path.count + 1)
        )
        var current = standardizedRoot
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try createOwnerOnlyDirectory(current)
        }
    }

    private func requireRegularOwnerOnlyFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        try requirePermissions(url, expected: 0o600)
    }

    private func requirePermissions(_ url: URL, expected: Int) throws {
        guard let value = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber,
              value.intValue & 0o777 == expected else {
            throw VisualModelPackError.unsafeInstalledPack
        }
    }

    private func isRealDirectory(_ url: URL) throws -> Bool {
        let standardized = url.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        return values.isDirectory == true
            && values.isSymbolicLink != true
            && standardized.resolvingSymlinksInPath().path == standardized.path
            && Self.isInside(standardized, root: rootDirectory)
    }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard url != rootDirectory,
              (try fileManager.contentsOfDirectory(atPath: url.path)).isEmpty else { return }
        try fileManager.removeItem(at: url)
    }

    private func packDirectory(identifier: String, revision: String) -> URL {
        rootDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    nonisolated static func validatedPathComponent(
        _ value: String,
        field: String
    ) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value != ".",
              value != "..",
              !value.hasPrefix("."),
              value.unicodeScalars.allSatisfy({ isAllowedTokenScalar($0, allowsPlus: true) }) else {
            throw VisualModelPackError.invalidManifest(field)
        }
        return value
    }

    private static func validatedRelativePath(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 2_048,
              !value.hasPrefix("/"),
              !value.contains("\u{0}") else {
            throw VisualModelPackError.invalidArtifact(value)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.utf8.count <= 255
              }),
              components.joined(separator: "/") == value,
              value != Self.manifestFilename,
              value != Self.receiptFilename,
              components.first != Substring(Self.manifestFilename),
              components.first != Substring(Self.receiptFilename),
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && scalar != "\\"
              }) else {
            throw VisualModelPackError.invalidArtifact(value)
        }
        return value
    }

    nonisolated static func validatedSHA256(_ value: String) throws -> String {
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw VisualModelPackError.invalidManifest("SHA-256")
        }
        return value
    }

    private static func isAllowedTokenScalar(
        _ scalar: Unicode.Scalar,
        allowsPlus: Bool
    ) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || scalar == "."
            || scalar == "_"
            || scalar == "-"
            || (allowsPlus && scalar == "+")
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }
}

private struct InstallReceipt: Codable, Sendable {
    var formatVersion: Int
    var manifestSHA256: String
    var installedAt: Date
}
