import PassageCore
import Foundation
import Testing

@Suite("Agent context bundle v2")
struct AgentContextBundleTests {
    @Test("Chronological runs retain retrieval representatives across app and domain transitions")
    func observedRunsAndRepresentatives() throws {
        let hits = [
            Self.hit(
                id: "a-2",
                at: 20,
                session: "session",
                app: "A",
                bundle: "app.a",
                snippet: "second moment"
            ),
            Self.hit(id: "b", at: 40, session: "session", app: "B", bundle: "app.b"),
            Self.hit(
                id: "a-1",
                at: 10,
                session: "session",
                app: "A",
                bundle: "app.a",
                snippet: "first moment"
            ),
            Self.hit(
                id: "c",
                at: 50,
                session: "session",
                app: "B",
                bundle: "app.b",
                domain: "c.example"
            ),
            Self.hit(
                id: "a-3",
                at: 30,
                session: "session",
                app: "A",
                bundle: "app.a",
                snippet: "third moment"
            ),
        ]

        let bundle = try Self.bundle(hits: hits, limit: 5)

        #expect(bundle.schemaVersion == 2)
        #expect(bundle.sources.map(\.frameID.rawValue) == ["a-1", "a-2", "a-3", "b", "c"])
        #expect(bundle.sources.map(\.retrievalRank) == [3, 1, 5, 2, 4])
        #expect(bundle.sources.compactMap { $0.run?.index } == [1, 1, 1, 2, 3])
        #expect(bundle.sources[0].run?.representativeRetrievalRank == 1)
        #expect(bundle.sources[1].reasons.contains(.observedRunRepresentative))
        #expect(bundle.sources[3].reasons.contains(.observedRunRepresentative))
        #expect(bundle.sources[4].reasons.contains(.observedRunRepresentative))
        #expect(bundle.coverage.observedRunCount == 3)
        #expect(bundle.coverage.disclosedTransitionCount == 2)
    }

    @Test("Diversity representatives outrank redundant high-ranked runs")
    func greedyDiversity() throws {
        let hits = [
            Self.hit(id: "a-top", at: 0, session: "a", app: "A", bundle: "app.a"),
            Self.hit(id: "a-repeat", at: 120, session: "a", app: "A", bundle: "app.a"),
            Self.hit(
                id: "b-diverse",
                at: 240,
                session: "b",
                app: "B",
                bundle: "app.b",
                domain: "b.example"
            ),
            Self.hit(
                id: "c-diverse",
                at: 360,
                session: "c",
                app: "C",
                bundle: "app.c",
                domain: "c.example"
            ),
        ]

        let bundle = try Self.bundle(hits: hits, limit: 3)

        #expect(bundle.sources.map(\.frameID.rawValue) == ["a-top", "b-diverse", "c-diverse"])
        #expect(bundle.sources[1].reasons.contains(.activitySessionDiversity))
        #expect(bundle.sources[1].reasons.contains(.applicationDiversity))
        #expect(bundle.sources[1].reasons.contains(.domainDiversity))
        #expect(bundle.coverage.activitySessionCount == 3)
        #expect(bundle.coverage.disclosedActivitySessionCount == 3)
    }

    @Test("Missing activity sessions never merge otherwise identical captures")
    func missingSessionsDoNotMerge() throws {
        let hits = [
            Self.hit(id: "first", at: 10, session: nil, app: "A", bundle: "app.a"),
            Self.hit(id: "second", at: 20, session: nil, app: "A", bundle: "app.a"),
        ]

        let bundle = try Self.bundle(hits: hits, limit: 2)

        #expect(bundle.sources.compactMap { $0.run?.index } == [1, 2])
        #expect(bundle.coverage.observedRunCount == 2)
        #expect(bundle.coverage.activitySessionCount == 0)
    }

    @Test("Timestamp and diversity ties are deterministic")
    func deterministicTies() throws {
        let hits = [
            Self.hit(
                id: "z", at: 10, session: "same", app: "A", bundle: "app.a", snippet: "z"
            ),
            Self.hit(
                id: "a", at: 10, session: "same", app: "A", bundle: "app.a", snippet: "a"
            ),
            Self.hit(
                id: "m", at: 10, session: "same", app: "A", bundle: "app.a", snippet: "m"
            ),
        ]

        let first = try Self.bundle(hits: hits, limit: 3)
        let second = try Self.bundle(hits: hits, limit: 3)

        #expect(first == second)
        #expect(first.sources.map(\.frameID.rawValue) == ["z", "a", "m"])
        #expect(first.sources.map(\.retrievalRank) == [1, 2, 3])
        let canonicalByteCount = try first.canonicalJSONData().count
        #expect(first.encodedUTF8Bytes == canonicalByteCount)
    }

