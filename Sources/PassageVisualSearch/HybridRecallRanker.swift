import PassageCore
import Foundation

/// The visual reason a remembered moment was admitted to a hybrid Recall result.
/// Similarity stays separate from OCR so presentation can explain the match
/// without implying that the query words appeared on screen.
public struct VisualRecallEvidence: Equatable, Sendable {
    public var similarity: Double
    public var maximumSimilarityError: Double
    public var associatedFrameCount: Int
    public var model: VisualModelIdentity
    public var region: VisualRegionRecallEvidence?

    public init(
        similarity: Double,
        maximumSimilarityError: Double,
        associatedFrameCount: Int,
        model: VisualModelIdentity,
        region: VisualRegionRecallEvidence? = nil
    ) {
        self.similarity = similarity
        self.maximumSimilarityError = maximumSimilarityError
        self.associatedFrameCount = associatedFrameCount
        self.model = model
        self.region = region
    }

    /// A conservative lower bound after Passage's Int8 storage error.
    public var minimumPossibleSimilarity: Double {
        similarity - maximumSimilarityError
    }
}

public struct HybridRecallResult: Equatable, Sendable {
    public var hits: [SearchHit]
    public var visualEvidenceByFrameID: [FrameID: VisualRecallEvidence]
    public var visuallyRankedFrameIDs: Set<FrameID>

    public init(
        hits: [SearchHit],
        visualEvidenceByFrameID: [FrameID: VisualRecallEvidence],
        visuallyRankedFrameIDs: Set<FrameID>
    ) {
        self.hits = hits
        self.visualEvidenceByFrameID = visualEvidenceByFrameID
        self.visuallyRankedFrameIDs = visuallyRankedFrameIDs
    }

    public var includesVisualMatches: Bool {
        !visuallyRankedFrameIDs.isEmpty
    }
}

public struct HybridRecallPolicy: Equatable, Sendable {
    public var minimumVisualSimilarity: Double
    public var resultLimit: Int
    public var reciprocalRankConstant: Double
    public var lexicalWeight: Double
    public var visualWeight: Double

    public init(
        minimumVisualSimilarity: Double,
        resultLimit: Int = 60,
        reciprocalRankConstant: Double = 60,
        lexicalWeight: Double = 1.15,
        visualWeight: Double = 1
    ) {
        self.minimumVisualSimilarity = min(max(minimumVisualSimilarity, -1), 1)
        self.resultLimit = min(max(resultLimit, 1), RecallPage.maximumLimit)
        self.reciprocalRankConstant = max(reciprocalRankConstant, 1)
        self.lexicalWeight = max(lexicalWeight, 0)
        self.visualWeight = max(visualWeight, 0)
    }
}

/// Deterministic reciprocal-rank fusion for local text and appearance evidence.
///
/// The caller supplies a benchmark-calibrated visual threshold. Passage uses
/// the conservative similarity lower bound so quantization uncertainty cannot
/// promote a borderline match. Exact-word search bypasses this type entirely.
public enum HybridRecallRanker {
    public static func fuse(
        lexicalHits: [SearchHit],
        visualMatches: [VisualEmbeddingMatch],
        regionEvidenceByFrameID: [FrameID: VisualRegionRecallEvidence] = [:],
        policy: HybridRecallPolicy
    ) -> HybridRecallResult {
        var candidates = [FrameID: Candidate]()

        for (index, hit) in lexicalHits.enumerated() {
            var candidate = candidates[hit.id] ?? Candidate(hit: hit)
            candidate.score += policy.lexicalWeight
                / (policy.reciprocalRankConstant + Double(index + 1))
            candidate.lexicalRank = min(candidate.lexicalRank ?? Int.max, index)
            candidate.hit = hit
            candidates[hit.id] = candidate
        }

        for (index, match) in visualMatches.enumerated() {
            let evidence = VisualRecallEvidence(
                similarity: match.similarity,
                maximumSimilarityError: match.maximumSimilarityError,
                associatedFrameCount: match.associatedFrameCount,
                model: match.model,
                region: regionEvidenceByFrameID[match.hit.id]
            )
            guard evidence.minimumPossibleSimilarity >= policy.minimumVisualSimilarity else {
                continue
            }
            var candidate = candidates[match.hit.id] ?? Candidate(hit: match.hit)
            candidate.score += policy.visualWeight
                / (policy.reciprocalRankConstant + Double(index + 1))
            candidate.visualRank = min(candidate.visualRank ?? Int.max, index)
            candidate.visualEvidence = bestEvidence(candidate.visualEvidence, evidence)
            // Prefer the lexical SearchHit when the same frame appeared in both
            // streams because it carries highlighted snippet markers.
            if candidate.lexicalRank == nil {
                candidate.hit = match.hit
            }
            candidates[match.hit.id] = candidate
        }

        let ordered = candidates.values.sorted(by: candidateIsBetter).prefix(policy.resultLimit)
        let hits = ordered.map(\.hit)
        let evidence = Dictionary(uniqueKeysWithValues: ordered.compactMap { candidate in
            candidate.visualEvidence.map { (candidate.hit.id, $0) }
        })
        let visualIDs = Set(ordered.compactMap { candidate in
            candidate.visualRank == nil ? nil : candidate.hit.id
        })
        return HybridRecallResult(
            hits: hits,
            visualEvidenceByFrameID: evidence,
            visuallyRankedFrameIDs: visualIDs
        )
    }

    private struct Candidate {
        var hit: SearchHit
        var score = 0.0
        var lexicalRank: Int?
        var visualRank: Int?
        var visualEvidence: VisualRecallEvidence?
    }

    private static func bestEvidence(
        _ current: VisualRecallEvidence?,
        _ proposed: VisualRecallEvidence
    ) -> VisualRecallEvidence {
        guard let current else { return proposed }
        if proposed.minimumPossibleSimilarity != current.minimumPossibleSimilarity {
            return proposed.minimumPossibleSimilarity > current.minimumPossibleSimilarity
                ? proposed
                : current
        }
        return proposed.similarity > current.similarity ? proposed : current
    }

    private static func candidateIsBetter(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsBestRank = min(lhs.lexicalRank ?? Int.max, lhs.visualRank ?? Int.max)
        let rhsBestRank = min(rhs.lexicalRank ?? Int.max, rhs.visualRank ?? Int.max)
        if lhsBestRank != rhsBestRank { return lhsBestRank < rhsBestRank }
        if lhs.hit.capturedAt != rhs.hit.capturedAt {
            return lhs.hit.capturedAt > rhs.hit.capturedAt
        }
        return lhs.hit.id.rawValue > rhs.hit.id.rawValue
    }
}
