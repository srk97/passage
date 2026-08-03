import PassageCore
import Foundation
@preconcurrency import SQLCipher

/// Exact v3 b-trees attributable to MemorySegment retrieval. The stable frame
/// key table/index are included because compact membership depends on them;
/// excluding them would incorrectly shift support cost into the canonical base.
private let expectedMemorySegmentStorageObjects = [
    "frame_key_sequence",
    "frames_frame_key",
    "memory_segment_dirty_sessions",
    "memory_segment_dirty_sessions_order",
    "memory_segment_index_state",
    "memory_segment_members",
    "memory_segments",
    "memory_segments_context_order",
    "memory_segments_order",
    "sqlite_autoindex_memory_segment_members_1",
    "sqlite_autoindex_memory_segments_1",
    "sqlite_autoindex_memory_segments_2",
]

/// Aggregate diagnostics for Passage's encrypted, rebuildable memory-segment shadow.
///
/// This deliberately exposes no segment payload, frame identifier, search text, or
/// other personal evidence. It exists so scale tests and local health surfaces can
/// verify index coverage without walking every result page.
public struct MemorySegmentIndexStatistics: Codable, Equatable, Sendable {
    public let lifecycle: String
    /// Baseline generation produced by the last complete rebuild. Incremental
    /// overlays and maintenance derive live query revisions without rewriting
    /// this diagnostic value.
    public let lastFullRebuildRevision: MemorySegmentIndexRevision?
    public let canonicalFrameCount: Int
    public let segmentCount: Int
    public let pendingSessionCount: Int?

    public init(
        lifecycle: String,
        lastFullRebuildRevision: MemorySegmentIndexRevision?,
        canonicalFrameCount: Int,
        segmentCount: Int,
        pendingSessionCount: Int? = nil
    ) {
        self.lifecycle = lifecycle
        self.lastFullRebuildRevision = lastFullRebuildRevision
        self.canonicalFrameCount = canonicalFrameCount
        self.segmentCount = segmentCount
        self.pendingSessionCount = pendingSessionCount
    }
}

/// Page-level encrypted-store diagnostics for reproducible benchmark accounting.
/// `memorySegmentShadowBytes` is the exact dbstat footprint of every table and
/// index owned by the rebuildable MemorySegment shadow, including stable-frame
/// key support and SQLite-created autoindexes.
public struct MemorySegmentStorageDiagnostics: Codable, Equatable, Sendable {
    public let pageSizeBytes: Int64
    public let pageCount: Int64
    public let freelistPageCount: Int64
    public let liveDatabaseBytes: Int64
    public let memorySegmentShadowBytes: Int64
    public let canonicalLiveBytes: Int64
    public let memorySegmentSchemaObjects: [String]
    public let memorySegmentDBStatObjects: [String]
    /// Exact live-page totals by shadow object. Entries are ordered by name and
    /// intentionally contain no row counts, identifiers, text, or payloads.
    public let memorySegmentObjectLiveBytes: [MemorySegmentObjectStorageDiagnostics]

    public init(
        pageSizeBytes: Int64,
        pageCount: Int64,
        freelistPageCount: Int64,
        liveDatabaseBytes: Int64,
        memorySegmentShadowBytes: Int64,
        canonicalLiveBytes: Int64,
        memorySegmentSchemaObjects: [String],
        memorySegmentDBStatObjects: [String],
        memorySegmentObjectLiveBytes: [MemorySegmentObjectStorageDiagnostics]
    ) {
        self.pageSizeBytes = pageSizeBytes
        self.pageCount = pageCount
        self.freelistPageCount = freelistPageCount
        self.liveDatabaseBytes = liveDatabaseBytes
        self.memorySegmentShadowBytes = memorySegmentShadowBytes
        self.canonicalLiveBytes = canonicalLiveBytes
        self.memorySegmentSchemaObjects = memorySegmentSchemaObjects
        self.memorySegmentDBStatObjects = memorySegmentDBStatObjects
        self.memorySegmentObjectLiveBytes = memorySegmentObjectLiveBytes
    }
}

/// Content-free dbstat accounting for one MemorySegment shadow object.
public struct MemorySegmentObjectStorageDiagnostics: Codable, Equatable, Sendable {
    public let name: String
    public let liveBytes: Int64

    public init(name: String, liveBytes: Int64) {
        self.name = name
        self.liveBytes = liveBytes
    }
}

