import PassageCore
import CryptoKit
import Foundation
@preconcurrency import SQLCipher

private let memorySegmentSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

/// Lifecycle of Passage's rebuildable, SQLCipher-resident segment shadow.
/// Only `ready` is readable; every other state fails closed to an explicit
/// incomplete-index omission rather than exposing a partially rebuilt view.
enum MemorySegmentIndexLifecycle: String, Equatable, Sendable {
    case dirty
    case building
    case ready
}

struct MemorySegmentIndexStatus: Equatable, Sendable {
    /// The immutable generation selected by the state pointer in the same
    /// SQLite snapshot as the remainder of the operation. `nil` means there
    /// is no readable generation yet.
    var generationID: Int64?
    var lifecycle: MemorySegmentIndexLifecycle
    var revision: MemorySegmentIndexRevision?
    var revisionIsCurrent: Bool
    var canonicalFrameCount: Int
    var segmentCount: Int
    var hasPendingSessions: Bool
}

public enum MemorySegmentMaintenanceResult: Equatable, Sendable {
    case noWork
    case maintained(ActivitySessionID)
    /// The session remains queued. `atLeastFrameCount` is the bounded count
    /// observed by this maintenance slice; it is exactly one greater than the
    /// requested maximum and therefore a truthful lower bound.
    case deferred(ActivitySessionID, atLeastFrameCount: Int)
}

enum MemorySegmentIndex {
    static let schemaVersion = 4
    /// `frame_key` is the named durable identity. As an additional operational
    /// guardrail, Passage never VACUUMs a ready shadow without rebuilding it
    /// in the same maintenance operation.
    static let maximumFrameCount = 64
    static let maximumOverlayFrameCount = 2_048
    static let maximumOverlaySearchableBytes = 8 * 1_024 * 1_024
    static let nextDirtySessionSQL =
        """
        SELECT activity_session_id, dirty_version
        FROM memory_segment_dirty_sessions
             INDEXED BY memory_segment_dirty_sessions_order
        WHERE generation_id = ?
        ORDER BY first_enqueued_at ASC, activity_session_id ASC
        LIMIT 1
        """
    static let boundedMaintenanceFrameCountSQL =
        """
        SELECT COUNT(*)
        FROM (
            SELECT 1
            FROM frames INDEXED BY frames_activity_session
            WHERE activity_session_id = ?
            LIMIT ?
        )
        """
    static let fastUnfilteredPrivateFirstPageSQL =
        """
        SELECT segment.segment_key, segment.id, segment.revision_id,
               segment.search_content_revision, segment.bundle_identifier,
               segment.normalized_domain, segment.activity_session_id,
               segment.chunk_ordinal, segment.frame_count,
               segment.contains_sensitive, segment.started_at, segment.ended_at
        FROM memory_segments AS segment INDEXED BY memory_segments_order
        WHERE segment.generation_id = ?
        ORDER BY segment.ended_at DESC, segment.id DESC
        LIMIT ?
        """
    static let fastUnfilteredPrivateNextPageSQL =
        """
        SELECT segment.segment_key, segment.id, segment.revision_id,
               segment.search_content_revision, segment.bundle_identifier,
               segment.normalized_domain, segment.activity_session_id,
               segment.chunk_ordinal, segment.frame_count,
               segment.contains_sensitive, segment.started_at, segment.ended_at
        FROM memory_segments AS segment INDEXED BY memory_segments_order
        WHERE segment.generation_id = ?
          AND (segment.ended_at, segment.id) < (?, ?)
        ORDER BY segment.ended_at DESC, segment.id DESC
        LIMIT ?
        """

    static func boundedDirtyMatchingFrameSQL(matchPredicate: String) -> String {
        """
        SELECT frame.id, frame.activity_session_id
        FROM memory_segment_dirty_sessions AS dirty
        CROSS JOIN frames AS frame INDEXED BY frames_activity_session
        WHERE dirty.generation_id = ?
          AND frame.activity_session_id = dirty.activity_session_id
          AND \(matchPredicate)
        LIMIT \(maximumOverlayFrameCount + 1)
        """
    }

    /// The shadow lives in the same SQLCipher database as canonical frames.
    /// Canonical mutations enqueue only the affected activity sessions in the
    /// same transaction. A ready shadow remains useful for every clean session;
    /// retrieval reconstructs intersecting dirty sessions from canonical rows.
    static func migrate(on database: OpaquePointer) throws {
        try migrateGenerationSchema(on: database)
    }

    /// Installs the generation-qualified v4 schema in one crash-atomic writer
    /// transaction. A structurally and semantically valid ready v3 shadow is
    /// copied to generation 1. Every other legacy state starts with no active
    /// generation, which makes retrieval fail closed until a rebuild succeeds.
    private static func migrateGenerationSchema(on database: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            let stateTableExists = try tableExists(
                "memory_segment_index_state",
                on: database
            )
            let stateColumnNames = try columnNames(
                in: "memory_segment_index_state",
                on: database
            )
            let priorVersion: Int? = if stateTableExists,
                                        stateColumnNames.contains("schema_version") {
                try withStatement(
                    "SELECT schema_version FROM memory_segment_index_state WHERE singleton = 1",
                    on: database
                ) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                    return Int(sqlite3_column_int(statement, 0))
                }
            } else {
                nil
            }

            let v4StateColumns: Set<String> = [
                "singleton", "schema_version", "active_generation_id",
                "building_generation_id",
            ]
            let v4GenerationColumns: Set<String> = [
                "generation_id", "build_nonce", "lifecycle", "revision",
                "revision_is_current",
                "canonical_frame_count", "segment_count", "built_at",
            ]
            let v4SegmentColumns: Set<String> = [
                "generation_id", "segment_key", "id", "revision_id",
                "search_content_revision", "started_at", "ended_at",
                "bundle_identifier", "normalized_domain", "activity_session_id",
                "chunk_ordinal", "frame_count", "contains_sensitive",
            ]
            let v4MemberColumns: Set<String> = [
                "generation_id", "frame_key", "segment_key", "ordinal",
            ]
            let v4DirtyColumns: Set<String> = [
                "generation_id", "activity_session_id", "dirty_version",
                "reason_mask", "first_enqueued_at", "last_enqueued_at",
            ]
            let currentV4State = stateColumnNames == v4StateColumns
            let currentV4Generations = try columnNames(
                in: "memory_segment_generations",
                on: database
            ) == v4GenerationColumns
            let currentV4Segments = try columnNames(
                in: "memory_segments",
                on: database
            ) == v4SegmentColumns
            let currentV4Members = try columnNames(
                in: "memory_segment_members",
                on: database
            ) == v4MemberColumns
            let currentV4Dirty = try columnNames(
                in: "memory_segment_dirty_sessions",
                on: database
            ) == v4DirtyColumns
            let hasRequiredV4Structure = try generationSchemaHasRequiredStructure(
                on: database
            )
            let isCurrentV4 = priorVersion == schemaVersion
                && currentV4State
                && currentV4Generations
                && currentV4Segments
                && currentV4Members
                && currentV4Dirty
                && hasRequiredV4Structure

            if isCurrentV4 {
                try installGenerationTriggers(on: database)
                try execute("COMMIT", on: database)
                return
            }

            let preservableReadyV3 = try isPreservableReadyV3Shadow(on: database)
            let preserveReadyV3 = priorVersion == 3 && preservableReadyV3
            let hasLegacyState = try tableExists(
                "memory_segment_index_state",
                on: database
            )
            let hasLegacyDirty = try tableExists(
                "memory_segment_dirty_sessions",
                on: database
            )
            let hasLegacySegments = try tableExists("memory_segments", on: database)
            let hasLegacyMembers = try tableExists(
                "memory_segment_members",
                on: database
            )
            let hasRenameableV3Tables = priorVersion == 3
                && hasLegacyState && hasLegacyDirty
                && hasLegacySegments && hasLegacyMembers
            try dropMemorySegmentTriggers(on: database)

            if hasRenameableV3Tables {
                // These names cannot survive a committed migration because the
                // rename, copy, and drop are enclosed by this transaction.
                try execute(
                    """
                    DROP TABLE IF EXISTS memory_segment_members_v3_legacy;
                    DROP TABLE IF EXISTS memory_segments_v3_legacy;
                    DROP TABLE IF EXISTS memory_segment_dirty_sessions_v3_legacy;
                    DROP TABLE IF EXISTS memory_segment_index_state_v3_legacy;
                    ALTER TABLE memory_segment_members
                        RENAME TO memory_segment_members_v3_legacy;
                    ALTER TABLE memory_segments
                        RENAME TO memory_segments_v3_legacy;
                    ALTER TABLE memory_segment_dirty_sessions
                        RENAME TO memory_segment_dirty_sessions_v3_legacy;
                    ALTER TABLE memory_segment_index_state
                        RENAME TO memory_segment_index_state_v3_legacy;
                    DROP TABLE IF EXISTS memory_segment_generations;
                    """,
                    on: database
                )
            } else {
                // Unknown, incomplete, or pre-v3 shadows are rebuildable
                // derivatives. Removing them is safer than guessing lineage.
                try execute(
                    """
                    DROP TABLE IF EXISTS memory_segment_members;
                    DROP TABLE IF EXISTS memory_segments;
                    DROP TABLE IF EXISTS memory_segment_dirty_sessions;
                    DROP TABLE IF EXISTS memory_segment_index_state;
                    DROP TABLE IF EXISTS memory_segment_generations;
                    """,
                    on: database
                )
            }
            try execute("DROP TABLE IF EXISTS memory_segment_search", on: database)

