import PassageCore
import PassageService
import Foundation
import Testing

@Suite("Passage service framing and messages")
struct PassageServiceFramingTests {
    private let client = PassageServiceClientIdentity(
        identifier: "app.passage.tests",
        displayName: "Passage Tests",
        version: "1.0"
    )

    @Test("The public wire protocol advertises visual search and Memory Capsules")
    func protocolVersion() {
        #expect(PassageServiceProtocol.currentVersion == 5)
        #expect(PassageServiceProtocol.serviceVersion == "0.9.0")
        #expect(PassageServiceCapabilities.current.capabilities.contains(.sessions))
        #expect(PassageServiceCapabilities.current.capabilities.contains(.visualSearch))
        #expect(PassageServiceCapabilities.current.visualSearchSchemaVersion == 1)
        #expect(PassageServiceCapabilities.current.visualSearchDisclosureModes == [.metadataOnly])
        #expect(PassageServiceCapabilities.current.defaultVisualSearchResultLimit == 6)
        #expect(PassageServiceCapabilities.current.maximumVisualSearchResultLimit == 20)
        #expect(PassageServiceCapabilities.current.maximumVisualSearchDescriptionUTF8Bytes == 4 * 1_024)
        #expect(PassageServiceCapabilities.current.minimumVisualSearchUTF8ByteBudget == 1_024)
        #expect(PassageServiceCapabilities.current.defaultVisualSearchUTF8ByteBudget == 64 * 1_024)
        #expect(PassageServiceCapabilities.current.maximumVisualSearchUTF8ByteBudget == 256 * 1_024)
        #expect(PassageServiceCapabilities.current.capabilities.contains(.memoryCapsule))
        #expect(PassageServiceCapabilities.current.memoryCapsuleSchemaVersion == 1)
        #expect(PassageServiceCapabilities.current.memoryCapsuleRetrievalModalities == [.savedText, .visualAppearance])
        #expect(PassageServiceCapabilities.current.memoryCapsuleDisclosureModes == [.structuredEvidence])
        #expect(PassageServiceCapabilities.current.defaultMemoryCapsuleResultLimit == 8)
        #expect(PassageServiceCapabilities.current.maximumMemoryCapsuleResultLimit == 24)
        #expect(PassageServiceCapabilities.current.minimumMemoryCapsuleUTF8ByteBudget == 2 * 1_024)
        #expect(PassageServiceCapabilities.current.defaultMemoryCapsuleUTF8ByteBudget == 64 * 1_024)
        #expect(PassageServiceCapabilities.current.maximumMemoryCapsuleUTF8ByteBudget == 512 * 1_024)
    }

