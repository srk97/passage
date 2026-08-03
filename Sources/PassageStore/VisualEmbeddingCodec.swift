import PassageCore
import CryptoKit
import Foundation

public enum VisualEmbeddingStoreError: Error, LocalizedError, Sendable {
    case invalidModelIdentity(String)
    case invalidVector(expected: Int, actual: Int)
    case nonFiniteVector
    case zeroMagnitudeVector
    case invalidQuery
    case batchTooLarge
    case frameNotFound(FrameID)
    case sensitiveFrame(FrameID)
    case modelFingerprintCollision
    case corruptStoredVector

    public var errorDescription: String? {
        switch self {
        case .invalidModelIdentity(let field):
            "The visual model \(field) is invalid."
        case .invalidVector(let expected, let actual):
            "The visual embedding has \(actual) values; this model requires \(expected)."
        case .nonFiniteVector:
            "Visual embeddings must contain only finite values."
        case .zeroMagnitudeVector:
            "A zero-magnitude visual embedding cannot be indexed or searched."
        case .invalidQuery:
            "The visual search query is invalid."
        case .batchTooLarge:
            "A visual embedding batch may contain at most 1,000 frames."
        case .frameNotFound(let id):
            "Visual indexing could not find frame \(id.rawValue)."
        case .sensitiveFrame(let id):
            "Visual indexing is disabled for sensitive frame \(id.rawValue)."
        case .modelFingerprintCollision:
            "The visual model fingerprint is already registered with different metadata."
        case .corruptStoredVector:
            "A stored visual embedding is corrupt or incompatible."
        }
    }
}

struct QuantizedVisualEmbedding: Equatable, Sendable {
    var bytes: Data
    var angularHash: Data
    var scale: Double
    var maximumCosineError: Double
    var contentHash: Data
    var dimension: Int
}

/// Symmetric per-vector Int8 quantization for normalized embeddings.
///
/// If `x` is the normalized source and `x̂` its dequantized value, every search
/// query `q` is normalized before scoring. Cauchy-Schwarz therefore guarantees
/// `|q·x - q·x̂| <= ||x - x̂||₂`. We calculate and persist that exact L2 error
/// for every vector, so every returned approximate cosine has a per-result bound.
enum VisualEmbeddingCodec {
    static let encoding = "symmetric-int8-v1"
    static let embeddingDimension = 512
    static let angularHashBytes = embeddingDimension / 8