/// Package-only, one-shot retrieval measurement for the frozen benchmark.
/// The aggregate counts canonical rows entering the evidence decode loop and
/// does not expose any additional content or retain mutable instrumentation.
package struct MemorySegmentPageDiagnostics: Sendable {
    package let page: MemorySegmentPage
    package let hydratedCanonicalFrameCount: Int

    package init(page: MemorySegmentPage, hydratedCanonicalFrameCount: Int) {
        self.page = page
        self.hydratedCanonicalFrameCount = hydratedCanonicalFrameCount
    }
}

extension SQLiteFrameStore {
    /// Returns aggregate segment-index health without disclosing memory content.
    public func memorySegmentIndexStatistics() throws -> MemorySegmentIndexStatistics? {
        let lease = try activeConnectionLease()
        defer { lease.release() }
        guard let status = try MemorySegmentIndex.status(on: lease.pointer) else { return nil }
        let pendingSessionCount = try MemorySegmentIndex.pendingSessionCount(on: lease.pointer)
        return MemorySegmentIndexStatistics(
            lifecycle: status.lifecycle.rawValue,
            lastFullRebuildRevision: status.revision,
            canonicalFrameCount: status.canonicalFrameCount,
            segmentCount: status.segmentCount,
            pendingSessionCount: pendingSessionCount
        )
    }

    package func retrievePrivateMemorySegmentsForDiagnostics(
        _ request: PrivateMemorySegmentRequest
    ) throws -> MemorySegmentPageDiagnostics {
        try memorySegmentPageDiagnostics(
            request.retrieval,
            boundary: .privateLocal
        )
    }

    package func retrieveAgentSafeMemorySegmentsForDiagnostics(
        _ request: AgentSafeMemorySegmentRequest
    ) throws -> MemorySegmentPageDiagnostics {
        try memorySegmentPageDiagnostics(
            request.retrieval,
            boundary: .agentSafe
        )
    }

    private func memorySegmentPageDiagnostics(
        _ request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary
    ) throws -> MemorySegmentPageDiagnostics {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let measurement = try MemorySegmentIndex.retrieveMeasuringHydration(
            request,
            boundary: boundary,
            on: lease.pointer
        )
        return MemorySegmentPageDiagnostics(
            page: measurement.page,
            hydratedCanonicalFrameCount: measurement.hydratedCanonicalFrameCount
        )
    }

    /// Forces the encrypted database's committed WAL pages into the main file
    /// for reproducible diagnostics. This is intentionally not used by normal
    /// capture or retrieval paths; callers must run it only between benchmark
    /// phases when no other connection is holding a read transaction.
    public func checkpointStorageForDiagnostics() throws {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }

