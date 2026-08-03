import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Memory-segment generation cleanup slices", .serialized)
struct MemorySegmentGenerationCleanupTests {
    @Test("Cleanup limits reject non-positive or non-finite budgets")
    func limitsAreStrictlyPositive() throws {
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentCleanupSliceLimits(maxRows: 0, maxWallDuration: 1)
        }
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentCleanupSliceLimits(maxRows: 1, maxWallDuration: 0)
        }
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentCleanupSliceLimits(
                maxRows: MemorySegmentCleanupSliceLimits.maximumRows + 1,
                maxWallDuration: 1
            )
        }
        #expect(throws: PassageError.self) {
            _ = try MemorySegmentCleanupSliceLimits(
                rowBudget: 1,
                maxWallDuration: .infinity
            )
        }
    }

    @Test("Retired rows drain over resumable ordered slices within the exact cap")
    func retiredGenerationDrainsAcrossSlices() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let seeded = try await fixture.seedRetiredGeneration(frameCount: 7)
        let budget = 3
        var results = [MemorySegmentCleanupSliceResult]()

        while results.last?.isComplete != true {
            let result = try await seeded.store.cleanupMemorySegmentGenerationSlice(
                limits: try MemorySegmentCleanupSliceLimits(
                    maxRows: budget,
                    maxWallDuration: 1
                )
            )
            results.append(result)
            #expect(result.generationID == seeded.retiredGenerationID)
            #expect(result.rowsChanged > 0)
            #expect(result.rowsChanged <= budget)
            #expect(result.callWallDuration >= result.writerOwnershipDuration)
            #expect(result.writerWaitDuration >= 0)
            #expect(results.count < 20)
        }

        #expect(results.map(\.phase) == [
            .members,
            .members,
            .members,
            .segments,
            .dirtySessions,
            .generationMetadata,
        ])
        #expect(results.prefix(2).allSatisfy { $0.rowsChanged == budget })
        #expect(results.last?.disposition == .completed)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_generations
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: seeded.store.connection.pointer
        ) == seeded.activeGenerationID)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.activeGenerationID)
            """,
            on: seeded.store.connection.pointer
        ) == 8)
    }

    @Test("SQLite interruption rolls a slice back and the next slice resumes")
    func interruptionRollsBackAndResumes() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let seeded = try await fixture.seedRetiredGeneration(frameCount: 24)
        let before = try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        )

        var hooks = MemorySegmentCleanupTestHooks()
        hooks.interruptAfterProgressCallbacks = 1
        hooks.progressInstructionInterval = 1
        let interrupted = try await seeded.store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 10,
                maxWallDuration: 1
            ),
            hooks: hooks
        )

        #expect(interrupted.disposition == .interrupted)
        #expect(interrupted.phase == .members)
        #expect(interrupted.rowsChanged == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        ) == before)

        let resumed = try await seeded.store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 10,
                maxWallDuration: 1
            )
        )
        #expect(resumed.disposition == .progressed)
        #expect(resumed.phase == .members)
        #expect(resumed.rowsChanged == 10)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        ) == before - 10)
    }

    @Test("A monotonic deadline yields without mutation and later work resumes")
    func deadlineYieldsWithoutMutation() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let seeded = try await fixture.seedRetiredGeneration(frameCount: 5)
        let before = try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        )

        let yielded = try await seeded.store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 3,
                maxWallDuration: .leastNonzeroMagnitude
            )
        )
        #expect(yielded.disposition == .deadlineReached)
        #expect(yielded.rowsChanged == 0)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        ) == before)

        let resumed = try await seeded.store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 3,
                maxWallDuration: 1
            )
        )
        #expect(resumed.rowsChanged == 3)
    }

    @Test("The strict cap includes rows removed by foreign-key cascades")
    func rowCapIncludesCascades() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let store = try fixture.makeStore()
        try Self.execute(
            """
            CREATE TABLE cleanup_cascade_probe (
                id INTEGER PRIMARY KEY,
                generation_id INTEGER NOT NULL,
                FOREIGN KEY(generation_id)
                    REFERENCES memory_segment_generations(generation_id)
                    ON DELETE CASCADE
            );
            INSERT INTO memory_segment_generations(
                build_nonce, lifecycle, revision, revision_is_current,
                canonical_frame_count, segment_count, built_at
            ) VALUES ('cleanup-cascade', 'retired', NULL, 0, 0, 0, NULL);
            """,
            on: store.connection.pointer
        )
        let generationID = try Self.scalarInt(
            "SELECT generation_id FROM memory_segment_generations",
            on: store.connection.pointer
        )
        try Self.execute(
            """
            INSERT INTO cleanup_cascade_probe(id, generation_id)
            VALUES
                (1, \(generationID)),
                (2, \(generationID)),
                (3, \(generationID));
            """,
            on: store.connection.pointer
        )

        do {
            _ = try await store.cleanupMemorySegmentGenerationSlice(
                limits: try MemorySegmentCleanupSliceLimits(
                    maxRows: 3,
                    maxWallDuration: 1
                )
            )
            Issue.record("Expected the cascade to exceed the cleanup row cap")
        } catch is PassageError {
            // The over-budget transaction must be rolled back in full.
        }
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_generations
            WHERE generation_id = \(generationID)
            """,
            on: store.connection.pointer
        ) == 1)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM cleanup_cascade_probe",
            on: store.connection.pointer
        ) == 3)

        let completed = try await store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 4,
                maxWallDuration: 1
            )
        )
        #expect(completed.disposition == .completed)
        #expect(completed.phase == .generationMetadata)
        #expect(completed.rowsChanged == 4)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM cleanup_cascade_probe",
            on: store.connection.pointer
        ) == 0)
    }

    @Test("Active and selected building generations are never cleanup candidates")
    func activeAndBuildingPointersAreProtected() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(id: "protected", time: 100))
        _ = try await store.rebuildMemorySegmentIndex()
        let activeID = try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        try Self.execute(
            """
            INSERT INTO memory_segment_generations(
                build_nonce, lifecycle, revision, revision_is_current,
                canonical_frame_count, segment_count, built_at
            ) VALUES ('selected-building', 'building', NULL, 0, 0, 0, NULL);
            UPDATE memory_segment_index_state
            SET building_generation_id = last_insert_rowid()
            WHERE singleton = 1;
            """,
            on: store.connection.pointer
        )
        let buildingID = try Self.scalarInt(
            "SELECT building_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )

        let result = try await store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 20,
                maxWallDuration: 1
            )
        )
        #expect(result.disposition == .noWork)
        #expect(result.generationID == nil)
        #expect(result.rowsChanged == 0)
        #expect(result.writerOwnershipDuration == 0)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == activeID)
        #expect(try Self.scalarInt(
            "SELECT building_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == buildingID)
        #expect(try Self.scalarInt(
            "SELECT COUNT(*) FROM memory_segment_generations",
            on: store.connection.pointer
        ) == 2)
    }

    @Test("A pointer change between selection and writer ownership supersedes cleanup")
    func candidateIsRecheckedAfterWriterAcquisition() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let seeded = try await fixture.seedRetiredGeneration(frameCount: 6)
        let competingStore = try fixture.makeStore()
        let before = try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        )
        var hooks = MemorySegmentCleanupTestHooks()
        hooks.afterCandidateSelection = { generationID in
            try Self.execute(
                """
                UPDATE memory_segment_index_state
                SET building_generation_id = \(generationID)
                WHERE singleton = 1;
                """,
                on: competingStore.connection.pointer
            )
        }

        let result = try await seeded.store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 4,
                maxWallDuration: 1
            ),
            hooks: hooks
        )
        #expect(result.disposition == .superseded)
        #expect(result.generationID == seeded.retiredGenerationID)
        #expect(result.rowsChanged == 0)
        #expect(try Self.scalarInt(
            "SELECT building_generation_id FROM memory_segment_index_state",
            on: seeded.store.connection.pointer
        ) == seeded.retiredGenerationID)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_members
            WHERE generation_id = \(seeded.retiredGenerationID)
            """,
            on: seeded.store.connection.pointer
        ) == before)
    }

    @Test("Cancelled unpointed builds become resumable retired cleanup work")
    func cancelledBuildIsCleanedWithSingleRowSlices() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let store = try fixture.makeStore()
        try await store.insert(Self.frame(id: "cancelled", time: 100))
        _ = try await store.rebuildMemorySegmentIndex()
        let activeID = try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        try await store.insert(Self.frame(id: "cancelled-late", time: 110))
        let ticket = try await store.beginMemorySegmentGenerationBuild()
        try Self.execute(
            """
            INSERT INTO memory_segments(
                generation_id, id, revision_id, search_content_revision,
                started_at, ended_at, bundle_identifier, normalized_domain,
                activity_session_id, chunk_ordinal, frame_count, contains_sensitive
            ) VALUES (
                \(ticket.generationID), 'cancelled-segment',
                'cancelled-revision', 'cancelled-search-revision',
                100, 100, 'app.notes', '',
                (SELECT activity_session_id FROM frames ORDER BY frame_key ASC LIMIT 1),
                0, 1, 0
            );
            INSERT INTO memory_segment_members(
                generation_id, frame_key, segment_key, ordinal
            )
            SELECT \(ticket.generationID), MIN(frame_key), last_insert_rowid(), 0
            FROM frames;
            INSERT INTO memory_segment_dirty_sessions(
                generation_id, activity_session_id, dirty_version,
                reason_mask, first_enqueued_at, last_enqueued_at
            ) VALUES (
                \(ticket.generationID), 'cancelled-dirty', 1, 1, 100, 100
            ) ON CONFLICT(generation_id, activity_session_id) DO NOTHING;
            """,
            on: store.connection.pointer
        )
        #expect(try await store.cancelMemorySegmentGenerationBuild(ticket))

        let limits = try MemorySegmentCleanupSliceLimits(
            maxRows: 1,
            maxWallDuration: 1
        )
        var results = [MemorySegmentCleanupSliceResult]()
        while results.last?.isComplete != true {
            results.append(try await store.cleanupMemorySegmentGenerationSlice(limits: limits))
            #expect(results.count < 10)
        }

        #expect(results.map(\.phase) == [
            .members,
            .segments,
            .dirtySessions,
            .retiringCancelledGeneration,
            .generationProgress,
            .generationMetadata,
        ])
        #expect(results.allSatisfy { $0.rowsChanged == 1 })
        #expect(results.last?.disposition == .completed)
        #expect(try Self.scalarInt(
            """
            SELECT COUNT(*) FROM memory_segment_generations
            WHERE generation_id = \(ticket.generationID)
            """,
            on: store.connection.pointer
        ) == 0)
        #expect(try Self.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == activeID)
        #expect(try Self.scalarInt(
            "SELECT building_generation_id IS NULL FROM memory_segment_index_state",
            on: store.connection.pointer
        ) == 1)
    }

    @Test("A store with no abandoned generation reports no work without a writer")
    func noWorkDoesNotAcquireWriter() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let store = try fixture.makeStore()
        let result = try await store.cleanupMemorySegmentGenerationSlice(
            limits: try MemorySegmentCleanupSliceLimits(
                maxRows: 4,
                maxWallDuration: 1
            )
        )
        #expect(result.disposition == .noWork)
        #expect(result.phase == .selection)
        #expect(result.generationID == nil)
        #expect(result.rowsChanged == 0)
        #expect(result.writerWaitDuration == 0)
        #expect(result.writerOwnershipDuration == 0)
    }

    @Test("The oldest retired identity is selected deterministically")
    func oldestRetiredGenerationIsSelectedFirst() async throws {
        let fixture = try MemorySegmentGenerationCleanupFixture()
        let store = try fixture.makeStore()
        try Self.execute(
            """
            INSERT INTO memory_segment_generations(
                build_nonce, lifecycle, revision, revision_is_current,
                canonical_frame_count, segment_count, built_at
            ) VALUES ('older-retired', 'retired', NULL, 0, 0, 0, NULL);
            INSERT INTO memory_segment_generations(
                build_nonce, lifecycle, revision, revision_is_current,
                canonical_frame_count, segment_count, built_at
            ) VALUES ('newer-retired', 'retired', NULL, 0, 0, 0, NULL);
            """,
            on: store.connection.pointer
        )
        let oldest = try Self.scalarInt(
            "SELECT MIN(generation_id) FROM memory_segment_generations",
            on: store.connection.pointer
        )
        let newest = try Self.scalarInt(
            "SELECT MAX(generation_id) FROM memory_segment_generations",
            on: store.connection.pointer
        )
        let limits = try MemorySegmentCleanupSliceLimits(
            maxRows: 1,
            maxWallDuration: 1
        )

        let first = try await store.cleanupMemorySegmentGenerationSlice(limits: limits)
        let second = try await store.cleanupMemorySegmentGenerationSlice(limits: limits)

        #expect(first.generationID == oldest)
        #expect(first.disposition == .completed)
        #expect(second.generationID == newest)
        #expect(second.disposition == .completed)
    }

    fileprivate static func frame(id: String, time: Double) -> FrameDocument {
        let text = "Cleanup evidence \(id)"
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
                OCRRegion(
                    text: text,
                    confidence: 0.99,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                ),
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

    fileprivate static func scalarInt(
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
}

private final class MemorySegmentGenerationCleanupFixture {
    struct SeededGeneration {
        let store: SQLiteFrameStore
        let retiredGenerationID: Int64
        let activeGenerationID: Int64
    }

    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-generation-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(
            bytes: Data(repeating: 0x6C, count: VaultKey.byteCount)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeStore() throws -> SQLiteFrameStore {
        try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
    }

    func seedRetiredGeneration(frameCount: Int) async throws -> SeededGeneration {
        let store = try makeStore()
        try await store.insertBatch((0..<frameCount).map { index in
            MemorySegmentGenerationCleanupTests.frame(
                id: String(format: "retired-%02d", index),
                time: 100 + Double(index * 10)
            )
        })
        _ = try await store.rebuildMemorySegmentIndex()
        let retiredGenerationID = try MemorySegmentGenerationCleanupTests.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        try await store.insert(MemorySegmentGenerationCleanupTests.frame(
            id: "active-late",
            time: 100 + Double(frameCount * 10)
        ))
        _ = try await store.rebuildMemorySegmentIndex()
        let activeGenerationID = try MemorySegmentGenerationCleanupTests.scalarInt(
            "SELECT active_generation_id FROM memory_segment_index_state",
            on: store.connection.pointer
        )
        return SeededGeneration(
            store: store,
            retiredGenerationID: retiredGenerationID,
            activeGenerationID: activeGenerationID
        )
    }
}
