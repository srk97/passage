import Foundation
import Testing
@testable import PassageCore

@Suite("Shared memory-segment contracts")
struct MemorySegmentTests {
    @Test("Scope normalization is deterministic and dates are half open")
    func scopeNormalizationAndHalfOpenRange() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_100)
        let first = try MemorySegmentScope(
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: [" app.notes ", "app.browser", "app.notes", ""],
            domains: [" EXAMPLE.com ", "docs.example.com", "example.COM", ""],
            activitySessionIDs: [
                ActivitySessionID(rawValue: "session-b"),
                ActivitySessionID(rawValue: "session-a"),
                ActivitySessionID(rawValue: "session-b"),
                ActivitySessionID(rawValue: " "),
            ]
        )
        let second = try MemorySegmentScope(
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: ["app.browser", "app.notes"],
            domains: ["docs.example.com", "example.com"],
            activitySessionIDs: [
                ActivitySessionID(rawValue: "session-a"),
                ActivitySessionID(rawValue: "session-b"),
            ]
        )

        #expect(first == second)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.applicationBundleIdentifiers == ["app.browser", "app.notes"])
        #expect(first.domains == ["docs.example.com", "example.com"])
        #expect(first.activitySessionIDs.map(\.rawValue) == ["session-a", "session-b"])

        let differentlyPartitioned = try MemorySegmentScope(
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: ["app.browser", "app.notes", "docs.example.com"],
            domains: ["example.com"],
            activitySessionIDs: first.activitySessionIDs
        )
        #expect(first.fingerprint != differentlyPartitioned.fingerprint)

        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentScope(startDate: end, endDate: start)
        }
        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentScope(startDate: start, endDate: start)
        }
        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentScope(startDate: Date(timeIntervalSince1970: .nan))
        }
    }

    @Test("Segment identity is stable while exact content changes revision")
    func deterministicIdentityAndRevision() throws {
        let fixture = try Self.fixture()
        let first = try Self.segment(fixture: fixture, snippet: "  Design\n review ready  ")
        let equivalent = try Self.segment(fixture: fixture, snippet: "Design review ready")
        let enriched = try Self.segment(fixture: fixture, snippet: "Design review approved")

        #expect(first == equivalent)
        #expect(first.id == enriched.id)
        #expect(first.revisionID != enriched.revisionID)
        #expect(first.frameIDs == fixture.frameIDs)
        #expect(first.representativeEvidence.map(\.frameID) == [fixture.frameIDs[1]])
        #expect(first.modalityCoverage.map(\.modality) == [.ocr, .visualSimilarity])
        #expect(first.modalityCoverage[0].state == .complete)
        #expect(first.modalityCoverage[1].state == .partial)
        #expect(first.modalityCoverage[1].coveredFraction == 1.0 / 3.0)

        let revisions = [first.revisionID, enriched.revisionID]
        #expect(
            MemorySegmentIndexRevision.derived(from: revisions)
                == MemorySegmentIndexRevision.derived(from: revisions.reversed())
        )
    }

    @Test("Codable round trip preserves validated identities and exact lineage")
    func codableRoundTrip() throws {
        let fixture = try Self.fixture()
        let segment = try Self.segment(fixture: fixture, snippet: "Remember this")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(segment)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(MemorySegment.self, from: data)

        #expect(decoded == segment)
        #expect(decoded.frameIDs == fixture.frameIDs)
        #expect(decoded.revisionID == segment.revisionID)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["revisionID"] = "forged-revision"
        let forged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: MemorySegmentValidationError.self) {
            try decoder.decode(MemorySegment.self, from: forged)
        }
    }

    @Test("Lineage, representatives, and modality provenance fail closed")
    func invalidConstruction() throws {
        let fixture = try Self.fixture()
        let representative = try Self.representative(
            frameID: fixture.frameIDs[1],
            capturedAt: fixture.start.addingTimeInterval(20),
            snippet: "Evidence"
        )
        let coverage = try Self.coverage(frameIDs: fixture.frameIDs)

        #expect(throws: MemorySegmentValidationError.self) {
            _ = try MemorySegment(
                scope: fixture.scope,
                frameIDs: [fixture.frameIDs[0], fixture.frameIDs[0]],
                representativeEvidence: [representative],
                modalityCoverage: coverage,
                containsSensitive: false
            )
        }
        #expect(throws: MemorySegmentValidationError.self) {
            _ = try MemorySegment(
                scope: fixture.scope,
                frameIDs: fixture.frameIDs,
                representativeEvidence: [
                    try Self.representative(
                        frameID: FrameID(rawValue: "outside"),
                        capturedAt: fixture.start.addingTimeInterval(20),
                        snippet: "Outside lineage"
                    ),
                ],
                modalityCoverage: coverage,
                containsSensitive: false
            )
        }
        #expect(throws: MemorySegmentValidationError.self) {
            let reversedSource = try MemorySegmentModalityProvenance(
                producerIdentifier: "vision.ocr",
                producerRevision: "2",
                frameIDs: fixture.frameIDs.reversed()
            )
            let reversedCoverage = try MemorySegmentModalityCoverage(
                modality: .ocr,
                segmentFrameCount: fixture.frameIDs.count,
                coveredFrameIDs: fixture.frameIDs.reversed(),
                provenance: [reversedSource]
            )
            _ = try MemorySegment(
                scope: fixture.scope,
                frameIDs: fixture.frameIDs,
                representativeEvidence: [representative],
                modalityCoverage: [reversedCoverage],
                containsSensitive: false
            )
        }
    }

    @Test("Cursor is bound to normalized scope and immutable index revision")
    func cursorBindingAndOmissionSafePaging() throws {
        let fixture = try Self.fixture()
        let segment = try Self.segment(fixture: fixture, snippet: "Cursor evidence")
        let baseRequest = try MemorySegmentRequest(
            text: "  quarterly\nreview ",
            scope: fixture.scope,
            retrievalModalities: [.visualAppearance, .savedText],
            limit: 10_000
        )
        #expect(baseRequest.text == "quarterly review")
        #expect(baseRequest.limit == MemorySegmentSchema.maximumPageLimit)
        #expect(baseRequest.retrievalModalities == [.savedText, .visualAppearance])

        let revision = MemorySegmentIndexRevision.derived(from: [segment.revisionID])
        let cursor = try MemorySegmentCursor(
            token: "next-1",
            scopeFingerprint: baseRequest.cursorScopeFingerprint,
            revision: revision
        )
        let continuation = try MemorySegmentRequest(
            text: "quarterly review",
            scope: fixture.scope,
            retrievalModalities: [.savedText, .visualAppearance],
            after: cursor,
            limit: 20
        )
        #expect(continuation.after == cursor)

        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentRequest(
                text: "different query",
                scope: fixture.scope,
                after: cursor
            )
        }

        let emptyContinuingPage = try MemorySegmentPage(
            accessBoundary: .agentSafe,
            scopeFingerprint: baseRequest.cursorScopeFingerprint,
            revision: revision,
            segments: [],
            nextCursor: cursor,
            hasMore: true,
            omissions: [.init(reason: .policyFiltered)]
        )
        #expect(emptyContinuingPage.segments.isEmpty)
        #expect(emptyContinuingPage.hasMore)
        #expect(!emptyContinuingPage.isComplete)

        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentPage(
                accessBoundary: .agentSafe,
                scopeFingerprint: baseRequest.cursorScopeFingerprint,
                revision: revision,
                segments: [],
                nextCursor: nil,
                hasMore: true
            )
        }
    }

    @Test("Agent-safe pages reject sensitive lineage and private omission counts")
    func agentBoundaryFailsClosed() throws {
        let fixture = try Self.fixture()
        let sensitive = try Self.segment(
            fixture: fixture,
            snippet: "Private",
            containsSensitive: true
        )
        let revision = MemorySegmentIndexRevision.derived(from: [sensitive.revisionID])
        let request = try MemorySegmentRequest(scope: fixture.scope)

        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentPage(
                accessBoundary: .agentSafe,
                scopeFingerprint: request.cursorScopeFingerprint,
                revision: revision,
                segments: [sensitive],
                nextCursor: nil,
                hasMore: false
            )
        }
        #expect(throws: MemorySegmentValidationError.self) {
            try MemorySegmentPage(
                accessBoundary: .agentSafe,
                scopeFingerprint: request.cursorScopeFingerprint,
                revision: revision,
                segments: [],
                nextCursor: nil,
                hasMore: false,
                omissions: [.init(reason: .policyFiltered, count: 1)]
            )
        }

        let privatePage = try MemorySegmentPage(
            accessBoundary: .privateLocal,
            scopeFingerprint: request.cursorScopeFingerprint,
            revision: revision,
            segments: [sensitive],
            nextCursor: nil,
            hasMore: false
        )
        #expect(privatePage.segments == [sensitive])
    }

    private struct Fixture {
        let start: Date
        let scope: MemorySegmentScope
        let frameIDs: [FrameID]
    }

    private static func fixture() throws -> Fixture {
        let start = Date(timeIntervalSince1970: 20_000)
        return try Fixture(
            start: start,
            scope: MemorySegmentScope(
                startDate: start,
                endDate: start.addingTimeInterval(60),
                applicationBundleIdentifiers: ["app.notes"],
                domains: ["example.com"],
                activitySessionIDs: [ActivitySessionID(rawValue: "session-1")]
            ),
            frameIDs: ["frame-1", "frame-2", "frame-3"].map(FrameID.init(rawValue:))
        )
    }

    private static func representative(
        frameID: FrameID,
        capturedAt: Date,
        snippet: String
    ) throws -> MemorySegmentRepresentativeEvidence {
        try MemorySegmentRepresentativeEvidence(
            frameID: frameID,
            capturedAt: capturedAt,
            applicationName: "Notes",
            bundleIdentifier: "app.notes",
            domain: "EXAMPLE.COM",
            activitySessionID: ActivitySessionID(rawValue: "session-1"),
            snippet: snippet,
            modalities: [.visualSimilarity, .ocr, .ocr]
        )
    }

    private static func coverage(
        frameIDs: [FrameID]
    ) throws -> [MemorySegmentModalityCoverage] {
        let ocrSource = try MemorySegmentModalityProvenance(
            producerIdentifier: "vision.ocr",
            producerRevision: "2",
            artifactFingerprint: "ocr-pack-a",
            frameIDs: frameIDs
        )
        let visualSource = try MemorySegmentModalityProvenance(
            producerIdentifier: "clip",
            producerRevision: "1",
            artifactFingerprint: "model-a",
            frameIDs: [frameIDs[1]]
        )
        return [
            try MemorySegmentModalityCoverage(
                modality: .visualSimilarity,
                segmentFrameCount: frameIDs.count,
                coveredFrameIDs: [frameIDs[1]],
                provenance: [visualSource]
            ),
            try MemorySegmentModalityCoverage(
                modality: .ocr,
                segmentFrameCount: frameIDs.count,
                coveredFrameIDs: frameIDs,
                provenance: [ocrSource]
            ),
        ]
    }

    private static func segment(
        fixture: Fixture,
        snippet: String,
        containsSensitive: Bool = false
    ) throws -> MemorySegment {
        try MemorySegment(
            scope: fixture.scope,
            frameIDs: fixture.frameIDs,
            representativeEvidence: [
                try representative(
                    frameID: fixture.frameIDs[1],
                    capturedAt: fixture.start.addingTimeInterval(20),
                    snippet: snippet
                ),
            ],
            modalityCoverage: try coverage(frameIDs: fixture.frameIDs),
            containsSensitive: containsSensitive
        )
    }
}