            try createGenerationTables(on: database)
            if preserveReadyV3 {
                try execute(
                    """
                    INSERT INTO memory_segment_generations(
                        generation_id, build_nonce, lifecycle, revision,
                        revision_is_current,
                        canonical_frame_count, segment_count, built_at
                    )
                    SELECT 1, 'migrated-v3-generation-1', 'ready', revision,
                           revision_is_current,
                           canonical_frame_count, segment_count, built_at
                    FROM memory_segment_index_state_v3_legacy
                    WHERE singleton = 1;

                    INSERT INTO memory_segments(
                        generation_id, segment_key, id, revision_id,
                        search_content_revision, started_at, ended_at,
                        bundle_identifier, normalized_domain, activity_session_id,
                        chunk_ordinal, frame_count, contains_sensitive
                    )
                    SELECT 1, segment_key, id, revision_id,
                           search_content_revision, started_at, ended_at,
                           bundle_identifier, normalized_domain, activity_session_id,
                           chunk_ordinal, frame_count, contains_sensitive
                    FROM memory_segments_v3_legacy;

                    INSERT INTO memory_segment_members(
                        generation_id, frame_key, segment_key, ordinal
                    )
                    SELECT 1, frame_key, segment_key, ordinal
                    FROM memory_segment_members_v3_legacy;

                    INSERT INTO memory_segment_dirty_sessions(
                        generation_id, activity_session_id, dirty_version,
                        reason_mask, first_enqueued_at, last_enqueued_at
                    )
                    SELECT 1, activity_session_id, dirty_version,
                           reason_mask, first_enqueued_at, last_enqueued_at
                    FROM memory_segment_dirty_sessions_v3_legacy;

                    UPDATE memory_segment_index_state
                    SET active_generation_id = 1
                    WHERE singleton = 1;
                    """,
                    on: database
                )
            }
            if hasRenameableV3Tables {
                try execute(
                    """
                    DROP TABLE memory_segment_members_v3_legacy;
                    DROP TABLE memory_segments_v3_legacy;
                    DROP TABLE memory_segment_dirty_sessions_v3_legacy;
                    DROP TABLE memory_segment_index_state_v3_legacy;
                    """,
                    on: database
                )
            }
            try installGenerationTriggers(on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func createGenerationTables(on database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE memory_segment_generations (
                generation_id INTEGER PRIMARY KEY AUTOINCREMENT,
                build_nonce TEXT NOT NULL CHECK(length(build_nonce) > 0),
                lifecycle TEXT NOT NULL
                    CHECK(lifecycle IN ('building', 'ready', 'retired')),
                revision TEXT,
                revision_is_current INTEGER NOT NULL DEFAULT 0
                    CHECK(revision_is_current IN (0, 1)),
                canonical_frame_count INTEGER NOT NULL DEFAULT 0
                    CHECK(canonical_frame_count >= 0),
                segment_count INTEGER NOT NULL DEFAULT 0 CHECK(segment_count >= 0),
                built_at REAL,
                CHECK(
                    lifecycle IN ('building', 'retired')
                    OR (revision IS NOT NULL AND built_at IS NOT NULL)
                )
            );
            CREATE TABLE memory_segment_index_state (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                schema_version INTEGER NOT NULL CHECK(schema_version = 4),
                active_generation_id INTEGER,
                building_generation_id INTEGER,
                CHECK(
                    active_generation_id IS NULL
                    OR building_generation_id IS NULL
                    OR active_generation_id != building_generation_id
                ),
                FOREIGN KEY(active_generation_id)
                    REFERENCES memory_segment_generations(generation_id)
                    ON DELETE RESTRICT ON UPDATE RESTRICT,
                FOREIGN KEY(building_generation_id)
                    REFERENCES memory_segment_generations(generation_id)
                    ON DELETE SET NULL ON UPDATE RESTRICT
            );
            INSERT INTO memory_segment_index_state(
                singleton, schema_version, active_generation_id, building_generation_id
            ) VALUES (1, 4, NULL, NULL);

            CREATE TABLE memory_segments (
                segment_key INTEGER PRIMARY KEY NOT NULL,
                generation_id INTEGER NOT NULL,
                id TEXT NOT NULL,
                revision_id TEXT NOT NULL,
                search_content_revision TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                bundle_identifier TEXT NOT NULL,
                normalized_domain TEXT NOT NULL,
                activity_session_id TEXT NOT NULL,
                chunk_ordinal INTEGER NOT NULL CHECK(chunk_ordinal >= 0),
                frame_count INTEGER NOT NULL CHECK(frame_count BETWEEN 1 AND 64),
                contains_sensitive INTEGER NOT NULL CHECK(contains_sensitive IN (0, 1)),
                UNIQUE(generation_id, segment_key),
                UNIQUE(generation_id, id),
                UNIQUE(
                    generation_id, activity_session_id, bundle_identifier,
                    normalized_domain, chunk_ordinal
                ),
                FOREIGN KEY(generation_id)
                    REFERENCES memory_segment_generations(generation_id)
                    ON DELETE CASCADE ON UPDATE RESTRICT
            );
            CREATE INDEX memory_segments_order
                ON memory_segments(generation_id, ended_at DESC, id DESC);
            CREATE INDEX memory_segments_context_order
                ON memory_segments(
                    generation_id, bundle_identifier, normalized_domain,
                    ended_at DESC, id DESC
                );

            CREATE TABLE memory_segment_members (
                generation_id INTEGER NOT NULL,
                frame_key INTEGER NOT NULL,
                segment_key INTEGER NOT NULL,
                ordinal INTEGER NOT NULL CHECK(ordinal >= 0 AND ordinal < 64),
                PRIMARY KEY(generation_id, frame_key),
                UNIQUE(generation_id, segment_key, ordinal),
                FOREIGN KEY(frame_key) REFERENCES frames(frame_key)
                    ON DELETE CASCADE ON UPDATE RESTRICT,
                FOREIGN KEY(generation_id, segment_key)
                    REFERENCES memory_segments(generation_id, segment_key)
                    ON DELETE CASCADE ON UPDATE RESTRICT
            ) WITHOUT ROWID;

            CREATE TABLE memory_segment_dirty_sessions (
                generation_id INTEGER NOT NULL,
                activity_session_id TEXT NOT NULL,
                dirty_version INTEGER NOT NULL CHECK(dirty_version > 0),
                reason_mask INTEGER NOT NULL CHECK(reason_mask > 0),
                first_enqueued_at REAL NOT NULL,
                last_enqueued_at REAL NOT NULL,
                PRIMARY KEY(generation_id, activity_session_id),
                FOREIGN KEY(generation_id)
                    REFERENCES memory_segment_generations(generation_id)
                    ON DELETE CASCADE ON UPDATE RESTRICT
            ) WITHOUT ROWID;
            CREATE INDEX memory_segment_dirty_sessions_order
                ON memory_segment_dirty_sessions(
                    generation_id, first_enqueued_at, activity_session_id
                );
            """,
            on: database
        )
    }

    /// Column names alone cannot prove the constraints that make generations
    /// isolating. This rejects hand-built/partial v4 lookalikes (including the
    /// brief pre-retirement draft) so migration recreates them fail-closed.
    private static func generationSchemaHasRequiredStructure(
        on database: OpaquePointer
    ) throws -> Bool {
        func normalizedSQL(for name: String) throws -> String? {
            try withStatement(
                "SELECT sql FROM sqlite_master WHERE name = ? LIMIT 1",
                on: database
            ) { statement in
                bind(name, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let sql = string(statement, column: 0) else { return nil }
                return sql.lowercased().filter { !$0.isWhitespace }
            }
        }
        guard let generations = try normalizedSQL(for: "memory_segment_generations"),
              generations.contains("'retired'"),
              generations.contains("build_noncetext"),
              generations.contains("lifecyclein('building','retired')or"),
              let state = try normalizedSQL(for: "memory_segment_index_state"),
              state.contains("foreignkey(active_generation_id)referencesmemory_segment_generations"),
              state.contains("foreignkey(building_generation_id)referencesmemory_segment_generations"),
              let segments = try normalizedSQL(for: "memory_segments"),
              segments.contains("foreignkey(generation_id)referencesmemory_segment_generations"),
              let members = try normalizedSQL(for: "memory_segment_members"),
              members.contains("primarykey(generation_id,frame_key)"),
              members.contains("foreignkey(generation_id,segment_key)referencesmemory_segments"),
              let dirty = try normalizedSQL(for: "memory_segment_dirty_sessions"),
              dirty.contains("primarykey(generation_id,activity_session_id)"),
              dirty.contains("foreignkey(generation_id)referencesmemory_segment_generations"),
              let order = try normalizedSQL(for: "memory_segments_order"),
              order.contains("(generation_id,ended_atdesc,iddesc)"),
              let context = try normalizedSQL(for: "memory_segments_context_order"),
              context.contains("(generation_id,bundle_identifier,normalized_domain,ended_atdesc,iddesc)"),
              let dirtyOrder = try normalizedSQL(
                  for: "memory_segment_dirty_sessions_order"
              ),
              dirtyOrder.contains("(generation_id,first_enqueued_at,activity_session_id)")
        else {
            return false
        }
        return true
    }

    private static func isPreservableReadyV3Shadow(
        on database: OpaquePointer
    ) throws -> Bool {
        let expectedState: Set<String> = [
            "singleton", "schema_version", "lifecycle", "revision",
            "revision_is_current", "canonical_frame_count", "segment_count", "built_at",
        ]
        let expectedSegments: Set<String> = [
            "segment_key", "id", "revision_id", "search_content_revision",
            "started_at", "ended_at", "bundle_identifier", "normalized_domain",
            "activity_session_id", "chunk_ordinal", "frame_count", "contains_sensitive",
        ]
        let expectedMembers: Set<String> = ["frame_key", "segment_key", "ordinal"]
        let expectedDirty: Set<String> = [
            "activity_session_id", "dirty_version", "reason_mask",
            "first_enqueued_at", "last_enqueued_at",
        ]
        guard try columnNames(in: "memory_segment_index_state", on: database)
                == expectedState,
              try columnNames(in: "memory_segments", on: database) == expectedSegments,
              try columnNames(in: "memory_segment_members", on: database) == expectedMembers,
              try columnNames(in: "memory_segment_dirty_sessions", on: database)
                == expectedDirty else {
            return false
        }
        let ready = try withStatement(
            """
            SELECT lifecycle = 'ready'
                       AND revision IS NOT NULL AND revision != ''
                       AND built_at IS NOT NULL,
                   canonical_frame_count, segment_count
            FROM memory_segment_index_state
            WHERE singleton = 1 AND schema_version = 3
            """,
            on: database
        ) { statement -> (Bool, Int64, Int64)? in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (
                sqlite3_column_int(statement, 0) != 0,
                sqlite3_column_int64(statement, 1),
                sqlite3_column_int64(statement, 2)
            )
        }
        guard let ready, ready.0 else { return false }
        let canonicalCount = try scalarInt("SELECT COUNT(*) FROM frames", on: database)
        let segmentCount = try scalarInt("SELECT COUNT(*) FROM memory_segments", on: database)
        let invalidCount = try scalarInt(
            """
            SELECT
                (SELECT COUNT(*)
                 FROM frames
                 WHERE activity_session_id IS NULL
                    OR activity_session_id = '')
              + (SELECT COUNT(*)
                 FROM frames AS frame
                 WHERE NOT EXISTS (
                           SELECT 1
                           FROM memory_segment_dirty_sessions AS dirty
                           WHERE dirty.activity_session_id = frame.activity_session_id
                       )
                   AND (
                       frame.frame_key IS NULL
                       OR (SELECT COUNT(*)
                           FROM memory_segment_members AS member
                           WHERE member.frame_key = frame.frame_key) != 1
                       OR EXISTS (
                           SELECT 1
                           FROM memory_segment_members AS member
                           JOIN memory_segments AS segment
                             ON segment.segment_key = member.segment_key
                           WHERE member.frame_key = frame.frame_key
                             AND (
                                 segment.activity_session_id
                                     IS NOT frame.activity_session_id
                                 OR segment.bundle_identifier
                                     IS NOT TRIM(COALESCE(frame.bundle_identifier, ''))
                                 OR segment.normalized_domain
                                     IS NOT LOWER(TRIM(COALESCE(frame.domain, '')))
                             )
                       )
                   ))
              + (SELECT COUNT(*)
                 FROM memory_segment_members AS member
                 LEFT JOIN frames AS frame ON frame.frame_key = member.frame_key
                 LEFT JOIN memory_segments AS segment
                   ON segment.segment_key = member.segment_key
                 WHERE frame.frame_key IS NULL OR segment.segment_key IS NULL)
              + (SELECT COUNT(*)
                 FROM memory_segments AS segment
                 WHERE NOT EXISTS (
                           SELECT 1
                           FROM memory_segment_dirty_sessions AS dirty
                           WHERE dirty.activity_session_id = segment.activity_session_id
                       )
                   AND (
                       segment.frame_count != (
                           SELECT COUNT(*)
                           FROM memory_segment_members AS member
                           WHERE member.segment_key = segment.segment_key
                       )
                       OR EXISTS (
                           SELECT 1
                           FROM memory_segment_members AS member
                           JOIN frames AS frame
                             ON frame.frame_key = member.frame_key
                           WHERE member.segment_key = segment.segment_key
                             AND (
                                 frame.activity_session_id
                                     IS NOT segment.activity_session_id
                                 OR TRIM(COALESCE(frame.bundle_identifier, ''))
                                     IS NOT segment.bundle_identifier
                                 OR LOWER(TRIM(COALESCE(frame.domain, '')))
                                     IS NOT segment.normalized_domain
                             )
                       )
                   ))
              + (SELECT COUNT(*)
                 FROM memory_segment_dirty_sessions
                 WHERE activity_session_id = ''
                    OR dirty_version <= 0 OR reason_mask <= 0)
            """,
            on: database
        )
        let hasNoForeignKeyViolations = try foreignKeyViolationCount(
            table: "memory_segment_members",
            on: database
        ) == 0
        return ready.1 == canonicalCount
            && ready.2 == segmentCount
            && invalidCount == 0
            && hasNoForeignKeyViolations
    }

    private static func dropMemorySegmentTriggers(on database: OpaquePointer) throws {
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
            """,
            on: database
        )
    }

    private static func installGenerationTriggers(on database: OpaquePointer) throws {
        try dropMemorySegmentTriggers(on: database)
        try execute(
            """
            CREATE TRIGGER frames_memory_segment_insert
            AFTER INSERT ON frames BEGIN
                UPDATE memory_segment_generations
                SET canonical_frame_count = canonical_frame_count + 1,
                    revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, NEW.activity_session_id, 1, 1,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE NEW.activity_session_id IS NOT NULL
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
                UPDATE memory_segment_generations
                SET lifecycle = 'retired', revision_is_current = 0
                WHERE (NEW.activity_session_id IS NULL OR NEW.activity_session_id = '')
                  AND generation_id IN (
                      SELECT active_generation_id FROM memory_segment_index_state
                      WHERE singleton = 1 AND active_generation_id IS NOT NULL
                      UNION
                      SELECT building_generation_id FROM memory_segment_index_state
                      WHERE singleton = 1 AND building_generation_id IS NOT NULL
                  );
                UPDATE memory_segment_index_state
                SET active_generation_id = NULL, building_generation_id = NULL
                WHERE singleton = 1
                  AND (NEW.activity_session_id IS NULL OR NEW.activity_session_id = '');
            END;

            CREATE TRIGGER frames_memory_segment_delete
            AFTER DELETE ON frames BEGIN
                UPDATE memory_segment_generations
                SET canonical_frame_count = MAX(canonical_frame_count - 1, 0),
                    revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, OLD.activity_session_id, 1, 1,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE OLD.activity_session_id IS NOT NULL
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;

            CREATE TRIGGER frames_memory_segment_update
            AFTER UPDATE OF captured_at, application_name, bundle_identifier,
                            window_title, url, domain, ocr_text,
                            activity_session_id, accessibility_snapshot_hash,
                            is_sensitive, visual_fingerprint
            ON frames
            WHEN OLD.captured_at IS NOT NEW.captured_at
              OR OLD.application_name IS NOT NEW.application_name
              OR OLD.bundle_identifier IS NOT NEW.bundle_identifier
              OR OLD.window_title IS NOT NEW.window_title
              OR OLD.url IS NOT NEW.url
              OR OLD.domain IS NOT NEW.domain
              OR OLD.ocr_text IS NOT NEW.ocr_text
              OR OLD.activity_session_id IS NOT NEW.activity_session_id
              OR OLD.accessibility_snapshot_hash IS NOT NEW.accessibility_snapshot_hash
              OR OLD.is_sensitive IS NOT NEW.is_sensitive
              OR OLD.visual_fingerprint IS NOT NEW.visual_fingerprint
            BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, OLD.activity_session_id, 1,
                       (CASE WHEN OLD.captured_at IS NOT NEW.captured_at
                                  OR OLD.bundle_identifier IS NOT NEW.bundle_identifier
                                  OR OLD.domain IS NOT NEW.domain
                                  OR OLD.activity_session_id IS NOT NEW.activity_session_id
                             THEN 2 ELSE 0 END)
                       |
                       (CASE WHEN OLD.application_name IS NOT NEW.application_name
                                  OR OLD.window_title IS NOT NEW.window_title
                                  OR OLD.url IS NOT NEW.url
                                  OR OLD.ocr_text IS NOT NEW.ocr_text
                                  OR OLD.accessibility_snapshot_hash IS NOT NEW.accessibility_snapshot_hash
                                  OR OLD.is_sensitive IS NOT NEW.is_sensitive
                                  OR OLD.visual_fingerprint IS NOT NEW.visual_fingerprint
                             THEN 4 ELSE 0 END),
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE OLD.activity_session_id IS NOT NULL
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, NEW.activity_session_id, 1,
                       (CASE WHEN OLD.captured_at IS NOT NEW.captured_at
                                  OR OLD.bundle_identifier IS NOT NEW.bundle_identifier
                                  OR OLD.domain IS NOT NEW.domain
                                  OR OLD.activity_session_id IS NOT NEW.activity_session_id
                             THEN 2 ELSE 0 END)
                       |
                       (CASE WHEN OLD.application_name IS NOT NEW.application_name
                                  OR OLD.window_title IS NOT NEW.window_title
                                  OR OLD.url IS NOT NEW.url
                                  OR OLD.ocr_text IS NOT NEW.ocr_text
                                  OR OLD.accessibility_snapshot_hash IS NOT NEW.accessibility_snapshot_hash
                                  OR OLD.is_sensitive IS NOT NEW.is_sensitive
                                  OR OLD.visual_fingerprint IS NOT NEW.visual_fingerprint
                             THEN 4 ELSE 0 END),
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE NEW.activity_session_id IS NOT NULL
                  AND NEW.activity_session_id IS NOT OLD.activity_session_id
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
                UPDATE memory_segment_generations
                SET lifecycle = 'retired', revision_is_current = 0
                WHERE (NEW.activity_session_id IS NULL OR NEW.activity_session_id = '')
                  AND generation_id IN (
                      SELECT active_generation_id FROM memory_segment_index_state
                      WHERE singleton = 1 AND active_generation_id IS NOT NULL
                      UNION
                      SELECT building_generation_id FROM memory_segment_index_state
                      WHERE singleton = 1 AND building_generation_id IS NOT NULL
                  );
                UPDATE memory_segment_index_state
                SET active_generation_id = NULL, building_generation_id = NULL
                WHERE singleton = 1
                  AND (NEW.activity_session_id IS NULL OR NEW.activity_session_id = '');
            END;

            CREATE TRIGGER sessions_memory_segment_insert
            AFTER INSERT ON activity_sessions BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, NEW.id, 1, 8,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE 1
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;

            CREATE TRIGGER sessions_memory_segment_delete
            AFTER DELETE ON activity_sessions BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, OLD.id, 1, 8,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE 1
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;

            CREATE TRIGGER sessions_memory_segment_update
            AFTER UPDATE OF contains_sensitive ON activity_sessions
            WHEN OLD.contains_sensitive IS NOT NEW.contains_sensitive
            BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, NEW.id, 1, 16,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE 1
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;

            CREATE TRIGGER visual_memory_segment_insert
            AFTER INSERT ON visual_frame_embeddings BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, frame.activity_session_id, 1, 32,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM frames AS frame
                CROSS JOIN (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE frame.id = NEW.frame_id
                  AND frame.activity_session_id IS NOT NULL
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;

            CREATE TRIGGER visual_memory_segment_delete
            AFTER DELETE ON visual_frame_embeddings BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, frame.activity_session_id, 1, 32,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM frames AS frame
                CROSS JOIN (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE frame.id = OLD.frame_id
                  AND frame.activity_session_id IS NOT NULL
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;

            CREATE TRIGGER visual_memory_segment_update
            AFTER UPDATE OF frame_id, model_fingerprint, vector_id,
                            source_visual_fingerprint
            ON visual_frame_embeddings
            WHEN OLD.frame_id IS NOT NEW.frame_id
              OR OLD.model_fingerprint IS NOT NEW.model_fingerprint
              OR OLD.vector_id IS NOT NEW.vector_id
              OR OLD.source_visual_fingerprint IS NOT NEW.source_visual_fingerprint
            BEGIN
                UPDATE memory_segment_generations
                SET revision_is_current = 0
                WHERE generation_id IN (
                    SELECT active_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                );
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT target.generation_id, frame.activity_session_id, 1, 32,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM frames AS frame
                CROSS JOIN (
                    SELECT active_generation_id AS generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND active_generation_id IS NOT NULL
                    UNION
                    SELECT building_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1 AND building_generation_id IS NOT NULL
                ) AS target
                WHERE frame.id IN (OLD.frame_id, NEW.frame_id)
                  AND frame.activity_session_id IS NOT NULL
                GROUP BY target.generation_id, frame.activity_session_id
                ON CONFLICT(generation_id, activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            """,
            on: database
        )
    }

