import PassageCore
import Foundation
@preconcurrency import SQLCipher

enum VisualEmbeddingSchema {
    static let currentVersion = 9

    static func migrate(on database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS visual_embedding_models (
                fingerprint TEXT PRIMARY KEY NOT NULL,
                identifier TEXT NOT NULL,
                revision TEXT NOT NULL,
                preprocessing_revision TEXT NOT NULL,
                embedding_dimension INTEGER NOT NULL CHECK(embedding_dimension = 512),
                vector_encoding TEXT NOT NULL CHECK(vector_encoding = 'symmetric-int8-v1'),
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS visual_embedding_vectors (
                id INTEGER PRIMARY KEY NOT NULL,
                model_fingerprint TEXT NOT NULL,
                content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
                angular_hash BLOB NOT NULL CHECK(length(angular_hash) = 64),
                quantized_vector BLOB NOT NULL CHECK(length(quantized_vector) = 512),
                quantization_scale REAL NOT NULL CHECK(quantization_scale > 0),
                maximum_cosine_error REAL NOT NULL CHECK(maximum_cosine_error >= 0),
                created_at REAL NOT NULL,
                UNIQUE(model_fingerprint, content_hash),
                FOREIGN KEY(model_fingerprint)
                    REFERENCES visual_embedding_models(fingerprint) ON DELETE CASCADE
            );
            DROP INDEX IF EXISTS visual_embedding_vectors_model;
            DROP INDEX IF EXISTS visual_embedding_vectors_angular_scan;
            CREATE TABLE IF NOT EXISTS visual_frame_embeddings (
                frame_id TEXT NOT NULL,
                frame_rowid INTEGER NOT NULL,
                model_fingerprint TEXT NOT NULL,
                vector_id INTEGER NOT NULL,
                source_visual_fingerprint INTEGER NOT NULL,
                indexed_at REAL NOT NULL,
                PRIMARY KEY(frame_id, model_fingerprint),
                FOREIGN KEY(frame_id) REFERENCES frames(id) ON DELETE CASCADE,
                FOREIGN KEY(model_fingerprint)
                    REFERENCES visual_embedding_models(fingerprint) ON DELETE CASCADE,
                FOREIGN KEY(vector_id)
                    REFERENCES visual_embedding_vectors(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS visual_frame_embeddings_model
                ON visual_frame_embeddings(model_fingerprint, vector_id, frame_id);
            CREATE INDEX IF NOT EXISTS visual_frame_embeddings_vector
                ON visual_frame_embeddings(vector_id, frame_id);
            CREATE TABLE IF NOT EXISTS visual_embedding_hash_blocks (
                model_fingerprint TEXT NOT NULL,
                block_id INTEGER NOT NULL CHECK(block_id >= 0),
                occupancy BLOB NOT NULL CHECK(length(occupancy) = 256),
                angular_hashes BLOB NOT NULL CHECK(length(angular_hashes) = 131072),
                PRIMARY KEY(model_fingerprint, block_id),
                FOREIGN KEY(model_fingerprint)
                    REFERENCES visual_embedding_models(fingerprint) ON DELETE CASCADE
            ) WITHOUT ROWID;
            """,
            on: database
        )
        if try !columnNames(in: "visual_frame_embeddings", on: database)
            .contains("frame_rowid") {
            try execute(
                "ALTER TABLE visual_frame_embeddings ADD COLUMN frame_rowid INTEGER",
                on: database
            )
            try execute(
                """
                UPDATE visual_frame_embeddings
                SET frame_rowid = (
                    SELECT frame.rowid FROM frames AS frame
                    WHERE frame.id = visual_frame_embeddings.frame_id
                )
                """,
                on: database
            )
        }
        try execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS visual_frame_embeddings_rowid
            ON visual_frame_embeddings(frame_rowid, model_fingerprint, vector_id)
            """,
            on: database
        )
        try VisualEmbeddingHashBlocks.migrateIfNeeded(on: database)
    }

    static func deleteOrphanVectors(on database: OpaquePointer) throws {
        let affectedBlocks = try VisualEmbeddingHashBlocks.orphanedBlockKeys(on: database)
        try execute(
            """
            DELETE FROM visual_embedding_vectors
            WHERE NOT EXISTS (
                SELECT 1 FROM visual_frame_embeddings AS association
                WHERE association.vector_id = visual_embedding_vectors.id
            )
            """,
            on: database
        )
        try VisualEmbeddingHashBlocks.rebuild(affectedBlocks, on: database)
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

    private static func columnNames(
        in table: String,
        on database: OpaquePointer
    ) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(table))",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
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
}

/// A disk-resident, SQLCipher-encrypted layout for the angular shortlist.
///
/// SQLite row iteration dominated the old million-vector path even though its
/// Hamming work is tiny. These fixed blocks keep the same 64-byte angular keys
/// in roughly 128 KiB encrypted chunks. A store holds at most one model's
/// blocks in memory while its vault is open, so warm queries scan contiguous
/// bytes without a plaintext sidecar or an unbounded multi-model cache.
/// Exclusive-below cursor in (captured_at, id) order: frames strictly before
/// it are known to have fresh visual embeddings for one model fingerprint.
struct VisualPendingScanFloor {
    var capturedAt: Double
    var id: String
}

enum VisualEmbeddingHashBlocks {
    static let slotCount = 2_048
    static let occupancyByteCount = slotCount / 8
    static let angularHashByteCount = VisualEmbeddingCodec.angularHashBytes
    static let angularPayloadByteCount = slotCount * angularHashByteCount

    private static let revisionKey = "visual_hash_blocks_revision"
    private static let generationKey = "visual_hash_blocks_generation"
    private static let revision = "fixed-angular-blocks-v1"
    static let loadStatement = """
        SELECT block_id, occupancy, angular_hashes
        FROM visual_embedding_hash_blocks
        WHERE model_fingerprint = ?
        ORDER BY block_id
        """

    static func key(modelFingerprint: String, vectorID: Int64) -> VisualHashBlockKey {
        precondition(vectorID > 0)
        return VisualHashBlockKey(
            modelFingerprint: modelFingerprint,
            blockID: (vectorID - 1) / Int64(slotCount)
        )
    }

    static func migrateIfNeeded(on database: OpaquePointer) throws {
        guard try metadataValue(revisionKey, on: database) != revision else { return }
        try execute("DELETE FROM visual_embedding_hash_blocks", on: database)
        let keys = try allBlockKeys(on: database)
        try rebuild(keys, on: database, marksChanged: false)
        try setMetadata(revision, for: revisionKey, on: database)
        try markChanged(on: database)
    }

    static func orphanedBlockKeys(on database: OpaquePointer) throws
        -> Set<VisualHashBlockKey> {
        try withStatement(
            """
            SELECT DISTINCT vector.model_fingerprint,
                   CAST((vector.id - 1) / \(slotCount) AS INTEGER)
            FROM visual_embedding_vectors AS vector
            WHERE NOT EXISTS (
                SELECT 1 FROM visual_frame_embeddings AS association
                WHERE association.vector_id = vector.id
            )
            """,
            on: database
        ) { statement in
            var keys = Set<VisualHashBlockKey>()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return keys }
                guard status == SQLITE_ROW,
                      let text = sqlite3_column_text(statement, 0) else {
                    try throwStep(status, on: database)
                }
                keys.insert(VisualHashBlockKey(
                    modelFingerprint: String(cString: text),
                    blockID: sqlite3_column_int64(statement, 1)
                ))
            }
        }
    }

    static func rebuild(
        _ keys: Set<VisualHashBlockKey>,
        on database: OpaquePointer,
        marksChanged: Bool = true
    ) throws {
        guard !keys.isEmpty else { return }
        for (offset, key) in keys.sorted().enumerated() {
            if offset.isMultiple(of: 16) { try Task.checkCancellation() }
            try rebuild(key, on: database)
        }
        if marksChanged { try markChanged(on: database) }
    }

    static func generation(on database: OpaquePointer) throws -> Int64? {
        guard try metadataValue(revisionKey, on: database) == revision,
              let value = try metadataValue(generationKey, on: database),
              let generation = Int64(value) else {
            return nil
        }
        return generation
    }

    static func load(
        modelFingerprint: String,
        on database: OpaquePointer
    ) throws -> [VisualHashBlock] {
        let blocks = try withStatement(
            loadStatement,
            on: database
        ) { statement in
            bind(modelFingerprint, at: 1, to: statement)
            var result = [VisualHashBlock]()
            var occupiedCount: Int64 = 0
            while true {
                if result.count.isMultiple(of: 4) { try Task.checkCancellation() }
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                      let occupancy = data(statement, column: 1),
                      let angularHashes = data(statement, column: 2),
                      occupancy.count == occupancyByteCount,
                      angularHashes.count == angularPayloadByteCount else {
                    if status == SQLITE_ROW {
                        throw VisualEmbeddingStoreError.corruptStoredVector
                    }
                    try throwStep(status, on: database)
                }
                occupiedCount += Int64(occupancy.reduce(0) { $0 + $1.nonzeroBitCount })
                result.append(VisualHashBlock(
                    blockID: sqlite3_column_int64(statement, 0),
                    occupancy: occupancy,
                    angularHashes: angularHashes
                ))
            }
            return (result, occupiedCount)
        }
        let vectorCount = try scalarInt(
            "SELECT COUNT(*) FROM visual_embedding_vectors WHERE model_fingerprint = ?",
            text: modelFingerprint,
            on: database
        )
        guard blocks.1 == vectorCount else {
            throw VisualEmbeddingStoreError.corruptStoredVector
        }
        return blocks.0
    }

