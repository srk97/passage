import PassageCore
import Dispatch
import Foundation
@preconcurrency import SQLCipher

/// Independent row and wall-clock limits for one retired-generation cleanup slice.
public struct MemorySegmentCleanupSliceLimits: Hashable, Sendable {
    public static let maximumRows = 4_096

    public let maxRows: Int
    public let maxWallDuration: TimeInterval

    public var rowBudget: Int { maxRows }

    public init(
        maxRows: Int = 512,
        maxWallDuration: TimeInterval = 0.012
    ) throws {
        guard maxRows > 0 else {
            throw PassageError.invalidQuery(
                "A memory-segment cleanup slice must allow at least one changed row."
            )
        }
        guard maxRows <= Self.maximumRows else {
            throw PassageError.invalidQuery(
                "A memory-segment cleanup slice cannot change more than \(Self.maximumRows) rows."
            )
        }
        guard maxWallDuration.isFinite, maxWallDuration > 0 else {
            throw PassageError.invalidQuery(
                "A memory-segment cleanup slice must have a positive finite wall duration."
            )
        }
        self.maxRows = maxRows
        self.maxWallDuration = maxWallDuration
    }

    public init(
        rowBudget: Int,
        maxWallDuration: TimeInterval
    ) throws {
        try self.init(maxRows: rowBudget, maxWallDuration: maxWallDuration)
    }
}

/// The ordered cleanup phase attempted by a slice.
public enum MemorySegmentCleanupPhase: String, Codable, Hashable, Sendable {
    case selection
    case members
    case segments
    case dirtySessions = "dirty_sessions"
    case retiringCancelledGeneration = "retiring_cancelled_generation"
    case generationProgress = "generation_progress"
    case generationMetadata = "generation_metadata"
}

public enum MemorySegmentCleanupSliceDisposition: String, Codable, Hashable, Sendable {
    case progressed
    case completed
    case superseded
    case noWork = "no_work"
    case deadlineReached = "deadline_reached"
    case interrupted
}

/// Evidence for both cleanup progress and foreground writer-gate accounting.
public struct MemorySegmentCleanupSliceResult: Codable, Hashable, Sendable {
    public let disposition: MemorySegmentCleanupSliceDisposition
    public let phase: MemorySegmentCleanupPhase
    public let generationID: Int64?
    public let rowsChanged: Int
    public let callWallDuration: TimeInterval
    public let writerWaitDuration: TimeInterval
    public let writerOwnershipDuration: TimeInterval

    public var isComplete: Bool { disposition == .completed }
    public var wasSuperseded: Bool { disposition == .superseded }
    public var hadNoWork: Bool { disposition == .noWork }

    init(
        disposition: MemorySegmentCleanupSliceDisposition,
        phase: MemorySegmentCleanupPhase,
        generationID: Int64?,
        rowsChanged: Int,
        callWallDuration: TimeInterval,
        writerWaitDuration: TimeInterval,
        writerOwnershipDuration: TimeInterval
    ) {
        self.disposition = disposition
        self.phase = phase
        self.generationID = generationID
        self.rowsChanged = rowsChanged
        self.callWallDuration = callWallDuration
        self.writerWaitDuration = writerWaitDuration
        self.writerOwnershipDuration = writerOwnershipDuration
    }
}

/// Narrow fault-injection seams used to prove transaction rechecks and rollback.
/// Production callers always use the empty value.
struct MemorySegmentCleanupTestHooks: @unchecked Sendable {
    var afterCandidateSelection: ((Int64) throws -> Void)?
    var interruptAfterProgressCallbacks: Int?
    var progressInstructionInterval: Int32 = 100

    static let none = MemorySegmentCleanupTestHooks()
}

private struct MemorySegmentCleanupCandidate {
    enum Kind {
        case retired
        case cancelledBuilding
    }

    let generationID: Int64
    let kind: Kind
}

private struct MemorySegmentCleanupProgressTable {
    let exists: Bool
}

