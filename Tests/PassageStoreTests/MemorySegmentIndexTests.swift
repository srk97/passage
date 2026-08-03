import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Encrypted memory segment index")
struct MemorySegmentIndexTests {
    @Test("A dirty shadow is explicit and a rebuild is deterministic with 64-frame chunks")
    func lifecycleAndDeterministicChunking() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<130).map { index in
            Self.frame(
                id: String(format: "frame-%03d", index),
                time: 1_000 + Double(index),
                text: "deterministic evidence \(index)",
                app: "Notes",
                bundle: "app.notes",
                domain: "Example.COM"
            )
        })

        let dirtyStatus = try await store.memorySegmentIndexStatus()
        #expect(dirtyStatus?.lifecycle == .dirty)
        let request = try Self.request(limit: 10)
        let incomplete = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(incomplete.segments.isEmpty)
        #expect(incomplete.omissions == [
            MemorySegmentOmission(reason: .incompleteIndex),
        ])
        #expect(!incomplete.isComplete)

        let firstRevision = try await store.rebuildMemorySegmentIndex()
        let readyStatus = try await store.memorySegmentIndexStatus()
        #expect(readyStatus?.lifecycle == .ready)
        #expect(readyStatus?.revision == firstRevision)
        #expect(readyStatus?.canonicalFrameCount == 130)
        #expect(readyStatus?.segmentCount == 3)

        let firstPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(firstPage.isComplete)
        #expect(firstPage.segments.count == 3)
        #expect(firstPage.segments.map { $0.frameIDs.count }.sorted() == [2, 64, 64])
        #expect(firstPage.segments.allSatisfy { $0.frameIDs.count <= 64 })
        #expect(Set(firstPage.segments.flatMap(\.frameIDs)).count == 130)
        #expect(firstPage.segments.allSatisfy {
            $0.scope.domains == ["example.com"]
                && $0.scope.applicationBundleIdentifiers == ["app.notes"]
                && $0.scope.activitySessionIDs.count == 1
        })
        let firstSegments = firstPage.segments

        let secondRevision = try await store.rebuildMemorySegmentIndex()
        let secondPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(secondRevision == firstRevision)
        #expect(secondPage.revision == firstPage.revision)
        #expect(secondPage.segments == firstSegments)
    }

    @Test("A time scope projects only in-range lineage and enrichment evidence")
    func timeScopeProjectsAuthoritativeMembers() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "outside-before",
                time: 100,
                text: "before private detail",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "inside-one",
                time: 101,
                text: "first included detail",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "inside-two",
                time: 102,
                text: "second included detail",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "outside-after",
                time: 103,
                text: "after private detail",
                app: "Notes",
                bundle: "app.notes"
            ),
        ])
        try await store.rebuildMemorySegmentIndex()

        let requestedScope = try MemorySegmentScope(
            startDate: Date(timeIntervalSince1970: 101),
            endDate: Date(timeIntervalSince1970: 103)
        )
        let request = try MemorySegmentRequest(
            scope: requestedScope,
            retrievalModalities: [.savedText],
            limit: 10
        )
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        let segment = try #require(page.segments.first)
        let expected = [
            FrameID(rawValue: "inside-one"),
            FrameID(rawValue: "inside-two"),
        ]

        #expect(page.segments.count == 1)
        #expect(segment.frameIDs == expected)
        #expect(segment.scope.startDate == Date(timeIntervalSince1970: 101))
        #expect(segment.scope.endDate! <= Date(timeIntervalSince1970: 103))
        #expect(Set(segment.representativeEvidence.map(\.frameID)) == Set(expected))
        #expect(segment.representativeEvidence.allSatisfy {
            !$0.snippet.contains("private detail")
        })
        #expect(segment.modalityCoverage.allSatisfy { coverage in
            coverage.segmentFrameCount == expected.count
                && Set(coverage.coveredFrameIDs).isSubset(of: Set(expected))
                && coverage.provenance.allSatisfy {
                    Set($0.frameIDs).isSubset(of: Set(expected))
                }
        })
    }

    @Test("Segment FTS candidates cannot combine query terms from different frames")
    func exactFrameTextVerification() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "alpha-frame",
                time: 100,
                text: "alpha only",
                app: "Reader",
                bundle: "app.reader"
            ),
            Self.frame(
                id: "beta-frame",
                time: 101,
                text: "beta only",
                app: "Reader",
                bundle: "app.reader"
            ),
            Self.frame(
                id: "gamma-frame",
                time: 102,
                text: "gamma neighbor private detail",
                app: "Reader",
                bundle: "app.reader"
            ),
        ])
        try await store.rebuildMemorySegmentIndex()

        let falseCrossFrameMatch = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request(text: "alpha beta"))
        )
        #expect(falseCrossFrameMatch.segments.isEmpty)
        #expect(falseCrossFrameMatch.isComplete)

        let exactMatch = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request(text: "alpha"))
        )
        #expect(exactMatch.segments.count == 1)
        let segment = exactMatch.segments[0]
        #expect(segment.frameIDs == [FrameID(rawValue: "alpha-frame")])
        #expect(segment.representativeEvidence.map(\.frameID) == segment.frameIDs)
        #expect(segment.representativeEvidence.allSatisfy {
            $0.snippet.contains("alpha")
                && !$0.snippet.contains("beta")
                && !$0.snippet.contains("gamma")
        })
        #expect(segment.modalityCoverage.allSatisfy { coverage in
            coverage.segmentFrameCount == 1
                && coverage.coveredFrameIDs == segment.frameIDs
                && coverage.provenance.allSatisfy { $0.frameIDs == segment.frameIDs }
        })
    }

    @Test("Context keys and exact member scope keep website filters truthful")
    func contextAndScopeFiltering() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "one-a",
                time: 100,
                text: "shared browser evidence",
                app: "Browser",
                bundle: "app.browser",
                domain: "one.example"
            ),
            Self.frame(
                id: "two-a",
                time: 101,
                text: "shared browser evidence",
                app: "Browser",
                bundle: "app.browser",
                domain: "TWO.EXAMPLE"
            ),
            Self.frame(
                id: "native-a",
                time: 102,
                text: "shared native evidence",
                app: "Editor",
                bundle: "app.editor"
            ),
        ])
        try await store.rebuildMemorySegmentIndex()

        let scope = try MemorySegmentScope(domains: [" two.EXAMPLE "])
        let request = try MemorySegmentRequest(
            text: "shared",
            scope: scope,
            retrievalModalities: [.savedText],
            limit: 10
        )
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == false)
        #expect(page.segments.count == 1)
        #expect(page.segments[0].scope.domains == ["two.example"])
        #expect(page.segments[0].frameIDs == [FrameID(rawValue: "two-a")])

        try await store.insert(Self.frame(
            id: "two-b",
            time: 103,
            text: "shared browser evidence after rebuild",
            app: "Browser",
            bundle: "app.browser",
            domain: "two.example"
        ))
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == true)
        let overlaid = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(overlaid.segments.count == 1)
        #expect(overlaid.segments[0].scope.domains == ["two.example"])
        #expect(overlaid.segments[0].frameIDs == [
            FrameID(rawValue: "two-a"),
            FrameID(rawValue: "two-b"),
        ])
    }

    @Test("Unsupported visual and mixed-modality requests fail explicitly")
    func unsupportedVisualModalitiesAreNotPartiallyFulfilled() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "text-only",
            time: 100,
            text: "saved words",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()

        let mixed = try MemorySegmentRequest(
            text: "saved",
            scope: MemorySegmentScope(),
            retrievalModalities: [.savedText, .visualAppearance],
            limit: 10
        )
        let mixedPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(mixed)
        )
        #expect(mixedPage.segments.isEmpty)
        #expect(mixedPage.omissions == [
            MemorySegmentOmission(reason: .unavailableModality),
        ])

        let visualBrowse = try MemorySegmentRequest(
            scope: MemorySegmentScope(),
            retrievalModalities: [.visualAppearance],
            limit: 10
        )
        let visualPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(visualBrowse)
        )
        #expect(visualPage.segments.isEmpty)
        #expect(visualPage.omissions == [
            MemorySegmentOmission(reason: .unavailableModality),
        ])
    }

    @Test("An orphan accessibility hash never claims accessibility coverage")
    func orphanAccessibilityHashDoesNotClaimCoverage() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "orphaned-ax",
            time: 100,
            text: "canonical OCR remains available",
            app: "Notes",
            bundle: "app.notes"
        ))

        // Simulate a damaged legacy association. A hash alone is not evidence;
        // hydration must require the referenced encrypted snapshot to join.
        try Self.execute(
            """
            PRAGMA foreign_keys = OFF;
            UPDATE frames
            SET accessibility_snapshot_hash = zeroblob(32)
            WHERE id = 'orphaned-ax';
            PRAGMA foreign_keys = ON;
            """,
            on: store.connection.pointer
        )
        try await store.rebuildMemorySegmentIndex()

        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request(text: "canonical"))
        )
        let segment = try #require(page.segments.first)
        #expect(!segment.modalityCoverage.contains { $0.modality == .accessibility })
        #expect(segment.representativeEvidence.allSatisfy {
            !$0.modalities.contains(.accessibility)
        })
    }

    @Test("Agent privacy is checked for the current whole session before LIMIT")
    func authoritativeAgentPrivacyPrecedesLimit() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "older-safe",
                time: 1_000,
                text: "common evidence",
                app: "Mail",
                bundle: "app.mail"
            ),
            Self.frame(
                id: "newer-apparently-safe",
                time: 2_000,
                text: "common evidence",
                app: "Mail",
                bundle: "app.mail"
            ),
            Self.frame(
                id: "newer-private-neighbor",
                time: 2_001,
                text: "private evidence",
                app: "Passwords",
                bundle: "app.passwords",
                isSensitive: true
            ),
        ])
        try await store.rebuildMemorySegmentIndex()

        let request = try Self.request(text: "common", limit: 1)
        let privatePage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(privatePage.segments.count == 1)
        #expect(privatePage.segments[0].frameIDs == [
            FrameID(rawValue: "newer-apparently-safe"),
        ])
        #expect(privatePage.segments[0].containsSensitive)

        let agentPage = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(request)
        )
        #expect(agentPage.segments.count == 1)
        #expect(agentPage.segments[0].frameIDs == [FrameID(rawValue: "older-safe")])
        #expect(!agentPage.segments[0].containsSensitive)
        #expect(agentPage.omissions == [
            MemorySegmentOmission(reason: .policyFiltered),
        ])
        #expect(agentPage.omissions[0].count == nil)
    }

    @Test("A dirty session applies current whole-session privacy before paging")
    func dirtySessionAgentPrivacyIsCanonical() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "safe-first",
            time: 100,
            text: "shared public phrase",
            app: "Mail",
            bundle: "app.mail"
        ))
        try await store.rebuildMemorySegmentIndex()

        try await store.insert(Self.frame(
            id: "private-neighbor",
            time: 101,
            text: "secret only",
            app: "Passwords",
            bundle: "app.passwords",
            isSensitive: true
        ))
        // Defense in depth: even a damaged/stale materialized session marker
        // must not let a sensitive sibling leak through the dirty overlay.
        try Self.execute(
            "UPDATE activity_sessions SET contains_sensitive = 0 WHERE id = 'safe-first'",
            on: store.connection.pointer
        )
        #expect(try await store.memorySegmentIndexStatus()?.lifecycle == .ready)
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == true)

        let request = try Self.request(text: "shared", limit: 1)
        let privatePage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(privatePage.segments.count == 1)
        #expect(privatePage.segments[0].frameIDs == [FrameID(rawValue: "safe-first")])
        #expect(privatePage.segments[0].containsSensitive)

        let agentPage = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(request)
        )
        #expect(agentPage.segments.isEmpty)
        #expect(agentPage.omissions == [
            MemorySegmentOmission(reason: .policyFiltered),
        ])
        #expect(agentPage.omissions[0].count == nil)
    }

    @Test("Canonical append stays ready and overlays current lineage until rebuild")
    func appendStaysReadyAndUsesCanonicalOverlay() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "before",
            time: 100,
            text: "before rebuild",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        #expect(try await store.memorySegmentIndexStatus()?.lifecycle == .ready)

        try await store.insert(Self.frame(
            id: "after",
            time: 101,
            text: "after rebuild",
            app: "Notes",
            bundle: "app.notes"
        ))
        let queuedStatus = try await store.memorySegmentIndexStatus()
        #expect(queuedStatus?.lifecycle == .ready)
        #expect(queuedStatus?.hasPendingSessions == true)
        let overlaid = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(overlaid.isComplete)
        #expect(overlaid.segments.flatMap(\.frameIDs) == [
            FrameID(rawValue: "before"),
            FrameID(rawValue: "after"),
        ])

        try await store.rebuildMemorySegmentIndex()
        let rebuilt = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == false)
        #expect(rebuilt.segments.flatMap(\.frameIDs) == [
            FrameID(rawValue: "before"),
            FrameID(rawValue: "after"),
        ])
        #expect(rebuilt.segments == overlaid.segments)
        #expect(rebuilt.revision == overlaid.revision)
    }

    @Test("Bounded maintenance replaces one dirty session and cleans a deleted session")
    func boundedMaintenanceAndDeletedCleanup() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "session-first",
                time: 100,
                text: "first searchable",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "session-second",
                time: 101,
                text: "second searchable",
                app: "Notes",
                bundle: "app.notes"
            ),
        ])
        try await store.rebuildMemorySegmentIndex()
        try await store.insert(Self.frame(
            id: "session-third",
            time: 102,
            text: "third searchable",
            app: "Notes",
            bundle: "app.notes"
        ))
        let overlaid = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request(text: "searchable"))
        )

        let maintained = try await store.maintainNextMemorySegmentSession(maxFrames: 512)
        #expect(maintained == .maintained(ActivitySessionID(rawValue: "session-first")))
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == false)
        let indexed = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request(text: "searchable"))
        )
        #expect(indexed.segments == overlaid.segments)
        #expect(indexed.revision == overlaid.revision)

        _ = try await store.deleteFrames(from: nil, through: nil)
        let deletedOverlay = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(deletedOverlay.isComplete)
        #expect(deletedOverlay.segments.isEmpty)

        let cleaned = try await store.maintainNextMemorySegmentSession(maxFrames: 512)
        #expect(cleaned == .maintained(ActivitySessionID(rawValue: "session-first")))
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == false)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segments",
            on: store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE name = 'memory_segment_search'
            """,
            on: store.connection.pointer
        ) == 0)
    }

    @Test("Maintenance tolerates a retention split whose new session is repaired first")
    func retentionSplitMaintenanceAvoidsCrossSessionMemberConflicts() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "z-first",
                time: 100,
                text: "old surviving side",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "middle-one",
                time: 200,
                text: "delete one",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "middle-two",
                time: 300,
                text: "delete two",
                app: "Notes",
                bundle: "app.notes"
            ),
            Self.frame(
                id: "a-last",
                time: 400,
                text: "new surviving side",
                app: "Notes",
                bundle: "app.notes"
            ),
        ])
        try await store.rebuildMemorySegmentIndex()
        _ = try await store.deleteFrames(
            from: Date(timeIntervalSince1970: 150),
            through: Date(timeIntervalSince1970: 350)
        )
        try Self.execute(
            """
            UPDATE memory_segment_dirty_sessions
            SET first_enqueued_at = CASE activity_session_id
                WHEN 'a-last' THEN 0 ELSE 1 END
            """,
            on: store.connection.pointer
        )

        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .maintained(ActivitySessionID(rawValue: "a-last"))
        )
        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .maintained(ActivitySessionID(rawValue: "z-first"))
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == false)
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(Set(page.segments.flatMap(\.frameIDs)) == Set([
            FrameID(rawValue: "z-first"),
            FrameID(rawValue: "a-last"),
        ]))
        #expect(Set(page.segments.flatMap(\.frameIDs)).count == 2)
    }

    @Test("An oversized dirty-session overlay fails closed without hiding readiness")
    func oversizedDirtyOverlayIsIncomplete() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        let frameCount = MemorySegmentIndex.maximumOverlayFrameCount + 1
        try await store.insertBatch((0..<frameCount).map { index in
            Self.frame(
                id: String(format: "large-%04d", index),
                time: 1_000 + Double(index),
                text: "bounded overlay evidence \(index)",
                app: "Notes",
                bundle: "app.notes"
            )
        })
        try await store.rebuildMemorySegmentIndex()
        let targetID = "large-0000"
        let fingerprint = targetID.utf8.reduce(UInt64.zero) {
            $0 &+ UInt64($1)
        }
        _ = try await store.replaceOCR(
            for: FrameID(rawValue: targetID),
            expectedVisualFingerprint: fingerprint,
            text: "bounded overlay revised",
            regions: [
                OCRRegion(
                    text: "bounded overlay revised",
                    confidence: 0.99,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                ),
            ]
        )

        #expect(try await store.memorySegmentIndexStatus()?.lifecycle == .ready)
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions == [
            MemorySegmentOmission(reason: .incompleteIndex),
        ])
        #expect(!page.isComplete)
        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .deferred(
                    ActivitySessionID(rawValue: "large-0000"),
                    atLeastFrameCount: 513
                )
        )
    }

    @Test("An oversized FIFO head rotates so later bounded work progresses")
    func oversizedSessionDoesNotHeadOfLineBlockMaintenance() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        let oversizedCount = 513
        var frames = (0..<oversizedCount).map { index in
            Self.frame(
                id: String(format: "a-large-%03d", index),
                time: 1_000 + Double(index),
                text: "large evidence \(index)",
                app: "Notes",
                bundle: "app.notes"
            )
        }
        frames.append(Self.frame(
            id: "z-small",
            time: 2_000,
            text: "small evidence",
            app: "Mail",
            bundle: "app.mail"
        ))
        try await store.insertBatch(frames)
        try await store.rebuildMemorySegmentIndex()

        for id in ["a-large-000", "z-small"] {
            let fingerprint = id.utf8.reduce(UInt64.zero) { $0 &+ UInt64($1) }
            _ = try await store.replaceOCR(
                for: FrameID(rawValue: id),
                expectedVisualFingerprint: fingerprint,
                text: "revised \(id)",
                regions: [
                    OCRRegion(
                        text: "revised \(id)",
                        confidence: 0.99,
                        x: 0,
                        y: 0,
                        width: 1,
                        height: 1
                    ),
                ]
            )
        }

        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .deferred(
                    ActivitySessionID(rawValue: "a-large-000"),
                    atLeastFrameCount: oversizedCount
                )
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == true)
        #expect(try Self.scalarString(
            """
            SELECT activity_session_id
            FROM memory_segment_dirty_sessions
                 INDEXED BY memory_segment_dirty_sessions_order
            ORDER BY first_enqueued_at ASC, activity_session_id ASC
            LIMIT 1
            """,
            on: store.connection.pointer
        ) == "z-small")
        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .maintained(ActivitySessionID(rawValue: "z-small"))
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == true)
        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .deferred(
                    ActivitySessionID(rawValue: "a-large-000"),
                    atLeastFrameCount: oversizedCount
                )
        )
    }

    @Test("Maintenance selection uses bounded covering-index reads")
    func maintenanceSelectionQueryPlansStayBounded() throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()

        let selectionPlan = try Self.queryPlan(
            MemorySegmentIndex.nextDirtySessionSQL,
            on: store.connection.pointer
        )
        #expect(selectionPlan.contains {
            $0.contains("memory_segment_dirty_sessions_order")
        })
        #expect(!selectionPlan.contains { $0.contains("USE TEMP B-TREE") })

        let countPlan = try Self.queryPlan(
            MemorySegmentIndex.boundedMaintenanceFrameCountSQL,
            on: store.connection.pointer
        )
        #expect(countPlan.contains {
            $0.contains("frames_activity_session")
                && $0.contains("activity_session_id=?")
        })

        let dirtyFramePlan = try Self.queryPlan(
            MemorySegmentIndex.boundedDirtyMatchingFrameSQL(
                matchPredicate: "1 = 1"
            ),
            on: store.connection.pointer
        )
        #expect(dirtyFramePlan.contains {
            $0.contains("memory_segment_dirty_sessions_order")
                && $0.contains("generation_id=?")
        })
        #expect(dirtyFramePlan.contains {
            $0.contains("SEARCH frame")
                && $0.contains("frames_activity_session")
                && $0.contains("activity_session_id=?")
        })
        #expect(!dirtyFramePlan.contains { $0.contains("SCAN frame") })

        for sql in [
            MemorySegmentIndex.fastUnfilteredPrivateFirstPageSQL,
            MemorySegmentIndex.fastUnfilteredPrivateNextPageSQL,
        ] {
            let pagePlan = try Self.queryPlan(sql, on: store.connection.pointer)
            #expect(pagePlan.contains { $0.contains("memory_segments_order") })
            #expect(!pagePlan.contains { $0.contains("USE TEMP B-TREE") })
        }

        let contextPlan = try Self.queryPlan(
            """
            SELECT segment_key, id, ended_at
            FROM memory_segments
            WHERE generation_id = 1
              AND bundle_identifier = 'app.notes'
              AND normalized_domain = 'example.com'
            ORDER BY ended_at DESC, id DESC
            LIMIT 41
            """,
            on: store.connection.pointer
        )
        #expect(contextPlan.contains {
            $0.contains("memory_segments_context_order")
                && $0.contains("generation_id=?")
                && $0.contains("bundle_identifier=?")
                && $0.contains("normalized_domain=?")
        })
        #expect(!contextPlan.contains { $0.contains("USE TEMP B-TREE") })
    }

    @Test("A building-only state never exposes a partial shadow")
    func buildingGenerationFailsClosed() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "only",
            time: 100,
            text: "only evidence",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        try Self.execute(
            """
            INSERT INTO memory_segment_generations(
                build_nonce, lifecycle, revision, revision_is_current,
                canonical_frame_count, segment_count, built_at
            ) VALUES ('test-building-only', 'building', NULL, 0, 0, 0, NULL);
            UPDATE memory_segment_index_state
            SET active_generation_id = NULL,
                building_generation_id = last_insert_rowid()
            WHERE singleton = 1
            """,
            on: store.connection.pointer
        )

        let page = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(try Self.request())
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions.map(\.reason) == [.incompleteIndex])
        #expect(page.accessBoundary == .agentSafe)
    }

    @Test("A vault without segment readiness metadata is incomplete, not empty")
    func absentGenerationFailsClosed() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try Self.execute(
            "DROP TABLE memory_segment_index_state",
            on: store.connection.pointer
        )

        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions.map(\.reason) == [.incompleteIndex])
        #expect(!page.isComplete)
    }

    @Test("A read-only legacy vault without the dirty-session schema fails closed")
    func readOnlyLegacyQueueAbsenceIsIncomplete() async throws {
        let fixture = try MemorySegmentIndexFixture()
        var writer: SQLiteFrameStore? = try fixture.makeStore()
        try Self.execute(
            "DROP TABLE memory_segment_dirty_sessions",
            on: try #require(writer).connection.pointer
        )
        writer = nil

        let readOnly = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        let page = try await readOnly.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions.map(\.reason) == [.incompleteIndex])
        #expect(!page.isComplete)
    }

    @Test("Paging is stable and a queued canonical mutation rejects an old cursor")
    func cursorBindsRevision() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "a", time: 100, text: "page", app: "A", bundle: "app.a"),
            Self.frame(
                id: "a-neighbor",
                time: 100.1,
                text: "hidden neighbor",
                app: "A",
                bundle: "app.a"
            ),
            Self.frame(
                id: "b-first",
                time: 101,
                text: "page first",
                app: "B",
                bundle: "app.b"
            ),
            Self.frame(
                id: "b-middle",
                time: 101.04,
                text: "page middle original",
                app: "B",
                bundle: "app.b"
            ),
            Self.frame(
                id: "b-last",
                time: 101.08,
                text: "page last",
                app: "B",
                bundle: "app.b"
            ),
            Self.frame(
                id: "b-neighbor",
                time: 101.1,
                text: "hidden neighbor",
                app: "B",
                bundle: "app.b"
            ),
            Self.frame(id: "c", time: 102, text: "page", app: "C", bundle: "app.c"),
            Self.frame(
                id: "c-neighbor",
                time: 102.1,
                text: "hidden neighbor",
                app: "C",
                bundle: "app.c"
            ),
        ])
        try await store.rebuildMemorySegmentIndex()
        let firstRequest = try Self.request(text: "page", limit: 1)
        let first = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(firstRequest)
        )
        #expect(first.hasMore)
        #expect(first.segments.count == 1)
        #expect(first.segments[0].frameIDs.count == 1)
        let cursor = try #require(first.nextCursor)
        #expect(cursor.revision == first.revision)
        #expect(cursor.scopeFingerprint == first.scopeFingerprint)
        let secondRequest = try MemorySegmentRequest(
            text: "page",
            scope: firstRequest.scope,
            retrievalModalities: [.savedText],
            after: cursor,
            limit: 1
        )
        let second = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(secondRequest)
        )
        #expect(second.segments.count == 1)
        #expect(second.segments[0].frameIDs == [
            FrameID(rawValue: "b-first"),
            FrameID(rawValue: "b-middle"),
            FrameID(rawValue: "b-last"),
        ])
        #expect(second.segments[0].id != first.segments[0].id)
        #expect(second.revision == first.revision)

        // The middle match is not representative evidence. Its searchable
        // content must still participate in the page/cursor snapshot revision.
        try Self.execute(
            """
            UPDATE frames
            SET ocr_text = 'page middle revised'
            WHERE id = 'b-middle';
            UPDATE frame_search
            SET ocr_text = 'page middle revised'
            WHERE rowid = (SELECT rowid FROM frames WHERE id = 'b-middle');
            """,
            on: store.connection.pointer
        )
        await #expect(throws: MemorySegmentValidationError.cursorScopeMismatch) {
            try await store.retrievePrivateMemorySegments(
                PrivateMemorySegmentRequest(secondRequest)
            )
        }
    }

    @Test("Schema v4 is generation-qualified and covers every stable canonical frame key")
    func compactSchemaAndExactCoverage() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "coverage-a", time: 100, text: "one", app: "A", bundle: "app.a"),
            Self.frame(id: "coverage-b", time: 101, text: "two", app: "A", bundle: "app.a"),
        ])
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer

        #expect(try Self.scalarInt(
            "SELECT schema_version FROM memory_segment_index_state WHERE singleton = 1",
            on: database
        ) == 4)
        #expect(try Self.scalarInt(
            """
            SELECT generation.revision_is_current
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
            WHERE state.singleton = 1
            """,
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('memory_segments') WHERE name = 'payload'",
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'memory_segment_search%'",
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'index' AND tbl_name = 'memory_segment_members'
              AND name NOT LIKE 'sqlite_autoindex%'
            """,
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM frames WHERE frame_key IS NULL OR frame_key <= 0",
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*)
            FROM frames AS frame
            LEFT JOIN memory_segment_members AS member
              ON member.generation_id = (
                     SELECT active_generation_id
                     FROM memory_segment_index_state WHERE singleton = 1
                 )
             AND member.frame_key = frame.frame_key
            WHERE member.frame_key IS NULL
            """,
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check('memory_segment_members')",
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'trigger'
              AND name IN (
                  'visual_memory_segment_insert',
                  'visual_memory_segment_delete',
                  'visual_memory_segment_update',
                  'sessions_memory_segment_update'
              )
            """,
            on: database
        ) == 4)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'index' AND name = 'memory_segments_context_order'
            """,
            on: database
        ) == 1)
    }

    @Test("A v2 payload and duplicate FTS migrate atomically to empty v4")
    func v2MigrationRecreatesCompactShadow() throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        let database = store.connection.pointer
        try Self.execute(
            """
            DROP TRIGGER IF EXISTS frames_memory_segment_insert;
            DROP TRIGGER IF EXISTS frames_memory_segment_delete;
            DROP TRIGGER IF EXISTS frames_memory_segment_update;
            DROP TRIGGER IF EXISTS sessions_memory_segment_insert;
            DROP TRIGGER IF EXISTS sessions_memory_segment_delete;
            DROP TRIGGER IF EXISTS sessions_memory_segment_update;
            DROP TRIGGER IF EXISTS visual_memory_segment_insert;
            DROP TRIGGER IF EXISTS visual_memory_segment_delete;
            DROP TRIGGER IF EXISTS visual_memory_segment_update;
            DROP TABLE memory_segment_members;
            DROP TABLE memory_segments;
            DROP TABLE memory_segment_dirty_sessions;
            DROP TABLE memory_segment_index_state;
            DROP TABLE memory_segment_generations;
            CREATE TABLE memory_segment_index_state (
                singleton INTEGER PRIMARY KEY,
                schema_version INTEGER NOT NULL,
                lifecycle TEXT NOT NULL,
                revision TEXT,
                canonical_frame_count INTEGER NOT NULL,
                segment_count INTEGER NOT NULL,
                built_at REAL
            );
            INSERT INTO memory_segment_index_state
            VALUES (1, 2, 'ready', 'legacy-ready', 7, 2, 1);
            CREATE TABLE memory_segments (
                id TEXT PRIMARY KEY NOT NULL,
                revision_id TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE memory_segment_members (
                segment_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                frame_id TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE memory_segment_search USING fts5(
                segment_id UNINDEXED, searchable_text
            );
            """,
            on: database
        )

        try MemorySegmentIndex.migrate(on: database)

        #expect(try Self.scalarInt(
            "SELECT schema_version FROM memory_segment_index_state WHERE singleton = 1",
            on: database
        ) == 4)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id IS NULL FROM memory_segment_index_state WHERE singleton = 1",
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('memory_segments') WHERE name = 'payload'",
            on: database
        ) == 0)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'memory_segment_search%'",
            on: database
        ) == 0)
    }

    @Test("Stable frame keys backfill, advance direct inserts, and never reuse")
    func stableFrameKeySequenceAndFallback() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "key-seed",
            time: 100,
            text: "seed",
            app: "Notes",
            bundle: "app.notes"
        ))
        let database = store.connection.pointer
        let seedKey = try Self.scalarInt(
            "SELECT frame_key FROM frames WHERE id = 'key-seed'",
            on: database
        )
        try Self.execute(
            """
            INSERT INTO frames(
                id, captured_at, application_name, bundle_identifier, window_title,
                url, domain, display_id, window_id, window_x, window_y,
                window_width, window_height, ocr_text, ocr_regions, image_path,
                thumbnail_path, pixel_width, pixel_height, visual_fingerprint,
                change_score, is_sensitive, activity_session_id,
                accessibility_snapshot_hash
            )
            SELECT 'key-fallback', captured_at + 1, application_name,
                   bundle_identifier, window_title, url, domain, display_id,
                   window_id, window_x, window_y, window_width, window_height,
                   ocr_text, ocr_regions, image_path, thumbnail_path, pixel_width,
                   pixel_height, visual_fingerprint, change_score, is_sensitive,
                   activity_session_id, accessibility_snapshot_hash
            FROM frames WHERE id = 'key-seed';

            INSERT INTO frames(
                id, captured_at, application_name, bundle_identifier, window_title,
                url, domain, display_id, window_id, window_x, window_y,
                window_width, window_height, ocr_text, ocr_regions, image_path,
                thumbnail_path, pixel_width, pixel_height, visual_fingerprint,
                change_score, is_sensitive, activity_session_id,
                accessibility_snapshot_hash, frame_key
            )
            SELECT 'key-explicit', captured_at + 2, application_name,
                   bundle_identifier, window_title, url, domain, display_id,
                   window_id, window_x, window_y, window_width, window_height,
                   ocr_text, ocr_regions, image_path, thumbnail_path, pixel_width,
                   pixel_height, visual_fingerprint, change_score, is_sensitive,
                   activity_session_id, accessibility_snapshot_hash, 900000
            FROM frames WHERE id = 'key-seed';
            DELETE FROM frames WHERE id = 'key-explicit';
            """,
            on: database
        )
        let fallbackKey = try Self.scalarInt(
            "SELECT frame_key FROM frames WHERE id = 'key-fallback'",
            on: database
        )
        #expect(fallbackKey > seedKey)
        #expect(try Self.scalarInt(
            "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
            on: database
        ) > 900000)

        try await store.insert(Self.frame(
            id: "key-after-delete",
            time: 200,
            text: "after",
            app: "Notes",
            bundle: "app.notes"
        ))
        #expect(try Self.scalarInt(
            "SELECT frame_key FROM frames WHERE id = 'key-after-delete'",
            on: database
        ) > 900000)
        #expect(throws: PassageError.self) {
            try Self.execute(
                "UPDATE frames SET frame_key = frame_key + 1 WHERE id = 'key-seed'",
                on: database
            )
        }
        #expect(throws: PassageError.self) {
            try Self.execute(
                """
                INSERT INTO frames(
                    id, captured_at, application_name, ocr_text, ocr_regions,
                    image_path, pixel_width, pixel_height, visual_fingerprint,
                    change_score, frame_key
                ) SELECT 'key-invalid', captured_at + 3, application_name,
                         ocr_text, ocr_regions, image_path, pixel_width,
                         pixel_height, visual_fingerprint, change_score, 0
                  FROM frames WHERE id = 'key-seed'
                """,
                on: database
            )
        }
    }

    @Test("A first legacy frame-key backfill preserves positive rowids in one generation")
    func firstFrameKeyMigrationUsesLegacyRowIDs() async throws {
        let fixture = try MemorySegmentIndexFixture()
        var writer: SQLiteFrameStore? = try fixture.makeStore()
        try await writer?.insertBatch([
            Self.frame(id: "legacy-key-a", time: 100, text: "a", app: "A", bundle: "app.a"),
            Self.frame(id: "legacy-key-b", time: 101, text: "b", app: "A", bundle: "app.a"),
            Self.frame(id: "legacy-key-c", time: 102, text: "c", app: "A", bundle: "app.a"),
        ])
        let database = try #require(writer).connection.pointer
        try Self.execute(
            """
            DROP TABLE memory_segment_members;
            DROP TABLE memory_segments;
            DROP TRIGGER frames_assign_frame_key;
            DROP TRIGGER frames_advance_frame_key_sequence;
            DROP TRIGGER frames_reject_frame_key_update;
            DROP INDEX frames_frame_key;
            DROP TABLE frame_key_sequence;
            DELETE FROM store_metadata WHERE key = 'frame_key_schema_version';
            ALTER TABLE frames DROP COLUMN frame_key;
            """,
            on: database
        )
        writer = nil

        let migrated = try fixture.makeStore()
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM frames WHERE frame_key != rowid OR frame_key <= 0",
            on: migrated.connection.pointer
        ) == 0)
        let expectedNextKey = try Self.scalarInt(
            "SELECT COALESCE(MAX(rowid), 0) + 1 FROM frames",
            on: migrated.connection.pointer
        )
        #expect(try Self.scalarInt(
            "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
            on: migrated.connection.pointer
        ) == expectedNextKey)
    }

    @Test("A completed frame-key migration reopens cheaply and repairs only a stale sequence")
    func stableFrameKeyReopenRepairsSequence() async throws {
        let fixture = try MemorySegmentIndexFixture()
        var writer: SQLiteFrameStore? = try fixture.makeStore()
        try await writer?.insertBatch([
            Self.frame(id: "reopen-a", time: 100, text: "a", app: "A", bundle: "app.a"),
            Self.frame(id: "reopen-b", time: 101, text: "b", app: "A", bundle: "app.a"),
        ])
        let database = try #require(writer).connection.pointer
        let maximumKey = try Self.scalarInt(
            "SELECT MAX(frame_key) FROM frames",
            on: database
        )
        try Self.execute(
            "UPDATE frame_key_sequence SET next_key = 1 WHERE singleton = 1",
            on: database
        )
        writer = nil

        let reopened = try fixture.makeStore()
        #expect(try Self.scalarString(
            "SELECT value FROM store_metadata WHERE key = 'frame_key_schema_version'",
            on: reopened.connection.pointer
        ) == "1")
        #expect(try Self.scalarInt(
            "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
            on: reopened.connection.pointer
        ) == maximumKey + 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM frames WHERE frame_key IS NULL OR frame_key <= 0",
            on: reopened.connection.pointer
        ) == 0)
    }

    @Test("Descriptor paging hydrates only selected clean chunks")
    func pageBeforeHydrationIsBounded() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        var frames = [FrameDocument]()
        for index in 0..<128 {
            frames.append(Self.frame(
                id: String(format: "hydrate-%03d", index),
                time: 1_000 + Double(index),
                text: "hydration bound",
                app: index < 64 ? "Alpha" : "Zulu",
                bundle: index < 64 ? "app.alpha" : "app.zulu"
            ))
        }
        try await store.insertBatch(frames)
        try await store.rebuildMemorySegmentIndex()
        let firstRequest = try Self.request(text: "hydration", limit: 1)
        let first = try MemorySegmentIndex.retrieveMeasuringHydration(
            firstRequest,
            boundary: .privateLocal,
            on: store.connection.pointer
        )
        #expect(first.page.segments.count == 1)
        #expect(first.page.hasMore)
        #expect(first.hydratedCanonicalFrameCount == 64)
        let firstCursor = first.page.nextCursor
        #expect(firstCursor != nil)
        guard let firstCursor else { return }

        let secondRequest = try MemorySegmentRequest(
            text: "hydration",
            scope: firstRequest.scope,
            retrievalModalities: [.savedText],
            after: firstCursor,
            limit: 1
        )
        let second = try MemorySegmentIndex.retrieveMeasuringHydration(
            secondRequest,
            boundary: .privateLocal,
            on: store.connection.pointer
        )
        #expect(second.page.segments.count == 1)
        #expect(second.hydratedCanonicalFrameCount == 64)
        #expect(second.page.revision == first.page.revision)
    }

    @Test("A pristine private browse keysets directly and invalidates on every content mutation")
    func pristinePrivateBrowseUsesValidatedFastPath() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<130).map { index in
            Self.frame(
                id: String(format: "fast-%03d", index),
                time: 1_000 + Double(index),
                text: "fast page \(index)",
                app: "Notes",
                bundle: "app.notes"
            )
        })
        let rebuiltRevision = try await store.rebuildMemorySegmentIndex()
        #expect(try Self.scalarInt(
            """
            SELECT generation.revision_is_current
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
            WHERE state.singleton = 1
            """,
            on: store.connection.pointer
        ) == 1)

        let request = try Self.request(limit: 1)
        let first = try MemorySegmentIndex.retrieveMeasuringHydration(
            request,
            boundary: .privateLocal,
            on: store.connection.pointer
        )
        #expect(first.page.revision == rebuiltRevision)
        #expect(first.page.segments.count == 1)
        #expect(first.page.hasMore)
        #expect(first.hydratedCanonicalFrameCount <= MemorySegmentIndex.maximumFrameCount)
        let cursor = try #require(first.page.nextCursor)
        let secondRequest = try MemorySegmentRequest(
            scope: request.scope,
            retrievalModalities: [.savedText],
            after: cursor,
            limit: 1
        )
        let second = try MemorySegmentIndex.retrieveMeasuringHydration(
            secondRequest,
            boundary: .privateLocal,
            on: store.connection.pointer
        )
        #expect(second.page.segments.count == 1)
        #expect(second.page.revision == first.page.revision)
        #expect(second.hydratedCanonicalFrameCount <= MemorySegmentIndex.maximumFrameCount)

        let forgedCursor = try MemorySegmentCursor(
            token: String(
                format: "%016llx:%@",
                Double(999).bitPattern,
                "forged-segment"
            ),
            scopeFingerprint: request.cursorScopeFingerprint,
            revision: rebuiltRevision
        )
        let forgedRequest = try MemorySegmentRequest(
            scope: request.scope,
            retrievalModalities: [.savedText],
            after: forgedCursor,
            limit: 1
        )
        #expect(throws: MemorySegmentValidationError.cursorScopeMismatch) {
            try MemorySegmentIndex.retrieve(
                forgedRequest,
                boundary: .privateLocal,
                on: store.connection.pointer
            )
        }

        try Self.execute(
            "UPDATE frames SET visual_fingerprint = visual_fingerprint + 1 WHERE id = 'fast-000'",
            on: store.connection.pointer
        )
        #expect(try Self.scalarInt(
            """
            SELECT generation.revision_is_current
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
            WHERE state.singleton = 1
            """,
            on: store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT reason_mask & 4
            FROM memory_segment_dirty_sessions
            WHERE activity_session_id = 'fast-000'
            """,
            on: store.connection.pointer
        ) == 4)
        let dirtyPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .maintained(ActivitySessionID(rawValue: "fast-000"))
        )
        #expect(try Self.scalarInt(
            """
            SELECT generation.revision_is_current
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
            WHERE state.singleton = 1
            """,
            on: store.connection.pointer
        ) == 0)
        let maintainedPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(maintainedPage.segments == dirtyPage.segments)
        #expect(maintainedPage.revision == dirtyPage.revision)
    }

    @Test("A stable-key membership swap fails closed during selected hydration")
    func corruptedStableKeyMembershipFailsClosed() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "swap-a", time: 100, text: "swap", app: "A", bundle: "app.a"),
            Self.frame(id: "swap-b", time: 101, text: "swap", app: "A", bundle: "app.a"),
        ])
        try await store.rebuildMemorySegmentIndex()
        try Self.execute(
            """
            PRAGMA foreign_keys = OFF;
            UPDATE memory_segment_members SET frame_key = -1 WHERE ordinal = 0;
            UPDATE memory_segment_members
            SET frame_key = (SELECT frame_key FROM frames WHERE id = 'swap-a')
            WHERE ordinal = 1;
            UPDATE memory_segment_members
            SET frame_key = (SELECT frame_key FROM frames WHERE id = 'swap-b')
            WHERE frame_key = -1;
            PRAGMA foreign_keys = ON;
            """,
            on: store.connection.pointer
        )
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check('memory_segment_members')",
            on: store.connection.pointer
        ) == 0)
        await #expect(throws: Error.self) {
            try await store.retrievePrivateMemorySegments(
                PrivateMemorySegmentRequest(try Self.request())
            )
        }
    }

    @Test("Privacy mutations enqueue before agent-safe descriptor paging")
    func privacyMutationTriggersDirtyOverlay() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "privacy-trigger",
            time: 100,
            text: "shared phrase",
            app: "Mail",
            bundle: "app.mail"
        ))
        try await store.rebuildMemorySegmentIndex()
        try Self.execute(
            "UPDATE frames SET is_sensitive = 1 WHERE id = 'privacy-trigger'",
            on: store.connection.pointer
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == true)
        var page = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(try Self.request(text: "shared"))
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions == [MemorySegmentOmission(reason: .policyFiltered)])

        try Self.execute(
            "UPDATE frames SET is_sensitive = 0 WHERE id = 'privacy-trigger'",
            on: store.connection.pointer
        )
        _ = try await store.maintainNextMemorySegmentSession(maxFrames: 512)
        try Self.execute(
            "UPDATE activity_sessions SET contains_sensitive = 1 WHERE id = 'privacy-trigger'",
            on: store.connection.pointer
        )
        #expect(try await store.memorySegmentIndexStatus()?.hasPendingSessions == true)
        page = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(try Self.request(text: "shared"))
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions == [MemorySegmentOmission(reason: .policyFiltered)])
    }

    @Test("Whole-session privacy is identical across rebuild, dirty overlay, and maintenance")
    func staleSessionPrivacyAcrossMultipleChunks() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<65).map { index in
            Self.frame(
                id: String(format: "privacy-chunk-%02d", index),
                time: 1_000 + Double(index),
                text: index == 0 ? "clean-phase-target" : "neighbor \(index)",
                app: "Notes",
                bundle: "app.notes",
                isSensitive: index == 64
            )
        })
        // Damage only the denormalized marker. The authoritative sibling scan
        // must still classify every chunk in the session as private.
        try Self.execute(
            "UPDATE activity_sessions SET contains_sensitive = 0 WHERE id = 'privacy-chunk-00'",
            on: store.connection.pointer
        )
        try await store.rebuildMemorySegmentIndex()

        let cleanRequest = try Self.request(text: "clean-phase-target", limit: 1)
        let cleanPrivate = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(cleanRequest)
        )
        #expect(cleanPrivate.segments.count == 1)
        #expect(cleanPrivate.segments[0].containsSensitive)
        var agent = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(cleanRequest)
        )
        #expect(agent.segments.isEmpty)
        #expect(agent.omissions == [MemorySegmentOmission(reason: .policyFiltered)])

        try Self.execute(
            """
            UPDATE frames
            SET ocr_text = 'dirty-phase-target'
            WHERE id = 'privacy-chunk-00';
            UPDATE frame_search
            SET ocr_text = 'dirty-phase-target'
            WHERE frame_id = 'privacy-chunk-00';
            """,
            on: store.connection.pointer
        )
        let dirtyRequest = try Self.request(text: "dirty-phase-target", limit: 1)
        let dirtyPrivate = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(dirtyRequest)
        )
        #expect(dirtyPrivate.segments.count == 1)
        #expect(dirtyPrivate.segments[0].containsSensitive)
        agent = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(dirtyRequest)
        )
        #expect(agent.segments.isEmpty)
        #expect(agent.omissions == [MemorySegmentOmission(reason: .policyFiltered)])

        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .maintained(ActivitySessionID(rawValue: "privacy-chunk-00"))
        )
        let maintainedPrivate = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(dirtyRequest)
        )
        #expect(maintainedPrivate.segments == dirtyPrivate.segments)
        #expect(maintainedPrivate.revision == dirtyPrivate.revision)
        agent = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(dirtyRequest)
        )
        #expect(agent.segments.isEmpty)
        #expect(agent.omissions == [MemorySegmentOmission(reason: .policyFiltered)])
    }

    @Test("A missing materialized session stays private-readable and agent-hidden everywhere")
    func missingSessionPrivacyParity() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "missing-session",
            time: 100,
            text: "orphan session evidence",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        try Self.execute(
            "DELETE FROM activity_sessions WHERE id = 'missing-session'",
            on: store.connection.pointer
        )
        let request = try Self.request(text: "orphan")

        let dirtyPrivate = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(dirtyPrivate.segments.count == 1)
        #expect(dirtyPrivate.segments[0].containsSensitive)
        var agent = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(request)
        )
        #expect(agent.segments.isEmpty)
        #expect(agent.omissions == [MemorySegmentOmission(reason: .policyFiltered)])

        #expect(
            try await store.maintainNextMemorySegmentSession(maxFrames: 512)
                == .maintained(ActivitySessionID(rawValue: "missing-session"))
        )
        let maintainedPrivate = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(maintainedPrivate.segments == dirtyPrivate.segments)
        #expect(maintainedPrivate.revision == dirtyPrivate.revision)
        agent = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(request)
        )
        #expect(agent.segments.isEmpty)

        try await store.rebuildMemorySegmentIndex()
        let rebuiltPrivate = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(request)
        )
        #expect(rebuiltPrivate.segments == dirtyPrivate.segments)
        #expect(rebuiltPrivate.revision == dirtyPrivate.revision)
        agent = try await store.retrieveAgentSafeMemorySegments(
            AgentSafeMemorySegmentRequest(request)
        )
        #expect(agent.segments.isEmpty)
        #expect(agent.omissions == [MemorySegmentOmission(reason: .policyFiltered)])
    }

    @Test("A ready v3 shadow migrates atomically as active generation 1")
    func readyV3MigratesAsGenerationOne() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "v3-a", time: 100, text: "legacy one", app: "A", bundle: "app.a"),
            Self.frame(id: "v3-b", time: 101, text: "legacy two", app: "B", bundle: "app.b"),
        ])
        try await store.rebuildMemorySegmentIndex()
        let before = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        let database = store.connection.pointer
        try Self.installLegacyV3Snapshot(fromActiveIn: database)
        try Self.execute(
            "CREATE TABLE memory_segment_generations(stale INTEGER)",
            on: database
        )

        try MemorySegmentIndex.migrate(on: database)

        #expect(try Self.scalarInt(
            "SELECT schema_version FROM memory_segment_index_state WHERE singleton = 1",
            on: database
        ) == 4)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state WHERE singleton = 1",
            on: database
        ) == 1)
        #expect(try Self.scalarString(
            "SELECT lifecycle FROM memory_segment_generations WHERE generation_id = 1",
            on: database
        ) == "ready")
        #expect(try Self.scalarString(
            "SELECT build_nonce FROM memory_segment_generations WHERE generation_id = 1",
            on: database
        ) == "migrated-v3-generation-1")
        #expect(try Self.scalarInt(
            "SELECT COUNT(DISTINCT generation_id) FROM memory_segments",
            on: database
        ) == 1)
        let after = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(after.segments == before.segments)
        #expect(after.revision == before.revision)
    }

    @Test("A ready v3 shadow with a dirty overlay remains readable after migration")
    func readyDirtyV3MigrationPreservesCanonicalOverlay() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "v3-dirty",
            time: 100,
            text: "legacy phrase",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        try Self.execute(
            """
            UPDATE frames SET ocr_text = 'current migrated phrase'
            WHERE id = 'v3-dirty';
            UPDATE frame_search SET ocr_text = 'current migrated phrase'
            WHERE frame_id = 'v3-dirty';
            """,
            on: database
        )
        try Self.installLegacyV3Snapshot(fromActiveIn: database)

        try MemorySegmentIndex.migrate(on: database)

        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = 1 AND activity_session_id = 'v3-dirty'
            """,
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT revision_is_current FROM memory_segment_generations WHERE generation_id = 1",
            on: database
        ) == 0)
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request(text: "current migrated"))
        )
        #expect(page.isComplete)
        #expect(page.segments.flatMap(\.frameIDs) == [FrameID(rawValue: "v3-dirty")])
    }

    @Test("A corrupt ready v3 shadow is discarded fail-closed")
    func corruptReadyV3MigrationIsDiscarded() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "v3-corrupt",
            time: 100,
            text: "corrupt",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        try Self.installLegacyV3Snapshot(fromActiveIn: database)
        try Self.execute("DELETE FROM memory_segment_members", on: database)

        try MemorySegmentIndex.migrate(on: database)

        #expect(try Self.scalarInt(
            "SELECT active_generation_id IS NULL FROM memory_segment_index_state",
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segment_generations",
            on: database
        ) == 0)
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(page.omissions.map(\.reason) == [.incompleteIndex])
    }

    @Test("A v3 frame without a materialized session is discarded fail-closed")
    func nullableSessionV3MigrationIsDiscarded() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "v3-null-session",
            time: 100,
            text: "orphan",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        try Self.installLegacyV3Snapshot(fromActiveIn: database)
        try Self.execute(
            "UPDATE frames SET activity_session_id = NULL WHERE id = 'v3-null-session'",
            on: database
        )

        try MemorySegmentIndex.migrate(on: database)

        #expect(try Self.scalarInt(
            "SELECT active_generation_id IS NULL FROM memory_segment_index_state",
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segment_generations",
            on: database
        ) == 0)
    }

    @Test("Partial and wrong-shape v3 shadows do not block v4 startup")
    func malformedV3MigrationStartsEmpty() async throws {
        for damage in ["missing", "wrong-column", "null-built-at"] {
            let fixture = try MemorySegmentIndexFixture()
            let store = try fixture.makeStore()
            try await store.insert(Self.frame(
                id: "v3-\(damage)",
                time: 100,
                text: damage,
                app: "Notes",
                bundle: "app.notes"
            ))
            try await store.rebuildMemorySegmentIndex()
            let database = store.connection.pointer
            try Self.installLegacyV3Snapshot(fromActiveIn: database)
            if damage == "missing" {
                try Self.execute("DROP TABLE memory_segment_members", on: database)
            } else if damage == "wrong-column" {
                try Self.execute(
                    "ALTER TABLE memory_segments ADD COLUMN unexpected TEXT",
                    on: database
                )
            } else {
                try Self.execute(
                    "UPDATE memory_segment_index_state SET built_at = NULL",
                    on: database
                )
            }

            try MemorySegmentIndex.migrate(on: database)

            #expect(try Self.scalarInt(
                "SELECT schema_version FROM memory_segment_index_state",
                on: database
            ) == 4)
            #expect(try Self.scalarInt(
                "SELECT active_generation_id IS NULL FROM memory_segment_index_state",
                on: database
            ) == 1)
        }
    }

    @Test("A malformed state table without schema metadata starts empty v4")
    func stateWithoutSchemaVersionDoesNotBlockMigration() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "missing-schema-version",
            time: 100,
            text: "malformed state",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        try Self.installLegacyV3Snapshot(fromActiveIn: database)
        try Self.execute(
            """
            DROP TABLE memory_segment_index_state;
            CREATE TABLE memory_segment_index_state(
                singleton INTEGER PRIMARY KEY,
                legacy_state TEXT
            );
            INSERT INTO memory_segment_index_state VALUES (1, 'unknown');
            """,
            on: database
        )

        try MemorySegmentIndex.migrate(on: database)

        #expect(try Self.scalarInt(
            "SELECT schema_version FROM memory_segment_index_state",
            on: database
        ) == 4)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id IS NULL FROM memory_segment_index_state",
            on: database
        ) == 1)
    }

    @Test("Canonical mutations enqueue both active and building generations")
    func mutationDualEnqueuesActiveAndBuilding() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "dual-enqueue",
            time: 100,
            text: "before",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        let active = try Self.activeGenerationID(on: database)
        let building = try Self.installBuildingGeneration(on: database)

        try Self.execute(
            "UPDATE frames SET ocr_text = 'after' WHERE id = 'dual-enqueue'",
            on: database
        )

        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE activity_session_id = 'dual-enqueue'
              AND generation_id IN (\(active), \(building))
            """,
            on: database
        ) == 2)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_generations
            WHERE generation_id IN (\(active), \(building))
              AND revision_is_current = 0
            """,
            on: database
        ) == 2)
    }

    @Test("An unmaterialized canonical session retires every readable generation")
    func nullableSessionMutationFailsClosed() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "null-session",
            time: 100,
            text: "before",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        let active = try Self.activeGenerationID(on: database)
        let building = try Self.installBuildingGeneration(on: database)

        try Self.execute(
            "UPDATE frames SET activity_session_id = NULL WHERE id = 'null-session'",
            on: database
        )

        #expect(try Self.scalarInt(
            """
            SELECT active_generation_id IS NULL AND building_generation_id IS NULL
            FROM memory_segment_index_state
            """,
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_generations
            WHERE generation_id IN (\(active), \(building))
              AND lifecycle = 'retired'
            """,
            on: database
        ) == 2)
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(page.segments.isEmpty)
        #expect(page.omissions.map(\.reason) == [.incompleteIndex])
    }

    @Test("A partial building generation never mixes into an active page")
    func retrievalNeverMixesGenerations() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "active-only",
            time: 100,
            text: "active evidence",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        let active = try Self.activeGenerationID(on: database)
        let building = try Self.installBuildingGeneration(on: database)
        try Self.execute(
            """
            INSERT INTO memory_segments(
                generation_id, id, revision_id, search_content_revision,
                started_at, ended_at, bundle_identifier, normalized_domain,
                activity_session_id, chunk_ordinal, frame_count, contains_sensitive
            ) VALUES (
                \(building), 'building-only-segment', 'building-revision',
                'building-search', 999, 1000, 'app.fake', '',
                'building-session', 0, 1, 0
            );
            """,
            on: database
        )

        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(page.segments.flatMap(\.frameIDs) == [FrameID(rawValue: "active-only")])
        #expect(try await store.memorySegmentIndexStatus()?.generationID == active)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segments WHERE generation_id = \(building)",
            on: database
        ) == 1)
    }

    @Test("The active generation remains readable while another generation builds")
    func activeGenerationReadsDuringBuilding() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "read-during-build",
            time: 100,
            text: "stable active evidence",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let before = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        _ = try Self.installBuildingGeneration(on: store.connection.pointer)

        let status = try await store.memorySegmentIndexStatus()
        let during = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(status?.lifecycle == .ready)
        #expect(during.segments == before.segments)
        #expect(during.revision == before.revision)
        #expect(during.omissions.isEmpty)
    }

    @Test("A rebuild atomically swaps generations and retires the old active")
    func rebuildAtomicallySwapsGenerationPointers() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "swap-old",
            time: 100,
            text: "old",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await store.rebuildMemorySegmentIndex()
        let database = store.connection.pointer
        let oldActive = try Self.activeGenerationID(on: database)
        try await store.insert(Self.frame(
            id: "swap-new",
            time: 101,
            text: "new",
            app: "Notes",
            bundle: "app.notes"
        ))

        try await store.rebuildMemorySegmentIndex()

        let newActive = try Self.activeGenerationID(on: database)
        #expect(newActive != oldActive)
        #expect(try Self.scalarString(
            "SELECT lifecycle FROM memory_segment_generations WHERE generation_id = \(oldActive)",
            on: database
        ) == "retired")
        #expect(try Self.scalarString(
            "SELECT lifecycle FROM memory_segment_generations WHERE generation_id = \(newActive)",
            on: database
        ) == "ready")
        #expect(try Self.scalarInt(
            "SELECT building_generation_id IS NULL FROM memory_segment_index_state",
            on: database
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segments WHERE generation_id = \(oldActive)",
            on: database
        ) > 0)
        let page = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(Set(page.segments.flatMap(\.frameIDs)) == Set([
            FrameID(rawValue: "swap-old"), FrameID(rawValue: "swap-new"),
        ]))
    }

    @Test("An established reader snapshot stays on G1 across G2 activation")
    func readerSnapshotPinsOneActiveGeneration() async throws {
        let fixture = try MemorySegmentIndexFixture()
        let writer = try fixture.makeStore()
        try await writer.insert(Self.frame(
            id: "snapshot-old",
            time: 100,
            text: "old",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await writer.rebuildMemorySegmentIndex()
        let reader = try fixture.makeStore()
        let readerDatabase = reader.connection.pointer
        try Self.execute("BEGIN DEFERRED", on: readerDatabase)
        let g1 = try #require(MemorySegmentIndex.status(on: readerDatabase)?.generationID)
        try await writer.insert(Self.frame(
            id: "snapshot-new",
            time: 101,
            text: "new",
            app: "Notes",
            bundle: "app.notes"
        ))
        try await writer.rebuildMemorySegmentIndex()
        let writerStatus = try await writer.memorySegmentIndexStatus()
        let writerG2 = try #require(writerStatus?.generationID)

        let readerStillG1 = try #require(
            MemorySegmentIndex.status(on: readerDatabase)?.generationID
        )
        #expect(readerStillG1 == g1)
        #expect(writerG2 != g1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segments WHERE generation_id = \(g1)",
            on: readerDatabase
        ) > 0)
        try Self.execute("COMMIT", on: readerDatabase)
        #expect(try MemorySegmentIndex.status(on: readerDatabase)?.generationID == writerG2)
    }

    private static func activeGenerationID(on database: OpaquePointer) throws -> Int64 {
        try scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state WHERE singleton = 1",
            on: database
        )
    }

    @discardableResult
    private static func installBuildingGeneration(
        on database: OpaquePointer
    ) throws -> Int64 {
        let nonce = "test-building-\(UUID().uuidString.lowercased())"
        try execute(
            """
            INSERT INTO memory_segment_generations(
                build_nonce, lifecycle, revision, revision_is_current,
                canonical_frame_count, segment_count, built_at
            ) VALUES ('\(nonce)', 'building', NULL, 0, 0, 0, NULL);
            UPDATE memory_segment_index_state
            SET building_generation_id = last_insert_rowid()
            WHERE singleton = 1;
            """,
            on: database
        )
        return try scalarInt(
            "SELECT building_generation_id FROM memory_segment_index_state",
            on: database
        )
    }

    /// Reconstructs the exact v3 table shape from the currently active v4
    /// generation so migration tests exercise a real, fully populated shadow.
    private static func installLegacyV3Snapshot(
        fromActiveIn database: OpaquePointer
    ) throws {
        try execute(
            """
            DROP TRIGGER IF EXISTS frames_memory_segment_insert;
            DROP TRIGGER IF EXISTS frames_memory_segment_delete;
            DROP TRIGGER IF EXISTS frames_memory_segment_update;
            DROP TRIGGER IF EXISTS sessions_memory_segment_insert;
            DROP TRIGGER IF EXISTS sessions_memory_segment_delete;
            DROP TRIGGER IF EXISTS sessions_memory_segment_update;
            DROP TRIGGER IF EXISTS visual_memory_segment_insert;
            DROP TRIGGER IF EXISTS visual_memory_segment_delete;
            DROP TRIGGER IF EXISTS visual_memory_segment_update;

            CREATE TABLE memory_segment_index_state_v3_fixture (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                schema_version INTEGER NOT NULL,
                lifecycle TEXT NOT NULL,
                revision TEXT,
                revision_is_current INTEGER NOT NULL DEFAULT 0,
                canonical_frame_count INTEGER NOT NULL DEFAULT 0,
                segment_count INTEGER NOT NULL DEFAULT 0,
                built_at REAL
            );
            CREATE TABLE memory_segments_v3_fixture (
                segment_key INTEGER PRIMARY KEY NOT NULL,
                id TEXT NOT NULL UNIQUE,
                revision_id TEXT NOT NULL,
                search_content_revision TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                bundle_identifier TEXT NOT NULL,
                normalized_domain TEXT NOT NULL,
                activity_session_id TEXT NOT NULL,
                chunk_ordinal INTEGER NOT NULL,
                frame_count INTEGER NOT NULL,
                contains_sensitive INTEGER NOT NULL,
                UNIQUE(
                    activity_session_id, bundle_identifier,
                    normalized_domain, chunk_ordinal
                )
            );
            CREATE TABLE memory_segment_members_v3_fixture (
                frame_key INTEGER PRIMARY KEY NOT NULL,
                segment_key INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                UNIQUE(segment_key, ordinal),
                FOREIGN KEY(frame_key) REFERENCES frames(frame_key)
                    ON DELETE CASCADE ON UPDATE RESTRICT,
                FOREIGN KEY(segment_key)
                    REFERENCES memory_segments_v3_fixture(segment_key)
                    ON DELETE CASCADE ON UPDATE RESTRICT
            );
            CREATE TABLE memory_segment_dirty_sessions_v3_fixture (
                activity_session_id TEXT PRIMARY KEY NOT NULL,
                dirty_version INTEGER NOT NULL,
                reason_mask INTEGER NOT NULL,
                first_enqueued_at REAL NOT NULL,
                last_enqueued_at REAL NOT NULL
            ) WITHOUT ROWID;

            INSERT INTO memory_segment_index_state_v3_fixture
            SELECT 1, 3, generation.lifecycle, generation.revision,
                   generation.revision_is_current,
                   generation.canonical_frame_count, generation.segment_count,
                   generation.built_at
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
            WHERE state.singleton = 1;
            INSERT INTO memory_segments_v3_fixture
            SELECT segment_key, id, revision_id, search_content_revision,
                   started_at, ended_at, bundle_identifier, normalized_domain,
                   activity_session_id, chunk_ordinal, frame_count, contains_sensitive
            FROM memory_segments
            WHERE generation_id = (
                SELECT active_generation_id FROM memory_segment_index_state
                WHERE singleton = 1
            );
            INSERT INTO memory_segment_members_v3_fixture
            SELECT frame_key, segment_key, ordinal
            FROM memory_segment_members
            WHERE generation_id = (
                SELECT active_generation_id FROM memory_segment_index_state
                WHERE singleton = 1
            );
            INSERT INTO memory_segment_dirty_sessions_v3_fixture
            SELECT activity_session_id, dirty_version, reason_mask,
                   first_enqueued_at, last_enqueued_at
            FROM memory_segment_dirty_sessions
            WHERE generation_id = (
                SELECT active_generation_id FROM memory_segment_index_state
                WHERE singleton = 1
            );

            DROP TABLE memory_segment_members;
            DROP TABLE memory_segments;
            DROP TABLE memory_segment_dirty_sessions;
            DROP TABLE memory_segment_index_state;
            DROP TABLE memory_segment_generations;
            ALTER TABLE memory_segments_v3_fixture RENAME TO memory_segments;
            ALTER TABLE memory_segment_members_v3_fixture
                RENAME TO memory_segment_members;
            ALTER TABLE memory_segment_dirty_sessions_v3_fixture
                RENAME TO memory_segment_dirty_sessions;
            ALTER TABLE memory_segment_index_state_v3_fixture
                RENAME TO memory_segment_index_state;
            """,
            on: database
        )
    }

    private static func request(
        text: String = "",
        limit: Int = 40
    ) throws -> MemorySegmentRequest {
        try MemorySegmentRequest(
            text: text,
            scope: MemorySegmentScope(),
            retrievalModalities: [.savedText],
            limit: limit
        )
    }

    private static func frame(
        id: String,
        time: Double,
        text: String,
        app: String,
        bundle: String?,
        domain: String? = nil,
        isSensitive: Bool = false
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: "\(app) window",
                url: domain.flatMap { URL(string: "https://\($0)/\(id)") },
                domain: domain,
                isSensitive: isSensitive
            ),
            ocrText: text,
            ocrRegions: [
                OCRRegion(text: text, confidence: 0.99, x: 0, y: 0, width: 1, height: 1),
            ],
            imageRelativePath: "Media/\(id).jpg",
            thumbnailRelativePath: "Thumbnails/\(id).jpg",
            pixelWidth: 1_280,
            pixelHeight: 720,
            visualFingerprint: id.utf8.reduce(UInt64.zero) { $0 &+ UInt64($1) },
            changeScore: 0.5
        )
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw PassageError.database(detail)
        }
    }

    private static func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func scalarString(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private static func queryPlan(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "EXPLAIN QUERY PLAN \(sql)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var details = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let detail = sqlite3_column_text(statement, 3) else { continue }
            details.append(String(cString: detail))
        }
        return details
    }
}

private final class MemorySegmentIndexFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "passage-memory-segment-index-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(
            bytes: Data(repeating: 0x6d, count: VaultKey.byteCount)
        )
        try paths.createDirectories()
    }

    func makeStore() throws -> SQLiteFrameStore {
        try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