    /// Kept only as executable documentation for the v3 source shape used by
    /// the migration above. It is never called by a v4 store.
    private static func migrateLegacyV3(on database: OpaquePointer) throws {
        // Trigger replacement is itself a correctness boundary. Keeping the
        // state/table upgrade and every DROP/CREATE in one writer transaction
        // prevents another connection from committing an unqueued mutation in
        // a temporary trigger-free window.
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS memory_segment_index_state (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                    schema_version INTEGER NOT NULL,
                    lifecycle TEXT NOT NULL
                        CHECK(lifecycle IN ('dirty', 'building', 'ready')),
                    revision TEXT,
                    revision_is_current INTEGER NOT NULL DEFAULT 0
                        CHECK(revision_is_current IN (0, 1)),
                    canonical_frame_count INTEGER NOT NULL DEFAULT 0,
                    segment_count INTEGER NOT NULL DEFAULT 0,
                    built_at REAL
                );
                CREATE TABLE IF NOT EXISTS memory_segment_dirty_sessions (
                    activity_session_id TEXT PRIMARY KEY NOT NULL,
                    dirty_version INTEGER NOT NULL CHECK(dirty_version > 0),
                    reason_mask INTEGER NOT NULL CHECK(reason_mask > 0),
                    first_enqueued_at REAL NOT NULL,
                    last_enqueued_at REAL NOT NULL
                ) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS memory_segment_dirty_sessions_order
                    ON memory_segment_dirty_sessions(first_enqueued_at, activity_session_id);
                """,
                on: database
            )

            let stateColumns = try columnNames(
                in: "memory_segment_index_state",
                on: database
            )
            if !stateColumns.contains("revision_is_current") {
                // Existing v3 vaults did not record whether the persisted
                // full-rebuild revision still describes the current shadow.
                // Defaulting false keeps them on the generic exact path until
                // the next complete rebuild establishes that invariant.
                try execute(
                    """
                    ALTER TABLE memory_segment_index_state
                    ADD COLUMN revision_is_current INTEGER NOT NULL DEFAULT 0
                        CHECK(revision_is_current IN (0, 1))
                    """,
                    on: database
                )
            }

            let priorVersion = try withStatement(
                "SELECT schema_version FROM memory_segment_index_state WHERE singleton = 1",
                on: database
            ) { statement -> Int? in
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return Int(sqlite3_column_int(statement, 0))
            }
            let expectedColumns: Set<String> = [
                "segment_key", "id", "revision_id", "search_content_revision",
                "started_at", "ended_at", "bundle_identifier", "normalized_domain",
                "activity_session_id", "chunk_ordinal", "frame_count",
                "contains_sensitive",
            ]
            let expectedMemberColumns: Set<String> = [
                "frame_key", "segment_key", "ordinal",
            ]
            let existingColumns = try columnNames(in: "memory_segments", on: database)
            let existingMemberColumns = try columnNames(
                in: "memory_segment_members",
                on: database
            )
            let requiresRecreation = priorVersion != schemaVersion
                || existingColumns != expectedColumns
                || existingMemberColumns != expectedMemberColumns

            if priorVersion == nil {
                try execute(
                    """
                    INSERT INTO memory_segment_index_state(
                        singleton, schema_version, lifecycle, revision,
                        revision_is_current,
                        canonical_frame_count, segment_count, built_at
                    ) VALUES (1, 3, 'dirty', NULL, 0, 0, 0, NULL)
                    """,
                    on: database
                )
            } else if requiresRecreation {
                // The v2 payload/FTS generation is never copied forward. Mark
                // it unreadable before replacing every dependent shadow table;
                // the enclosing transaction makes this one atomic boundary.
                try execute(
                    """
                    UPDATE memory_segment_index_state
                    SET schema_version = 3, lifecycle = 'dirty', revision = NULL,
                        revision_is_current = 0,
                        canonical_frame_count = 0, segment_count = 0, built_at = NULL
                    WHERE singleton = 1;
                    """,
                    on: database
                )
            }
            if requiresRecreation {
                try execute(
                    """
                    DROP TABLE IF EXISTS memory_segment_search;
                    DROP TABLE IF EXISTS memory_segment_members;
                    DROP TABLE IF EXISTS memory_segments;
                    """,
                    on: database
                )
            } else {
                // A v3 vault never needs or maintains a duplicate segment FTS.
                try execute("DROP TABLE IF EXISTS memory_segment_search", on: database)
            }

            try execute(
                """
                CREATE TABLE IF NOT EXISTS memory_segments (
                    segment_key INTEGER PRIMARY KEY NOT NULL,
                    id TEXT NOT NULL UNIQUE,
                    revision_id TEXT NOT NULL,
                    search_content_revision TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL NOT NULL,
                    bundle_identifier TEXT NOT NULL,
                    normalized_domain TEXT NOT NULL,
                    activity_session_id TEXT NOT NULL,
                    chunk_ordinal INTEGER NOT NULL CHECK(chunk_ordinal >= 0),
                    frame_count INTEGER NOT NULL CHECK(frame_count BETWEEN 1 AND 64),
                    contains_sensitive INTEGER NOT NULL CHECK(contains_sensitive IN (0, 1)),
                    UNIQUE(
                        activity_session_id, bundle_identifier,
                        normalized_domain, chunk_ordinal
                    )
                );
                CREATE INDEX IF NOT EXISTS memory_segments_order
                    ON memory_segments(ended_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS memory_segments_context_order
                    ON memory_segments(
                        bundle_identifier, normalized_domain,
                        ended_at DESC, id DESC
                    );
                CREATE TABLE IF NOT EXISTS memory_segment_members (
                    frame_key INTEGER PRIMARY KEY NOT NULL,
                    segment_key INTEGER NOT NULL,
                    ordinal INTEGER NOT NULL CHECK(ordinal >= 0 AND ordinal < 64),
                    UNIQUE(segment_key, ordinal),
                    FOREIGN KEY(frame_key) REFERENCES frames(frame_key)
                        ON DELETE CASCADE ON UPDATE RESTRICT,
                    FOREIGN KEY(segment_key) REFERENCES memory_segments(segment_key)
                        ON DELETE CASCADE ON UPDATE RESTRICT
                );
                """,
                on: database
            )

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

            CREATE TRIGGER frames_memory_segment_insert
            AFTER INSERT ON frames BEGIN
                UPDATE memory_segment_index_state
                SET canonical_frame_count = CASE
                        WHEN lifecycle = 'ready' THEN canonical_frame_count + 1
                        ELSE canonical_frame_count
                    END,
                    revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT NEW.activity_session_id, 1, 1,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                WHERE NEW.activity_session_id IS NOT NULL
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER frames_memory_segment_delete
            AFTER DELETE ON frames BEGIN
                UPDATE memory_segment_index_state
                SET canonical_frame_count = CASE
                        WHEN lifecycle = 'ready'
                        THEN MAX(canonical_frame_count - 1, 0)
                        ELSE canonical_frame_count
                    END,
                    revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT OLD.activity_session_id, 1, 1,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                WHERE OLD.activity_session_id IS NOT NULL
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER frames_memory_segment_update
            AFTER UPDATE OF captured_at, application_name, bundle_identifier,
                            window_title, url, domain, ocr_text,
                            activity_session_id, accessibility_snapshot_hash,
                            is_sensitive, visual_fingerprint
            ON frames
            WHEN OLD.captured_at IS NOT NEW.captured_at
              OR OLD.application_name IS NOT NEW.application_name
              OR OLD.bundle_identifier IS NOT NEW.bundle_identifier
              OR OLD.window_title IS NOT NEW.window_title
              OR OLD.url IS NOT NEW.url
              OR OLD.domain IS NOT NEW.domain
              OR OLD.ocr_text IS NOT NEW.ocr_text
              OR OLD.activity_session_id IS NOT NEW.activity_session_id
              OR OLD.accessibility_snapshot_hash IS NOT NEW.accessibility_snapshot_hash
              OR OLD.is_sensitive IS NOT NEW.is_sensitive
              OR OLD.visual_fingerprint IS NOT NEW.visual_fingerprint
            BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT OLD.activity_session_id, 1,
                       (CASE WHEN OLD.captured_at IS NOT NEW.captured_at
                                  OR OLD.bundle_identifier IS NOT NEW.bundle_identifier
                                  OR OLD.domain IS NOT NEW.domain
                                  OR OLD.activity_session_id IS NOT NEW.activity_session_id
                             THEN 2 ELSE 0 END)
                       |
                       (CASE WHEN OLD.application_name IS NOT NEW.application_name
                                  OR OLD.window_title IS NOT NEW.window_title
                                  OR OLD.url IS NOT NEW.url
                                  OR OLD.ocr_text IS NOT NEW.ocr_text
                                  OR OLD.accessibility_snapshot_hash IS NOT NEW.accessibility_snapshot_hash
                                  OR OLD.is_sensitive IS NOT NEW.is_sensitive
                                  OR OLD.visual_fingerprint IS NOT NEW.visual_fingerprint
                             THEN 4 ELSE 0 END),
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                WHERE OLD.activity_session_id IS NOT NULL
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT NEW.activity_session_id, 1,
                       (CASE WHEN OLD.captured_at IS NOT NEW.captured_at
                                  OR OLD.bundle_identifier IS NOT NEW.bundle_identifier
                                  OR OLD.domain IS NOT NEW.domain
                                  OR OLD.activity_session_id IS NOT NEW.activity_session_id
                             THEN 2 ELSE 0 END)
                       |
                       (CASE WHEN OLD.application_name IS NOT NEW.application_name
                                  OR OLD.window_title IS NOT NEW.window_title
                                  OR OLD.url IS NOT NEW.url
                                  OR OLD.ocr_text IS NOT NEW.ocr_text
                                  OR OLD.accessibility_snapshot_hash IS NOT NEW.accessibility_snapshot_hash
                                  OR OLD.is_sensitive IS NOT NEW.is_sensitive
                                  OR OLD.visual_fingerprint IS NOT NEW.visual_fingerprint
                             THEN 4 ELSE 0 END),
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                WHERE NEW.activity_session_id IS NOT NULL
                  AND NEW.activity_session_id IS NOT OLD.activity_session_id
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER sessions_memory_segment_insert
            AFTER INSERT ON activity_sessions BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                ) VALUES (
                    NEW.id, 1, 8, CAST(strftime('%s', 'now') AS REAL),
                    CAST(strftime('%s', 'now') AS REAL)
                )
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER sessions_memory_segment_delete
            AFTER DELETE ON activity_sessions BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                ) VALUES (
                    OLD.id, 1, 8, CAST(strftime('%s', 'now') AS REAL),
                    CAST(strftime('%s', 'now') AS REAL)
                )
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER sessions_memory_segment_update
            AFTER UPDATE OF contains_sensitive ON activity_sessions
            WHEN OLD.contains_sensitive IS NOT NEW.contains_sensitive
            BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                ) VALUES (
                    NEW.id, 1, 16, CAST(strftime('%s', 'now') AS REAL),
                    CAST(strftime('%s', 'now') AS REAL)
                )
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER visual_memory_segment_insert
            AFTER INSERT ON visual_frame_embeddings
            BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT frame.activity_session_id, 1, 32,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM frames AS frame
                WHERE frame.id = NEW.frame_id
                  AND frame.activity_session_id IS NOT NULL
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER visual_memory_segment_delete
            AFTER DELETE ON visual_frame_embeddings
            BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT frame.activity_session_id, 1, 32,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM frames AS frame
                WHERE frame.id = OLD.frame_id
                  AND frame.activity_session_id IS NOT NULL
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            CREATE TRIGGER visual_memory_segment_update
            AFTER UPDATE OF frame_id, model_fingerprint, vector_id,
                            source_visual_fingerprint
            ON visual_frame_embeddings
            WHEN OLD.frame_id IS NOT NEW.frame_id
              OR OLD.model_fingerprint IS NOT NEW.model_fingerprint
              OR OLD.vector_id IS NOT NEW.vector_id
              OR OLD.source_visual_fingerprint IS NOT NEW.source_visual_fingerprint
            BEGIN
                UPDATE memory_segment_index_state
                SET revision_is_current = 0
                WHERE singleton = 1;
                INSERT INTO memory_segment_dirty_sessions(
                    activity_session_id, dirty_version, reason_mask,
                    first_enqueued_at, last_enqueued_at
                )
                SELECT frame.activity_session_id, 1, 32,
                       CAST(strftime('%s', 'now') AS REAL),
                       CAST(strftime('%s', 'now') AS REAL)
                FROM frames AS frame
                WHERE frame.id IN (OLD.frame_id, NEW.frame_id)
                  AND frame.activity_session_id IS NOT NULL
                GROUP BY frame.activity_session_id
                ON CONFLICT(activity_session_id) DO UPDATE SET
                    dirty_version = dirty_version + 1,
                    reason_mask = reason_mask | excluded.reason_mask,
                    last_enqueued_at = excluded.last_enqueued_at;
            END;
            """,
                on: database
            )
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    static func status(on database: OpaquePointer) throws -> MemorySegmentIndexStatus? {
        guard try tableExists("memory_segment_index_state", on: database),
              try tableExists("memory_segment_generations", on: database),
              try tableExists("memory_segment_dirty_sessions", on: database) else {
            return nil
        }
        return try withStatement(
            """
            SELECT state.schema_version, state.active_generation_id,
                   generation.lifecycle, generation.revision,
                   generation.revision_is_current,
                   generation.canonical_frame_count, generation.segment_count,
                   EXISTS(
                       SELECT 1 FROM memory_segment_dirty_sessions AS dirty
                       WHERE dirty.generation_id = state.active_generation_id
                       LIMIT 1
                   ),
                   state.building_generation_id
            FROM memory_segment_index_state AS state
            LEFT JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
            WHERE state.singleton = 1
            LIMIT 1
            """,
            on: database
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_int(statement, 0) == Int32(schemaVersion) else {
                return nil
            }
            if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                return MemorySegmentIndexStatus(
                    generationID: nil,
                    lifecycle: sqlite3_column_type(statement, 8) == SQLITE_NULL
                        ? .dirty : .building,
                    revision: nil,
                    revisionIsCurrent: false,
                    canonicalFrameCount: 0,
                    segmentCount: 0,
                    hasPendingSessions: false
                )
            }
            guard let lifecycleText = string(statement, column: 2),
                  lifecycleText == MemorySegmentIndexLifecycle.ready.rawValue,
                  let revisionText = string(statement, column: 3),
                  !revisionText.isEmpty else {
                // A dangling pointer or a non-ready active generation is
                // corruption, not an empty result set.
                return nil
            }
            return MemorySegmentIndexStatus(
                generationID: sqlite3_column_int64(statement, 1),
                lifecycle: .ready,
                revision: MemorySegmentIndexRevision(rawValue: revisionText),
                revisionIsCurrent: sqlite3_column_int(statement, 4) != 0,
                canonicalFrameCount: Int(sqlite3_column_int64(statement, 5)),
                segmentCount: Int(sqlite3_column_int64(statement, 6)),
                hasPendingSessions: sqlite3_column_int(statement, 7) != 0
            )
        }
    }

