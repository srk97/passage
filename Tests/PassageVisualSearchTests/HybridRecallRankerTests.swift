import PassageCore
import PassageVisualSearch
import Foundation
import Testing

@Suite("Hybrid Recall ranking")
struct HybridRecallRankerTests {
    @Test("Appearance-only memories are admitted and lexical highlights survive fusion")
    func combinesEvidenceWithoutInventingText() {
        let lexical = hit("lexical", seconds: 1, snippet: "‹glasses› in notes")
        let sharedLexical = hit("shared", seconds: 2, snippet: "‹man› in a caption")
        let visualOnly = hit("visual", seconds: 3, snippet: "ordinary unhighlighted OCR")
        let result = HybridRecallRanker.fuse(
            lexicalHits: [sharedLexical, lexical],
            visualMatches: [
                match(visualOnly, similarity: 0.42),
                match(sharedLexical, similarity: 0.40),
            ],
            policy: HybridRecallPolicy(minimumVisualSimilarity: 0.20)
        )

        #expect(result.hits.map(\.id) == [sharedLexical.id, lexical.id, visualOnly.id])
        #expect(result.hits[0].snippet == "‹man› in a caption")
        #expect(result.hits[2].snippet == "ordinary unhighlighted OCR")
        #expect(result.visualEvidenceByFrameID[visualOnly.id]?.similarity == 0.42)
        #expect(result.visuallyRankedFrameIDs == [sharedLexical.id, visualOnly.id])
    }

    @Test("Quantization uncertainty rejects borderline visual matches")
    func usesConservativeSimilarityBound() {
        let safe = hit("safe", seconds: 1)
        let borderline = hit("borderline", seconds: 2)
        let result = HybridRecallRanker.fuse(
            lexicalHits: [],
            visualMatches: [
                match(safe, similarity: 0.31, error: 0.01),
                match(borderline, similarity: 0.31, error: 0.02),
            ],
            policy: HybridRecallPolicy(minimumVisualSimilarity: 0.30)
        )

        #expect(result.hits.map(\.id) == [safe.id])
        #expect(result.visualEvidenceByFrameID[borderline.id] == nil)
    }

    @Test("Result limits and deterministic ties are stable")
    func deterministicLimit() {
        let older = hit("a", seconds: 1)
        let newer = hit("b", seconds: 2)
        let result = HybridRecallRanker.fuse(
            lexicalHits: [older, newer],
            visualMatches: [],
            policy: HybridRecallPolicy(
                minimumVisualSimilarity: 0,
                resultLimit: 1,
                lexicalWeight: 0,
                visualWeight: 0
            )
        )

        #expect(result.hits.map(\.id) == [older.id])
        #expect(!result.includesVisualMatches)
    }

    @Test("Region provenance stays attached to one visual stream")
    func regionProvenanceDoesNotDoubleCount() throws {
        let frame = hit("region", seconds: 3)
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.2,
            y: 0.3,
            width: 0.4,
            height: 0.5
        ))
        let region = VisualRegionRecallEvidence(
            kind: .face,
            bounds: bounds,
            similarity: 0.44,
            sourceVisualFingerprint: 42
        )

        let result = HybridRecallRanker.fuse(
            lexicalHits: [frame],
            visualMatches: [match(frame, similarity: 0.44, error: 0)],
            regionEvidenceByFrameID: [frame.id: region],
            policy: HybridRecallPolicy(minimumVisualSimilarity: 0.30)
        )

        #expect(result.hits == [frame])
        #expect(result.visualRecallEvidence(for: frame.id)?.region == region)
        #expect(result.visuallyRankedFrameIDs == [frame.id])
    }

    private func match(
        _ hit: SearchHit,
        similarity: Double,
        error: Double = 0.001
    ) -> VisualEmbeddingMatch {
        VisualEmbeddingMatch(
            hit: hit,
            similarity: similarity,
            maximumSimilarityError: error,
            model: VisualModelIdentity(
                identifier: "pe",
                revision: "1",
                fingerprint: String(repeating: "a", count: 64),
                preprocessingRevision: "v1",
                embeddingDimension: 512
            ),
            associatedFrameCount: 1
        )
    }

    private func hit(
        _ id: String,
        seconds: TimeInterval,
        snippet: String = "plain OCR"
    ) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: seconds),
            context: ScreenContext(
                applicationName: "Example",
                bundleIdentifier: "com.example.app"
            ),
            snippet: snippet,
            imageRelativePath: "\(id).heic",
            thumbnailRelativePath: "\(id).heic",
            score: 0
        )
    }
}

private extension HybridRecallResult {
    func visualRecallEvidence(for id: FrameID) -> VisualRecallEvidence? {
        visualEvidenceByFrameID[id]
    }
}
