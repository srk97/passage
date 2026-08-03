import PassageCore
import PassageService
import Darwin
import Foundation
import Testing

@Suite("Passage local capability service")
struct PassageLocalServiceTests {
    @Test("Server and thin client round trip every capability")
    func roundTrips() throws {
        let fixture = try ServiceFixture()
        let server = PassageLocalServiceServer(
            endpoint: fixture.endpoint,
            handler: FixtureHandler()
        )
        try server.start()
        defer { server.stop() }

        #expect(server.isRunning)
        #expect(fixture.socketPermissions == 0o600)

        let client = fixture.client()
        let capabilities = try client.capabilities()
        #expect(capabilities.protocolVersion == PassageServiceProtocol.currentVersion)
        #expect(capabilities.bundleSchemaVersion == PassageContextBundleSchema.currentVersion)
        #expect(capabilities.capabilities.contains(.bundle))
        #expect(capabilities.capabilities.contains(.sessions))
        #expect(capabilities.capabilities.contains(.visualSearch))
        #expect(capabilities.capabilities.contains(.memoryCapsule))
        #expect(capabilities.defaultVisualSearchResultLimit == 6)
        #expect(capabilities.maximumVisualSearchResultLimit == 20)

        let health = try client.health()
        #expect(health.status == .ready)

        let bundle = try client.bundle(PassageContextBundleRequest(
            query: SearchQuery(text: "Aurora"),
            resultLimit: 3,
            utf8ByteBudget: 2_048
        ))
        #expect(bundle.sources.map(\.frameID.rawValue) == ["bundle-result"])
        #expect(bundle.matchedCount == 2)
        #expect(bundle.truncated)
        #expect(bundle.encodedUTF8Bytes <= 2_048)

        let visual = try client.visualSearch(PassageAgentVisualSearchRequest(
            description: "a planning board",
            scope: RecallScope(domains: ["example.com"]),
            resultLimit: 1,
            utf8ByteBudget: 4_096
        ))
        #expect(visual.sources.map(\.frameID.rawValue) == ["visual-result"])
        #expect(abs(visual.sources[0].minimumPossibleSimilarity - 0.39) < 0.000_001)
        #expect(visual.disclosure == .metadataOnly)
        #expect(visual.encodedUTF8Bytes <= 4_096)

        let capsule = try client.memoryCapsule(PassageMemoryCapsuleRequest(
            query: SearchQuery(text: "a planning board", limit: 2),
            resultLimit: 2,
            utf8ByteBudget: 4_096
        ))
        #expect(capsule.sources.map(\.frameID.rawValue) == ["capsule-result"])
        #expect(capsule.disclosure == .structuredEvidence)
        #expect(capsule.encodedUTF8Bytes <= 4_096)

        let search = try client.search(SearchQuery(text: "Aurora", limit: 10))
        #expect(search.map(\.id.rawValue) == ["search-sensitive", "search-result"])
        #expect(search.first?.context.isSensitive == true)
        #expect(search.last?.context.isSensitive == false)

        let recent = try client.recent(limit: 7)
        #expect(recent.map(\.id.rawValue) == ["recent-result"])

        let sessions = try client.sessions(ActivitySessionQuery(
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 500),
            limit: 7,
            includeSensitive: false
        ))
        #expect(sessions.map(\.id.rawValue) == ["session-result"])
        #expect(sessions[0].frameCount == 2)

        let frame = try client.frame(id: FrameID(rawValue: "detail"))
        #expect(frame?.id.rawValue == "detail")
        #expect(frame?.ocrText == "Full frame detail")

