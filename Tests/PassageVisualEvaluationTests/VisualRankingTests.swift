@testable import PassageVisualEvaluation
import Foundation
import Testing

struct VisualRankingTests {
    @Test
    func calculatesRecallAndReciprocalRankFromOpaqueIDs() {
        let frames = [
            VisualFrameScores(frameID: "frame-a", similarities: [0.9]),
            VisualFrameScores(frameID: "frame-b", similarities: [0.8]),
            VisualFrameScores(frameID: "frame-c", similarities: [0.7]),
            VisualFrameScores(frameID: "frame-d", similarities: [0.6]),
        ]

        let result = VisualRanking.evaluate(
            frames: frames,
            promptIndex: 0,
            positiveFrameIDs: ["frame-b", "frame-d", "not-in-corpus"],
            recallCutoffs: [4, 1, 2, 2],
            reportedResultLimit: 3
        )

        #expect(result.firstPositiveRank == 2)
        #expect(result.reciprocalRank == 0.5)
        #expect(result.rankedFrames.map(\.frameID) == ["frame-a", "frame-b", "frame-c"])
        #expect(result.recall == [
            RecallAtK(k: 1, matchingPositiveCount: 0, eligiblePositiveCount: 2, recall: 0),
            RecallAtK(k: 2, matchingPositiveCount: 1, eligiblePositiveCount: 2, recall: 0.5),
            RecallAtK(k: 4, matchingPositiveCount: 2, eligiblePositiveCount: 2, recall: 1),
        ])
    }

    @Test
    func tieBreaksByOpaqueFrameIDForRepeatableReports() {
        let result = VisualRanking.evaluate(
            frames: [
                VisualFrameScores(frameID: "z", similarities: [0.5]),
                VisualFrameScores(frameID: "a", similarities: [0.5]),
            ],
            promptIndex: 0,
            positiveFrameIDs: [],
            recallCutoffs: [1]
        )

        #expect(result.rankedFrames.map(\.frameID) == ["a", "z"])
        #expect(result.recall.first?.recall == nil)
    }

    @Test
    func interpolatesLatencyPercentiles() {
        #expect(VisualRanking.percentile([], percentile: 0.95) == nil)
        #expect(VisualRanking.percentile([10], percentile: 0.95) == 10)
        #expect(VisualRanking.percentile([0, 10, 20], percentile: 0.5) == 10)
        #expect(VisualRanking.percentile([0, 10], percentile: 0.25) == 2.5)
        #expect(VisualRanking.percentile([0, 10], percentile: 2) == 10)
    }

    @Test
    func framedJSONRoundTripsWithoutEmbeddingPayloadInResponse() throws {
        struct Message: Codable, Equatable {
            var operation: String
            var payloadBytes: Int
        }
        let pipe = Pipe()
        let expected = Message(operation: "score-image", payloadBytes: 7)
        try WireCodec.writeJSON(expected, payload: nil, to: pipe.fileHandleForWriting)
        pipe.fileHandleForWriting.closeFile()

        let decoded: Message = try WireCodec.readJSON(from: pipe.fileHandleForReading)
        #expect(decoded == expected)
    }
}
