import Foundation

public struct VisualFrameScores: Equatable, Sendable {
    public var frameID: String
    public var similarities: [Double]

    public init(frameID: String, similarities: [Double]) {
        self.frameID = frameID
        self.similarities = similarities
    }
}

public struct RankedVisualFrame: Codable, Equatable, Sendable {
    public var frameID: String
    public var score: Double
    public var isPositive: Bool

    public init(frameID: String, score: Double, isPositive: Bool) {
        self.frameID = frameID
        self.score = score
        self.isPositive = isPositive
    }
}

public struct RecallAtK: Codable, Equatable, Sendable {
    public var k: Int
    public var matchingPositiveCount: Int
    public var eligiblePositiveCount: Int
    public var recall: Double?

    public init(
        k: Int,
        matchingPositiveCount: Int,
        eligiblePositiveCount: Int,
        recall: Double?
    ) {
        self.k = k
        self.matchingPositiveCount = matchingPositiveCount
        self.eligiblePositiveCount = eligiblePositiveCount
        self.recall = recall
    }
}

public struct VisualRetrievalEvaluation: Codable, Equatable, Sendable {
    public var rankedFrames: [RankedVisualFrame]
    public var recall: [RecallAtK]
    public var firstPositiveRank: Int?
    public var reciprocalRank: Double?

    public init(
        rankedFrames: [RankedVisualFrame],
        recall: [RecallAtK],
        firstPositiveRank: Int?,
        reciprocalRank: Double?
    ) {
        self.rankedFrames = rankedFrames
        self.recall = recall
        self.firstPositiveRank = firstPositiveRank
        self.reciprocalRank = reciprocalRank
    }
}

public enum VisualRanking {
    public static func evaluate(
        frames: [VisualFrameScores],
        promptIndex: Int,
        positiveFrameIDs: Set<String>,
        recallCutoffs: [Int] = [1, 5, 10, 20],
        reportedResultLimit: Int = 20
    ) -> VisualRetrievalEvaluation {
        let eligiblePositiveIDs = positiveFrameIDs.intersection(frames.lazy.map(\.frameID))
        let ranked = frames
            .compactMap { frame -> RankedVisualFrame? in
                guard frame.similarities.indices.contains(promptIndex) else { return nil }
                let score = frame.similarities[promptIndex]
                guard score.isFinite else { return nil }
                return RankedVisualFrame(
                    frameID: frame.frameID,
                    score: score,
                    isPositive: eligiblePositiveIDs.contains(frame.frameID)
                )
            }
            .sorted {
                if $0.score == $1.score { return $0.frameID < $1.frameID }
                return $0.score > $1.score
            }

        let firstPositiveRank = ranked.firstIndex(where: \.isPositive).map { $0 + 1 }
        let reciprocalRank = firstPositiveRank.map { 1 / Double($0) }
        let recall = Array(Set(recallCutoffs.filter { $0 > 0 }))
            .sorted()
            .map { cutoff -> RecallAtK in
                let matches = ranked.prefix(cutoff).lazy.filter(\.isPositive).count
                let denominator = eligiblePositiveIDs.count
                return RecallAtK(
                    k: cutoff,
                    matchingPositiveCount: matches,
                    eligiblePositiveCount: denominator,
                    recall: denominator == 0 ? nil : Double(matches) / Double(denominator)
                )
            }
        return VisualRetrievalEvaluation(
            rankedFrames: Array(ranked.prefix(max(reportedResultLimit, 0))),
            recall: recall,
            firstPositiveRank: firstPositiveRank,
            reciprocalRank: reciprocalRank
        )
    }

    public static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - fraction) + sorted[upperIndex] * fraction
    }
}
