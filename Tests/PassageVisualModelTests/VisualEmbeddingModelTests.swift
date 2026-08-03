@testable import PassageVisualModel
import PassageCore
import Foundation
import Testing

struct VisualEmbeddingModelTests {
    @Test("Embeddings normalize once and cosine similarity is bounded")
    func normalizationAndSimilarity() throws {
        let first = try NormalizedVisualEmbedding(normalizing: [3, 4])
        let sameDirection = try NormalizedVisualEmbedding(normalizing: [6, 8])
        let orthogonal = try NormalizedVisualEmbedding(normalizing: [-4, 3])

        #expect(abs(first.values[0] - 0.6) < 0.000_01)
        #expect(abs(first.values[1] - 0.8) < 0.000_01)
        #expect(abs(try first.cosineSimilarity(to: sameDirection) - 1) < 0.000_01)
        #expect(abs(try first.cosineSimilarity(to: orthogonal)) < 0.000_01)
    }

    @Test("Invalid vectors and encoded images fail before reaching a runtime")
    func invalidInputs() {
        #expect(throws: VisualEmbeddingError.self) {
            try NormalizedVisualEmbedding(normalizing: [])
        }
        #expect(throws: VisualEmbeddingError.self) {
            try NormalizedVisualEmbedding(normalizing: [0, 0])
        }
        #expect(throws: VisualEmbeddingError.self) {
            try NormalizedVisualEmbedding(normalizing: [.nan])
        }
        #expect(throws: VisualEmbeddingError.self) {
            try VisualEmbeddingImage(encodedBytes: Data())
        }
        #expect(throws: VisualEmbeddingError.self) {
            let lhs = try NormalizedVisualEmbedding(normalizing: [1, 0])
            let rhs = try NormalizedVisualEmbedding(normalizing: [1, 0, 0])
            _ = try lhs.cosineSimilarity(to: rhs)
        }
    }

    @Test("Runtime wrappers enforce the canonical Core model identity")
    func validatesRuntimeDimensionAndText() async throws {
        let model = StubVisualEmbeddingModel()
        let image = try VisualEmbeddingImage(encodedBytes: Data([0xFF, 0xD8, 0xFF]))
        let imageEmbedding = try await model.validatedImageEmbedding(for: image)
        #expect(imageEmbedding.dimension == 3)
        let textEmbedding = try await model.validatedTextEmbedding(for: "  person with glasses  ")
        #expect(textEmbedding.dimension == 3)

        await #expect(throws: VisualEmbeddingError.self) {
            try await model.validatedTextEmbedding(for: "  \n ")
        }

        let mismatched = StubVisualEmbeddingModel(reportedDimension: 4)
        await #expect(throws: VisualEmbeddingError.self) {
            try await mismatched.validatedImageEmbedding(for: image)
        }
    }
}

private struct StubVisualEmbeddingModel: VisualEmbeddingModel {
    var reportedDimension = 3

    var identity: VisualModelIdentity {
        VisualModelIdentity(
            identifier: "stub",
            revision: "1",
            fingerprint: String(repeating: "a", count: 64),
            preprocessingRevision: "test-v1",
            embeddingDimension: reportedDimension
        )
    }

    func embed(image: VisualEmbeddingImage) async throws -> NormalizedVisualEmbedding {
        try NormalizedVisualEmbedding(normalizing: [1, 2, 3])
    }

    func embed(text: String) async throws -> NormalizedVisualEmbedding {
        try NormalizedVisualEmbedding(normalizing: [3, 2, 1])
    }
}
