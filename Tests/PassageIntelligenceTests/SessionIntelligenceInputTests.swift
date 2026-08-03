import PassageCore
import Foundation
import Testing

@Suite("Session intelligence text input")
struct SessionIntelligenceInputTests {
    @Test("Bounds source count and keeps the latest evidence chronologically")
    func sourceCountBound() {
        let sources = (0..<30).reversed().map { index in
            SessionIntelligenceSource(
                frameID: FrameID(rawValue: "frame-\(index)"),
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                applicationName: "Editor",
                ocrSnippet: "Text \(index)"
            )
        }

        let input = SessionIntelligenceInput(
            activitySessionID: ActivitySessionID(rawValue: "session-a"),
            sources: sources
        )

        #expect(input.sources.count == SessionIntelligenceInput.maximumSourceCount)
        #expect(input.sources.first?.frameID.rawValue == "frame-10")
        #expect(input.sources.last?.frameID.rawValue == "frame-29")
        #expect(input.sources.map(\.capturedAt) == input.sources.map(\.capturedAt).sorted())
    }

    @Test("Clamps individual and aggregate Unicode text without splitting characters")
    func textBounds() {
        let oversized = String(repeating: "🧭", count: 10_000)
        let sources = (0..<20).map { index in
            SessionIntelligenceSource(
                frameID: FrameID(rawValue: "unicode-\(index)"),
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                applicationName: oversized,
                windowTitle: oversized,
                domain: oversized,
                urlString: oversized,
                ocrSnippet: oversized
            )
        }
        let input = SessionIntelligenceInput(
            activitySessionID: ActivitySessionID(rawValue: "session-unicode"),
            sources: sources
        )

        #expect(input.sources.reduce(0) { $0 + $1.textUTF8ByteCount }
            <= SessionIntelligenceInput.maximumTotalTextUTF8Bytes)
        #expect(input.sources.allSatisfy {
            $0.ocrSnippet.utf8.count <= SessionIntelligenceSource.maximumOCRSnippetUTF8Bytes
                && String(data: Data($0.ocrSnippet.utf8), encoding: .utf8) != nil
        })
    }

    @Test("Fingerprint is order-independent but changes with bounded content")
    func fingerprint() {
        let first = Self.source(id: "first", timestamp: 1, text: "alpha")
        let second = Self.source(id: "second", timestamp: 2, text: "beta")
        let ordered = SessionIntelligenceInput(
            activitySessionID: ActivitySessionID(rawValue: "session-fingerprint"),
            sources: [first, second]
        )
        let reversed = SessionIntelligenceInput(
            activitySessionID: ActivitySessionID(rawValue: "session-fingerprint"),
            sources: [second, first]
        )
        let changed = SessionIntelligenceInput(
            activitySessionID: ActivitySessionID(rawValue: "session-fingerprint"),
            sources: [first, Self.source(id: "second", timestamp: 2, text: "changed")]
        )

        #expect(ordered.contentFingerprint == reversed.contentFingerprint)
        #expect(ordered.contentFingerprint != changed.contentFingerprint)
        #expect(ordered.contentFingerprint.count == 64)
    }

    private static func source(id: String, timestamp: TimeInterval, text: String) -> SessionIntelligenceSource {
        SessionIntelligenceSource(
            frameID: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: timestamp),
            applicationName: "Notes",
            windowTitle: "Draft",
            domain: "example.com",
            urlString: "https://example.com/draft",
            ocrSnippet: text
        )
    }
}
