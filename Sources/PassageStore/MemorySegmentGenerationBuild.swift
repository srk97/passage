import PassageCore
import Dispatch
import Foundation
@preconcurrency import SQLCipher

/// Durable authority for one selected memory-segment generation build.
///
/// The nonce is intentionally unpredictable and stored beside the generation.
/// Every advancing or cancelling mutation checks both values and the selected
/// building pointer in one SQLite writer transaction.
public struct MemorySegmentBuildTicket: Codable, Hashable, Sendable {
    public let generationID: Int64
    public let buildNonce: String

    init(generationID: Int64, buildNonce: String) {
        self.generationID = generationID
        self.buildNonce = buildNonce
    }
}

/// Independent row and writer-ownership limits for one build slice.
public struct MemorySegmentBuildSliceLimits: Hashable, Sendable {
    public static let maximumFrames = 4_096

    public let maxFrames: Int
    public let maxWallDuration: TimeInterval
    let testingSQLiteInterruptAfterRows: Int?

    public init(
        maxFrames: Int = 512,
        maxWallDuration: TimeInterval = 0.012
    ) throws {
        try self.init(
            maxFrames: maxFrames,
            maxWallDuration: maxWallDuration,
            testingSQLiteInterruptAfterRows: nil
        )
    }

    init(
        maxFrames: Int,
        maxWallDuration: TimeInterval,
        testingSQLiteInterruptAfterRows: Int?
    ) throws {
        guard (1...Self.maximumFrames).contains(maxFrames) else {
            throw PassageError.invalidQuery(
                "A memory-segment build slice must allow between 1 and \(Self.maximumFrames) frames."
            )
        }
        guard maxWallDuration.isFinite, maxWallDuration > 0 else {
            throw PassageError.invalidQuery(
                "A memory-segment build slice must have a positive finite wall duration."
            )
        }
        if let testingSQLiteInterruptAfterRows {
            guard (1..<maxFrames).contains(testingSQLiteInterruptAfterRows) else {
                throw PassageError.invalidQuery(
                    "A test SQLite interruption must follow a row within the slice limit."
                )
            }
        }
        self.maxFrames = maxFrames
        self.maxWallDuration = maxWallDuration
        self.testingSQLiteInterruptAfterRows = testingSQLiteInterruptAfterRows
    }
}

/// Durable phase names are part of the encrypted progress-row contract. Later
/// repair and validation slices can advance these values without changing the
/// ticket or the active/building generation isolation model.
public enum MemorySegmentBuildPhase: String, Codable, Hashable, Sendable {
    case seeding
    case catchingUp = "catching_up"
    case repairing
    case validating
    case activating
    case cancelled
}

public struct MemorySegmentBuildProgress: Codable, Hashable, Sendable {
    public let generationID: Int64
    public let phase: MemorySegmentBuildPhase
    public let seedHighWaterFrameKey: Int64
    public let seedCursorFrameKey: Int64
    public let seedFramesVisited: Int64
    public let seedSessionsEnqueued: Int64
    public let completedSliceCount: Int64
    public let deadlineYieldCount: Int64
    public let validationCursorSegmentKey: Int64
    public let validationEpoch: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public let cancelledAt: Date?

    public var seedIsComplete: Bool {
        seedCursorFrameKey >= seedHighWaterFrameKey
            && phase != .seeding
            && phase != .cancelled
    }
}

public enum MemorySegmentBuildSliceDisposition: String, Codable, Hashable, Sendable {
    case progressed
    case phaseAdvanced = "phase_advanced"
    case activated
    case superseded
    case noWork = "no_work"
}

/// Per-call and cumulative evidence needed by the lifecycle benchmark without
/// requiring it to infer progress from partially written derivative rows.
public struct MemorySegmentBuildSliceResult: Codable, Hashable, Sendable {
    public let disposition: MemorySegmentBuildSliceDisposition
    public let progress: MemorySegmentBuildProgress?
    public let canonicalRowsVisited: Int
    public let sqliteRowsChanged: Int
    public let sessionsEnqueued: Int
    public let hitFrameLimit: Bool
    public let hitWallDeadline: Bool
    public let sqliteProgressInterrupted: Bool
    public let callWallDuration: TimeInterval
    public let writerWallDuration: TimeInterval