        let statistics = try client.statistics()
        #expect(statistics.frameCount == 42)
        #expect(statistics.databaseBytes == 1_024)
    }

    @Test("Intentional handler denials arrive as structured remote errors")
    func policyDenial() throws {
        let fixture = try ServiceFixture()
        let server = PassageLocalServiceServer(
            endpoint: fixture.endpoint,
            handler: FixtureHandler()
        )
        try server.start()
        defer { server.stop() }

        let deniedClient = fixture.client(identifier: "denied-client")
        do {
            _ = try deniedClient.statistics()
            Issue.record("Expected the service policy to deny this client")
        } catch let PassageServiceTransportError.remote(failure) {
            #expect(failure.code == .denied)
            #expect(failure.retryable == false)
            #expect(failure.message == "This client is disabled in Passage settings.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A running endpoint cannot be unlinked or taken over")
    func rejectsSecondServer() throws {
        let fixture = try ServiceFixture()
        let first = PassageLocalServiceServer(
            endpoint: fixture.endpoint,
            handler: FixtureHandler()
        )
        let second = PassageLocalServiceServer(
            endpoint: fixture.endpoint,
            handler: FixtureHandler()
        )
        try first.start()
        defer {
            second.stop()
            first.stop()
        }

        #expect(throws: PassageServiceTransportError.self) {
            try second.start()
        }
        #expect(try fixture.client().statistics().frameCount == 42)
    }

    @Test("Oversized handler results become bounded responseTooLarge failures")
    func responseLimit() throws {
        let fixture = try ServiceFixture()
        let limits = PassageServiceLimits(
            maximumRequestBytes: 2_048,
            maximumResponseBytes: 512,
            ioTimeoutSeconds: 2
        )
        let handler = AnyPassageServiceRequestHandler { request, _ in
            guard request.capability == .search else { return .statistics(.empty) }
            let oversized = SearchHit(
                id: FrameID(rawValue: "large"),
                capturedAt: Date(timeIntervalSince1970: 1),
                context: ScreenContext(applicationName: "Test"),
                snippet: String(repeating: "x", count: 4_096),
                imageRelativePath: "Media/large.jpg",
                score: 1
            )
            return .search([oversized])
        }
        let server = PassageLocalServiceServer(
            endpoint: fixture.endpoint,
            limits: limits,
            handler: handler
        )
        try server.start()
        defer { server.stop() }

        let client = fixture.client(limits: limits)
        do {
            _ = try client.search(SearchQuery(text: "large"))
            Issue.record("Expected a response-size failure")
        } catch let PassageServiceTransportError.remote(failure) {
            #expect(failure.code == .responseTooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Stopping removes only the server's own socket and clients fail clearly")
    func stopLifecycle() throws {
        let fixture = try ServiceFixture()
        let server = PassageLocalServiceServer(
            endpoint: fixture.endpoint,
            handler: FixtureHandler()
        )
        try server.start()
        #expect(FileManager.default.fileExists(atPath: fixture.endpoint.path))
        server.stop()

        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.path))
        #expect(throws: PassageServiceTransportError.self) {
            try fixture.client().statistics()
        }
    }
}

