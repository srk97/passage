import PassageCore
import Foundation
import Testing

@Suite("Bounded session questions")
struct SessionQuestionTests {
    @Test("Normalizes the question and shares one Unicode-safe text budget")
    func normalizationAndSharedBudget() {
        let oversized = String(repeating: "🧭", count: 8_000)
        let input = SessionQuestionInput(
            activitySessionID: .init(rawValue: "session-question"),
            question: "  What\n\n did   I decide?  " + oversized,
            sourcesByPriority: (0..<20).map { index in
                source(id: "frame-\(index)", timestamp: TimeInterval(index), text: oversized)
            },
            provider: "openai-responses",
            model: "gpt-5.6-luna"
        )

        #expect(input.question.hasPrefix("What did I decide?"))
        #expect(input.question.utf8.count <= SessionQuestionInput.maximumQuestionUTF8Bytes)
        #expect(input.totalTextUTF8ByteCount <= SessionQuestionInput.maximumTotalTextUTF8Bytes)
        #expect(String(data: Data(input.question.utf8), encoding: .utf8) != nil)
        #expect(input.sources.allSatisfy {
            String(data: Data($0.ocrSnippet.utf8), encoding: .utf8) != nil
        })
    }

    @Test("Request fingerprint covers question, evidence, provider, model, and schema")
    func requestFingerprintInvalidation() {
        let evidence = [source(id: "frame-a", timestamp: 1, text: "Launch on Friday")]
        let baseline = input(question: "When is launch?", evidence: evidence)
        let same = input(question: "  When   is launch? ", evidence: evidence)
        let newQuestion = input(question: "Who owns launch?", evidence: evidence)
        let newEvidence = input(
            question: "When is launch?",
            evidence: [source(id: "frame-a", timestamp: 1, text: "Launch on Monday")]
        )
        let newModel = SessionQuestionInput(
            activitySessionID: .init(rawValue: "session-question"),
            question: "When is launch?",
            sourcesByPriority: evidence,
            provider: "openai-responses",
            model: "another-model"
        )

        #expect(baseline.requestFingerprint == same.requestFingerprint)
        #expect(baseline.questionFingerprint != newQuestion.questionFingerprint)
        #expect(baseline.requestFingerprint != newQuestion.requestFingerprint)
        #expect(baseline.contentFingerprint != newEvidence.contentFingerprint)
        #expect(baseline.requestFingerprint != newEvidence.requestFingerprint)
        #expect(baseline.requestFingerprint != newModel.requestFingerprint)
        #expect(baseline.requestFingerprint.count == 64)
    }

    @Test("Decoding recomputes fingerprints instead of trusting serialized values")
    func decodingRecomputesFingerprints() throws {
        let original = input(
            question: "What changed?",
            evidence: [source(id: "frame-a", timestamp: 1, text: "Before")]
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object["requestFingerprint"] = String(repeating: "0", count: 64)
        object["questionFingerprint"] = String(repeating: "0", count: 64)
        object["contentFingerprint"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionQuestionInput.self, from: tampered)

        #expect(decoded.requestFingerprint == original.requestFingerprint)
        #expect(decoded.questionFingerprint == original.questionFingerprint)
        #expect(decoded.contentFingerprint == original.contentFingerprint)
    }

    @Test("Search terms cannot carry advanced FTS syntax")
    func safeSearchTerms() {
        let selector = SessionQuestionEvidenceSelector()
        let terms = selector.searchText(
            for: "What did I decide about \"alpha\" OR secret* (NOT beta)—and alpha?"
        )

        #expect(terms == "decide about alpha secret not beta")
        #expect(!terms.contains("\""))
        #expect(!terms.contains("*"))
        #expect(!terms.contains("("))
    }

    @Test("Selector prioritizes relevant matches, deduplicates, and rejects other sessions")
    func deterministicSelection() {
        let target = ActivitySessionID(rawValue: "target")
        let other = ActivitySessionID(rawValue: "other")
        let recent = [
            hit(id: "recent", sessionID: target, timestamp: 30, text: "Recent context"),
            hit(id: "matched", sessionID: target, timestamp: 20, text: "Short recent snippet"),
        ]
        let detail = ActivitySessionDetail(summary: summary(id: target), moments: recent)
        let preparation = SessionQuestionEvidenceSelector().prepare(
            question: "What was the launch decision?",
            session: detail,
            matchedMoments: [
                hit(id: "wrong", sessionID: other, timestamp: 40, text: "Must never escape scope"),
                hit(id: "matched", sessionID: target, timestamp: 20, text: "Launch moves to Friday"),
            ],
            provider: "openai-responses",
            model: "gpt-5.6-luna"
        )

        #expect(preparation.input.sources.map(\.frameID.rawValue) == ["matched", "recent"])
        #expect(preparation.input.sources.first?.ocrSnippet == "Launch moves to Friday")
        #expect(preparation.input.sources.first?.urlString == "https://example.com/plan")
        #expect(!preparation.input.sources.contains { $0.frameID.rawValue == "wrong" })
        #expect(preparation.selectedMomentCount == 2)
        #expect(preparation.evidenceThrough == Date(timeIntervalSince1970: 30))
    }

    @Test("Selector returns no disclosure when no frame proves session membership")
    func failClosedMembership() {
        let target = ActivitySessionID(rawValue: "target")
        let detail = ActivitySessionDetail(
            summary: summary(id: target),
            moments: [hit(id: "nil-member", sessionID: nil, timestamp: 1, text: "Unscoped")]
        )
        let preparation = SessionQuestionEvidenceSelector().prepare(
            question: "What happened?",
            session: detail,
            matchedMoments: [],
            provider: "openai-responses",
            model: "gpt-5.6-luna"
        )

        #expect(preparation.input.sources.isEmpty)
        #expect(preparation.selectedTextUTF8ByteCount == 0)
    }

    @Test("Private disclosure is per-question and preserves the prepared snapshot")
    func privateDisclosurePolicy() {
        var draft = "What did I decide?"
        let preparation = SessionQuestionPreparation(
            input: input(
                question: draft,
                evidence: [source(id: "frame-a", timestamp: 1, text: "Ship Friday")]
            )
        )
        draft = "Send a different question"
        let policy = SessionQuestionDisclosurePolicy()

        #expect(policy.decision(
            for: preparation,
            sessionContainsSensitiveHistory: false
        ) == .submit)
        #expect(policy.decision(
            for: preparation,
            sessionContainsSensitiveHistory: true
        ) == .requirePrivateConfirmation)
        #expect(preparation.input.question == "What did I decide?")
        #expect(preparation.input.question != draft)
    }

    private func input(
        question: String,
        evidence: [SessionIntelligenceSource]
    ) -> SessionQuestionInput {
        SessionQuestionInput(
            activitySessionID: .init(rawValue: "session-question"),
            question: question,
            sourcesByPriority: evidence,
            provider: "openai-responses",
            model: "gpt-5.6-luna"
        )
    }

    private func source(
        id: String,
        timestamp: TimeInterval,
        text: String
    ) -> SessionIntelligenceSource {
        SessionIntelligenceSource(
            frameID: .init(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: timestamp),
            applicationName: "Notes",
            windowTitle: "Launch plan",
            ocrSnippet: text
        )
    }

    private func hit(
        id: String,
        sessionID: ActivitySessionID?,
        timestamp: TimeInterval,
        text: String
    ) -> SearchHit {
        SearchHit(
            id: .init(rawValue: id),
            activitySessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: timestamp),
            context: ScreenContext(
                applicationName: "Notes",
                windowTitle: "Launch plan",
                url: URL(string: "https://user:password@example.com/plan?token=secret#draft"),
                domain: "example.com"
            ),
            snippet: text,
            imageRelativePath: "never-sent.enc",
            score: 0
        )
    }

    private func summary(id: ActivitySessionID) -> ActivitySessionSummary {
        ActivitySessionSummary(
            id: id,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 40),
            frameCount: 2,
            title: "Launch plan",
            latestApplicationName: "Notes",
            representativeFrameID: .init(rawValue: "recent"),
            latestFrameID: .init(rawValue: "recent"),
            latestSnippet: "Recent context",
            resumeTarget: ActivityResumeTarget(applicationName: "Notes")
        )
    }
}
