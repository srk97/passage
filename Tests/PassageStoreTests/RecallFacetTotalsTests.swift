import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Recall browse facet totals")
struct RecallFacetTotalsTests {
    @Test("Unfiltered browse facets read the materialized totals in stable order")
    func unfilteredBrowseFacetsUseMaterializedTotals() async throws {
        let fixture = try RecallFacetTotalsFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch([
            Self.frame(id: "alpha-old", time: 100, app: "Alpha", bundle: "app.alpha", domain: "ONE.example"),
            Self.frame(id: "alpha-new", time: 200, app: "Zulu", bundle: "app.alpha", domain: "one.EXAMPLE"),
            Self.frame(id: "beta-old", time: 250, app: "Beta", bundle: "app.beta", domain: "two.example"),
            Self.frame(id: "beta-new", time: 300, app: "Beta", bundle: "app.beta", domain: "two.example"),
            Self.frame(id: "missing", time: 400, app: "No metadata", bundle: nil, domain: nil),
        ])

        let facets = try await store.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(facets.applications.map(\.bundleIdentifier) == ["app.beta", "app.alpha"])
        #expect(facets.applications.map(\.applicationName) == ["Beta", "Zulu"])
        #expect(facets.applications.map(\.frameCount) == [2, 2])
        #expect(facets.domains.map(\.domain) == ["two.example", "one.example"])
        #expect(facets.domains.map(\.frameCount) == [2, 2])

        let connection = try SQLCipherConnection(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        let applicationPlan = try Self.explain(
            """
            EXPLAIN QUERY PLAN
            SELECT bundle_identifier, application_name, frame_count
            FROM recall_application_facets
            ORDER BY frame_count DESC, latest_capture DESC, bundle_identifier ASC
            LIMIT 20
            """,
            on: connection.pointer
        )
        #expect(applicationPlan.contains {
            $0.contains("COVERING INDEX recall_application_facets_order")
        })
        #expect(!applicationPlan.contains { $0.contains("SCAN frames") })
        #expect(!applicationPlan.contains { $0.contains("USE TEMP B-TREE") })

        let domainPlan = try Self.explain(
            """
            EXPLAIN QUERY PLAN
            SELECT normalized_domain, frame_count
            FROM recall_domain_facets
            ORDER BY frame_count DESC, latest_capture DESC, normalized_domain ASC
            LIMIT 20
            """,
            on: connection.pointer
        )
        #expect(domainPlan.contains {
            $0.contains("COVERING INDEX recall_domain_facets_order")
        })
        #expect(!domainPlan.contains { $0.contains("SCAN frames") })
        #expect(!domainPlan.contains { $0.contains("USE TEMP B-TREE") })
    }

    @Test("Insert, domain repair, retention, range deletion, and full deletion stay exact")
    func mutationsMaintainMaterializedTotals() async throws {
        let fixture = try RecallFacetTotalsFixture()
        let store = try fixture.makeStore()
        var repaired = Self.frame(
            id: "safari-repair",
            time: 400,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil
        )
        repaired.context.url = URL(string: "https://two.example/repaired")
        try await store.insertBatch([
            Self.frame(id: "alpha-zulu", time: 100, app: "Zulu", bundle: "app.alpha", domain: "one.example"),
            Self.frame(id: "alpha-alpha", time: 200, app: "Alpha", bundle: "app.alpha", domain: "one.example"),
            Self.frame(id: "safari-domain", time: 300, app: "Safari", bundle: "com.apple.Safari", domain: "two.example"),
            repaired,
            Self.frame(id: "charlie", time: 500, app: "Charlie", bundle: "app.charlie", domain: "three.example"),
        ])

        #expect(try await store.backfillMissingBrowserDomains() == 1)
        var facets = try await store.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(Self.applicationCounts(facets) == [
            "app.alpha": 2,
            "com.apple.Safari": 2,
            "app.charlie": 1,
        ])
        #expect(Self.domainCounts(facets) == [
            "one.example": 2,
            "two.example": 2,
            "three.example": 1,
        ])

        _ = try await store.deleteFrames(olderThan: Date(timeIntervalSince1970: 150))
        facets = try await store.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(Self.applicationCounts(facets)["app.alpha"] == 1)
        #expect(facets.applications.first { $0.bundleIdentifier == "app.alpha" }?.applicationName == "Alpha")
        #expect(Self.domainCounts(facets)["one.example"] == 1)

        _ = try await store.deleteFrames(
            from: Date(timeIntervalSince1970: 350),
            through: Date(timeIntervalSince1970: 450)
        )
        facets = try await store.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(Self.applicationCounts(facets)["com.apple.Safari"] == 1)
        #expect(Self.domainCounts(facets)["two.example"] == 1)

        _ = try await store.deleteOldestFrames(limit: 1)
        facets = try await store.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(Self.applicationCounts(facets)["app.alpha"] == nil)
        #expect(Self.domainCounts(facets)["one.example"] == nil)

        _ = try await store.deleteFrames(from: nil, through: nil)
        facets = try await store.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(facets.applications.isEmpty)
        #expect(facets.domains.isEmpty)
    }

    @Test("An existing encrypted vault populates derived totals exactly once")
    func existingVaultPopulatesDerivedTotals() async throws {
        let fixture = try RecallFacetTotalsFixture()
        var store: SQLiteFrameStore? = try fixture.makeStore()
        try await store?.insertBatch([
            Self.frame(id: "legacy-one", time: 100, app: "Legacy", bundle: "app.legacy", domain: "legacy.example"),
            Self.frame(id: "legacy-two", time: 200, app: "Legacy", bundle: "app.legacy", domain: "LEGACY.example"),
        ])
        store?.revoke()
        store = nil

        let mutation = try SQLCipherConnection(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: false
        )
        try Self.execute(
            """
            DELETE FROM recall_application_facets;
            DELETE FROM recall_domain_facets;
            DELETE FROM store_metadata WHERE key = 'recall_facet_totals_version';
            """,
            on: mutation.pointer
        )
        mutation.revoke()

        let reopened = try fixture.makeStore()
        let facets = try await reopened.recallFacets(RecallScope(), limitPerKind: 20)
        #expect(Self.applicationCounts(facets) == ["app.legacy": 2])
        #expect(Self.domainCounts(facets) == ["legacy.example": 2])
    }

    private static func applicationCounts(_ facets: RecallFacets) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: facets.applications.map {
            ($0.bundleIdentifier, $0.frameCount)
        })
    }

    private static func domainCounts(_ facets: RecallFacets) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: facets.domains.map { ($0.domain, $0.frameCount) })
    }

    private static func frame(
        id: String,
        time: Double,
        app: String,
        bundle: String?,
        domain: String?
    ) -> FrameDocument {
        let text = "Recall evidence for \(id)"
        return FrameDocument(
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
}

private final class RecallFacetTotalsFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-facet-total-tests-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x46, count: VaultKey.byteCount))
        try paths.createDirectories()
    }

    func makeStore() throws -> SQLiteFrameStore {
        try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