private final class MemorySegmentCleanupDeadlineContext: @unchecked Sendable {
    let deadline: UInt64
    let interruptAfterCallbacks: Int?
    var callbackCount = 0
    var deadlineReached = false
    var cancellationObserved = false
    var forcedInterruption = false

    init(deadline: UInt64, interruptAfterCallbacks: Int?) {
        self.deadline = deadline
        self.interruptAfterCallbacks = interruptAfterCallbacks
    }
}

private let memorySegmentCleanupProgressCallback: @convention(c) (
    UnsafeMutableRawPointer?
) -> Int32 = { rawContext in
    guard let rawContext else { return 0 }
    let context = Unmanaged<MemorySegmentCleanupDeadlineContext>
        .fromOpaque(rawContext)
        .takeUnretainedValue()
    context.callbackCount += 1
    if let interruptAfterCallbacks = context.interruptAfterCallbacks,
       context.callbackCount >= interruptAfterCallbacks {
        context.forcedInterruption = true
        return 1
    }
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
    return 0
}

enum MemorySegmentGenerationCleanup {
    static func run(
        limits: MemorySegmentCleanupSliceLimits,
        hooks: MemorySegmentCleanupTestHooks = .none,
        callStartedAt: UInt64,
        on database: OpaquePointer
    ) throws -> MemorySegmentCleanupSliceResult {
        let deadline = self.deadline(
            after: limits.maxWallDuration,
            from: callStartedAt
        )
        try Task.checkCancellation()
        guard monotonicNow() < deadline else {
            return result(
                disposition: .deadlineReached,
                phase: .selection,
                generationID: nil,
                callStartedAt: callStartedAt
            )
        }

        let progressTable = try inspectProgressTable(on: database)
        guard let candidate = try oldestCandidate(
            progressTable: progressTable,
            on: database
        ) else {
            return result(
                disposition: .noWork,
                phase: .selection,
                generationID: nil,
                callStartedAt: callStartedAt
            )
        }
        try hooks.afterCandidateSelection?(candidate.generationID)
        try Task.checkCancellation()
        guard monotonicNow() < deadline else {
            return result(
                disposition: .deadlineReached,
                phase: .selection,
                generationID: candidate.generationID,
                callStartedAt: callStartedAt
            )
        }

        let writerAttemptedAt = monotonicNow()
        try MemorySegmentIndex.execute("BEGIN IMMEDIATE", on: database)
        let writerAcquiredAt = monotonicNow()
        do {
            try Task.checkCancellation()
            guard monotonicNow() < deadline else {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                return result(
                    disposition: .deadlineReached,
                    phase: .selection,
                    generationID: candidate.generationID,
                    callStartedAt: callStartedAt,
                    writerAttemptedAt: writerAttemptedAt,
                    writerAcquiredAt: writerAcquiredAt
                )
            }

            let transactionProgressTable = try inspectProgressTable(on: database)
            guard let selected = try exactCandidate(
                generationID: candidate.generationID,
                progressTable: transactionProgressTable,
                on: database
            ) else {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                return result(
                    disposition: .superseded,
                    phase: .selection,
                    generationID: candidate.generationID,
                    callStartedAt: callStartedAt,
                    writerAttemptedAt: writerAttemptedAt,
                    writerAcquiredAt: writerAcquiredAt
                )
            }

            let phase = try nextPhase(
                for: selected,
                progressTable: transactionProgressTable,
                on: database
            )
            let changeCountBefore = sqlite3_total_changes64(database)
            // Prepare before installing the handler. SQLite may execute virtual
            // machine work while preparing complex DELETE statements; keeping
            // interruption around sqlite3_step gives us the raw status needed
            // to classify a clean rollback instead of surfacing "interrupted"
            // as an undifferentiated database error.
            let mutation = try prepareMutation(
                phase,
                candidate: selected,
                maxRows: limits.maxRows,
                progressTable: transactionProgressTable,
                on: database
            )
            let progressContext = MemorySegmentCleanupDeadlineContext(
                deadline: deadline,
                interruptAfterCallbacks: hooks.interruptAfterProgressCallbacks
            )
            let retainedContext = Unmanaged.passRetained(progressContext)
            let instructionInterval = max(hooks.progressInstructionInterval, 1)
            sqlite3_progress_handler(
                database,
                instructionInterval,
                memorySegmentCleanupProgressCallback,
                retainedContext.toOpaque()
            )
            let status = sqlite3_step(mutation)
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_finalize(mutation)
            retainedContext.release()

            if status == SQLITE_INTERRUPT {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                if progressContext.cancellationObserved
                    || Task<Never, Never>.isCancelled {
                    throw CancellationError()
                }
                let disposition: MemorySegmentCleanupSliceDisposition =
                    progressContext.deadlineReached ? .deadlineReached : .interrupted
                return result(
                    disposition: disposition,
                    phase: phase,
                    generationID: selected.generationID,
                    callStartedAt: callStartedAt,
                    writerAttemptedAt: writerAttemptedAt,
                    writerAcquiredAt: writerAcquiredAt
                )
            }
            guard status == SQLITE_DONE else {
                throw MemorySegmentIndex.databaseError(on: database)
            }

            let changed = sqlite3_total_changes64(database) - changeCountBefore
            guard changed >= 0, changed <= Int64(limits.maxRows) else {
                throw PassageError.database(
                    "Memory-segment cleanup exceeded its SQLite row budget."
                )
            }
            guard changed > 0 else {
                throw PassageError.database(
                    "Memory-segment cleanup selected work but changed no rows."
                )
            }
            try Task.checkCancellation()
            guard monotonicNow() < deadline else {
                try MemorySegmentIndex.execute("ROLLBACK", on: database)
                return result(
                    disposition: .deadlineReached,
                    phase: phase,
                    generationID: selected.generationID,
                    callStartedAt: callStartedAt,
                    writerAttemptedAt: writerAttemptedAt,
                    writerAcquiredAt: writerAcquiredAt
                )
            }

            try MemorySegmentIndex.execute("COMMIT", on: database)
            return result(
                disposition: phase == .generationMetadata ? .completed : .progressed,
                phase: phase,
                generationID: selected.generationID,
                rowsChanged: Int(changed),
                callStartedAt: callStartedAt,
                writerAttemptedAt: writerAttemptedAt,
                writerAcquiredAt: writerAcquiredAt
            )
        } catch {
            sqlite3_progress_handler(database, 0, nil, nil)
            try? MemorySegmentIndex.execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func inspectProgressTable(
        on database: OpaquePointer
    ) throws -> MemorySegmentCleanupProgressTable {
        let exists = try MemorySegmentIndex.scalarInt(
            """
            SELECT EXISTS(
                SELECT 1 FROM sqlite_master
                WHERE type = 'table'
                  AND name = 'memory_segment_generation_progress'
            )
            """,
            on: database
        ) != 0
        guard exists else {
            return MemorySegmentCleanupProgressTable(exists: false)
        }

        let statement = try MemorySegmentIndex.prepare(
            "PRAGMA table_info(memory_segment_generation_progress)",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  let name = MemorySegmentIndex.string(statement, column: 1) else {
                throw MemorySegmentIndex.databaseError(on: database)
            }
            columns.insert(name)
        }
        guard columns.isSuperset(of: ["generation_id", "phase", "cancelled_at"]) else {
            throw PassageError.database(
                "Memory-segment generation progress has an unsupported schema."
            )
        }
        return MemorySegmentCleanupProgressTable(exists: true)
    }

    private static func oldestCandidate(
        progressTable: MemorySegmentCleanupProgressTable,
        on database: OpaquePointer
    ) throws -> MemorySegmentCleanupCandidate? {
        let cancelledPredicate = progressTable.exists
            ? """
              OR (
                  generation.lifecycle = 'building'
                  AND EXISTS (
                      SELECT 1
                      FROM memory_segment_generation_progress AS progress
                      WHERE progress.generation_id = generation.generation_id
                        AND progress.phase = 'cancelled'
                        AND progress.cancelled_at IS NOT NULL
                  )
              )
              """
            : ""
        return try MemorySegmentIndex.withStatement(
            """
            SELECT generation.generation_id, generation.lifecycle
            FROM memory_segment_generations AS generation
            JOIN memory_segment_index_state AS state
              ON state.singleton = 1 AND state.schema_version = 4
            WHERE (state.active_generation_id IS NULL
                   OR state.active_generation_id != generation.generation_id)
              AND (state.building_generation_id IS NULL
                   OR state.building_generation_id != generation.generation_id)
              AND (
                  generation.lifecycle = 'retired'
                  \(cancelledPredicate)
              )
            ORDER BY generation.generation_id ASC
            LIMIT 1
            """,
            on: database
        ) { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW,
                  let lifecycle = MemorySegmentIndex.string(statement, column: 1) else {
                throw MemorySegmentIndex.databaseError(on: database)
            }
            return MemorySegmentCleanupCandidate(
                generationID: sqlite3_column_int64(statement, 0),
                kind: lifecycle == "retired" ? .retired : .cancelledBuilding
            )
        }
    }

    private static func exactCandidate(
        generationID: Int64,
        progressTable: MemorySegmentCleanupProgressTable,
        on database: OpaquePointer
    ) throws -> MemorySegmentCleanupCandidate? {
        let cancelledPredicate = progressTable.exists
            ? """
              OR (
                  generation.lifecycle = 'building'
                  AND EXISTS (
                      SELECT 1
                      FROM memory_segment_generation_progress AS progress
                      WHERE progress.generation_id = generation.generation_id
                        AND progress.phase = 'cancelled'
                        AND progress.cancelled_at IS NOT NULL
                  )
              )
              """
            : ""
        let statement = try MemorySegmentIndex.prepare(
            """
            SELECT generation.lifecycle
            FROM memory_segment_generations AS generation
            JOIN memory_segment_index_state AS state
              ON state.singleton = 1 AND state.schema_version = 4
            WHERE generation.generation_id = ?
              AND (state.active_generation_id IS NULL
                   OR state.active_generation_id != generation.generation_id)
              AND (state.building_generation_id IS NULL
                   OR state.building_generation_id != generation.generation_id)
              AND (
                  generation.lifecycle = 'retired'
                  \(cancelledPredicate)
              )
            LIMIT 1
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generationID)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
              let lifecycle = MemorySegmentIndex.string(statement, column: 0) else {
            throw MemorySegmentIndex.databaseError(on: database)
        }
        return MemorySegmentCleanupCandidate(
            generationID: generationID,
            kind: lifecycle == "retired" ? .retired : .cancelledBuilding
        )
    }

    private static func nextPhase(
        for candidate: MemorySegmentCleanupCandidate,
        progressTable: MemorySegmentCleanupProgressTable,
        on database: OpaquePointer
    ) throws -> MemorySegmentCleanupPhase {
        if try childExists(
            table: "memory_segment_members",
            generationID: candidate.generationID,
            on: database
        ) {
            return .members
        }
        if try childExists(
            table: "memory_segments",
            generationID: candidate.generationID,
            on: database
        ) {
            return .segments
        }
        if try childExists(
            table: "memory_segment_dirty_sessions",
            generationID: candidate.generationID,
            on: database
        ) {
            return .dirtySessions
        }
        if case .cancelledBuilding = candidate.kind {
            return .retiringCancelledGeneration
        }
        if progressTable.exists,
           try childExists(
               table: "memory_segment_generation_progress",
               generationID: candidate.generationID,
               on: database
           ) {
            return .generationProgress
        }
        return .generationMetadata
    }

    private static func childExists(
        table: String,
        generationID: Int64,
        on database: OpaquePointer
    ) throws -> Bool {
        let statement = try MemorySegmentIndex.prepare(
            "SELECT EXISTS(SELECT 1 FROM \(table) WHERE generation_id = ?)",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generationID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MemorySegmentIndex.databaseError(on: database)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    /// Prepares and binds one mutation. The caller installs its progress
    /// handler only after this succeeds, then observes sqlite3_step directly.
    private static func prepareMutation(
        _ phase: MemorySegmentCleanupPhase,
        candidate: MemorySegmentCleanupCandidate,
        maxRows: Int,
        progressTable: MemorySegmentCleanupProgressTable,
        on database: OpaquePointer
    ) throws -> OpaquePointer {
        let sql: String
        switch phase {
        case .selection:
            throw PassageError.database("Selection is not a mutable cleanup phase.")
        case .members:
            sql =
                """
                DELETE FROM memory_segment_members
                WHERE generation_id = ?
                  AND frame_key IN (
                      SELECT frame_key
                      FROM memory_segment_members
                      WHERE generation_id = ?
                      ORDER BY frame_key ASC
                      LIMIT ?
                  )
                """
        case .segments:
            sql =
                """
                DELETE FROM memory_segments
                WHERE generation_id = ?
                  AND segment_key IN (
                      SELECT segment_key
                      FROM memory_segments
                      WHERE generation_id = ?
                      ORDER BY segment_key ASC
                      LIMIT ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_members
                      WHERE generation_id = ?
                  )
                """
        case .dirtySessions:
            sql =
                """
                DELETE FROM memory_segment_dirty_sessions
                WHERE generation_id = ?
                  AND activity_session_id IN (
                      SELECT activity_session_id
                      FROM memory_segment_dirty_sessions
                      WHERE generation_id = ?
                      ORDER BY activity_session_id ASC
                      LIMIT ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_members
                      WHERE generation_id = ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segments
                      WHERE generation_id = ?
                  )
                """
        case .retiringCancelledGeneration:
            guard progressTable.exists else {
                throw PassageError.database(
                    "A cancelled generation lost its durable progress row."
                )
            }
            sql =
                """
                UPDATE memory_segment_generations AS generation
                SET lifecycle = 'retired'
                WHERE generation_id = ?
                  AND lifecycle = 'building'
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_members
                      WHERE generation_id = generation.generation_id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segments
                      WHERE generation_id = generation.generation_id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_dirty_sessions
                      WHERE generation_id = generation.generation_id
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM memory_segment_generation_progress AS progress
                      WHERE progress.generation_id = generation.generation_id
                        AND progress.phase = 'cancelled'
                        AND progress.cancelled_at IS NOT NULL
                  )
                  AND EXISTS (
                      SELECT 1 FROM memory_segment_index_state AS state
                      WHERE state.singleton = 1 AND state.schema_version = 4
                        AND (state.active_generation_id IS NULL
                             OR state.active_generation_id != generation.generation_id)
                        AND (state.building_generation_id IS NULL
                             OR state.building_generation_id != generation.generation_id)
                  )
                """
        case .generationProgress:
            guard progressTable.exists else {
                throw PassageError.database("Generation progress is unavailable.")
            }
            sql =
                """
                DELETE FROM memory_segment_generation_progress
                WHERE generation_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_members
                      WHERE generation_id = ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segments
                      WHERE generation_id = ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_dirty_sessions
                      WHERE generation_id = ?
                  )
                """
        case .generationMetadata:
            let progressAbsence = progressTable.exists
                ? """
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_generation_progress
                      WHERE generation_id = generation.generation_id
                  )
                  """
                : ""
            sql =
                """
                DELETE FROM memory_segment_generations AS generation
                WHERE generation_id = ?
                  AND lifecycle = 'retired'
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_members
                      WHERE generation_id = generation.generation_id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segments
                      WHERE generation_id = generation.generation_id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM memory_segment_dirty_sessions
                      WHERE generation_id = generation.generation_id
                  )
                  \(progressAbsence)
                  AND EXISTS (
                      SELECT 1 FROM memory_segment_index_state AS state
                      WHERE state.singleton = 1 AND state.schema_version = 4
                        AND (state.active_generation_id IS NULL
                             OR state.active_generation_id != generation.generation_id)
                        AND (state.building_generation_id IS NULL
                             OR state.building_generation_id != generation.generation_id)
                  )
                """
        }

        let statement = try MemorySegmentIndex.prepare(sql, on: database)
        switch phase {
        case .members:
            sqlite3_bind_int64(statement, 1, candidate.generationID)
            sqlite3_bind_int64(statement, 2, candidate.generationID)
            sqlite3_bind_int64(statement, 3, Int64(maxRows))
        case .segments:
            sqlite3_bind_int64(statement, 1, candidate.generationID)
            sqlite3_bind_int64(statement, 2, candidate.generationID)
            sqlite3_bind_int64(statement, 3, Int64(maxRows))
            sqlite3_bind_int64(statement, 4, candidate.generationID)
        case .dirtySessions:
            sqlite3_bind_int64(statement, 1, candidate.generationID)
            sqlite3_bind_int64(statement, 2, candidate.generationID)
            sqlite3_bind_int64(statement, 3, Int64(maxRows))
            sqlite3_bind_int64(statement, 4, candidate.generationID)
            sqlite3_bind_int64(statement, 5, candidate.generationID)
        case .retiringCancelledGeneration, .generationMetadata:
            sqlite3_bind_int64(statement, 1, candidate.generationID)
        case .generationProgress:
            sqlite3_bind_int64(statement, 1, candidate.generationID)
            sqlite3_bind_int64(statement, 2, candidate.generationID)
            sqlite3_bind_int64(statement, 3, candidate.generationID)
            sqlite3_bind_int64(statement, 4, candidate.generationID)
        case .selection:
            break
        }
        return statement
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

    private static func result(
        disposition: MemorySegmentCleanupSliceDisposition,
        phase: MemorySegmentCleanupPhase,
        generationID: Int64?,
        rowsChanged: Int = 0,
        callStartedAt: UInt64,
        writerAttemptedAt: UInt64? = nil,
        writerAcquiredAt: UInt64? = nil
    ) -> MemorySegmentCleanupSliceResult {
        let finishedAt = monotonicNow()
        return MemorySegmentCleanupSliceResult(
            disposition: disposition,
            phase: phase,
            generationID: generationID,
            rowsChanged: rowsChanged,
            callWallDuration: elapsedSeconds(from: callStartedAt, to: finishedAt),
            writerWaitDuration: writerAttemptedAt.flatMap { attempted in
                writerAcquiredAt.map { acquired in
                    elapsedSeconds(from: attempted, to: acquired)
                }
            } ?? 0,
            writerOwnershipDuration: writerAcquiredAt.map { acquired in
                elapsedSeconds(from: acquired, to: finishedAt)
            } ?? 0
        )
    }
}

extension SQLiteFrameStore {
    /// Deletes at most one bounded phase from the oldest abandoned generation.
    /// Every mutating slice rechecks pointer ownership after acquiring SQLite's
    /// writer lock, so foreground activation always wins over cleanup.
    public func cleanupMemorySegmentGenerationSlice(
        limits: MemorySegmentCleanupSliceLimits
    ) throws -> MemorySegmentCleanupSliceResult {
        try cleanupMemorySegmentGenerationSlice(limits: limits, hooks: .none)
    }

    func cleanupMemorySegmentGenerationSlice(
        limits: MemorySegmentCleanupSliceLimits,
        hooks: MemorySegmentCleanupTestHooks
    ) throws -> MemorySegmentCleanupSliceResult {
        let callStartedAt = MemorySegmentGenerationCleanup.monotonicNow()
        try Task.checkCancellation()
        let lease = try activeConnectionLease()
        defer { lease.release() }
        let result = try MemorySegmentGenerationCleanup.run(
            limits: limits,
            hooks: hooks,
            callStartedAt: callStartedAt,
            on: lease.pointer
        )
        if result.rowsChanged > 0 {
            try connection.hardenFilePermissions()
        }
        return result
    }
}
