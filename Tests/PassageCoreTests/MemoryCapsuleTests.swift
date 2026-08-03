import Foundation
import Testing
@testable import PassageCore

@Suite("One-call memory capsules")
struct MemoryCapsuleTests {
    @Test("Reciprocal-rank fusion keeps multimodal winners and discloses chronologically")
    func fusionAndChronology() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        let textOnly = candidate(
            id: "text",
            capturedAt: base.addingTimeInterval(20),
            app: "Editor",
            bundle: "app.editor",
            textRank: 1
        )
        let visualOnly = candidate(
            id: "visual",
            capturedAt: base,
            app: "Player",
            bundle: "app.player",
            visualRank: 1,
            visual: visualEvidence(similarity: 0.8)
        )
        let multimodal = candidate(
            id: "both",
            capturedAt: base.addingTimeInterval(10),
            app: "Browser",
            bundle: "app.browser",
            textRank: 2,
            visualRank: 2,
            visual: visualEvidence(similarity: 0.7)
        )
        let request = request(limit: 2)

        let first = try PassageMemoryCapsuleBuilder.build(
            request: request,
            candidates: [textOnly, visualOnly, multimodal]
        )
        let second = try PassageMemoryCapsuleBuilder.build(
            request: request,
            candidates: [textOnly, visualOnly, multimodal]
        )

