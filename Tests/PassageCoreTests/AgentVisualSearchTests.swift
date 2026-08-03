import PassageCore
import Foundation
import Testing

@Suite("Agent visual-search disclosure")
struct AgentVisualSearchTests {
    @Test("Defaults are bounded for compact metadata-only answers")
    func defaults() {
        let request = PassageAgentVisualSearchRequest(description: "a whiteboard sketch")

        #expect(request.scope == RecallScope())
        #expect(request.resultLimit == 6)
        #expect(request.utf8ByteBudget == 64 * 1_024)
        #expect(request.disclosure == .metadataOnly)
        #expect(PassageAgentVisualSearchSchema.maximumResultLimit == 20)
        #expect(PassageAgentVisualSearchSchema.minimumUTF8ByteBudget == 1_024)
        #expect(PassageAgentVisualSearchSchema.maximumUTF8ByteBudget == 256 * 1_024)
    }

    @Test("Manifest is canonical, path-free, sanitized, and conservatively admitted")
    func canonicalMinimalDisclosure() throws {
        let request = PassageAgentVisualSearchRequest(
            description: "a project planning board",
            scope: RecallScope(
                startDate: Date(timeIntervalSince1970: 900),
                endDate: Date(timeIntervalSince1970: 2_000),
                applicationBundleIdentifiers: ["com.apple.Safari"],
                domains: ["example.com"]
            ),
            resultLimit: 2
        )
        let candidates = [
            Self.match(id: "sensitive", similarity: 0.99, error: 0, sensitive: true),
            Self.match(id: "rounding-risk", similarity: 0.250, error: 0.010),
            Self.match(
                id: "best",
                similarity: 0.310,
                error: 0.010,
                url: "https://alice:secret@example.com/board?token=private#selection"
            ),
            Self.match(
                id: "unsupported-url",
                similarity: 0.305,
                error: 0.010,
                url: "file:///Thumbnails/private.bin"
            ),
            Self.match(id: "look-ahead", similarity: 0.300, error: 0.010),
        ]

        let first = try PassageAgentVisualSearchBuilder.build(
            request: request,
            candidates: candidates,
            coverage: Self.coverage,
            minimumSimilarity: 0.245
        )
        let second = try PassageAgentVisualSearchBuilder.build(
            request: request,
            candidates: candidates,
            coverage: Self.coverage,
            minimumSimilarity: 0.245
        )

        #expect(first == second)
        #expect(first.requestedCount == 2)
        #expect(first.matchedCount == 3)
        #expect(first.disclosedCount == 2)
        #expect(first.hasMore)
        #expect(first.truncated)
        #expect(first.sources.map(\.frameID.rawValue) == ["best", "unsupported-url"])
        #expect(abs(first.sources[0].minimumPossibleSimilarity - 0.300) < 0.000_001)
        #expect(first.sources[0].url == "https://example.com/board")
        #expect(first.sources[1].url == nil)
        #expect(first.omissionReasons.contains(.sensitiveContext))
        #expect(first.omissionReasons.contains(.belowMinimumSimilarity))
        #expect(first.omissionReasons.contains(.resultLimit))

        let canonical = try first.canonicalJSONData()
        #expect(first.encodedUTF8Bytes == canonical.count)
        #expect(first.encodedUTF8Bytes <= request.utf8ByteBudget)
        let encoded = try #require(String(data: canonical, encoding: .utf8))
        #expect(!encoded.contains("Media/"))
        #expect(!encoded.contains("Thumbnails/"))
        #expect(!encoded.contains(".bin"))
        #expect(!encoded.contains("secret"))
        #expect(!encoded.contains("token"))
        #expect(!encoded.contains("windowBounds"))
        #expect(!encoded.contains("pixelWidth"))
        #expect(!encoded.contains("imageRelativePath"))
    }

    @Test("Byte fitting truncates OCR only at Unicode character boundaries")
    func unicodeSafeByteFit() throws {
        let snippet = String(repeating: "👩🏽‍💻 café 漢字 ", count: 500)
        let request = PassageAgentVisualSearchRequest(
            description: "developer at a laptop",
            resultLimit: 1,
            utf8ByteBudget: 2_048
        )
        let manifest = try PassageAgentVisualSearchBuilder.build(
            request: request,
            candidates: [Self.match(id: "unicode", similarity: 0.5, error: 0.01, snippet: snippet)],
            coverage: Self.coverage,
            minimumSimilarity: 0.245
        )

        let source = try #require(manifest.sources.first)
        #expect(source.snippetTruncated)
        #expect(!source.ocrSnippet.isEmpty)
        #expect(source.ocrSnippet != snippet)
        #expect(snippet.hasPrefix(source.ocrSnippet))
        #expect(manifest.omissionReasons.contains(.utf8ByteBudget))
        #expect(manifest.omissionReasons.contains(.ocrSnippetTruncated))
        #expect(manifest.encodedUTF8Bytes == (try manifest.canonicalJSONData()).count)
        #expect(manifest.encodedUTF8Bytes <= request.utf8ByteBudget)
        #expect(String(data: try manifest.canonicalJSONData(), encoding: .utf8) != nil)
    }

    private static let model = VisualModelIdentity(
        identifier: "pe-core-s-16-384",
        revision: "1",
        fingerprint: "0123456789abcdef",
        preprocessingRevision: "passage-384-v1",
        embeddingDimension: 512
    )

    private static let coverage = VisualEmbeddingCoverage(
        model: model,
        eligibleFrameCount: 100,
        indexedEligibleFrameCount: 80,
        indexedFrameCount: 80,
        pendingEligibleFrameCount: 20,
        staleEmbeddingCount: 2,
        uniqueVectorCount: 60,
        deduplicatedFrameCount: 20,
        storedVectorPayloadBytes: 30_720,
        coverageFraction: 0.8
    )

    private static func match(
        id: String,
        similarity: Double,
        error: Double,
        sensitive: Bool = false,
        url: String? = nil,
        snippet: String = "Planning notes"
    ) -> VisualEmbeddingMatch {
        VisualEmbeddingMatch(
            hit: SearchHit(
                id: FrameID(rawValue: id),
                capturedAt: Date(timeIntervalSince1970: 1_234),
                context: ScreenContext(
                    applicationName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    windowTitle: "Project board",
                    url: url.flatMap(URL.init(string:)),
                    domain: "example.com",
                    displayID: 9,
                    windowID: 42,
                    windowBounds: ScreenRect(x: 1, y: 2, width: 3, height: 4),
                    isSensitive: sensitive
                ),
                snippet: snippet,
                imageRelativePath: "Media/Thumbnails/private.bin",
                score: similarity
            ),
            similarity: similarity,
            maximumSimilarityError: error,
            model: model,
            associatedFrameCount: 3
        )
    }
}