        var logFrameCount: Int32 = 0
        var checkpointedFrameCount: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            lease.pointer,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrameCount,
            &checkpointedFrameCount
        )
        guard result == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(lease.pointer))
            if result == SQLITE_BUSY {
                throw PassageError.database(
                    "Diagnostic WAL checkpoint was busy (\(checkpointedFrameCount)/\(logFrameCount) frames checkpointed): \(detail)"
                )
            }
            throw PassageError.database(
                "Diagnostic WAL checkpoint failed with code \(result): \(detail)"
            )
        }
        try connection.hardenFilePermissions()
    }

    /// Returns exact live-page accounting after a diagnostic checkpoint.
    /// The benchmark treats a missing expected shadow object or unavailable
    /// `dbstat` support as a hard error rather than emitting a partial metric.
    public func memorySegmentStorageDiagnostics() throws -> MemorySegmentStorageDiagnostics {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let database = lease.pointer
        let pageSize = try memorySegmentDiagnosticScalar("PRAGMA page_size", on: database)
        let pageCount = try memorySegmentDiagnosticScalar("PRAGMA page_count", on: database)
        let freelistPageCount = try memorySegmentDiagnosticScalar(
            "PRAGMA freelist_count",
            on: database
        )
        let schemaObjects = try memorySegmentDiagnosticStrings(
            """
            SELECT name
            FROM sqlite_schema
            WHERE type IN ('table', 'index')
              AND (
                    name LIKE 'memory_segment%'
                 OR name LIKE 'sqlite_autoindex_memory_segment%'
                 OR tbl_name LIKE 'memory_segment%'
                 OR name IN ('frame_key_sequence', 'frames_frame_key')
              )
            ORDER BY name
            """,
            on: database
        )
        try requireExactMemorySegmentStorageObjects(
            schemaObjects,
            source: "sqlite_schema"
        )
        let dbstatObjects = try memorySegmentDiagnosticStrings(
            """
            SELECT DISTINCT stat.name
            FROM dbstat AS stat
            JOIN sqlite_schema AS schema ON schema.name = stat.name
            WHERE schema.type IN ('table', 'index')
              AND (
                    schema.name LIKE 'memory_segment%'
                 OR schema.name LIKE 'sqlite_autoindex_memory_segment%'
                 OR schema.tbl_name LIKE 'memory_segment%'
                 OR schema.name IN ('frame_key_sequence', 'frames_frame_key')
              )
            ORDER BY stat.name
            """,
            on: database
        )
        try requireExactMemorySegmentStorageObjects(dbstatObjects, source: "dbstat")
        let objectLiveBytes = try memorySegmentDiagnosticObjectBytes(on: database)
        let liveBytes = try memorySegmentDiagnosticScalar(
            "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat",
            on: database
        )
        let shadowBytes = try memorySegmentDiagnosticScalar(
            """
            SELECT COALESCE(SUM(stat.pgsize), 0)
            FROM dbstat AS stat
            JOIN sqlite_schema AS schema ON schema.name = stat.name
            WHERE schema.type IN ('table', 'index')
              AND (
                    schema.name LIKE 'memory_segment%'
                 OR schema.name LIKE 'sqlite_autoindex_memory_segment%'
                 OR schema.tbl_name LIKE 'memory_segment%'
                 OR schema.name IN ('frame_key_sequence', 'frames_frame_key')
              )
            """,
            on: database
        )
        let objectLiveByteTotal = objectLiveBytes.reduce(Int64(0)) {
            $0 + $1.liveBytes
        }
        guard pageSize > 0,
              pageCount > 0,
              freelistPageCount >= 0,
              freelistPageCount <= pageCount,
              liveBytes > 0,
              shadowBytes > 0,
              shadowBytes < liveBytes,
              !dbstatObjects.isEmpty,
              objectLiveBytes.map(\.name) == dbstatObjects,
              objectLiveBytes.allSatisfy({ $0.liveBytes > 0 }),
              objectLiveBytes.allSatisfy({ $0.liveBytes % pageSize == 0 }),
              objectLiveByteTotal == shadowBytes else {
            throw PassageError.database("MemorySegment dbstat accounting was incomplete.")
        }
        return MemorySegmentStorageDiagnostics(
            pageSizeBytes: pageSize,
            pageCount: pageCount,
            freelistPageCount: freelistPageCount,
            liveDatabaseBytes: liveBytes,
            memorySegmentShadowBytes: shadowBytes,
            canonicalLiveBytes: liveBytes - shadowBytes,
            memorySegmentSchemaObjects: schemaObjects,
            memorySegmentDBStatObjects: dbstatObjects,
            memorySegmentObjectLiveBytes: objectLiveBytes
        )
    }
}

private func requireExactMemorySegmentStorageObjects(
    _ actualObjects: [String],
    source: String
) throws {
    let expected = Set(expectedMemorySegmentStorageObjects)
    let actual = Set(actualObjects)
    guard actualObjects == actualObjects.sorted(),
          actualObjects.count == actual.count,
          actual == expected else {
        let missing = expected.subtracting(actual).sorted()
        let unexpected = actual.subtracting(expected).sorted()
        throw PassageError.database(
            "MemorySegment \(source) object set did not match schema v3; "
                + "missing=[\(missing.joined(separator: ", "))], "
                + "unexpected=[\(unexpected.joined(separator: ", "))]."
        )
    }
}

private func memorySegmentDiagnosticObjectBytes(
    on database: OpaquePointer
) throws -> [MemorySegmentObjectStorageDiagnostics] {
    let sql =
        """
        SELECT stat.name, SUM(stat.pgsize)
        FROM dbstat AS stat
        JOIN sqlite_schema AS schema ON schema.name = stat.name
        WHERE schema.type IN ('table', 'index')
          AND (
                schema.name LIKE 'memory_segment%'
             OR schema.name LIKE 'sqlite_autoindex_memory_segment%'
             OR schema.tbl_name LIKE 'memory_segment%'
             OR schema.name IN ('frame_key_sequence', 'frames_frame_key')
          )
        GROUP BY stat.name
        ORDER BY stat.name
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw PassageError.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var values = [MemorySegmentObjectStorageDiagnostics]()
    while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return values }
        guard result == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        values.append(MemorySegmentObjectStorageDiagnostics(
            name: String(cString: text),
            liveBytes: sqlite3_column_int64(statement, 1)
        ))
    }
}

private func memorySegmentDiagnosticScalar(
    _ sql: String,
    on database: OpaquePointer
) throws -> Int64 {
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

private func memorySegmentDiagnosticStrings(
    _ sql: String,
    on database: OpaquePointer
) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw PassageError.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var values = [String]()
    while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return values }
        guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        values.append(String(cString: text))
    }
}
