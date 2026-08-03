import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Recall navigation store")
struct RecallNavigationStoreTests {
    @Test("Time, application, and domain filters intersect with an exclusive end")
    func combinedMetadataFilters() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "before", time: 99, bundle: "com.apple.Safari", domain: "work.example"),
            Self.frame(id: "at-start", time: 100, bundle: "com.apple.Safari", domain: "work.example"),
            Self.frame(id: "middle", time: 150, bundle: "com.apple.Safari", domain: "work.example"),
            Self.frame(id: "wrong-app", time: 150, bundle: "com.apple.dt.Xcode", domain: "work.example"),
            Self.frame(id: "wrong-domain", time: 150, bundle: "com.apple.Safari", domain: "other.example"),
            Self.frame(id: "at-end", time: 200, bundle: "com.apple.Safari", domain: "work.example"),
        ])

        let page = try await store.recall(
            RecallScope(
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                applicationBundleIdentifiers: [" com.apple.Safari "],
                domains: [" WORK.EXAMPLE "]
            ),
            after: nil,
            limit: 20
        )

        #expect(page.hits.map(\.id.rawValue) == ["middle", "at-start"])
        #expect(!page.hasMore)
        #expect(page.nextCursor == nil)
    }

    @Test("Every retained item, including the oldest, is reachable by cursor")
    func oldestRetainedItemIsReachable() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        let frames = (0..<17).map { offset in
            Self.frame(
                id: String(format: "frame-%02d", offset),
                time: Double(1_000 + offset),
                bundle: "com.apple.Notes",
                domain: nil
            )
        }
        try await store.insertBatch(Array(frames.reversed()))

        var cursor: RecallCursor?
        var received: [String] = []
        var pageCount = 0
        repeat {
            let page = try await store.recall(RecallScope(), after: cursor, limit: 4)
            received.append(contentsOf: page.hits.map(\.id.rawValue))
            cursor = page.nextCursor
            pageCount += 1
            #expect(page.hasMore == (page.nextCursor != nil))
            #expect(page.hits.count <= 4)
            if pageCount >= 6 { break }
        } while cursor != nil
        #expect(cursor == nil, "Cursor traversal must terminate")

        let expected = frames.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id.rawValue > $1.id.rawValue }
            return $0.capturedAt > $1.capturedAt
        }.map(\.id.rawValue)
        #expect(received == expected)
        #expect(received.last == "frame-00")
        #expect(Set(received).count == frames.count)
    }

    @Test("Equal timestamps page by ID without duplicates or omissions")
    func stableCursorAtIdenticalTimestamps() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        let tiedIDs = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
        let frames = tiedIDs.map {
            Self.frame(id: $0, time: 500, bundle: "com.apple.Notes", domain: nil)
        } + [
            Self.frame(id: "newer", time: 501, bundle: "com.apple.Notes", domain: nil),
            Self.frame(id: "older", time: 499, bundle: "com.apple.Notes", domain: nil),
        ]
        try await store.insertBatch(Array(frames.reversed()))

        var cursor: RecallCursor?
        var received: [String] = []
        var pageCount = 0
        repeat {
            let page = try await store.recall(
                RecallScope(text: "Recall"),
                after: cursor,
                limit: 3
            )
            received.append(contentsOf: page.hits.map(\.id.rawValue))
            cursor = page.nextCursor
            pageCount += 1
            if pageCount >= 5 { break }
        } while cursor != nil
        #expect(cursor == nil, "Cursor traversal must terminate")

        #expect(received == ["newer"] + tiedIDs.sorted(by: >) + ["older"])
        #expect(received.count == frames.count)
        #expect(Set(received).count == frames.count)
    }

    @Test("Page limits are clamped to the documented one-through-two-hundred range")
    func pageSizeBounds() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<205).map { offset in
            Self.frame(
                id: String(format: "bounded-%03d", offset),
                time: Double(offset),
                bundle: "com.apple.Notes",
                domain: nil
            )
        })

        let minimum = try await store.recall(RecallScope(), after: nil, limit: 0)
        #expect(minimum.hits.count == 1)
        #expect(minimum.hasMore)
        #expect(minimum.nextCursor != nil)

        let maximum = try await store.recall(RecallScope(), after: nil, limit: 10_000)
        #expect(maximum.hits.count == 200)
        #expect(maximum.hasMore)
        #expect(maximum.nextCursor != nil)
    }

    @Test("Text search intersects every metadata constraint")
    func textAndMetadataIntersection() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "target", time: 150, bundle: "com.figma.Desktop", domain: "figma.com", text: "Project Phoenix checkout"),
            Self.frame(id: "wrong-text", time: 150, bundle: "com.figma.Desktop", domain: "figma.com", text: "Project Atlas checkout"),
            Self.frame(id: "wrong-app", time: 150, bundle: "com.apple.Safari", domain: "figma.com", text: "Project Phoenix checkout"),
            Self.frame(id: "wrong-domain", time: 150, bundle: "com.figma.Desktop", domain: "example.com", text: "Project Phoenix checkout"),
            Self.frame(id: "too-early", time: 99, bundle: "com.figma.Desktop", domain: "figma.com", text: "Project Phoenix checkout"),
            Self.frame(id: "at-end", time: 200, bundle: "com.figma.Desktop", domain: "figma.com", text: "Project Phoenix checkout"),
        ])

        let page = try await store.recall(
            RecallScope(
                text: "  Phoenix  ",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                applicationBundleIdentifiers: ["com.figma.Desktop"],
                domains: ["FIGMA.COM"]
            ),
            after: nil,
            limit: 20
        )

        #expect(page.hits.map(\.id.rawValue) == ["target"])
        #expect(page.hits.first?.snippet.contains("Phoenix") == true)
    }

    @Test("Ranked recall preserves FTS relevance and the half-open time bound")
    func rankedRecallUsesRelevance() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "older-strong",
                time: 120,
                bundle: "com.apple.Notes",
                domain: nil,
                text: "Phoenix Phoenix Phoenix Phoenix"
            ),
            Self.frame(
                id: "newer-weak",
                time: 190,
                bundle: "com.apple.Notes",
                domain: nil,
                text: "Phoenix appears once among several unrelated planning words"
            ),
            Self.frame(
                id: "at-exclusive-end",
                time: 200,
                bundle: "com.apple.Notes",
                domain: nil,
                text: "Phoenix Phoenix Phoenix Phoenix Phoenix"
            ),
        ])

        let hits = try await store.rankedRecall(
            RecallScope(
                text: "Phoenix",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200)
            ),
            limit: 20
        )

        #expect(hits.map(\.id.rawValue) == ["older-strong", "newer-weak"])
    }

    @Test("Million-frame probe is shaped as a covering ordered scan plus a bounded FTS scan")
    func recentTextProbeQueryPlanShape() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(
            id: "plan",
            time: 100,
            bundle: "com.example.Plan",
            domain: "plan.example",
            text: "Phoenix"
        ))
        let connection = try SQLCipherConnection(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )

        let candidatePlan = try Self.explain(
            """
            EXPLAIN QUERY PLAN
            SELECT f.rowid, f.id, f.captured_at
            FROM frames AS f INDEXED BY frames_domain_application_recall
            WHERE f.domain COLLATE NOCASE IN (?)
              AND f.bundle_identifier IN (?)
            ORDER BY f.captured_at DESC, f.id DESC
            LIMIT ?
            """,
            on: connection.pointer
        )
        #expect(candidatePlan.contains {
            $0.contains("COVERING INDEX frames_domain_application_recall")
        })
        #expect(!candidatePlan.contains { $0.contains("USE TEMP B-TREE") })

        let textPlan = try Self.explain(
            """
            EXPLAIN QUERY PLAN
            SELECT rowid
            FROM frame_search
            WHERE frame_search MATCH ? AND rowid >= ? AND rowid <= ?
            """,
            on: connection.pointer
        )
        #expect(textPlan.contains { $0.contains("VIRTUAL TABLE INDEX") })
        #expect(!textPlan.contains { $0.contains("USE TEMP B-TREE") })

        let snippetPlan = try Self.explain(
            """
            EXPLAIN QUERY PLAN
            SELECT rowid,
                   CASE WHEN rowid IN (?, ?, ?)
                        THEN snippet(frame_search, -1, '‹', '›', ' … ', 18)
                        ELSE NULL END
            FROM frame_search
            WHERE frame_search MATCH ? AND rowid >= ? AND rowid <= ?
            """,
            on: connection.pointer
        )
        #expect(snippetPlan.contains { $0.contains("VIRTUAL TABLE INDEX") })
        #expect(!snippetPlan.contains { $0.contains("USE TEMP B-TREE") })
    }

    @Test("Cursors are opaque, scope-bound, and reject malformed tokens")
    func cursorValidation() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "latest", time: 300, bundle: "com.apple.Safari", domain: "one.example"),
            Self.frame(id: "middle", time: 200, bundle: "com.apple.Safari", domain: "one.example"),
            Self.frame(id: "oldest", time: 100, bundle: "com.apple.Safari", domain: "one.example"),
        ])
        let originalScope = RecallScope(applicationBundleIdentifiers: ["com.apple.Safari"])
        let firstPage = try await store.recall(originalScope, after: nil, limit: 1)
        let cursor = try #require(firstPage.nextCursor)
        #expect(!cursor.token.isEmpty)

        let equivalentScope = RecallScope(
            applicationBundleIdentifiers: ["  com.apple.Safari  "]
        )
        let secondPage = try await store.recall(equivalentScope, after: cursor, limit: 1)
        #expect(secondPage.hits.map(\.id.rawValue) == ["middle"])

        await #expect(throws: PassageError.self) {
            _ = try await store.recall(
                RecallScope(domains: ["one.example"]),
                after: cursor,
                limit: 1
            )
        }
        await #expect(throws: PassageError.self) {
            _ = try await store.recall(
                originalScope,
                after: RecallCursor(token: "not-a-valid-passage-cursor"),
                limit: 1
            )
        }
    }

    @Test("Facet counts drill sideways while honoring text, date, and the opposite facet")
    func facetCountsAndDrillSideways() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "safari-work-1", time: 110, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", text: "Phoenix"),
            Self.frame(id: "safari-work-2", time: 120, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", text: "Phoenix"),
            Self.frame(id: "figma-work", time: 130, app: "Figma", bundle: "com.figma.Desktop", domain: "work.example", text: "Phoenix"),
            Self.frame(id: "xcode-work", time: 140, app: "Xcode", bundle: "com.apple.dt.Xcode", domain: "work.example", text: "Phoenix"),
            Self.frame(id: "safari-other", time: 150, app: "Safari", bundle: "com.apple.Safari", domain: "other.example", text: "Phoenix"),
            Self.frame(id: "figma-other", time: 160, app: "Figma", bundle: "com.figma.Desktop", domain: "other.example", text: "Phoenix"),
            Self.frame(id: "wrong-text", time: 170, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", text: "Atlas"),
            Self.frame(id: "too-old", time: 99, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", text: "Phoenix"),
            Self.frame(id: "missing-metadata", time: 180, app: "Terminal", bundle: nil, domain: nil, text: "Phoenix"),
        ])

        let facets = try await store.recallFacets(
            RecallScope(
                text: "Phoenix",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                applicationBundleIdentifiers: ["com.apple.Safari"],
                domains: ["work.example"]
            ),
            limitPerKind: 20
        )

        // Application selection is ignored only while producing application
        // alternatives, so every app used on work.example remains discoverable.
        let applicationCounts = Dictionary(uniqueKeysWithValues: facets.applications.map {
            ($0.bundleIdentifier, $0.frameCount)
        })
        #expect(applicationCounts == [
            "com.apple.Safari": 2,
            "com.apple.dt.Xcode": 1,
            "com.figma.Desktop": 1,
        ])
        let applicationNames = Dictionary(uniqueKeysWithValues: facets.applications.map {
            ($0.bundleIdentifier, $0.applicationName)
        })
        #expect(applicationNames == [
            "com.apple.Safari": "Safari",
            "com.apple.dt.Xcode": "Xcode",
            "com.figma.Desktop": "Figma",
        ])

        // Domain selection is ignored only while producing domain alternatives;
        // the selected Safari app still narrows the domain counts.
        let domainCounts = Dictionary(uniqueKeysWithValues: facets.domains.map {
            ($0.domain, $0.frameCount)
        })
        #expect(domainCounts == ["work.example": 2, "other.example": 1])

        let limited = try await store.recallFacets(
            RecallScope(text: "Phoenix"),
            limitPerKind: 1
        )
        #expect(limited.applications.count == 1)
        #expect(limited.applications.first?.bundleIdentifier == "com.apple.Safari")
        #expect(limited.domains.count == 1)
        #expect(limited.domains.first?.domain == "work.example")
    }

    @Test("Browser availability is uncapped and uses the website drill-sideways scope")
    func browserMomentCountIsUncappedAndScoped() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        var frames = (0..<45).map { index in
            Self.frame(
                id: "ordinary-\(index)",
                time: 200 + Double(index),
                app: "Ordinary \(index)",
                bundle: "com.example.ordinary.\(index)",
                domain: nil,
                text: "Phoenix"
            )
        }
        frames.append(Self.frame(
            id: "old-browser",
            time: 100,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: "Phoenix"
        ))
        try await store.insertBatch(frames)

        let capped = try await store.recallFacets(RecallScope(), limitPerKind: 40)
        #expect(capped.applications.count == 40)
        #expect(!capped.applications.contains {
            $0.bundleIdentifier == "com.apple.Safari"
        })
        #expect(capped.domains.isEmpty)
        #expect(capped.browserMomentCount == 1)

        let selectedMissingWebsite = try await store.recallFacets(
            RecallScope(
                text: "Phoenix",
                startDate: Date(timeIntervalSince1970: 90),
                endDate: Date(timeIntervalSince1970: 150),
                applicationBundleIdentifiers: ["com.apple.Safari"],
                domains: ["missing.example"]
            ),
            limitPerKind: 40
        )
        #expect(selectedMissingWebsite.domains.isEmpty)
        #expect(selectedMissingWebsite.browserMomentCount == 1)

        let nonBrowserScope = try await store.recallFacets(
            RecallScope(
                text: "Phoenix",
                applicationBundleIdentifiers: ["com.example.ordinary.0"]
            ),
            limitPerKind: 40
        )
        #expect(nonBrowserScope.browserMomentCount == 0)
    }

    @Test("Invalid and empty time intervals fail closed")
    func invalidTimeIntervals() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()

        for (start, end) in [(200.0, 100.0), (100.0, 100.0)] {
            let scope = RecallScope(
                startDate: Date(timeIntervalSince1970: start),
                endDate: Date(timeIntervalSince1970: end)
            )
            await #expect(throws: PassageError.self) {
                _ = try await store.recall(scope, after: nil, limit: 10)
            }
            await #expect(throws: PassageError.self) {
                _ = try await store.recallFacets(scope, limitPerKind: 10)
            }
        }
    }

    @Test("Expired media remains navigable with an honest missing-visual path")
    func expiredMediaRemainsRecallable() async throws {
        let fixture = try RecallStoreFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(
                id: "old-evidence",
                time: 100,
                bundle: "com.apple.Notes",
                domain: nil,
                text: "Retained Phoenix evidence"
            ),
            Self.frame(
                id: "new-evidence",
                time: 200,
                bundle: "com.apple.Notes",
                domain: nil,
                text: "Newer evidence"
            ),
        ])

        _ = try await store.expireOldestMedia(limit: 1)
        let page = try await store.recall(
            RecallScope(text: "Phoenix"),
            after: nil,
            limit: 10
        )
        let hit = try #require(page.hits.first)
        #expect(hit.id.rawValue == "old-evidence")
        #expect(hit.imageRelativePath.isEmpty)
        #expect(hit.thumbnailRelativePath == nil)
        #expect(hit.snippet.contains("Phoenix"))
    }

    private static func frame(
        id: String,
        time: Double,
        app: String = "Safari",
        bundle: String?,
        domain: String?,
        text: String = "Recall evidence"
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: "\(app) · \(id)",
                url: domain.flatMap { URL(string: "https://\($0)/\(id)") },
                domain: domain
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

    private static func explain(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> [String] {
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
            guard status == SQLITE_ROW else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            if let text = sqlite3_column_text(statement, 3) {
                details.append(String(cString: text))
            }
        }
    }
}

private final class RecallStoreFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-recall-tests-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x52, count: VaultKey.byteCount))
        try paths.createDirectories()
    }

    func makeStore() throws -> SQLiteFrameStore {
        try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
