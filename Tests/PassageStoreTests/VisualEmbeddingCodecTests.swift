@testable import PassageStore
import Foundation
import Testing

@Suite("Visual embedding codec")
struct VisualEmbeddingCodecTests {
    private static let fingerprintA = String(repeating: "a", count: 64)
    private static let fingerprintB = String(repeating: "b", count: 64)

    @Test("Int8 payloads and angular keys are deterministic and model separated")
    func deterministicEncodingAndAngularKey() throws {
        let first = Self.patternVector(phase: 0.17)
        let second = Self.patternVector(phase: 0.73)
        let encoded = try VisualEmbeddingCodec.encode(
            first,
            expectedDimension: 512,
            modelFingerprint: Self.fingerprintA
        )
        let repeated = try VisualEmbeddingCodec.encode(
            first,
            expectedDimension: 512,
            modelFingerprint: Self.fingerprintA
        )
        let otherModel = try VisualEmbeddingCodec.encode(
            first,
            expectedDimension: 512,
            modelFingerprint: Self.fingerprintB
        )
        let encodedSecond = try VisualEmbeddingCodec.encode(
            second,
            expectedDimension: 512,
            modelFingerprint: Self.fingerprintA
        )
        let otherModelSecond = try VisualEmbeddingCodec.encode(
            second,
            expectedDimension: 512,
            modelFingerprint: Self.fingerprintB
        )

        #expect(encoded == repeated)
        #expect(encoded.bytes.count == 512)
        #expect(encoded.angularHash.count == 64)
        #expect(encoded.contentHash.count == 32)
        #expect(encoded.angularHash != otherModel.angularHash)
        #expect(try Self.angularDistance(encoded.angularHash, encodedSecond.angularHash)
            == Self.angularDistance(otherModel.angularHash, otherModelSecond.angularHash))
    }

    @Test("Every approximate cosine stays inside its persisted error bound")
    func cosineErrorBoundIncludesRandomAndAdversarialVectors() throws {
        var generator = VisualTestGenerator(seed: 0xC051_CE)
        let query = Self.randomVector(using: &generator)
        let normalizedQuery = try VisualEmbeddingCodec.normalizedQuery(
            query,
            expectedDimension: 512
        )
        var vectors = (0..<384).map { _ in Self.randomVector(using: &generator) }
        vectors.append(Self.axisVector(index: 0, value: 1))
        vectors.append(Self.axisVector(index: 511, value: -1))
        vectors.append((0..<512).map { index in
            index.isMultiple(of: 2) ? Float.leastNormalMagnitude : -Float.leastNormalMagnitude
        })
        vectors.append((0..<512).map { index in
            index == 0 ? 1 : (index.isMultiple(of: 2) ? 0.000_001 : -0.000_001)
        })

        var worstObservedError = 0.0
        var largestBound = 0.0
        for vector in vectors {
            let encoded = try VisualEmbeddingCodec.encode(
                vector,
                expectedDimension: 512,
                modelFingerprint: Self.fingerprintA
            )
            let approximate = try VisualEmbeddingCodec.similarity(
                normalizedQuery: normalizedQuery,
                bytes: encoded.bytes,
                scale: encoded.scale,
                expectedDimension: 512
            )
            let exact = Self.cosine(query, vector)
            let observedError = abs(exact - approximate)
            worstObservedError = max(worstObservedError, observedError)
            largestBound = max(largestBound, encoded.maximumCosineError)
            #expect(observedError <= encoded.maximumCosineError + 1e-12)
        }

        #expect(worstObservedError < 0.01)
        #expect(largestBound < 0.01)
    }

    @Test("Angular shortlist plus Int8 reranking preserves exact nearest neighbors")
    func shortlistRecallAgainstExactFloatRanking() throws {
        var generator = VisualTestGenerator(seed: 0x51_0A_7E)
        let query = Self.normalized(Self.randomVector(using: &generator))
        var noise = Self.normalized(Self.randomVector(using: &generator))
        let projection = zip(query, noise).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        noise = Self.normalized(zip(noise, query).map { $0.0 - projection * $0.1 })
        var vectors = [query]
        for rank in 1...31 {
            let perturbation = Float(rank) * 0.03
            vectors.append(zip(query, noise).map { $0.0 + perturbation * $0.1 })
        }
        vectors.append(contentsOf: (0..<4_064).map { _ in
            Self.randomVector(using: &generator)
        })

        let queryNormalized = try VisualEmbeddingCodec.normalizedQuery(
            query,
            expectedDimension: 512
        )
        let queryHash = VisualEmbeddingCodec.angularHash(
            normalizedVector: queryNormalized,
            modelFingerprint: Self.fingerprintA
        )
        let encoded = try vectors.map {
            try VisualEmbeddingCodec.encode(
                $0,
                expectedDimension: 512,
                modelFingerprint: Self.fingerprintA
            )
        }
        let exactScores = vectors.map { Self.cosine(query, $0) }
        let exactTop = vectors.indices.sorted {
            exactScores[$0] == exactScores[$1]
                ? $0 < $1
                : exactScores[$0] > exactScores[$1]
        }.prefix(20)
        let shortlist = try encoded.indices.sorted {
            let lhs = try Self.angularDistance(queryHash, encoded[$0].angularHash)
            let rhs = try Self.angularDistance(queryHash, encoded[$1].angularHash)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }.prefix(256)
        var approximateScores = [Int: Double]()
        for index in shortlist {
            approximateScores[index] = try VisualEmbeddingCodec.similarity(
                normalizedQuery: queryNormalized,
                bytes: encoded[index].bytes,
                scale: encoded[index].scale,
                expectedDimension: 512
            )
        }
        let approximateTop = shortlist.sorted {
            approximateScores[$0] == approximateScores[$1]
                ? $0 < $1
                : approximateScores[$0, default: -.infinity]
                    > approximateScores[$1, default: -.infinity]
        }.prefix(20)

        let exactSet = Set(exactTop)
        let recall = Double(approximateTop.filter(exactSet.contains).count) / 20
        #expect(approximateTop.first == exactTop.first)
        #expect(recall >= 0.95)
    }

    @Test("Malformed vectors are rejected before persistence")
    func malformedVectors() {
        #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try VisualEmbeddingCodec.encode(
                [Float](repeating: 1, count: 511),
                expectedDimension: 512,
                modelFingerprint: Self.fingerprintA
            )
        }
        #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try VisualEmbeddingCodec.encode(
                [Float](repeating: 0, count: 512),
                expectedDimension: 512,
                modelFingerprint: Self.fingerprintA
            )
        }
        var nonFinite = [Float](repeating: 1, count: 512)
        nonFinite[17] = .nan
        #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try VisualEmbeddingCodec.encode(
                nonFinite,
                expectedDimension: 512,
                modelFingerprint: Self.fingerprintA
            )
        }
    }

    private static func angularDistance(_ lhs: Data, _ rhs: Data) throws -> Int {
        try rhs.withUnsafeBytes { buffer in
            try VisualEmbeddingCodec.angularDistance(lhs, buffer)
        }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let lhsMagnitude = sqrt(lhs.reduce(0.0) { $0 + Double($1) * Double($1) })
        let rhsMagnitude = sqrt(rhs.reduce(0.0) { $0 + Double($1) * Double($1) })
        return zip(lhs, rhs).reduce(0.0) { result, pair in
            result + Double(pair.0) * Double(pair.1)
        } / (lhsMagnitude * rhsMagnitude)
    }

    private static func randomVector(using generator: inout VisualTestGenerator) -> [Float] {
        (0..<512).map { _ in generator.nextSignedFloat() }
    }

    private static func patternVector(phase: Double) -> [Float] {
        (0..<512).map { index in
            Float(sin(Double(index) * 0.071 + phase) + cos(Double(index) * 0.019 - phase))
        }
    }

    private static func axisVector(index: Int, value: Float) -> [Float] {
        var vector = [Float](repeating: 0, count: 512)
        vector[index] = value
        return vector
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        return vector.map { Float(Double($0) / magnitude) }
    }
}

private struct VisualTestGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextSignedFloat() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        let unit = Double(value >> 11) / Double(UInt64(1) << 53)
        return Float(unit * 2 - 1)
    }
}
