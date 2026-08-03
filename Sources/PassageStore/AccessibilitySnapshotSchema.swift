import PassageCore
import Foundation
@preconcurrency import SQLCipher

enum AccessibilitySnapshotSchema {
    static let currentVersion = 10

    static func migrate(on database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS accessibility_snapshots (
                content_hash BLOB PRIMARY KEY NOT NULL CHECK(length(content_hash) = 32),
                payload BLOB NOT NULL CHECK(length(payload) <= 16384),
                accessibility_text TEXT NOT NULL
            ) WITHOUT ROWID;
            """,
            on: database
        )

        let frameColumns = try columnNames(in: "frames", on: database)
        if !frameColumns.contains("accessibility_snapshot_hash") {
            try execute(
                """
                ALTER TABLE frames ADD COLUMN accessibility_snapshot_hash BLOB
                    REFERENCES accessibility_snapshots(content_hash) ON DELETE SET NULL
                """,
                on: database
            )
        }
        try execute(
            """
            CREATE INDEX IF NOT EXISTS frames_accessibility_snapshot
                ON frames(accessibility_snapshot_hash)
                WHERE accessibility_snapshot_hash IS NOT NULL
            """,
            on: database
        )

        let schemaVersion = try metadataValue("schema_version", on: database)
            .flatMap(Int.init) ?? 0
        let searchColumns = try columnNames(in: "frame_search", on: database)
        guard schemaVersion < currentVersion
                || !searchColumns.contains("accessibility_text") else { return }

        // FTS5 cannot add a column. Rebuild in one encrypted transaction and
        // retain the owning frame rowid alignment used by Recall's fast path.
        try execute("DROP TABLE IF EXISTS frame_search", on: database)
        try execute(
            """
            CREATE VIRTUAL TABLE frame_search USING fts5(
                frame_id UNINDEXED,
                ocr_text,
                window_title,
                application_name,
                url,
                accessibility_text,
                tokenize = 'porter unicode61 remove_diacritics 2'
            )
            """,
            on: database
        )
        try execute(
            """
            INSERT INTO frame_search(
                rowid, frame_id, ocr_text, window_title, application_name, url,
                accessibility_text
            )
            SELECT frame.rowid, frame.id, frame.ocr_text, frame.window_title,
                   frame.application_name, frame.url,
                   COALESCE(snapshot.accessibility_text, '')
            FROM frames AS frame
            LEFT JOIN accessibility_snapshots AS snapshot
              ON snapshot.content_hash = frame.accessibility_snapshot_hash
            """,
            on: database
        )
        try execute(
            "INSERT OR REPLACE INTO store_metadata(key, value) VALUES ('schema_version', '10')",
            on: database
        )
    }

    static func deleteOrphans(on database: OpaquePointer) throws {
        try execute(
            """
            DELETE FROM accessibility_snapshots
            WHERE NOT EXISTS (
                SELECT 1 FROM frames
                WHERE frames.accessibility_snapshot_hash = accessibility_snapshots.content_hash
            )
            """,
            on: database
        )
    }

    private static func metadataValue(
        _ key: String,
        on database: OpaquePointer
    ) throws -> String? {
        let statement = try prepare(
            "SELECT value FROM store_metadata WHERE key = ? LIMIT 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
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
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return names }
            guard status == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 1) else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            names.insert(String(cString: text))
        }
    }

    private static func prepare(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> OpaquePointer {
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

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
