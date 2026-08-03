import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Accessibility snapshot store", .serialized)
struct AccessibilitySnapshotStoreTests {
    @Test("Snapshot round-trip deduplicates, searches, survives OCR replacement, and reclaims")
    func roundTripSearchAndReclamation() async throws {
        let fixture = try AccessibilityStoreFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let snapshot = try #require(Self.snapshot(
            label: "Quasarneedle launch control",
            value: "Ready for review"
        ))
        let first = Self.frame(id: "ax-one", time: 100, snapshot: snapshot)
        let second = Self.frame(id: "ax-two", time: 200, snapshot: snapshot)
        try await store.insertBatch([first, second])

        let restored = try #require(await store.frame(id: first.id)?.accessibilitySnapshot)
        #expect(restored == snapshot)
        #expect(restored.encodedByteCount > 0)
        #expect(try Self.scalar(
            "SELECT COUNT(*) FROM accessibility_snapshots",
            on: store.connection.pointer
        ) == 1)
        #expect(try Self.scalar(
            "SELECT length(payload) FROM accessibility_snapshots LIMIT 1",
            on: store.connection.pointer
        ) == Int64(restored.encodedByteCount))

        let axOnlyMatches = try await store.search(SearchQuery(text: "Quasarneedle"))
        #expect(Set(axOnlyMatches.map(\.id)) == Set([first.id, second.id]))

        let replacementText = "Corrected optical text"
        let replacement = try await store.replaceOCR(
            for: first.id,
            expectedVisualFingerprint: first.visualFingerprint,
            text: replacementText,
            regions: [
                OCRRegion(
                    text: replacementText,
                    confidence: 0.99,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                ),
            ]
        )
        #expect(replacement?.accessibilitySnapshot == snapshot)
        #expect(Set(try await store.search(
            SearchQuery(text: "Quasarneedle")
        ).map(\.id)) == Set([first.id, second.id]))

        _ = try await store.deleteFrames(
            from: first.capturedAt,
            through: first.capturedAt
        )
        #expect(try Self.scalar(
            "SELECT COUNT(*) FROM accessibility_snapshots",
            on: store.connection.pointer
        ) == 1)
        _ = try await store.deleteFrames(from: nil, through: nil)
        #expect(try Self.scalar(
            "SELECT COUNT(*) FROM accessibility_snapshots",
            on: store.connection.pointer
        ) == 0)
    }

    @Test("Sensitive frames discard supplied Accessibility evidence")
    func sensitiveFrameDropsEvidence() async throws {
        let fixture = try AccessibilityStoreFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var frame = Self.frame(
            id: "sensitive-ax",
            time: 100,
            snapshot: try #require(Self.snapshot(label: "must not persist", value: nil))
        )
        frame.context.isSensitive = true
        try await store.insert(frame)

        #expect(try await store.frame(id: frame.id)?.accessibilitySnapshot == nil)
        #expect(try Self.scalar(
            "SELECT COUNT(*) FROM accessibility_snapshots",
            on: store.connection.pointer
        ) == 0)
        #expect(try await store.search(SearchQuery(text: "persist")).isEmpty)
    }

    @Test("A writable v9 vault migrates additively to searchable v10 evidence")
    func schemaNineMigration() async throws {
        let fixture = try AccessibilityStoreFixture()
        defer { fixture.cleanUp() }
        var store: SQLiteFrameStore? = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey
        )
        let legacy = Self.frame(id: "legacy-v9", time: 50, snapshot: nil)
        try await store?.insert(legacy)
        store = nil

        var legacyConnection: SQLCipherConnection? = try SQLCipherConnection(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: false
        )
        let database = try #require(legacyConnection?.pointer)
        try Self.execute(
            """
            DROP TABLE frame_search;
            CREATE VIRTUAL TABLE frame_search USING fts5(
                frame_id UNINDEXED,
                ocr_text,
                window_title,
                application_name,
                url,
                tokenize = 'porter unicode61 remove_diacritics 2'
            );
            INSERT INTO frame_search(
                rowid, frame_id, ocr_text, window_title, application_name, url
            )
            SELECT rowid, id, ocr_text, window_title, application_name, url FROM frames;
            -- Memory segments postdate a v9 vault. Remove the modern trigger
            -- before recreating that legacy shape so SQLite does not validate
            -- its accessibility-column reference during DROP COLUMN.
            DROP TRIGGER IF EXISTS frames_memory_segment_update;
            DROP INDEX frames_accessibility_snapshot;
            ALTER TABLE frames DROP COLUMN accessibility_snapshot_hash;
            DROP TABLE accessibility_snapshots;
            UPDATE store_metadata SET value = '9' WHERE key = 'schema_version';
            """,
            on: database
        )
        legacyConnection = nil

        var readOnlyLegacy: SQLiteFrameStore? = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        #expect(try await readOnlyLegacy?.frame(id: legacy.id)?.accessibilitySnapshot == nil)
        #expect(try await readOnlyLegacy?.search(
            SearchQuery(text: "ordinary")
        ).map(\.id) == [legacy.id])
        readOnlyLegacy = nil

        let migrated = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        #expect(try Self.textScalar(
            "SELECT value FROM store_metadata WHERE key = 'schema_version'",
            on: migrated.connection.pointer
        ) == "10")
        #expect(try Self.columnNames(
            in: "frames",
            on: migrated.connection.pointer
        ).contains("accessibility_snapshot_hash"))
        #expect(try Self.columnNames(
            in: "frame_search",
            on: migrated.connection.pointer
        ).contains("accessibility_text"))
        #expect(try await migrated.search(SearchQuery(text: "ordinary")).map(\.id) == [legacy.id])

        let evidenceFrame = Self.frame(
            id: "post-migration-ax",
            time: 100,
            snapshot: try #require(Self.snapshot(
                label: "Migrationonlyword button",
                value: nil
            ))
        )
        try await migrated.insert(evidenceFrame)
        #expect(try await migrated.search(
            SearchQuery(text: "Migrationonlyword")
        ).map(\.id) == [evidenceFrame.id])
        #expect(try Self.scalar(
            """
            SELECT COUNT(*)
            FROM frame_search AS search
            JOIN frames AS frame ON frame.id = search.frame_id
            WHERE search.rowid != frame.rowid
            """,
            on: migrated.connection.pointer
        ) == 0)
    }

    private static func snapshot(
        label: String,
        value: String?
    ) -> AccessibilitySnapshot? {
        try? AccessibilitySnapshotCodec.boundedSnapshot(
            nodes: [
                AccessibilityNodeEvidence(
                    role: "AXButton",
                    label: label,
                    value: value,
                    depth: 1,
                    bounds: ScreenRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
                ),
            ],
            visitedNodeCount: 4,
            isTruncated: false
        )
    }

    private static func frame(
        id: String,
        time: TimeInterval,
        snapshot: AccessibilitySnapshot?
    ) -> FrameDocument {
        let text = "ordinary optical evidence"
        return FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                windowTitle: "Draft",
                displayID: 1,
                windowID: 7,
                windowBounds: ScreenRect(x: 0, y: 0, width: 800, height: 600)
            ),
            ocrText: text,
            ocrRegions: [
                OCRRegion(text: text, confidence: 0.9, x: 0, y: 0, width: 1, height: 1),
            ],
            imageRelativePath: "Media/\(id).jpg",
            thumbnailRelativePath: "Thumbnails/\(id).jpg",
            pixelWidth: 800,
            pixelHeight: 600,
            visualFingerprint: id.utf8.reduce(0) { $0 &+ UInt64($1) },
            changeScore: 0.5,
            accessibilitySnapshot: snapshot
        )
    }

    private static func scalar(_ sql: String, on database: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func textScalar(_ sql: String, on database: OpaquePointer) throws -> String? {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static func columnNames(
        in table: String,
        on database: OpaquePointer
    ) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))", on: database)
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: text))
            }
        }
        return names
    }

    private static func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw PassageError.database(message)
        }
    }
}

private final class AccessibilityStoreFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-ax-store-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x47, count: VaultKey.byteCount))
        try paths.createDirectories()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
