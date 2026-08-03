import PassageCore
import Foundation

public struct VisualModelPackManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var identifier: String
    public var revision: String
    public var model: VisualModelMetadata
    public var license: VisualModelLicenseMetadata
    public var artifacts: [VisualModelArtifact]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        identifier: String,
        revision: String,
        model: VisualModelMetadata,
        license: VisualModelLicenseMetadata,
        artifacts: [VisualModelArtifact]
    ) {
        self.formatVersion = formatVersion
        self.identifier = identifier
        self.revision = revision
        self.model = model
        self.license = license
        self.artifacts = artifacts
    }
}

public struct VisualModelMetadata: Codable, Equatable, Sendable {
    public var displayName: String
    public var provider: String
    public var architecture: String
    public var imageEncoderPath: String
    public var textEncoderPath: String
    public var preprocessingRevision: String
    public var embeddingDimension: Int
    public var imageInputWidth: Int
    public var imageInputHeight: Int
    public var maximumTextTokens: Int
    public var parameterCount: Int64?

    public init(
        displayName: String,
        provider: String,
        architecture: String,
        imageEncoderPath: String,
        textEncoderPath: String,
        preprocessingRevision: String,
        embeddingDimension: Int,
        imageInputWidth: Int,
        imageInputHeight: Int,
        maximumTextTokens: Int,
        parameterCount: Int64? = nil
    ) {
        self.displayName = displayName
        self.provider = provider
        self.architecture = architecture
        self.imageEncoderPath = imageEncoderPath
        self.textEncoderPath = textEncoderPath
        self.preprocessingRevision = preprocessingRevision
        self.embeddingDimension = embeddingDimension
        self.imageInputWidth = imageInputWidth
        self.imageInputHeight = imageInputHeight
        self.maximumTextTokens = maximumTextTokens
        self.parameterCount = parameterCount
    }
}

/// License facts travel with the installed model instead of being inferred by
/// Passage. `notice` is the exact attribution or use restriction shown by a
/// future download surface; it is not a legal conclusion made by the app.
public struct VisualModelLicenseMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var spdxIdentifier: String?
    public var sourceURL: URL?
    public var notice: String

    public init(
        name: String,
        spdxIdentifier: String? = nil,
        sourceURL: URL? = nil,
        notice: String
    ) {
        self.name = name
        self.spdxIdentifier = spdxIdentifier
        self.sourceURL = sourceURL
        self.notice = notice
    }
}

public struct VisualModelArtifact: Codable, Equatable, Sendable {
    /// A model-defined role such as `image-encoder`, `text-encoder`,
    /// `tokenizer-vocabulary`, or `tokenizer-merges`.
    public var role: VisualModelArtifactRole
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String

    public init(
        role: VisualModelArtifactRole,
        relativePath: String,
        byteCount: Int64,
        sha256: String
    ) {
        self.role = role
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Extensible rather than an enum so a future runtime can introduce another
/// artifact role without changing the manifest decoder.
public struct VisualModelArtifactRole:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let imageEncoder = Self(rawValue: "image-encoder")
    public static let textEncoder = Self(rawValue: "text-encoder")
    public static let tokenizerVocabulary = Self(rawValue: "tokenizer-vocabulary")
    public static let tokenizerMerges = Self(rawValue: "tokenizer-merges")
}

/// Durable, non-secret identity for a selected pack. The pinned manifest hash
/// prevents an identifier/revision pair from silently resolving to different
/// weights after an app restart.
public struct VisualModelPackReference: Codable, Equatable, Sendable {
    public var identifier: String
    public var revision: String
    public var manifestSHA256: String

    public init(identifier: String, revision: String, manifestSHA256: String) {
        self.identifier = identifier
        self.revision = revision
        self.manifestSHA256 = manifestSHA256
    }
}

public struct InstalledVisualModelPack: Equatable, Sendable {
    public let manifest: VisualModelPackManifest
    public let manifestSHA256: String
    public let directoryURL: URL

    init(
        manifest: VisualModelPackManifest,
        manifestSHA256: String,
        directoryURL: URL
    ) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.directoryURL = directoryURL
    }

    /// Validated file or directory entry points declared by model metadata.
    /// Every file beneath either URL is still individually size/hash pinned in
    /// `manifest.artifacts`.
    public var imageEncoderURL: URL {
        directoryURL.appendingPathComponent(manifest.model.imageEncoderPath)
    }

    public var textEncoderURL: URL {
        directoryURL.appendingPathComponent(manifest.model.textEncoderPath)
    }

    public var reference: VisualModelPackReference {
        VisualModelPackReference(
            identifier: manifest.identifier,
            revision: manifest.revision,
            manifestSHA256: manifestSHA256
        )
    }

    public var identity: VisualModelIdentity {
        VisualModelIdentity(
            identifier: manifest.identifier,
            revision: manifest.revision,
            fingerprint: manifestSHA256,
            preprocessingRevision: manifest.model.preprocessingRevision,
            embeddingDimension: manifest.model.embeddingDimension
        )
    }

    public func artifactURL(forRole role: VisualModelArtifactRole) -> URL? {
        guard let artifact = manifest.artifacts.first(where: { $0.role == role }) else {
            return nil
        }
        return directoryURL.appendingPathComponent(artifact.relativePath, isDirectory: false)
    }

    public func artifactURLs(forRole role: VisualModelArtifactRole) -> [URL] {
        manifest.artifacts
            .filter { $0.role == role }
            .map { directoryURL.appendingPathComponent($0.relativePath, isDirectory: false) }
    }

    public func requiredArtifactURL(forRole role: VisualModelArtifactRole) throws -> URL {
        let matches = artifactURLs(forRole: role)
        guard matches.count == 1, let match = matches.first else {
            throw VisualModelPackError.invalidArtifactRole(role.rawValue)
        }
        return match
    }
}
