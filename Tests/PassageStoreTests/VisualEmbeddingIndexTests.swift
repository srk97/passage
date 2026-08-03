import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Encrypted visual embedding index")
struct VisualEmbeddingIndexTests {
    private static let modelA = VisualModelIdentity(
        identifier: "test.dual-encoder",
        revision: "2026-07-28",
        fingerprint: String(repeating: "1", count: 64),
        preprocessingRevision: "rgb-center-crop-v1",
        embeddingDimension: 512
    )
    private static let modelB = VisualModelIdentity(
        identifier: "test.dual-encoder",
        revision: "2026-07-29",
        fingerprint: String(repeating: "2", count: 64),
        preprocessingRevision: "rgb-center-crop-v1",
        embeddingDimension: 512
    )

    @Test("Identical vectors deduplicate and return one complete newest representative")
    func deduplicationRepresentativeAndCoverage() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let older = Self.frame(
            id: "older",
            time: 100,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "example.com",
            text: "A clean unhighlighted description of the first scene",
            fingerprint: 101
        )
        let newer = Self.frame(
            id: "newer",
            time: 200,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "example.com",
            text: "Harry Potter stands beside a window wearing round glasses",
            fingerprint: 202
        )
        try await store.insertBatch([newer, older])
        let sharedVector = Self.axisVector(0)