    /// Exact aggregate used only by explicit diagnostics/benchmarks. Runtime
    /// retrieval uses the O(1) `EXISTS` bit in `status(on:)` so a growing
    /// maintenance queue cannot add linear work to every query.
    static func pendingSessionCount(on database: OpaquePointer) throws -> Int {
        guard try tableExists("memory_segment_index_state", on: database),
              try tableExists("memory_segment_generations", on: database),
              try tableExists("memory_segment_dirty_sessions", on: database) else {
            return 0
        }
        return Int(try withStatement(
            """
            SELECT COUNT(dirty.activity_session_id)
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.active_generation_id
             AND generation.lifecycle = 'ready'
            LEFT JOIN memory_segment_dirty_sessions AS dirty
              ON dirty.generation_id = generation.generation_id
            WHERE state.singleton = 1 AND state.schema_version = 4
            """,
            on: database
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(on: database)
            }
            return sqlite3_column_int64(statement, 0)
        })
    }

    /// Rebuilds a complete copy-on-write generation from canonical frames.
    /// The building pointer is committed first, but the active pointer is not
    /// changed and no active row is deleted. Readers therefore continue using
    /// the old ready generation until validation and the final pointer swap
    /// commit atomically.
    static func rebuild(on database: OpaquePointer) throws -> MemorySegmentIndexRevision {
        guard try tableExists("memory_segment_index_state", on: database) else {
            try migrate(on: database)
            return try rebuild(on: database)
        }

        let buildingGenerationID: Int64
        let buildNonce = UUID().uuidString.lowercased()
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            // A prior interrupted monolithic build was never active. Clear its
            // pointer and derivative rows before allocating a fresh identity.
            try execute(
                """
                UPDATE memory_segment_index_state
                SET building_generation_id = NULL
                WHERE singleton = 1;
                DELETE FROM memory_segment_generations
                WHERE lifecycle = 'building'
                  AND generation_id NOT IN (
                      SELECT active_generation_id
                      FROM memory_segment_index_state
                      WHERE singleton = 1 AND active_generation_id IS NOT NULL
                  );
                """,
                on: database
            )
            let generationInsert = try prepare(
                """
                INSERT INTO memory_segment_generations(
                    build_nonce, lifecycle, revision, revision_is_current,
                    canonical_frame_count, segment_count, built_at
                ) VALUES (?, 'building', NULL, 0, 0, 0, NULL)
                """,
                on: database
            )
            defer { sqlite3_finalize(generationInsert) }
            bind(buildNonce, at: 1, to: generationInsert)
            try stepDone(generationInsert, on: database)
            buildingGenerationID = sqlite3_last_insert_rowid(database)
            let pointToBuilding = try prepare(
                """
                UPDATE memory_segment_index_state
                SET building_generation_id = ?
                WHERE singleton = 1 AND building_generation_id IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(pointToBuilding) }
            sqlite3_bind_int64(pointToBuilding, 1, buildingGenerationID)
            try stepDone(pointToBuilding, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Memory segment building generation could not be selected."
                )
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }

        do {
            try execute("BEGIN IMMEDIATE", on: database)
            let stillSelected = try withStatement(
                """
                SELECT EXISTS(
                    SELECT 1
                    FROM memory_segment_index_state AS state
                    JOIN memory_segment_generations AS generation
                      ON generation.generation_id = state.building_generation_id
                    WHERE state.singleton = 1
                      AND state.building_generation_id = ?
                      AND generation.lifecycle = 'building'
                )
                """,
                on: database
            ) { statement in
                sqlite3_bind_int64(statement, 1, buildingGenerationID)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw databaseError(on: database)
                }
                return sqlite3_column_int(statement, 0) != 0
            }
            guard stillSelected else {
                throw PassageError.database(
                    "Memory segment building generation was superseded."
                )
            }

            let source = try prepare(
                """
                SELECT frame.id,
                       frame.captured_at,
                       frame.application_name,
                       TRIM(COALESCE(frame.bundle_identifier, '')) AS normalized_bundle,
                       LOWER(TRIM(COALESCE(frame.domain, ''))) AS normalized_domain,
                       frame.activity_session_id,
                       frame.ocr_text,
                       frame.window_title,
                       frame.url,
                       frame.is_sensitive,
                       CASE
                           WHEN session.id IS NULL THEN 1
                           WHEN session.contains_sensitive != 0
                             OR session_privacy.contains_sensitive != 0
                           THEN 1 ELSE 0
                       END AS session_contains_sensitive,
                       CASE WHEN snapshot.content_hash IS NOT NULL
                            THEN HEX(frame.accessibility_snapshot_hash)
                       END,
                       COALESCE(snapshot.accessibility_text, ''),
                       (
                           SELECT GROUP_CONCAT(model_fingerprint, CHAR(31))
                           FROM (
                               SELECT association.model_fingerprint AS model_fingerprint
                               FROM visual_frame_embeddings AS association
                               WHERE association.frame_id = frame.id
                                 AND association.source_visual_fingerprint = frame.visual_fingerprint
                               ORDER BY association.model_fingerprint
                           )
                       ) AS visual_models,
                       frame.frame_key
                FROM frames AS frame
                LEFT JOIN activity_sessions AS session
                  ON session.id = frame.activity_session_id
                LEFT JOIN (
                    SELECT activity_session_id,
                           MAX(CASE WHEN is_sensitive != 0 THEN 1 ELSE 0 END)
                               AS contains_sensitive
                    FROM frames
                    WHERE activity_session_id IS NOT NULL
                    GROUP BY activity_session_id
                ) AS session_privacy
                  ON session_privacy.activity_session_id = frame.activity_session_id
                LEFT JOIN accessibility_snapshots AS snapshot
                  ON snapshot.content_hash = frame.accessibility_snapshot_hash
                ORDER BY frame.activity_session_id ASC,
                         normalized_bundle ASC,
                         normalized_domain ASC,
                         frame.captured_at ASC,
                         frame.id ASC
                """,
                on: database
            )
            defer { sqlite3_finalize(source) }
            let segmentInsert = try prepare(
                """
                INSERT INTO memory_segments(
                    generation_id, id, revision_id, search_content_revision,
                    started_at, ended_at, bundle_identifier,
                    normalized_domain, activity_session_id, chunk_ordinal,
                    frame_count, contains_sensitive
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(segmentInsert) }
            let memberInsert = try prepare(
                """
                INSERT INTO memory_segment_members(
                    generation_id, frame_key, segment_key, ordinal
                ) VALUES (?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(memberInsert) }

            var currentKey: BuildKey?
            var currentRows = [BuildFrame]()
            var chunkOrdinal = 0
            var revisions = [MemorySegmentRevisionID]()
            var segmentCount = 0
            var sourceFrameCount = 0

            func flushCurrentChunk() throws {
                guard let key = currentKey, !currentRows.isEmpty else { return }
                let built = try buildSegment(
                    key: key,
                    chunkOrdinal: chunkOrdinal,
                    rows: currentRows
                )

                sqlite3_bind_int64(segmentInsert, 1, buildingGenerationID)
                bind(built.segment.id.rawValue, at: 2, to: segmentInsert)
                bind(built.segment.revisionID.rawValue, at: 3, to: segmentInsert)
                bind(built.searchContentRevision.rawValue, at: 4, to: segmentInsert)
                sqlite3_bind_double(
                    segmentInsert,
                    5,
                    built.segment.scope.startDate!.timeIntervalSince1970
                )
                sqlite3_bind_double(
                    segmentInsert,
                    6,
                    built.segment.scope.endDate!.timeIntervalSince1970
                )
                bind(key.bundleIdentifier, at: 7, to: segmentInsert)
                bind(key.domain, at: 8, to: segmentInsert)
                bind(key.sessionID.rawValue, at: 9, to: segmentInsert)
                sqlite3_bind_int64(segmentInsert, 10, Int64(chunkOrdinal))
                sqlite3_bind_int64(segmentInsert, 11, Int64(currentRows.count))
                sqlite3_bind_int(segmentInsert, 12, built.segment.containsSensitive ? 1 : 0)
                try stepDone(segmentInsert, on: database)
                sqlite3_reset(segmentInsert)
                sqlite3_clear_bindings(segmentInsert)

                let segmentKey = sqlite3_last_insert_rowid(database)
                for (ordinal, row) in currentRows.enumerated() {
                    sqlite3_bind_int64(memberInsert, 1, buildingGenerationID)
                    sqlite3_bind_int64(memberInsert, 2, row.frameKey)
                    sqlite3_bind_int64(memberInsert, 3, segmentKey)
                    sqlite3_bind_int64(memberInsert, 4, Int64(ordinal))
                    try stepDone(memberInsert, on: database)
                    sqlite3_reset(memberInsert)
                    sqlite3_clear_bindings(memberInsert)
                }

                revisions.append(built.segment.revisionID)
                revisions.append(built.searchContentRevision)
                segmentCount += 1
                currentRows.removeAll(keepingCapacity: true)
            }

            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(source)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw databaseError(on: database)
                }
                let row = try decodeBuildFrame(source)
                sourceFrameCount += 1
                let key = BuildKey(
                    sessionID: row.sessionID,
                    bundleIdentifier: row.bundleIdentifier,
                    domain: row.domain
                )
                if currentKey != key {
                    try flushCurrentChunk()
                    currentKey = key
                    chunkOrdinal = 0
                } else if currentRows.count == maximumFrameCount {
                    try flushCurrentChunk()
                    chunkOrdinal += 1
                }
                currentRows.append(row)
            }
            try flushCurrentChunk()

            let canonicalFrameCount = Int(try scalarInt(
                "SELECT COUNT(*) FROM frames",
                on: database
            ))
            let memberCount = Int(try scalarInt(
                "SELECT COUNT(*) FROM memory_segment_members WHERE generation_id = \(buildingGenerationID)",
                on: database
            ))
            let distinctMemberCount = Int(try scalarInt(
                "SELECT COUNT(DISTINCT frame_key) FROM memory_segment_members WHERE generation_id = \(buildingGenerationID)",
                on: database
            ))
            let uncoveredCanonicalCount = try scalarInt(
                """
                SELECT COUNT(*)
                FROM frames AS frame
                LEFT JOIN memory_segment_members AS member
                  ON member.generation_id = \(buildingGenerationID)
                 AND member.frame_key = frame.frame_key
                WHERE frame.frame_key IS NULL OR member.frame_key IS NULL
                """,
                on: database
            )
            let invalidForeignKeyCount = try scalarInt(
                """
                SELECT COUNT(*)
                FROM memory_segment_members AS member
                LEFT JOIN frames AS frame ON frame.frame_key = member.frame_key
                LEFT JOIN memory_segments AS segment
                  ON segment.generation_id = member.generation_id
                 AND segment.segment_key = member.segment_key
                WHERE member.generation_id = \(buildingGenerationID)
                  AND (frame.frame_key IS NULL OR segment.segment_key IS NULL)
                """,
                on: database
            )
            let malformedSegmentCount = try scalarInt(
                """
                SELECT COUNT(*) FROM memory_segments AS segment
                WHERE segment.generation_id = \(buildingGenerationID)
                  AND (segment.frame_count != (
                    SELECT COUNT(*) FROM memory_segment_members AS member
                    WHERE member.generation_id = segment.generation_id
                      AND member.segment_key = segment.segment_key
                  ) OR segment.frame_count > 64)
                """,
                on: database
            )
            guard sourceFrameCount == canonicalFrameCount,
                  memberCount == canonicalFrameCount,
                  distinctMemberCount == canonicalFrameCount,
                  uncoveredCanonicalCount == 0,
                  invalidForeignKeyCount == 0,
                  malformedSegmentCount == 0 else {
                throw PassageError.database(
                    "Memory segment rebuild failed canonical-lineage validation."
                )
            }

            let revision = MemorySegmentIndexRevision.derived(from: revisions)
            // The rebuild and queue drain share this write transaction. Any
            // later canonical commit necessarily enqueues its affected session
            // again, so ready can never hide a mutation that the rebuild missed.
            try execute(
                "DELETE FROM memory_segment_dirty_sessions WHERE generation_id = \(buildingGenerationID)",
                on: database
            )
            let ready = try prepare(
                """
                UPDATE memory_segment_generations
                SET lifecycle = 'ready', revision = ?, canonical_frame_count = ?,
                    revision_is_current = 1, segment_count = ?, built_at = ?
                WHERE generation_id = ? AND build_nonce = ? AND lifecycle = 'building'
                """,
                on: database
            )
            defer { sqlite3_finalize(ready) }
            bind(revision.rawValue, at: 1, to: ready)
            sqlite3_bind_int64(ready, 2, Int64(canonicalFrameCount))
            sqlite3_bind_int64(ready, 3, Int64(segmentCount))
            sqlite3_bind_double(ready, 4, Date().timeIntervalSince1970)
            sqlite3_bind_int64(ready, 5, buildingGenerationID)
            bind(buildNonce, at: 6, to: ready)
            try stepDone(ready, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Memory segment generation changed during rebuild."
                )
            }
            let retireOld = try prepare(
                """
                UPDATE memory_segment_generations
                SET lifecycle = 'retired'
                WHERE generation_id = (
                    SELECT active_generation_id
                    FROM memory_segment_index_state
                    WHERE singleton = 1
                )
                  AND generation_id != ?
                  AND lifecycle = 'ready'
                """,
                on: database
            )
            defer { sqlite3_finalize(retireOld) }
            sqlite3_bind_int64(retireOld, 1, buildingGenerationID)
            try stepDone(retireOld, on: database)
            let swap = try prepare(
                """
                UPDATE memory_segment_index_state
                SET active_generation_id = ?, building_generation_id = NULL
                WHERE singleton = 1 AND building_generation_id = ?
                """,
                on: database
            )
            defer { sqlite3_finalize(swap) }
            sqlite3_bind_int64(swap, 1, buildingGenerationID)
            sqlite3_bind_int64(swap, 2, buildingGenerationID)
            try stepDone(swap, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Memory segment generation pointer changed during swap."
                )
            }
            try execute("COMMIT", on: database)
            return revision
        } catch {
            try? execute("ROLLBACK", on: database)
            try? execute("BEGIN IMMEDIATE", on: database)
            try? execute(
                """
                UPDATE memory_segment_index_state
                SET building_generation_id = NULL
                WHERE singleton = 1 AND building_generation_id = \(buildingGenerationID);
                DELETE FROM memory_segment_generations
                WHERE generation_id = \(buildingGenerationID)
                  AND lifecycle = 'building';
                """,
                on: database
            )
            try? execute("COMMIT", on: database)
            throw error
        }
    }

    /// Repairs one queued session in a bounded write transaction. Large
    /// sessions remain queued and continue to use the canonical retrieval
    /// overlay; callers can report that truthfully and defer copy-on-write
    /// generation work to a later maintenance slice.
    static func maintainNextSession(
        maxFrames: Int,
        on database: OpaquePointer
    ) throws -> MemorySegmentMaintenanceResult {
        guard maxFrames > 0 else {
            throw PassageError.invalidQuery(
                "Memory segment maintenance requires a positive frame bound."
            )
        }
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            guard let currentStatus = try status(on: database),
                  currentStatus.lifecycle == .ready,
                  currentStatus.revision != nil,
                  let generationID = currentStatus.generationID else {
                try execute("COMMIT", on: database)
                return .noWork
            }
            // Selection is a strict indexed FIFO read. Repairability is then
            // determined by touching at most maxFrames + 1 canonical rows for
            // that one session, never by counting every dirty session.
            let work: (sessionID: String, version: Int64)? = try withStatement(
                nextDirtySessionSQL,
                on: database
            ) { statement in
                sqlite3_bind_int64(statement, 1, generationID)
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let sessionID = string(statement, column: 0),
                      !sessionID.isEmpty else { return nil }
                return (
                    sessionID,
                    sqlite3_column_int64(statement, 1)
                )
            }
            guard let work else {
                try execute("COMMIT", on: database)
                return .noWork
            }

            let boundedLimit = maxFrames == Int.max
                ? Int64.max
                : Int64(maxFrames + 1)
            let canonicalFrameCount = try withStatement(
                boundedMaintenanceFrameCountSQL,
                on: database
            ) { statement in
                bind(work.sessionID, at: 1, to: statement)
                sqlite3_bind_int64(statement, 2, boundedLimit)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw databaseError(on: database)
                }
                return sqlite3_column_int64(statement, 0)
            }
            guard canonicalFrameCount <= Int64(maxFrames) else {
                try rotateDeferredSession(
                    work.sessionID,
                    expectedVersion: work.version,
                    generationID: generationID,
                    on: database
                )
                try execute("COMMIT", on: database)
                return .deferred(
                    ActivitySessionID(rawValue: work.sessionID),
                    atLeastFrameCount: Int(clamping: canonicalFrameCount)
                )
            }

            let oldSegmentCount = try affectedIndexedSegmentCount(
                for: work.sessionID,
                generationID: generationID,
                on: database
            )
            try deleteIndexedSession(
                work.sessionID,
                generationID: generationID,
                on: database
            )
            let inserted = try insertIndexedSession(
                work.sessionID,
                generationID: generationID,
                on: database
            )
            guard inserted.frameCount == canonicalFrameCount else {
                throw PassageError.database(
                    "Incremental memory segment repair lost canonical lineage."
                )
            }
            try validateIndexedSessionCoverage(
                work.sessionID,
                expectedFrameCount: canonicalFrameCount,
                generationID: generationID,
                on: database
            )

            let queueDelete = try prepare(
                """
                DELETE FROM memory_segment_dirty_sessions
                WHERE generation_id = ?
                  AND activity_session_id = ? AND dirty_version = ?
                """,
                on: database
            )
            defer { sqlite3_finalize(queueDelete) }
            sqlite3_bind_int64(queueDelete, 1, generationID)
            bind(work.sessionID, at: 2, to: queueDelete)
            sqlite3_bind_int64(queueDelete, 3, work.version)
            try stepDone(queueDelete, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Memory segment dirty version changed during repair."
                )
            }

            let generationUpdate = try prepare(
                """
                UPDATE memory_segment_generations
                SET segment_count = MAX(segment_count - ? + ?, 0),
                    revision_is_current = 0, built_at = ?
                WHERE generation_id = ? AND lifecycle = 'ready'
                """,
                on: database
            )
            defer { sqlite3_finalize(generationUpdate) }
            sqlite3_bind_int64(generationUpdate, 1, oldSegmentCount)
            sqlite3_bind_int64(generationUpdate, 2, inserted.segmentCount)
            sqlite3_bind_double(generationUpdate, 3, Date().timeIntervalSince1970)
            sqlite3_bind_int64(generationUpdate, 4, generationID)
            try stepDone(generationUpdate, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Memory segment readiness changed during repair."
                )
            }
            try execute("COMMIT", on: database)
            return .maintained(ActivitySessionID(rawValue: work.sessionID))
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Moves an oversized FIFO head strictly behind the current tail without
    /// scanning the queue. The version predicate preserves the same CAS
    /// boundary used when deleting successfully repaired work.
    private static func rotateDeferredSession(
        _ sessionID: String,
        expectedVersion: Int64,
        generationID: Int64,
        on database: OpaquePointer
    ) throws {
        let tailPosition = try withStatement(
            """
            SELECT first_enqueued_at
            FROM memory_segment_dirty_sessions
                 INDEXED BY memory_segment_dirty_sessions_order
            WHERE generation_id = ?
            ORDER BY first_enqueued_at DESC, activity_session_id DESC
            LIMIT 1
            """,
            on: database
        ) { statement -> Double in
            sqlite3_bind_int64(statement, 1, generationID)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(on: database)
            }
            return sqlite3_column_double(statement, 0)
        }
        let rotatedPosition = tailPosition.nextUp
        guard tailPosition.isFinite,
              rotatedPosition.isFinite,
              rotatedPosition > tailPosition else {
            throw PassageError.database(
                "Memory segment queue position cannot advance."
            )
        }

        let rotate = try prepare(
            """
            UPDATE memory_segment_dirty_sessions
            SET first_enqueued_at = ?
            WHERE generation_id = ?
              AND activity_session_id = ? AND dirty_version = ?
            """,
            on: database
        )
        defer { sqlite3_finalize(rotate) }
        sqlite3_bind_double(rotate, 1, rotatedPosition)
        sqlite3_bind_int64(rotate, 2, generationID)
        bind(sessionID, at: 3, to: rotate)
        sqlite3_bind_int64(rotate, 4, expectedVersion)
        try stepDone(rotate, on: database)
        guard sqlite3_changes(database) == 1 else {
            throw PassageError.database(
                "Memory segment dirty version changed during deferral."
            )
        }
    }

    private static func deleteIndexedSession(
        _ sessionID: String,
        generationID: Int64,
        on database: OpaquePointer
    ) throws {
        let affectedKeys =
            """
            SELECT segment_key
            FROM memory_segments
            WHERE generation_id = \(generationID)
              AND activity_session_id = ?
            UNION
            SELECT member.segment_key
            FROM frames AS current_frame
            JOIN memory_segment_members AS member
              ON member.generation_id = \(generationID)
             AND member.frame_key = current_frame.frame_key
            WHERE current_frame.activity_session_id = ?
            """
        let segmentDelete = try prepare(
            """
            WITH affected_keys(segment_key) AS (\(affectedKeys))
            DELETE FROM memory_segments
            WHERE generation_id = \(generationID)
              AND segment_key IN (SELECT segment_key FROM affected_keys)
            """,
            on: database
        )
        defer { sqlite3_finalize(segmentDelete) }
        bind(sessionID, at: 1, to: segmentDelete)
        bind(sessionID, at: 2, to: segmentDelete)
        try stepDone(segmentDelete, on: database)
    }

    private static func affectedIndexedSegmentCount(
        for sessionID: String,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> Int64 {
        try withStatement(
            """
            WITH affected_keys(segment_key) AS (
                SELECT segment_key
                FROM memory_segments
                WHERE generation_id = \(generationID)
                  AND activity_session_id = ?
                UNION
                SELECT member.segment_key
                FROM frames AS current_frame
                JOIN memory_segment_members AS member
                  ON member.generation_id = \(generationID)
                 AND member.frame_key = current_frame.frame_key
                WHERE current_frame.activity_session_id = ?
            )
            SELECT COUNT(*)
            FROM affected_keys
            """,
            on: database
        ) { statement in
            bind(sessionID, at: 1, to: statement)
            bind(sessionID, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(on: database)
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private static func validateIndexedSessionCoverage(
        _ sessionID: String,
        expectedFrameCount: Int64,
        generationID: Int64,
        on database: OpaquePointer
    ) throws {
        try withStatement(
            """
            SELECT
                (
                    SELECT COUNT(*)
                    FROM frames AS frame
                    WHERE frame.activity_session_id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM memory_segment_members AS member
                          WHERE member.generation_id = \(generationID)
                            AND member.frame_key = frame.frame_key
                      )
                ),
                (
                    SELECT COUNT(*)
                    FROM frames AS frame
                    JOIN memory_segment_members AS member
                      ON member.generation_id = \(generationID)
                     AND member.frame_key = frame.frame_key
                    WHERE frame.activity_session_id = ?
                ),
                (
                    SELECT COUNT(*)
                    FROM memory_segments AS segment
                    WHERE segment.generation_id = \(generationID)
                      AND segment.activity_session_id = ?
                      AND segment.frame_count != (
                          SELECT COUNT(*)
                          FROM memory_segment_members AS member
                          WHERE member.generation_id = segment.generation_id
                            AND member.segment_key = segment.segment_key
                      )
                ),
                (
                    SELECT COUNT(*)
                    FROM frames AS frame
                    JOIN memory_segment_members AS member
                      ON member.generation_id = \(generationID)
                     AND member.frame_key = frame.frame_key
                    JOIN memory_segments AS segment
                      ON segment.generation_id = member.generation_id
                     AND segment.segment_key = member.segment_key
                    WHERE frame.activity_session_id = ?
                      AND segment.activity_session_id != ?
                )
            """,
            on: database
        ) { statement in
            for index in Int32(1)...Int32(5) {
                bind(sessionID, at: index, to: statement)
            }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_int64(statement, 0) == 0,
                  sqlite3_column_int64(statement, 1) == expectedFrameCount,
                  sqlite3_column_int64(statement, 2) == 0,
                  sqlite3_column_int64(statement, 3) == 0 else {
                throw PassageError.database(
                    "Incremental memory segment repair failed exact canonical coverage."
                )
            }
        }
    }

    private static func insertIndexedSession(
        _ sessionID: String,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> (frameCount: Int64, segmentCount: Int64) {
        let source = try prepare(
            """
            SELECT frame.id,
                   frame.captured_at,
                   frame.application_name,
                   TRIM(COALESCE(frame.bundle_identifier, '')) AS normalized_bundle,
                   LOWER(TRIM(COALESCE(frame.domain, ''))) AS normalized_domain,
                   frame.activity_session_id,
                   frame.ocr_text,
                   frame.window_title,
                   frame.url,
                   frame.is_sensitive,
                   CASE
                       WHEN session.id IS NULL THEN 1
                       WHEN session.contains_sensitive != 0
                         OR EXISTS (
                             SELECT 1
                             FROM frames AS session_frame
                             WHERE session_frame.activity_session_id =
                                   frame.activity_session_id
                               AND session_frame.is_sensitive != 0
                         )
                       THEN 1 ELSE 0
                   END AS session_contains_sensitive,
                   CASE WHEN snapshot.content_hash IS NOT NULL
                        THEN HEX(frame.accessibility_snapshot_hash)
                   END,
                   COALESCE(snapshot.accessibility_text, ''),
                   (
                       SELECT GROUP_CONCAT(model_fingerprint, CHAR(31))
                       FROM (
                           SELECT association.model_fingerprint AS model_fingerprint
                           FROM visual_frame_embeddings AS association
                           WHERE association.frame_id = frame.id
                             AND association.source_visual_fingerprint = frame.visual_fingerprint
                           ORDER BY association.model_fingerprint
                       )
                   ) AS visual_models,
                   frame.frame_key
            FROM frames AS frame
            LEFT JOIN activity_sessions AS session
              ON session.id = frame.activity_session_id
            LEFT JOIN accessibility_snapshots AS snapshot
              ON snapshot.content_hash = frame.accessibility_snapshot_hash
            WHERE frame.activity_session_id = ?
            ORDER BY normalized_bundle ASC,
                     normalized_domain ASC,
                     frame.captured_at ASC,
                     frame.id ASC
            """,
            on: database
        )
        defer { sqlite3_finalize(source) }
        bind(sessionID, at: 1, to: source)
        let segmentInsert = try prepare(
            """
            INSERT INTO memory_segments(
                generation_id, id, revision_id, search_content_revision,
                started_at, ended_at, bundle_identifier,
                normalized_domain, activity_session_id, chunk_ordinal,
                frame_count, contains_sensitive
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        )
        defer { sqlite3_finalize(segmentInsert) }
        let memberInsert = try prepare(
            """
            INSERT INTO memory_segment_members(
                generation_id, frame_key, segment_key, ordinal
            ) VALUES (?, ?, ?, ?)
            """,
            on: database
        )
        defer { sqlite3_finalize(memberInsert) }

        var currentKey: BuildKey?
        var currentRows = [BuildFrame]()
        var chunkOrdinal = 0
        var frameCount: Int64 = 0
        var segmentCount: Int64 = 0

        func flush() throws {
            guard let key = currentKey, !currentRows.isEmpty else { return }
            let built = try buildSegment(
                key: key,
                chunkOrdinal: chunkOrdinal,
                rows: currentRows
            )
            sqlite3_bind_int64(segmentInsert, 1, generationID)
            bind(built.segment.id.rawValue, at: 2, to: segmentInsert)
            bind(built.segment.revisionID.rawValue, at: 3, to: segmentInsert)
            bind(built.searchContentRevision.rawValue, at: 4, to: segmentInsert)
            sqlite3_bind_double(
                segmentInsert,
                5,
                built.segment.scope.startDate!.timeIntervalSince1970
            )
            sqlite3_bind_double(
                segmentInsert,
                6,
                built.segment.scope.endDate!.timeIntervalSince1970
            )
            bind(key.bundleIdentifier, at: 7, to: segmentInsert)
            bind(key.domain, at: 8, to: segmentInsert)
            bind(key.sessionID.rawValue, at: 9, to: segmentInsert)
            sqlite3_bind_int64(segmentInsert, 10, Int64(chunkOrdinal))
            sqlite3_bind_int64(segmentInsert, 11, Int64(currentRows.count))
            sqlite3_bind_int(segmentInsert, 12, built.segment.containsSensitive ? 1 : 0)
            try stepDone(segmentInsert, on: database)
            sqlite3_reset(segmentInsert)
            sqlite3_clear_bindings(segmentInsert)

            let segmentKey = sqlite3_last_insert_rowid(database)
            for (ordinal, row) in currentRows.enumerated() {
                sqlite3_bind_int64(memberInsert, 1, generationID)
                sqlite3_bind_int64(memberInsert, 2, row.frameKey)
                sqlite3_bind_int64(memberInsert, 3, segmentKey)
                sqlite3_bind_int64(memberInsert, 4, Int64(ordinal))
                try stepDone(memberInsert, on: database)
                sqlite3_reset(memberInsert)
                sqlite3_clear_bindings(memberInsert)
            }
            segmentCount += 1
            currentRows.removeAll(keepingCapacity: true)
        }

        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(source)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError(on: database) }
            let row = try decodeBuildFrame(source)
            frameCount += 1
            let key = BuildKey(
                sessionID: row.sessionID,
                bundleIdentifier: row.bundleIdentifier,
                domain: row.domain
            )
            if currentKey != key {
                try flush()
                currentKey = key
                chunkOrdinal = 0
            } else if currentRows.count == maximumFrameCount {
                try flush()
                chunkOrdinal += 1
            }
            currentRows.append(row)
        }
        try flush()
        return (frameCount, segmentCount)
    }

    static func retrieve(
        _ request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary,
        on database: OpaquePointer
    ) throws -> MemorySegmentPage {
        try retrieveMeasuringHydration(
            request,
            boundary: boundary,
            on: database
        ).page
    }

    /// One-shot diagnostics for benchmarks and regression tests. The count is
    /// derived from this retrieval's local decode path; no mutable/global
    /// instrumentation is involved.
    static func retrieveMeasuringHydration(
        _ request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary,
        on database: OpaquePointer
    ) throws -> (page: MemorySegmentPage, hydratedCanonicalFrameCount: Int) {
        try execute("BEGIN DEFERRED", on: database)
        do {
            guard let status = try status(on: database),
                  status.lifecycle == .ready,
                  status.revision != nil,
                  let generationID = status.generationID else {
                let page = try incompletePage(request: request, boundary: boundary)
                try execute("COMMIT", on: database)
                return (page, 0)
            }

            // This first runtime slice only implements canonical saved-text
            // retrieval. A mixed request is not partially fulfilled because
            // that would misleadingly look like complete visual retrieval.
            if request.retrievalModalities.contains(.visualAppearance) {
                let page = try MemorySegmentPage(
                    accessBoundary: boundary,
                    scopeFingerprint: request.cursorScopeFingerprint,
                    revision: .derived(from: []),
                    segments: [],
                    nextCursor: nil,
                    hasMore: false,
                    omissions: [MemorySegmentOmission(reason: .unavailableModality)]
                )
                try execute("COMMIT", on: database)
                return (page, 0)
            }

            // A complete private browse can page the immutable rebuild
            // generation directly. The persisted revision is usable only
            // while every canonical mutation has left both the dirty queue
            // empty and the explicit validity bit intact. Incremental repair
            // deliberately leaves the bit false and falls through to the
            // generic content-derived revision path below.
            if boundary == .privateLocal,
               request.text.isEmpty,
               request.scope.startDate == nil,
               request.scope.endDate == nil,
               request.scope.applicationBundleIdentifiers.isEmpty,
               request.scope.domains.isEmpty,
               request.scope.activitySessionIDs.isEmpty,
               !status.hasPendingSessions,
               status.revisionIsCurrent,
               let revision = status.revision {
                let result = try fastUnfilteredPrivatePage(
                    request: request,
                    revision: revision,
                    generationID: generationID,
                    on: database
                )
                try execute("COMMIT", on: database)
                return result
            }

            // The encrypted shadow is only a candidate accelerator. Clean
            // sessions hydrate through it; queued sessions are reconstructed
            // directly from canonical rows in this same SQLite snapshot. Stale
            // shadow rows are therefore never candidates, while capture does
            // not make the entire ready index unavailable.
            let dirtyProjection: DirtyProjection
            if status.hasPendingSessions {
                dirtyProjection = try projectedDirtyCandidates(
                    request: request,
                    boundary: boundary,
                    generationID: generationID,
                    on: database
                )
            } else {
                // `status` and retrieval share this deferred transaction, so
                // an empty queue is a same-snapshot proof that no canonical
                // overlay work exists. Metadata requests must not touch the
                // million-row frames table merely to rediscover that fact.
                dirtyProjection = .available(
                    candidates: [],
                    hadUnsafeMatch: false,
                    hydratedCanonicalFrameCount: 0
                )
            }
            guard case .available(
                let dirtyCandidates,
                let dirtyUnsafeMatch,
                let dirtyHydratedFrameCount
            ) = dirtyProjection else {
                let page = try incompletePage(request: request, boundary: boundary)
                try execute("COMMIT", on: database)
                return (page, 0)
            }
            let cleanProjection = try cleanCandidateDescriptors(
                request: request,
                boundary: boundary,
                generationID: generationID,
                on: database
            )
            var candidates = cleanProjection.candidates
            candidates.append(contentsOf: dirtyCandidates)
            guard Set(candidates.map(\.sourceID)).count == candidates.count,
                  Set(candidates.map(\.projectedID)).count == candidates.count else {
                throw PassageError.database(
                    "Merged memory segment identities are not unique."
                )
            }
            candidates.sort { lhs, rhs in
                if lhs.projectedEndedAt == rhs.projectedEndedAt {
                    return lhs.projectedID > rhs.projectedID
                }
                return lhs.projectedEndedAt > rhs.projectedEndedAt
            }
            let revision = MemorySegmentIndexRevision.derived(
                from: candidates.flatMap {
                    [$0.sourceRevision, $0.searchContentRevision]
                }
            )
            if let cursor = request.after, cursor.revision != revision {
                throw MemorySegmentValidationError.cursorScopeMismatch
            }

            let pageStart: Int
            if let cursor = request.after {
                guard let position = decodeCursor(cursor.token),
                      let anchor = candidates.firstIndex(where: {
                          $0.projectedEndedAt == position.endedAt
                              && $0.projectedID == position.id
                      }) else {
                    // A token with a valid shape still cannot choose an
                    // arbitrary position inside a revision-bound snapshot.
                    throw MemorySegmentValidationError.cursorScopeMismatch
                }
                pageStart = candidates.index(after: anchor)
            } else {
                pageStart = candidates.startIndex
            }
            let descriptorWindow = Array(
                candidates.dropFirst(pageStart).prefix(request.limit + 1)
            )
            let hasMore = descriptorWindow.count > request.limit
            let selectedCandidates = Array(descriptorWindow.prefix(request.limit))
            let cleanSelected = selectedCandidates.filter { $0.segmentKey != nil }
            let cleanHydration = try hydrateCleanCandidates(
                cleanSelected,
                request: request,
                generationID: generationID,
                on: database
            )
            guard cleanHydration.hydratedCanonicalFrameCount
                    <= request.limit * maximumFrameCount else {
                throw PassageError.database(
                    "Clean memory segment hydration exceeded the selected page bound."
                )
            }
            let segments = try selectedCandidates.map { descriptor -> MemorySegment in
                if let overlaid = descriptor.overlaidSegment { return overlaid }
                guard let segmentKey = descriptor.segmentKey,
                      let hydrated = cleanHydration.segments[segmentKey] else {
                    throw PassageError.database(
                        "Selected memory segment was not hydrated."
                    )
                }
                return hydrated
            }

            var omissions = [MemorySegmentOmission]()
            if boundary == .agentSafe,
               cleanProjection.hadUnsafeMatch || dirtyUnsafeMatch {
                omissions.append(MemorySegmentOmission(reason: .policyFiltered))
            }

            let nextCursor: MemorySegmentCursor?
            if hasMore, let last = selectedCandidates.last {
                nextCursor = try MemorySegmentCursor(
                    token: encodeCursor(
                        endedAt: last.projectedEndedAt,
                        id: last.projectedID
                    ),
                    scopeFingerprint: request.cursorScopeFingerprint,
                    revision: revision
                )
            } else {
                nextCursor = nil
            }
            let page = try MemorySegmentPage(
                accessBoundary: boundary,
                scopeFingerprint: request.cursorScopeFingerprint,
                revision: revision,
                segments: segments,
                nextCursor: nextCursor,
                hasMore: hasMore,
                omissions: omissions
            )
            try execute("COMMIT", on: database)
            return (
                page,
                dirtyHydratedFrameCount
                    + cleanHydration.hydratedCanonicalFrameCount
            )
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func incompletePage(
        request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary
    ) throws -> MemorySegmentPage {
        try MemorySegmentPage(
            accessBoundary: boundary,
            scopeFingerprint: request.cursorScopeFingerprint,
            revision: .derived(from: []),
            segments: [],
            nextCursor: nil,
            hasMore: false,
            omissions: [MemorySegmentOmission(reason: .incompleteIndex)]
        )
    }

    /// Direct keyset page for a pristine full-rebuild generation. This is the
    /// million-row browse path: it decodes limit + 1 compact descriptors and
    /// hydrates at most limit × 64 canonical members.
    private static func fastUnfilteredPrivatePage(
        request: MemorySegmentRequest,
        revision: MemorySegmentIndexRevision,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> (page: MemorySegmentPage, hydratedCanonicalFrameCount: Int) {
        var cursorPosition: (endedAt: Double, id: String)?
        if let cursor = request.after {
            guard cursor.revision == revision,
                  let position = decodeCursor(cursor.token) else {
                throw MemorySegmentValidationError.cursorScopeMismatch
            }
            let anchorExists = try withStatement(
                """
                SELECT EXISTS(
                    SELECT 1 FROM memory_segments
                    WHERE generation_id = ? AND ended_at = ? AND id = ?
                )
                """,
                on: database
            ) { statement in
                sqlite3_bind_int64(statement, 1, generationID)
                sqlite3_bind_double(statement, 2, position.endedAt)
                bind(position.id, at: 3, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw databaseError(on: database)
                }
                return sqlite3_column_int(statement, 0) != 0
            }
            guard anchorExists else {
                throw MemorySegmentValidationError.cursorScopeMismatch
            }
            cursorPosition = position
        }

        let sql = cursorPosition == nil
            ? fastUnfilteredPrivateFirstPageSQL
            : fastUnfilteredPrivateNextPageSQL
        let descriptorWindow = try withStatement(sql, on: database) {
            statement -> [CandidateDescriptor] in
            var bindIndex: Int32 = 1
            sqlite3_bind_int64(statement, bindIndex, generationID)
            bindIndex += 1
            if let cursorPosition {
                sqlite3_bind_double(statement, bindIndex, cursorPosition.endedAt)
                bindIndex += 1
                bind(cursorPosition.id, at: bindIndex, to: statement)
                bindIndex += 1
            }
            sqlite3_bind_int64(statement, bindIndex, Int64(request.limit + 1))

            var descriptors = [CandidateDescriptor]()
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw databaseError(on: database) }
                descriptors.append(try decodeFullSourceDescriptor(statement))
            }
            return descriptors
        }
        let hasMore = descriptorWindow.count > request.limit
        let selected = Array(descriptorWindow.prefix(request.limit))
        let hydration = try hydrateCleanCandidates(
            selected,
            request: request,
            generationID: generationID,
            on: database
        )
        guard hydration.hydratedCanonicalFrameCount
                <= request.limit * maximumFrameCount else {
            throw PassageError.database(
                "Clean memory segment hydration exceeded the selected page bound."
            )
        }
        let segments = try selected.map { descriptor -> MemorySegment in
            guard let segmentKey = descriptor.segmentKey,
                  let segment = hydration.segments[segmentKey] else {
                throw PassageError.database(
                    "Selected memory segment was not hydrated."
                )
            }
            return segment
        }
        let nextCursor: MemorySegmentCursor?
        if hasMore, let last = selected.last {
            nextCursor = try MemorySegmentCursor(
                token: encodeCursor(
                    endedAt: last.projectedEndedAt,
                    id: last.projectedID
                ),
                scopeFingerprint: request.cursorScopeFingerprint,
                revision: revision
            )
        } else {
            nextCursor = nil
        }
        return (
            try MemorySegmentPage(
                accessBoundary: .privateLocal,
                scopeFingerprint: request.cursorScopeFingerprint,
                revision: revision,
                segments: segments,
                nextCursor: nextCursor,
                hasMore: hasMore,
                omissions: []
            ),
            hydration.hydratedCanonicalFrameCount
        )
    }

    /// Module-internal deterministic primitives shared with the forthcoming
    /// bounded generation builder. They are intentionally not public API.
    struct BuildKey: Equatable {
        var sessionID: ActivitySessionID
        var bundleIdentifier: String
        var domain: String
    }

    struct BuildFrame {
        var id: FrameID
        var frameKey: Int64
        var capturedAt: Date
        var applicationName: String
        var bundleIdentifier: String
        var domain: String
        var sessionID: ActivitySessionID
        var ocrText: String
        var windowTitle: String?
        var url: String?
        var containsSensitive: Bool
        var accessibilityFingerprint: String?
        var accessibilityText: String
        var visualModelFingerprint: String?
    }

    struct BuiltSegment {
        var segment: MemorySegment
        var searchContentRevision: MemorySegmentRevisionID
    }

    static func decodeBuildFrame(
        _ statement: OpaquePointer,
        columnOffset: Int32 = 0,
        allowMissingSessionAsSensitive: Bool = false
    ) throws -> BuildFrame {
        guard let id = string(statement, column: columnOffset), !id.isEmpty,
              let applicationName = string(statement, column: columnOffset + 2),
              let sessionID = string(statement, column: columnOffset + 5), !sessionID.isEmpty,
              sqlite3_column_type(statement, columnOffset + 14) != SQLITE_NULL,
              allowMissingSessionAsSensitive
                || sqlite3_column_type(statement, columnOffset + 10) != SQLITE_NULL else {
            throw PassageError.database(
                "Canonical frame is missing its materialized activity session."
            )
        }
        let visualModels = string(statement, column: columnOffset + 13)?
            .split(separator: Character(UnicodeScalar(31)))
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
        let accessibilityFingerprint = string(statement, column: columnOffset + 11)
            .flatMap { $0.isEmpty ? nil : $0.lowercased() }
        return BuildFrame(
            id: FrameID(rawValue: id),
            frameKey: sqlite3_column_int64(statement, columnOffset + 14),
            capturedAt: Date(
                timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 1)
            ),
            applicationName: applicationName,
            bundleIdentifier: string(statement, column: columnOffset + 3) ?? "",
            domain: string(statement, column: columnOffset + 4) ?? "",
            sessionID: ActivitySessionID(rawValue: sessionID),
            ocrText: string(statement, column: columnOffset + 6) ?? "",
            windowTitle: string(statement, column: columnOffset + 7),
            url: string(statement, column: columnOffset + 8),
            containsSensitive: sqlite3_column_int(statement, columnOffset + 9) != 0
                || sqlite3_column_type(statement, columnOffset + 10) == SQLITE_NULL
                || sqlite3_column_int(statement, columnOffset + 10) != 0,
            accessibilityFingerprint: accessibilityFingerprint,
            accessibilityText: string(statement, column: columnOffset + 12) ?? "",
            visualModelFingerprint: visualModels?.first
        )
    }

    static func buildSegment(
        key: BuildKey,
        chunkOrdinal: Int,
        rows: [BuildFrame]
    ) throws -> BuiltSegment {
        precondition(!rows.isEmpty && rows.count <= maximumFrameCount)
        let scope = try boundedScope(
            key: key,
            firstTimestamp: rows[0].capturedAt.timeIntervalSince1970,
            lastTimestamp: rows[rows.count - 1].capturedAt.timeIntervalSince1970
        )
        let frameIDs = rows.map(\.id)

        let ocrProvenance = try MemorySegmentModalityProvenance(
            producerIdentifier: "chronicle.ocr.canonical",
            producerRevision: "1",
            frameIDs: frameIDs
        )
        var coverage = [try MemorySegmentModalityCoverage(
            modality: .ocr,
            segmentFrameCount: rows.count,
            coveredFrameIDs: frameIDs,
            provenance: [ocrProvenance]
        )]

        let accessibilityGroups = Dictionary(grouping: rows.filter {
            $0.accessibilityFingerprint != nil
        }) { $0.accessibilityFingerprint! }
        let accessibilityIDs = rows.compactMap { row in
            row.accessibilityFingerprint == nil ? nil : row.id
        }
        if !accessibilityIDs.isEmpty {
            let provenance = try accessibilityGroups.keys.sorted().map { fingerprint in
                try MemorySegmentModalityProvenance(
                    producerIdentifier: "chronicle.accessibility.snapshot",
                    producerRevision: String(AccessibilitySnapshotSchema.currentVersion),
                    artifactFingerprint: fingerprint,
                    frameIDs: rows.filter {
                        $0.accessibilityFingerprint == fingerprint
                    }.map(\.id)
                )
            }
            coverage.append(try MemorySegmentModalityCoverage(
                modality: .accessibility,
                segmentFrameCount: rows.count,
                coveredFrameIDs: accessibilityIDs,
                provenance: provenance
            ))
        }

        let visualGroups = Dictionary(grouping: rows.filter {
            $0.visualModelFingerprint != nil
        }) { $0.visualModelFingerprint! }
        let visualIDs = rows.compactMap { row in
            row.visualModelFingerprint == nil ? nil : row.id
        }
        if !visualIDs.isEmpty {
            let provenance = try visualGroups.keys.sorted().map { fingerprint in
                try MemorySegmentModalityProvenance(
                    producerIdentifier: "chronicle.visual.embedding",
                    producerRevision: "1",
                    artifactFingerprint: fingerprint,
                    frameIDs: rows.filter {
                        $0.visualModelFingerprint == fingerprint
                    }.map(\.id)
                )
            }
            coverage.append(try MemorySegmentModalityCoverage(
                modality: .visualSimilarity,
                segmentFrameCount: rows.count,
                coveredFrameIDs: visualIDs,
                provenance: provenance
            ))
        }

        let representativeIndices = rows.count == 1 ? [0] : [0, rows.count - 1]
        let representatives = try representativeIndices.map { index in
            let row = rows[index]
            var modalities: [PassageMemoryEvidenceModality] = [.ocr]
            if row.accessibilityFingerprint != nil { modalities.append(.accessibility) }
            if row.visualModelFingerprint != nil { modalities.append(.visualSimilarity) }
            return try MemorySegmentRepresentativeEvidence(
                frameID: row.id,
                capturedAt: row.capturedAt,
                applicationName: normalizedApplicationName(row.applicationName),
                bundleIdentifier: key.bundleIdentifier.isEmpty ? nil : key.bundleIdentifier,
                domain: key.domain.isEmpty ? nil : key.domain,
                activitySessionID: key.sessionID,
                snippet: representativeSnippet(row),
                modalities: modalities
            )
        }
        let segment = try MemorySegment(
            scope: scope,
            frameIDs: frameIDs,
            representativeEvidence: representatives,
            modalityCoverage: coverage,
            containsSensitive: rows.contains(where: \.containsSensitive)
        )
        _ = chunkOrdinal // persisted by the caller; identity is contract-derived.
        return BuiltSegment(
            segment: segment,
            searchContentRevision: fullSourceSearchContentRevision(
                sourceSegmentID: segment.id.rawValue,
                rows: rows
            )
        )
    }

    private static func boundedScope(
        key: BuildKey,
        firstTimestamp: Double,
        lastTimestamp: Double
    ) throws -> MemorySegmentScope {
        // `Date` stores seconds relative to 2001, so the IEEE nextUp of a small
        // Unix timestamp can be rounded away while converting through that
        // reference epoch. A microsecond remains representable across the
        // supported macOS date range and preserves the half-open bound.
        let endTimestamp = lastTimestamp + 0.000_001
        guard firstTimestamp.isFinite, endTimestamp.isFinite else {
            throw PassageError.database("Canonical frame has an invalid capture date.")
        }
        return try MemorySegmentScope(
            startDate: Date(timeIntervalSince1970: firstTimestamp),
            endDate: Date(timeIntervalSince1970: endTimestamp),
            applicationBundleIdentifiers: key.bundleIdentifier.isEmpty
                ? [] : [key.bundleIdentifier],
            domains: key.domain.isEmpty ? [] : [key.domain],
            activitySessionIDs: [key.sessionID]
        )
    }

    private static func normalizedApplicationName(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Unknown app" : normalized
    }

    private static func representativeSnippet(_ row: BuildFrame) -> String {
        let candidates = [row.ocrText, row.accessibilityText, row.windowTitle ?? ""]
        let source = candidates.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? row.applicationName
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(512))
    }

    enum SQLValue {
        case text(String)
        case double(Double)
        case integer(Int64)
    }

    private struct SQLQuery {
        var sql: String
        var values: [SQLValue]
    }

    private struct CandidateDescriptor {
        var segmentKey: Int64?
        var sourceID: MemorySegmentID
        var sourceRevision: MemorySegmentRevisionID
        var searchContentRevision: MemorySegmentRevisionID
        var key: BuildKey
        var chunkOrdinal: Int
        var frameCount: Int
        var containsSensitive: Bool
        var projectedStartedAt: Double
        var projectedEndedAt: Double
        var projectedID: String
        var overlaidSegment: MemorySegment?
    }

    private struct CandidateProjection {
        var candidates: [CandidateDescriptor]
        var hadUnsafeMatch: Bool
    }

    private enum DirtyProjection {
        case available(
            candidates: [CandidateDescriptor],
            hadUnsafeMatch: Bool,
            hydratedCanonicalFrameCount: Int
        )
        case exceedsBound
    }

    private struct HydratedMember {
        var ordinal: Int
        var row: BuildFrame
        var matches: Bool
    }

    /// Enumerates compact source descriptors and their full-source revision
    /// leaves. No representative payload or canonical frame body is decoded.
    private static func cleanCandidateDescriptors(
        request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> CandidateProjection {
        if request.text.isEmpty,
           request.scope.startDate == nil,
           request.scope.endDate == nil {
            return try fullSourceCandidateDescriptors(
                request: request,
                boundary: boundary,
                generationID: generationID,
                on: database
            )
        }
        let match = canonicalFramePredicate(request: request, frameAlias: "frame")
        let query =
            """
            WITH matching AS MATERIALIZED (
                SELECT member.segment_key, member.ordinal,
                       frame.id AS frame_id, frame.captured_at
                FROM memory_segment_members AS member
                JOIN frames AS frame ON frame.frame_key = member.frame_key
                WHERE member.generation_id = ?
                  AND \(match.sql)
            ),
            projected_bounds AS (
                SELECT segment_key,
                       MIN(captured_at) AS projected_started_at,
                       MAX(captured_at) AS projected_last_at,
                       MIN(ordinal) AS first_matching_ordinal
                FROM matching
                GROUP BY segment_key
            )
            SELECT segment.segment_key, segment.id, segment.revision_id,
                   segment.search_content_revision, segment.bundle_identifier,
                   segment.normalized_domain, segment.activity_session_id,
                   segment.chunk_ordinal, segment.frame_count,
                   segment.contains_sensitive,
                   projected.projected_started_at,
                   projected.projected_last_at,
                   first_match.frame_id
            FROM projected_bounds AS projected
            JOIN memory_segments AS segment
              ON segment.generation_id = \(generationID)
             AND segment.segment_key = projected.segment_key
            JOIN matching AS first_match
              ON first_match.segment_key = projected.segment_key
             AND first_match.ordinal = projected.first_matching_ordinal
            WHERE NOT EXISTS (
                SELECT 1 FROM memory_segment_dirty_sessions AS dirty
                WHERE dirty.generation_id = segment.generation_id
                  AND dirty.activity_session_id = segment.activity_session_id
            )
            """
        return try withStatement(query, on: database) { statement in
            bind([.integer(generationID)] + match.values, to: statement)
            var candidates = [CandidateDescriptor]()
            var hadUnsafeMatch = false
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                      let sourceID = string(statement, column: 1), !sourceID.isEmpty,
                      let sourceRevision = string(statement, column: 2),
                      !sourceRevision.isEmpty,
                      let searchRevision = string(statement, column: 3),
                      !searchRevision.isEmpty,
                      let bundleIdentifier = string(statement, column: 4),
                      let domain = string(statement, column: 5),
                      let sessionID = string(statement, column: 6), !sessionID.isEmpty,
                      let firstFrameID = string(statement, column: 12),
                      !firstFrameID.isEmpty else {
                    throw databaseError(on: database)
                }
                let key = BuildKey(
                    sessionID: ActivitySessionID(rawValue: sessionID),
                    bundleIdentifier: bundleIdentifier,
                    domain: domain
                )
                let projectedScope = try boundedScope(
                    key: key,
                    firstTimestamp: sqlite3_column_double(statement, 10),
                    lastTimestamp: sqlite3_column_double(statement, 11)
                )
                let containsSensitive = sqlite3_column_int(statement, 9) != 0
                if boundary == .agentSafe, containsSensitive {
                    hadUnsafeMatch = true
                    continue
                }
                candidates.append(CandidateDescriptor(
                    segmentKey: sqlite3_column_int64(statement, 0),
                    sourceID: MemorySegmentID(rawValue: sourceID),
                    sourceRevision: MemorySegmentRevisionID(rawValue: sourceRevision),
                    searchContentRevision: MemorySegmentRevisionID(rawValue: searchRevision),
                    key: key,
                    chunkOrdinal: Int(sqlite3_column_int64(statement, 7)),
                    frameCount: Int(sqlite3_column_int64(statement, 8)),
                    containsSensitive: containsSensitive,
                    projectedStartedAt: projectedScope.startDate!.timeIntervalSince1970,
                    projectedEndedAt: projectedScope.endDate!.timeIntervalSince1970,
                    projectedID: projectedSegmentID(
                        scope: projectedScope,
                        firstFrameID: FrameID(rawValue: firstFrameID)
                    ),
                    overlaidSegment: nil
                ))
            }
            return CandidateProjection(
                candidates: candidates,
                hadUnsafeMatch: hadUnsafeMatch
            )
        }
    }

    /// Empty/time-unbounded browse scopes cover complete homogeneous chunks,
    /// so their projected identity is already present in the descriptor. This
    /// avoids touching the member/frame map merely to rediscover full coverage.
    private static func decodeFullSourceDescriptor(
        _ statement: OpaquePointer
    ) throws -> CandidateDescriptor {
        guard let sourceID = string(statement, column: 1), !sourceID.isEmpty,
              let sourceRevision = string(statement, column: 2),
              !sourceRevision.isEmpty,
              let searchRevision = string(statement, column: 3),
              !searchRevision.isEmpty,
              let bundleIdentifier = string(statement, column: 4),
              let domain = string(statement, column: 5),
              let sessionID = string(statement, column: 6), !sessionID.isEmpty else {
            throw PassageError.database(
                "Memory segment descriptor is missing required identity."
            )
        }
        return CandidateDescriptor(
            segmentKey: sqlite3_column_int64(statement, 0),
            sourceID: MemorySegmentID(rawValue: sourceID),
            sourceRevision: MemorySegmentRevisionID(rawValue: sourceRevision),
            searchContentRevision: MemorySegmentRevisionID(rawValue: searchRevision),
            key: BuildKey(
                sessionID: ActivitySessionID(rawValue: sessionID),
                bundleIdentifier: bundleIdentifier,
                domain: domain
            ),
            chunkOrdinal: Int(sqlite3_column_int64(statement, 7)),
            frameCount: Int(sqlite3_column_int64(statement, 8)),
            containsSensitive: sqlite3_column_int(statement, 9) != 0,
            projectedStartedAt: sqlite3_column_double(statement, 10),
            projectedEndedAt: sqlite3_column_double(statement, 11),
            projectedID: sourceID,
            overlaidSegment: nil
        )
    }

    private static func fullSourceCandidateDescriptors(
        request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> CandidateProjection {
        var clauses = [
            "segment.generation_id = ?",
            """
            NOT EXISTS (
                SELECT 1 FROM memory_segment_dirty_sessions AS dirty
                WHERE dirty.generation_id = segment.generation_id
                  AND dirty.activity_session_id = segment.activity_session_id
            )
            """,
        ]
        var values = [SQLValue.integer(generationID)]
        if !request.scope.applicationBundleIdentifiers.isEmpty {
            clauses.append(
                "segment.bundle_identifier IN (\(placeholders(request.scope.applicationBundleIdentifiers.count)))"
            )
            values += request.scope.applicationBundleIdentifiers.map(SQLValue.text)
        }
        if !request.scope.domains.isEmpty {
            clauses.append(
                "segment.normalized_domain IN (\(placeholders(request.scope.domains.count)))"
            )
            values += request.scope.domains.map(SQLValue.text)
        }
        if !request.scope.activitySessionIDs.isEmpty {
            clauses.append(
                "segment.activity_session_id IN (\(placeholders(request.scope.activitySessionIDs.count)))"
            )
            values += request.scope.activitySessionIDs.map { .text($0.rawValue) }
        }
        let query =
            """
            SELECT segment.segment_key, segment.id, segment.revision_id,
                   segment.search_content_revision, segment.bundle_identifier,
                   segment.normalized_domain, segment.activity_session_id,
                   segment.chunk_ordinal, segment.frame_count,
                   segment.contains_sensitive, segment.started_at, segment.ended_at
            FROM memory_segments AS segment
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY segment.ended_at DESC, segment.id DESC
            """
        return try withStatement(query, on: database) { statement in
            bind(values, to: statement)
            var candidates = [CandidateDescriptor]()
            var hadUnsafeMatch = false
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw databaseError(on: database) }
                let descriptor = try decodeFullSourceDescriptor(statement)
                if boundary == .agentSafe, descriptor.containsSensitive {
                    hadUnsafeMatch = true
                    continue
                }
                candidates.append(descriptor)
            }
            return CandidateProjection(
                candidates: candidates,
                hadUnsafeMatch: hadUnsafeMatch
            )
        }
    }

    /// Reconstructs bounded dirty sessions from canonical rows. These rows are
    /// already needed for the overlay, but their descriptor leaves deliberately
    /// use the same full-source revisions persisted by clean maintenance.
    private static func projectedDirtyCandidates(
        request: MemorySegmentRequest,
        boundary: MemorySegmentAccessBoundary,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> DirtyProjection {
        let match = canonicalFramePredicate(request: request, frameAlias: "frame")
        let matchingSQL = boundedDirtyMatchingFrameSQL(matchPredicate: match.sql)
        var matchingFrameIDs = Set<FrameID>()
        var sessionIDs = Set<String>()
        try withStatement(matchingSQL, on: database) { statement in
            bind([.integer(generationID)] + match.values, to: statement)
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                      let frameID = string(statement, column: 0), !frameID.isEmpty,
                      let sessionID = string(statement, column: 1), !sessionID.isEmpty else {
                    throw databaseError(on: database)
                }
                matchingFrameIDs.insert(FrameID(rawValue: frameID))
                sessionIDs.insert(sessionID)
                if matchingFrameIDs.count > maximumOverlayFrameCount { return }
            }
        }
        if matchingFrameIDs.count > maximumOverlayFrameCount {
            return .exceedsBound
        }
        guard !sessionIDs.isEmpty else {
            return .available(
                candidates: [],
                hadUnsafeMatch: false,
                hydratedCanonicalFrameCount: 0
            )
        }

        let orderedSessionIDs = sessionIDs.sorted()
        let sessionPlaceholders = placeholders(orderedSessionIDs.count)
        let metrics = try withStatement(
            """
            SELECT COUNT(*), COALESCE(SUM(searchable_bytes), 0)
            FROM (
                SELECT
                       length(CAST(COALESCE(frame.ocr_text, '') AS BLOB))
                     + length(CAST(COALESCE(snapshot.accessibility_text, '') AS BLOB))
                     + length(CAST(COALESCE(frame.window_title, '') AS BLOB))
                     + length(CAST(COALESCE(frame.application_name, '') AS BLOB))
                     + length(CAST(COALESCE(frame.url, '') AS BLOB))
                       AS searchable_bytes
                FROM frames AS frame
                LEFT JOIN accessibility_snapshots AS snapshot
                  ON snapshot.content_hash = frame.accessibility_snapshot_hash
                WHERE frame.activity_session_id IN (\(sessionPlaceholders))
                LIMIT \(maximumOverlayFrameCount + 1)
            )
            """,
            on: database
        ) { statement -> (frameCount: Int64, searchableBytes: Int64) in
            bind(orderedSessionIDs.map(SQLValue.text), to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(on: database)
            }
            return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
        }
        guard metrics.frameCount <= Int64(maximumOverlayFrameCount),
              metrics.searchableBytes <= Int64(maximumOverlaySearchableBytes) else {
            return .exceedsBound
        }

        let sourceSQL =
            """
            SELECT frame.id, frame.captured_at, frame.application_name,
                   TRIM(COALESCE(frame.bundle_identifier, '')) AS normalized_bundle,
                   LOWER(TRIM(COALESCE(frame.domain, ''))) AS normalized_domain,
                   frame.activity_session_id, frame.ocr_text, frame.window_title,
                   frame.url, frame.is_sensitive,
                   CASE
                       WHEN session.id IS NULL
                         OR session.contains_sensitive != 0
                         OR EXISTS (
                             SELECT 1 FROM frames AS session_frame
                             WHERE session_frame.activity_session_id = frame.activity_session_id
                               AND session_frame.is_sensitive != 0
                         )
                       THEN 1 ELSE 0
                   END AS session_contains_sensitive,
                   CASE WHEN snapshot.content_hash IS NOT NULL
                        THEN HEX(frame.accessibility_snapshot_hash)
                   END,
                   COALESCE(snapshot.accessibility_text, ''),
                   (
                       SELECT GROUP_CONCAT(model_fingerprint, CHAR(31))
                       FROM (
                           SELECT association.model_fingerprint AS model_fingerprint
                           FROM visual_frame_embeddings AS association
                           WHERE association.frame_id = frame.id
                             AND association.source_visual_fingerprint = frame.visual_fingerprint
                           ORDER BY association.model_fingerprint
                       )
                   ) AS visual_models,
                   frame.frame_key
            FROM frames AS frame
            LEFT JOIN activity_sessions AS session
              ON session.id = frame.activity_session_id
            LEFT JOIN accessibility_snapshots AS snapshot
              ON snapshot.content_hash = frame.accessibility_snapshot_hash
            WHERE frame.activity_session_id IN (\(sessionPlaceholders))
            ORDER BY frame.activity_session_id ASC, normalized_bundle ASC,
                     normalized_domain ASC, frame.captured_at ASC, frame.id ASC
            """
        return try withStatement(sourceSQL, on: database) { statement in
            bind(orderedSessionIDs.map(SQLValue.text), to: statement)
            var candidates = [CandidateDescriptor]()
            var hadUnsafeMatch = false
            var hydratedFrameCount = 0
            var currentKey: BuildKey?
            var currentRows = [BuildFrame]()
            var chunkOrdinal = 0

            func flush() throws {
                guard let key = currentKey, !currentRows.isEmpty else { return }
                defer { currentRows.removeAll(keepingCapacity: true) }
                let projectedRows = currentRows.filter { matchingFrameIDs.contains($0.id) }
                guard !projectedRows.isEmpty else { return }
                let source = try buildSegment(
                    key: key,
                    chunkOrdinal: chunkOrdinal,
                    rows: currentRows
                )
                if boundary == .agentSafe, source.segment.containsSensitive {
                    hadUnsafeMatch = true
                    return
                }
                let projected = try buildSegment(
                    key: key,
                    chunkOrdinal: chunkOrdinal,
                    rows: projectedRows
                )
                candidates.append(CandidateDescriptor(
                    segmentKey: nil,
                    sourceID: source.segment.id,
                    sourceRevision: source.segment.revisionID,
                    searchContentRevision: source.searchContentRevision,
                    key: key,
                    chunkOrdinal: chunkOrdinal,
                    frameCount: currentRows.count,
                    containsSensitive: source.segment.containsSensitive,
                    projectedStartedAt: projected.segment.scope.startDate!.timeIntervalSince1970,
                    projectedEndedAt: projected.segment.scope.endDate!.timeIntervalSince1970,
                    projectedID: projected.segment.id.rawValue,
                    overlaidSegment: projected.segment
                ))
            }

            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    try flush()
                    break
                }
                guard status == SQLITE_ROW else { throw databaseError(on: database) }
                let row = try decodeBuildFrame(statement, allowMissingSessionAsSensitive: true)
                hydratedFrameCount += 1
                let key = BuildKey(
                    sessionID: row.sessionID,
                    bundleIdentifier: row.bundleIdentifier,
                    domain: row.domain
                )
                if currentKey != key {
                    try flush()
                    currentKey = key
                    chunkOrdinal = 0
                } else if currentRows.count == maximumFrameCount {
                    try flush()
                    chunkOrdinal += 1
                }
                currentRows.append(row)
            }
            return .available(
                candidates: candidates,
                hadUnsafeMatch: hadUnsafeMatch,
                hydratedCanonicalFrameCount: hydratedFrameCount
            )
        }
    }

    /// Hydrates only clean source chunks selected by descriptor paging. Every
    /// stable key, count, ordinal, source identity, and full-source revision is
    /// revalidated against canonical rows before projected evidence is emitted.
    private static func hydrateCleanCandidates(
        _ descriptors: [CandidateDescriptor],
        request: MemorySegmentRequest,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> (segments: [Int64: MemorySegment], hydratedCanonicalFrameCount: Int) {
        let segmentKeys = try descriptors.map { descriptor -> Int64 in
            guard let segmentKey = descriptor.segmentKey else {
                throw PassageError.database("Dirty descriptor entered clean hydration.")
            }
            return segmentKey
        }
        guard !segmentKeys.isEmpty else { return ([:], 0) }
        guard Set(segmentKeys).count == segmentKeys.count else {
            throw PassageError.database("Selected clean segment keys are not unique.")
        }
        let match = canonicalFramePredicate(request: request, frameAlias: "canonical_frame")
        let query =
            """
            SELECT member.segment_key, member.ordinal, member.frame_key,
                   canonical_frame.frame_key,
                   canonical_frame.id, canonical_frame.captured_at,
                   canonical_frame.application_name,
                   TRIM(COALESCE(canonical_frame.bundle_identifier, '')),
                   LOWER(TRIM(COALESCE(canonical_frame.domain, ''))),
                   canonical_frame.activity_session_id, canonical_frame.ocr_text,
                   canonical_frame.window_title, canonical_frame.url,
                   canonical_frame.is_sensitive,
                   CASE
                       WHEN canonical_session.id IS NULL THEN 1
                       WHEN canonical_session.contains_sensitive != 0
                         OR EXISTS (
                             SELECT 1
                             FROM frames AS privacy_session_frame
                             WHERE privacy_session_frame.activity_session_id =
                                   canonical_frame.activity_session_id
                               AND privacy_session_frame.is_sensitive != 0
                         )
                       THEN 1 ELSE 0
                   END AS session_contains_sensitive,
                   CASE WHEN canonical_snapshot.content_hash IS NOT NULL
                        THEN HEX(canonical_frame.accessibility_snapshot_hash)
                   END,
                   COALESCE(canonical_snapshot.accessibility_text, ''),
                   (
                       SELECT GROUP_CONCAT(model_fingerprint, CHAR(31))
                       FROM (
                           SELECT association.model_fingerprint AS model_fingerprint
                           FROM visual_frame_embeddings AS association
                           WHERE association.frame_id = canonical_frame.id
                             AND association.source_visual_fingerprint =
                                 canonical_frame.visual_fingerprint
                           ORDER BY association.model_fingerprint
                       )
                   ) AS visual_models,
                   canonical_frame.frame_key,
                   CASE WHEN \(match.sql) THEN 1 ELSE 0 END AS is_matching
            FROM memory_segment_members AS member
            LEFT JOIN frames AS canonical_frame
              ON canonical_frame.frame_key = member.frame_key
            LEFT JOIN activity_sessions AS canonical_session
              ON canonical_session.id = canonical_frame.activity_session_id
            LEFT JOIN accessibility_snapshots AS canonical_snapshot
              ON canonical_snapshot.content_hash =
                 canonical_frame.accessibility_snapshot_hash
            WHERE member.generation_id = ?
              AND member.segment_key IN (\(placeholders(segmentKeys.count)))
            ORDER BY member.segment_key ASC, member.ordinal ASC
            """
        return try withStatement(query, on: database) { statement in
            bind(
                match.values
                    + [.integer(generationID)]
                    + segmentKeys.map(SQLValue.integer),
                to: statement
            )
            var members = [Int64: [HydratedMember]]()
            var hydratedFrameCount = 0
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                      sqlite3_column_type(statement, 3) != SQLITE_NULL else {
                    throw PassageError.database(
                        "Memory segment member lost its canonical frame key."
                    )
                }
                let segmentKey = sqlite3_column_int64(statement, 0)
                let memberFrameKey = sqlite3_column_int64(statement, 2)
                let canonicalFrameKey = sqlite3_column_int64(statement, 3)
                guard memberFrameKey == canonicalFrameKey else {
                    throw PassageError.database(
                        "Memory segment member resolved a different canonical frame key."
                    )
                }
                let row = try decodeBuildFrame(statement, columnOffset: 4)
                guard row.frameKey == memberFrameKey else {
                    throw PassageError.database(
                        "Memory segment hydration changed canonical frame identity."
                    )
                }
                hydratedFrameCount += 1
                members[segmentKey, default: []].append(HydratedMember(
                    ordinal: Int(sqlite3_column_int64(statement, 1)),
                    row: row,
                    matches: sqlite3_column_int(statement, 19) != 0
                ))
            }

            var segments = [Int64: MemorySegment]()
            for descriptor in descriptors {
                guard let segmentKey = descriptor.segmentKey,
                      let hydrated = members[segmentKey],
                      hydrated.count == descriptor.frameCount,
                      hydrated.count <= maximumFrameCount,
                      hydrated.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
                      Set(hydrated.map { $0.row.frameKey }).count == hydrated.count,
                      Set(hydrated.map { $0.row.id }).count == hydrated.count else {
                    throw PassageError.database(
                        "Memory segment hydration failed exact canonical coverage."
                    )
                }
                let sourceRows = hydrated.map(\.row)
                guard sourceRows.allSatisfy({ row in
                    row.sessionID == descriptor.key.sessionID
                        && row.bundleIdentifier == descriptor.key.bundleIdentifier
                        && row.domain == descriptor.key.domain
                }) else {
                    throw PassageError.database(
                        "Memory segment hydration crossed its source scope."
                    )
                }
                let source = try buildSegment(
                    key: descriptor.key,
                    chunkOrdinal: descriptor.chunkOrdinal,
                    rows: sourceRows
                )
                guard source.segment.id == descriptor.sourceID,
                      source.segment.revisionID == descriptor.sourceRevision,
                      source.searchContentRevision == descriptor.searchContentRevision,
                      source.segment.containsSensitive == descriptor.containsSensitive else {
                    throw PassageError.database(
                        "Memory segment descriptor failed source-revision validation."
                    )
                }
                let projectedRows = hydrated.filter(\.matches).map(\.row)
                guard !projectedRows.isEmpty else {
                    throw PassageError.database(
                        "Memory segment descriptor no longer has matching lineage."
                    )
                }
                let projected = try buildSegment(
                    key: descriptor.key,
                    chunkOrdinal: descriptor.chunkOrdinal,
                    rows: projectedRows
                ).segment
                guard projected.id.rawValue == descriptor.projectedID,
                      projected.scope.startDate!.timeIntervalSince1970
                        == descriptor.projectedStartedAt,
                      projected.scope.endDate!.timeIntervalSince1970
                        == descriptor.projectedEndedAt else {
                    throw PassageError.database(
                        "Memory segment projection disagreed with its paged descriptor."
                    )
                }
                segments[segmentKey] = projected
            }
            guard hydratedFrameCount <= descriptors.count * maximumFrameCount else {
                throw PassageError.database("Memory segment hydration exceeded its page bound.")
            }
            return (segments, hydratedFrameCount)
        }
    }

    private static func projectedSegmentID(
        scope: MemorySegmentScope,
        firstFrameID: FrameID
    ) -> String {
        var canonical = Data()
        appendRevisionString("chronicle.memory-segment.v1", to: &canonical)
        appendRevisionString(scope.fingerprint, to: &canonical)
        appendRevisionString(firstFrameID.rawValue, to: &canonical)
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `MemorySegment.revisionID` intentionally hashes bounded representative
    /// evidence. Cursor snapshots additionally bind every searchable field in
    /// the complete source chunk, including nonmatching/nonrepresentative rows.
    private static func fullSourceSearchContentRevision(
        sourceSegmentID: String,
        rows: [BuildFrame]
    ) -> MemorySegmentRevisionID {
        var canonical = Data()
        appendRevisionString("chronicle.memory-segment-search-content.v1", to: &canonical)
        appendRevisionString(sourceSegmentID, to: &canonical)
        appendRevisionInteger(rows.count, to: &canonical)
        for row in rows {
            appendRevisionString(row.id.rawValue, to: &canonical)
            appendRevisionBits(row.capturedAt.timeIntervalSince1970.bitPattern, to: &canonical)
            appendRevisionString(row.applicationName, to: &canonical)
            appendRevisionString(row.bundleIdentifier, to: &canonical)
            appendRevisionString(row.domain, to: &canonical)
            appendRevisionString(row.sessionID.rawValue, to: &canonical)
            appendRevisionString(row.ocrText, to: &canonical)
            appendRevisionOptionalString(row.windowTitle, to: &canonical)
            appendRevisionOptionalString(row.url, to: &canonical)
            canonical.append(row.containsSensitive ? 1 : 0)
            appendRevisionOptionalString(row.accessibilityFingerprint, to: &canonical)
            appendRevisionString(row.accessibilityText, to: &canonical)
            appendRevisionOptionalString(row.visualModelFingerprint, to: &canonical)
        }
        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        return MemorySegmentRevisionID(rawValue: "search:\(digest)")
    }

    private static func appendRevisionOptionalString(
        _ value: String?,
        to data: inout Data
    ) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendRevisionString(value, to: &data)
    }

    private static func appendRevisionString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendRevisionBits(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendRevisionInteger(_ value: Int, to data: inout Data) {
        appendRevisionBits(UInt64(value), to: &data)
    }

    private static func appendRevisionBits(_ value: UInt64, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func canonicalFramePredicate(
        request: MemorySegmentRequest,
        frameAlias: String
    ) -> SQLQuery {
        var clauses = ["1 = 1"]
        var values = [SQLValue]()
        if let startDate = request.scope.startDate {
            clauses.append("\(frameAlias).captured_at >= ?")
            values.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = request.scope.endDate {
            clauses.append("\(frameAlias).captured_at < ?")
            values.append(.double(endDate.timeIntervalSince1970))
        }
        if !request.scope.applicationBundleIdentifiers.isEmpty {
            clauses.append(
                "TRIM(COALESCE(\(frameAlias).bundle_identifier, '')) IN (\(placeholders(request.scope.applicationBundleIdentifiers.count)))"
            )
            values += request.scope.applicationBundleIdentifiers.map(SQLValue.text)
        }
        if !request.scope.domains.isEmpty {
            clauses.append(
                "LOWER(TRIM(COALESCE(\(frameAlias).domain, ''))) IN (\(placeholders(request.scope.domains.count)))"
            )
            values += request.scope.domains.map(SQLValue.text)
        }
        if !request.scope.activitySessionIDs.isEmpty {
            clauses.append(
                "\(frameAlias).activity_session_id IN (\(placeholders(request.scope.activitySessionIDs.count)))"
            )
            values += request.scope.activitySessionIDs.map {
                .text($0.rawValue)
            }
        }
        if !request.text.isEmpty {
            clauses.append(
                "\(frameAlias).id IN (SELECT frame_id FROM frame_search WHERE frame_search MATCH ?)"
            )
            values.append(.text(safeFTSExpression(request.text)))
        }
        return SQLQuery(sql: clauses.joined(separator: " AND "), values: values)
    }

    private static func safeFTSExpression(_ query: String) -> String {
        let tokens = query.split { !$0.isLetter && !$0.isNumber }
        guard !tokens.isEmpty else {
            return "\"passage_no_searchable_token_7f89d8f5\""
        }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " ")
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func encodeCursor(endedAt: Double, id: String) -> String {
        String(format: "%016llx:%@", endedAt.bitPattern, id)
    }

    private static func decodeCursor(_ token: String) -> (endedAt: Double, id: String)? {
        guard let separator = token.firstIndex(of: ":") else { return nil }
        let bitsText = String(token[..<separator])
        let id = String(token[token.index(after: separator)...])
        guard bitsText.count == 16,
              let bits = UInt64(bitsText, radix: 16),
              !id.isEmpty else { return nil }
        let endedAt = Double(bitPattern: bits)
        guard endedAt.isFinite else { return nil }
        return (endedAt, id)
    }

    static func bind(_ values: [SQLValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                bind(text, at: index, to: statement)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            }
        }
    }

    static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, memorySegmentSQLiteTransient)
    }

    static func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                memorySegmentSQLiteTransient
            )
        }
    }

    static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func tableExists(_ name: String, on database: OpaquePointer) throws -> Bool {
        try withStatement(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            on: database
        ) { statement in
            bind(name, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(on: database)
            }
            return sqlite3_column_int(statement, 0) != 0
        }
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
                  let name = string(statement, column: 1) else {
                throw databaseError(on: database)
            }
            names.insert(name)
        }
    }

    private static func foreignKeyViolationCount(
        table: String,
        on database: OpaquePointer
    ) throws -> Int64 {
        let statement = try prepare("PRAGMA foreign_key_check(\(table))", on: database)
        defer { sqlite3_finalize(statement) }
        var count: Int64 = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return count }
            guard status == SQLITE_ROW else { throw databaseError(on: database) }
            count += 1
        }
    }

    static func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int64 {
        try withStatement(sql, on: database) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(on: database)
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    static func withStatement<T>(
        _ sql: String,
        on database: OpaquePointer,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    static func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(on: database)
        }
        return statement
    }

    static func stepDone(_ statement: OpaquePointer, on database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(on: database)
        }
    }

    static func execute(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw PassageError.database(detail)
        }
    }

    static func databaseError(on database: OpaquePointer) -> PassageError {
        PassageError.database(String(cString: sqlite3_errmsg(database)))
    }
}