private struct FixtureHandler: PassageServiceRequestHandling {
    func handle(
        _ request: PassageServiceRequest,
        peer: PassageServicePeer
    ) async throws -> PassageServiceResult {
        guard peer.userID == UInt32(geteuid()) else {
            throw PassageServiceRejection(code: .denied, message: "Wrong local user.")
        }
        if request.client.identifier == "denied-client" {
            throw PassageServiceRejection(
                code: .denied,
                message: "This client is disabled in Passage settings."
            )
        }

        switch request.capability {
        case .capabilities:
            return .capabilities(.current)
        case .health:
            return .health(.ready)
        case .bundle:
            guard let bundleRequest = request.bundleRequest else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Missing bundle request.")
            }
            return .bundle(try PassageContextBundleBuilder.build(
                request: bundleRequest,
                hits: [Self.sensitiveHit(id: "bundle-sensitive"), Self.hit(id: "bundle-result")]
            ))
        case .visualSearch:
            guard let visualRequest = request.visualSearchRequest else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Missing visual request.")
            }
            let model = Self.visualModel
            return .visualSearch(try PassageAgentVisualSearchBuilder.build(
                request: visualRequest,
                candidates: [VisualEmbeddingMatch(
                    hit: Self.hit(id: "visual-result"),
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
            ))
        case .memoryCapsule:
            guard let capsuleRequest = request.memoryCapsuleRequest else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Missing capsule request.")
            }
            return .memoryCapsule(try PassageMemoryCapsuleBuilder.build(
                request: capsuleRequest,
                candidates: [PassageMemoryCapsuleCandidate(
                    hit: Self.hit(id: "capsule-result"),
                    ocrText: "Planning board evidence",
                    savedTextRank: 1
                )]
            ))
        case .search:
            return .search([Self.sensitiveHit(id: "search-sensitive"), Self.hit(id: "search-result")])
        case .recent:
            return .recent([Self.hit(id: "recent-result")])
        case .sessions:
            return .sessions([Self.session(id: "session-result")])
        case .frame:
            guard let id = request.frameID else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Missing frame ID.")
            }
            return .frame(FrameDocument(
                id: id,
                capturedAt: Date(timeIntervalSince1970: 500),
                context: ScreenContext(applicationName: "Xcode"),
                ocrText: "Full frame detail",
                imageRelativePath: "Media/\(id.rawValue).jpg",
                pixelWidth: 1_440,
                pixelHeight: 900,
                visualFingerprint: 99,
                changeScore: 0.5
            ))
        case .statistics:
            return .statistics(StoreStatistics(
                frameCount: 42,
                oldestCapture: Date(timeIntervalSince1970: 100),
                newestCapture: Date(timeIntervalSince1970: 500),
                databaseBytes: 1_024,
                mediaBytes: 2_048
            ))
        }
    }

    private static func hit(id: String) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: 400),
            context: ScreenContext(applicationName: "Safari", domain: "example.com"),
            snippet: "Project Aurora",
            imageRelativePath: "Media/\(id).jpg",
            score: 1
        )
    }

    private static func sensitiveHit(id: String) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: 401),
            context: ScreenContext(applicationName: "Passwords", isSensitive: true),
            snippet: "Private Project Aurora",
            imageRelativePath: "Media/\(id).jpg",
            score: 2
        )
    }

    private static func session(id: String) -> ActivitySessionSummary {
        ActivitySessionSummary(
            id: ActivitySessionID(rawValue: id),
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 400),
            frameCount: 2,
            title: "Project Aurora",
            latestApplicationName: "Safari",
            latestBundleIdentifier: "com.apple.Safari",
            latestDomain: "example.com",
            representativeFrameID: FrameID(rawValue: "session-first"),
            latestFrameID: FrameID(rawValue: "session-latest"),
            latestSnippet: "Project Aurora",
            resumeTarget: ActivityResumeTarget(
                url: URL(string: "https://example.com/project"),
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari"
            )
        )
    }

    private static let visualModel = VisualModelIdentity(
        identifier: "test-model",
        revision: "1",
        fingerprint: "abcdef",
        preprocessingRevision: "test-v1",
        embeddingDimension: 512
    )
}

private final class ServiceFixture {
    let root: URL
    let endpoint: PassageServiceEndpoint

    init() throws {
        // Unix-domain socket paths are limited to 103 UTF-8 bytes on Darwin, while
        // XCTest's per-process temporary directory is often already quite long.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("passage-ipc-\(UUID().uuidString)", isDirectory: true)
        endpoint = try PassageServiceEndpoint(
            socketURL: root.appendingPathComponent("service.sock")
        )
    }

    func client(
        identifier: String = "app.passage.tests",
        limits: PassageServiceLimits = PassageServiceLimits()
    ) -> PassageLocalServiceClient {
        PassageLocalServiceClient(
            endpoint: endpoint,
            identity: PassageServiceClientIdentity(
                identifier: identifier,
                displayName: "Passage Tests",
                version: "1"
            ),
            limits: limits
        )
    }

    var socketPermissions: UInt16? {
        guard let value = try? FileManager.default.attributesOfItem(atPath: endpoint.path)[.posixPermissions]
            as? NSNumber else { return nil }
        return value.uint16Value & 0o777
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension StoreStatistics {
    static let empty = StoreStatistics(
        frameCount: 0,
        oldestCapture: nil,
        newestCapture: nil,
        databaseBytes: 0,
        mediaBytes: 0
    )
}
