import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Memory-segment generation build slices", .serialized)
struct MemorySegmentGenerationBuildTests {
    @Test("Slice limits reject non-positive or non-finite budgets")
    func limitsAreStrictlyPositive() throws {
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentBuildSliceLimits(maxFrames: 0, maxWallDuration: 0.012)
        }
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentBuildSliceLimits(maxFrames: 1, maxWallDuration: 0)
        }
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentBuildSliceLimits(
                maxFrames: 1,
                maxWallDuration: .infinity
            )
        }
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentBuildSliceLimits(
                maxFrames: MemorySegmentBuildSliceLimits.maximumFrames + 1,
                maxWallDuration: 0.012
            )
        }
    }

    @Test("Begin allocates once, resumes after reopen, and replaces only cancelled work")
    func allocationResumeAndReplacement() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(id: "allocation", time: 100))

        let initial = try await store.beginMemorySegmentGenerationBuild()
        #expect(initial.generationID > 0)
        #expect(!initial.buildNonce.isEmpty)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'memory_segment_generation_progress'
            """,
            on: store.connection.pointer
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT building_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == initial.generationID)

        let reopened = try fixture.makeStore()
        let resumed = try await reopened.beginMemorySegmentGenerationBuild()
        #expect(resumed == initial)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segment_generations WHERE lifecycle = 'building'",
            on: reopened.connection.pointer
        ) == 1)

        #expect(try await reopened.cancelMemorySegmentGenerationBuild(initial))
        let replacement = try await reopened.beginMemorySegmentGenerationBuild()
        #expect(replacement.generationID > initial.generationID)
        #expect(replacement.buildNonce != initial.buildNonce)
        #expect(try Self.scalarString(
            """
            SELECT phase FROM memory_segment_generation_progress
            WHERE generation_id = \(initial.generationID)
            """,
            on: reopened.connection.pointer
        ) == MemorySegmentBuildPhase.cancelled.rawValue)
        #expect(try Self.scalarInt(
            """
            SELECT cancelled_at IS NOT NULL
            FROM memory_segment_generation_progress
            WHERE generation_id = \(initial.generationID)
            """,
            on: reopened.connection.pointer
        ) == 1)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_generations
            WHERE generation_id IN (\(initial.generationID), \(replacement.generationID))
              AND lifecycle = 'building'
            """,
            on: reopened.connection.pointer
        ) == 2)
    }

    @Test("Begin fails closed when the selected build has lost durable progress")
    func invalidSelectedBuildFailsClosed() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        let ticket = try await store.beginMemorySegmentGenerationBuild()
        try Self.execute(
            """
            DELETE FROM memory_segment_generation_progress
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        )

        var rejected = false
        do {
            _ = try await store.beginMemorySegmentGenerationBuild()
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(try Self.scalarInt(
            "SELECT building_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == ticket.generationID)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segment_generations",
            on: store.connection.pointer
        ) == 1)
    }

    @Test("Begin rejects a progress table with an incompatible contract")
    func incompatibleProgressSchemaIsRejected() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try Self.execute(
            """
            CREATE TABLE memory_segment_generation_progress (
                generation_id INTEGER PRIMARY KEY NOT NULL,
                build_nonce TEXT NOT NULL
            )
            """,
            on: store.connection.pointer
        )

        var rejected = false
        do {
            _ = try await store.beginMemorySegmentGenerationBuild()
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(try Self.scalarInt(
            "SELECT building_generation_id IS NULL FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segment_generations",
            on: store.connection.pointer
        ) == 0)
    }

    @Test("Seed high-water and cursor resume exactly across another store connection")
    func seedCursorResumesAcrossReopen() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        let frames = (0..<9).map { index in
            Self.frame(
                id: String(format: "resume-%02d", index),
                time: 100 + Double(index * 400)
            )
        }
        try await store.insertBatch(frames)
        let expectedKeys = try Self.int64Rows(
            "SELECT frame_key FROM frames ORDER BY frame_key ASC",
            on: store.connection.pointer
        )
        let ticket = try await store.beginMemorySegmentGenerationBuild()
        let highWater = try #require(expectedKeys.last)

        let first = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 3,
                maxWallDuration: 1
            )
        )
        #expect(first.canonicalRowsVisited == 3)
        #expect(first.hitFrameLimit)
        #expect(first.progress?.seedHighWaterFrameKey == highWater)
        #expect(first.progress?.seedCursorFrameKey == expectedKeys[2])
        #expect(first.progress?.seedFramesVisited == 3)

        let reopened = try fixture.makeStore()
        let resumedTicket = try await reopened.beginMemorySegmentGenerationBuild()
        #expect(resumedTicket == ticket)
        let second = try await reopened.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 2,
                maxWallDuration: 1
            )
        )
        #expect(second.canonicalRowsVisited == 2)
        #expect(second.progress?.seedCursorFrameKey == expectedKeys[4])
        #expect(second.progress?.seedFramesVisited == 5)

        let completed = try await reopened.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 20,
                maxWallDuration: 1
            )
        )
        #expect(completed.disposition == .phaseAdvanced)
        #expect(completed.progress?.phase == .catchingUp)
        #expect(completed.progress?.seedCursorFrameKey == highWater)
        #expect(completed.progress?.seedFramesVisited == 9)
        #expect(completed.progress?.seedIsComplete == true)
    }

    @Test("A tiny deadline yields durably and a later slice continues")
    func tinyDeadlineYieldsThenProgresses() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<40).map { index in
            Self.frame(
                id: String(format: "deadline-%02d", index),
                time: 100 + Double(index * 400)
            )
        })
        let ticket = try await store.beginMemorySegmentGenerationBuild()

        let yielded = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 40,
                maxWallDuration: .leastNonzeroMagnitude
            )
        )
        #expect(yielded.hitWallDeadline)
        #expect(yielded.canonicalRowsVisited < 40)
        #expect(yielded.progress?.deadlineYieldCount == 1)
        let durableCursor = try #require(yielded.progress?.seedCursorFrameKey)

        let continued = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 4,
                maxWallDuration: 1
            )
        )
        #expect(continued.canonicalRowsVisited == 4)
        #expect((continued.progress?.seedCursorFrameKey ?? 0) > durableCursor)
        #expect(continued.progress?.deadlineYieldCount == 1)
    }

    @Test("A SQLite progress interruption can still commit durable slice progress")
    func sqliteProgressInterruptionCommitsDurably() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<64).map { index in
            Self.frame(
                id: String(format: "interrupt-%02d", index),
                time: 100 + Double(index * 400)
            )
        })
        let ticket = try await store.beginMemorySegmentGenerationBuild()

        let committed = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 64,
                maxWallDuration: 1,
                testingSQLiteInterruptAfterRows: 3
            )
        )
        let committedProgress = try #require(committed.progress)
        #expect(committed.sqliteProgressInterrupted)
        #expect(!committed.hitWallDeadline)
        #expect(committed.canonicalRowsVisited >= 3)
        #expect(committed.canonicalRowsVisited < 64)
        #expect(committed.sessionsEnqueued == committed.canonicalRowsVisited)
        #expect(committed.sqliteRowsChanged == committed.sessionsEnqueued + 1)
        #expect(committedProgress.phase == .seeding)
        #expect(committedProgress.seedFramesVisited
            == Int64(committed.canonicalRowsVisited))
        #expect(committedProgress.seedSessionsEnqueued
            == Int64(committed.sessionsEnqueued))
        #expect(committedProgress.completedSliceCount == 1)
        #expect(committedProgress.deadlineYieldCount == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == committed.sessionsEnqueued)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM frames
            WHERE frame_key <= \(committedProgress.seedCursorFrameKey)
            """,
            on: store.connection.pointer
        ) == committed.canonicalRowsVisited)

        let reopened = try fixture.makeStore()
        #expect(try await reopened.beginMemorySegmentGenerationBuild() == ticket)
        #expect(try Self.scalarInt(
            """
            SELECT seed_cursor_frame_key
            FROM memory_segment_generation_progress
            WHERE generation_id = \(ticket.generationID)
            """,
            on: reopened.connection.pointer
        ) == committedProgress.seedCursorFrameKey)
        #expect(try Self.scalarInt(
            """
            SELECT completed_slice_count
            FROM memory_segment_generation_progress
            WHERE generation_id = \(ticket.generationID)
            """,
            on: reopened.connection.pointer
        ) == committedProgress.completedSliceCount)

        let continued = try await reopened.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 1,
                maxWallDuration: 1
            )
        )
        #expect(continued.canonicalRowsVisited == 1)
        #expect(
            (continued.progress?.seedCursorFrameKey ?? 0)
                > committedProgress.seedCursorFrameKey
        )
    }

    @Test("The old active generation remains the only readable generation during seed")
    func activeRemainsReadableAndSeedWritesDoNotMix() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<6).map { index in
            Self.frame(
                id: String(format: "active-%02d", index),
                time: 100 + Double(index)
            )
        })
        try await store.rebuildMemorySegmentIndex()
        let activeID = try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        let before = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        let ticket = try await store.beginMemorySegmentGenerationBuild()

        let seeded = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 3,
                maxWallDuration: 1
            )
        )
        let during = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )

        #expect(seeded.canonicalRowsVisited == 3)
        #expect(during.segments == before.segments)
        #expect(during.revision == before.revision)
        #expect(during.omissions.isEmpty)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == activeID)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segments
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(activeID)
            """,
            on: store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) > 0)
    }

    @Test("Begin does not copy active dirty work and seed accounting counts only changes")
    func seedDoesNotInheritActiveDirtyQueueAndAccountsExactly() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<8).map { index in
            Self.frame(
                id: String(format: "accounting-%02d", index),
                time: 100 + Double(index * 400)
            )
        })
        try await store.rebuildMemorySegmentIndex()
        let activeID = try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        try Self.execute(
            """
            INSERT INTO memory_segment_dirty_sessions(
                generation_id, activity_session_id, dirty_version,
                reason_mask, first_enqueued_at, last_enqueued_at
            )
            SELECT \(activeID), activity_session_id, 1, 32, 1, 1
            FROM frames
            """,
            on: store.connection.pointer
        )
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(activeID)
            """,
            on: store.connection.pointer
        ) == 8)

        let ticket = try await store.beginMemorySegmentGenerationBuild()
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == 0)
        try Self.execute(
            """
            INSERT INTO memory_segment_dirty_sessions(
                generation_id, activity_session_id, dirty_version,
                reason_mask, first_enqueued_at, last_enqueued_at
            )
            SELECT \(ticket.generationID), activity_session_id, 7, 32, 2, 2
            FROM frames ORDER BY frame_key ASC LIMIT 1
            """,
            on: store.connection.pointer
        )

        let seeded = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 3,
                maxWallDuration: 1
            )
        )
        #expect(seeded.canonicalRowsVisited == 3)
        #expect(seeded.sessionsEnqueued == 2)
        #expect(seeded.sqliteRowsChanged == 3)
        #expect(seeded.progress?.seedFramesVisited == 3)
        #expect(seeded.progress?.seedSessionsEnqueued == 2)
        #expect(seeded.progress?.completedSliceCount == 1)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == 3)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(activeID)
            """,
            on: store.connection.pointer
        ) == 8)
        #expect(try Self.scalarInt(
            """
            SELECT dirty_version
            FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            ORDER BY first_enqueued_at ASC, activity_session_id ASC
            LIMIT 1
            """,
            on: store.connection.pointer
        ) == 7)
        #expect(try Self.scalarInt(
            """
            SELECT reason_mask
            FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            ORDER BY first_enqueued_at ASC, activity_session_id ASC
            LIMIT 1
            """,
            on: store.connection.pointer
        ) == 32)
    }

    @Test("Post-high-water capture dual-enqueues and seed never overwrites its version")
    func postHighWaterCaptureIsCoveredByDirtyWork() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(id: "before-high-water", time: 100))
        try await store.rebuildMemorySegmentIndex()
        let activeID = try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        let ticket = try await store.beginMemorySegmentGenerationBuild()
        let highWater = try Self.scalarInt(
            """
            SELECT seed_high_water_frame_key
            FROM memory_segment_generation_progress
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        )

        let captured = Self.frame(id: "after-high-water", time: 1_000)
        try await store.insert(captured)
        let sessionID = try #require(try Self.scalarString(
            "SELECT activity_session_id FROM frames WHERE id = 'after-high-water'",
            on: store.connection.pointer
        ))
        let newFrameKey = try Self.scalarInt(
            "SELECT frame_key FROM frames WHERE id = 'after-high-water'",
            on: store.connection.pointer
        )
        #expect(newFrameKey > highWater)
        let beforeSeed = try Self.dirtyVersionAndReason(
            generationID: ticket.generationID,
            sessionID: sessionID,
            on: store.connection.pointer
        )
        #expect(beforeSeed != nil)
        #expect(try Self.dirtyVersionAndReason(
            generationID: activeID,
            sessionID: sessionID,
            on: store.connection.pointer
        ) != nil)

        let seeded = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 100,
                maxWallDuration: 1
            )
        )
        #expect(seeded.progress?.phase == .catchingUp)
        #expect(seeded.progress?.seedCursorFrameKey == highWater)
        #expect(try Self.dirtyVersionAndReason(
            generationID: ticket.generationID,
            sessionID: sessionID,
            on: store.connection.pointer
        ) == beforeSeed)
    }

    @Test("A superseded ticket cannot move cursors or write another generation")
    func staleTicketIsSupersededWithoutMixedWrites() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<8).map { index in
            Self.frame(
                id: String(format: "stale-%02d", index),
                time: 100 + Double(index * 400)
            )
        })
        let stale = try await store.beginMemorySegmentGenerationBuild()
        let first = try await store.advanceMemorySegmentGenerationBuild(
            stale,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 2,
                maxWallDuration: 1
            )
        )
        let staleCursor = try #require(first.progress?.seedCursorFrameKey)
        let staleDirtyCount = try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(stale.generationID)
            """,
            on: store.connection.pointer
        )
        #expect(try await store.cancelMemorySegmentGenerationBuild(stale))
        let current = try await store.beginMemorySegmentGenerationBuild()

        let rejected = try await store.advanceMemorySegmentGenerationBuild(
            stale,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 8,
                maxWallDuration: 1
            )
        )
        #expect(rejected.disposition == .superseded)
        #expect(rejected.progress == nil)
        #expect(rejected.sqliteRowsChanged == 0)
        #expect(try Self.scalarInt(
            """
            SELECT seed_cursor_frame_key
            FROM memory_segment_generation_progress
            WHERE generation_id = \(stale.generationID)
            """,
            on: store.connection.pointer
        ) == staleCursor)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(stale.generationID)
            """,
            on: store.connection.pointer
        ) == staleDirtyCount)

        let accepted = try await store.advanceMemorySegmentGenerationBuild(
            current,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 2,
                maxWallDuration: 1
            )
        )
        #expect(accepted.canonicalRowsVisited == 2)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(current.generationID)
            """,
            on: store.connection.pointer
        ) == accepted.progress?.seedSessionsEnqueued)
    }

    @Test("Cancel preserves old active reads and durable abandoned work")
    func cancellationIsSafeAndDurable() async throws {
        let fixture = try MemorySegmentGenerationBuildFixture()
        let store = try fixture.makeStore()
        try await store.insertBatch((0..<6).map { index in
            Self.frame(
                id: String(format: "cancel-%02d", index),
                time: 100 + Double(index)
            )
        })
        try await store.rebuildMemorySegmentIndex()
        let activeID = try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        let before = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        let ticket = try await store.beginMemorySegmentGenerationBuild()
        let slice = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 2,
                maxWallDuration: 1
            )
        )
        let cursor = try #require(slice.progress?.seedCursorFrameKey)
        let dirtyCount = try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        )

        #expect(try await store.cancelMemorySegmentGenerationBuild(ticket))
        #expect(!(try await store.cancelMemorySegmentGenerationBuild(ticket)))
        #expect(try Self.scalarInt(
            "SELECT building_generation_id IS NULL FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == activeID)
        #expect(try Self.scalarInt(
            """
            SELECT seed_cursor_frame_key
            FROM memory_segment_generation_progress
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == cursor)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_dirty_sessions
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == dirtyCount)
        #expect(try Self.scalarString(
            """
            SELECT phase FROM memory_segment_generation_progress
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == MemorySegmentBuildPhase.cancelled.rawValue)

        let after = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(try Self.request())
        )
        #expect(after.segments == before.segments)
        #expect(after.revision == before.revision)
        let rejected = try await store.advanceMemorySegmentGenerationBuild(
            ticket,
            limits: try MemorySegmentBuildSliceLimits(
                maxFrames: 2,
                maxWallDuration: 1
            )
        )
        #expect(rejected.disposition == .superseded)
    }

    private static func request() throws -> MemorySegmentRequest {
        try MemorySegmentRequest(
            scope: MemorySegmentScope(),
            retrievalModalities: [.savedText],
            limit: 40
        )
    }

    private static func frame(id: String, time: Double) -> FrameDocument {
        let text = "Generation evidence \(id)"
        return FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: "Notes",
                bundleIdentifier: "app.notes",
                windowTitle: "\(id) window"
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

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw PassageError.database(
                message.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int64 {
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

    private static func scalarString(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static func int64Rows(
        _ sql: String,
        on database: OpaquePointer
    ) throws -> [Int64] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows = [Int64]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            rows.append(sqlite3_column_int64(statement, 0))
        }
    }

    private static func dirtyVersionAndReason(
        generationID: Int64,
        sessionID: String,
        on database: OpaquePointer
    ) throws -> [Int64]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            SELECT dirty_version, reason_mask
            FROM memory_segment_dirty_sessions
            WHERE generation_id = ? AND activity_session_id = ?
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generationID)
        sqlite3_bind_text(statement, 2, sessionID, -1, unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        ))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        return [sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)]
    }
}

private final class MemorySegmentGenerationBuildFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-generation-build-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(
            bytes: Data(repeating: 0x73, count: VaultKey.byteCount)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeStore() throws -> SQLiteFrameStore {
        try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
    }
}