    @Test("Omission summaries count privacy, selection, and lower-bound window omissions")
    func omissionCounts() throws {
        let hits = [
            Self.hit(
                id: "private",
                at: 0,
                session: "private",
                app: "Passwords",
                bundle: "app.passwords",
                sensitive: true
            ),
            Self.hit(
                id: "one", at: 10, session: "work", app: "A", bundle: "app.a", snippet: "one"
            ),
            Self.hit(
                id: "two", at: 20, session: "work", app: "A", bundle: "app.a", snippet: "two"
            ),
            Self.hit(
                id: "three", at: 30, session: "work", app: "A", bundle: "app.a", snippet: "three"
            ),
        ]

        let bundle = try Self.bundle(
            hits: hits,
            limit: 2,
            hasMoreCandidates: true
        )
        let omissions = Dictionary(uniqueKeysWithValues: bundle.omissions.map {
            ($0.reason, $0)
        })

        #expect(bundle.candidateCount == 4)
        #expect(bundle.matchedCount == 4)
        #expect(bundle.sources.count == 2)
        #expect(omissions[.sensitiveContext]?.count == 1)
        #expect(omissions[.resultLimit]?.count == 1)
        #expect(omissions[.candidateWindow]?.count == 1)
        #expect(omissions[.candidateWindow]?.countIsLowerBound == true)
        #expect(bundle.truncated)
    }

