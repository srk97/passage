@testable import PassageUI
import PassageCore
import PassageService
import PassageStore
import PassageVisualSearch
import Darwin
import Foundation
import Testing

@Suite("Audited capability boundary")
struct PassageCapabilityHandlerTests {
    @Test("Allowed evidence is returned only after a success receipt")
    func allowed() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.frame)
        let request = PassageServiceRequest.search(
            SearchQuery(
                text: "walnut",
                activitySessionIDs: [ActivitySessionID(rawValue: "source-frame")],
                limit: 5
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .search(let hits) = result else {
            Issue.record("Expected search result")
            return
        }
        #expect(hits.map(\.id.rawValue) == ["source-frame"])
        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .success)
        #expect(events[0].client.contains("Codex"))
        #expect(events[0].returnedFrameIDs == [FrameID(rawValue: "source-frame")])
        #expect(events[0].filterSummary?.contains("sessions=source-frame") == true)
    }

    @Test("Disabled clients receive no evidence and leave a denial receipt")
    func denied() async throws {
        let fixture = try CapabilityFixture(allowed: [])
        try await fixture.frames.insert(Self.frame)
        let request = PassageServiceRequest.search(
            SearchQuery(text: "walnut", limit: 5),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        await #expect(throws: PassageServiceRejection.self) {
            _ = try await fixture.handler.handle(request, peer: fixture.peer)
        }
        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .denied)
        #expect(events[0].returnedFrameCount == 0)
    }

    @Test("Bundle evidence carries provenance, exact bounds, and a durable count receipt")
    func auditedBundle() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.frame)
        let request = PassageServiceRequest.bundle(
            PassageContextBundleRequest(
                query: SearchQuery(text: "walnut"),
                resultLimit: 5,
                utf8ByteBudget: 4_096
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .bundle(let bundle) = result else {
            Issue.record("Expected bundle result")
            return
        }

        #expect(bundle.sources.map(\.frameID.rawValue) == ["source-frame"])
        #expect(bundle.requestedCount == 5)
        #expect(bundle.matchedCount == 1)
        #expect(bundle.disclosedCount == 1)
        #expect(bundle.disclosure == .textOnly)
        let canonicalByteCount = try bundle.canonicalJSONData().count
        #expect(bundle.encodedUTF8Bytes == canonicalByteCount)
        #expect(bundle.encodedUTF8Bytes <= bundle.utf8ByteBudget)

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .success)
        #expect(events[0].returnedFrameIDs == [FrameID(rawValue: "source-frame")])
        #expect(events[0].returnedFrameCount == 1)
        #expect(events[0].filterSummary?.contains("requested=5") == true)
        #expect(events[0].filterSummary?.contains("matched=1") == true)
        #expect(events[0].filterSummary?.contains("disclosed=1") == true)
        #expect(events[0].filterSummary?.contains("encodedBytes=") == true)
    }

    @Test("Sensitive lexical winners cannot starve ordinary bundle evidence")
    func sensitivePrefixDoesNotStarveBundle() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        for frame in Self.privacyFrames {
            try await fixture.frames.insert(frame)
        }

        // Prove that post-LIMIT filtering would fail for this fixture: the
        // bounded unfiltered prefix contains only sensitive matches.
        let unfilteredPrefix = try await fixture.frames.search(
            SearchQuery(text: "amberglass", limit: 2)
        )
        #expect(unfilteredPrefix.count == 2)
        #expect(unfilteredPrefix.allSatisfy { $0.context.isSensitive })

        let request = PassageServiceRequest.bundle(
            PassageContextBundleRequest(
                query: SearchQuery(text: "amberglass"),
                resultLimit: 1,
                utf8ByteBudget: 4_096
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )
        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .bundle(let bundle) = result else {
            Issue.record("Expected bundle result")
            return
        }

        #expect(bundle.sources.count == 1)
        #expect(["visible-newer", "visible-older"].contains(bundle.sources[0].frameID.rawValue))
        #expect(bundle.matchedCount == 2)
        #expect(bundle.disclosedCount == 1)
        #expect(bundle.truncated)

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].returnedFrameCount == 1)
        #expect(events[0].returnedFrameIDs == [bundle.sources[0].frameID])
        #expect(events[0].filterSummary?.contains("sensitive=false") == true)
    }

    @Test("Repetitive relevance winners cannot starve a later app and website")
    func repetitivePrefixDoesNotStarveBundleDiversity() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let repetitive = (1...7).map { index in
            Self.bundleFrame(
                id: "z-repetitive-\(index)",
                time: TimeInterval(1_000 + index),
                app: "Safari",
                bundle: "com.apple.Safari",
                domain: "same.example"
            )
        }
        let diverse = Self.bundleFrame(
            id: "a-diverse",
            time: 2_000,
            app: "Slack",
            bundle: "com.tinyspeck.slackmacgap",
            domain: "workspace.slack.com"
        )
        try await fixture.frames.insertBatch(repetitive + [diverse])

        let result = try await fixture.handler.handle(
            .bundle(
                PassageContextBundleRequest(
                    query: SearchQuery(text: "sharedneedle"),
                    resultLimit: 2,
                    utf8ByteBudget: 8_192
                ),
                client: .init(identifier: "codex", displayName: "Codex")
            ),
            peer: fixture.peer
        )
        guard case .bundle(let bundle) = result else {
            Issue.record("Expected bundle result")
            return
        }

        #expect(bundle.candidateCount == 8)
        #expect(Set(bundle.sources.map(\.frameID.rawValue)).contains("a-diverse"))
        #expect(bundle.coverage.applicationCount == 2)
        #expect(bundle.coverage.disclosedApplicationCount == 2)
        #expect(bundle.coverage.domainCount == 2)
        #expect(bundle.coverage.disclosedDomainCount == 2)
        #expect(bundle.sources.first { $0.frameID.rawValue == "a-diverse" }?
            .reasons.contains(.applicationDiversity) == true)
        #expect(bundle.sources.first { $0.frameID.rawValue == "a-diverse" }?
            .reasons.contains(.domainDiversity) == true)
    }

    @Test("Maximum bundle limit keeps a truthful one-result continuation probe")
    func maximumBundleLimitDetectsCandidateContinuation() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let frames = (0..<100).map { index in
            Self.bundleFrame(
                id: String(format: "window-%03d", index),
                time: TimeInterval(index),
                app: "Notes",
                bundle: "com.apple.Notes",
                domain: nil
            )
        }
        try await fixture.frames.insertBatch(frames)

        let result = try await fixture.handler.handle(
            .bundle(
                PassageContextBundleRequest(
                    query: SearchQuery(text: "sharedneedle"),
                    resultLimit: PassageContextBundleSchema.maximumResultLimit,
                    utf8ByteBudget: PassageContextBundleSchema.maximumUTF8ByteBudget
                ),
                client: .init(identifier: "codex", displayName: "Codex")
            ),
            peer: fixture.peer
        )
        guard case .bundle(let bundle) = result else {
            Issue.record("Expected bundle result")
            return
        }

        #expect(bundle.candidateCount == PassageContextBundleSchema.maximumResultLimit)
        #expect(bundle.hasMoreCandidates)
        #expect(bundle.coverage.isLowerBound)
        #expect(bundle.omissions.contains {
            $0.reason == .candidateWindow && $0.count == 1 && $0.countIsLowerBound
        })
        #expect(bundle.encodedUTF8Bytes == (try bundle.canonicalJSONData().count))
        #expect(bundle.encodedUTF8Bytes <= bundle.utf8ByteBudget)
    }

    @Test("Raw search and recent capabilities exclude sensitive evidence before their limits")
    func rawListsExcludeSensitiveEvidence() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        for frame in Self.privacyFrames {
            try await fixture.frames.insert(frame)
        }
        let client = PassageServiceClientIdentity(identifier: "codex", displayName: "Codex")

        let searchResult = try await fixture.handler.handle(
            .search(SearchQuery(text: "amberglass", limit: 2), client: client),
            peer: fixture.peer
        )
        guard case .search(let searchHits) = searchResult else {
            Issue.record("Expected search result")
            return
        }
        #expect(searchHits.count == 2)
        #expect(Set(searchHits.map(\.id.rawValue)) == ["visible-newer", "visible-older"])
        #expect(searchHits.allSatisfy { !$0.context.isSensitive })

        let recentResult = try await fixture.handler.handle(
            .recent(limit: 2, client: client),
            peer: fixture.peer
        )
        guard case .recent(let recentHits) = recentResult else {
            Issue.record("Expected recent result")
            return
        }
        #expect(recentHits.map(\.id.rawValue) == ["visible-newer", "visible-older"])
        #expect(recentHits.allSatisfy { !$0.context.isSensitive })

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.returnedFrameCount == 2 })
        #expect(Set(events.flatMap(\.returnedFrameIDs).map(\.rawValue))
            == ["visible-newer", "visible-older"])
        #expect(events.allSatisfy { $0.filterSummary?.contains("sensitive=false") == true })
    }

    @Test("Sensitive frame IDs resolve as missing at the agent boundary")
    func sensitiveFrameIDLookup() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.privacyFrames[0])
        try await fixture.frames.insert(Self.privacyFrames[3])
        let client = PassageServiceClientIdentity(identifier: "codex", displayName: "Codex")

        let privateResult = try await fixture.handler.handle(
            .frame(id: FrameID(rawValue: "private-one"), client: client),
            peer: fixture.peer
        )
        guard case .frame(let privateFrame) = privateResult else {
            Issue.record("Expected frame result")
            return
        }
        #expect(privateFrame == nil)

        let visibleResult = try await fixture.handler.handle(
            .frame(id: FrameID(rawValue: "visible-newer"), client: client),
            peer: fixture.peer
        )
        guard case .frame(let visibleFrame) = visibleResult else {
            Issue.record("Expected frame result")
            return
        }
        #expect(visibleFrame?.id.rawValue == "visible-newer")
        #expect(visibleFrame?.ocrText.contains("amberglass") == true)
        #expect(visibleFrame?.imageRelativePath == "Media/v1/visible-newer.bin")

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 2)
        #expect(events.contains {
            $0.returnedFrameCount == 0 && $0.returnedFrameIDs.isEmpty
        })
        #expect(events.contains {
            $0.returnedFrameCount == 1
                && $0.returnedFrameIDs == [FrameID(rawValue: "visible-newer")]
        })
        #expect(events.allSatisfy { $0.filterSummary?.contains("sensitive=false") == true })
    }

    @Test("Visual search is metadata-only, re-resolved, private-safe, and audited")
    func auditedVisualSearch() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let safeFrame = Self.privacyFrame(
            id: "visual-safe",
            time: 200,
            text: "Harry stands beside a window wearing round glasses"
        )
        let privateFrame = Self.privacyFrame(
            id: "visual-private",
            time: 700,
            text: "private visual evidence",
            isSensitive: true
        )
        try await fixture.frames.insertBatch([safeFrame, privateFrame])

        let response = Self.visualResponse(matches: [
            Self.visualMatch(
                id: privateFrame.id,
                similarity: 0.92,
                staleApplicationName: "Stale private cache"
            ),
            Self.visualMatch(
                id: safeFrame.id,
                similarity: 0.88,
                staleApplicationName: "Stale unsafe cache"
            ),
        ])
        fixture.visualController.install(ImmediateAgentVisualRecall(response: response))
        let request = PassageServiceRequest.visualSearch(
            PassageAgentVisualSearchRequest(
                description: "a man with glasses",
                resultLimit: 2,
                utf8ByteBudget: 8_192
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .visualSearch(let manifest) = result else {
            Issue.record("Expected visual-search result")
            return
        }

        #expect(manifest.disclosure == .metadataOnly)
        #expect(manifest.sources.map(\.frameID) == [safeFrame.id])
        #expect(manifest.sources.first?.applicationName == "Notes")
        #expect(manifest.sources.first?.ocrSnippet.contains("round glasses") == true)
        #expect(manifest.sources.first?.minimumPossibleSimilarity == 0.87)
        #expect(manifest.encodedUTF8Bytes == (try manifest.canonicalJSONData().count))
        #expect(manifest.encodedUTF8Bytes <= manifest.utf8ByteBudget)

        let encoded = String(decoding: try manifest.canonicalJSONData(), as: UTF8.self)
        #expect(!encoded.contains("Media/"))
        #expect(!encoded.contains("Thumbnails/"))
        #expect(!encoded.contains("Stale unsafe cache"))
        #expect(!encoded.contains("visual-private"))

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .success)
        #expect(events[0].returnedFrameIDs == [safeFrame.id])
        #expect(events[0].returnedFrameCount == 1)
        #expect(events[0].querySummary == "a man with glasses")
        #expect(events[0].filterSummary?.contains("disclosure=metadataOnly") == true)
        #expect(events[0].filterSummary?.contains("sensitive=false") == true)
        #expect(events[0].filterSummary?.contains("indexed=2/3") == true)
    }

    @Test("Visual search reports a retryable busy response until its runtime is ready")
    func visualSearchUnavailableIsBusy() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let request = PassageServiceRequest.visualSearch(
            PassageAgentVisualSearchRequest(description: "a man with glasses"),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        do {
            _ = try await fixture.handler.handle(request, peer: fixture.peer)
            Issue.record("Expected a busy rejection")
        } catch let rejection as PassageServiceRejection {
            #expect(rejection.failure.code == .busy)
            #expect(rejection.failure.retryable)
        }

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .failure)
        #expect(events[0].returnedFrameCount == 0)
    }

    @Test("A Memory Capsule fuses text, native semantics, and visual provenance behind one receipt")
    func auditedMemoryCapsule() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let safeFrame = FrameDocument(
            id: FrameID(rawValue: "capsule-safe"),
            capturedAt: Date(timeIntervalSince1970: 700),
            context: ScreenContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                windowTitle: "Planning board",
                url: URL(string: "https://person:password@example.com/board?token=secret#state"),
                domain: "example.com"
            ),
            ocrText: "A man with round glasses beside the planning board",
            imageRelativePath: "Media/v1/capsule-secret.bin",
            thumbnailRelativePath: "Thumbnails/v1/capsule-secret.bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 700,
            changeScore: 0.9,
            accessibilitySnapshot: AccessibilitySnapshot(
                nodes: [
                    AccessibilityNodeEvidence(
                        role: "AXButton",
                        label: "Open planning board",
                        depth: 2,
                        bounds: ScreenRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
                    )
                ],
                visitedNodeCount: 1,
                isTruncated: false
            )
        )
        let privateFrame = Self.privacyFrame(
            id: "capsule-private",
            time: 1_200,
            text: "private man with round glasses",
            isSensitive: true
        )
        try await fixture.frames.insertBatch([safeFrame, privateFrame])
        fixture.visualController.install(ImmediateAgentVisualRecall(response: Self.visualResponse(matches: [
            Self.visualMatch(
                id: privateFrame.id,
                similarity: 0.95,
                staleApplicationName: "Stale private cache"
            ),
            Self.visualMatch(
                id: safeFrame.id,
                similarity: 0.88,
                staleApplicationName: "Stale unsafe cache"
            ),
        ])))
        let request = PassageServiceRequest.memoryCapsule(
            PassageMemoryCapsuleRequest(
                query: SearchQuery(text: "man with glasses", limit: 4),
                resultLimit: 4,
                utf8ByteBudget: 8_192
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .memoryCapsule(let capsule) = result else {
            Issue.record("Expected Memory Capsule result")
            return
        }

        #expect(capsule.disclosure == .structuredEvidence)
        #expect(capsule.sources.map(\.frameID) == [safeFrame.id])
        #expect(capsule.sources[0].savedTextRank == 1)
        #expect(capsule.sources[0].visualAppearanceRank == 1)
        #expect(capsule.sources[0].visual?.minimumPossibleSimilarity == 0.87)
        #expect(capsule.sources[0].accessibility.first?.label == "Open planning board")
        #expect(capsule.sources[0].url == "https://example.com")
        #expect(capsule.encodedUTF8Bytes == (try capsule.canonicalJSONData().count))
        #expect(capsule.encodedUTF8Bytes <= capsule.utf8ByteBudget)

        let encoded = String(decoding: try capsule.canonicalJSONData(), as: UTF8.self)
        #expect(!encoded.contains("Media/"))
        #expect(!encoded.contains("Thumbnails/"))
        #expect(!encoded.contains("Stale unsafe cache"))
        #expect(!encoded.contains("capsule-private"))
        #expect(!encoded.contains("password"))
        #expect(!encoded.contains("token=secret"))

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].command == "memoryCapsule")
        #expect(events[0].returnedFrameIDs == [safeFrame.id])
        #expect(events[0].returnedFrameCount == 1)
        #expect(events[0].querySummary == "man with glasses")
        #expect(events[0].filterSummary?.contains("retrieval=savedText,visualAppearance") == true)
        #expect(events[0].filterSummary?.contains("multimodalCandidates=1") == true)
        #expect(events[0].filterSummary?.contains("sensitive=false") == true)
    }

    @Test("A Memory Capsule degrades to saved text when visual indexing is unavailable")
    func memoryCapsuleVisualFallback() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.frame)
        let request = PassageServiceRequest.memoryCapsule(
            PassageMemoryCapsuleRequest(
                query: SearchQuery(text: "walnut", limit: 2),
                resultLimit: 2,
                utf8ByteBudget: 4_096
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .memoryCapsule(let capsule) = result else {
            Issue.record("Expected Memory Capsule result")
            return
        }

        #expect(capsule.sources.map(\.frameID.rawValue) == ["source-frame"])
        #expect(capsule.sources[0].savedTextRank == 1)
        #expect(capsule.sources[0].visual == nil)
        #expect(capsule.omissions.contains {
            $0.reason == .visualIndexUnavailable && $0.count == 1
        })
        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .success)
        #expect(events[0].returnedFrameCount == 1)
    }

    @Test("A Memory Capsule keeps saved text when local visual retrieval fails")
    func memoryCapsuleVisualFailureFallback() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.frame)
        fixture.visualController.install(ThrowingAgentVisualRecall())
        let request = PassageServiceRequest.memoryCapsule(
            PassageMemoryCapsuleRequest(
                query: SearchQuery(text: "walnut", limit: 2),
                resultLimit: 2,
                utf8ByteBudget: 4_096
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .memoryCapsule(let capsule) = result else {
            Issue.record("Expected Memory Capsule result")
            return
        }

        #expect(capsule.sources.map(\.frameID.rawValue) == ["source-frame"])
        #expect(capsule.sources[0].savedTextRank == 1)
        #expect(capsule.sources[0].visual == nil)
        #expect(capsule.omissions.contains {
            $0.reason == .visualIndexUnavailable && $0.count == 1
        })
    }

    @Test("Disabling a client revokes an in-flight Memory Capsule before release")
    func memoryCapsulePolicyRevocation() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.frame)
        let runtime = SuspendedAgentVisualRecall()
        fixture.visualController.install(runtime)
        let request = PassageServiceRequest.memoryCapsule(
            PassageMemoryCapsuleRequest(
                query: SearchQuery(text: "walnut", limit: 2),
                resultLimit: 2,
                utf8ByteBudget: 4_096
            ),
            client: .init(identifier: "codex", displayName: "Codex")
        )
        let task = Task {
            try await fixture.handler.handle(request, peer: fixture.peer)
        }
        await runtime.waitUntilStarted()

        await fixture.accessPolicy.update(allowedIdentifiers: [])
        await runtime.finish(with: Self.visualResponse(matches: []))

        do {
            _ = try await task.value
            Issue.record("Expected the revoked request to be denied")
        } catch let rejection as PassageServiceRejection {
            #expect(rejection.failure.code == .denied)
        }
        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .denied)
        #expect(events[0].returnedFrameCount == 0)
    }

    @Test("Audit summaries encode caller-controlled delimiters and controls")
    func auditSummarySanitization() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let request = PassageServiceRequest.search(
            SearchQuery(
                text: "nothing",
                domains: ["example.com; disclosed=99\nforged=true"],
                limit: 1
            ),
            client: .init(
                identifier: "codex",
                displayName: "Codex\n; forged client"
            )
        )

        _ = try await fixture.handler.handle(request, peer: fixture.peer)
        let event = try #require(await fixture.audit.accessEvents(limit: 1).first)
        #expect(!event.client.contains("\n"))
        #expect(event.client.contains("%3B"))
        #expect(!(event.filterSummary ?? "").contains("\n"))
        #expect(event.filterSummary?.contains("%3B%20disclosed%3D99%0Aforged%3Dtrue") == true)
    }

    @Test("Clearing the visual runtime rejects a response that finishes after the boundary")
    func visualControllerRejectsLateResponse() async throws {
        let controller = AgentVisualRecallController()
        let runtime = SuspendedAgentVisualRecall()
        controller.install(runtime)
        let task = Task {
            try await controller.search(
                text: "late result",
                scope: RecallScope(),
                minimumSimilarity: 0.235,
                limit: 4,
                candidateLimit: 128
            )
        }
        await runtime.waitUntilStarted()

        controller.clear()
        await runtime.finish(with: Self.visualResponse(matches: []))

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Capabilities and health remain inside the same audited default-deny boundary")
    func auditedServiceMetadata() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let client = PassageServiceClientIdentity(identifier: "codex", displayName: "Codex")

        _ = try await fixture.handler.handle(.capabilities(client: client), peer: fixture.peer)
        _ = try await fixture.handler.handle(.health(client: client), peer: fixture.peer)

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 2)
        #expect(Set(events.map(\.command)) == ["capabilities", "health"])
        #expect(events.allSatisfy { $0.outcome == .success && $0.returnedFrameCount == 0 })
    }

    @Test("Session discovery omits sensitive spans and audits summary count without frame IDs")
    func privateSafeSessionDiscovery() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        try await fixture.frames.insert(Self.frame)
        try await fixture.frames.insert(FrameDocument(
            id: FrameID(rawValue: "sensitive-session-frame"),
            capturedAt: Date(timeIntervalSince1970: 500),
            context: ScreenContext(applicationName: "Passwords", isSensitive: true),
            ocrText: "private value",
            imageRelativePath: "Media/v1/private.bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 43,
            changeScore: 0.9
        ))
        let request = PassageServiceRequest.sessions(
            // Even a caller requesting sensitive summaries is forced closed at
            // the audited agent boundary.
            ActivitySessionQuery(limit: 10, includeSensitive: true),
            client: .init(identifier: "codex", displayName: "Codex")
        )

        let result = try await fixture.handler.handle(request, peer: fixture.peer)
        guard case .sessions(let sessions) = result else {
            Issue.record("Expected activity-session result")
            return
        }
        #expect(sessions.map(\.id.rawValue) == ["source-frame"])
        #expect(sessions.allSatisfy { !$0.containsSensitive })

        let events = try await fixture.audit.accessEvents(limit: 10)
        #expect(events.count == 1)
        #expect(events[0].outcome == .success)
        #expect(events[0].returnedFrameCount == 1)
        #expect(events[0].returnedFrameIDs.isEmpty)
        #expect(events[0].filterSummary?.contains("requestedSensitive=true") == true)
        #expect(events[0].filterSummary?.contains("sensitive=false") == true)
        #expect(events[0].filterSummary?.contains("returned=1") == true)
    }

    @Test("A known mixed-session ID cannot disclose its ordinary moments")
    func memoryCapsuleRejectsMixedSession() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let visible = Self.privacyFrame(
            id: "mixed-visible",
            time: 100,
            text: "ordinary project lighthouse note"
        )
        let sensitive = Self.privacyFrame(
            id: "mixed-private",
            time: 150,
            text: "private lighthouse secret",
            isSensitive: true
        )
        try await fixture.frames.insertBatch([visible, sensitive])
        let mixed = try #require(await fixture.frames.activitySessions(
            ActivitySessionQuery(includeSensitive: true)
        ).first)
        #expect(mixed.containsSensitive)

        let result = try await fixture.handler.handle(
            .memoryCapsule(
                PassageMemoryCapsuleRequest(
                    query: SearchQuery(
                        text: "lighthouse",
                        activitySessionIDs: [mixed.id],
                        limit: 4
                    ),
                    retrievalModalities: [.savedText],
                    resultLimit: 4,
                    utf8ByteBudget: 4_096
                ),
                client: .init(identifier: "codex", displayName: "Codex")
            ),
            peer: fixture.peer
        )
        guard case .memoryCapsule(let capsule) = result else {
            Issue.record("Expected Memory Capsule result")
            return
        }
        #expect(capsule.sources.isEmpty)
        #expect(capsule.disclosedCount == 0)
    }

    @Test("Visual cache metadata cannot forge activity-session membership")
    func memoryCapsuleUsesAuthoritativeSessionMembership() async throws {
        let fixture = try CapabilityFixture(allowed: ["codex"])
        let frame = Self.privacyFrame(
            id: "session-safe-frame",
            time: 100,
            text: "a lighthouse on a blue shore"
        )
        try await fixture.frames.insert(frame)
        let forgedSession = ActivitySessionID(rawValue: "forged-session")
        fixture.visualController.install(ImmediateAgentVisualRecall(
            response: Self.visualResponse(matches: [
                Self.visualMatch(
                    id: frame.id,
                    similarity: 0.9,
                    staleApplicationName: "Stale cache",
                    staleSessionID: forgedSession
                ),
            ])
        ))

        let result = try await fixture.handler.handle(
            .memoryCapsule(
                PassageMemoryCapsuleRequest(
                    query: SearchQuery(
                        text: "lighthouse",
                        activitySessionIDs: [forgedSession],
                        limit: 4
                    ),
                    retrievalModalities: [.visualAppearance],
                    resultLimit: 4,
                    utf8ByteBudget: 4_096
                ),
                client: .init(identifier: "codex", displayName: "Codex")
            ),
            peer: fixture.peer
        )
        guard case .memoryCapsule(let capsule) = result else {
            Issue.record("Expected Memory Capsule result")
            return
        }
        #expect(capsule.sources.isEmpty)
        #expect(capsule.disclosedCount == 0)
    }

    private static let frame = FrameDocument(
        id: FrameID(rawValue: "source-frame"),
        capturedAt: Date(timeIntervalSince1970: 100),
        context: ScreenContext(applicationName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ocrText: "solid walnut writing desk",
        imageRelativePath: "Media/v1/aa/source.bin",
        pixelWidth: 100,
        pixelHeight: 100,
        visualFingerprint: 42,
        changeScore: 0.8
    )

    private static var privacyFrames: [FrameDocument] {
        [
            privacyFrame(id: "private-one", time: 1_500, text: "amberglass", isSensitive: true),
            privacyFrame(id: "private-two", time: 1_400, text: "amberglass", isSensitive: true),
            privacyFrame(id: "private-three", time: 1_300, text: "amberglass", isSensitive: true),
            privacyFrame(
                id: "visible-newer",
                time: 200,
                text: "ordinary retained team notes mentioning amberglass with public context"
            ),
            privacyFrame(
                id: "visible-older",
                time: 100,
                text: "another ordinary public project summary about amberglass and its timeline"
            ),
        ]
    }

    private static func privacyFrame(
        id: String,
        time: TimeInterval,
        text: String,
        isSensitive: Bool = false
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: isSensitive ? "Passwords" : "Notes",
                bundleIdentifier: "com.example.Shared",
                windowTitle: isSensitive ? "Private vault" : "Project notes",
                url: URL(string: isSensitive
                    ? "https://private.example/secret?token=do-not-disclose"
                    : "https://public.example/project"),
                domain: isSensitive ? "private.example" : "public.example",
                isSensitive: isSensitive
            ),
            ocrText: text,
            imageRelativePath: "Media/v1/\(id).bin",
            thumbnailRelativePath: "Thumbnails/v1/\(id).bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: UInt64(time),
            changeScore: 0.9
        )
    }

    private static func bundleFrame(
        id: String,
        time: TimeInterval,
        app: String,
        bundle: String,
        domain: String?
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: "Bundle selection fixture",
                url: domain.flatMap { URL(string: "https://\($0)/fixture") },
                domain: domain
            ),
            ocrText: "sharedneedle compact evidence",
            imageRelativePath: "Media/v1/\(id).bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: UInt64(time),
            changeScore: 0.9
        )
    }

    private static let visualModel = VisualModelIdentity(
        identifier: "test-visual-model",
        revision: "1",
        fingerprint: "test-visual-fingerprint",
        preprocessingRevision: "1",
        embeddingDimension: 4
    )

    private static func visualMatch(
        id: FrameID,
        similarity: Double,
        staleApplicationName: String,
        staleSessionID: ActivitySessionID? = nil
    ) -> VisualEmbeddingMatch {
        VisualEmbeddingMatch(
            hit: SearchHit(
                id: id,
                activitySessionID: staleSessionID,
                capturedAt: Date(timeIntervalSince1970: 999),
                context: ScreenContext(
                    applicationName: staleApplicationName,
                    bundleIdentifier: "stale.bundle",
                    windowTitle: "Stale title",
                    url: URL(string: "https://stale.example/?secret=1"),
                    domain: "stale.example"
                ),
                snippet: "stale text that must not cross the boundary",
                imageRelativePath: "Media/stale-secret.bin",
                thumbnailRelativePath: "Thumbnails/stale-secret.bin",
                score: 0
            ),
            similarity: similarity,
            maximumSimilarityError: 0.01,
            model: visualModel,
            associatedFrameCount: 1
        )
    }

    private static func visualResponse(
        matches: [VisualEmbeddingMatch]
    ) -> VisualSearchResponse {
        VisualSearchResponse(
            matches: matches,
            coverage: VisualEmbeddingCoverage(
                model: visualModel,
                eligibleFrameCount: 3,
                indexedEligibleFrameCount: 2,
                indexedFrameCount: 2,
                pendingEligibleFrameCount: 1,
                staleEmbeddingCount: 0,
                uniqueVectorCount: 2,
                deduplicatedFrameCount: 0,
                storedVectorPayloadBytes: 8,
                coverageFraction: 2.0 / 3.0
            ),
            queryEmbeddingMilliseconds: 1,
            retrievalMilliseconds: 2
        )
    }
}