    init(
        disposition: MemorySegmentBuildSliceDisposition,
        progress: MemorySegmentBuildProgress?,
        canonicalRowsVisited: Int,
        sqliteRowsChanged: Int,
        sessionsEnqueued: Int,
        hitFrameLimit: Bool,
        hitWallDeadline: Bool,
        sqliteProgressInterrupted: Bool,
        callWallDuration: TimeInterval,
        writerWallDuration: TimeInterval
    ) {
        self.disposition = disposition
        self.progress = progress
        self.canonicalRowsVisited = canonicalRowsVisited
        self.sqliteRowsChanged = sqliteRowsChanged
        self.sessionsEnqueued = sessionsEnqueued
        self.hitFrameLimit = hitFrameLimit
        self.hitWallDeadline = hitWallDeadline
        self.sqliteProgressInterrupted = sqliteProgressInterrupted
        self.callWallDuration = callWallDuration
        self.writerWallDuration = writerWallDuration
    }
}

private struct MemorySegmentSeedFrame {
    let frameKey: Int64
    let activitySessionID: String?
}

private struct MemorySegmentProgressColumnContract: Equatable {
    let name: String
    let type: String
    let isNotNull: Bool
    let defaultSQL: String?
    let primaryKeyOrdinal: Int32
}

private struct MemorySegmentProgressForeignKeyContract: Equatable {
    let table: String
    let sourceColumn: String
    let targetColumn: String
    let updateAction: String
    let deleteAction: String
}

private final class MemorySegmentBuildDeadlineContext: @unchecked Sendable {
    let deadline: UInt64
    let testingSQLiteInterruptAfterRows: Int?
    var deadlineReached = false
    var cancellationObserved = false
    var selectedRowsReturned = 0
    var testingInterruptObserved = false

    init(deadline: UInt64, testingSQLiteInterruptAfterRows: Int?) {
        self.deadline = deadline
        self.testingSQLiteInterruptAfterRows = testingSQLiteInterruptAfterRows
    }
}

private let memorySegmentBuildProgressCallback: @convention(c) (
    UnsafeMutableRawPointer?
) -> Int32 = { rawContext in
    guard let rawContext else { return 0 }
    let context = Unmanaged<MemorySegmentBuildDeadlineContext>
        .fromOpaque(rawContext)
        .takeUnretainedValue()
    let isCancelled = withUnsafeCurrentTask { task in
        task?.isCancelled == true
    }
    if isCancelled {
        context.cancellationObserved = true
        return 1
    }
    if DispatchTime.now().uptimeNanoseconds >= context.deadline {
        context.deadlineReached = true
        return 1
    }
    if let interruptAfterRows = context.testingSQLiteInterruptAfterRows,
       context.selectedRowsReturned >= interruptAfterRows {
        context.testingInterruptObserved = true
        return 1
    }
    return 0
}

private enum MemorySegmentGenerationBuilder {
    /// This table is deliberately lazy-created by `begin` in the first builder
    /// slice. The eager v4 migration will adopt the exact shape once repair,
    /// validation, activation, and cleanup schemas are frozen together.
    static let createProgressTableSQL =
        """
        CREATE TABLE IF NOT EXISTS memory_segment_generation_progress (
            generation_id INTEGER PRIMARY KEY NOT NULL,
            build_nonce TEXT NOT NULL CHECK(length(build_nonce) > 0),
            phase TEXT NOT NULL CHECK(
                phase IN (
                    'seeding', 'catching_up', 'repairing',
                    'validating', 'activating', 'cancelled'
                )
            ),
            seed_high_water_frame_key INTEGER NOT NULL
                CHECK(seed_high_water_frame_key >= 0),
            seed_cursor_frame_key INTEGER NOT NULL DEFAULT 0
                CHECK(
                    seed_cursor_frame_key >= 0
                    AND seed_cursor_frame_key <= seed_high_water_frame_key
                ),
            seed_frames_visited INTEGER NOT NULL DEFAULT 0
                CHECK(seed_frames_visited >= 0),
            seed_sessions_enqueued INTEGER NOT NULL DEFAULT 0
                CHECK(seed_sessions_enqueued >= 0),
            completed_slice_count INTEGER NOT NULL DEFAULT 0
                CHECK(completed_slice_count >= 0),
            deadline_yield_count INTEGER NOT NULL DEFAULT 0
                CHECK(deadline_yield_count >= 0),
            validation_cursor_segment_key INTEGER NOT NULL DEFAULT 0
                CHECK(validation_cursor_segment_key >= 0),
            validation_epoch INTEGER NOT NULL DEFAULT 0
                CHECK(validation_epoch >= 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            cancelled_at REAL,
            CHECK(
                (phase = 'cancelled' AND cancelled_at IS NOT NULL)
                OR (phase != 'cancelled' AND cancelled_at IS NULL)
            ),
            UNIQUE(generation_id, build_nonce),
            FOREIGN KEY(generation_id)
                REFERENCES memory_segment_generations(generation_id)
                ON DELETE CASCADE ON UPDATE RESTRICT
        );
        """