    @Test("Temporal duplicates are suppressed before selection and counted exactly")
    func temporalDuplicateSuppressionAndCounts() throws {
        let hits = [
            Self.hit(
                id: "best",
                at: 10,
                session: "work",
                app: "Notes",
                bundle: "app.notes",
                title: "Release plan",
                snippet: "same evidence"
            ),
            Self.hit(
                id: "duplicate",
                at: 12,
                session: "work",
                app: "Notes",
                bundle: "app.notes",
                title: "Release plan",
                snippet: "  same\n evidence  "
            ),
            Self.hit(
                id: "private-duplicate",
                at: 12.5,
                session: "work",
                app: "Notes",
                bundle: "app.notes",
                title: "Release plan",
                snippet: "same evidence",
                sensitive: true
            ),
            Self.hit(
                id: "distinct",
                at: 13,
                session: "work",
                app: "Notes",
                bundle: "app.notes",
                title: "Release plan",
                snippet: "same evidence!"
            ),
        ]

        let bundle = try Self.bundle(hits: hits, limit: 3)

        #expect(bundle.candidateCount == 4)
        #expect(bundle.matchedCount == 4)
        #expect(bundle.sources.map(\.frameID.rawValue) == ["best", "distinct"])
        #expect(bundle.sources.allSatisfy { $0.run?.candidateCount == 3 })
        #expect(bundle.coverage.observedRunCount == 1)
        #expect(bundle.omissions == [
            PassageContextOmissionSummary(reason: .sensitiveContext, count: 1),
            PassageContextOmissionSummary(reason: .temporalDuplicate, count: 1),
        ])
    }

    @Test("Temporal suppression has a strict time boundary")
    func temporalDuplicateTimeBoundary() throws {
        let hits = [
            Self.hit(
                id: "near-best",
                at: 10,
                session: "near",
                app: "Notes",
                bundle: "app.notes",
                snippet: "stable"
            ),
            Self.hit(
                id: "near-duplicate",
                at: 24.999,
                session: "near",
                app: "Notes",
                bundle: "app.notes",
                snippet: "stable"
            ),
            Self.hit(
                id: "boundary-first",
                at: 100,
                session: "boundary",
                app: "Notes",
                bundle: "app.notes",
                snippet: "stable"
            ),
            Self.hit(
                id: "boundary-second",
                at: 115,
                session: "boundary",
                app: "Notes",
                bundle: "app.notes",
                snippet: "stable"
            ),
        ]

        let bundle = try Self.bundle(hits: hits, limit: 4)

        #expect(bundle.sources.map(\.frameID.rawValue) == [
            "near-best", "boundary-first", "boundary-second",
        ])
        #expect(bundle.omissions.first { $0.reason == .temporalDuplicate }?.count == 1)
        #expect(bundle.omissions.allSatisfy { $0.reason != .resultLimit })
    }

    @Test("App, domain, session, locator, and snippet transitions remain distinct")
    func temporalDuplicateIdentityBoundaries() throws {
        let hits = [
            Self.hit(
                id: "app-a-before",
                at: 0,
                session: "work",
                app: "A",
                bundle: "app.a",
                domain: "one.example",
                url: "https://one.example/a",
                title: "One",
                snippet: "evidence"
            ),
            Self.hit(
                id: "app-b",
                at: 1,
                session: "work",
                app: "B",
                bundle: "app.b",
                domain: "one.example",
                url: "https://one.example/a",
                title: "One",
                snippet: "evidence"
            ),
            Self.hit(
                id: "app-a-after",
                at: 2,
                session: "work",
                app: "A",
                bundle: "app.a",
                domain: "one.example",
                url: "https://one.example/a",
                title: "One",
                snippet: "evidence"
            ),
            Self.hit(
                id: "domain-transition",
                at: 3,
                session: "work",
                app: "A",
                bundle: "app.a",
                domain: "two.example",
                url: "https://two.example/a",
                title: "One",
                snippet: "evidence"
            ),
            Self.hit(
                id: "session-transition",
                at: 4,
                session: "other",
                app: "A",
                bundle: "app.a",
                domain: "two.example",
                url: "https://two.example/a",
                title: "One",
                snippet: "evidence"
            ),
            Self.hit(
                id: "title-transition",
                at: 5,
                session: "other",
                app: "A",
                bundle: "app.a",
                domain: "two.example",
                url: "https://two.example/a",
                title: "Two",
                snippet: "evidence"
            ),
            Self.hit(
                id: "url-transition",
                at: 6,
                session: "other",
                app: "A",
                bundle: "app.a",
                domain: "two.example",
                url: "https://two.example/a?view=two",
                title: "Two",
                snippet: "evidence"
            ),
            Self.hit(
                id: "snippet-transition",
                at: 7,
                session: "other",
                app: "A",
                bundle: "app.a",
                domain: "two.example",
                url: "https://two.example/a?view=two",
                title: "Two",
                snippet: "meaningfully different evidence"
            ),
        ]

        let bundle = try Self.bundle(hits: hits, limit: hits.count)

        #expect(bundle.sources.map(\.frameID.rawValue) == hits.map(\.id.rawValue))
        #expect(!bundle.omissions.contains { $0.reason == .temporalDuplicate })
        #expect(bundle.coverage.observedRunCount == 5)
        #expect(bundle.coverage.disclosedObservedRunCount == 5)
    }

    @Test("Duplicate suppression is rank-stable, chronological, and byte-exact")
    func temporalDuplicateDeterminismAndBudget() throws {
        let repeated = String(repeating: "👩🏽‍💻 evidence ", count: 160)
        let hits = [
            Self.hit(
                id: "ranked-best",
                at: 12,
                session: "same",
                app: "A",
                bundle: "app.a",
                snippet: repeated
            ),
            Self.hit(
                id: "earlier-duplicate",
                at: 10,
                session: "same",
                app: "A",
                bundle: "app.a",
                snippet: repeated
            ),
            Self.hit(
                id: "later-duplicate",
                at: 14,
                session: "same",
                app: "A",
                bundle: "app.a",
                snippet: repeated
            ),
            Self.hit(
                id: "compact",
                at: 20,
                session: "compact",
                app: "B",
                bundle: "app.b",
                snippet: "compact evidence"
            ),
        ]

        let first = try Self.bundle(hits: hits, limit: 2, budget: 2_048)
        let second = try Self.bundle(hits: hits, limit: 2, budget: 2_048)

        #expect(first == second)
        #expect(try first.canonicalJSONData() == second.canonicalJSONData())
        #expect(first.sources.map(\.frameID.rawValue) == ["ranked-best", "compact"])
        #expect(first.sources.first?.snippetTruncated == true)
        #expect(first.omissions.first { $0.reason == .temporalDuplicate }?.count == 2)
        #expect(first.omissions.allSatisfy { $0.reason != .resultLimit })
        #expect(first.encodedUTF8Bytes == (try first.canonicalJSONData()).count)
        #expect(first.encodedUTF8Bytes <= first.utf8ByteBudget)
    }

    @Test("An oversized metadata shell does not starve a later compact source")
    func skipsOversizedMetadataShell() throws {
        let hits = [
            Self.hit(
                id: "oversized",
                at: 10,
                session: "work",
                app: "A",
                bundle: "app.a",
                title: String(repeating: "metadata", count: 4_000)
            ),
            Self.hit(
                id: "compact",
                at: 20,
                session: "work",
                app: "A",
                bundle: "app.a",
                snippet: "compact evidence"
            ),
        ]

        let bundle = try Self.bundle(hits: hits, limit: 2, budget: 2_048)

        #expect(bundle.sources.map(\.frameID.rawValue) == ["compact"])
        #expect(bundle.omissions.first { $0.reason == .byteBudget }?.count == 1)
        #expect(bundle.encodedUTF8Bytes <= bundle.utf8ByteBudget)
    }

    @Test("Unicode snippet fitting is grapheme-safe, maximal, and byte-exact")
    func unicodeBudgetIsExact() throws {
        let grapheme = "👩🏽‍💻"
        let original = String(repeating: grapheme, count: 300)
        let hit = Self.hit(
            id: "unicode",
            at: 10,
            session: "work",
            app: "A",
            bundle: "app.a",
            snippet: original
        )

        let bundle = try Self.bundle(hits: [hit], limit: 1, budget: 1_600)
        let source = try #require(bundle.sources.first)

        #expect(source.snippetTruncated)
        #expect(!source.ocrSnippet.isEmpty)
        #expect(original.hasPrefix(source.ocrSnippet))
        #expect(source.ocrSnippet.allSatisfy { String($0) == grapheme })
        let canonicalByteCount = try bundle.canonicalJSONData().count
        #expect(bundle.encodedUTF8Bytes == canonicalByteCount)
        #expect(bundle.encodedUTF8Bytes <= bundle.utf8ByteBudget)

        var oneMore = bundle
        oneMore.sources[0].ocrSnippet.append(grapheme)
        let oneMoreBytes = try Self.stabilizedByteCount(oneMore)
        #expect(oneMoreBytes > bundle.utf8ByteBudget)
    }

    @Test("Explicit candidate-window continuation makes coverage a lower bound")
    func candidateWindowLowerBound() throws {
        let hit = Self.hit(id: "only-observed", at: 10, session: "work", app: "A", bundle: "app.a")

        let bundle = try Self.bundle(
            hits: [hit],
            limit: 3,
            hasMoreCandidates: true
        )

        #expect(bundle.candidateCount == 1)
        #expect(bundle.hasMoreCandidates)
        #expect(bundle.coverage.isLowerBound)
        #expect(bundle.omissions == [PassageContextOmissionSummary(
            reason: .candidateWindow,
            count: 1,
            countIsLowerBound: true
        )])
    }

    @Test("Source URLs retain provenance without credentials, queries, or local paths")
    func sanitizedSourceURLs() throws {
        let bundle = try Self.bundle(hits: [
            Self.hit(
                id: "web",
                at: 10,
                session: "work",
                app: "Safari",
                bundle: "com.apple.Safari",
                domain: "example.com",
                url: "https://alice:secret@example.com/board?token=private#selection"
            ),
            Self.hit(
                id: "local-path",
                at: 20,
                session: "work",
                app: "Preview",
                bundle: "com.apple.Preview",
                url: "file:///Users/person/private.pdf"
            ),
        ], limit: 2)

        #expect(bundle.sources.first { $0.frameID.rawValue == "web" }?.url
            == "https://example.com/board")
        #expect(bundle.sources.first { $0.frameID.rawValue == "local-path" }?.url == nil)
        let encoded = String(decoding: try bundle.canonicalJSONData(), as: UTF8.self)
        #expect(!encoded.contains("alice"))
        #expect(!encoded.contains("secret"))
        #expect(!encoded.contains("token"))
        #expect(!encoded.contains("/Users/"))
    }

    private static func bundle(
        hits: [SearchHit],
        limit: Int,
        budget: Int = 16_384,
        hasMoreCandidates: Bool? = false
    ) throws -> PassageContextBundleManifest {
        try PassageContextBundleBuilder.build(
            request: PassageContextBundleRequest(
                query: SearchQuery(text: "synthetic"),
                resultLimit: limit,
                utf8ByteBudget: budget
            ),
            hits: hits,
            hasMoreCandidates: hasMoreCandidates
        )
    }

    private static func hit(
        id: String,
        at: TimeInterval,
        session: String?,
        app: String,
        bundle: String?,
        domain: String? = nil,
        url: String? = nil,
        title: String? = nil,
        snippet: String = "evidence",
        sensitive: Bool = false
    ) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            activitySessionID: session.map(ActivitySessionID.init(rawValue:)),
            capturedAt: Date(timeIntervalSince1970: at),
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: title,
                url: url.flatMap(URL.init(string:)),
                domain: domain,
                isSensitive: sensitive
            ),
            snippet: snippet,
            imageRelativePath: "private/media/\(id).jpg",
            score: 1
        )
    }

    private static func stabilizedByteCount(
        _ manifest: PassageContextBundleManifest
    ) throws -> Int {
        var value = manifest
        for _ in 0..<32 {
            let bytes = try value.canonicalJSONData().count
            if value.encodedUTF8Bytes == bytes { return bytes }
            value.encodedUTF8Bytes = bytes
        }
        Issue.record("Canonical byte count did not stabilize")
        return .max
    }
}
