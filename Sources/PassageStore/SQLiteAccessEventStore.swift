import PassageCore
import Foundation
@preconcurrency import SQLCipher

private let accessSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed access receipts kept in Passage's primary database.
public actor SQLiteAccessEventStore: AccessEventRepository {
    public static let maximumListLimit = 500

    nonisolated let connection: SQLCipherConnection
    public nonisolated let encryptionStatus: SQLCipherRuntimeStatus

    public init(paths: PassagePaths, vaultKey: VaultKey, readOnly: Bool = false) throws {
        let connection = try SQLCipherConnection(paths: paths, vaultKey: vaultKey, readOnly: readOnly)
        self.connection = connection
        encryptionStatus = connection.runtimeStatus
        let database = connection.pointer
        if !readOnly {
            try Self.migrate(database)
            try connection.hardenFilePermissions()
        }
    }

    public nonisolated func revoke() {
        connection.revoke()
    }

    public func recordAccessEvent(_ event: AccessEvent) throws {
        guard event.returnedFrameCount >= 0 else {
            throw PassageError.invalidQuery("Returned frame count cannot be negative.")
        }

        let encodedFrameIDs = try JSONEncoder().encode(event.returnedFrameIDs.map(\.rawValue))
        let sql = """
            INSERT INTO access_events (
                event_id, occurred_at, client, command, capability,
                query_summary, filter_summary, returned_frame_ids,
                returned_frame_count, outcome
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        try withStatement(sql) { statement in
            try Self.bind(event.id.rawValue, at: 1, to: statement)
            try Self.bind(event.occurredAt.timeIntervalSince1970, at: 2, to: statement)
            try Self.bind(event.client, at: 3, to: statement)
            try Self.bind(event.command, at: 4, to: statement)
            try Self.bind(event.capability, at: 5, to: statement)
            try Self.bind(event.querySummary, at: 6, to: statement)
            try Self.bind(event.filterSummary, at: 7, to: statement)
            try Self.bind(encodedFrameIDs, at: 8, to: statement)
            try Self.bind(Int64(event.returnedFrameCount), at: 9, to: statement)
            try Self.bind(event.outcome.rawValue, at: 10, to: statement)
            try stepDone(statement)
        }
        try connection.hardenFilePermissions()
    }

    public func accessEvents(limit: Int) throws -> [AccessEvent] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, Self.maximumListLimit)
        let sql = """
            SELECT event_id, occurred_at, client, command, capability,
                   query_summary, filter_summary, returned_frame_ids,
                   returned_frame_count, outcome
            FROM access_events
            ORDER BY occurred_at DESC, sequence DESC
            LIMIT ?
            """
        return try withStatement(sql) { statement in
            try Self.bind(Int64(boundedLimit), at: 1, to: statement)
            var events: [AccessEvent] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    events.append(try Self.decodeEvent(statement))
                case SQLITE_DONE:
                    return events
                default:
                    throw databaseError(statement)
                }
            }
        }
    }

    @discardableResult
    public func clearAccessEvents() throws -> Int {
        let deletedCount = try withStatement("DELETE FROM access_events") { statement in
            try stepDone(statement)
            return Int(sqlite3_changes(sqlite3_db_handle(statement)))
        }
        try connection.hardenFilePermissions()
        return deletedCount
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        guard let connectionLease = connection.lease() else {
            throw PassageError.database("Store is closed")
        }
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            if status == SQLITE_INTERRUPT || Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
            throw PassageError.database(String(cString: sqlite3_errmsg(
                sqlite3_db_handle(statement)
            )))
        }
    }

    private func databaseError(_ statement: OpaquePointer) -> PassageError {
        .database(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))
    }

    private static func decodeEvent(_ statement: OpaquePointer) throws -> AccessEvent {
        let encodedFrameIDs = data(statement, column: 7)
        let rawFrameIDs = try JSONDecoder().decode([String].self, from: encodedFrameIDs)
        guard let rawOutcome = string(statement, column: 9),
              let outcome = AccessEventOutcome(rawValue: rawOutcome) else {
            throw PassageError.database("Access event contains an unknown outcome.")
        }
        return AccessEvent(
            id: AccessEventID(rawValue: string(statement, column: 0) ?? ""),
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            client: string(statement, column: 2) ?? "",
            command: string(statement, column: 3) ?? "",
            capability: string(statement, column: 4) ?? "",
            querySummary: string(statement, column: 5),
            filterSummary: string(statement, column: 6),
            returnedFrameIDs: rawFrameIDs.map(FrameID.init(rawValue:)),
            returnedFrameCount: Int(sqlite3_column_int64(statement, 8)),
            outcome: outcome
        )
    }

    private static func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, accessSQLiteTransient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        try checkBinding(result, statement: statement)
    }

    private static func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), accessSQLiteTransient)
        }
        try checkBinding(result, statement: statement)
    }

    private static func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        try checkBinding(sqlite3_bind_double(statement, index, value), statement: statement)
    }

    private static func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        try checkBinding(sqlite3_bind_int64(statement, index, value), statement: statement)
    }

    private static func checkBinding(_ result: Int32, statement: OpaquePointer) throws {
        guard result == SQLITE_OK else {
            let database = sqlite3_db_handle(statement)
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func data(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw PassageError.database(message)
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS access_events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL UNIQUE,
                    occurred_at REAL NOT NULL,
                    client TEXT NOT NULL,
                    command TEXT NOT NULL,
                    capability TEXT NOT NULL,
                    query_summary TEXT,
                    filter_summary TEXT,
                    returned_frame_ids BLOB NOT NULL,
                    returned_frame_count INTEGER NOT NULL CHECK (returned_frame_count >= 0),
                    outcome TEXT NOT NULL CHECK (outcome IN ('success', 'denied', 'failure'))
                );
                CREATE INDEX IF NOT EXISTS access_events_occurred_at
                    ON access_events(occurred_at DESC, sequence DESC);
                CREATE TABLE IF NOT EXISTS store_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                INSERT OR REPLACE INTO store_metadata(key, value)
                    VALUES ('access_event_schema_version', '1');
                """, on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }
}
