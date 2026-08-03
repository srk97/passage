import PassageCore
import Foundation

/// Encoded image bytes remain in memory and are decoded/preprocessed by the
/// selected local runtime. Passage does not impose JPEG, HEIC, or PNG on a
/// model implementation.
public struct VisualEmbeddingImage: Sendable {
    public static let maximumEncodedBytes = 128 * 1_024 * 1_024

    public let encodedBytes: Data

    public init(encodedBytes: Data) throws {
        guard !encodedBytes.isEmpty,
              encodedBytes.count <= Self.maximumEncodedBytes else {
            throw VisualEmbeddingError.invalidImage
        }
        self.encodedBytes = encodedBytes
    }
}

/// A finite, non-zero vector with an L2 norm of one (within Float rounding).
/// Construction normalizes model output once, so every index and query path
/// shares the same cosine-similarity invariant.
public struct NormalizedVisualEmbedding: Equatable, Sendable {
    public static let maximumDimension = 65_536

    public let values: [Float]

    public init(normalizing values: [Float]) throws {
        guard !values.isEmpty, values.count <= Self.maximumDimension else {
            throw VisualEmbeddingError.invalidDimension
        }
        var squaredMagnitude = 0.0
        for value in values {
            guard value.isFinite else { throw VisualEmbeddingError.nonFiniteValue }
            let component = Double(value)
            squaredMagnitude += component * component
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > Double.leastNonzeroMagnitude else {
            throw VisualEmbeddingError.zeroMagnitude
        }
        let magnitude = sqrt(squaredMagnitude)
        self.values = values.map { Float(Double($0) / magnitude) }
    }

    public var dimension: Int { values.count }

    public func cosineSimilarity(to other: Self) throws -> Float {
        guard values.count == other.values.count else {
            throw VisualEmbeddingError.dimensionMismatch(
                expected: values.count,
                actual: other.values.count
            )
        }
        let similarity = zip(values, other.values).reduce(0.0) { partial, pair in
            partial + Double(pair.0) * Double(pair.1)
        }
        return Float(min(max(similarity, -1), 1))
    }
}

public enum VisualEmbeddingError: Error, LocalizedError, Equatable, Sendable {
    case invalidImage
    case invalidText
    case invalidDimension
    case dimensionMismatch(expected: Int, actual: Int)
    case nonFiniteValue
    case zeroMagnitude
    case incompatibleModelOutput

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The image is empty or exceeds Passage's in-memory safety limit."
        case .invalidText:
            "A visual search needs non-empty text."
        case .invalidDimension:
            "The visual model returned an unsupported embedding size."
        case .dimensionMismatch:
            "The visual embeddings were produced with incompatible dimensions."
        case .nonFiniteValue:
            "The visual model returned a non-finite value."
        case .zeroMagnitude:
            "The visual model returned an empty signal."
        case .incompatibleModelOutput:
            "The visual model returned output that does not match its manifest."
        }
    }
}

/// Model-neutral boundary for an on-device dual encoder. Implementations may
/// use Core ML, MLX, Metal, or another local runtime, but must never perform a
/// network request and must return normalized vectors in one shared space.
public protocol VisualEmbeddingModel: Sendable {
    var identity: VisualModelIdentity { get async }
    func embed(image: VisualEmbeddingImage) async throws -> NormalizedVisualEmbedding
    func embed(text: String) async throws -> NormalizedVisualEmbedding
}

public extension VisualEmbeddingModel {
    func validatedImageEmbedding(
        for image: VisualEmbeddingImage
    ) async throws -> NormalizedVisualEmbedding {
        let identity = await identity
        let embedding = try await embed(image: image)
        guard embedding.dimension == identity.embeddingDimension else {
            throw VisualEmbeddingError.incompatibleModelOutput
        }
        return embedding
    }

    func validatedTextEmbedding(
        for text: String
    ) async throws -> NormalizedVisualEmbedding {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VisualEmbeddingError.invalidText }
        let identity = await identity
        let embedding = try await embed(text: trimmed)
        guard embedding.dimension == identity.embeddingDimension else {
            throw VisualEmbeddingError.incompatibleModelOutput
        }
        return embedding
    }
}