extension SQLiteFrameStore {
    /// Explicit maintenance hook for the first shadow-index slice. Capture and
    /// retention mutations invalidate the generation; a later incremental
    /// builder can replace this bounded correctness-first rebuild without
    /// changing the public retrieval contract.
    @discardableResult
    public func rebuildMemorySegmentIndex() throws -> MemorySegmentIndexRevision {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let revision = try MemorySegmentIndex.rebuild(on: lease.pointer)
        try connection.hardenFilePermissions()
        return revision
    }

    func memorySegmentIndexStatus() throws -> MemorySegmentIndexStatus? {
        let lease = try activeConnectionLease()
        defer { lease.release() }
        return try MemorySegmentIndex.status(on: lease.pointer)
    }

    /// Repairs one queued activity session without invalidating clean history.
    /// A `.deferred` result means the session remains safely served through the
    /// bounded canonical overlay and needs a later large-session builder.
    public func maintainNextMemorySegmentSession(
        maxFrames: Int = 512
    ) throws -> MemorySegmentMaintenanceResult {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let result = try MemorySegmentIndex.maintainNextSession(
            maxFrames: maxFrames,
            on: lease.pointer
        )
        if case .maintained = result {
            try connection.hardenFilePermissions()
        }
        return result
    }

    public func retrievePrivateMemorySegments(
        _ request: PrivateMemorySegmentRequest
    ) throws -> MemorySegmentPage {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        return try MemorySegmentIndex.retrieve(
            request.retrieval,
            boundary: .privateLocal,
            on: lease.pointer
        )
    }

    public func retrieveAgentSafeMemorySegments(
        _ request: AgentSafeMemorySegmentRequest
    ) throws -> MemorySegmentPage {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        return try MemorySegmentIndex.retrieve(
            request.retrieval,
            boundary: .agentSafe,
            on: lease.pointer
        )
    }
}