    static func begin(on database: OpaquePointer) throws -> MemorySegmentBuildTicket {
        try MemorySegmentIndex.execute("BEGIN IMMEDIATE", on: database)
        do {
            try MemorySegmentIndex.execute(createProgressTableSQL, on: database)
            try verifyProgressTable(on: database)

            if let selected = try selectedTicket(on: database) {
                try MemorySegmentIndex.execute("COMMIT", on: database)
                return selected
            }
            let hasInvalidSelectedBuild = try MemorySegmentIndex.scalarInt(
                """
                SELECT building_generation_id IS NOT NULL
                FROM memory_segment_index_state
                WHERE singleton = 1 AND schema_version = 4
                """,
                on: database
            ) != 0
            guard !hasInvalidSelectedBuild else {
                throw PassageError.database(
                    "Selected memory-segment build is missing valid durable progress."
                )
            }

            let highWater = try MemorySegmentIndex.scalarInt(
                """
                SELECT COALESCE(MAX(frame_key), 0)
                FROM frames INDEXED BY frames_frame_key
                """,
                on: database
            )
            let nonce = UUID().uuidString.lowercased()
            let now = Date().timeIntervalSince1970
            let generationInsert = try MemorySegmentIndex.prepare(
                """
                INSERT INTO memory_segment_generations(
                    build_nonce, lifecycle, revision, revision_is_current,
                    canonical_frame_count, segment_count, built_at
                ) VALUES (?, 'building', NULL, 0, 0, 0, NULL)
                """,
                on: database
            )
            defer { sqlite3_finalize(generationInsert) }
            MemorySegmentIndex.bind(nonce, at: 1, to: generationInsert)
            try MemorySegmentIndex.stepDone(generationInsert, on: database)
            let generationID = sqlite3_last_insert_rowid(database)
            guard generationID > 0 else {
                throw PassageError.database(
                    "Memory-segment generation allocation returned an invalid identity."
                )
            }

            let progressInsert = try MemorySegmentIndex.prepare(
                """
                INSERT INTO memory_segment_generation_progress(
                    generation_id, build_nonce, phase,
                    seed_high_water_frame_key, seed_cursor_frame_key,
                    seed_frames_visited, seed_sessions_enqueued,
                    completed_slice_count,
                    deadline_yield_count, validation_cursor_segment_key,
                    validation_epoch, created_at, updated_at, cancelled_at
                ) VALUES (?, ?, 'seeding', ?, 0, 0, 0, 0, 0, 0, 0, ?, ?, NULL)
                """,
                on: database
            )
            defer { sqlite3_finalize(progressInsert) }
            sqlite3_bind_int64(progressInsert, 1, generationID)
            MemorySegmentIndex.bind(nonce, at: 2, to: progressInsert)
            sqlite3_bind_int64(progressInsert, 3, highWater)
            sqlite3_bind_double(progressInsert, 4, now)
            sqlite3_bind_double(progressInsert, 5, now)
            try MemorySegmentIndex.stepDone(progressInsert, on: database)

            let selectBuilding = try MemorySegmentIndex.prepare(
                """
                UPDATE memory_segment_index_state
                SET building_generation_id = ?
                WHERE singleton = 1 AND schema_version = 4
                  AND (active_generation_id IS NULL OR active_generation_id != ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(selectBuilding) }
            sqlite3_bind_int64(selectBuilding, 1, generationID)
            sqlite3_bind_int64(selectBuilding, 2, generationID)
            try MemorySegmentIndex.stepDone(selectBuilding, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Memory-segment building generation could not be selected."
                )
            }

            try MemorySegmentIndex.execute("COMMIT", on: database)
            return MemorySegmentBuildTicket(
                generationID: generationID,
                buildNonce: nonce
            )
        } catch {
            try? MemorySegmentIndex.execute("ROLLBACK", on: database)
            throw error
        }
    }

    static func advance(
        _ ticket: MemorySegmentBuildTicket,
        limits: MemorySegmentBuildSliceLimits,
        callStartedAt: UInt64,
        on database: OpaquePointer
    ) throws -> MemorySegmentBuildSliceResult {
        try MemorySegmentIndex.execute("BEGIN IMMEDIATE", on: database)
        let writerStartedAt = monotonicNow()
        let deadline = deadline(after: limits.maxWallDuration, from: writerStartedAt)
        do {
            guard let original = try selectedProgress(ticket, on: database) else {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                let finishedAt = monotonicNow()
                return result(
                    disposition: .superseded,
                    progress: nil,
                    callStartedAt: callStartedAt,
                    writerStartedAt: writerStartedAt,
                    finishedAt: finishedAt
                )
            }
            guard original.phase == .seeding else {
                try MemorySegmentIndex.execute("COMMIT", on: database)
                let finishedAt = monotonicNow()
                return result(
                    disposition: .noWork,
                    progress: original,
                    callStartedAt: callStartedAt,
                    writerStartedAt: writerStartedAt,
                    finishedAt: finishedAt
                )
            }

            var deadlineReached = monotonicNow() >= deadline
            // An empty array proves exhaustion only after SQLite has returned
            // SQLITE_DONE. If the deadline expires before that first step, the
            // durable cursor must remain where it was.
            var sourceWasIncomplete =
                original.seedCursorFrameKey < original.seedHighWaterFrameKey
            var sqliteProgressInterrupted = false
            var sourceRows = [MemorySegmentSeedFrame]()
            if !deadlineReached,
               original.seedCursorFrameKey < original.seedHighWaterFrameKey {
                let loaded = try loadSeedFrames(
                    after: original.seedCursorFrameKey,
                    through: original.seedHighWaterFrameKey,
                    limit: limits.maxFrames,
                    deadline: deadline,
                    testingSQLiteInterruptAfterRows:
                        limits.testingSQLiteInterruptAfterRows,
                    on: database
                )
                sourceRows = loaded.rows
                deadlineReached = loaded.deadlineReached
                sourceWasIncomplete = loaded.wasIncomplete
                sqliteProgressInterrupted = loaded.sqliteProgressInterrupted
            }

            var cursor = original.seedCursorFrameKey
            var visited = 0
            var enqueued = 0
            var seenSessions = Set<String>()
            let enqueueTimestamp = Date().timeIntervalSince1970
            let enqueue = try MemorySegmentIndex.prepare(
                """
                INSERT INTO memory_segment_dirty_sessions(
                    generation_id, activity_session_id, dirty_version,
                    reason_mask, first_enqueued_at, last_enqueued_at
                ) VALUES (?, ?, 1, 64, ?, ?)
                ON CONFLICT(generation_id, activity_session_id) DO NOTHING
                """,
                on: database
            )
            defer { sqlite3_finalize(enqueue) }

            for row in sourceRows {
                try Task.checkCancellation()
                if monotonicNow() >= deadline {
                    deadlineReached = true
                    break
                }
                if let sessionID = row.activitySessionID,
                   seenSessions.insert(sessionID).inserted {
                    sqlite3_bind_int64(enqueue, 1, ticket.generationID)
                    MemorySegmentIndex.bind(sessionID, at: 2, to: enqueue)
                    sqlite3_bind_double(enqueue, 3, enqueueTimestamp)
                    sqlite3_bind_double(enqueue, 4, enqueueTimestamp)
                    try MemorySegmentIndex.stepDone(enqueue, on: database)
                    enqueued += Int(sqlite3_changes(database))
                    sqlite3_reset(enqueue)
                    sqlite3_clear_bindings(enqueue)
                }
                cursor = row.frameKey
                visited += 1
            }

            let processedEveryLoadedRow = visited == sourceRows.count
            let sourceExhausted = !sourceWasIncomplete
                && processedEveryLoadedRow
                && sourceRows.count < limits.maxFrames
            var nextPhase = original.phase
            if cursor >= original.seedHighWaterFrameKey || sourceExhausted {
                cursor = original.seedHighWaterFrameKey
                nextPhase = .catchingUp
            }

            try Task.checkCancellation()
            let updatedAt = Date()
            let update = try MemorySegmentIndex.prepare(
                """
                UPDATE memory_segment_generation_progress
                SET phase = ?, seed_cursor_frame_key = ?,
                    seed_frames_visited = seed_frames_visited + ?,
                    seed_sessions_enqueued = seed_sessions_enqueued + ?,
                    completed_slice_count = completed_slice_count + 1,
                    deadline_yield_count = deadline_yield_count + ?,
                    updated_at = ?
                WHERE generation_id = ? AND build_nonce = ?
                  AND phase = ? AND seed_cursor_frame_key = ?
                  AND EXISTS (
                      SELECT 1
                      FROM memory_segment_index_state AS state
                      JOIN memory_segment_generations AS generation
                        ON generation.generation_id = state.building_generation_id
                      WHERE state.singleton = 1 AND state.schema_version = 4
                        AND state.building_generation_id =
                            memory_segment_generation_progress.generation_id
                        AND generation.lifecycle = 'building'
                        AND generation.build_nonce =
                            memory_segment_generation_progress.build_nonce
                  )
                """,
                on: database
            )
            defer { sqlite3_finalize(update) }
            MemorySegmentIndex.bind(nextPhase.rawValue, at: 1, to: update)
            sqlite3_bind_int64(update, 2, cursor)
            sqlite3_bind_int64(update, 3, Int64(visited))
            sqlite3_bind_int64(update, 4, Int64(enqueued))
            sqlite3_bind_int64(update, 5, deadlineReached ? 1 : 0)
            sqlite3_bind_double(update, 6, updatedAt.timeIntervalSince1970)
            sqlite3_bind_int64(update, 7, ticket.generationID)
            MemorySegmentIndex.bind(ticket.buildNonce, at: 8, to: update)
            MemorySegmentIndex.bind(original.phase.rawValue, at: 9, to: update)
            sqlite3_bind_int64(update, 10, original.seedCursorFrameKey)
            try MemorySegmentIndex.stepDone(update, on: database)
            guard sqlite3_changes(database) == 1 else {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                let finishedAt = monotonicNow()
                return result(
                    disposition: .superseded,
                    progress: nil,
                    callStartedAt: callStartedAt,
                    writerStartedAt: writerStartedAt,
                    finishedAt: finishedAt
                )
            }
            try Task.checkCancellation()

            let progress = MemorySegmentBuildProgress(
                generationID: original.generationID,
                phase: nextPhase,
                seedHighWaterFrameKey: original.seedHighWaterFrameKey,
                seedCursorFrameKey: cursor,
                seedFramesVisited: original.seedFramesVisited + Int64(visited),
                seedSessionsEnqueued: original.seedSessionsEnqueued + Int64(enqueued),
                completedSliceCount: original.completedSliceCount + 1,
                deadlineYieldCount: original.deadlineYieldCount
                    + (deadlineReached ? 1 : 0),
                validationCursorSegmentKey: original.validationCursorSegmentKey,
                validationEpoch: original.validationEpoch,
                createdAt: original.createdAt,
                updatedAt: updatedAt,
                cancelledAt: nil
            )
            try MemorySegmentIndex.execute("COMMIT", on: database)
            let finishedAt = monotonicNow()
            let disposition: MemorySegmentBuildSliceDisposition
            if nextPhase != original.phase {
                disposition = .phaseAdvanced
            } else if visited > 0 || enqueued > 0 {
                disposition = .progressed
            } else {
                disposition = .noWork
            }
            return result(
                disposition: disposition,
                progress: progress,
                canonicalRowsVisited: visited,
                sqliteRowsChanged: enqueued + 1,
                sessionsEnqueued: enqueued,
                hitFrameLimit: visited == limits.maxFrames,
                hitWallDeadline: deadlineReached,
                sqliteProgressInterrupted: sqliteProgressInterrupted,
                callStartedAt: callStartedAt,
                writerStartedAt: writerStartedAt,
                finishedAt: finishedAt
            )
        } catch {
            try? MemorySegmentIndex.execute("ROLLBACK", on: database)
            throw error
        }
    }

    static func cancel(
        _ ticket: MemorySegmentBuildTicket,
        on database: OpaquePointer
    ) throws -> Bool {
        try MemorySegmentIndex.execute("BEGIN IMMEDIATE", on: database)
        do {
            let now = Date().timeIntervalSince1970
            let markCancelled = try MemorySegmentIndex.prepare(
                """
                UPDATE memory_segment_generation_progress
                SET phase = 'cancelled', cancelled_at = ?, updated_at = ?
                WHERE generation_id = ? AND build_nonce = ?
                  AND phase != 'cancelled'
                  AND EXISTS (
                      SELECT 1
                      FROM memory_segment_index_state AS state
                      JOIN memory_segment_generations AS generation
                        ON generation.generation_id = state.building_generation_id
                      WHERE state.singleton = 1 AND state.schema_version = 4
                        AND state.building_generation_id =
                            memory_segment_generation_progress.generation_id
                        AND generation.lifecycle = 'building'
                        AND generation.build_nonce =
                            memory_segment_generation_progress.build_nonce
                  )
                """,
                on: database
            )
            defer { sqlite3_finalize(markCancelled) }
            sqlite3_bind_double(markCancelled, 1, now)
            sqlite3_bind_double(markCancelled, 2, now)
            sqlite3_bind_int64(markCancelled, 3, ticket.generationID)
            MemorySegmentIndex.bind(ticket.buildNonce, at: 4, to: markCancelled)
            try MemorySegmentIndex.stepDone(markCancelled, on: database)
            guard sqlite3_changes(database) == 1 else {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                return false
            }

            let clearPointer = try MemorySegmentIndex.prepare(
                """
                UPDATE memory_segment_index_state
                SET building_generation_id = NULL
                WHERE singleton = 1 AND schema_version = 4
                  AND building_generation_id = ?
                """,
                on: database
            )
            defer { sqlite3_finalize(clearPointer) }
            sqlite3_bind_int64(clearPointer, 1, ticket.generationID)
            try MemorySegmentIndex.stepDone(clearPointer, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw PassageError.database(
                    "Cancelled memory-segment generation lost its selected pointer."
                )
            }
            try MemorySegmentIndex.execute("COMMIT", on: database)
            return true
        } catch {
            try? MemorySegmentIndex.execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func selectedTicket(
        on database: OpaquePointer
    ) throws -> MemorySegmentBuildTicket? {
        try MemorySegmentIndex.withStatement(
            """
            SELECT generation.generation_id, generation.build_nonce
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.building_generation_id
            JOIN memory_segment_generation_progress AS progress
              ON progress.generation_id = generation.generation_id
             AND progress.build_nonce = generation.build_nonce
            WHERE state.singleton = 1 AND state.schema_version = 4
              AND generation.lifecycle = 'building'
              AND progress.phase != 'cancelled'
            LIMIT 1
            """,
            on: database
        ) { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW,
                  let nonce = MemorySegmentIndex.string(statement, column: 1),
                  !nonce.isEmpty else {
                throw MemorySegmentIndex.databaseError(on: database)
            }
            return MemorySegmentBuildTicket(
                generationID: sqlite3_column_int64(statement, 0),
                buildNonce: nonce
            )
        }
    }

    private static func verifyProgressTable(on database: OpaquePointer) throws {
        let expectedColumns = [
            MemorySegmentProgressColumnContract(
                name: "generation_id", type: "INTEGER", isNotNull: true,
                defaultSQL: nil, primaryKeyOrdinal: 1
            ),
            MemorySegmentProgressColumnContract(
                name: "build_nonce", type: "TEXT", isNotNull: true,
                defaultSQL: nil, primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "phase", type: "TEXT", isNotNull: true,
                defaultSQL: nil, primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "seed_high_water_frame_key", type: "INTEGER", isNotNull: true,
                defaultSQL: nil, primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "seed_cursor_frame_key", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "seed_frames_visited", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "seed_sessions_enqueued", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "completed_slice_count", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "deadline_yield_count", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "validation_cursor_segment_key", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "validation_epoch", type: "INTEGER", isNotNull: true,
                defaultSQL: "0", primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "created_at", type: "REAL", isNotNull: true,
                defaultSQL: nil, primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "updated_at", type: "REAL", isNotNull: true,
                defaultSQL: nil, primaryKeyOrdinal: 0
            ),
            MemorySegmentProgressColumnContract(
                name: "cancelled_at", type: "REAL", isNotNull: false,
                defaultSQL: nil, primaryKeyOrdinal: 0
            ),
        ]
        let columns = try MemorySegmentIndex.withStatement(
            "PRAGMA table_info(memory_segment_generation_progress)",
            on: database
        ) { statement in
            var values = [MemorySegmentProgressColumnContract]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return values }
                guard status == SQLITE_ROW,
                      let name = MemorySegmentIndex.string(statement, column: 1),
                      let type = MemorySegmentIndex.string(statement, column: 2) else {
                    throw MemorySegmentIndex.databaseError(on: database)
                }
                let defaultSQL = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : MemorySegmentIndex.string(statement, column: 4)
                values.append(MemorySegmentProgressColumnContract(
                    name: name,
                    type: type.uppercased(),
                    isNotNull: sqlite3_column_int(statement, 3) == 1,
                    defaultSQL: defaultSQL,
                    primaryKeyOrdinal: sqlite3_column_int(statement, 5)
                ))
            }
        }
        let foreignKeys = try MemorySegmentIndex.withStatement(
            "PRAGMA foreign_key_list(memory_segment_generation_progress)",
            on: database
        ) { statement in
            var values = [MemorySegmentProgressForeignKeyContract]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return values }
                guard status == SQLITE_ROW,
                      let table = MemorySegmentIndex.string(statement, column: 2),
                      let source = MemorySegmentIndex.string(statement, column: 3),
                      let target = MemorySegmentIndex.string(statement, column: 4),
                      let update = MemorySegmentIndex.string(statement, column: 5),
                      let delete = MemorySegmentIndex.string(statement, column: 6) else {
                    throw MemorySegmentIndex.databaseError(on: database)
                }
                values.append(MemorySegmentProgressForeignKeyContract(
                    table: table,
                    sourceColumn: source,
                    targetColumn: target,
                    updateAction: update.uppercased(),
                    deleteAction: delete.uppercased()
                ))
            }
        }
        let normalizedSQL = try MemorySegmentIndex.withStatement(
            """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = 'memory_segment_generation_progress'
            LIMIT 1
            """,
            on: database
        ) { statement -> String? in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let sql = MemorySegmentIndex.string(statement, column: 0) else {
                return nil
            }
            return sql.lowercased().filter { !$0.isWhitespace }
        }
        guard columns == expectedColumns,
              foreignKeys == [
                  MemorySegmentProgressForeignKeyContract(
                      table: "memory_segment_generations",
                      sourceColumn: "generation_id",
                      targetColumn: "generation_id",
                      updateAction: "RESTRICT",
                      deleteAction: "CASCADE"
                  ),
              ],
              let normalizedSQL,
              normalizedSQL.contains("check(length(build_nonce)>0)"),
              normalizedSQL.contains(
                  "check(phasein('seeding','catching_up','repairing','validating','activating','cancelled'))"
              ),
              normalizedSQL.contains("check(seed_high_water_frame_key>=0)"),
              normalizedSQL.contains(
                  "check(seed_cursor_frame_key>=0andseed_cursor_frame_key<=seed_high_water_frame_key)"
              ),
              normalizedSQL.contains("check(seed_frames_visited>=0)"),
              normalizedSQL.contains("check(seed_sessions_enqueued>=0)"),
              normalizedSQL.contains("check(completed_slice_count>=0)"),
              normalizedSQL.contains("check(deadline_yield_count>=0)"),
              normalizedSQL.contains("check(validation_cursor_segment_key>=0)"),
              normalizedSQL.contains("check(validation_epoch>=0)"),
              normalizedSQL.contains("unique(generation_id,build_nonce)"),
              normalizedSQL.contains(
                  "check((phase='cancelled'andcancelled_atisnotnull)or(phase!='cancelled'andcancelled_atisnull))"
              ) else {
            throw PassageError.database(
                "Memory-segment generation progress schema is not the expected revision."
            )
        }
    }

    private static func selectedProgress(
        _ ticket: MemorySegmentBuildTicket,
        on database: OpaquePointer
    ) throws -> MemorySegmentBuildProgress? {
        try MemorySegmentIndex.withStatement(
            """
            SELECT progress.generation_id, progress.phase,
                   progress.seed_high_water_frame_key,
                   progress.seed_cursor_frame_key,
                   progress.seed_frames_visited,
                   progress.seed_sessions_enqueued,
                   progress.completed_slice_count,
                   progress.deadline_yield_count,
                   progress.validation_cursor_segment_key,
                   progress.validation_epoch,
                   progress.created_at, progress.updated_at,
                   progress.cancelled_at
            FROM memory_segment_index_state AS state
            JOIN memory_segment_generations AS generation
              ON generation.generation_id = state.building_generation_id
            JOIN memory_segment_generation_progress AS progress
              ON progress.generation_id = generation.generation_id
             AND progress.build_nonce = generation.build_nonce
            WHERE state.singleton = 1 AND state.schema_version = 4
              AND state.building_generation_id = ?
              AND generation.generation_id = ?
              AND generation.build_nonce = ?
              AND generation.lifecycle = 'building'
              AND progress.build_nonce = ?
              AND progress.phase != 'cancelled'
            LIMIT 1
            """,
            on: database
        ) { statement in
            sqlite3_bind_int64(statement, 1, ticket.generationID)
            sqlite3_bind_int64(statement, 2, ticket.generationID)
            MemorySegmentIndex.bind(ticket.buildNonce, at: 3, to: statement)
            MemorySegmentIndex.bind(ticket.buildNonce, at: 4, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW,
                  let phaseText = MemorySegmentIndex.string(statement, column: 1),
                  let phase = MemorySegmentBuildPhase(rawValue: phaseText) else {
                throw MemorySegmentIndex.databaseError(on: database)
            }
            let cancelledAt = sqlite3_column_type(statement, 12) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            return MemorySegmentBuildProgress(
                generationID: sqlite3_column_int64(statement, 0),
                phase: phase,
                seedHighWaterFrameKey: sqlite3_column_int64(statement, 2),
                seedCursorFrameKey: sqlite3_column_int64(statement, 3),
                seedFramesVisited: sqlite3_column_int64(statement, 4),
                seedSessionsEnqueued: sqlite3_column_int64(statement, 5),
                completedSliceCount: sqlite3_column_int64(statement, 6),
                deadlineYieldCount: sqlite3_column_int64(statement, 7),
                validationCursorSegmentKey: sqlite3_column_int64(statement, 8),
                validationEpoch: sqlite3_column_int64(statement, 9),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                cancelledAt: cancelledAt
            )
        }
    }

    private static func loadSeedFrames(
        after cursor: Int64,
        through highWater: Int64,
        limit: Int,
        deadline: UInt64,
        testingSQLiteInterruptAfterRows: Int?,
        on database: OpaquePointer
    ) throws -> (
        rows: [MemorySegmentSeedFrame],
        deadlineReached: Bool,
        wasIncomplete: Bool,
        sqliteProgressInterrupted: Bool
    ) {
        let context = MemorySegmentBuildDeadlineContext(
            deadline: deadline,
            testingSQLiteInterruptAfterRows: testingSQLiteInterruptAfterRows
        )
        let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
        sqlite3_progress_handler(
            database,
            100,
            memorySegmentBuildProgressCallback,
            opaqueContext
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        if Task<Never, Never>.isCancelled {
            throw CancellationError()
        }
        if monotonicNow() >= deadline {
            context.deadlineReached = true
            return ([], true, true, false)
        }

        let statement = try MemorySegmentIndex.prepare(
            """
            SELECT frame_key, activity_session_id
            FROM frames INDEXED BY frames_frame_key
            WHERE frame_key > ? AND frame_key <= ?
            ORDER BY frame_key ASC
            LIMIT ?
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int64(statement, 2, highWater)
        sqlite3_bind_int64(statement, 3, Int64(limit))

        var rows = [MemorySegmentSeedFrame]()
        rows.reserveCapacity(limit)
        while true {
            if Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return (rows, context.deadlineReached, false, false)
            }
            if status == SQLITE_INTERRUPT {
                if context.cancellationObserved || Task<Never, Never>.isCancelled {
                    throw CancellationError()
                }
                if context.deadlineReached {
                    return (rows, true, true, true)
                }
                if context.testingInterruptObserved {
                    return (rows, false, true, true)
                }
            }
            guard status == SQLITE_ROW else {
                throw MemorySegmentIndex.databaseError(on: database)
            }
            rows.append(MemorySegmentSeedFrame(
                frameKey: sqlite3_column_int64(statement, 0),
                activitySessionID: MemorySegmentIndex.string(statement, column: 1)
            ))
            context.selectedRowsReturned = rows.count
        }
    }

    private static func result(
        disposition: MemorySegmentBuildSliceDisposition,
        progress: MemorySegmentBuildProgress?,
        canonicalRowsVisited: Int = 0,
        sqliteRowsChanged: Int = 0,
        sessionsEnqueued: Int = 0,
        hitFrameLimit: Bool = false,
        hitWallDeadline: Bool = false,
        sqliteProgressInterrupted: Bool = false,
        callStartedAt: UInt64,
        writerStartedAt: UInt64,
        finishedAt: UInt64
    ) -> MemorySegmentBuildSliceResult {
        MemorySegmentBuildSliceResult(
            disposition: disposition,
            progress: progress,
            canonicalRowsVisited: canonicalRowsVisited,
            sqliteRowsChanged: sqliteRowsChanged,
            sessionsEnqueued: sessionsEnqueued,
            hitFrameLimit: hitFrameLimit,
            hitWallDeadline: hitWallDeadline,
            sqliteProgressInterrupted: sqliteProgressInterrupted,
            callWallDuration: elapsedSeconds(from: callStartedAt, to: finishedAt),
            writerWallDuration: elapsedSeconds(from: writerStartedAt, to: finishedAt)
        )
    }

    static func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func deadline(
        after duration: TimeInterval,
        from start: UInt64
    ) -> UInt64 {
        let requested = duration * 1_000_000_000
        let bounded = min(max(requested, 1), Double(UInt64.max / 4))
        return start &+ UInt64(bounded)
    }

    private static func elapsedSeconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end >= start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }
}