    /// Loads one block row, or nil when a rebuild deleted it because every
    /// slot in its ID range became unoccupied.
    static func loadBlock(
        _ key: VisualHashBlockKey,
        on database: OpaquePointer
    ) throws -> VisualHashBlock? {
        try withStatement(
            """
            SELECT occupancy, angular_hashes
            FROM visual_embedding_hash_blocks
            WHERE model_fingerprint = ? AND block_id = ?
            """,
            on: database
        ) { statement in
            bind(key.modelFingerprint, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, key.blockID)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW,
                  let occupancy = data(statement, column: 0),
                  let angularHashes = data(statement, column: 1),
                  occupancy.count == occupancyByteCount,
                  angularHashes.count == angularPayloadByteCount else {
                if status == SQLITE_ROW {
                    throw VisualEmbeddingStoreError.corruptStoredVector
                }
                try throwStep(status, on: database)
            }
            return VisualHashBlock(
                blockID: key.blockID,
                occupancy: occupancy,
                angularHashes: angularHashes
            )
        }
    }

    static func markChanged(on database: OpaquePointer) throws {
        try execute(
            """
            INSERT INTO store_metadata(key, value)
            VALUES ('\(generationKey)', '1')
            ON CONFLICT(key) DO UPDATE SET
                value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
            """,
            on: database
        )
    }

    private static func rebuild(
        _ key: VisualHashBlockKey,
        on database: OpaquePointer
    ) throws {
        var occupancy = Data(repeating: 0, count: occupancyByteCount)
        var angularHashes = Data(repeating: 0, count: angularPayloadByteCount)
        let firstID = key.blockID * Int64(slotCount) + 1
        let endID = firstID + Int64(slotCount)
        let count = try withStatement(
            """
            SELECT id, angular_hash
            FROM visual_embedding_vectors NOT INDEXED
            WHERE model_fingerprint = ? AND id >= ? AND id < ?
            ORDER BY id
            """,
            on: database
        ) { statement in
            bind(key.modelFingerprint, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, firstID)
            sqlite3_bind_int64(statement, 3, endID)
            var count = 0
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return count }
                guard status == SQLITE_ROW,
                      let hash = data(statement, column: 1),
                      hash.count == angularHashByteCount else {
                    if status == SQLITE_ROW {
                        throw VisualEmbeddingStoreError.corruptStoredVector
                    }
                    try throwStep(status, on: database)
                }
                let id = sqlite3_column_int64(statement, 0)
                let slot = Int(id - firstID)
                guard (0..<slotCount).contains(slot) else {
                    throw VisualEmbeddingStoreError.corruptStoredVector
                }
                occupancy[slot / 8] |= UInt8(1 << (slot % 8))
                angularHashes.withUnsafeMutableBytes { destination in
                    hash.withUnsafeBytes { source in
                        destination.baseAddress!
                            .advanced(by: slot * angularHashByteCount)
                            .copyMemory(from: source.baseAddress!, byteCount: angularHashByteCount)
                    }
                }
                count += 1
            }
        }

        if count == 0 {
            try withStatement(
                "DELETE FROM visual_embedding_hash_blocks WHERE model_fingerprint = ? AND block_id = ?",
                on: database
            ) { statement in
                bind(key.modelFingerprint, at: 1, to: statement)
                sqlite3_bind_int64(statement, 2, key.blockID)
                try stepDone(statement, on: database)
            }
            return
        }
        try withStatement(
            """
            INSERT INTO visual_embedding_hash_blocks(
                model_fingerprint, block_id, occupancy, angular_hashes
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(model_fingerprint, block_id) DO UPDATE SET
                occupancy = excluded.occupancy,
                angular_hashes = excluded.angular_hashes
            """,
            on: database
        ) { statement in
            bind(key.modelFingerprint, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, key.blockID)
            bind(occupancy, at: 3, to: statement)
            bind(angularHashes, at: 4, to: statement)
            try stepDone(statement, on: database)
        }
    }

    private static func allBlockKeys(on database: OpaquePointer) throws
        -> Set<VisualHashBlockKey> {
        try withStatement(
            """
            SELECT DISTINCT model_fingerprint,
                   CAST((id - 1) / \(slotCount) AS INTEGER)
            FROM visual_embedding_vectors
            """,
            on: database
        ) { statement in
            var keys = Set<VisualHashBlockKey>()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return keys }
                guard status == SQLITE_ROW,
                      let text = sqlite3_column_text(statement, 0) else {
                    try throwStep(status, on: database)
                }
                keys.insert(VisualHashBlockKey(
                    modelFingerprint: String(cString: text),
                    blockID: sqlite3_column_int64(statement, 1)
                ))
            }
        }
    }

    private static func metadataValue(
        _ key: String,
        on database: OpaquePointer
    ) throws -> String? {
        try withStatement(
            "SELECT value FROM store_metadata WHERE key = ? LIMIT 1",
            on: database
        ) { statement in
            bind(key, at: 1, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { try throwStep(status, on: database) }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }

    private static func setMetadata(
        _ value: String,
        for key: String,
        on database: OpaquePointer
    ) throws {
        try withStatement(
            "INSERT OR REPLACE INTO store_metadata(key, value) VALUES (?, ?)",
            on: database
        ) { statement in
            bind(key, at: 1, to: statement)
            bind(value, at: 2, to: statement)
            try stepDone(statement, on: database)
        }
    }

    private static func scalarInt(
        _ sql: String,
        text: String,
        on database: OpaquePointer
    ) throws -> Int64 {
        try withStatement(sql, on: database) { statement in
            bind(text, at: 1, to: statement)
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else { try throwStep(status, on: database) }
            return sqlite3_column_int64(statement, 0)
        }
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

    private static func withStatement<Result>(
        _ sql: String,
        on database: OpaquePointer,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, visualSQLiteTransient)
        }
    }

    private static func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), visualSQLiteTransient)
        }
    }

    private static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func stepDone(
        _ statement: OpaquePointer,
        on database: OpaquePointer
    ) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { try throwStep(status, on: database) }
    }

    private static func throwStep(_ status: Int32, on database: OpaquePointer) throws -> Never {
        if status == SQLITE_INTERRUPT, Task.isCancelled { throw CancellationError() }
        throw PassageError.database(String(cString: sqlite3_errmsg(database)))
    }
}

extension SQLiteFrameStore {
    /// Decrypts the fixed angular blocks into the one-model session cache
    /// without scanning or scoring them. Passage calls this on a utility task
    /// before publishing visual search as ready, keeping the cold SQLCipher
    /// snapshot load out of the first user query.
    public func prewarmVisualEmbeddingIndex(modelFingerprint: String) throws {
        try Task.checkCancellation()
        try Self.validateVisualFingerprint(modelFingerprint)
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        try Self.visualExecute("BEGIN DEFERRED", on: database)
        do {
            guard let generation = try VisualEmbeddingHashBlocks.generation(on: database) else {
                try Self.visualExecute("COMMIT", on: database)
                return
            }
            try visualAngularShortlistCache.prewarm(
                modelFingerprint: modelFingerprint,
                generation: generation
            ) {
                try VisualEmbeddingHashBlocks.load(
                    modelFingerprint: modelFingerprint,
                    on: database
                )
            }
            try Task.checkCancellation()
            try Self.visualExecute("COMMIT", on: database)
        } catch {
            try? Self.visualExecute("ROLLBACK", on: database)
            throw error
        }
    }