    static func encode(
        _ values: [Float],
        expectedDimension: Int,
        modelFingerprint: String
    ) throws
        -> QuantizedVisualEmbedding {
        let normalized = try normalize(values, expectedDimension: expectedDimension)
        let maximumMagnitude = normalized.reduce(0) { max($0, abs($1)) }
        guard maximumMagnitude > 0, maximumMagnitude.isFinite else {
            throw VisualEmbeddingStoreError.zeroMagnitudeVector
        }
        let scale = maximumMagnitude / 127
        var bytes = Data(count: expectedDimension)
        var squaredError = 0.0
        bytes.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: UInt8.self)
            for index in normalized.indices {
                let quantized = Int((normalized[index] / scale).rounded())
                let clamped = min(max(quantized, -127), 127)
                output[index] = UInt8(bitPattern: Int8(clamped))
                let reconstructed = Double(clamped) * scale
                let error = normalized[index] - reconstructed
                squaredError += error * error
            }
        }
        let error = sqrt(squaredError)
            + Double.ulpOfOne * Double(expectedDimension) * 4
        return QuantizedVisualEmbedding(
            bytes: bytes,
            angularHash: angularHash(
                normalizedVector: normalized,
                modelFingerprint: modelFingerprint
            ),
            scale: scale,
            maximumCosineError: error,
            contentHash: contentHash(
                bytes: bytes,
                scale: scale,
                dimension: expectedDimension
            ),
            dimension: expectedDimension
        )
    }

    static func normalizedQuery(_ values: [Float], expectedDimension: Int) throws -> [Double] {
        try normalize(values, expectedDimension: expectedDimension)
    }

    /// A compact angular shortlist key. Each bit records one normalized
    /// embedding-coordinate sign. XORing a deterministic per-model mask makes
    /// the serialized key namespace-specific while preserving Hamming distance
    /// between vectors from that model exactly.
    static func angularHash(
        normalizedVector: [Double],
        modelFingerprint: String
    ) -> Data {
        precondition(normalizedVector.count == embeddingDimension)
        let mask = angularMask(modelFingerprint: modelFingerprint)
        var hash = Data(count: angularHashBytes)
        hash.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: UInt8.self)
            for byteIndex in 0..<angularHashBytes {
                var signByte: UInt8 = 0
                for bitIndex in 0..<8 {
                    let vectorIndex = byteIndex * 8 + bitIndex
                    if normalizedVector[vectorIndex] >= 0 {
                        signByte |= UInt8(1 << bitIndex)
                    }
                }
                output[byteIndex] = signByte ^ mask[byteIndex]
            }
        }
        return hash
    }

    static func angularDistance(_ lhs: Data, _ rhs: UnsafeRawBufferPointer) throws -> Int {
        guard lhs.count == angularHashBytes, rhs.count == angularHashBytes else {
            throw VisualEmbeddingStoreError.corruptStoredVector
        }
        return lhs.withUnsafeBytes { leftBuffer in
            var distance = 0
            for offset in stride(from: 0, to: angularHashBytes, by: MemoryLayout<UInt64>.size) {
                let left = leftBuffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                let right = rhs.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                distance += (left ^ right).nonzeroBitCount
            }
            return distance
        }
    }

    static func similarity(
        normalizedQuery: [Double],
        bytes: Data,
        scale: Double,
        expectedDimension: Int
    ) throws -> Double {
        guard normalizedQuery.count == expectedDimension,
              bytes.count == expectedDimension,
              scale.isFinite, scale > 0 else {
            throw VisualEmbeddingStoreError.corruptStoredVector
        }
        var score = 0.0
        bytes.withUnsafeBytes { rawBuffer in
            let stored = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<expectedDimension {
                score += normalizedQuery[index]
                    * Double(Int8(bitPattern: stored[index]))
                    * scale
            }
        }
        guard score.isFinite else { throw VisualEmbeddingStoreError.corruptStoredVector }
        return min(max(score, -1), 1)
    }

    private static func normalize(
        _ values: [Float],
        expectedDimension: Int
    ) throws -> [Double] {
        guard expectedDimension == embeddingDimension,
              values.count == expectedDimension else {
            throw VisualEmbeddingStoreError.invalidVector(
                expected: expectedDimension,
                actual: values.count
            )
        }
        var squaredMagnitude = 0.0
        var converted = [Double]()
        converted.reserveCapacity(values.count)
        for value in values {
            guard value.isFinite else { throw VisualEmbeddingStoreError.nonFiniteVector }
            let convertedValue = Double(value)
            squaredMagnitude += convertedValue * convertedValue
            converted.append(convertedValue)
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > Double.leastNormalMagnitude else {
            throw VisualEmbeddingStoreError.zeroMagnitudeVector
        }
        let inverseMagnitude = 1 / sqrt(squaredMagnitude)
        for index in converted.indices {
            converted[index] *= inverseMagnitude
        }
        return converted
    }

    private static func contentHash(bytes: Data, scale: Double, dimension: Int) -> Data {
        var canonical = Data("app.chronicle.visual-embedding/symmetric-int8-v1".utf8)
        canonical.append(0)
        var encodedDimension = UInt32(dimension).bigEndian
        withUnsafeBytes(of: &encodedDimension) { canonical.append(contentsOf: $0) }
        var encodedScale = scale.bitPattern.bigEndian
        withUnsafeBytes(of: &encodedScale) { canonical.append(contentsOf: $0) }
        canonical.append(bytes)
        return Data(SHA256.hash(data: canonical))
    }

    private static func angularMask(modelFingerprint: String) -> Data {
        var mask = Data()
        mask.reserveCapacity(angularHashBytes)
        for counter in 0..<2 {
            var input = Data("app.chronicle.visual-angular-hash/v1".utf8)
            input.append(0)
            input.append(contentsOf: modelFingerprint.utf8)
            input.append(UInt8(counter))
            mask.append(contentsOf: SHA256.hash(data: input))
        }
        return mask
    }
}
