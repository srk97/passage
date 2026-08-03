import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Agent-safe frame resolution", .serialized)
struct AgentSafeFrameResolutionTests {
    @Test("Batch resolution preserves first-occurrence order and removes duplicates")
    func orderAndDeduplication() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let first = Self.frame(id: "first", time: 100)
        let second = Self.frame(id: "second", time: 500)
        let third = Self.frame(id: "third", time: 900, withAccessibility: true)
        try await store.insertBatch([first, second, third])

        let evidence = try await store.agentSafeFrames(ids: [
            third.id,
            first.id,
            third.id,
            FrameID(rawValue: "missing"),
            second.id,
            first.id,
        ])

        #expect(evidence.map(\.frame.id.rawValue) == ["third", "first", "second"])
        #expect(evidence.map(\.activitySessionID.rawValue) == ["third", "first", "second"])
        #expect(evidence.first?.frame.accessibilitySnapshot?.nodes.first?.label == "Remembered control")
        #expect(try await store.agentSafeFrame(id: third.id) == evidence.first)
    }

    @Test("Search-hit resolution preserves first-occurrence order without paths or omission gaps")
    func searchHitOrderDeduplicationAndProjection() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let first = Self.frame(id: "search-first", time: 100)
        let second = Self.frame(id: "search-second", time: 500)
        let third = Self.frame(id: "search-third", time: 900)
        try await store.insertBatch([first, second, third])

        let hits = try await store.agentSafeSearchHits(
            ids: [
                third.id,
                FrameID(rawValue: "missing-before-first"),
                first.id,
                third.id,
                FrameID(rawValue: "missing-before-second"),
                second.id,
                first.id,
            ],
            matching: SearchQuery(limit: 1)
        )

        #expect(hits.map(\.id.rawValue) == ["search-third", "search-first", "search-second"])
        #expect(hits.map(\.activitySessionID?.rawValue) == [
            "search-third", "search-first", "search-second",
        ])
        #expect(hits.allSatisfy { $0.imageRelativePath.isEmpty })
        #expect(hits.allSatisfy { $0.thumbnailRelativePath == nil })
        #expect(hits.allSatisfy { !$0.context.isSensitive })
    }

    @Test("Search-hit raw requests are capped before SQL deduplication")
    func searchHitRequestCapBeforeDeduplication() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let repeated = Array(
            repeating: FrameID(rawValue: "one-duplicated-id"),
            count: SQLiteFrameStore.maximumAgentSafeFrameRequestCount + 1
        )

        do {
            _ = try await store.agentSafeSearchHits(
                ids: repeated,
                matching: SearchQuery()
            )
            Issue.record("An oversized raw search-hit window must be rejected.")
        } catch PassageError.invalidQuery(let message) {
            #expect(message.contains(String(SQLiteFrameStore.maximumAgentSafeFrameRequestCount)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let atCap = Array(
            repeating: FrameID(rawValue: "one-duplicated-id"),
            count: SQLiteFrameStore.maximumAgentSafeFrameRequestCount
        )
        #expect(try await store.agentSafeSearchHits(
            ids: atCap,
            matching: SearchQuery()
        ).isEmpty)
    }

    @Test("Search-hit SQL is driven by an ordered requested-ID CTE")
    func searchHitQueryShape() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let query = SearchQuery(
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 900),
            applicationBundleIdentifiers: ["com.apple.Notes"],
            domains: ["docs.example"],
            activitySessionIDs: [ActivitySessionID(rawValue: "session")]
        )
        let productionSQL = SQLiteFrameStore.agentSafeSearchHitsSQL(
            requestCount: 3,
            query: query
        )
        let plan = try Self.explain(
            "EXPLAIN QUERY PLAN " + productionSQL,
            on: store.connection.pointer
        )

        #expect(productionSQL.contains(
            "WITH requested(frame_id, ordinal) AS (\n    VALUES (?, 0), (?, 1), (?, 2)"
        ))
        #expect(productionSQL.contains("SELECT frame_id, MIN(ordinal)"))
        #expect(plan.contains { $0.contains("CONSTANT ROWS") })
        #expect(plan.contains { $0.contains("SEARCH f USING INDEX") && $0.contains("id=?") })
        #expect(plan.contains { $0.contains("SEARCH safe_session USING INDEX") })
        #expect(plan.contains {
            $0.contains("SEARCH sensitive_session_frame USING INDEX frames_activity_session")
        })
        #expect(!plan.contains { $0 == "SCAN f" || $0.hasPrefix("SCAN f ") })
        #expect(!plan.contains { $0.contains("SCAN safe_session") })

        var textQuery = query
        textQuery.text = "Currentcobalt"
        let textPlan = try Self.explain(
            "EXPLAIN QUERY PLAN " + SQLiteFrameStore.agentSafeSearchHitsSQL(
                requestCount: 3,
                query: textQuery
            ),
            on: store.connection.pointer
        )
        let requestedIndex = try #require(textPlan.firstIndex {
            $0 == "SCAN first_requested"
        })
        let frameIndex = try #require(textPlan.firstIndex {
            $0.contains("SEARCH f USING INDEX") && $0.contains("id=?")
        })
        let searchIndex = try #require(textPlan.firstIndex {
            $0.contains("frame_search VIRTUAL TABLE INDEX")
        })
        #expect(requestedIndex < frameIndex)
        #expect(frameIndex < searchIndex)
        #expect(textPlan[searchIndex].contains(":="))
    }

    @Test("Search-hit resolution omits stale materialized privacy and missing sessions")
    func searchHitWholeSessionPrivacyFailsClosed() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let privateFrame = Self.frame(id: "search-private", time: 100, isSensitive: true)
        let ordinaryPeer = Self.frame(id: "search-ordinary-peer", time: 200)
        let safe = Self.frame(id: "search-safe", time: 600)
        let orphaned = Self.frame(id: "search-orphaned", time: 1_000)
        try await store.insertBatch([privateFrame, ordinaryPeer, safe, orphaned])

        // Force the summary stale-safe; the resolver must still inspect the
        // authoritative sibling frames before disclosing the ordinary peer.
        try Self.execute(
            """
            UPDATE activity_sessions
            SET contains_sensitive = 0
            WHERE id = (
                SELECT activity_session_id FROM frames WHERE id = 'search-ordinary-peer'
            )
            """,
            on: store.connection.pointer
        )
        try Self.execute(
            """
            DELETE FROM activity_sessions
            WHERE id = (
                SELECT activity_session_id FROM frames WHERE id = 'search-orphaned'
            )
            """,
            on: store.connection.pointer
        )

        let hits = try await store.agentSafeSearchHits(
            ids: [ordinaryPeer.id, orphaned.id, privateFrame.id, safe.id],
            matching: SearchQuery()
        )
        #expect(hits.map(\.id.rawValue) == ["search-safe"])
    }

    @Test("Search-hit resolution reapplies current text, time, app, domain, and session scope")
    func searchHitReappliesCurrentQuery() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let frame = Self.frame(
            id: "scope-candidate",
            time: 500,
            text: "Legacycobalt evidence",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            domain: "docs.example"
        )
        try await store.insert(frame)
        #expect(try await store.search(
            SearchQuery(text: "Legacycobalt")
        ).map(\.id) == [frame.id])

        _ = try #require(await store.replaceOCR(
            for: frame.id,
            expectedVisualFingerprint: frame.visualFingerprint,
            text: "Currentcobalt evidence",
            regions: [
                OCRRegion(
                    text: "Currentcobalt evidence",
                    confidence: 0.99,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                ),
            ]
        ))
        let sessionID = try #require(
            await store.agentSafeFrame(id: frame.id)?.activitySessionID
        )

        #expect(try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(text: "Legacycobalt")
        ).isEmpty)
        #expect(try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(applicationBundleIdentifiers: ["com.apple.Safari"])
        ).isEmpty)
        #expect(try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(domains: ["other.example"])
        ).isEmpty)
        #expect(try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(
                activitySessionIDs: [ActivitySessionID(rawValue: "stale-session")]
            )
        ).isEmpty)
        #expect(try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(startDate: Date(timeIntervalSince1970: 501))
        ).isEmpty)
        #expect(try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(endDate: Date(timeIntervalSince1970: 499))
        ).isEmpty)

        let current = try await store.agentSafeSearchHits(
            ids: [frame.id],
            matching: SearchQuery(
                text: "Currentcobalt",
                startDate: Date(timeIntervalSince1970: 500),
                endDate: Date(timeIntervalSince1970: 500),
                applicationBundleIdentifiers: ["com.apple.Notes"],
                domains: ["DOCS.EXAMPLE"],
                activitySessionIDs: [sessionID]
            )
        )
        #expect(current.map(\.id) == [frame.id])
        #expect(current.first?.snippet.contains("‹Currentcobalt›") == true)
    }

    @Test("One sensitive frame withholds its entire materialized session")
    func mixedSensitiveSessionFailsClosed() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let privateFrame = Self.frame(id: "private", time: 100, isSensitive: true)
        let ordinaryPeer = Self.frame(id: "ordinary-peer", time: 200)
        let safe = Self.frame(id: "safe", time: 600)
        try await store.insertBatch([privateFrame, ordinaryPeer, safe])

        let evidence = try await store.agentSafeFrames(ids: [
            ordinaryPeer.id,
            privateFrame.id,
            safe.id,
        ])

        #expect(evidence.map(\.frame.id.rawValue) == ["safe"])
        #expect(evidence.first?.activitySessionID.rawValue == "safe")
    }

    @Test("Missing session materialization is indistinguishable from a missing frame")
    func missingSessionFailsClosed() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let orphaned = Self.frame(id: "orphaned", time: 100)
        let absent = FrameID(rawValue: "absent")
        try await store.insert(orphaned)

        try Self.execute(
            "DELETE FROM activity_sessions WHERE id = 'orphaned'",
            on: store.connection.pointer
        )

        #expect(try await store.agentSafeFrames(ids: [orphaned.id, absent]).isEmpty)
        #expect(try await store.agentSafeFrame(id: orphaned.id) == nil)
    }

    @Test("Deleted and stale identifiers are omitted while retained evidence keeps order")
    func deletionAndStaleIdentifiers() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let deleted = Self.frame(id: "deleted", time: 100)
        let retained = Self.frame(id: "retained", time: 500)
        try await store.insertBatch([deleted, retained])

        _ = try await store.deleteFrames(olderThan: Date(timeIntervalSince1970: 300))
        let evidence = try await store.agentSafeFrames(ids: [
            deleted.id,
            FrameID(rawValue: "stale-candidate"),
            retained.id,
        ])

        #expect(evidence.map(\.frame.id.rawValue) == ["retained"])
    }

    @Test("Raw requests are capped before deduplication")
    func requestCap() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let repeated = Array(
            repeating: FrameID(rawValue: "same-missing-id"),
            count: SQLiteFrameStore.maximumAgentSafeFrameRequestCount + 1
        )

        do {
            _ = try await store.agentSafeFrames(ids: repeated)
            Issue.record("An oversized raw candidate window must be rejected.")
        } catch PassageError.invalidQuery(let message) {
            #expect(message.contains(String(SQLiteFrameStore.maximumAgentSafeFrameRequestCount)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let atCap = Array(
            repeating: FrameID(rawValue: "same-missing-id"),
            count: SQLiteFrameStore.maximumAgentSafeFrameRequestCount
        )
        #expect(try await store.agentSafeFrames(ids: atCap).isEmpty)
    }

    @Test("Production batch SQL starts from bounded requested IDs")
    func queryShape() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let sql = "EXPLAIN QUERY PLAN " + SQLiteFrameStore.agentSafeFramesSQL(
            requestCount: 3,
            includesAccessibilityEvidence: true
        )
        let plan = try Self.explain(sql, on: store.connection.pointer)

        #expect(plan.contains { $0.contains("CONSTANT ROWS") })
        #expect(plan.contains { $0.contains("SEARCH f USING INDEX") && $0.contains("id=?") })
        #expect(plan.contains { $0.contains("SEARCH safe_session USING INDEX") })
        #expect(!plan.contains { $0.contains("SCAN f") })
        #expect(!plan.contains { $0.contains("SCAN safe_session") })
    }

    @Test("Revocation prevents later batch resolution")
    func revokedStoreRejectsBatch() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let frame = Self.frame(id: "revoked", time: 100)
        try await store.insert(frame)

        store.revoke()

        await #expect(throws: Error.self) {
            _ = try await store.agentSafeFrames(ids: [frame.id])
        }
    }

    @Test("Revocation prevents later search-hit resolution")
    func revokedStoreRejectsSearchHits() async throws {
        let fixture = try AgentSafeFrameResolutionFixture()
        let store = try fixture.makeStore()
        let frame = Self.frame(id: "revoked-search-hit", time: 100)
        try await store.insert(frame)

        store.revoke()

        await #expect(throws: Error.self) {
            _ = try await store.agentSafeSearchHits(
                ids: [frame.id],
                matching: SearchQuery()
            )
        }
    }

    private static func frame(
        id: String,
        time: TimeInterval,
        isSensitive: Bool = false,
        withAccessibility: Bool = false,
        text: String? = nil,
        applicationName: String = "Notes",
        bundleIdentifier: String = "com.apple.Notes",
        domain: String? = nil
    ) -> FrameDocument {
        let text = text ?? "Evidence for \(id)"
        return FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: "\(id) window",
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
            pixelWidth: 1,
            pixelHeight: 1,
            visualFingerprint: UInt64(time),
            changeScore: 1,
            accessibilitySnapshot: withAccessibility ? AccessibilitySnapshot(
                nodes: [
                    AccessibilityNodeEvidence(
                        role: "AXButton",
                        label: "Remembered control",
                        depth: 0
                    ),
                ],
                visitedNodeCount: 1,
                isTruncated: false
            ) : nil
        )
    }

    private static func explain(_ sql: String, on database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var details = [String]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return details }
            guard status == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 3) else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            details.append(String(cString: text))
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw PassageError.database(
                message.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
            )
        }
    }
}

private final class AgentSafeFrameResolutionFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-agent-safe-batch-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(
            bytes: Data(repeating: 0x61, count: VaultKey.byteCount)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeStore() throws -> SQLiteFrameStore {
        try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
    }
}