    @Test("Frames use an unsigned four-byte big-endian length")
    func bigEndianLengthPrefix() throws {
        let payload = Data(repeating: 0x5a, count: 258)
        let frame = try PassageServiceFraming.frame(
            payload: payload,
            maximumPayloadBytes: 1_024,
            direction: .request
        )

        #expect(Array(frame.prefix(4)) == [0x00, 0x00, 0x01, 0x02])
        #expect(frame.dropFirst(4) == payload)
        #expect(try PassageServiceFraming.payloadLength(
            from: frame.prefix(4),
            maximumPayloadBytes: 1_024,
            direction: .request
        ) == 258)
    }

    @Test("Empty and oversized payloads fail before allocation or I/O")
    func rejectsInvalidLengths() {
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceFraming.frame(
                payload: Data(),
                maximumPayloadBytes: 10,
                direction: .request
            )
        }
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceFraming.frame(
                payload: Data(repeating: 1, count: 11),
                maximumPayloadBytes: 10,
                direction: .request
            )
        }
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceFraming.payloadLength(
                from: Data([0, 0, 1, 0]),
                maximumPayloadBytes: 255,
                direction: .response
            )
        }
    }

    @Test("Codable request and every response result round trip")
    func typedMessageRoundTrips() throws {
        let codec = PassageServiceJSONCodec()
        let request = PassageServiceRequest.search(
            SearchQuery(
                text: "project aurora",
                startDate: Date(timeIntervalSince1970: 1_000),
                endDate: Date(timeIntervalSince1970: 2_000),
                applicationBundleIdentifiers: ["com.apple.Safari"],
                domains: ["example.com"],
                activitySessionIDs: [ActivitySessionID(rawValue: "session-frame-1")],
                limit: 25
            ),
            client: client,
            requestID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let decodedRequest = try codec.decode(
            PassageServiceRequest.self,
            from: codec.encode(request)
        )
        #expect(decodedRequest == request)
        try decodedRequest.validate()

        let frame = FrameDocument(
            id: FrameID(rawValue: "frame-1"),
            capturedAt: Date(timeIntervalSince1970: 1_500),
            context: ScreenContext(applicationName: "Safari", domain: "example.com"),
            ocrText: "Project Aurora",
            imageRelativePath: "Media/frame-1.jpg",
            pixelWidth: 1_440,
            pixelHeight: 900,
            visualFingerprint: 42,
            changeScore: 0.75
        )
        let hit = SearchHit(
            id: frame.id,
            capturedAt: frame.capturedAt,
            context: frame.context,
            snippet: frame.ocrText,
            imageRelativePath: frame.imageRelativePath,
            score: 1
        )
        let statistics = StoreStatistics(
            frameCount: 1,
            oldestCapture: frame.capturedAt,
            newestCapture: frame.capturedAt,
            databaseBytes: 100,
            mediaBytes: 200
        )
        let session = Self.session(id: "session-frame-1")
        let sessionRequest = PassageServiceRequest.sessions(
            ActivitySessionQuery(
                startDate: Date(timeIntervalSince1970: 1_000),
                endDate: Date(timeIntervalSince1970: 2_000),
                limit: 20,
                includeSensitive: false
            ),
            client: client
        )
        let decodedSessionRequest = try codec.decode(
            PassageServiceRequest.self,
            from: codec.encode(sessionRequest)
        )
        #expect(decodedSessionRequest == sessionRequest)
        try decodedSessionRequest.validate()
        let visualRequest = PassageServiceRequest.visualSearch(
            PassageAgentVisualSearchRequest(
                description: "a planning board",
                scope: RecallScope(domains: ["example.com"]),
                resultLimit: 2,
                utf8ByteBudget: 4_096
            ),
            client: client,
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let decodedVisualRequest = try codec.decode(
            PassageServiceRequest.self,
            from: codec.encode(visualRequest)
        )
        #expect(decodedVisualRequest == visualRequest)
        try decodedVisualRequest.validate()
        let encodedVisualRequest = try #require(
            String(data: codec.encode(visualRequest), encoding: .utf8)
        )
        #expect(!encodedVisualRequest.contains("activitySession"))
        let capsuleRequest = PassageServiceRequest.memoryCapsule(
            PassageMemoryCapsuleRequest(
                query: SearchQuery(
                    text: "a planning board",
                    domains: ["example.com"],
                    activitySessionIDs: [ActivitySessionID(rawValue: "session-frame-1")],
                    limit: 2
                ),
                resultLimit: 2,
                utf8ByteBudget: 4_096
            ),
            client: client,
            requestID: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!
        )
        let decodedCapsuleRequest = try codec.decode(
            PassageServiceRequest.self,
            from: codec.encode(capsuleRequest)
        )
        #expect(decodedCapsuleRequest == capsuleRequest)
        try decodedCapsuleRequest.validate()
        let capsule = try PassageMemoryCapsuleBuilder.build(
            request: try #require(capsuleRequest.memoryCapsuleRequest),
            candidates: [PassageMemoryCapsuleCandidate(
                hit: hit,
                ocrText: "Project Aurora",
                accessibility: [
                    .init(role: "AXStaticText", label: "Project Aurora", depth: 1)
                ],
                savedTextRank: 1
            )]
        )
        let results: [PassageServiceResult] = [
            .capabilities(.current),
            .health(.ready),
            .bundle(try PassageContextBundleBuilder.build(
                request: PassageContextBundleRequest(
                    query: SearchQuery(text: "Aurora", limit: 1),
                    resultLimit: 1,
                    utf8ByteBudget: 4_096
                ),
                hits: [hit]
            )),
            .visualSearch(try Self.visualManifest()),
            .memoryCapsule(capsule),
            .search([hit]),
            .recent([hit]),
            .sessions([session]),
            .frame(frame),
            .frame(nil),
            .statistics(statistics),
        ]

        for result in results {
            let response = PassageServiceResponse.success(
                requestID: request.requestID,
                result: result
            )
            let decoded = try codec.decode(
                PassageServiceResponse.self,
                from: codec.encode(response)
            )
            #expect(decoded == response)
        }

        let visualResult = PassageServiceResult.visualSearch(try Self.visualManifest())
        var mixedObject = try #require(
            JSONSerialization.jsonObject(with: codec.encode(visualResult)) as? [String: Any]
        )
        mixedObject["hits"] = []
        let mixedData = try JSONSerialization.data(withJSONObject: mixedObject)
        #expect(throws: PassageServiceTransportError.self) {
            try codec.decode(PassageServiceResult.self, from: mixedData)
        }
    }

    @Test("Context bundles preserve source order and enforce their exact canonical byte budget")
    func contextBundleOrderingAndBudget() throws {
        let hits = [
            Self.hit(id: "ranked-first", snippet: String(repeating: "🧭", count: 300)),
            Self.hit(id: "ranked-second", snippet: "second source"),
            Self.hit(id: "look-ahead", snippet: "not disclosed past the result cap"),
        ]
        let request = PassageContextBundleRequest(
            query: SearchQuery(text: "project"),
            resultLimit: 2,
            utf8ByteBudget: 2_048
        )

        let first = try PassageContextBundleBuilder.build(request: request, hits: hits)
        let second = try PassageContextBundleBuilder.build(request: request, hits: hits)

        #expect(first == second)
        #expect(first.sources.map(\.frameID.rawValue).first == "ranked-first")
        #expect(first.requestedCount == 2)
        #expect(first.matchedCount == 3)
        #expect(first.disclosedCount <= 2)
        #expect(first.truncated)
        let firstCanonicalByteCount = try first.canonicalJSONData().count
        #expect(first.encodedUTF8Bytes == firstCanonicalByteCount)
        #expect(first.encodedUTF8Bytes <= request.utf8ByteBudget)
    }

    @Test("Bundle truncation stays Unicode-safe and sensitive contexts are omitted")
    func unicodeAndSensitiveDisclosure() throws {
        let sensitive = SearchHit(
            id: FrameID(rawValue: "sensitive"),
            capturedAt: Date(timeIntervalSince1970: 10),
            context: ScreenContext(applicationName: "Passwords", isSensitive: true),
            snippet: "secret",
            imageRelativePath: "Media/sensitive.jpg",
            score: 2
        )
        let visible = Self.hit(
            id: "visible",
            snippet: String(repeating: "👩🏽‍💻", count: 500)
        )
        let request = PassageContextBundleRequest(
            query: SearchQuery(text: "work"),
            resultLimit: 2,
            utf8ByteBudget: PassageContextBundleSchema.minimumUTF8ByteBudget
        )

        let bundle = try PassageContextBundleBuilder.build(
            request: request,
            hits: [sensitive, visible]
        )

        #expect(bundle.matchedCount == 2)
        #expect(bundle.sources.map(\.frameID.rawValue) == ["visible"])
        #expect(bundle.sources[0].snippetTruncated)
        #expect(bundle.sources[0].ocrSnippet.utf8.count < visible.snippet.utf8.count)
        #expect(bundle.truncated)
        let canonicalByteCount = try bundle.canonicalJSONData().count
        #expect(bundle.encodedUTF8Bytes == canonicalByteCount)
        #expect(bundle.encodedUTF8Bytes <= request.utf8ByteBudget)
    }

    @Test("Request validation rejects mismatched payloads and protocol versions")
    func validatesUntrustedRequests() {
        let mismatched = PassageServiceRequest(
            client: client,
            capability: .statistics,
            recentLimit: 10
        )
        #expect(throws: PassageServiceTransportError.self) {
            try mismatched.validate()
        }

        let future = PassageServiceRequest(
            protocolVersion: PassageServiceProtocol.currentVersion + 1,
            client: client,
            capability: .statistics
        )
        #expect(throws: PassageServiceTransportError.self) {
            try future.validate()
        }

        let unboundedBundle = PassageServiceRequest.bundle(
            PassageContextBundleRequest(
                query: SearchQuery(text: "too broad"),
                resultLimit: PassageContextBundleSchema.maximumResultLimit + 1,
                utf8ByteBudget: PassageContextBundleSchema.maximumUTF8ByteBudget + 1
            ),
            client: client
        )
        #expect(throws: PassageServiceTransportError.self) {
            try unboundedBundle.validate()
        }

        var unboundedSessions = ActivitySessionQuery(includeSensitive: false)
        unboundedSessions.limit = 101
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.sessions(
                unboundedSessions,
                client: client
            ).validate()
        }

        let mixedSessionPayload = PassageServiceRequest(
            client: client,
            capability: .sessions,
            recentLimit: 5,
            activitySessionQuery: ActivitySessionQuery(includeSensitive: false)
        )
        #expect(throws: PassageServiceTransportError.self) {
            try mixedSessionPayload.validate()
        }

        let visualRequest = PassageAgentVisualSearchRequest(description: "a chart")
        let mixedVisualPayload = PassageServiceRequest(
            client: client,
            capability: .visualSearch,
            searchQuery: SearchQuery(text: "chart"),
            visualSearchRequest: visualRequest
        )
        #expect(throws: PassageServiceTransportError.self) {
            try mixedVisualPayload.validate()
        }

        let mixedCapsulePayload = PassageServiceRequest(
            client: client,
            capability: .memoryCapsule,
            searchQuery: SearchQuery(text: "chart"),
            memoryCapsuleRequest: PassageMemoryCapsuleRequest(
                query: SearchQuery(text: "chart")
            )
        )
        #expect(throws: PassageServiceTransportError.self) {
            try mixedCapsulePayload.validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.memoryCapsule(
                PassageMemoryCapsuleRequest(query: SearchQuery(text: "   ")),
                client: client
            ).validate()
        }

        for malformedFilter in ["", "   ", " example.com", "example.com\n", "x; disclosed=0"] {
            #expect(throws: PassageServiceTransportError.self) {
                try PassageServiceRequest.memoryCapsule(
                    PassageMemoryCapsuleRequest(query: SearchQuery(
                        text: "chart",
                        domains: [malformedFilter]
                    )),
                    client: client
                ).validate()
            }
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.memoryCapsule(
                PassageMemoryCapsuleRequest(query: SearchQuery(
                    text: "chart",
                    applicationBundleIdentifiers: ["   "]
                )),
                client: client
            ).validate()
        }

        var malformedVisualScope = RecallScope()
        malformedVisualScope.domains = ["   "]
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    scope: malformedVisualScope
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.memoryCapsule(
                PassageMemoryCapsuleRequest(
                    query: SearchQuery(text: "chart"),
                    retrievalModalities: [.savedText, .savedText]
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.memoryCapsule(
                PassageMemoryCapsuleRequest(
                    query: SearchQuery(text: "chart"),
                    resultLimit: PassageMemoryCapsuleSchema.maximumResultLimit + 1
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.memoryCapsule(
                PassageMemoryCapsuleRequest(
                    query: SearchQuery(text: "chart"),
                    utf8ByteBudget: PassageMemoryCapsuleSchema.minimumUTF8ByteBudget - 1
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(description: "   "),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: String(repeating: "x", count: 4 * 1_024 + 1)
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    scope: RecallScope(text: "ignored lexical filter")
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    resultLimit: PassageAgentVisualSearchSchema.maximumResultLimit + 1
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    utf8ByteBudget: PassageAgentVisualSearchSchema.minimumUTF8ByteBudget - 1
                ),
                client: client
            ).validate()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    scope: RecallScope(
                        startDate: Date(timeIntervalSince1970: 2),
                        endDate: Date(timeIntervalSince1970: 1)
                    )
                ),
                client: client
            ).validate()
        }

        var tooManyDomains = RecallScope()
        tooManyDomains.domains = Set((0...100).map { "\($0).example.com" })
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    scope: tooManyDomains
                ),
                client: client
            ).validate()
        }

        var tooManyApplications = RecallScope()
        tooManyApplications.applicationBundleIdentifiers = Set((0...100).map { "app.\($0)" })
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.visualSearch(
                PassageAgentVisualSearchRequest(
                    description: "a chart",
                    scope: tooManyApplications
                ),
                client: client
            ).validate()
        }

        var tooManySessionFilters = SearchQuery(text: "project")
        tooManySessionFilters.activitySessionIDs = Set((0...100).map {
            ActivitySessionID(rawValue: "session-\($0)")
        })
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.search(
                tooManySessionFilters,
                client: client
            ).validate()
        }

        var emptySessionFilter = SearchQuery(text: "project")
        emptySessionFilter.activitySessionIDs = [ActivitySessionID(rawValue: "")]
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceRequest.search(
                emptySessionFilter,
                client: client
            ).validate()
        }
    }

    @Test("Socket paths are bounded by sockaddr_un")
    func validatesSocketPaths() {
        let longName = String(repeating: "x", count: PassageServiceEndpoint.maximumPathBytes + 1)
        #expect(throws: PassageServiceTransportError.self) {
            try PassageServiceEndpoint(socketURL: URL(fileURLWithPath: "/\(longName)"))
        }
    }

    private static func hit(id: String, snippet: String) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: 1_234),
            context: ScreenContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                windowTitle: "Project notes",
                url: URL(string: "https://example.com/project"),
                domain: "example.com"
            ),
            snippet: snippet,
            imageRelativePath: "Media/\(id).jpg",
            score: 1
        )
    }

    private static func session(id: String, containsSensitive: Bool = false) -> ActivitySessionSummary {
        ActivitySessionSummary(
            id: ActivitySessionID(rawValue: id),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_500),
            frameCount: 3,
            title: "Project notes",
            latestApplicationName: "Safari",
            latestBundleIdentifier: "com.apple.Safari",
            latestDomain: "example.com",
            representativeFrameID: FrameID(rawValue: "frame-1"),
            representativeThumbnailRelativePath: "Thumbnails/frame-1.jpg",
            latestFrameID: FrameID(rawValue: "frame-3"),
            latestSnippet: "Project Aurora",
            resumeTarget: ActivityResumeTarget(
                url: URL(string: "https://example.com/project"),
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari"
            ),
            containsSensitive: containsSensitive
        )
    }

    private static func visualManifest() throws -> PassageAgentVisualSearchManifest {
        let model = VisualModelIdentity(
            identifier: "test-model",
            revision: "1",
            fingerprint: "abcdef",
            preprocessingRevision: "test-v1",
            embeddingDimension: 512
        )
        let hit = Self.hit(id: "visual-result", snippet: "Planning board")
        return try PassageAgentVisualSearchBuilder.build(
            request: PassageAgentVisualSearchRequest(
                description: "a planning board",
                resultLimit: 1,
                utf8ByteBudget: 4_096
            ),
            candidates: [VisualEmbeddingMatch(
                hit: hit,
                similarity: 0.4,
                maximumSimilarityError: 0.01,
                model: model,
                associatedFrameCount: 2
            )],
            coverage: VisualEmbeddingCoverage(
                model: model,
                eligibleFrameCount: 10,
                indexedEligibleFrameCount: 8,
                indexedFrameCount: 8,
                pendingEligibleFrameCount: 2,
                staleEmbeddingCount: 0,
                uniqueVectorCount: 7,
                deduplicatedFrameCount: 1,
                storedVectorPayloadBytes: 3_584,
                coverageFraction: 0.8
            ),
            minimumSimilarity: 0.245
        )
    }
}