        let summary = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: older.id, model: Self.modelA, vector: sharedVector),
            VisualEmbeddingWrite(frameID: newer.id, model: Self.modelA, vector: sharedVector),
        ])
        #expect(summary.processedFrameCount == 2)
        #expect(summary.insertedAssociationCount == 2)
        #expect(summary.insertedUniqueVectorCount == 1)
        #expect(summary.reusedUniqueVectorCount == 1)
        #expect(summary.storedVectorBytesDelta == 576)

        let coverage = try await store.visualEmbeddingCoverage(for: Self.modelA)
        #expect(coverage.model == Self.modelA)
        #expect(coverage.eligibleFrameCount == 2)
        #expect(coverage.indexedEligibleFrameCount == 2)
        #expect(coverage.indexedFrameCount == 2)
        #expect(coverage.pendingEligibleFrameCount == 0)
        #expect(coverage.uniqueVectorCount == 1)
        #expect(coverage.deduplicatedFrameCount == 1)
        #expect(coverage.storedVectorPayloadBytes == 576)
        #expect(coverage.coverageFraction == 1)

        let matches = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: sharedVector,
            minimumSimilarity: 0.99,
            limit: 10,
            candidateLimit: 10
        ))
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        #expect(match.hit.id == newer.id)
        #expect(match.hit.activitySessionID != nil)
        #expect(match.hit.capturedAt == newer.capturedAt)
        #expect(match.hit.context == newer.context)
        #expect(match.hit.imageRelativePath == newer.imageRelativePath)
        #expect(match.hit.thumbnailRelativePath == newer.thumbnailRelativePath)
        #expect(match.hit.snippet == newer.ocrText)
        #expect(!match.hit.snippet.contains("‹"))
        #expect(!match.hit.snippet.contains("›"))
        #expect(match.hit.score == match.similarity)
        #expect(abs(match.similarity - 1) < 1e-12)
        #expect(match.maximumSimilarityError >= 0)
        #expect(match.model == Self.modelA)
        #expect(match.associatedFrameCount == 2)
        #expect(match.sourceVisualFingerprint == newer.visualFingerprint)

        let pending = try await store.framesNeedingVisualEmbedding(
            for: Self.modelA,
            limit: 100
        )
        #expect(pending.isEmpty)

        let encryptedHeader = try Data(contentsOf: fixture.paths.database).prefix(16)
        #expect(encryptedHeader != Data("SQLite format 3\0".utf8))

        let readOnly = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        #expect(try await readOnly.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: sharedVector,
            limit: 1,
            candidateLimit: 1
        )).first?.hit.id == newer.id)

        let inspection = try SQLCipherConnection(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        let blockStats = try Self.hashBlockStats(
            database: inspection.pointer,
            modelFingerprint: Self.modelA.fingerprint
        )
        let block = try #require(blockStats)
        #expect(block.blockCount == 1)
        #expect(block.occupiedSlotCount == 1)
        #expect(block.occupancyBytes == 256)
        #expect(block.angularHashBytes == 131_072)
        #expect(!Self.indexNames(database: inspection.pointer).contains(
            "visual_embedding_vectors_angular_scan"
        ))
    }

    @Test("Scope filters constrain candidates, representative choice, and association count")
    func scopedSearchAndSensitiveIsolation() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let frames = [
            Self.frame(id: "outside-time", time: 90, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", fingerprint: 1),
            Self.frame(id: "inside-old", time: 110, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", fingerprint: 2),
            Self.frame(id: "inside-new", time: 120, app: "Safari", bundle: "com.apple.Safari", domain: "WORK.EXAMPLE", fingerprint: 3),
            Self.frame(id: "wrong-app", time: 121, app: "Xcode", bundle: "com.apple.dt.Xcode", domain: "work.example", fingerprint: 4),
            Self.frame(id: "wrong-domain", time: 122, app: "Safari", bundle: "com.apple.Safari", domain: "other.example", fingerprint: 5),
            Self.frame(id: "outside-only-vector", time: 115, app: "Xcode", bundle: "com.apple.dt.Xcode", domain: "other.example", fingerprint: 6),
            Self.frame(id: "sensitive", time: 123, app: "Safari", bundle: "com.apple.Safari", domain: "work.example", isSensitive: true, fingerprint: 7),
        ]
        try await store.insertBatch(frames)

        let initialCandidates = try await store.framesNeedingVisualEmbedding(
            for: Self.modelA,
            limit: 3
        )
        #expect(initialCandidates.map(\.frameID.rawValue) == [
            "wrong-domain", "wrong-app", "inside-new",
        ])
        #expect(initialCandidates.allSatisfy { !$0.isSensitive })
        #expect(initialCandidates.first?.pixelWidth == 1280)
        #expect(initialCandidates.first?.thumbnailRelativePath != nil)

        let shared = Self.axisVector(0)
        let outsideOnly = Self.axisVector(1)
        let writes = frames.filter { !$0.context.isSensitive }.map { frame in
            VisualEmbeddingWrite(
                frameID: frame.id,
                model: Self.modelA,
                vector: frame.id.rawValue == "outside-only-vector" ? outsideOnly : shared
            )
        }
        _ = try await store.upsertVisualEmbeddings(writes)
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.upsertVisualEmbeddings([
                VisualEmbeddingWrite(
                    frameID: FrameID(rawValue: "sensitive"),
                    model: Self.modelA,
                    vector: shared
                ),
            ])
        }

        let scoped = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: shared,
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 121),
            applicationBundleIdentifiers: [" com.apple.Safari "],
            domains: [" WORK.EXAMPLE "],
            limit: 10,
            candidateLimit: 10
        ))
        #expect(scoped.count == 1)
        #expect(scoped.first?.hit.id.rawValue == "inside-new")
        #expect(scoped.first?.associatedFrameCount == 2)
        #expect(scoped.first?.hit.context.domain == "WORK.EXAMPLE")

        let noScopedAssociation = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: outsideOnly,
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 121),
            applicationBundleIdentifiers: ["com.apple.Safari"],
            domains: ["work.example"],
            minimumSimilarity: 0.9,
            limit: 10,
            candidateLimit: 10
        ))
        #expect(noScopedAssociation.isEmpty)
    }

    @Test("Excluded source frames cannot starve or become visual representatives")
    func sourceExclusionPrecedesShortlistAndRepresentation() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let source = Self.frame(
            id: "selected-source",
            time: 190,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "work.example",
            fingerprint: 901
        )
        let earlierDuplicate = Self.frame(
            id: "earlier-duplicate",
            time: 180,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "work.example",
            fingerprint: 902
        )
        let excludedOnly = Self.frame(
            id: "excluded-only",
            time: 170,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "work.example",
            fingerprint: 903
        )
        let outsideScopeDuplicate = Self.frame(
            id: "outside-scope-duplicate",
            time: 160,
            app: "Xcode",
            bundle: "com.apple.dt.Xcode",
            domain: "other.example",
            fingerprint: 904
        )
        try await store.insertBatch([
            source, earlierDuplicate, excludedOnly, outsideScopeDuplicate,
        ])
        let sharedVector = Self.axisVector(1)
        let sourceOnlyVector = Self.axisVector(0)
        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(
                frameID: source.id,
                model: Self.modelA,
                vector: sharedVector
            ),
            VisualEmbeddingWrite(
                frameID: earlierDuplicate.id,
                model: Self.modelA,
                vector: sharedVector
            ),
            VisualEmbeddingWrite(
                frameID: outsideScopeDuplicate.id,
                model: Self.modelA,
                vector: sharedVector
            ),
            VisualEmbeddingWrite(
                frameID: excludedOnly.id,
                model: Self.modelA,
                vector: sourceOnlyVector
            ),
        ])
        let scope = (
            start: Date(timeIntervalSince1970: 150),
            end: Date(timeIntervalSince1970: 200),
            apps: Set(["com.apple.Safari"]),
            domains: Set(["work.example"])
        )

        let sharedMatches = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: sharedVector,
            startDate: scope.start,
            endDate: scope.end,
            applicationBundleIdentifiers: scope.apps,
            domains: scope.domains,
            excludedFrameIDs: [source.id],
            minimumSimilarity: 0.99,
            limit: 1,
            candidateLimit: 1
        ))
        #expect(sharedMatches.map(\.hit.id) == [earlierDuplicate.id])
        #expect(sharedMatches.first?.associatedFrameCount == 1)
        #expect(sharedMatches.first?.sourceVisualFingerprint
            == earlierDuplicate.visualFingerprint)

        // The excluded-only vector is the exact nearest vector. It must be
        // removed before candidateLimit is applied so it cannot starve the
        // lower-scoring eligible scene.
        let exclusions: Set<FrameID> = [excludedOnly.id, source.id]
        for _ in 0..<3 {
            let surviving = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: sourceOnlyVector,
                startDate: scope.start,
                endDate: scope.end,
                applicationBundleIdentifiers: scope.apps,
                domains: scope.domains,
                excludedFrameIDs: exclusions,
                minimumSimilarity: -1,
                limit: 1,
                candidateLimit: 1
            ))
            #expect(surviving.map(\.hit.id) == [earlierDuplicate.id])
            #expect(surviving.first?.associatedFrameCount == 1)
        }
    }

    @Test("Stale visual associations are excluded before shortlist limits and representation")
    func staleAssociationsDoNotDiscloseOrStarveFreshEvidence() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let staleOnly = Self.frame(id: "stale-only", time: 400, fingerprint: 41)
        let sharedStale = Self.frame(id: "shared-stale", time: 300, fingerprint: 42)
        let sharedFresh = Self.frame(id: "shared-fresh", time: 200, fingerprint: 43)
        let sensitiveStale = Self.frame(id: "sensitive-stale", time: 100, fingerprint: 44)
        try await store.insertBatch([staleOnly, sharedStale, sharedFresh, sensitiveStale])

        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(
                frameID: staleOnly.id,
                model: Self.modelA,
                vector: Self.axisVector(0)
            ),
            VisualEmbeddingWrite(
                frameID: sharedStale.id,
                model: Self.modelA,
                vector: Self.axisVector(1)
            ),
            VisualEmbeddingWrite(
                frameID: sharedFresh.id,
                model: Self.modelA,
                vector: Self.axisVector(1)
            ),
            VisualEmbeddingWrite(
                frameID: sensitiveStale.id,
                model: Self.modelA,
                vector: Self.axisVector(2)
            ),
        ])

        // Simulate media replacement after indexing. The sensitive mutation
        // also proves stale coverage is scoped to ordinary frames.
        let mutationLease = try #require(store.connection.lease())
        let mutationStatus = sqlite3_exec(
            mutationLease.pointer,
            """
            UPDATE frames
            SET visual_fingerprint = visual_fingerprint + 1000
            WHERE id IN ('stale-only', 'shared-stale', 'sensitive-stale');
            UPDATE frames SET is_sensitive = 1 WHERE id = 'sensitive-stale';
            """,
            nil,
            nil,
            nil
        )
        let mutationMessage = String(cString: sqlite3_errmsg(mutationLease.pointer))
        mutationLease.release()
        #expect(mutationStatus == SQLITE_OK, "Raw fixture mutation failed: \(mutationMessage)")

        let coverage = try await store.visualEmbeddingCoverage(for: Self.modelA)
        #expect(coverage.eligibleFrameCount == 3)
        #expect(coverage.indexedEligibleFrameCount == 1)
        #expect(coverage.indexedFrameCount == 3)
        #expect(coverage.pendingEligibleFrameCount == 2)
        #expect(coverage.staleEmbeddingCount == 2)

        // The closest vector is stale. A scoped candidate limit of one must
        // still reach the fresh shared vector instead of returning nothing.
        let scoped = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            startDate: Date(timeIntervalSince1970: 0),
            minimumSimilarity: -1,
            limit: 1,
            candidateLimit: 1
        ))
        #expect(scoped.map(\.hit.id.rawValue) == ["shared-fresh"])
        #expect(scoped.first?.associatedFrameCount == 1)

        // The unscoped cache can still nominate stale vector payloads, so the
        // representative query is the final freshness boundary.
        let unscoped = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            minimumSimilarity: -1,
            limit: 3,
            candidateLimit: 3
        ))
        #expect(unscoped.map(\.hit.id.rawValue) == ["shared-fresh"])
        #expect(unscoped.first?.associatedFrameCount == 1)
    }

    @Test("Scoped shortlist plan starts at an indexed frame range")
    func scopedShortlistQueryPlan() throws {
        let fixture = try VisualStoreFixture()
        _ = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let query = VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            applicationBundleIdentifiers: ["com.apple.Safari"],
            domains: ["work.example"],
            limit: 20,
            candidateLimit: 2_048
        )
        let sql = VisualEmbeddingShortlistSQL.scopedVectorIDsStatement(for: query)
        let connection = try SQLCipherConnection(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        let details = try Self.explain(sql, database: connection.pointer)
            .joined(separator: "\n")
            .lowercased()

        #expect(sql.contains("FROM frames AS frame INDEXED BY frames_application"))
        #expect(sql.contains(
            "association.source_visual_fingerprint = frame.visual_fingerprint"
        ))
        #expect(details.contains("search frame using index frames_application"))
        #expect(details.contains(
            "search association using index visual_frame_embeddings_rowid"
        ))
        #expect(details.contains("frame_rowid=?") && details.contains("model_fingerprint=?"))
        #expect(!sql.contains("visual_embedding_vectors"))
        #expect(!details.contains("correlated scalar subquery"))

        let domainSQL = VisualEmbeddingShortlistSQL.scopedVectorIDsStatement(for: VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            domains: ["work.example"]
        ))
        #expect(domainSQL.contains("INDEXED BY frames_domain"))
        let timeSQL = VisualEmbeddingShortlistSQL.scopedVectorIDsStatement(for: VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            startDate: Date(timeIntervalSince1970: 100)
        ))
        #expect(timeSQL.contains("INDEXED BY frames_captured_at"))
        let exclusionSQL = VisualEmbeddingShortlistSQL.scopedVectorIDsStatement(
            for: VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0),
                excludedFrameIDs: [FrameID(rawValue: "selected-source")]
            )
        )
        #expect(exclusionSQL.contains(
            "FROM visual_frame_embeddings AS association"
        ))
        #expect(exclusionSQL.contains(
            "INDEXED BY visual_frame_embeddings_model"
        ))
        #expect(exclusionSQL.contains("association.frame_rowid = frame.rowid"))
        #expect(exclusionSQL.contains("frame.id NOT IN"))
        let exclusionPlan = try Self.explain(
            exclusionSQL,
            database: connection.pointer
        )
            .joined(separator: "\n")
            .lowercased()
        #expect(exclusionPlan.contains(
            "search association using index visual_frame_embeddings_model"
        ))
        #expect(exclusionPlan.contains("search frame using integer primary key"))
        let fallbackScopedSQL = VisualEmbeddingShortlistSQL.statement(for: query)
        #expect(fallbackScopedSQL.contains(
            "association.source_visual_fingerprint = frame.visual_fingerprint"
        ))
        let fallbackUnscopedSQL = VisualEmbeddingShortlistSQL.statement(for: VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0)
        ))
        #expect(fallbackUnscopedSQL.contains(
            "association.source_visual_fingerprint = frame.visual_fingerprint"
        ))
        let unscopedPlan = try Self.explain(
            VisualEmbeddingHashBlocks.loadStatement,
            database: connection.pointer
        )
            .joined(separator: "\n")
            .lowercased()
        #expect(unscopedPlan.contains("visual_embedding_hash_blocks"))
        #expect(unscopedPlan.contains("model_fingerprint=?"))

        let exactScoreSQL = VisualEmbeddingExactScoreSQL.statement(candidateCount: 3)
        let exactScorePlan = try Self.explain(
            exactScoreSQL,
            database: connection.pointer
        )
            .joined(separator: "\n")
            .lowercased()
        #expect(exactScoreSQL.contains("NOT INDEXED"))
        #expect(exactScorePlan.contains("integer primary key (rowid=?)"))
    }

    @Test("Scoped representative lookup stays candidate-first")
    func scopedRepresentativeQueryPlan() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let frame = Self.frame(
            id: "representative-plan",
            time: 150,
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "work.example",
            fingerprint: 404
        )
        try await store.insert(frame)
        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(
                frameID: frame.id,
                model: Self.modelA,
                vector: Self.axisVector(0)
            ),
        ])

        let traceLease = try #require(store.connection.lease())
        defer { traceLease.release() }
        let capture = SQLiteStatementCapture(sqlFragment: "WITH scoped AS")
        let traceContext = Unmanaged.passUnretained(capture).toOpaque()
        let traceStatus = sqlite3_trace_v2(
            traceLease.pointer,
            UInt32(SQLITE_TRACE_STMT),
            { _, context, _, sql in
                guard let context, let sql else { return 0 }
                let capture = Unmanaged<SQLiteStatementCapture>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                capture.record(String(cString: sql.assumingMemoryBound(to: CChar.self)))
                return 0
            },
            traceContext
        )
        #expect(traceStatus == SQLITE_OK)
        defer { sqlite3_trace_v2(traceLease.pointer, 0, nil, nil) }

        let matches = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            applicationBundleIdentifiers: ["com.apple.Safari"],
            domains: ["work.example"],
            limit: 1,
            candidateLimit: 1
        ))
        #expect(matches.map(\.hit.id) == [frame.id])

        let sql = try #require(capture.value())
        #expect(sql.contains("INDEXED BY visual_frame_embeddings_model"))
        #expect(sql.contains("CROSS JOIN frames AS frame"))
        #expect(sql.contains("association.source_visual_fingerprint = frame.visual_fingerprint"))
        #expect(sql.contains("frame.is_sensitive = 0"))
        #expect(sql.contains("frame.captured_at >="))
        #expect(sql.contains("frame.captured_at <"))
        #expect(sql.contains("frame.bundle_identifier IN"))
        #expect(sql.contains("frame.domain COLLATE NOCASE IN"))

        let details = try Self.explain(sql, database: traceLease.pointer)
            .map { $0.lowercased() }
        let associationStep = try #require(details.firstIndex {
            $0.contains("search association using index visual_frame_embeddings_model")
        })
        let frameStep = try #require(details.firstIndex {
            $0.contains("search frame using integer primary key")
        })
        #expect(associationStep < frameStep)
        #expect(!details.contains { $0.contains("search frame using index frames_domain") })
        #expect(!details.contains { $0.contains("search frame using index frames_application") })
    }

    @Test("Reindexing reclaims orphan payloads and model deletion is isolated")
    func reindexAndDeleteModelNamespace() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let frame = Self.frame(id: "scene", time: 100, fingerprint: 44)
        try await store.insert(frame)
        let firstVector = Self.axisVector(0)
        let secondVector = Self.axisVector(1)

        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: frame.id, model: Self.modelA, vector: firstVector),
        ])
        let unchanged = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: frame.id, model: Self.modelA, vector: firstVector),
        ])
        #expect(unchanged.unchangedAssociationCount == 1)
        #expect(unchanged.reusedUniqueVectorCount == 1)
        #expect(unchanged.storedVectorBytesDelta == 0)

        let replacement = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: frame.id, model: Self.modelA, vector: secondVector),
        ])
        #expect(replacement.replacedAssociationCount == 1)
        #expect(replacement.insertedUniqueVectorCount == 1)
        #expect(replacement.reclaimedUniqueVectorCount == 1)
        #expect(replacement.storedVectorBytesDelta == 0)
        #expect(try await store.visualEmbeddingCoverage(for: Self.modelA).uniqueVectorCount == 1)
        #expect(try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: firstVector,
            minimumSimilarity: 0.9,
            limit: 1,
            candidateLimit: 1
        )).isEmpty)
        #expect(try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: secondVector,
            minimumSimilarity: 0.9,
            limit: 1,
            candidateLimit: 1
        )).first?.hit.id == frame.id)

        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: frame.id, model: Self.modelB, vector: firstVector),
        ])
        var collision = Self.modelA
        collision.revision = "different-metadata-same-fingerprint"
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.visualEmbeddingCoverage(for: collision)
        }

        #expect(try await store.deleteVisualEmbeddings(
            modelFingerprint: Self.modelA.fingerprint
        ) == 1)
        #expect(try await store.visualEmbeddingCoverage(for: Self.modelA).indexedFrameCount == 0)
        #expect(try await store.visualEmbeddingCoverage(for: Self.modelB).indexedFrameCount == 1)
        #expect(try await store.deleteVisualEmbeddings(
            modelFingerprint: Self.modelA.fingerprint
        ) == 0)
    }

    @Test("All retention paths cascade associations, vectors, and expired visual evidence")
    func deletionAndMediaExpiry() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let frames = [
            Self.frame(id: "first", time: 100, fingerprint: 1),
            Self.frame(id: "second", time: 200, fingerprint: 2),
            Self.frame(id: "third", time: 300, fingerprint: 3),
        ]
        try await store.insertBatch(frames)
        _ = try await store.upsertVisualEmbeddings(zip(frames, 0...).map { frame, index in
            VisualEmbeddingWrite(
                frameID: frame.id,
                model: Self.modelA,
                vector: Self.axisVector(index)
            )
        })

        _ = try await store.deleteFrames(olderThan: Date(timeIntervalSince1970: 150))
        var coverage = try await store.visualEmbeddingCoverage(for: Self.modelA)
        #expect(coverage.indexedFrameCount == 2)
        #expect(coverage.uniqueVectorCount == 2)

        _ = try await store.deleteFrames(
            from: Date(timeIntervalSince1970: 190),
            through: Date(timeIntervalSince1970: 210)
        )
        coverage = try await store.visualEmbeddingCoverage(for: Self.modelA)
        #expect(coverage.indexedFrameCount == 1)
        #expect(coverage.uniqueVectorCount == 1)

        _ = try await store.deleteOldestFrames(limit: 1)
        coverage = try await store.visualEmbeddingCoverage(for: Self.modelA)
        #expect(coverage.indexedFrameCount == 0)
        #expect(coverage.uniqueVectorCount == 0)
        #expect(coverage.storedVectorPayloadBytes == 0)

        let oldMedia = Self.frame(id: "old-media", time: 400, fingerprint: 4)
        let newMedia = Self.frame(id: "new-media", time: 500, fingerprint: 5)
        try await store.insertBatch([oldMedia, newMedia])
        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: oldMedia.id, model: Self.modelA, vector: Self.axisVector(4)),
            VisualEmbeddingWrite(frameID: newMedia.id, model: Self.modelA, vector: Self.axisVector(5)),
        ])
        _ = try await store.expireOldestMedia(limit: 1)
        coverage = try await store.visualEmbeddingCoverage(for: Self.modelA)
        #expect(try await store.frame(id: oldMedia.id) != nil)
        #expect(try await store.frame(id: oldMedia.id)?.imageRelativePath == "")
        #expect(coverage.eligibleFrameCount == 1)
        #expect(coverage.indexedFrameCount == 1)
        #expect(coverage.uniqueVectorCount == 1)
        #expect(try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(4),
            minimumSimilarity: 0.9,
            limit: 2,
            candidateLimit: 2
        )).isEmpty)
    }

    @Test("Invalid writes and queries are atomic, bounded, and cancellation aware")
    func validationAtomicityAndCancellation() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let valid = Self.frame(id: "valid", time: 100, fingerprint: 8)
        let sensitive = Self.frame(
            id: "private",
            time: 101,
            isSensitive: true,
            fingerprint: 9
        )
        try await store.insertBatch([valid, sensitive])

        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.upsertVisualEmbeddings([
                VisualEmbeddingWrite(frameID: valid.id, model: Self.modelA, vector: Self.axisVector(0)),
                VisualEmbeddingWrite(
                    frameID: FrameID(rawValue: "missing"),
                    model: Self.modelA,
                    vector: Self.axisVector(1)
                ),
            ])
        }
        #expect(try await store.visualEmbeddingCoverage(for: Self.modelA).indexedFrameCount == 0)

        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.upsertVisualEmbeddings([
                VisualEmbeddingWrite(frameID: valid.id, model: Self.modelA, vector: Self.axisVector(0)),
                VisualEmbeddingWrite(frameID: sensitive.id, model: Self.modelA, vector: Self.axisVector(1)),
            ])
        }
        #expect(try await store.visualEmbeddingCoverage(for: Self.modelA).indexedFrameCount == 0)

        let unknownFingerprint = String(repeating: "f", count: 64)
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: unknownFingerprint,
                vector: [Float](repeating: 1, count: 511)
            ))
        }
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0),
                startDate: Date(timeIntervalSince1970: 200),
                endDate: Date(timeIntervalSince1970: 100)
            ))
        }
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0),
                startDate: Date(timeIntervalSince1970: .nan)
            ))
        }
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0),
                limit: 5,
                candidateLimit: 4
            ))
        }
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0),
                excludedFrameIDs: [FrameID(rawValue: "")]
            ))
        }
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0),
                excludedFrameIDs: Set((0...64).map {
                    FrameID(rawValue: "excluded-\($0)")
                })
            ))
        }
        await #expect(throws: VisualEmbeddingStoreError.self) {
            _ = try await store.framesNeedingVisualEmbedding(for: Self.modelA, limit: 1_001)
        }

        let cancelled = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await store.nearestVisualEmbeddings(VisualEmbeddingQuery(
                modelFingerprint: Self.modelA.fingerprint,
                vector: Self.axisVector(0)
            ))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
    }

    @Test("Exact-score ties have a stable order")
    func stableTieOrder() async throws {
        let fixture = try VisualStoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let first = Self.frame(id: "tie-a", time: 100, fingerprint: 10)
        let second = Self.frame(id: "tie-b", time: 101, fingerprint: 11)
        try await store.insertBatch([first, second])
        _ = try await store.upsertVisualEmbeddings([
            VisualEmbeddingWrite(frameID: first.id, model: Self.modelA, vector: Self.axisVector(1)),
            VisualEmbeddingWrite(frameID: second.id, model: Self.modelA, vector: Self.axisVector(2)),
        ])
        let query = VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(0),
            minimumSimilarity: -1,
            limit: 2,
            candidateLimit: 2
        )

        let expected = ["tie-a", "tie-b"]
        for _ in 0..<5 {
            #expect(try await store.nearestVisualEmbeddings(query).map(\.hit.id.rawValue)
                == expected)
        }
    }

    @Test("Prewarm validates generation, blocks, and vector count in one snapshot")
    func prewarmUsesGenerationConsistentSnapshot() async throws {
        let fixture = try VisualStoreFixture()
        let writer = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let first = Self.frame(id: "snapshot-first", time: 100, fingerprint: 301)
        let second = Self.frame(id: "snapshot-second", time: 200, fingerprint: 302)
        try await writer.insertBatch([first, second])
        _ = try await writer.upsertVisualEmbeddings([
            VisualEmbeddingWrite(
                frameID: first.id,
                model: Self.modelA,
                vector: Self.axisVector(0)
            ),
        ])

        let reader = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        let traceLease = try #require(reader.connection.lease())
        defer { traceLease.release() }
        let traceGate = SQLiteTraceGate(sqlFragment: "SELECT COUNT(*) FROM visual_embedding_vectors")
        let traceContext = Unmanaged.passUnretained(traceGate).toOpaque()
        sqlite3_trace_v2(traceLease.pointer, UInt32(SQLITE_TRACE_STMT), { _, context, _, sql in
            guard let context, let sql else { return 0 }
            let gate = Unmanaged<SQLiteTraceGate>
                .fromOpaque(context)
                .takeUnretainedValue()
            gate.pauseIfMatched(String(cString: sql.assumingMemoryBound(to: CChar.self)))
            return 0
        }, traceContext)
        defer { sqlite3_trace_v2(traceLease.pointer, 0, nil, nil) }

        let prewarm = Task {
            try await reader.prewarmVisualEmbeddingIndex(
                modelFingerprint: Self.modelA.fingerprint
            )
        }
        await traceGate.waitUntilPaused()

        _ = try await writer.upsertVisualEmbeddings([
            VisualEmbeddingWrite(
                frameID: second.id,
                model: Self.modelA,
                vector: Self.axisVector(1)
            ),
        ])
        traceGate.resume()
        try await prewarm.value

        let matches = try await reader.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: Self.modelA.fingerprint,
            vector: Self.axisVector(1),
            minimumSimilarity: 0.9,
            limit: 2,
            candidateLimit: 2
        ))
        #expect(matches.first?.hit.id == second.id)
    }

    private static func frame(
        id: String,
        time: TimeInterval,
        app: String = "Preview",
        bundle: String? = "com.apple.Preview",
        domain: String? = nil,
        text: String = "visual evidence",
        isSensitive: Bool = false,
        fingerprint: UInt64
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: "\(app) — \(id)",
                url: domain.flatMap { URL(string: "https://\($0)/page") },
                domain: domain,
                displayID: 7,
                windowID: 42,
                windowBounds: ScreenRect(x: 12, y: 24, width: 900, height: 640),
                isSensitive: isSensitive
            ),
            ocrText: text,
            ocrRegions: [
                OCRRegion(text: text, confidence: 0.98, x: 0, y: 0, width: 1, height: 1),
            ],
            imageRelativePath: "Media/\(id).jpg.enc",
            thumbnailRelativePath: "Thumbnails/\(id).jpg.enc",
            pixelWidth: 1280,
            pixelHeight: 720,
            visualFingerprint: fingerprint,
            changeScore: 0.5
        )
    }

    private static func axisVector(_ index: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 512)
        result[index] = 1
        return result
    }

    private static func explain(_ sql: String, database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "EXPLAIN QUERY PLAN \(sql)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var details = [String]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let value = sqlite3_column_text(statement, 3) {
                    details.append(String(cString: value))
                }
            case SQLITE_DONE:
                return details
            default:
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private struct HashBlockStats {
        var blockCount: Int
        var occupiedSlotCount: Int
        var occupancyBytes: Int
        var angularHashBytes: Int
    }

    private static func hashBlockStats(
        database: OpaquePointer,
        modelFingerprint: String
    ) throws -> HashBlockStats? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT occupancy, angular_hashes FROM visual_embedding_hash_blocks WHERE model_fingerprint = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = modelFingerprint.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, transient)
        }
        var blockCount = 0
        var occupiedSlotCount = 0
        var occupancyBytes = 0
        var angularHashBytes = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  let occupancyPointer = sqlite3_column_blob(statement, 0) else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            blockCount += 1
            occupancyBytes += Int(sqlite3_column_bytes(statement, 0))
            angularHashBytes += Int(sqlite3_column_bytes(statement, 1))
            let occupancy = UnsafeRawBufferPointer(
                start: occupancyPointer,
                count: Int(sqlite3_column_bytes(statement, 0))
            )
            occupiedSlotCount += occupancy.reduce(0) { $0 + $1.nonzeroBitCount }
        }
        guard blockCount > 0 else { return nil }
        return HashBlockStats(
            blockCount: blockCount,
            occupiedSlotCount: occupiedSlotCount,
            occupancyBytes: occupancyBytes,
            angularHashBytes: angularHashBytes
        )
    }

    private static func indexNames(database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'index'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                result.insert(String(cString: text))
            }
        }
        return result
    }
}

private final class SQLiteTraceGate: @unchecked Sendable {
    private let sqlFragment: String
    private let lock = NSLock()
    private let proceed = DispatchSemaphore(value: 0)
    private var hasPaused = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(sqlFragment: String) {
        self.sqlFragment = sqlFragment
    }

    func pauseIfMatched(_ sql: String) {
        guard sql.contains(sqlFragment) else { return }
        lock.lock()
        guard !hasPaused else {
            lock.unlock()
            return
        }
        hasPaused = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
        proceed.wait()
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasPaused {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func resume() {
        proceed.signal()
    }
}

private final class SQLiteStatementCapture: @unchecked Sendable {
    private let sqlFragment: String
    private let lock = NSLock()
    private var capturedSQL: String?

    init(sqlFragment: String) {
        self.sqlFragment = sqlFragment
    }

    func record(_ sql: String) {
        guard sql.contains(sqlFragment) else { return }
        lock.lock()
        if capturedSQL == nil {
            capturedSQL = sql
        }
        lock.unlock()
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return capturedSQL
    }
}

private final class VisualStoreFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-visual-index-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(
            bytes: Data(repeating: 0x71, count: VaultKey.byteCount)
        )
        try paths.createDirectories()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