extension SQLiteFrameStore {
    /// Starts a first build or resumes the currently selected, durable build.
    /// The progress table is lazy-created here in this first production slice.
    public func beginMemorySegmentGenerationBuild() throws -> MemorySegmentBuildTicket {
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let ticket = try MemorySegmentGenerationBuilder.begin(on: lease.pointer)
        try connection.hardenFilePermissions()
        return ticket
    }

    public func advanceMemorySegmentGenerationBuild(
        _ ticket: MemorySegmentBuildTicket,
        limits: MemorySegmentBuildSliceLimits
    ) throws -> MemorySegmentBuildSliceResult {
        let callStartedAt = MemorySegmentGenerationBuilder.monotonicNow()
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let result = try MemorySegmentGenerationBuilder.advance(
            ticket,
            limits: limits,
            callStartedAt: callStartedAt,
            on: lease.pointer
        )
        if result.sqliteRowsChanged > 0 {
            try connection.hardenFilePermissions()
        }
        return result
    }

    /// Explicitly abandons the selected build. This never deletes derivative
    /// work: it marks the durable progress row cancelled and clears only the
    /// selected building pointer so later bounded cleanup can identify it.
    @discardableResult
    public func cancelMemorySegmentGenerationBuild(
        _ ticket: MemorySegmentBuildTicket
    ) throws -> Bool {
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let cancelled = try MemorySegmentGenerationBuilder.cancel(
            ticket,
            on: lease.pointer
        )
        if cancelled {
            try connection.hardenFilePermissions()
        }
        return cancelled
    }
}