    public func upsertVisualEmbeddings(
        _ writes: [VisualEmbeddingWrite]
    ) throws -> VisualEmbeddingWriteSummary {
        try Task.checkCancellation()
        guard writes.count <= 1_000 else { throw VisualEmbeddingStoreError.batchTooLarge }
        guard !writes.isEmpty else { return VisualEmbeddingWriteSummary() }
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer

        var keys = Set<VisualFrameModelKey>()
        var prepared = [PreparedVisualEmbeddingWrite]()
        prepared.reserveCapacity(writes.count)
        for write in writes {
            try Self.validateVisualModel(write.model)
            guard write.indexedAt.timeIntervalSince1970.isFinite else {
                throw VisualEmbeddingStoreError.invalidQuery
            }
            let key = VisualFrameModelKey(
                frameID: write.frameID.rawValue,
                modelFingerprint: write.model.fingerprint
            )
            guard !write.frameID.rawValue.isEmpty, keys.insert(key).inserted else {
                throw VisualEmbeddingStoreError.invalidQuery
            }
            prepared.append(PreparedVisualEmbeddingWrite(
                write: write,
                encoded: try VisualEmbeddingCodec.encode(
                    write.vector,
                    expectedDimension: write.model.embeddingDimension,
                    modelFingerprint: write.model.fingerprint
                )
            ))
        }

        try Self.visualExecute("BEGIN IMMEDIATE", on: database)
        do {
            var summary = VisualEmbeddingWriteSummary(processedFrameCount: writes.count)
            var affectedHashBlocks = Set<VisualHashBlockKey>()
            var modelsByFingerprint = [String: VisualModelIdentity]()
            for write in writes {
                if let existing = modelsByFingerprint[write.model.fingerprint],
                   existing != write.model {
                    throw VisualEmbeddingStoreError.modelFingerprintCollision
                }
                modelsByFingerprint[write.model.fingerprint] = write.model
            }
            for model in modelsByFingerprint.values {
                try visualRegisterModel(model, on: database)
            }

            for (offset, item) in prepared.enumerated() {
                if offset.isMultiple(of: 64) { try Task.checkCancellation() }
                let frameState = try visualFrameState(
                    id: item.write.frameID,
                    on: database
                )
                guard let frameState else {
                    throw VisualEmbeddingStoreError.frameNotFound(item.write.frameID)
                }
                guard !frameState.isSensitive else {
                    throw VisualEmbeddingStoreError.sensitiveFrame(item.write.frameID)
                }

                let vector = try visualInsertOrReuseVector(
                    item.encoded,
                    model: item.write.model,
                    createdAt: item.write.indexedAt,
                    on: database
                )
                if vector.wasInserted {
                    affectedHashBlocks.insert(VisualEmbeddingHashBlocks.key(
                        modelFingerprint: item.write.model.fingerprint,
                        vectorID: vector.id
                    ))
                    summary.insertedUniqueVectorCount += 1
                    summary.storedVectorBytesDelta += Int64(
                        item.encoded.bytes.count + item.encoded.angularHash.count
                    )
                } else {
                    summary.reusedUniqueVectorCount += 1
                }

                let prior = try visualAssociation(
                    frameID: item.write.frameID,
                    modelFingerprint: item.write.model.fingerprint,
                    on: database
                )
                try visualWriteAssociation(
                    frameID: item.write.frameID,
                    frameRowID: frameState.rowID,
                    modelFingerprint: item.write.model.fingerprint,
                    vectorID: vector.id,
                    sourceVisualFingerprint: frameState.visualFingerprint,
                    indexedAt: item.write.indexedAt,
                    on: database
                )
                if prior == nil {
                    summary.insertedAssociationCount += 1
                } else if prior?.vectorID == vector.id,
                          prior?.sourceVisualFingerprint == frameState.visualFingerprint {
                    summary.unchangedAssociationCount += 1
                } else {
                    summary.replacedAssociationCount += 1
                }

                if let prior, prior.vectorID != vector.id,
                   let reclaimedBytes = try visualDeleteVectorIfOrphaned(
                    id: prior.vectorID,
                    on: database
                   ) {
                    affectedHashBlocks.insert(VisualEmbeddingHashBlocks.key(
                        modelFingerprint: item.write.model.fingerprint,
                        vectorID: prior.vectorID
                    ))
                    summary.reclaimedUniqueVectorCount += 1
                    summary.storedVectorBytesDelta -= reclaimedBytes
                }
            }
            let generationBeforeRebuild = try VisualEmbeddingHashBlocks.generation(on: database)
            try VisualEmbeddingHashBlocks.rebuild(affectedHashBlocks, on: database)
            try Task.checkCancellation()
            try Self.visualExecute("COMMIT", on: database)
            visualPatchShortlistCache(
                affectedHashBlocks,
                expectedGeneration: generationBeforeRebuild,
                on: database
            )
            try connection.hardenFilePermissions()
            return summary
        } catch {
            try? Self.visualExecute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Carries the retained shortlist snapshot across an upsert by reloading
    /// only the blocks that transaction rebuilt. Failure to patch is not an
    /// error: dropping the snapshot merely restores the full prewarm reload.
    private func visualPatchShortlistCache(
        _ keys: Set<VisualHashBlockKey>,
        expectedGeneration: Int64?,
        on database: OpaquePointer
    ) {
        guard !keys.isEmpty, let expectedGeneration else { return }
        do {
            guard let generation = try VisualEmbeddingHashBlocks.generation(on: database) else {
                visualAngularShortlistCache.invalidate()
                return
            }
            for (modelFingerprint, modelKeys) in Dictionary(grouping: keys, by: \.modelFingerprint) {
                var rebuilt = [Int64: VisualHashBlock?]()
                for key in modelKeys {
                    rebuilt.updateValue(
                        try VisualEmbeddingHashBlocks.loadBlock(key, on: database),
                        forKey: key.blockID
                    )
                }
                visualAngularShortlistCache.apply(
                    modelFingerprint: modelFingerprint,
                    expectedGeneration: expectedGeneration,
                    generation: generation,
                    rebuiltBlocks: rebuilt
                )
            }
        } catch {
            visualAngularShortlistCache.invalidate()
        }
    }

    public func nearestVisualEmbeddings(
        _ requestedQuery: VisualEmbeddingQuery
    ) throws -> [VisualEmbeddingMatch] {
        try Task.checkCancellation()
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let query = try Self.validatedVisualQuery(requestedQuery)
        let normalizedQuery = try VisualEmbeddingCodec.normalizedQuery(
            query.vector,
            expectedDimension: VisualEmbeddingCodec.embeddingDimension
        )

        try Self.visualExecute("BEGIN DEFERRED", on: database)
        do {
            guard let model = try visualStoredModel(
                fingerprint: query.modelFingerprint,
                on: database
            ) else {
                try Self.visualExecute("COMMIT", on: database)
                return []
            }
            guard model.embeddingDimension == normalizedQuery.count else {
                throw VisualEmbeddingStoreError.corruptStoredVector
            }
            let queryHash = VisualEmbeddingCodec.angularHash(
                normalizedVector: normalizedQuery,
                modelFingerprint: model.fingerprint
            )
            let shortlist = try visualCachedAngularShortlist(
                queryHash: queryHash,
                query: query,
                on: database
            )
            guard !shortlist.isEmpty else {
                try Self.visualExecute("COMMIT", on: database)
                return []
            }
            let scored = try visualExactScores(
                candidates: shortlist,
                normalizedQuery: normalizedQuery,
                model: model,
                on: database
            )
            let representatives = try visualRepresentatives(
                vectorIDs: scored.map(\.vectorID),
                query: query,
                on: database
            )
            var matches = [VisualEmbeddingMatch]()
            matches.reserveCapacity(min(query.limit, scored.count))
            for score in scored where score.similarity >= query.minimumSimilarity {
                guard var representative = representatives[score.vectorID] else { continue }
                representative.hit.score = score.similarity
                matches.append(VisualEmbeddingMatch(
                    hit: representative.hit,
                    similarity: score.similarity,
                    maximumSimilarityError: score.maximumCosineError,
                    model: model,
                    associatedFrameCount: representative.associatedFrameCount,
                    sourceVisualFingerprint: representative.sourceVisualFingerprint
                ))
                if matches.count == query.limit { break }
            }
            try Task.checkCancellation()
            try Self.visualExecute("COMMIT", on: database)
            return matches
        } catch {
            try? Self.visualExecute("ROLLBACK", on: database)
            throw error
        }
    }

    public func visualEmbeddingCoverage(
        for requestedModel: VisualModelIdentity
    ) throws -> VisualEmbeddingCoverage {
        try Task.checkCancellation()
        try Self.validateVisualModel(requestedModel)
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let storedModel = try visualStoredModel(
            fingerprint: requestedModel.fingerprint,
            on: database
        )
        if let storedModel, storedModel != requestedModel {
            throw VisualEmbeddingStoreError.modelFingerprintCollision
        }
        let model = storedModel ?? requestedModel
        let eligible = try visualScalarInt(
            """
            SELECT COUNT(*) FROM frames
            WHERE is_sensitive = 0
              AND (thumbnail_path IS NOT NULL OR image_path != '')
            """,
            values: [],
            on: database
        )
        let indexedEligible = try visualScalarInt(
            """
            SELECT COUNT(*)
            FROM visual_frame_embeddings AS association
            JOIN frames AS frame ON frame.id = association.frame_id
            WHERE association.model_fingerprint = ?
              AND frame.is_sensitive = 0
              AND (frame.thumbnail_path IS NOT NULL OR frame.image_path != '')
              AND association.source_visual_fingerprint = frame.visual_fingerprint
            """,
            values: [.text(model.fingerprint)],
            on: database
        )
        let indexed = try visualScalarInt(
            """
            SELECT COUNT(*)
            FROM visual_frame_embeddings AS association
            JOIN frames AS frame ON frame.id = association.frame_id
            WHERE association.model_fingerprint = ? AND frame.is_sensitive = 0
            """,
            values: [.text(model.fingerprint)],
            on: database
        )
        let stale = try visualScalarInt(
            """
            SELECT COUNT(*)
            FROM visual_frame_embeddings AS association
            JOIN frames AS frame ON frame.id = association.frame_id
            WHERE association.model_fingerprint = ?
              AND frame.is_sensitive = 0
              AND association.source_visual_fingerprint != frame.visual_fingerprint
            """,
            values: [.text(model.fingerprint)],
            on: database
        )
        let vectorAggregate: (Int64, Int64) = try visualWithStatement(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(length(quantized_vector) + length(angular_hash)), 0)
            FROM visual_embedding_vectors WHERE model_fingerprint = ?
            """,
            on: database
        ) { statement in
            Self.visualBind(model.fingerprint, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            return (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1)
            )
        }
        let eligibleCount = Int(clamping: eligible)
        let indexedEligibleCount = Int(clamping: indexedEligible)
        let indexedCount = Int(clamping: indexed)
        let uniqueVectorCount = Int(clamping: vectorAggregate.0)
        return VisualEmbeddingCoverage(
            model: model,
            eligibleFrameCount: eligibleCount,
            indexedEligibleFrameCount: indexedEligibleCount,
            indexedFrameCount: indexedCount,
            pendingEligibleFrameCount: max(eligibleCount - indexedEligibleCount, 0),
            staleEmbeddingCount: Int(clamping: stale),
            uniqueVectorCount: uniqueVectorCount,
            deduplicatedFrameCount: max(indexedCount - uniqueVectorCount, 0),
            storedVectorPayloadBytes: vectorAggregate.1,
            coverageFraction: eligibleCount == 0
                ? nil
                : Double(indexedEligibleCount) / Double(eligibleCount)
        )
    }

    public func framesNeedingVisualEmbedding(
        for model: VisualModelIdentity,
        limit: Int
    ) throws -> [VisualEmbeddingCandidate] {
        try Task.checkCancellation()
        try Self.validateVisualModel(model)
        guard (1...1_000).contains(limit) else {
            throw VisualEmbeddingStoreError.invalidQuery
        }
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        if let stored = try visualStoredModel(fingerprint: model.fingerprint, on: database),
           stored != model {
            throw VisualEmbeddingStoreError.modelFingerprintCollision
        }
        // Once a full enumeration proved everything below the floor is
        // indexed, later passes only walk the newest sliver of the captured
        // order instead of joining the entire frames table per capture.
        let floor = visualPendingScanFloors[model.fingerprint]
        let floorClause = floor == nil ? "" : """
              AND (
                  frame.captured_at > ?3
                  OR (frame.captured_at = ?3 AND frame.id >= ?4)
              )
            """
        let candidates = try visualWithStatement(
            """
            SELECT frame.id, frame.captured_at, frame.image_path, frame.thumbnail_path,
                   frame.pixel_width, frame.pixel_height, frame.visual_fingerprint,
                   frame.is_sensitive
            FROM frames AS frame
            LEFT JOIN visual_frame_embeddings AS association
              ON association.frame_id = frame.id
             AND association.model_fingerprint = ?
            WHERE frame.is_sensitive = 0
              AND (frame.thumbnail_path IS NOT NULL OR frame.image_path != '')
              AND (
                  association.frame_id IS NULL
                  OR association.source_visual_fingerprint != frame.visual_fingerprint
              )
            \(floorClause)
            ORDER BY frame.captured_at DESC, frame.id DESC
            LIMIT ?2
            """,
            on: database
        ) { statement in
            Self.visualBind(model.fingerprint, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, Int64(limit))
            if let floor {
                sqlite3_bind_double(statement, 3, floor.capturedAt)
                Self.visualBind(floor.id, at: 4, to: statement)
            }
            var candidates = [VisualEmbeddingCandidate]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { try visualThrowStep(status) }
                candidates.append(VisualEmbeddingCandidate(
                    frameID: FrameID(rawValue: Self.visualString(statement, column: 0) ?? ""),
                    capturedAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 1)
                    ),
                    imageRelativePath: Self.visualString(statement, column: 2) ?? "",
                    thumbnailRelativePath: Self.visualString(statement, column: 3),
                    pixelWidth: Int(clamping: sqlite3_column_int64(statement, 4)),
                    pixelHeight: Int(clamping: sqlite3_column_int64(statement, 5)),
                    visualFingerprint: UInt64(
                        bitPattern: sqlite3_column_int64(statement, 6)
                    ),
                    isSensitive: sqlite3_column_int64(statement, 7) != 0
                ))
            }
            return candidates
        }
        if candidates.count < limit {
            // The window was not exhausted, so this is the complete pending
            // set above the current floor. Everything strictly older than the
            // oldest pending frame — or, with none pending, older than the
            // newest retained frame — is proven indexed for this model.
            let newFloor: VisualPendingScanFloor?
            if let oldestPending = candidates.last {
                newFloor = VisualPendingScanFloor(
                    capturedAt: oldestPending.capturedAt.timeIntervalSince1970,
                    id: oldestPending.frameID.rawValue
                )
            } else {
                newFloor = try visualNewestFrameFloor(on: database)
            }
            if let newFloor {
                visualPendingScanFloors[model.fingerprint] = newFloor
            }
        }
        return candidates
    }

    /// An insert at or below a floor may introduce pending work the floor
    /// claims is already indexed; lower every model's floor to include it.
    func lowerVisualPendingScanFloors(toInclude inserted: VisualPendingScanFloor) {
        for (fingerprint, floor) in visualPendingScanFloors {
            let insertedIsBelow = inserted.capturedAt < floor.capturedAt
                || (inserted.capturedAt == floor.capturedAt && inserted.id < floor.id)
            if insertedIsBelow {
                visualPendingScanFloors[fingerprint] = inserted
            }
        }
    }

    private func visualNewestFrameFloor(
        on database: OpaquePointer
    ) throws -> VisualPendingScanFloor? {
        try visualWithStatement(
            "SELECT captured_at, id FROM frames ORDER BY captured_at DESC, id DESC LIMIT 1",
            on: database
        ) { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW,
                  let id = Self.visualString(statement, column: 1) else {
                try visualThrowStep(status)
            }
            return VisualPendingScanFloor(
                capturedAt: sqlite3_column_double(statement, 0),
                id: id
            )
        }
    }

    public func deleteVisualEmbeddings(modelFingerprint: String) throws -> Int {
        try Task.checkCancellation()
        try Self.validateVisualFingerprint(modelFingerprint)
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        try Self.visualExecute("BEGIN IMMEDIATE", on: database)
        do {
            let associationCount = try visualScalarInt(
                "SELECT COUNT(*) FROM visual_frame_embeddings WHERE model_fingerprint = ?",
                values: [.text(modelFingerprint)],
                on: database
            )
            try visualWithStatement(
                "DELETE FROM visual_frame_embeddings WHERE model_fingerprint = ?",
                on: database
            ) { statement in
                Self.visualBind(modelFingerprint, at: 1, to: statement)
                try visualStepDone(statement)
            }
            try visualWithStatement(
                "DELETE FROM visual_embedding_vectors WHERE model_fingerprint = ?",
                on: database
            ) { statement in
                Self.visualBind(modelFingerprint, at: 1, to: statement)
                try visualStepDone(statement)
            }
            try visualWithStatement(
                "DELETE FROM visual_embedding_models WHERE fingerprint = ?",
                on: database
            ) { statement in
                Self.visualBind(modelFingerprint, at: 1, to: statement)
                try visualStepDone(statement)
            }
            if associationCount > 0 {
                try VisualEmbeddingHashBlocks.markChanged(on: database)
            }
            try Self.visualExecute("COMMIT", on: database)
            // Every eligible frame is pending again for this model.
            visualPendingScanFloors[modelFingerprint] = nil
            try connection.hardenFilePermissions()
            return Int(clamping: associationCount)
        } catch {
            try? Self.visualExecute("ROLLBACK", on: database)
            throw error
        }
    }
}

private extension SQLiteFrameStore {
    static func validateVisualModel(_ model: VisualModelIdentity) throws {
        let fields = [
            ("identifier", model.identifier),
            ("revision", model.revision),
            ("preprocessing revision", model.preprocessingRevision),
        ]
        for (name, value) in fields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= 256 else {
                throw VisualEmbeddingStoreError.invalidModelIdentity(name)
            }
        }
        try validateVisualFingerprint(model.fingerprint)
        guard model.embeddingDimension == VisualEmbeddingCodec.embeddingDimension else {
            throw VisualEmbeddingStoreError.invalidModelIdentity("embedding dimension")
        }
    }

    static func validateVisualFingerprint(_ fingerprint: String) throws {
        guard fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw VisualEmbeddingStoreError.invalidModelIdentity("fingerprint")
        }
    }

    static func validatedVisualQuery(_ query: VisualEmbeddingQuery) throws
        -> VisualEmbeddingQuery {
        try validateVisualFingerprint(query.modelFingerprint)
        guard query.minimumSimilarity.isFinite,
              (-1...1).contains(query.minimumSimilarity),
              (1...200).contains(query.limit),
              query.candidateLimit >= query.limit,
              query.candidateLimit <= 65_536,
              query.excludedFrameIDs.count <= 64,
              query.excludedFrameIDs.allSatisfy({ id in
                  !id.rawValue.isEmpty && id.rawValue.utf8.count <= 1_024
              }) else {
            throw VisualEmbeddingStoreError.invalidQuery
        }
        if let startDate = query.startDate,
           !startDate.timeIntervalSince1970.isFinite {
            throw VisualEmbeddingStoreError.invalidQuery
        }
        if let endDate = query.endDate,
           !endDate.timeIntervalSince1970.isFinite {
            throw VisualEmbeddingStoreError.invalidQuery
        }
        if let startDate = query.startDate,
           let endDate = query.endDate,
           startDate >= endDate {
            throw VisualEmbeddingStoreError.invalidQuery
        }
        return VisualEmbeddingQuery(
            modelFingerprint: query.modelFingerprint,
            vector: query.vector,
            startDate: query.startDate,
            endDate: query.endDate,
            applicationBundleIdentifiers: query.applicationBundleIdentifiers,
            domains: query.domains,
            excludedFrameIDs: query.excludedFrameIDs,
            minimumSimilarity: query.minimumSimilarity,
            limit: query.limit,
            candidateLimit: query.candidateLimit
        )
    }

    func visualRegisterModel(
        _ model: VisualModelIdentity,
        on database: OpaquePointer
    ) throws {
        if let stored = try visualStoredModel(fingerprint: model.fingerprint, on: database) {
            guard stored == model else {
                throw VisualEmbeddingStoreError.modelFingerprintCollision
            }
            return
        }
        try visualWithStatement(
            """
            INSERT INTO visual_embedding_models(
                fingerprint, identifier, revision, preprocessing_revision,
                embedding_dimension, vector_encoding, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        ) { statement in
            Self.visualBind(model.fingerprint, at: 1, to: statement)
            Self.visualBind(model.identifier, at: 2, to: statement)
            Self.visualBind(model.revision, at: 3, to: statement)
            Self.visualBind(model.preprocessingRevision, at: 4, to: statement)
            sqlite3_bind_int64(statement, 5, Int64(model.embeddingDimension))
            Self.visualBind(VisualEmbeddingCodec.encoding, at: 6, to: statement)
            sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
            try visualStepDone(statement)
        }
    }

    func visualStoredModel(
        fingerprint: String,
        on database: OpaquePointer
    ) throws -> VisualModelIdentity? {
        try visualWithStatement(
            """
            SELECT identifier, revision, preprocessing_revision, embedding_dimension,
                   vector_encoding
            FROM visual_embedding_models WHERE fingerprint = ? LIMIT 1
            """,
            on: database
        ) { statement in
            Self.visualBind(fingerprint, at: 1, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { try visualThrowStep(status) }
            guard Self.visualString(statement, column: 4) == VisualEmbeddingCodec.encoding else {
                throw VisualEmbeddingStoreError.corruptStoredVector
            }
            let model = VisualModelIdentity(
                identifier: Self.visualString(statement, column: 0) ?? "",
                revision: Self.visualString(statement, column: 1) ?? "",
                fingerprint: fingerprint,
                preprocessingRevision: Self.visualString(statement, column: 2) ?? "",
                embeddingDimension: Int(clamping: sqlite3_column_int64(statement, 3))
            )
            try Self.validateVisualModel(model)
            return model
        }
    }

    func visualFrameState(id: FrameID, on database: OpaquePointer) throws
        -> VisualFrameState? {
        try visualWithStatement(
            "SELECT rowid, visual_fingerprint, is_sensitive FROM frames WHERE id = ? LIMIT 1",
            on: database
        ) { statement in
            Self.visualBind(id.rawValue, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return VisualFrameState(
                rowID: sqlite3_column_int64(statement, 0),
                visualFingerprint: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                isSensitive: sqlite3_column_int64(statement, 2) != 0
            )
        }
    }

    func visualInsertOrReuseVector(
        _ encoded: QuantizedVisualEmbedding,
        model: VisualModelIdentity,
        createdAt: Date,
        on database: OpaquePointer
    ) throws -> StoredVisualVectorIdentity {
        try visualWithStatement(
            """
            INSERT OR IGNORE INTO visual_embedding_vectors(
                model_fingerprint, content_hash, angular_hash, quantized_vector,
                quantization_scale, maximum_cosine_error, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        ) { statement in
            Self.visualBind(model.fingerprint, at: 1, to: statement)
            Self.visualBind(encoded.contentHash, at: 2, to: statement)
            Self.visualBind(encoded.angularHash, at: 3, to: statement)
            Self.visualBind(encoded.bytes, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, encoded.scale)
            sqlite3_bind_double(statement, 6, encoded.maximumCosineError)
            sqlite3_bind_double(statement, 7, createdAt.timeIntervalSince1970)
            try visualStepDone(statement)
        }
        let inserted = sqlite3_changes(database) == 1
        return try visualWithStatement(
            """
            SELECT id, angular_hash, quantized_vector, quantization_scale,
                   maximum_cosine_error
            FROM visual_embedding_vectors
            WHERE model_fingerprint = ? AND content_hash = ? LIMIT 1
            """,
            on: database
        ) { statement in
            Self.visualBind(model.fingerprint, at: 1, to: statement)
            Self.visualBind(encoded.contentHash, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let storedAngular = Self.visualData(statement, column: 1),
                  let storedVector = Self.visualData(statement, column: 2),
                  storedAngular == encoded.angularHash,
                  storedVector == encoded.bytes,
                  sqlite3_column_double(statement, 3).bitPattern == encoded.scale.bitPattern,
                  sqlite3_column_double(statement, 4).bitPattern
                    == encoded.maximumCosineError.bitPattern else {
                throw VisualEmbeddingStoreError.corruptStoredVector
            }
            return StoredVisualVectorIdentity(
                id: sqlite3_column_int64(statement, 0),
                wasInserted: inserted
            )
        }
    }

    func visualAssociation(
        frameID: FrameID,
        modelFingerprint: String,
        on database: OpaquePointer
    ) throws -> StoredVisualAssociation? {
        try visualWithStatement(
            """
            SELECT vector_id, source_visual_fingerprint
            FROM visual_frame_embeddings
            WHERE frame_id = ? AND model_fingerprint = ? LIMIT 1
            """,
            on: database
        ) { statement in
            Self.visualBind(frameID.rawValue, at: 1, to: statement)
            Self.visualBind(modelFingerprint, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredVisualAssociation(
                vectorID: sqlite3_column_int64(statement, 0),
                sourceVisualFingerprint: UInt64(
                    bitPattern: sqlite3_column_int64(statement, 1)
                )
            )
        }
    }

    func visualWriteAssociation(
        frameID: FrameID,
        frameRowID: Int64,
        modelFingerprint: String,
        vectorID: Int64,
        sourceVisualFingerprint: UInt64,
        indexedAt: Date,
        on database: OpaquePointer
    ) throws {
        try visualWithStatement(
            """
            INSERT INTO visual_frame_embeddings(
                frame_id, frame_rowid, model_fingerprint, vector_id,
                source_visual_fingerprint, indexed_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(frame_id, model_fingerprint) DO UPDATE SET
                frame_rowid = excluded.frame_rowid,
                vector_id = excluded.vector_id,
                source_visual_fingerprint = excluded.source_visual_fingerprint,
                indexed_at = excluded.indexed_at
            """,
            on: database
        ) { statement in
            Self.visualBind(frameID.rawValue, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, frameRowID)
            Self.visualBind(modelFingerprint, at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, vectorID)
            sqlite3_bind_int64(statement, 5, Int64(bitPattern: sourceVisualFingerprint))
            sqlite3_bind_double(statement, 6, indexedAt.timeIntervalSince1970)
            try visualStepDone(statement)
        }
    }

    func visualDeleteVectorIfOrphaned(id: Int64, on database: OpaquePointer) throws
        -> Int64? {
        let bytes = try visualScalarInt(
            """
            SELECT COALESCE(length(quantized_vector) + length(angular_hash), 0)
            FROM visual_embedding_vectors WHERE id = ? LIMIT 1
            """,
            values: [.integer(id)],
            on: database
        )
        try visualWithStatement(
            """
            DELETE FROM visual_embedding_vectors
            WHERE id = ? AND NOT EXISTS (
                SELECT 1 FROM visual_frame_embeddings WHERE vector_id = ?
            )
            """,
            on: database
        ) { statement in
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_bind_int64(statement, 2, id)
            try visualStepDone(statement)
        }
        return sqlite3_changes(database) == 1 ? bytes : nil
    }

    func visualCachedAngularShortlist(
        queryHash: Data,
        query: VisualEmbeddingQuery,
        on database: OpaquePointer
    ) throws -> [AngularCandidate] {
        guard let generation = try VisualEmbeddingHashBlocks.generation(on: database) else {
            // Read-only tools can encounter a schema-v8 vault before the main
            // app has performed its writable migration. Preserve correctness
            // with the former encrypted row scan in that narrow case.
            return try visualAngularShortlist(
                queryHash: queryHash,
                query: query,
                on: database
            )
        }
        let scopedVectorIDs = VisualEmbeddingShortlistSQL.isScoped(query)
            ? try visualScopedVectorIDs(query, on: database)
            : nil
        return try visualAngularShortlistCache.shortlist(
            modelFingerprint: query.modelFingerprint,
            generation: generation,
            queryHash: queryHash,
            candidateLimit: query.candidateLimit,
            scopedVectorIDs: scopedVectorIDs
        ) {
            try VisualEmbeddingHashBlocks.load(
                modelFingerprint: query.modelFingerprint,
                on: database
            )
        }
    }

    func visualScopedVectorIDs(
        _ query: VisualEmbeddingQuery,
        on database: OpaquePointer
    ) throws -> [Int64] {
        var unusedClauses = [String]()
        var scopeValues = [VisualBoundValue]()
        Self.appendVisualScope(query, clauses: &unusedClauses, values: &scopeValues)
        let sql = VisualEmbeddingShortlistSQL.scopedVectorIDsStatement(for: query)
        sqlite3_progress_handler(database, 1_000, { _ in
            withUnsafeCurrentTask { task in
                task?.isCancelled == true ? 1 : 0
            }
        }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        return try visualWithStatement(sql, on: database) { statement in
            Self.visualBind(query.modelFingerprint, at: 1, to: statement)
            Self.visualBind(scopeValues, startingAt: 2, to: statement)
            var vectorIDs = [Int64]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return vectorIDs }
                guard status == SQLITE_ROW else { try visualThrowStep(status) }
                vectorIDs.append(sqlite3_column_int64(statement, 0))
                if vectorIDs.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
            }
        }
    }

    func visualAngularShortlist(
        queryHash: Data,
        query: VisualEmbeddingQuery,
        on database: OpaquePointer
    ) throws -> [AngularCandidate] {
        let isScoped = VisualEmbeddingShortlistSQL.isScoped(query)
        var unusedClauses = [String]()
        var scopeValues = [VisualBoundValue]()
        Self.appendVisualScope(
            query,
            clauses: &unusedClauses,
            values: &scopeValues
        )
        let sql = VisualEmbeddingShortlistSQL.statement(for: query)
        sqlite3_progress_handler(database, 1_000, { _ in
            withUnsafeCurrentTask { task in
                task?.isCancelled == true ? 1 : 0
            }
        }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        return try visualWithStatement(sql, on: database) { statement in
            if isScoped {
                Self.visualBind(query.modelFingerprint, at: 1, to: statement)
                Self.visualBind(query.modelFingerprint, at: 2, to: statement)
                Self.visualBind(scopeValues, startingAt: 3, to: statement)
            } else {
                Self.visualBind(query.modelFingerprint, at: 1, to: statement)
                Self.visualBind(query.modelFingerprint, at: 2, to: statement)
            }
            var heap = AngularCandidateHeap(capacity: query.candidateLimit)
            var rowCount = 0
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { try visualThrowStep(status) }
                guard let pointer = sqlite3_column_blob(statement, 1) else {
                    throw VisualEmbeddingStoreError.corruptStoredVector
                }
                let byteCount = Int(sqlite3_column_bytes(statement, 1))
                let distance = try VisualEmbeddingCodec.angularDistance(
                    queryHash,
                    UnsafeRawBufferPointer(start: pointer, count: byteCount)
                )
                heap.insert(AngularCandidate(
                    vectorID: sqlite3_column_int64(statement, 0),
                    distance: distance
                ))
                rowCount += 1
                if rowCount.isMultiple(of: 1_024) { try Task.checkCancellation() }
            }
            return heap.values
        }
    }

    func visualExactScores(
        candidates: [AngularCandidate],
        normalizedQuery: [Double],
        model: VisualModelIdentity,
        on database: OpaquePointer
    ) throws -> [ScoredVisualVector] {
        let distanceByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.vectorID, $0.distance) }
        )
        var scores = [ScoredVisualVector]()
        scores.reserveCapacity(candidates.count)
        for chunk in candidates.map(\.vectorID).chunked(maximumCount: 400) {
            try Task.checkCancellation()
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try visualWithStatement(
                VisualEmbeddingExactScoreSQL.statement(placeholders: placeholders),
                on: database
            ) { statement in
                Self.visualBind(model.fingerprint, at: 1, to: statement)
                for (offset, id) in chunk.enumerated() {
                    sqlite3_bind_int64(statement, Int32(offset + 2), id)
                }
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { try visualThrowStep(status) }
                    guard let bytes = Self.visualData(statement, column: 1) else {
                        throw VisualEmbeddingStoreError.corruptStoredVector
                    }
                    let id = sqlite3_column_int64(statement, 0)
                    let similarity = try VisualEmbeddingCodec.similarity(
                        normalizedQuery: normalizedQuery,
                        bytes: bytes,
                        scale: sqlite3_column_double(statement, 2),
                        expectedDimension: model.embeddingDimension
                    )
                    let error = sqlite3_column_double(statement, 3)
                    guard error.isFinite, error >= 0,
                          let distance = distanceByID[id] else {
                        throw VisualEmbeddingStoreError.corruptStoredVector
                    }
                    scores.append(ScoredVisualVector(
                        vectorID: id,
                        similarity: similarity,
                        maximumCosineError: error,
                        angularDistance: distance
                    ))
                }
            }
        }
        return scores.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.angularDistance != $1.angularDistance {
                return $0.angularDistance < $1.angularDistance
            }
            return $0.vectorID < $1.vectorID
        }
    }

    func visualRepresentatives(
        vectorIDs: [Int64],
        query: VisualEmbeddingQuery,
        on database: OpaquePointer
    ) throws -> [Int64: VisualRepresentative] {
        let frameJoin = try VisualEmbeddingHashBlocks.generation(on: database) == nil
            ? "frame.id = association.frame_id"
            : "frame.rowid = association.frame_rowid"
        var result = [Int64: VisualRepresentative]()
        for chunk in vectorIDs.chunked(maximumCount: 350) {
            try Task.checkCancellation()
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            var clauses = [
                frameJoin,
                "association.model_fingerprint = ?",
                "association.vector_id IN (\(placeholders))",
                "frame.is_sensitive = 0",
                "association.source_visual_fingerprint = frame.visual_fingerprint",
            ]
            var values: [VisualBoundValue] = [.text(query.modelFingerprint)]
            values.append(contentsOf: chunk.map(VisualBoundValue.integer))
            Self.appendVisualScope(query, clauses: &clauses, values: &values)
            let sql = """
                WITH scoped AS (
                    SELECT association.vector_id,
                           COUNT(*) OVER (PARTITION BY association.vector_id) AS association_count,
                           ROW_NUMBER() OVER (
                               PARTITION BY association.vector_id
                               ORDER BY frame.captured_at DESC, frame.id DESC
                           ) AS representative_rank,
                           frame.id, frame.captured_at, frame.application_name,
                           frame.bundle_identifier, frame.window_title, frame.url, frame.domain,
                           frame.display_id, frame.window_id, frame.window_x, frame.window_y,
                           frame.window_width, frame.window_height, frame.image_path,
                           frame.thumbnail_path, substr(frame.ocr_text, 1, 240) AS excerpt,
                           frame.is_sensitive, frame.activity_session_id,
                           frame.visual_fingerprint
                    FROM visual_frame_embeddings AS association
                        INDEXED BY visual_frame_embeddings_model
                    CROSS JOIN frames AS frame
                    WHERE \(clauses.joined(separator: " AND "))
                )
                SELECT vector_id, association_count, id, captured_at, application_name,
                       bundle_identifier, window_title, url, domain, display_id, window_id,
                       window_x, window_y, window_width, window_height, image_path,
                       thumbnail_path, excerpt, is_sensitive, activity_session_id,
                       visual_fingerprint
                FROM scoped WHERE representative_rank = 1
                """
            try visualWithStatement(sql, on: database) { statement in
                Self.visualBind(values, startingAt: 1, to: statement)
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { try visualThrowStep(status) }
                    let vectorID = sqlite3_column_int64(statement, 0)
                    let applicationName = Self.visualString(statement, column: 4) ?? "Unknown"
                    let context = ScreenContext(
                        applicationName: applicationName,
                        bundleIdentifier: Self.visualString(statement, column: 5),
                        windowTitle: Self.visualString(statement, column: 6),
                        url: Self.visualString(statement, column: 7).flatMap(URL.init(string:)),
                        domain: Self.visualString(statement, column: 8),
                        displayID: Self.visualUInt32(statement, column: 9),
                        windowID: Self.visualUInt32(statement, column: 10),
                        windowBounds: Self.visualScreenRect(
                            statement,
                            xColumn: 11,
                            yColumn: 12,
                            widthColumn: 13,
                            heightColumn: 14
                        ),
                        isSensitive: sqlite3_column_int64(statement, 18) != 0
                    )
                    result[vectorID] = VisualRepresentative(
                        hit: SearchHit(
                            id: FrameID(
                                rawValue: Self.visualString(statement, column: 2) ?? ""
                            ),
                            activitySessionID: Self.visualString(statement, column: 19)
                                .map(ActivitySessionID.init(rawValue:)),
                            capturedAt: Date(
                                timeIntervalSince1970: sqlite3_column_double(statement, 3)
                            ),
                            context: context,
                            snippet: Self.visualString(statement, column: 17) ?? "",
                            imageRelativePath: Self.visualString(statement, column: 15) ?? "",
                            thumbnailRelativePath: Self.visualString(statement, column: 16),
                            score: 0
                        ),
                        associatedFrameCount: Int(
                            clamping: sqlite3_column_int64(statement, 1)
                        ),
                        sourceVisualFingerprint: UInt64(
                            bitPattern: sqlite3_column_int64(statement, 20)
                        )
                    )
                }
            }
        }
        return result
    }

    static func appendVisualScope(
        _ query: VisualEmbeddingQuery,
        clauses: inout [String],
        values: inout [VisualBoundValue]
    ) {
        if let startDate = query.startDate {
            clauses.append("frame.captured_at >= ?")
            values.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = query.endDate {
            clauses.append("frame.captured_at < ?")
            values.append(.double(endDate.timeIntervalSince1970))
        }
        if !query.applicationBundleIdentifiers.isEmpty {
            let sorted = query.applicationBundleIdentifiers.sorted()
            clauses.append(
                "frame.bundle_identifier IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))"
            )
            values.append(contentsOf: sorted.map(VisualBoundValue.text))
        }
        if !query.domains.isEmpty {
            let sorted = query.domains.sorted()
            clauses.append(
                "frame.domain COLLATE NOCASE IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))"
            )
            values.append(contentsOf: sorted.map(VisualBoundValue.text))
        }
        if !query.excludedFrameIDs.isEmpty {
            let sorted = query.excludedFrameIDs.map(\.rawValue).sorted()
            clauses.append(
                "frame.id NOT IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))"
            )
            values.append(contentsOf: sorted.map(VisualBoundValue.text))
        }
    }

    func visualScalarInt(
        _ sql: String,
        values: [VisualBoundValue],
        on database: OpaquePointer
    ) throws -> Int64 {
        try visualWithStatement(sql, on: database) { statement in
            Self.visualBind(values, startingAt: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func visualWithStatement<Result>(
        _ sql: String,
        on database: OpaquePointer,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func visualThrowStep(_ status: Int32) throws -> Never {
        if status == SQLITE_INTERRUPT || Task<Never, Never>.isCancelled {
            throw CancellationError()
        }
        throw PassageError.database(String(cString: sqlite3_errstr(status)))
    }

    func visualStepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { try visualThrowStep(status) }
    }

    static func visualExecute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw PassageError.database(message)
        }
    }

    static func visualBind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, visualSQLiteTransient)
    }

    static func visualBind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                visualSQLiteTransient
            )
        }
    }

    static func visualBind(
        _ values: [VisualBoundValue],
        startingAt firstIndex: Int32,
        to statement: OpaquePointer
    ) {
        for (offset, value) in values.enumerated() {
            value.bind(at: firstIndex + Int32(offset), to: statement)
        }
    }

    static func visualString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    static func visualData(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    static func visualUInt32(_ statement: OpaquePointer, column: Int32) -> UInt32? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0, value <= Int64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    static func visualScreenRect(
        _ statement: OpaquePointer,
        xColumn: Int32,
        yColumn: Int32,
        widthColumn: Int32,
        heightColumn: Int32
    ) -> ScreenRect? {
        let columns = [xColumn, yColumn, widthColumn, heightColumn]
        guard columns.allSatisfy({ sqlite3_column_type(statement, $0) != SQLITE_NULL }) else {
            return nil
        }
        return ScreenRect(
            x: sqlite3_column_double(statement, xColumn),
            y: sqlite3_column_double(statement, yColumn),
            width: sqlite3_column_double(statement, widthColumn),
            height: sqlite3_column_double(statement, heightColumn)
        )
    }
}

enum VisualEmbeddingExactScoreSQL {
    static func statement(candidateCount: Int) -> String {
        precondition(candidateCount > 0)
        return statement(
            placeholders: Array(repeating: "?", count: candidateCount).joined(separator: ", ")
        )
    }

    fileprivate static func statement(placeholders: String) -> String {
        """
        SELECT id, quantized_vector, quantization_scale, maximum_cosine_error
        FROM visual_embedding_vectors AS vector NOT INDEXED
        WHERE vector.model_fingerprint = ? AND vector.id IN (\(placeholders))
        """
    }
}

/// Centralizes the shortlist statement so query-plan tests exercise the same
/// SQL production retrieval prepares. Metadata-scoped reads start with an
/// applicable frame index; exclusion-only reads start with the model's compact
/// association range. `CROSS JOIN` preserves those loop orders before primary-
/// key lookups. The fully unscoped path remains a streaming scan of compact
/// angular hashes.
enum VisualEmbeddingShortlistSQL {
    static func isScoped(_ query: VisualEmbeddingQuery) -> Bool {
        query.startDate != nil
            || query.endDate != nil
            || !query.applicationBundleIdentifiers.isEmpty
            || !query.domains.isEmpty
            || !query.excludedFrameIDs.isEmpty
    }

    static func statement(for query: VisualEmbeddingQuery) -> String {
        guard isScoped(query) else {
            return """
                SELECT vector.id, vector.angular_hash
                FROM visual_embedding_vectors AS vector
                    INDEXED BY visual_embedding_vectors_angular_scan
                WHERE vector.model_fingerprint = ?
                  AND EXISTS (
                      SELECT 1
                      FROM visual_frame_embeddings AS association
                      JOIN frames AS frame ON frame.id = association.frame_id
                      WHERE association.vector_id = vector.id
                        AND association.model_fingerprint = ?
                        AND frame.is_sensitive = 0
                        AND association.source_visual_fingerprint = frame.visual_fingerprint
                  )
                """
        }

        var clauses = [
            "association.frame_id = frame.id",
            "association.model_fingerprint = ?",
            "vector.id = association.vector_id",
            "vector.model_fingerprint = ?",
            "frame.is_sensitive = 0",
            "association.source_visual_fingerprint = frame.visual_fingerprint",
        ]
        if query.startDate != nil { clauses.append("frame.captured_at >= ?") }
        if query.endDate != nil { clauses.append("frame.captured_at < ?") }
        if !query.applicationBundleIdentifiers.isEmpty {
            clauses.append(
                "frame.bundle_identifier IN (\(placeholders(query.applicationBundleIdentifiers.count)))"
            )
        }
        if !query.domains.isEmpty {
            clauses.append(
                "frame.domain COLLATE NOCASE IN (\(placeholders(query.domains.count)))"
            )
        }
        if !query.excludedFrameIDs.isEmpty {
            clauses.append(
                "frame.id NOT IN (\(placeholders(query.excludedFrameIDs.count)))"
            )
        }
        let hasIndexedFrameScope = query.startDate != nil
            || query.endDate != nil
            || !query.applicationBundleIdentifiers.isEmpty
            || !query.domains.isEmpty
        if !hasIndexedFrameScope {
            return """
                SELECT DISTINCT vector.id, vector.angular_hash
                FROM visual_frame_embeddings AS association
                    INDEXED BY visual_frame_embeddings_model
                CROSS JOIN frames AS frame
                CROSS JOIN visual_embedding_vectors AS vector
                    INDEXED BY visual_embedding_vectors_angular_scan
                WHERE \(clauses.joined(separator: " AND "))
                """
        }
        let frameIndex: String
        if !query.applicationBundleIdentifiers.isEmpty {
            frameIndex = "frames_application"
        } else if !query.domains.isEmpty {
            frameIndex = "frames_domain"
        } else {
            frameIndex = "frames_captured_at"
        }
        return """
            SELECT DISTINCT vector.id, vector.angular_hash
            FROM frames AS frame INDEXED BY \(frameIndex)
            CROSS JOIN visual_frame_embeddings AS association
            CROSS JOIN visual_embedding_vectors AS vector
                INDEXED BY visual_embedding_vectors_angular_scan
            WHERE \(clauses.joined(separator: " AND "))
            """
    }

    static func scopedVectorIDsStatement(for query: VisualEmbeddingQuery) -> String {
        precondition(isScoped(query))
        var clauses = [
            "association.frame_rowid = frame.rowid",
            "association.model_fingerprint = ?",
            "frame.is_sensitive = 0",
            "association.source_visual_fingerprint = frame.visual_fingerprint",
        ]
        if query.startDate != nil { clauses.append("frame.captured_at >= ?") }
        if query.endDate != nil { clauses.append("frame.captured_at < ?") }
        if !query.applicationBundleIdentifiers.isEmpty {
            clauses.append(
                "frame.bundle_identifier IN (\(placeholders(query.applicationBundleIdentifiers.count)))"
            )
        }
        if !query.domains.isEmpty {
            clauses.append(
                "frame.domain COLLATE NOCASE IN (\(placeholders(query.domains.count)))"
            )
        }
        if !query.excludedFrameIDs.isEmpty {
            clauses.append(
                "frame.id NOT IN (\(placeholders(query.excludedFrameIDs.count)))"
            )
        }
        let hasIndexedFrameScope = query.startDate != nil
            || query.endDate != nil
            || !query.applicationBundleIdentifiers.isEmpty
            || !query.domains.isEmpty
        if !hasIndexedFrameScope {
            return """
                SELECT DISTINCT association.vector_id
                FROM visual_frame_embeddings AS association
                    INDEXED BY visual_frame_embeddings_model
                CROSS JOIN frames AS frame
                WHERE \(clauses.joined(separator: " AND "))
                """
        }
        let frameIndex: String
        if !query.applicationBundleIdentifiers.isEmpty {
            frameIndex = "frames_application"
        } else if !query.domains.isEmpty {
            frameIndex = "frames_domain"
        } else {
            frameIndex = "frames_captured_at"
        }
        return """
            SELECT DISTINCT association.vector_id
            FROM frames AS frame INDEXED BY \(frameIndex)
            CROSS JOIN visual_frame_embeddings AS association
            WHERE \(clauses.joined(separator: " AND "))
            """
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

private let visualSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct VisualHashBlockKey: Hashable, Comparable {
    var modelFingerprint: String
    var blockID: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.modelFingerprint != rhs.modelFingerprint {
            return lhs.modelFingerprint < rhs.modelFingerprint
        }
        return lhs.blockID < rhs.blockID
    }
}

struct VisualHashBlock {
    var blockID: Int64
    var occupancy: Data
    var angularHashes: Data
}

final class VisualAngularShortlistCache {
    private struct Snapshot {
        var modelFingerprint: String
        var generation: Int64
        var blocks: [VisualHashBlock]
        var blockIndex: [Int64: Int]
    }

    private var snapshot: Snapshot?

    fileprivate func prewarm(
        modelFingerprint: String,
        generation: Int64,
        loader: () throws -> [VisualHashBlock]
    ) throws {
        try prepareSnapshot(
            modelFingerprint: modelFingerprint,
            generation: generation,
            loader: loader
        )
    }

    fileprivate func shortlist(
        modelFingerprint: String,
        generation: Int64,
        queryHash: Data,
        candidateLimit: Int,
        scopedVectorIDs: [Int64]?,
        loader: () throws -> [VisualHashBlock]
    ) throws -> [AngularCandidate] {
        try Task.checkCancellation()
        try prepareSnapshot(
            modelFingerprint: modelFingerprint,
            generation: generation,
            loader: loader
        )
        guard let snapshot else { return [] }
        let queryWords = try Self.words(in: queryHash)
        var buckets = AngularCandidateBuckets(capacity: candidateLimit)
        if let scopedVectorIDs {
            for (offset, vectorID) in scopedVectorIDs.sorted().enumerated() {
                if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
                guard vectorID > 0 else {
                    throw VisualEmbeddingStoreError.corruptStoredVector
                }
                let blockID = (vectorID - 1) / Int64(VisualEmbeddingHashBlocks.slotCount)
                let slot = Int((vectorID - 1) % Int64(VisualEmbeddingHashBlocks.slotCount))
                guard let blockOffset = snapshot.blockIndex[blockID] else {
                    throw VisualEmbeddingStoreError.corruptStoredVector
                }
                let block = snapshot.blocks[blockOffset]
                guard Self.isOccupied(slot: slot, occupancy: block.occupancy) else {
                    throw VisualEmbeddingStoreError.corruptStoredVector
                }
                buckets.insert(AngularCandidate(
                    vectorID: vectorID,
                    distance: try Self.distance(
                        queryWords: queryWords,
                        slot: slot,
                        angularHashes: block.angularHashes
                    )
                ))
            }
            return buckets.values
        }

        for (blockOffset, block) in snapshot.blocks.enumerated() {
            if blockOffset.isMultiple(of: 4) { try Task.checkCancellation() }
            let firstID = block.blockID * Int64(VisualEmbeddingHashBlocks.slotCount) + 1
            try block.occupancy.withUnsafeBytes { occupancy in
                try block.angularHashes.withUnsafeBytes { hashes in
                    guard occupancy.count == VisualEmbeddingHashBlocks.occupancyByteCount,
                          hashes.count == VisualEmbeddingHashBlocks.angularPayloadByteCount else {
                        throw VisualEmbeddingStoreError.corruptStoredVector
                    }
                    for slot in 0..<VisualEmbeddingHashBlocks.slotCount
                    where (occupancy[slot / 8] & UInt8(1 << (slot % 8))) != 0 {
                        buckets.insert(AngularCandidate(
                            vectorID: firstID + Int64(slot),
                            distance: Self.distance(
                                queryWords: queryWords,
                                slot: slot,
                                hashBytes: hashes
                            )
                        ))
                    }
                }
            }
        }
        return buckets.values
    }

    fileprivate func invalidate() {
        snapshot = nil
    }

    /// Applies freshly rebuilt blocks to the retained snapshot instead of
    /// discarding it. Steady-state indexing touches one or two blocks per
    /// capture; invalidating on the global generation would otherwise force
    /// prewarm to decrypt and reload every block after every saved moment.
    /// A nil block means the rebuild deleted the row because its ID range
    /// became fully unoccupied. The patch only applies when the snapshot is
    /// current up to `expectedGeneration`: if any other writer (deletion,
    /// orphan cleanup) advanced the generation since this snapshot was built,
    /// its block changes were never applied here, so the snapshot must stay
    /// stale and reload in full on next use.
    fileprivate func apply(
        modelFingerprint: String,
        expectedGeneration: Int64,
        generation: Int64,
        rebuiltBlocks: [Int64: VisualHashBlock?]
    ) {
        guard var current = snapshot,
              current.modelFingerprint == modelFingerprint,
              current.generation == expectedGeneration else { return }
        var removedAny = false
        for (blockID, block) in rebuiltBlocks {
            if let block {
                if let offset = current.blockIndex[blockID] {
                    current.blocks[offset] = block
                } else {
                    current.blockIndex[blockID] = current.blocks.count
                    current.blocks.append(block)
                }
            } else if let offset = current.blockIndex[blockID] {
                current.blocks.remove(at: offset)
                removedAny = true
            }
        }
        if removedAny {
            current.blockIndex = Dictionary(
                uniqueKeysWithValues: current.blocks.enumerated().map {
                    ($0.element.blockID, $0.offset)
                }
            )
        }
        current.generation = generation
        snapshot = current
    }

    private func prepareSnapshot(
        modelFingerprint: String,
        generation: Int64,
        loader: () throws -> [VisualHashBlock]
    ) throws {
        try Task.checkCancellation()
        guard snapshot?.modelFingerprint != modelFingerprint
            || snapshot?.generation != generation else { return }
        let blocks = try loader()
        try Task.checkCancellation()
        snapshot = Snapshot(
            modelFingerprint: modelFingerprint,
            generation: generation,
            blocks: blocks,
            blockIndex: Dictionary(
                uniqueKeysWithValues: blocks.enumerated().map { ($0.element.blockID, $0.offset) }
            )
        )
    }

    private static func isOccupied(slot: Int, occupancy: Data) -> Bool {
        occupancy[slot / 8] & UInt8(1 << (slot % 8)) != 0
    }

    private static func words(in hash: Data) throws -> [UInt64] {
        guard hash.count == VisualEmbeddingCodec.angularHashBytes else {
            throw VisualEmbeddingStoreError.corruptStoredVector
        }
        return hash.withUnsafeBytes { bytes in
            (0..<8).map {
                bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)
            }
        }
    }

    private static func distance(
        queryWords: [UInt64],
        slot: Int,
        angularHashes: Data
    ) throws -> Int {
        guard angularHashes.count == VisualEmbeddingHashBlocks.angularPayloadByteCount else {
            throw VisualEmbeddingStoreError.corruptStoredVector
        }
        return angularHashes.withUnsafeBytes {
            distance(queryWords: queryWords, slot: slot, hashBytes: $0)
        }
    }

    @inline(__always)
    private static func distance(
        queryWords: [UInt64],
        slot: Int,
        hashBytes: UnsafeRawBufferPointer
    ) -> Int {
        let base = slot * VisualEmbeddingCodec.angularHashBytes
        var result = 0
        for word in 0..<8 {
            result += (
                queryWords[word]
                    ^ hashBytes.loadUnaligned(
                        fromByteOffset: base + word * 8,
                        as: UInt64.self
                    )
            ).nonzeroBitCount
        }
        return result
    }
}

private struct AngularCandidateBuckets {
    private var vectorIDsByDistance = Array(repeating: [Int64](), count: 513)
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func insert(_ candidate: AngularCandidate) {
        guard (0..<vectorIDsByDistance.count).contains(candidate.distance),
              vectorIDsByDistance[candidate.distance].count < capacity else { return }
        vectorIDsByDistance[candidate.distance].append(candidate.vectorID)
    }

    var values: [AngularCandidate] {
        var result = [AngularCandidate]()
        result.reserveCapacity(capacity)
        for (distance, vectorIDs) in vectorIDsByDistance.enumerated() {
            let remaining = capacity - result.count
            guard remaining > 0 else { break }
            result.append(contentsOf: vectorIDs.prefix(remaining).map {
                AngularCandidate(vectorID: $0, distance: distance)
            })
        }
        return result
    }
}

private struct PreparedVisualEmbeddingWrite {
    var write: VisualEmbeddingWrite
    var encoded: QuantizedVisualEmbedding
}

private struct VisualFrameModelKey: Hashable {
    var frameID: String
    var modelFingerprint: String
}

private struct VisualFrameState {
    var rowID: Int64
    var visualFingerprint: UInt64
    var isSensitive: Bool
}

private struct StoredVisualVectorIdentity {
    var id: Int64
    var wasInserted: Bool
}

private struct StoredVisualAssociation {
    var vectorID: Int64
    var sourceVisualFingerprint: UInt64
}

private struct AngularCandidate {
    var vectorID: Int64
    var distance: Int
}

private struct AngularCandidateHeap {
    private(set) var values = [AngularCandidate]()
    let capacity: Int

    mutating func insert(_ candidate: AngularCandidate) {
        guard capacity > 0 else { return }
        if values.count < capacity {
            values.append(candidate)
            siftUp(from: values.count - 1)
        } else if Self.isBetter(candidate, than: values[0]) {
            values[0] = candidate
            siftDown(from: 0)
        }
    }

    private mutating func siftUp(from startIndex: Int) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isWorse(values[child], than: values[parent]) else { break }
            values.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from startIndex: Int) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            guard left < values.count else { return }
            let right = left + 1
            var worseChild = left
            if right < values.count, Self.isWorse(values[right], than: values[left]) {
                worseChild = right
            }
            guard Self.isWorse(values[worseChild], than: values[parent]) else { return }
            values.swapAt(parent, worseChild)
            parent = worseChild
        }
    }

    private static func isBetter(_ lhs: AngularCandidate, than rhs: AngularCandidate) -> Bool {
        lhs.distance < rhs.distance
            || (lhs.distance == rhs.distance && lhs.vectorID < rhs.vectorID)
    }

    private static func isWorse(_ lhs: AngularCandidate, than rhs: AngularCandidate) -> Bool {
        lhs.distance > rhs.distance
            || (lhs.distance == rhs.distance && lhs.vectorID > rhs.vectorID)
    }
}

private struct ScoredVisualVector {
    var vectorID: Int64
    var similarity: Double
    var maximumCosineError: Double
    var angularDistance: Int
}

private struct VisualRepresentative {
    var hit: SearchHit
    var associatedFrameCount: Int
    var sourceVisualFingerprint: UInt64
}

private enum VisualBoundValue {
    case text(String)
    case integer(Int64)
    case double(Double)

    func bind(at index: Int32, to statement: OpaquePointer) {
        switch self {
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, visualSQLiteTransient)
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        }
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [ArraySlice<Element>] {
        guard !isEmpty else { return [] }
        var chunks = [ArraySlice<Element>]()
        chunks.reserveCapacity((count + maximumCount - 1) / maximumCount)
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maximumCount, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }
}