        #expect(first == second)
        #expect(first.sources.contains(where: { $0.frameID.rawValue == "both" }))
        #expect(first.sources.map(\.capturedAt) == first.sources.map(\.capturedAt).sorted())
        #expect(first.coverage.savedTextCandidateCount == 2)
        #expect(first.coverage.visualAppearanceCandidateCount == 2)
        #expect(first.coverage.multimodalCandidateCount == 1)
        #expect(first.omissions.contains(where: { $0.reason == .resultLimit && $0.count == 1 }))
    }

    @Test("Projection strips media paths and sanitizes source URLs")
    func pathFreeAndSanitized() throws {
        var value = candidate(
            id: "source",
            capturedAt: Date(timeIntervalSince1970: 20_000),
            app: "Browser",
            bundle: "app.browser",
            textRank: 1
        )
        value.hit.imageRelativePath = "/Users/private/Library/Passage/Media/secret.bin"
        value.hit.thumbnailRelativePath = "Thumbnails/secret.bin"
        value.hit.context.url = URL(
            string: "https://person:password@example.com/private/path?token=secret#state"
        )

        let result = try PassageMemoryCapsuleBuilder.build(
            request: request(limit: 1),
            candidates: [value]
        )
        let canonical = String(decoding: try result.canonicalJSONData(), as: UTF8.self)

        #expect(result.sources.first?.url == "https://example.com")
        #expect(!canonical.contains("/Users/private"))
        #expect(!canonical.contains("Thumbnails/secret.bin"))
        #expect(!canonical.contains("password"))
        #expect(!canonical.contains("token=secret"))
        #expect(!canonical.contains("#state"))
    }

    @Test("Native semantics are relevance ordered, deduplicated, normalized, and bounded")
    func accessibilityProjection() throws {
        var value = candidate(
            id: "semantic",
            capturedAt: Date(timeIntervalSince1970: 30_000),
            app: "Invoices",
            bundle: "app.invoices",
            textRank: 1
        )
        value.accessibility = [
            .init(role: "AXStaticText", label: "Unrelated footer", depth: 3),
            .init(
                role: "AXButton",
                label: "Submit\u{0000} invoice",
                depth: -4,
                normalizedBounds: ScreenRect(x: -0.2, y: 0.25, width: 1.4, height: 0.2)
            ),
            .init(
                role: "AXButton",
                label: "Submit\u{0000} invoice",
                depth: -4,
                normalizedBounds: ScreenRect(x: -0.2, y: 0.25, width: 1.4, height: 0.2)
            ),
            .init(
                role: "AXTextField",
                value: "Invoice 1842",
                depth: 2,
                normalizedBounds: ScreenRect(x: 2, y: 2, width: 0.2, height: 0.2)
            )
        ]
        let result = try PassageMemoryCapsuleBuilder.build(
            request: request(text: "submit invoice", limit: 1),
            candidates: [value]
        )
        let nodes = try #require(result.sources.first?.accessibility)

        #expect(nodes.first?.label == "Submit invoice")
        #expect(nodes.first?.depth == 0)
        #expect(nodes.first?.normalizedBounds == ScreenRect(x: 0, y: 0.25, width: 1, height: 0.2))
        #expect(nodes.count == 3)
        #expect(nodes.last(where: { $0.role == "AXTextField" })?.normalizedBounds == nil)
        #expect(result.sources.first?.evidenceModalities.contains(.accessibility) == true)
    }

    @Test("Exact byte accounting truncates only at Unicode character boundaries")
    func exactByteBudget() throws {
        let repeated = String(repeating: "Family 👨‍👩‍👧‍👦 remembers café. ", count: 1_000)
        var value = candidate(
            id: "bounded",
            capturedAt: Date(timeIntervalSince1970: 40_000),
            app: "Notes",
            bundle: "app.notes",
            textRank: 1,
            ocrText: repeated
        )
        value.accessibility = (0..<30).map {
            .init(role: "AXStaticText", label: "Semantic line \($0) " + String(repeating: "x", count: 80), depth: 2)
        }
        let boundedRequest = request(limit: 1, byteBudget: 2_048)
        let result = try PassageMemoryCapsuleBuilder.build(
            request: boundedRequest,
            candidates: [value]
        )
        let encoded = try result.canonicalJSONData()

        #expect(result.encodedUTF8Bytes == encoded.count)
        #expect(encoded.count <= boundedRequest.utf8ByteBudget)
        #expect(String(data: encoded, encoding: .utf8) != nil)
        #expect(result.sources.first?.ocrTextTruncated == true)
        #expect(result.sources.first?.accessibilityTruncated == true)
        #expect(result.omissions.contains(where: { $0.reason == .ocrTruncation }))
        #expect(result.omissions.contains(where: { $0.reason == .accessibilityTruncation }))
    }

    @Test("Sensitive candidates and visual-index limitations are explicit")
    func privacyAndAvailabilityOmissions() throws {
        var sensitive = candidate(
            id: "private",
            capturedAt: Date(timeIntervalSince1970: 50_000),
            app: "Passwords",
            bundle: "app.passwords",
            textRank: 1
        )
        sensitive.hit.context.isSensitive = true
        let ordinary = candidate(
            id: "ordinary",
            capturedAt: Date(timeIntervalSince1970: 50_001),
            app: "Notes",
            bundle: "app.notes",
            textRank: 2
        )
        let result = try PassageMemoryCapsuleBuilder.build(
            request: request(limit: 2),
            candidates: [sensitive, ordinary],
            hasMoreCandidates: true,
            visualIndexCoverageFraction: 0.4,
            additionalOmissions: [
                .init(reason: .visualIndexPartial, count: 1)
            ]
        )

        #expect(result.sources.map(\.frameID.rawValue) == ["ordinary"])
        #expect(result.coverage.visualIndexCoverageFraction == 0.4)
        #expect(result.coverage.isLowerBound)
        #expect(!result.omissions.contains(where: { $0.reason == .sensitiveContext }))
        #expect(result.omissions.contains(where: { $0.reason == .candidateWindow && $0.countIsLowerBound }))
        #expect(result.omissions.contains(where: { $0.reason == .visualIndexPartial }))
    }

    @Test("Only requested retrieval modalities influence rank and provenance")
    func requestedModalitiesAreAuthoritative() throws {
        let both = candidate(
            id: "both",
            capturedAt: Date(timeIntervalSince1970: 60_000),
            app: "Browser",
            bundle: "app.browser",
            textRank: 1,
            visualRank: 1,
            visual: visualEvidence(similarity: 0.9)
        )
        let textOnlyRequest = PassageMemoryCapsuleRequest(
            query: SearchQuery(text: "browser", limit: 1),
            retrievalModalities: [.savedText],
            resultLimit: 1,
            utf8ByteBudget: 4_096
        )
        let textOnly = try PassageMemoryCapsuleBuilder.build(
            request: textOnlyRequest,
            candidates: [both]
        )
        #expect(textOnly.sources.first?.savedTextRank == 1)
        #expect(textOnly.sources.first?.visualAppearanceRank == nil)
        #expect(textOnly.sources.first?.visual == nil)
        #expect(textOnly.coverage.visualAppearanceCandidateCount == 0)

        let visualOnlyRequest = PassageMemoryCapsuleRequest(
            query: SearchQuery(text: "browser", limit: 1),
            retrievalModalities: [.visualAppearance],
            resultLimit: 1,
            utf8ByteBudget: 4_096
        )
        let visualOnly = try PassageMemoryCapsuleBuilder.build(
            request: visualOnlyRequest,
            candidates: [both]
        )
        #expect(visualOnly.sources.first?.savedTextRank == nil)
        #expect(visualOnly.sources.first?.visualAppearanceRank == 1)
        #expect(visualOnly.sources.first?.visual != nil)
        #expect(visualOnly.coverage.savedTextCandidateCount == 0)
    }

    private func request(
        text: String = "person in a browser",
        limit: Int,
        byteBudget: Int = PassageMemoryCapsuleSchema.defaultUTF8ByteBudget
    ) -> PassageMemoryCapsuleRequest {
        PassageMemoryCapsuleRequest(
            query: SearchQuery(text: text, limit: limit),
            resultLimit: limit,
            utf8ByteBudget: byteBudget
        )
    }

    private func candidate(
        id: String,
        capturedAt: Date,
        app: String,
        bundle: String,
        textRank: Int? = nil,
        visualRank: Int? = nil,
        visual: PassageMemoryVisualEvidence? = nil,
        ocrText: String = "A useful remembered detail"
    ) -> PassageMemoryCapsuleCandidate {
        PassageMemoryCapsuleCandidate(
            hit: SearchHit(
                id: FrameID(rawValue: id),
                activitySessionID: ActivitySessionID(rawValue: "session-\(id)"),
                capturedAt: capturedAt,
                context: ScreenContext(
                    applicationName: app,
                    bundleIdentifier: bundle,
                    windowTitle: "Window \(id)",
                    domain: id == "visual" ? "example.com" : nil
                ),
                snippet: ocrText,
                imageRelativePath: "Media/\(id).bin",
                thumbnailRelativePath: "Thumbnails/\(id).bin",
                score: 1
            ),
            ocrText: ocrText,
            savedTextRank: textRank,
            visualAppearanceRank: visualRank,
            visual: visual
        )
    }

    private func visualEvidence(similarity: Double) -> PassageMemoryVisualEvidence {
        PassageMemoryVisualEvidence(
            similarity: similarity,
            maximumSimilarityError: 0.01,
            associatedFrameCount: 1,
            modelIdentifier: "pe-core",
            modelRevision: "test"
        )
    }
}