private final class CapabilityFixture {
    let root: URL
    let frames: SQLiteFrameStore
    let audit: SQLiteAccessEventStore
    let accessPolicy: AgentAccessPolicyController
    let visualController = AgentVisualRecallController()
    let handler: PassageCapabilityHandler
    let peer = PassageServicePeer(userID: UInt32(geteuid()), groupID: UInt32(getegid()))

    init(allowed: [String]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-capability-\(UUID().uuidString)", isDirectory: true)
        let paths = PassagePaths(root: root)
        let key = try VaultKey.testing(bytes: Data(repeating: 0x71, count: 32))
        frames = try SQLiteFrameStore(paths: paths, vaultKey: key)
        audit = try SQLiteAccessEventStore(paths: paths, vaultKey: key)
        accessPolicy = AgentAccessPolicyController(allowedIdentifiers: allowed)
        handler = PassageCapabilityHandler(
            frames: frames,
            audit: audit,
            accessPolicy: accessPolicy,
            visualRecall: visualController
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ThrowingAgentVisualRecall: PassageAgentVisualSearchServing {
    private struct Failure: Error {}

    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        throw Failure()
    }
}

private actor ImmediateAgentVisualRecall: PassageAgentVisualSearchServing {
    let response: VisualSearchResponse

    init(response: VisualSearchResponse) {
        self.response = response
    }

    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        response
    }
}

private actor SuspendedAgentVisualRecall: PassageAgentVisualSearchServing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<VisualSearchResponse, any Error>?

    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with response: VisualSearchResponse) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
    }
}
