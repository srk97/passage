import PassageCore
import CryptoKit
import Foundation
@preconcurrency import SQLCipher

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteFrameStore:
    FrameRepository,
    AgentSafeFrameRepository,
    OCRRefinementRepository,
    ActivitySessionRepository,
    RecallNavigationRepository,
    RankedRecallRepository,
    MemorySegmentRetrieving,
    VisualEmbeddingRepository {
    /// A session is a continuous work bout. Application changes do not split it;
    /// five minutes without a persisted frame does.
    public nonisolated static let activitySessionGap: TimeInterval = 5 * 60
    public nonisolated static let maximumAgentSafeFrameRequestCount = 256

    private let paths: PassagePaths
    nonisolated let connection: SQLCipherConnection
    private let hasAlignedSearchRowIDs: Bool
    private let hasAccessibilityEvidenceSchema: Bool
    private let hasMaterializedRecallFacetTotals: Bool
    private var storedFrameCount: Int64
    /// Walking tens of thousands of encrypted media blobs dominates statistics
    /// cost, so byte totals are remeasured at most once per lifetime window.
    /// Every store operation that can release media invalidates this cache,
    /// which keeps the retention sweep's measure-after-delete loop exact.
    private var cachedMediaBytes: (value: Int64, measuredAt: ContinuousClock.Instant)?
    private static let mediaBytesCacheLifetime: Duration = .seconds(300)
    var visualAngularShortlistCache = VisualAngularShortlistCache()
    /// Per model fingerprint: every frame ordered strictly before this cursor
    /// had a fresh visual embedding the last time pending frames were fully
    /// enumerated. Frames are immutable in captured order and their visual
    /// fingerprints never change after insert, so the pending scan can start
    /// here instead of walking the whole frames table; only an out-of-order
    /// insert can introduce pending work below it (handled in insertBatch).
    var visualPendingScanFloors: [String: VisualPendingScanFloor] = [:]
    public nonisolated let encryptionStatus: SQLCipherRuntimeStatus
    private static let browserDomainBackfillMarkerKey = "browser_domain_backfill_version"
    private static let browserDomainBackfillCursorKey = "browser_domain_backfill_cursor_v2"
    private static let browserDomainBackfillVersion = "2"
    private static let recallFacetTotalsMarkerKey = "recall_facet_totals_version"
    private static let recallFacetTotalsVersion = "1"

    public init(paths: PassagePaths, vaultKey: VaultKey, readOnly: Bool = false) throws {
        self.paths = paths
        let connection = try SQLCipherConnection(paths: paths, vaultKey: vaultKey, readOnly: readOnly)
        self.connection = connection
        encryptionStatus = connection.runtimeStatus
        let database = connection.pointer
        if !readOnly {
            try Self.migrate(database)
            try connection.hardenFilePermissions()
        }
        try Self.execute("PRAGMA foreign_keys = ON", on: database)
        let schemaVersion = try? Self.metadataValue(
            key: "schema_version",
            database: database
        ).flatMap(Int.init)
        hasAlignedSearchRowIDs = (schemaVersion ?? 0) >= 6
        hasAccessibilityEvidenceSchema = (schemaVersion ?? 0)
            >= AccessibilitySnapshotSchema.currentVersion
        let facetTotalsVersion = try? Self.metadataValue(
            key: Self.recallFacetTotalsMarkerKey,
            database: database
        )
        let facetTotalsTableCount = try? Self.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table'
              AND name IN ('recall_application_facets', 'recall_domain_facets')
            """,
            database: database
        )
        hasMaterializedRecallFacetTotals = facetTotalsVersion == Self.recallFacetTotalsVersion
            && facetTotalsTableCount == 2
        storedFrameCount = try Self.scalarInt(
            "SELECT COUNT(*) FROM frames",
            database: database
        )
    }

    /// Revokes this store's SQLCipher capability synchronously at the macOS
    /// session boundary. In-flight statements are interrupted and later actor
    /// calls fail through the existing closed-store guards.
    public nonisolated func revoke() {
        connection.revoke()
    }

    public func insert(_ frame: FrameDocument) throws {
        try Task.checkCancellation()
        try insertBatch([frame])
    }

    public func insertBatch(_ frames: [FrameDocument]) throws {
        try Task.checkCancellation()
        guard !frames.isEmpty else { return }
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let orderedFrames = frames.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id.rawValue < $1.id.rawValue }
            return $0.capturedAt < $1.capturedAt
        }
        let orderedFrameRecords = try orderedFrames.map { frame in
            let evidence = frame.context.isSensitive
                ? nil
                : try AccessibilitySnapshotCodec.stored(frame.accessibilitySnapshot)
            return (frame: frame, evidence: evidence)
        }
        let newestFrame = try newestFrameCursor()
        let appendOnly = newestFrame.map { newest in
            guard let first = orderedFrames.first else { return true }
            return first.capturedAt > newest.capturedAt
                || (first.capturedAt == newest.capturedAt && first.id.rawValue > newest.id)
        } ?? true
        var sessionCursor = appendOnly ? try latestActivitySessionCursor() : nil

        try Task.checkCancellation()
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            let firstFrameKey = try Self.reserveFrameKeys(
                count: orderedFrameRecords.count,
                on: database
            )
            let frameSQL = """
                INSERT INTO frames (
                    id, captured_at, application_name, bundle_identifier, window_title,
                    url, domain, display_id, window_id, window_x, window_y,
                    window_width, window_height, ocr_text, ocr_regions, image_path,
                    thumbnail_path, pixel_width, pixel_height, visual_fingerprint, change_score,
                    is_sensitive, activity_session_id, accessibility_snapshot_hash, frame_key
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            let ftsSQL = """
                INSERT INTO frame_search (
                    rowid, frame_id, ocr_text, window_title, application_name, url,
                    accessibility_text
                ) VALUES ((SELECT rowid FROM frames WHERE id = ?), ?, ?, ?, ?, ?, ?)
                """
            let snapshotSQL = """
                INSERT OR IGNORE INTO accessibility_snapshots (
                    content_hash, payload, accessibility_text
                ) VALUES (?, ?, ?)
                """
            let sessionInsertSQL = """
                INSERT INTO activity_sessions (
                    id, started_at, ended_at, frame_count, title,
                    latest_application_name, latest_bundle_identifier, latest_domain,
                    latest_url, latest_frame_id, representative_frame_id,
                    representative_score, representative_has_media, contains_sensitive
                ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            let sessionUpdateSQL = """
                UPDATE activity_sessions
                SET ended_at = ?, frame_count = frame_count + 1, title = ?,
                    latest_application_name = ?, latest_bundle_identifier = ?, latest_domain = ?,
                    latest_url = COALESCE(?, latest_url), latest_frame_id = ?,
                    representative_frame_id = ?, representative_score = ?,
                    representative_has_media = ?,
                    contains_sensitive = MAX(contains_sensitive, ?)
                WHERE id = ?
                """
            try withStatement(snapshotSQL) { snapshotStatement in
                try withStatement(frameSQL) { frameStatement in
                    try withStatement(ftsSQL) { ftsStatement in
                    try withStatement(sessionInsertSQL) { sessionInsertStatement in
                        try withStatement(sessionUpdateSQL) { sessionUpdateStatement in
                            for (recordOffset, record) in orderedFrameRecords.enumerated() {
                                let frame = record.frame
                                let evidence = record.evidence
                                let sessionID: ActivitySessionID?
                                if appendOnly {
                                    if let cursor = sessionCursor,
                                       frame.capturedAt.timeIntervalSince(cursor.endedAt) < Self.activitySessionGap {
                                        sessionID = cursor.id
                                    } else {
                                        sessionID = ActivitySessionID(rawValue: frame.id.rawValue)
                                    }
                                } else {
                                    sessionID = nil
                                }

                                if let evidence {
                                    Self.bind(evidence.contentHash, at: 1, to: snapshotStatement)
                                    Self.bind(evidence.payload, at: 2, to: snapshotStatement)
                                    Self.bind(evidence.searchableText, at: 3, to: snapshotStatement)
                                    try stepDone(snapshotStatement)
                                    sqlite3_reset(snapshotStatement)
                                    sqlite3_clear_bindings(snapshotStatement)
                                }

                                let regions = try OCRRegionCodec.encode(
                                    frame.ocrRegions,
                                    canonicalText: frame.ocrText
                                )
                                Self.bind(frame.id.rawValue, at: 1, to: frameStatement)
                                sqlite3_bind_double(frameStatement, 2, frame.capturedAt.timeIntervalSince1970)
                                Self.bind(frame.context.applicationName, at: 3, to: frameStatement)
                                Self.bind(frame.context.bundleIdentifier, at: 4, to: frameStatement)
                                Self.bind(frame.context.windowTitle, at: 5, to: frameStatement)
                                Self.bind(frame.context.url?.absoluteString, at: 6, to: frameStatement)
                                Self.bind(frame.context.domain, at: 7, to: frameStatement)
                                Self.bind(frame.context.displayID, at: 8, to: frameStatement)
                                Self.bind(frame.context.windowID, at: 9, to: frameStatement)
                                Self.bind(frame.context.windowBounds?.x, at: 10, to: frameStatement)
                                Self.bind(frame.context.windowBounds?.y, at: 11, to: frameStatement)
                                Self.bind(frame.context.windowBounds?.width, at: 12, to: frameStatement)
                                Self.bind(frame.context.windowBounds?.height, at: 13, to: frameStatement)
                                Self.bind(frame.ocrText, at: 14, to: frameStatement)
                                _ = regions.withUnsafeBytes { bytes in
                                    sqlite3_bind_blob(frameStatement, 15, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                                }
                                Self.bind(frame.imageRelativePath, at: 16, to: frameStatement)
                                Self.bind(frame.thumbnailRelativePath, at: 17, to: frameStatement)
                                sqlite3_bind_int64(frameStatement, 18, Int64(frame.pixelWidth))
                                sqlite3_bind_int64(frameStatement, 19, Int64(frame.pixelHeight))
                                sqlite3_bind_int64(frameStatement, 20, Int64(bitPattern: frame.visualFingerprint))
                                sqlite3_bind_double(frameStatement, 21, frame.changeScore)
                                sqlite3_bind_int(frameStatement, 22, frame.context.isSensitive ? 1 : 0)
                                Self.bind(sessionID?.rawValue, at: 23, to: frameStatement)
                                Self.bind(evidence?.contentHash, at: 24, to: frameStatement)
                                sqlite3_bind_int64(
                                    frameStatement,
                                    25,
                                    firstFrameKey + Int64(recordOffset)
                                )
                                try stepDone(frameStatement)
                                sqlite3_reset(frameStatement)
                                sqlite3_clear_bindings(frameStatement)

                                Self.bind(frame.id.rawValue, at: 1, to: ftsStatement)
                                Self.bind(frame.id.rawValue, at: 2, to: ftsStatement)
                                Self.bind(frame.ocrText, at: 3, to: ftsStatement)
                                Self.bind(frame.context.windowTitle, at: 4, to: ftsStatement)
                                Self.bind(frame.context.applicationName, at: 5, to: ftsStatement)
                                Self.bind(frame.context.url?.absoluteString, at: 6, to: ftsStatement)
                                Self.bind(evidence?.searchableText ?? "", at: 7, to: ftsStatement)
                                try stepDone(ftsStatement)
                                sqlite3_reset(ftsStatement)
                                sqlite3_clear_bindings(ftsStatement)

                                if let sessionID {
                                    sessionCursor = try Self.updateActivitySessionFastPath(
                                        sessionID: sessionID,
                                        frame: frame,
                                        previous: sessionCursor?.id == sessionID ? sessionCursor : nil,
                                        insertStatement: sessionInsertStatement,
                                        updateStatement: sessionUpdateStatement,
                                        connectionLease: connectionLease
                                    )
                                }
                            }
                        }
                    }
                }
            }
            }
            if !appendOnly {
                try Self.rebuildAllActivitySessions(on: database)
            }
            try Task.checkCancellation()
            try Self.execute("COMMIT", on: database)
            storedFrameCount += Int64(frames.count)
            if let oldestInserted = orderedFrames.first {
                lowerVisualPendingScanFloors(
                    toInclude: VisualPendingScanFloor(
                        capturedAt: oldestInserted.capturedAt.timeIntervalSince1970,
                        id: oldestInserted.id.rawValue
                    )
                )
            }
            try connection.hardenFilePermissions()
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func search(_ query: SearchQuery) throws -> [SearchHit] {
        try search(query, includeSensitive: true)
    }

    /// Executes the legacy bounded search with an optional privacy predicate.
    ///
    /// Agent-facing callers must pass `false` so sensitive rows are removed by
    /// SQLite before relevance ordering and `LIMIT` are applied. The protocol
    /// requirement above preserves the private app's existing inclusive reads.
    public func search(
        _ query: SearchQuery,
        includeSensitive: Bool
    ) throws -> [SearchHit] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try recentMatching(query, includeSensitive: includeSensitive)
        }

        let hasMetadataFilters = query.startDate != nil
            || query.endDate != nil
            || !query.applicationBundleIdentifiers.isEmpty
            || !query.domains.isEmpty
            || !query.activitySessionIDs.isEmpty
        if !hasMetadataFilters {
            // Materialize the small FTS winner set before touching the wider,
            // encrypted frame rows. Without this boundary SQLite may join and
            // decrypt every matching frame before applying LIMIT.
            let privacyJoinPredicate = hasAlignedSearchRowIDs
                ? "privacy_frame.rowid = frame_search.rowid"
                : "privacy_frame.id = frame_search.frame_id"
            let privacyPredicate = includeSensitive ? "" : """
                AND EXISTS (
                    SELECT 1
                    FROM frames privacy_frame
                    WHERE \(privacyJoinPredicate)
                      AND \(Self.agentSafePrivacyPredicate(frameAlias: "privacy_frame"))
                )
                """
            let matchedRowID = hasAlignedSearchRowIDs
                ? "frame_search.rowid AS matched_rowid,"
                : ""
            let winnerJoin = hasAlignedSearchRowIDs
                ? "f.rowid = matched.matched_rowid"
                : "f.id = matched.frame_id"
            let sql = """
                WITH matched AS MATERIALIZED (
                    SELECT \(matchedRowID) frame_id,
                           snippet(frame_search, -1, '‹', '›', ' … ', 18) AS excerpt,
                           frame_search.rank AS relevance
                    FROM frame_search
                    WHERE frame_search MATCH ?
                    \(privacyPredicate)
                    ORDER BY frame_search.rank ASC, frame_search.frame_id DESC
                    LIMIT ?
                )
                SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                       f.window_title, f.url, f.domain, f.display_id, f.window_id,
                       f.window_x, f.window_y, f.window_width, f.window_height,
                       f.image_path, f.thumbnail_path, matched.excerpt, matched.relevance,
                       f.is_sensitive, f.activity_session_id
                FROM matched
                JOIN frames f ON \(winnerJoin)
                ORDER BY matched.relevance ASC, matched.frame_id DESC
                """
            return try readHits(
                sql: sql,
                values: [.text(Self.ftsExpression(trimmed)), .integer(Int64(query.limit))]
            )
        }

        var clauses = ["frame_search MATCH ?"]
        var values: [BoundValue] = [.text(Self.ftsExpression(trimmed))]
        appendFilters(query, clauses: &clauses, values: &values)
        if !includeSensitive {
            clauses.append(Self.agentSafePrivacyPredicate(frameAlias: "f"))
        }

        let source = hasAlignedSearchRowIDs
            ? "frame_search JOIN frames f ON f.rowid = frame_search.rowid"
            : "frame_search JOIN frames f ON f.id = frame_search.frame_id"
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   f.image_path, f.thumbnail_path,
                   snippet(frame_search, -1, '‹', '›', ' … ', 18) AS excerpt,
                   frame_search.rank AS relevance, f.is_sensitive, f.activity_session_id
            FROM \(source)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY frame_search.rank ASC, f.captured_at DESC, f.id DESC
            LIMIT ?
            """
        values.append(.integer(Int64(query.limit)))
        return try readHits(sql: sql, values: values)
    }

    public func recent(limit: Int) throws -> [SearchHit] {
        try recent(limit: limit, includeSensitive: true)
    }

    /// Returns newest-first hits after applying the sensitivity predicate in
    /// SQL, before the requested result cap can hide ordinary evidence.
    public func recent(
        limit: Int,
        includeSensitive: Bool
    ) throws -> [SearchHit] {
        try recentMatching(
            SearchQuery(limit: limit),
            includeSensitive: includeSensitive
        )
    }

    public func recall(
        _ requestedScope: RecallScope,
        after cursor: RecallCursor?,
        limit: Int
    ) throws -> RecallPage {
        try Task.checkCancellation()
        let scope = requestedScope.normalized
        try Self.validateRecallScope(scope)
        let cursorPosition = try cursor.map {
            try Self.decodeRecallCursor($0, expectedScope: scope)
        }
        let boundedLimit = min(
            max(limit, RecallPage.minimumLimit),
            RecallPage.maximumLimit
        )

        var clauses = [String]()
        var values = [BoundValue]()
        let usesFullTextSearch = !scope.text.isEmpty
        if usesFullTextSearch {
            clauses.append("frame_search MATCH ?")
            values.append(.text(Self.safeFTSExpression(scope.text)))
        }
        appendRecallFilters(scope, excluding: nil, clauses: &clauses, values: &values)
        if let cursorPosition {
            clauses.append("(f.captured_at < ? OR (f.captured_at = ? AND f.id < ?))")
            values.append(.double(cursorPosition.capturedAt.timeIntervalSince1970))
            values.append(.double(cursorPosition.capturedAt.timeIntervalSince1970))
            values.append(.text(cursorPosition.id))
        }

        let source: String
        if usesFullTextSearch, hasAlignedSearchRowIDs {
            // The aligned integer rowid removes a secondary text-primary-key
            // lookup for every match before metadata filtering and paging.
            source = "frame_search JOIN frames f ON f.rowid = frame_search.rowid"
        } else if usesFullTextSearch {
            // A read-only client may open a v5 vault before the desktop app has
            // performed the one-time rowid-alignment migration.
            source = "frame_search JOIN frames f ON f.id = frame_search.frame_id"
        } else {
            source = "frames f"
        }
        let excerpt = usesFullTextSearch
            ? "snippet(frame_search, -1, '‹', '›', ' … ', 18)"
            : "substr(f.ocr_text, 1, 240)"
        let relevance = usesFullTextSearch ? "frame_search.rank" : "0.0"
        let predicate = clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   f.image_path, f.thumbnail_path, \(excerpt), \(relevance),
                   f.is_sensitive, f.activity_session_id
            FROM \(source)
            WHERE \(predicate)
            ORDER BY f.captured_at DESC, f.id DESC
            LIMIT ?
            """
        values.append(.integer(Int64(boundedLimit + 1)))

        let fastHits: [SearchHit]?
        if usesFullTextSearch,
           hasAlignedSearchRowIDs,
           storedFrameCount >= Self.recentTextRecallFastPathMinimumFrameCount {
            fastHits = try withCancellationProgressHandler {
                try readRecentTextRecallFastPath(
                    scope: scope,
                    after: cursorPosition,
                    requiredCount: boundedLimit + 1
                )
            }
        } else {
            fastHits = nil
        }
        var hits: [SearchHit]
        if let fastHits {
            hits = fastHits
        } else {
            hits = try withCancellationProgressHandler {
                try readHits(sql: sql, values: values)
            }
        }
        let hasMore = hits.count > boundedLimit
        if hasMore {
            hits.removeLast(hits.count - boundedLimit)
        }
        try Task.checkCancellation()

        let nextCursor: RecallCursor?
        if hasMore, let last = hits.last {
            nextCursor = try Self.encodeRecallCursor(
                FrameOrderCursor(id: last.id.rawValue, capturedAt: last.capturedAt),
                scope: scope
            )
        } else {
            nextCursor = nil
        }
        return RecallPage(hits: hits, nextCursor: nextCursor, hasMore: hasMore)
    }

    public func rankedRecall(
        _ requestedScope: RecallScope,
        limit: Int
    ) throws -> [SearchHit] {
        try Task.checkCancellation()
        let scope = requestedScope.normalized
        try Self.validateRecallScope(scope)
        let boundedLimit = min(
            max(limit, RecallPage.minimumLimit),
            RecallPage.maximumLimit
        )
        guard !scope.text.isEmpty else {
            return try recall(scope, after: nil, limit: boundedLimit).hits
        }

        var clauses = ["frame_search MATCH ?"]
        var values: [BoundValue] = [.text(Self.safeFTSExpression(scope.text))]
        appendRecallFilters(scope, excluding: nil, clauses: &clauses, values: &values)
        let source = hasAlignedSearchRowIDs
            ? "frame_search JOIN frames f ON f.rowid = frame_search.rowid"
            : "frame_search JOIN frames f ON f.id = frame_search.frame_id"
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   f.image_path, f.thumbnail_path,
                   snippet(frame_search, -1, '‹', '›', ' … ', 18),
                   frame_search.rank, f.is_sensitive, f.activity_session_id
            FROM \(source)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY frame_search.rank ASC, f.captured_at DESC, f.id DESC
            LIMIT ?
            """
        values.append(.integer(Int64(boundedLimit)))
        return try withCancellationProgressHandler {
            try readHits(sql: sql, values: values)
        }
    }

    private static func recallDrivingIndex(for scope: RecallScope) -> String {
        // A single equality-constrained prefix preserves the timestamp/ID
        // suffix order. Multiple selected facets need the global time index so
        // results from each value remain correctly interleaved.
        if scope.domains.count == 1,
           scope.applicationBundleIdentifiers.count == 1 {
            return "frames_domain_application_recall"
        }
        if scope.domains.count == 1 {
            return "frames_domain"
        }
        if scope.applicationBundleIdentifiers.count == 1 {
            return "frames_application"
        }
        return "frames_captured_at"
    }

    // The exhaustive aligned-rowid plan is faster for small vaults. Route only
    // after the measured crossover so the million-frame fix does not tax normal
    // early use; both branches retain identical full-history semantics.
    private static let recentTextRecallFastPathMinimumFrameCount: Int64 = 250_000

    /// Finds a newest-first page without enumerating and sorting every FTS hit.
    ///
    /// The probe walks a bounded number of narrow covering-index rows in exact
    /// Recall order, then intersects each chunk with its exact FTS rowids. If the
    /// requested page is found, snippet/rank work is limited to that final page
    /// and no full-history sort is needed. If a sparse
    /// query does not fill the page within the budget, the caller falls back to
    /// the original exhaustive plan, preserving complete-history correctness.
    private func readRecentTextRecallFastPath(
        scope: RecallScope,
        after cursor: FrameOrderCursor?,
        requiredCount: Int
    ) throws -> [SearchHit]? {
        // Start close to one page so dense queries do not scan a 512-row
        // metadata slice before we already have enough chronological hits.
        // Larger pages still fit in one probe, while sparse queries retain the
        // same complete-history fallback budget.
        let chunkSize = min(512, max(requiredCount, 128))
        let maximumCandidates = 8_192
        let expression = Self.safeFTSExpression(scope.text)
        var candidatesScanned = 0
        var position = cursor
        var selected = [RecallCandidate]()

        while candidatesScanned < maximumCandidates, selected.count < requiredCount {
            try Task.checkCancellation()
            let requestCount = min(chunkSize, maximumCandidates - candidatesScanned)
            let batch = try readRecallCandidates(
                scope: scope,
                after: position,
                limit: requestCount
            )
            guard !batch.isEmpty else {
                let textMatches = try readRecallTextMatches(
                    expression: expression,
                    candidateRowIDs: selected.map(\.rowID)
                )
                return try readRecallCandidateHits(selected, textMatches: textMatches)
            }

            let matchingRowIDs = try readRecallMatchingRowIDs(
                expression: expression,
                candidateRowIDs: batch.map(\.rowID)
            )
            for candidate in batch where matchingRowIDs.contains(candidate.rowID) {
                selected.append(candidate)
                if selected.count == requiredCount { break }
            }
            candidatesScanned += batch.count

            guard let last = batch.last else { break }
            position = FrameOrderCursor(
                id: last.id,
                capturedAt: Date(timeIntervalSince1970: last.capturedAt)
            )
            if batch.count < requestCount {
                let textMatches = try readRecallTextMatches(
                    expression: expression,
                    candidateRowIDs: selected.map(\.rowID)
                )
                return try readRecallCandidateHits(selected, textMatches: textMatches)
            }
        }

        guard selected.count == requiredCount else {
            return nil
        }
        let textMatches = try readRecallTextMatches(
            expression: expression,
            candidateRowIDs: selected.map(\.rowID)
        )
        return try readRecallCandidateHits(selected, textMatches: textMatches)
    }

    private func readRecallCandidates(
        scope: RecallScope,
        after cursor: FrameOrderCursor?,
        limit: Int
    ) throws -> [RecallCandidate] {
        var clauses = [String]()
        var values = [BoundValue]()
        appendRecallFilters(scope, excluding: nil, clauses: &clauses, values: &values)
        if let cursor {
            clauses.append("(f.captured_at < ? OR (f.captured_at = ? AND f.id < ?))")
            values.append(.double(cursor.capturedAt.timeIntervalSince1970))
            values.append(.double(cursor.capturedAt.timeIntervalSince1970))
            values.append(.text(cursor.id))
        }
        values.append(.integer(Int64(limit)))
        let predicate = clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")
        let index = Self.recallDrivingIndex(for: scope)
        let sql = """
            SELECT f.rowid, f.id, f.captured_at
            FROM frames AS f INDEXED BY \(index)
            WHERE \(predicate)
            ORDER BY f.captured_at DESC, f.id DESC
            LIMIT ?
            """
        return try withStatement(sql) { statement in
            Self.bind(values, to: statement)
            var candidates = [RecallCandidate]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { try throwStepError(status) }
                candidates.append(RecallCandidate(
                    rowID: sqlite3_column_int64(statement, 0),
                    id: Self.string(statement, column: 1) ?? "",
                    capturedAt: sqlite3_column_double(statement, 2)
                ))
            }
            return candidates
        }
    }

    private func readRecallMatchingRowIDs(
        expression: String,
        candidateRowIDs: [Int64]
    ) throws -> Set<Int64> {
        guard !candidateRowIDs.isEmpty else { return [] }
        let candidateSet = Set(candidateRowIDs)
        let ranges = Self.clusteredRowIDRanges(candidateRowIDs)
        let sql = """
            SELECT rowid
            FROM frame_search
            WHERE frame_search MATCH ? AND rowid >= ? AND rowid <= ?
            """
        return try withStatement(sql) { statement in
            var matches = Set<Int64>()
            for range in ranges {
                Self.bind(expression, at: 1, to: statement)
                sqlite3_bind_int64(statement, 2, range.lowerBound)
                sqlite3_bind_int64(statement, 3, range.upperBound)
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { try throwStepError(status) }
                    let rowID = sqlite3_column_int64(statement, 0)
                    if candidateSet.contains(rowID) { matches.insert(rowID) }
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            return matches
        }
    }

    private func readRecallTextMatches(
        expression: String,
        candidateRowIDs: [Int64]
    ) throws -> [Int64: RecallTextMatch] {
        guard !candidateRowIDs.isEmpty else { return [:] }
        let candidateSet = Set(candidateRowIDs)
        let ranges = Self.clusteredRowIDRanges(candidateRowIDs)
        let candidatePlaceholders = Array(repeating: "?", count: candidateRowIDs.count)
            .joined(separator: ", ")
        let sql = """
            SELECT rowid,
                   CASE WHEN rowid IN (\(candidatePlaceholders))
                        THEN snippet(frame_search, -1, '‹', '›', ' … ', 18)
                        ELSE NULL END
            FROM frame_search
            WHERE frame_search MATCH ? AND rowid >= ? AND rowid <= ?
            """
        return try withStatement(sql) { statement in
            var matches = [Int64: RecallTextMatch]()
            for range in ranges {
                for (offset, rowID) in candidateRowIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(offset + 1), rowID)
                }
                let expressionIndex = Int32(candidateRowIDs.count + 1)
                Self.bind(expression, at: expressionIndex, to: statement)
                sqlite3_bind_int64(statement, expressionIndex + 1, range.lowerBound)
                sqlite3_bind_int64(statement, expressionIndex + 2, range.upperBound)
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { try throwStepError(status) }
                    let rowID = sqlite3_column_int64(statement, 0)
                    guard candidateSet.contains(rowID) else { continue }
                    matches[rowID] = RecallTextMatch(
                        snippet: Self.string(statement, column: 1) ?? "",
                        // Chronological Recall never ranks by BM25. Ranked
                        // Recall retains its separate exhaustive relevance path.
                        relevance: 0
                    )
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            return matches
        }
    }

    private func readRecallCandidateHits(
        _ candidates: [RecallCandidate],
        textMatches: [Int64: RecallTextMatch]
    ) throws -> [SearchHit] {
        guard !candidates.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   f.image_path, f.thumbnail_path, '', 0.0,
                   f.is_sensitive, f.activity_session_id
            FROM frames f
            WHERE f.rowid IN (\(placeholders))
            ORDER BY f.captured_at DESC, f.id DESC
            """
        var hits = try readHits(
            sql: sql,
            values: candidates.map { .integer($0.rowID) }
        )
        let rowIDByFrameID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.rowID) })
        for index in hits.indices {
            guard let rowID = rowIDByFrameID[hits[index].id.rawValue],
                  let match = textMatches[rowID] else { continue }
            hits[index].snippet = match.snippet
            hits[index].score = -match.relevance
        }
        return hits
    }

    private static func clusteredRowIDRanges(_ rowIDs: [Int64]) -> [ClosedRange<Int64>] {
        let sorted = rowIDs.sorted()
        guard var lower = sorted.first else { return [] }
        var upper = lower
        var ranges = [ClosedRange<Int64>]()
        for rowID in sorted.dropFirst() {
            if rowID - upper > 4_096 {
                ranges.append(lower...upper)
                lower = rowID
            }
            upper = rowID
        }
        ranges.append(lower...upper)
        return ranges
    }

    public func recallFacets(
        _ requestedScope: RecallScope,
        limitPerKind: Int
    ) throws -> RecallFacets {
        try Task.checkCancellation()
        let scope = requestedScope.normalized
        try Self.validateRecallScope(scope)
        let boundedLimit = min(max(limitPerKind, 1), RecallFacets.maximumLimitPerKind)

        if hasMaterializedRecallFacetTotals,
           Self.isUnfilteredBrowseFacetScope(scope) {
            let applications = try withCancellationProgressHandler {
                try readMaterializedApplicationFacets(limit: boundedLimit)
            }
            try Task.checkCancellation()
            let domains = try withCancellationProgressHandler {
                try readMaterializedDomainFacets(limit: boundedLimit)
            }
            try Task.checkCancellation()
            let browserMomentCount = try withCancellationProgressHandler {
                try readMaterializedBrowserMomentCount()
            }
            try Task.checkCancellation()
            return RecallFacets(
                applications: applications,
                domains: domains,
                browserMomentCount: browserMomentCount
            )
        }

        let applications = try withCancellationProgressHandler {
            try readApplicationFacets(scope: scope, limit: boundedLimit)
        }
        try Task.checkCancellation()
        let domains = try withCancellationProgressHandler {
            try readDomainFacets(scope: scope, limit: boundedLimit)
        }
        try Task.checkCancellation()
        let browserMomentCount = try withCancellationProgressHandler {
            try readBrowserMomentCount(scope: scope)
        }
        try Task.checkCancellation()
        return RecallFacets(
            applications: applications,
            domains: domains,
            browserMomentCount: browserMomentCount
        )
    }

    public func frame(id: FrameID) throws -> FrameDocument? {
        try frame(id: id, includeSensitive: true)
    }

    /// Looks up a frame while allowing agent-facing callers to make sensitive
    /// identifiers indistinguishable from missing identifiers.
    public func frame(
        id: FrameID,
        includeSensitive: Bool
    ) throws -> FrameDocument? {
        guard includeSensitive else {
            return try agentSafeFrame(id: id)?.frame
        }
        let evidenceSelection = hasAccessibilityEvidenceSchema
            ? "snapshot.payload"
            : "NULL"
        let evidenceJoin = hasAccessibilityEvidenceSchema
            ? "LEFT JOIN accessibility_snapshots AS snapshot ON snapshot.content_hash = f.accessibility_snapshot_hash"
            : ""
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier, f.window_title,
                   f.url, f.domain, f.display_id, f.window_id, f.window_x, f.window_y,
                   f.window_width, f.window_height, f.ocr_text, f.ocr_regions, f.image_path,
                   f.thumbnail_path, f.pixel_width, f.pixel_height, f.visual_fingerprint,
                   f.change_score, f.is_sensitive, \(evidenceSelection)
            FROM frames AS f
            \(evidenceJoin)
            WHERE f.id = ? LIMIT 1
            """
        return try withStatement(sql) { statement in
            Self.bind(id.rawValue, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeFrame(statement)
        }
    }

    /// Resolves an agent-safe frame and its authoritative current session ID in
    /// one SQL snapshot. Missing session materialization fails closed.
    public func agentSafeFrame(id: FrameID) throws -> AgentSafeFrameEvidence? {
        try agentSafeFrames(ids: [id]).first
    }

    /// Resolves a bounded candidate window through one statement and one
    /// SQLCipher snapshot. The request is deduplicated without reordering;
    /// missing, deleted, sensitive, and mixed-private-session identifiers are
    /// all omitted through the same SQL predicate.
    public func agentSafeFrames(ids: [FrameID]) throws -> [AgentSafeFrameEvidence] {
        try Task.checkCancellation()
        guard ids.count <= Self.maximumAgentSafeFrameRequestCount else {
            throw PassageError.invalidQuery(
                "Agent-safe frame resolution accepts at most \(Self.maximumAgentSafeFrameRequestCount) identifiers."
            )
        }

        var seen = Set<FrameID>()
        let orderedUniqueIDs = ids.filter { seen.insert($0).inserted }
        guard !orderedUniqueIDs.isEmpty else { return [] }
        try Task.checkCancellation()

        let sql = Self.agentSafeFramesSQL(
            requestCount: orderedUniqueIDs.count,
            includesAccessibilityEvidence: hasAccessibilityEvidenceSchema
        )
        let resolvedByID: [FrameID: AgentSafeFrameEvidence] = try withCancellationProgressHandler {
            try withStatement(sql) { statement in
                for (offset, id) in orderedUniqueIDs.enumerated() {
                    Self.bind(id.rawValue, at: Int32(offset + 1), to: statement)
                }

                var resolved = [FrameID: AgentSafeFrameEvidence]()
                resolved.reserveCapacity(orderedUniqueIDs.count)
                while true {
                    try Task.checkCancellation()
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { try throwStepError(status) }
                    guard let sessionID = Self.string(statement, column: 23) else {
                        continue
                    }
                    let frame = try decodeFrame(statement)
                    resolved[frame.id] = AgentSafeFrameEvidence(
                        frame: frame,
                        activitySessionID: ActivitySessionID(rawValue: sessionID)
                    )
                }
                return resolved
            }
        }
        try Task.checkCancellation()
        return orderedUniqueIDs.compactMap { resolvedByID[$0] }
    }

    /// Re-resolves a bounded, possibly stale candidate window at the final
    /// agent-disclosure boundary. The raw request is capped before SQL performs
    /// first-occurrence deduplication. Every returned hit still matches the
    /// current query scope and belongs to a currently materialized session that
    /// is ordinary both in its summary and in its authoritative frame rows.
    ///
    /// Media paths are projected out in SQL. Omitted identifiers leave no
    /// placeholder or ordinal in the returned array, so private, deleted, and
    /// stale candidates remain indistinguishable.
    public func agentSafeSearchHits(
        ids: [FrameID],
        matching query: SearchQuery
    ) throws -> [SearchHit] {
        try Task.checkCancellation()
        guard ids.count <= Self.maximumAgentSafeFrameRequestCount else {
            throw PassageError.invalidQuery(
                "Agent-safe search-hit resolution accepts at most \(Self.maximumAgentSafeFrameRequestCount) identifiers."
            )
        }
        guard !ids.isEmpty else { return [] }

        let trimmedText = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = Self.agentSafeSearchHitsSQL(
            requestCount: ids.count,
            query: query,
            usesAlignedSearchRowIDs: hasAlignedSearchRowIDs
        )
        var values = ids.map { BoundValue.text($0.rawValue) }
        if !trimmedText.isEmpty {
            values.append(.text(Self.ftsExpression(trimmedText)))
        }
        values.append(contentsOf: Self.searchFilterValues(query))

        let hits = try withCancellationProgressHandler {
            try readHits(sql: sql, values: values)
        }
        try Task.checkCancellation()
        return hits
    }

    /// Internal so store tests can prove that authoritative resolution starts
    /// from the bounded VALUES relation and performs privacy/scope checks before
    /// any row is returned.
    nonisolated static func agentSafeSearchHitsSQL(
        requestCount: Int,
        query: SearchQuery,
        usesAlignedSearchRowIDs: Bool = true
    ) -> String {
        precondition((1...maximumAgentSafeFrameRequestCount).contains(requestCount))

        let requestedRows = (0..<requestCount)
            .map { "(?, \($0))" }
            .joined(separator: ", ")
        let trimmedText = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmedText.isEmpty
        let searchSelection = hasText
            ? "snippet(frame_search, -1, '‹', '›', ' … ', 18), frame_search.rank"
            : "substr(f.ocr_text, 1, 240), 0.0"
        let searchJoin: String
        if hasText {
            searchJoin = usesAlignedSearchRowIDs
                ? "CROSS JOIN frame_search"
                : "JOIN frame_search ON frame_search.frame_id = f.id"
        } else {
            searchJoin = ""
        }

        var clauses = [
            "f.id = first_requested.frame_id",
            "f.is_sensitive = 0",
            "f.activity_session_id IS NOT NULL",
            "NOT EXISTS (\n                SELECT 1\n                FROM frames AS sensitive_session_frame INDEXED BY frames_activity_session\n                WHERE sensitive_session_frame.activity_session_id = f.activity_session_id\n                  AND sensitive_session_frame.is_sensitive != 0\n            )",
        ]
        if hasText {
            if usesAlignedSearchRowIDs {
                clauses.append("frame_search.rowid = f.rowid")
                clauses.append("frame_search.frame_id = f.id")
            }
            clauses.append("frame_search MATCH ?")
        }
        clauses.append("safe_session.id = f.activity_session_id")
        clauses.append("safe_session.contains_sensitive = 0")
        clauses.append(contentsOf: searchFilterClauses(query, frameAlias: "f"))

        return """
            WITH requested(frame_id, ordinal) AS (
                VALUES \(requestedRows)
            ),
            first_requested(frame_id, ordinal) AS MATERIALIZED (
                SELECT frame_id, MIN(ordinal)
                FROM requested
                GROUP BY frame_id
            )
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   '' AS image_path, NULL AS thumbnail_path,
                   \(searchSelection), 0 AS is_sensitive, safe_session.id
            FROM first_requested
            CROSS JOIN frames AS f
            CROSS JOIN activity_sessions AS safe_session
            \(searchJoin)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY first_requested.ordinal ASC
            """
    }

    /// Internal so store tests can assert that the production batch statement
    /// is driven by its bounded requested-ID relation rather than a frame scan.
    nonisolated static func agentSafeFramesSQL(
        requestCount: Int,
        includesAccessibilityEvidence: Bool
    ) -> String {
        precondition((1...maximumAgentSafeFrameRequestCount).contains(requestCount))
        let evidenceSelection = includesAccessibilityEvidence
            ? "snapshot.payload"
            : "NULL"
        let evidenceJoin = includesAccessibilityEvidence
            ? "LEFT JOIN accessibility_snapshots AS snapshot ON snapshot.content_hash = f.accessibility_snapshot_hash"
            : ""
        let requestedRows = Array(repeating: "(?)", count: requestCount)
            .joined(separator: ", ")
        return """
            WITH requested(frame_id) AS (VALUES \(requestedRows))
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier, f.window_title,
                   f.url, f.domain, f.display_id, f.window_id, f.window_x, f.window_y,
                   f.window_width, f.window_height, f.ocr_text, f.ocr_regions, f.image_path,
                   f.thumbnail_path, f.pixel_width, f.pixel_height, f.visual_fingerprint,
                   f.change_score, f.is_sensitive, \(evidenceSelection), safe_session.id
            FROM requested
            CROSS JOIN frames AS f
            JOIN activity_sessions AS safe_session
              ON safe_session.id = f.activity_session_id
             AND safe_session.contains_sensitive = 0
            \(evidenceJoin)
            WHERE f.id = requested.frame_id
              AND f.is_sensitive = 0
            """
    }

    public func replaceOCR(
        for id: FrameID,
        expectedVisualFingerprint: UInt64,
        text: String,
        regions: [OCRRegion]
    ) throws -> FrameDocument? {
        try Task.checkCancellation()
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let encodedRegions = try OCRRegionCodec.encode(regions, canonicalText: text)

        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            try Task.checkCancellation()

            let rowID: Int64? = try withStatement(
                "SELECT rowid FROM frames WHERE id = ? AND visual_fingerprint = ? LIMIT 1"
            ) { statement in
                Self.bind(id.rawValue, at: 1, to: statement)
                sqlite3_bind_int64(statement, 2, Int64(bitPattern: expectedVisualFingerprint))
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return sqlite3_column_int64(statement, 0)
            }

            // Retention or explicit deletion may have won the race before this
            // transaction acquired its write lock. Never recreate that frame.
            guard let rowID else {
                try Self.execute("COMMIT", on: database)
                return nil
            }

            try Task.checkCancellation()
            try withStatement(
                "UPDATE frames SET ocr_text = ?, ocr_regions = ? WHERE rowid = ? AND id = ? AND visual_fingerprint = ?"
            ) { statement in
                Self.bind(text, at: 1, to: statement)
                _ = encodedRegions.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        2,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        sqliteTransient
                    )
                }
                sqlite3_bind_int64(statement, 3, rowID)
                Self.bind(id.rawValue, at: 4, to: statement)
                sqlite3_bind_int64(statement, 5, Int64(bitPattern: expectedVisualFingerprint))
                try stepDone(statement)
            }
            guard sqlite3_changes(database) == 1 else {
                try Self.execute("ROLLBACK", on: database)
                return nil
            }

            // FTS5 has no trigger by design. Replacing its row in the same
            // transaction preserves the rowid alignment used by Recall's fast
            // path and makes the corrected text searchable at commit time.
            try withStatement("DELETE FROM frame_search WHERE rowid = ?") { statement in
                sqlite3_bind_int64(statement, 1, rowID)
                try stepDone(statement)
            }
            try withStatement(
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
                WHERE frame.rowid = ? AND frame.id = ? AND frame.visual_fingerprint = ?
                """
            ) { statement in
                sqlite3_bind_int64(statement, 1, rowID)
                Self.bind(id.rawValue, at: 2, to: statement)
                sqlite3_bind_int64(statement, 3, Int64(bitPattern: expectedVisualFingerprint))
                try stepDone(statement)
            }

            try Task.checkCancellation()
            let replacement = try frame(id: id)
            guard replacement?.visualFingerprint == expectedVisualFingerprint else {
                try Self.execute("ROLLBACK", on: database)
                return nil
            }
            try Self.execute("COMMIT", on: database)
            try connection.hardenFilePermissions()
            return replacement
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Drains every bounded page of the legacy website-facet repair in one app
    /// session. Each page commits independently and yields the actor before the
    /// next page so capture and Recall can continue making progress. Cancellation
    /// is checked while scanning, while updating, and between pages.
    ///
    /// This deliberately retains the same evidence boundary as
    /// `backfillMissingBrowserDomains`: old OCR is not interpreted because old
    /// rows do not record whether their pixels came from a focused window or a
    /// full display.
    public func drainMissingBrowserDomains(batchLimit: Int = 2_000) async throws -> Int {
        var repairedCount = 0
        while true {
            try Task.checkCancellation()
            repairedCount += try backfillMissingBrowserDomains(limit: batchLimit)
            if try browserDomainBackfillIsComplete() {
                return repairedCount
            }
            await Task.yield()
        }
    }

    /// Repairs website facets for older browser moments that already carry a
    /// trusted HTTP(S) source URL but are missing its derived domain. Historical
    /// screenshots do not persist focused-window provenance, so this migration
    /// deliberately never guesses a website from their OCR.
    ///
    /// Progress advances over a bounded rowid batch even when no row can be
    /// repaired. This prevents malformed or ineligible recent rows from
    /// starving older evidence on every launch.
    public func backfillMissingBrowserDomains(limit: Int = 2_000) throws -> Int {
        try Task.checkCancellation()
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let boundedLimit = min(max(limit, 1), 10_000)
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            if try Self.metadataValue(
                key: Self.browserDomainBackfillMarkerKey,
                database: database
            ) == Self.browserDomainBackfillVersion {
                try Self.execute("COMMIT", on: database)
                return 0
            }

            let cursor = try Self.metadataValue(
                key: Self.browserDomainBackfillCursorKey,
                database: database
            )
                .flatMap(Int64.init) ?? Int64.max
            let select = try Self.prepare(
                """
                SELECT rowid, id, application_name, bundle_identifier,
                       window_title, url, domain, is_sensitive
                FROM frames
                WHERE rowid < ?
                ORDER BY rowid DESC
                LIMIT ?
                """,
                on: database
            )
            sqlite3_bind_int64(select, 1, cursor)
            sqlite3_bind_int64(select, 2, Int64(boundedLimit + 1))

            struct BackfillRow {
                var rowID: Int64
                var id: String
                var applicationName: String
                var bundleIdentifier: String?
                var windowTitle: String?
                var url: URL?
                var domain: String?
                var isSensitive: Bool
            }
            var scannedRows: [BackfillRow] = []
            do {
                while true {
                    try Task.checkCancellation()
                    let status = sqlite3_step(select)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { try throwStepError(status) }
                    scannedRows.append(BackfillRow(
                        rowID: sqlite3_column_int64(select, 0),
                        id: Self.string(select, column: 1) ?? "",
                        applicationName: Self.string(select, column: 2) ?? "Unknown",
                        bundleIdentifier: Self.string(select, column: 3),
                        windowTitle: Self.string(select, column: 4),
                        url: Self.string(select, column: 5).flatMap(URL.init(string:)),
                        domain: Self.string(select, column: 6),
                        isSensitive: Self.bool(select, column: 7)
                    ))
                }
                sqlite3_finalize(select)
            } catch {
                sqlite3_finalize(select)
                throw error
            }

            let hasMoreRows = scannedRows.count > boundedLimit
            let batch = Array(scannedRows.prefix(boundedLimit))
            let repairs = batch.compactMap { row -> (
                rowID: Int64,
                frameID: String,
                domain: String,
                sessionTitle: String
            )? in
                guard !row.isSensitive,
                      row.domain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ?? true,
                      ScreenContext.isKnownWebBrowserBundleIdentifier(row.bundleIdentifier),
                      let scheme = row.url?.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else { return nil }
                let context = ScreenContext(
                    applicationName: row.applicationName,
                    bundleIdentifier: row.bundleIdentifier,
                    url: row.url
                )
                guard let domain = BrowserWebsiteMetadata.enriching(
                    context,
                    from: []
                ).domain else { return nil }
                let title = [row.windowTitle, domain, row.applicationName]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "Untitled activity"
                return (row.rowID, row.id, domain, String(title.prefix(240)))
            }

            let update = try Self.prepare(
                "UPDATE frames SET domain = ? WHERE rowid = ? AND (domain IS NULL OR TRIM(domain) = '')",
                on: database
            )
            defer { sqlite3_finalize(update) }
            let sessionUpdate = try Self.prepare(
                """
                UPDATE activity_sessions
                SET latest_domain = ?, title = ?
                WHERE latest_frame_id = ?
                """,
                on: database
            )
            defer { sqlite3_finalize(sessionUpdate) }
            var repairedCount = 0
            for repair in repairs {
                try Task.checkCancellation()
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                Self.bind(repair.domain, at: 1, to: update)
                sqlite3_bind_int64(update, 2, repair.rowID)
                try Self.stepDone(update, database: database)
                let didRepair = sqlite3_changes(database) > 0
                repairedCount += didRepair ? 1 : 0
                guard didRepair else { continue }

                sqlite3_reset(sessionUpdate)
                sqlite3_clear_bindings(sessionUpdate)
                Self.bind(repair.domain, at: 1, to: sessionUpdate)
                Self.bind(repair.sessionTitle, at: 2, to: sessionUpdate)
                Self.bind(repair.frameID, at: 3, to: sessionUpdate)
                try Self.stepDone(sessionUpdate, database: database)
            }

            if hasMoreRows, let lastRowID = batch.last?.rowID {
                let progress = try Self.prepare(
                    "INSERT OR REPLACE INTO store_metadata(key, value) VALUES (?, ?)",
                    on: database
                )
                defer { sqlite3_finalize(progress) }
                Self.bind(Self.browserDomainBackfillCursorKey, at: 1, to: progress)
                Self.bind(String(lastRowID), at: 2, to: progress)
                try Self.stepDone(progress, database: database)
            } else {
                let marker = try Self.prepare(
                    "INSERT OR REPLACE INTO store_metadata(key, value) VALUES (?, ?)",
                    on: database
                )
                defer { sqlite3_finalize(marker) }
                Self.bind(Self.browserDomainBackfillMarkerKey, at: 1, to: marker)
                Self.bind(Self.browserDomainBackfillVersion, at: 2, to: marker)
                try Self.stepDone(marker, database: database)
                let clearCursor = try Self.prepare(
                    "DELETE FROM store_metadata WHERE key = ?",
                    on: database
                )
                defer { sqlite3_finalize(clearCursor) }
                Self.bind(Self.browserDomainBackfillCursorKey, at: 1, to: clearCursor)
                try Self.stepDone(clearCursor, database: database)
            }
            try Self.execute("COMMIT", on: database)
            try connection.hardenFilePermissions()
            return repairedCount
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    private func browserDomainBackfillIsComplete() throws -> Bool {
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        return try Self.metadataValue(
            key: Self.browserDomainBackfillMarkerKey,
            database: connectionLease.pointer
        ) == Self.browserDomainBackfillVersion
    }

    public func deleteFrames(olderThan date: Date) throws -> [String] {
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let selectSQL = "SELECT id, image_path, thumbnail_path, activity_session_id FROM frames WHERE captured_at < ?"
        var frameIDs: [String] = []
        var pathsToDelete: [String] = []
        var affectedSessionIDs: Set<String> = []
        try withStatement(selectSQL) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            while sqlite3_step(statement) == SQLITE_ROW {
                frameIDs.append(Self.string(statement, column: 0) ?? "")
                if let image = Self.string(statement, column: 1) { pathsToDelete.append(image) }
                if let thumbnail = Self.string(statement, column: 2) { pathsToDelete.append(thumbnail) }
                if let sessionID = Self.string(statement, column: 3) { affectedSessionIDs.insert(sessionID) }
            }
        }
        guard !frameIDs.isEmpty else { return [] }

        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            try withStatement("DELETE FROM frame_search WHERE frame_id IN (SELECT id FROM frames WHERE captured_at < ?)") { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM frames WHERE captured_at < ?") { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                try stepDone(statement)
            }
            try VisualEmbeddingSchema.deleteOrphanVectors(on: database)
            try AccessibilitySnapshotSchema.deleteOrphans(on: database)
            try repartitionActivitySessions(affectedSessionIDs)
            let orphanedPaths = try unreferencedMediaPaths(from: pathsToDelete)
            try Self.execute("COMMIT", on: database)
            storedFrameCount -= Int64(frameIDs.count)
            cachedMediaBytes = nil
            try connection.hardenFilePermissions()
            return orphanedPaths
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func deleteFrames(from startDate: Date?, through endDate: Date?) throws -> [String] {
        if let startDate, let endDate, startDate > endDate {
            throw PassageError.invalidQuery("Deletion start date must not be later than its end date.")
        }
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer

        var clauses = ["1 = 1"]
        var values: [Double] = []
        if let startDate {
            clauses.append("captured_at >= ?")
            values.append(startDate.timeIntervalSince1970)
        }
        if let endDate {
            clauses.append("captured_at <= ?")
            values.append(endDate.timeIntervalSince1970)
        }
        let predicate = clauses.joined(separator: " AND ")
        var frameIDs: [String] = []
        var pathsToDelete: [String] = []
        var affectedSessionIDs: Set<String> = []
        try withStatement("SELECT id, image_path, thumbnail_path, activity_session_id FROM frames WHERE \(predicate)") { statement in
            for (offset, value) in values.enumerated() {
                sqlite3_bind_double(statement, Int32(offset + 1), value)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = Self.string(statement, column: 0) { frameIDs.append(id) }
                if let image = Self.string(statement, column: 1) { pathsToDelete.append(image) }
                if let thumbnail = Self.string(statement, column: 2) { pathsToDelete.append(thumbnail) }
                if let sessionID = Self.string(statement, column: 3) { affectedSessionIDs.insert(sessionID) }
            }
        }
        guard !frameIDs.isEmpty else { return [] }

        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            try withStatement("DELETE FROM frame_search WHERE frame_id IN (SELECT id FROM frames WHERE \(predicate))") { statement in
                for (offset, value) in values.enumerated() {
                    sqlite3_bind_double(statement, Int32(offset + 1), value)
                }
                try stepDone(statement)
            }
            try withStatement("DELETE FROM frames WHERE \(predicate)") { statement in
                for (offset, value) in values.enumerated() {
                    sqlite3_bind_double(statement, Int32(offset + 1), value)
                }
                try stepDone(statement)
            }
            try VisualEmbeddingSchema.deleteOrphanVectors(on: database)
            try AccessibilitySnapshotSchema.deleteOrphans(on: database)
            if startDate == nil, endDate == nil {
                try Self.execute("DELETE FROM activity_sessions", on: database)
            } else {
                try repartitionActivitySessions(affectedSessionIDs)
            }
            let orphanedPaths = try unreferencedMediaPaths(from: pathsToDelete)
            try Self.execute("COMMIT", on: database)
            storedFrameCount -= Int64(frameIDs.count)
            cachedMediaBytes = nil
            try connection.hardenFilePermissions()
            return orphanedPaths
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func deleteOldestFrames(limit: Int) throws -> [String] {
        let boundedLimit = min(max(limit, 1), 1_000)
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        var frameIDs: [String] = []
        var pathsToDelete: [String] = []
        var affectedSessionIDs: Set<String> = []
        try withStatement(
            "SELECT id, image_path, thumbnail_path, activity_session_id FROM frames ORDER BY captured_at ASC, id ASC LIMIT ?"
        ) { statement in
            sqlite3_bind_int64(statement, 1, Int64(boundedLimit))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = Self.string(statement, column: 0) { frameIDs.append(id) }
                if let image = Self.string(statement, column: 1) { pathsToDelete.append(image) }
                if let thumbnail = Self.string(statement, column: 2) { pathsToDelete.append(thumbnail) }
                if let sessionID = Self.string(statement, column: 3) { affectedSessionIDs.insert(sessionID) }
            }
        }
        guard !frameIDs.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: frameIDs.count).joined(separator: ", ")
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            try withStatement("DELETE FROM frame_search WHERE frame_id IN (\(placeholders))") { statement in
                for (offset, id) in frameIDs.enumerated() {
                    Self.bind(id, at: Int32(offset + 1), to: statement)
                }
                try stepDone(statement)
            }
            try withStatement("DELETE FROM frames WHERE id IN (\(placeholders))") { statement in
                for (offset, id) in frameIDs.enumerated() {
                    Self.bind(id, at: Int32(offset + 1), to: statement)
                }
                try stepDone(statement)
            }
            try VisualEmbeddingSchema.deleteOrphanVectors(on: database)
            try AccessibilitySnapshotSchema.deleteOrphans(on: database)
            try repartitionActivitySessions(affectedSessionIDs)
            let orphanedPaths = try unreferencedMediaPaths(from: pathsToDelete)
            try Self.execute("COMMIT", on: database)
            storedFrameCount -= Int64(frameIDs.count)
            cachedMediaBytes = nil
            try connection.hardenFilePermissions()
            return orphanedPaths
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Removes the oldest screenshot references without deleting their OCR,
    /// metadata, or FTS rows. The caller unlinks the returned encrypted files
    /// only after this transaction commits, so search remains useful under
    /// storage pressure even when an old visual preview has expired.
    public func expireOldestMedia(limit: Int) throws -> [String] {
        let boundedLimit = min(max(limit, 1), 1_000)
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        var frameIDs: [String] = []
        var pathsToDelete: [String] = []
        var affectedSessionIDs: Set<String> = []
        try withStatement(
            """
            SELECT id, image_path, thumbnail_path, activity_session_id
            FROM frames
            WHERE image_path != '' OR thumbnail_path IS NOT NULL
            ORDER BY captured_at ASC, id ASC
            LIMIT ?
            """
        ) { statement in
            sqlite3_bind_int64(statement, 1, Int64(boundedLimit))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = Self.string(statement, column: 0) { frameIDs.append(id) }
                if let image = Self.string(statement, column: 1), !image.isEmpty {
                    pathsToDelete.append(image)
                }
                if let thumbnail = Self.string(statement, column: 2), !thumbnail.isEmpty {
                    pathsToDelete.append(thumbnail)
                }
                if let sessionID = Self.string(statement, column: 3) { affectedSessionIDs.insert(sessionID) }
            }
        }
        guard !frameIDs.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: frameIDs.count).joined(separator: ", ")
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            // An embedding is derived from screenshot pixels. Media expiry is
            // therefore also an erasure boundary for visual intelligence, even
            // though OCR and metadata remain useful and retained.
            try withStatement(
                "DELETE FROM visual_frame_embeddings WHERE frame_id IN (\(placeholders))"
            ) { statement in
                for (offset, id) in frameIDs.enumerated() {
                    Self.bind(id, at: Int32(offset + 1), to: statement)
                }
                try stepDone(statement)
            }
            try VisualEmbeddingSchema.deleteOrphanVectors(on: database)
            try withStatement(
                "UPDATE frames SET image_path = '', thumbnail_path = NULL WHERE id IN (\(placeholders))"
            ) { statement in
                for (offset, id) in frameIDs.enumerated() {
                    Self.bind(id, at: Int32(offset + 1), to: statement)
                }
                try stepDone(statement)
            }
            try repartitionActivitySessions(affectedSessionIDs)
            let orphanedPaths = try unreferencedMediaPaths(from: pathsToDelete)
            try Self.execute("COMMIT", on: database)
            cachedMediaBytes = nil
            try connection.hardenFilePermissions()
            return orphanedPaths
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Returns only candidate blobs that no surviving frame references. New
    /// content-addressed media can be shared by many frames, so a retention
    /// transaction must not ask the caller to unlink a blob while another row
    /// still points at it.
    private func unreferencedMediaPaths(from candidates: [String]) throws -> [String] {
        var seen: Set<String> = []
        let uniqueCandidates = candidates.filter { path in
            !path.isEmpty && seen.insert(path).inserted
        }
        guard !uniqueCandidates.isEmpty else { return [] }

        var referenced: Set<String> = []
        // Each candidate is bound twice. Staying below SQLite's traditional
        // 999-variable ceiling keeps this compatible with existing vaults.
        let batchSize = 400
        for start in stride(from: 0, to: uniqueCandidates.count, by: batchSize) {
            let end = min(start + batchSize, uniqueCandidates.count)
            let batch = Array(uniqueCandidates[start..<end])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            try withStatement(
                """
                SELECT image_path
                FROM frames
                WHERE image_path IN (\(placeholders)) AND image_path != ''
                UNION
                SELECT thumbnail_path
                FROM frames
                WHERE thumbnail_path IN (\(placeholders)) AND thumbnail_path IS NOT NULL
                """
            ) { statement in
                for (offset, path) in batch.enumerated() {
                    Self.bind(path, at: Int32(offset + 1), to: statement)
                    Self.bind(path, at: Int32(batch.count + offset + 1), to: statement)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let path = Self.string(statement, column: 0), !path.isEmpty {
                        referenced.insert(path)
                    }
                }
            }
        }
        return uniqueCandidates.filter { !referenced.contains($0) }
    }

    public func statistics() throws -> StoreStatistics {
        // Statistics runs after every persisted capture, so it must stay
        // O(log n): the maintained row count replaces COUNT(*) over encrypted
        // pages, and each boundary date is one probe of frames_captured_at.
        let oldest = try boundaryCapturedAt(order: "ASC")
        let newest = try boundaryCapturedAt(order: "DESC")
        let databaseBytes = Self.fileBytes(at: paths.database)
            + Self.fileBytes(at: URL(fileURLWithPath: paths.database.path + "-wal"))
        let mediaBytes: Int64
        let now = ContinuousClock.now
        if let cached = cachedMediaBytes,
           now - cached.measuredAt < Self.mediaBytesCacheLifetime {
            mediaBytes = cached.value
        } else {
            mediaBytes = Self.directoryBytes(at: paths.media) + Self.directoryBytes(at: paths.thumbnails)
            cachedMediaBytes = (mediaBytes, now)
        }
        return StoreStatistics(
            frameCount: Int(storedFrameCount),
            oldestCapture: oldest,
            newestCapture: newest,
            databaseBytes: databaseBytes,
            mediaBytes: mediaBytes
        )
    }

    private func boundaryCapturedAt(order: String) throws -> Date? {
        let sql = "SELECT captured_at FROM frames ORDER BY captured_at \(order), id \(order) LIMIT 1"
        return try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    public func activitySessions(_ query: ActivitySessionQuery) throws -> [ActivitySessionSummary] {
        if let startDate = query.startDate,
           let endDate = query.endDate,
           startDate > endDate {
            throw PassageError.invalidQuery("Session start date must not be later than its end date.")
        }
        var clauses = ["1 = 1"]
        var values: [BoundValue] = []
        if let startDate = query.startDate {
            clauses.append("s.ended_at >= ?")
            values.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = query.endDate {
            clauses.append("s.started_at <= ?")
            values.append(.double(endDate.timeIntervalSince1970))
        }
        if !query.includeSensitive {
            clauses.append("s.contains_sensitive = 0")
        }
        values.append(.integer(Int64(min(max(query.limit, 1), 100))))
        return try readActivitySessionSummaries(
            where: clauses.joined(separator: " AND "),
            values: values,
            limitPlaceholder: true
        )
    }

    public func activitySession(
        id: ActivitySessionID,
        momentLimit: Int
    ) throws -> ActivitySessionDetail? {
        guard !id.rawValue.isEmpty else {
            throw PassageError.invalidQuery("Activity session ID must not be empty.")
        }
        let summaries = try readActivitySessionSummaries(
            where: "s.id = ?",
            values: [.text(id.rawValue)],
            limitPlaceholder: false
        )
        guard let summary = summaries.first else { return nil }
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   f.image_path, f.thumbnail_path, substr(f.ocr_text, 1, 240), 0.0,
                   f.is_sensitive, f.activity_session_id
            FROM frames f
            WHERE f.activity_session_id = ?
            ORDER BY f.captured_at DESC, f.id DESC
            LIMIT ?
            """
        let moments = try readHits(
            sql: sql,
            values: [
                .text(id.rawValue),
                .integer(Int64(min(max(momentLimit, 1), 100))),
            ]
        )
        return ActivitySessionDetail(summary: summary, moments: moments)
    }

    private func newestFrameCursor() throws -> FrameOrderCursor? {
        try withStatement(
            "SELECT id, captured_at FROM frames ORDER BY captured_at DESC, id DESC LIMIT 1"
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return FrameOrderCursor(
                id: Self.string(statement, column: 0) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            )
        }
    }

    private func latestActivitySessionCursor() throws -> StoredActivitySessionCursor? {
        try withStatement(
            """
            SELECT id, ended_at, representative_frame_id, representative_score,
                   representative_has_media
            FROM activity_sessions
            ORDER BY ended_at DESC, id DESC
            LIMIT 1
            """
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredActivitySessionCursor(
                id: ActivitySessionID(rawValue: Self.string(statement, column: 0) ?? ""),
                endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                representativeFrameID: Self.string(statement, column: 2) ?? "",
                representativeScore: sqlite3_column_double(statement, 3),
                representativeHasMedia: Self.bool(statement, column: 4)
            )
        }
    }

    private static func updateActivitySessionFastPath(
        sessionID: ActivitySessionID,
        frame: FrameDocument,
        previous: StoredActivitySessionCursor?,
        insertStatement: OpaquePointer,
        updateStatement: OpaquePointer,
        connectionLease: SQLCipherConnection.Lease
    ) throws -> StoredActivitySessionCursor {
        try Self.writeActivitySession(
            sessionID: sessionID,
            frame: SessionFrameRecord(frame),
            previous: previous,
            insertStatement: insertStatement,
            updateStatement: updateStatement,
            database: connectionLease.pointer
        )
    }

    /// Rebuilds only sessions touched by retention. The first surviving segment
    /// keeps its original stable ID; deleting a middle range creates a new ID for
    /// each newly separated tail segment.
    private func repartitionActivitySessions(_ identifiers: Set<String>) throws {
        guard !identifiers.isEmpty else { return }
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        let frameUpdate = try Self.prepare(
            "UPDATE frames SET activity_session_id = ? WHERE id = ?",
            on: database
        )
        let sessionDelete = try Self.prepare(
            "DELETE FROM activity_sessions WHERE id = ?",
            on: database
        )
        let sessionInsert = try Self.prepare(
            """
            INSERT INTO activity_sessions (
                id, started_at, ended_at, frame_count, title,
                latest_application_name, latest_bundle_identifier, latest_domain,
                latest_url, latest_frame_id, representative_frame_id,
                representative_score, representative_has_media, contains_sensitive
            ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        )
        let sessionUpdate = try Self.prepare(
            """
            UPDATE activity_sessions
            SET ended_at = ?, frame_count = frame_count + 1, title = ?,
                latest_application_name = ?, latest_bundle_identifier = ?, latest_domain = ?,
                latest_url = COALESCE(?, latest_url), latest_frame_id = ?,
                representative_frame_id = ?, representative_score = ?,
                representative_has_media = ?,
                contains_sensitive = MAX(contains_sensitive, ?)
            WHERE id = ?
            """,
            on: database
        )
        defer {
            sqlite3_finalize(frameUpdate)
            sqlite3_finalize(sessionDelete)
            sqlite3_finalize(sessionInsert)
            sqlite3_finalize(sessionUpdate)
        }

        for originalID in identifiers.sorted() {
            let records = try sessionFrameRecords(id: originalID)
            Self.bind(originalID, at: 1, to: sessionDelete)
            try Self.stepDone(sessionDelete, database: database)
            sqlite3_reset(sessionDelete)
            sqlite3_clear_bindings(sessionDelete)

            var cursor: StoredActivitySessionCursor?
            var previousDate: Date?
            for (index, record) in records.enumerated() {
                let continuesCurrent = previousDate.map {
                    record.capturedAt.timeIntervalSince($0) < Self.activitySessionGap
                } ?? false
                let sessionID: ActivitySessionID
                if index == 0 {
                    sessionID = ActivitySessionID(rawValue: originalID)
                } else if continuesCurrent, let current = cursor?.id {
                    sessionID = current
                } else {
                    sessionID = ActivitySessionID(rawValue: record.id)
                    cursor = nil
                }

                Self.bind(sessionID.rawValue, at: 1, to: frameUpdate)
                Self.bind(record.id, at: 2, to: frameUpdate)
                try Self.stepDone(frameUpdate, database: database)
                sqlite3_reset(frameUpdate)
                sqlite3_clear_bindings(frameUpdate)

                cursor = try Self.writeActivitySession(
                    sessionID: sessionID,
                    frame: record,
                    previous: cursor?.id == sessionID ? cursor : nil,
                    insertStatement: sessionInsert,
                    updateStatement: sessionUpdate,
                    database: database
                )
                previousDate = record.capturedAt
            }
        }
    }

    private func sessionFrameRecords(id: String) throws -> [SessionFrameRecord] {
        try withStatement(
            """
            SELECT id, captured_at, application_name, bundle_identifier, window_title,
                   url, domain, image_path, thumbnail_path, change_score, is_sensitive
            FROM frames
            WHERE activity_session_id = ?
            ORDER BY captured_at ASC, id ASC
            """
        ) { statement in
            Self.bind(id, at: 1, to: statement)
            var records: [SessionFrameRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(SessionFrameRecord(
                    id: Self.string(statement, column: 0) ?? "",
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    applicationName: Self.string(statement, column: 2) ?? "Unknown",
                    bundleIdentifier: Self.string(statement, column: 3),
                    windowTitle: Self.string(statement, column: 4),
                    url: Self.string(statement, column: 5).flatMap(URL.init(string:)),
                    domain: Self.string(statement, column: 6),
                    imagePath: Self.string(statement, column: 7) ?? "",
                    thumbnailPath: Self.string(statement, column: 8),
                    changeScore: sqlite3_column_double(statement, 9),
                    isSensitive: Self.bool(statement, column: 10)
                ))
            }
            return records
        }
    }

    private func readActivitySessionSummaries(
        where predicate: String,
        values: [BoundValue],
        limitPlaceholder: Bool
    ) throws -> [ActivitySessionSummary] {
        let sql = """
            SELECT s.id, s.started_at, s.ended_at, s.frame_count, s.title,
                   s.latest_application_name, s.latest_bundle_identifier,
                   s.latest_domain, s.latest_url, s.latest_frame_id,
                   s.representative_frame_id, s.contains_sensitive,
                   representative.thumbnail_path, substr(latest.ocr_text, 1, 240)
            FROM activity_sessions s
            JOIN frames latest ON latest.id = s.latest_frame_id
            JOIN frames representative ON representative.id = s.representative_frame_id
            WHERE \(predicate)
            ORDER BY s.ended_at DESC, s.id DESC
            \(limitPlaceholder ? "LIMIT ?" : "LIMIT 1")
            """
        return try withStatement(sql) { statement in
            for (offset, value) in values.enumerated() {
                value.bind(at: Int32(offset + 1), to: statement)
            }
            var summaries: [ActivitySessionSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let applicationName = Self.string(statement, column: 5) ?? "Unknown"
                let url = Self.string(statement, column: 8).flatMap(URL.init(string:))
                summaries.append(ActivitySessionSummary(
                    id: ActivitySessionID(rawValue: Self.string(statement, column: 0) ?? ""),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    frameCount: Int(sqlite3_column_int64(statement, 3)),
                    title: Self.string(statement, column: 4) ?? applicationName,
                    latestApplicationName: applicationName,
                    latestBundleIdentifier: Self.string(statement, column: 6),
                    latestDomain: Self.string(statement, column: 7),
                    representativeFrameID: FrameID(
                        rawValue: Self.string(statement, column: 10) ?? ""
                    ),
                    representativeThumbnailRelativePath: Self.string(statement, column: 12),
                    latestFrameID: FrameID(rawValue: Self.string(statement, column: 9) ?? ""),
                    latestSnippet: Self.string(statement, column: 13) ?? "",
                    resumeTarget: ActivityResumeTarget(
                        url: url,
                        bundleIdentifier: Self.string(statement, column: 6),
                        applicationName: applicationName
                    ),
                    containsSensitive: Self.bool(statement, column: 11)
                ))
            }
            return summaries
        }
    }

    private func recentMatching(
        _ query: SearchQuery,
        includeSensitive: Bool
    ) throws -> [SearchHit] {
        var clauses = ["1 = 1"]
        var values: [BoundValue] = []
        appendFilters(query, clauses: &clauses, values: &values)
        if !includeSensitive {
            clauses.append(Self.agentSafePrivacyPredicate(frameAlias: "f"))
        }
        let sql = """
            SELECT f.id, f.captured_at, f.application_name, f.bundle_identifier,
                   f.window_title, f.url, f.domain, f.display_id, f.window_id,
                   f.window_x, f.window_y, f.window_width, f.window_height,
                   f.image_path, f.thumbnail_path, substr(f.ocr_text, 1, 240), 0.0,
                   f.is_sensitive, f.activity_session_id
            FROM frames f
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY f.captured_at DESC, f.id DESC
            LIMIT ?
            """
        values.append(.integer(Int64(query.limit)))
        return try readHits(sql: sql, values: values)
    }

    /// Agent reads are safe only when the frame is ordinary and its current,
    /// materialized session is known not to contain any sensitive frame.
    private static func agentSafePrivacyPredicate(frameAlias: String) -> String {
        """
        \(frameAlias).is_sensitive = 0
        AND \(frameAlias).activity_session_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM activity_sessions AS agent_safe_session
            WHERE agent_safe_session.id = \(frameAlias).activity_session_id
              AND agent_safe_session.contains_sensitive = 0
        )
        """
    }

    private func appendFilters(
        _ query: SearchQuery,
        clauses: inout [String],
        values: inout [BoundValue]
    ) {
        clauses.append(contentsOf: Self.searchFilterClauses(query, frameAlias: "f"))
        values.append(contentsOf: Self.searchFilterValues(query))
    }

    private nonisolated static func searchFilterClauses(
        _ query: SearchQuery,
        frameAlias: String
    ) -> [String] {
        var clauses = [String]()
        if query.startDate != nil {
            clauses.append("\(frameAlias).captured_at >= ?")
        }
        if query.endDate != nil {
            clauses.append("\(frameAlias).captured_at <= ?")
        }
        if !query.applicationBundleIdentifiers.isEmpty {
            clauses.append(
                "\(frameAlias).bundle_identifier IN (\(Self.placeholders(query.applicationBundleIdentifiers.count)))"
            )
        }
        if !query.domains.isEmpty {
            clauses.append(
                "\(frameAlias).domain COLLATE NOCASE IN (\(Self.placeholders(query.domains.count)))"
            )
        }
        if !query.activitySessionIDs.isEmpty {
            clauses.append(
                "\(frameAlias).activity_session_id IN (\(Self.placeholders(query.activitySessionIDs.count)))"
            )
        }
        return clauses
    }

    private nonisolated static func searchFilterValues(
        _ query: SearchQuery
    ) -> [BoundValue] {
        var values = [BoundValue]()
        if let startDate = query.startDate {
            values.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = query.endDate {
            values.append(.double(endDate.timeIntervalSince1970))
        }
        values.append(contentsOf: query.applicationBundleIdentifiers.sorted().map(BoundValue.text))
        values.append(contentsOf: query.domains.sorted().map(BoundValue.text))
        values.append(contentsOf: query.activitySessionIDs
            .map(\.rawValue)
            .sorted()
            .map(BoundValue.text))
        return values
    }

    private nonisolated static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func appendRecallFilters(
        _ scope: RecallScope,
        excluding excludedFacet: RecallFacetKind?,
        clauses: inout [String],
        values: inout [BoundValue]
    ) {
        if let startDate = scope.startDate {
            clauses.append("f.captured_at >= ?")
            values.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = scope.endDate {
            clauses.append("f.captured_at < ?")
            values.append(.double(endDate.timeIntervalSince1970))
        }
        if excludedFacet != .application, !scope.applicationBundleIdentifiers.isEmpty {
            let sorted = scope.applicationBundleIdentifiers.sorted()
            clauses.append(
                "f.bundle_identifier IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))"
            )
            values.append(contentsOf: sorted.map(BoundValue.text))
        }
        if excludedFacet != .domain, !scope.domains.isEmpty {
            let sorted = scope.domains.sorted()
            clauses.append(
                "f.domain COLLATE NOCASE IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))"
            )
            values.append(contentsOf: sorted.map(BoundValue.text))
        }
    }

    private func readApplicationFacets(
        scope: RecallScope,
        limit: Int
    ) throws -> [RecallApplicationFacet] {
        var clauses = [
            "f.bundle_identifier IS NOT NULL",
            "TRIM(f.bundle_identifier) <> ''",
        ]
        var values = [BoundValue]()
        let usesFullTextSearch = !scope.text.isEmpty
        if usesFullTextSearch {
            clauses.append("frame_search MATCH ?")
            values.append(.text(Self.safeFTSExpression(scope.text)))
        }
        appendRecallFilters(
            scope,
            excluding: .application,
            clauses: &clauses,
            values: &values
        )
        values.append(.integer(Int64(limit)))
        let source: String
        if usesFullTextSearch, hasAlignedSearchRowIDs {
            source = "frame_search JOIN frames f ON f.rowid = frame_search.rowid"
        } else if usesFullTextSearch {
            source = "frame_search JOIN frames f ON f.id = frame_search.frame_id"
        } else {
            source = "frames f"
        }
        let sql = """
            SELECT f.bundle_identifier, MAX(f.application_name), COUNT(*) AS frame_count,
                   MAX(f.captured_at) AS latest_capture
            FROM \(source)
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY f.bundle_identifier
            ORDER BY frame_count DESC, latest_capture DESC, f.bundle_identifier ASC
            LIMIT ?
            """

        return try withStatement(sql) { statement in
            Self.bind(values, to: statement)
            var facets = [RecallApplicationFacet]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    try throwStepError(status)
                }
                let identifier = Self.string(statement, column: 0) ?? ""
                guard !identifier.isEmpty else { continue }
                let name = Self.string(statement, column: 1).flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? identifier
                facets.append(RecallApplicationFacet(
                    bundleIdentifier: identifier,
                    applicationName: name,
                    frameCount: Int(clamping: sqlite3_column_int64(statement, 2))
                ))
            }
            return facets
        }
    }

    private func readMaterializedApplicationFacets(
        limit: Int
    ) throws -> [RecallApplicationFacet] {
        let sql = """
            SELECT bundle_identifier, application_name, frame_count
            FROM recall_application_facets
            ORDER BY frame_count DESC, latest_capture DESC, bundle_identifier ASC
            LIMIT ?
            """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var facets = [RecallApplicationFacet]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return facets }
                guard status == SQLITE_ROW else { try throwStepError(status) }
                let identifier = Self.string(statement, column: 0) ?? ""
                guard !identifier.isEmpty else { continue }
                let name = Self.string(statement, column: 1).flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? identifier
                facets.append(RecallApplicationFacet(
                    bundleIdentifier: identifier,
                    applicationName: name,
                    frameCount: Int(clamping: sqlite3_column_int64(statement, 2))
                ))
            }
        }
    }

    /// Uses only the persisted application identity shared with capture's
    /// browser boundary. This deliberately does not inspect screenshots, OCR,
    /// titles, or URLs to guess whether a moment came from a browser.
    private func readMaterializedBrowserMomentCount() throws -> Int {
        let sql = """
            SELECT bundle_identifier, frame_count
            FROM recall_application_facets
            """
        return try withStatement(sql) { statement in
            var total: Int64 = 0
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return Int(clamping: total) }
                guard status == SQLITE_ROW else { try throwStepError(status) }
                guard ScreenContext.isKnownWebBrowserBundleIdentifier(
                    Self.string(statement, column: 0)
                ) else { continue }
                total += max(sqlite3_column_int64(statement, 1), 0)
            }
        }
    }

    /// Counts every known-browser row in the website facet's drill-sideways
    /// scope. The query is uncapped and applies the same text, time, and app
    /// predicates as domain facets while intentionally ignoring the currently
    /// selected domain values.
    private func readBrowserMomentCount(scope: RecallScope) throws -> Int {
        var clauses = [
            "f.bundle_identifier IS NOT NULL",
            "TRIM(f.bundle_identifier) <> ''",
        ]
        var values = [BoundValue]()
        let usesFullTextSearch = !scope.text.isEmpty
        if usesFullTextSearch {
            clauses.append("frame_search MATCH ?")
            values.append(.text(Self.safeFTSExpression(scope.text)))
        }
        appendRecallFilters(
            scope,
            excluding: .domain,
            clauses: &clauses,
            values: &values
        )
        let source: String
        if usesFullTextSearch, hasAlignedSearchRowIDs {
            source = "frame_search JOIN frames f ON f.rowid = frame_search.rowid"
        } else if usesFullTextSearch {
            source = "frame_search JOIN frames f ON f.id = frame_search.frame_id"
        } else {
            source = "frames f"
        }
        let sql = """
            SELECT f.bundle_identifier, COUNT(*) AS frame_count
            FROM \(source)
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY f.bundle_identifier
            """

        return try withStatement(sql) { statement in
            Self.bind(values, to: statement)
            var total: Int64 = 0
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return Int(clamping: total) }
                guard status == SQLITE_ROW else { try throwStepError(status) }
                guard ScreenContext.isKnownWebBrowserBundleIdentifier(
                    Self.string(statement, column: 0)
                ) else { continue }
                total += max(sqlite3_column_int64(statement, 1), 0)
            }
        }
    }

    private func readDomainFacets(
        scope: RecallScope,
        limit: Int
    ) throws -> [RecallDomainFacet] {
        var clauses = [
            "f.domain IS NOT NULL",
            "TRIM(f.domain) <> ''",
        ]
        var values = [BoundValue]()
        let usesFullTextSearch = !scope.text.isEmpty
        if usesFullTextSearch {
            clauses.append("frame_search MATCH ?")
            values.append(.text(Self.safeFTSExpression(scope.text)))
        }
        appendRecallFilters(
            scope,
            excluding: .domain,
            clauses: &clauses,
            values: &values
        )
        values.append(.integer(Int64(limit)))
        let source: String
        if usesFullTextSearch, hasAlignedSearchRowIDs {
            source = "frame_search JOIN frames f ON f.rowid = frame_search.rowid"
        } else if usesFullTextSearch {
            source = "frame_search JOIN frames f ON f.id = frame_search.frame_id"
        } else {
            source = "frames f"
        }
        let sql = """
            SELECT LOWER(f.domain) AS normalized_domain, COUNT(*) AS frame_count,
                   MAX(f.captured_at) AS latest_capture
            FROM \(source)
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY f.domain COLLATE NOCASE
            ORDER BY frame_count DESC, latest_capture DESC, normalized_domain ASC
            LIMIT ?
            """

        return try withStatement(sql) { statement in
            Self.bind(values, to: statement)
            var facets = [RecallDomainFacet]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    try throwStepError(status)
                }
                let domain = Self.string(statement, column: 0) ?? ""
                guard !domain.isEmpty else { continue }
                facets.append(RecallDomainFacet(
                    domain: domain,
                    frameCount: Int(clamping: sqlite3_column_int64(statement, 1))
                ))
            }
            return facets
        }
    }

    private func readMaterializedDomainFacets(
        limit: Int
    ) throws -> [RecallDomainFacet] {
        let sql = """
            SELECT normalized_domain, frame_count
            FROM recall_domain_facets
            ORDER BY frame_count DESC, latest_capture DESC, normalized_domain ASC
            LIMIT ?
            """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var facets = [RecallDomainFacet]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return facets }
                guard status == SQLITE_ROW else { try throwStepError(status) }
                let domain = Self.string(statement, column: 0) ?? ""
                guard !domain.isEmpty else { continue }
                facets.append(RecallDomainFacet(
                    domain: domain,
                    frameCount: Int(clamping: sqlite3_column_int64(statement, 1))
                ))
            }
        }
    }

    private func readHits(sql: String, values: [BoundValue]) throws -> [SearchHit] {
        try withStatement(sql) { statement in
            Self.bind(values, to: statement)
            var hits: [SearchHit] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    try throwStepError(status)
                }
                let context = ScreenContext(
                    applicationName: Self.string(statement, column: 2) ?? "Unknown",
                    bundleIdentifier: Self.string(statement, column: 3),
                    windowTitle: Self.string(statement, column: 4),
                    url: Self.string(statement, column: 5).flatMap(URL.init(string:)),
                    domain: Self.string(statement, column: 6),
                    displayID: Self.uint32(statement, column: 7),
                    windowID: Self.uint32(statement, column: 8),
                    windowBounds: Self.screenRect(
                        statement,
                        xColumn: 9,
                        yColumn: 10,
                        widthColumn: 11,
                        heightColumn: 12
                    ),
                    isSensitive: Self.bool(statement, column: 17)
                )
                hits.append(SearchHit(
                    id: FrameID(rawValue: Self.string(statement, column: 0) ?? ""),
                    activitySessionID: Self.string(statement, column: 18).map(ActivitySessionID.init(rawValue:)),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    context: context,
                    snippet: Self.string(statement, column: 15) ?? "",
                    imageRelativePath: Self.string(statement, column: 13) ?? "",
                    thumbnailRelativePath: Self.string(statement, column: 14),
                    score: -sqlite3_column_double(statement, 16)
                ))
            }
            return hits
        }
    }

    private func decodeFrame(_ statement: OpaquePointer) throws -> FrameDocument {
        let ocrText = Self.string(statement, column: 13) ?? ""
        let regionData: Data
        if let bytes = sqlite3_column_blob(statement, 14) {
            regionData = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 14)))
        } else {
            regionData = Data()
        }
        let regions = try OCRRegionCodec.decode(regionData, canonicalText: ocrText)
        let accessibilitySnapshot: AccessibilitySnapshot?
        if let bytes = sqlite3_column_blob(statement, 22) {
            let payload = Data(
                bytes: bytes,
                count: Int(sqlite3_column_bytes(statement, 22))
            )
            accessibilitySnapshot = try AccessibilitySnapshotCodec.decode(payload)
        } else {
            accessibilitySnapshot = nil
        }
        let context = ScreenContext(
            applicationName: Self.string(statement, column: 2) ?? "Unknown",
            bundleIdentifier: Self.string(statement, column: 3),
            windowTitle: Self.string(statement, column: 4),
            url: Self.string(statement, column: 5).flatMap(URL.init(string:)),
            domain: Self.string(statement, column: 6),
            displayID: Self.uint32(statement, column: 7),
            windowID: Self.uint32(statement, column: 8),
            windowBounds: Self.screenRect(
                statement,
                xColumn: 9,
                yColumn: 10,
                widthColumn: 11,
                heightColumn: 12
            ),
            isSensitive: Self.bool(statement, column: 21)
        )
        return FrameDocument(
            id: FrameID(rawValue: Self.string(statement, column: 0) ?? ""),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            context: context,
            ocrText: ocrText,
            ocrRegions: regions,
            imageRelativePath: Self.string(statement, column: 15) ?? "",
            thumbnailRelativePath: Self.string(statement, column: 16),
            pixelWidth: Int(sqlite3_column_int64(statement, 17)),
            pixelHeight: Int(sqlite3_column_int64(statement, 18)),
            visualFingerprint: UInt64(bitPattern: sqlite3_column_int64(statement, 19)),
            changeScore: sqlite3_column_double(statement, 20),
            accessibilitySnapshot: accessibilitySnapshot
        )
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        let connectionLease = try activeConnectionLease()
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

    private func withCancellationProgressHandler<T>(
        _ body: () throws -> T
    ) throws -> T {
        let connectionLease = try activeConnectionLease()
        defer { connectionLease.release() }
        let database = connectionLease.pointer
        sqlite3_progress_handler(database, 1_000, { _ in
            withUnsafeCurrentTask { task in
                task?.isCancelled == true ? 1 : 0
            }
        }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        return try body()
    }

    private func throwStepError(_ status: Int32) throws -> Never {
        if status == SQLITE_INTERRUPT || Task<Never, Never>.isCancelled {
            throw CancellationError()
        }
        throw PassageError.database(String(cString: sqlite3_errstr(status)))
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PassageError.database(String(cString: sqlite3_errstr(sqlite3_errcode(
                sqlite3_db_handle(statement)
            ))))
        }
    }

    func activeConnectionLease() throws -> SQLCipherConnection.Lease {
        guard let lease = connection.lease() else {
            throw PassageError.database("Store is closed")
        }
        return lease
    }

    private static func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private static func bind(_ value: Data?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
    }

    private static func bind(_ value: UInt32?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private static func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private static func bind(_ values: [BoundValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            value.bind(at: Int32(offset + 1), to: statement)
        }
    }

    private static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func uint32(_ statement: OpaquePointer, column: Int32) -> UInt32? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0, value <= Int64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    private static func bool(_ statement: OpaquePointer, column: Int32) -> Bool {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return false }
        return sqlite3_column_int64(statement, column) != 0
    }

    private static func screenRect(
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

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw PassageError.database(message)
        }
    }

    private static func writeActivitySession(
        sessionID: ActivitySessionID,
        frame: SessionFrameRecord,
        previous: StoredActivitySessionCursor?,
        insertStatement: OpaquePointer,
        updateStatement: OpaquePointer,
        database: OpaquePointer?
    ) throws -> StoredActivitySessionCursor {
        guard let database else { throw PassageError.database("Store is closed") }
        let hasMedia = !frame.imagePath.isEmpty || !(frame.thumbnailPath?.isEmpty ?? true)
        let shouldReplaceRepresentative = previous.map {
            (hasMedia && !$0.representativeHasMedia)
                || (hasMedia == $0.representativeHasMedia
                    && frame.changeScore >= $0.representativeScore)
        } ?? true
        let representativeFrameID = shouldReplaceRepresentative
            ? frame.id
            : previous?.representativeFrameID ?? frame.id
        let representativeScore = shouldReplaceRepresentative
            ? frame.changeScore
            : previous?.representativeScore ?? frame.changeScore
        let representativeHasMedia = shouldReplaceRepresentative
            ? hasMedia
            : previous?.representativeHasMedia ?? hasMedia
        let title = sessionTitle(for: frame)
        let safeURL = ActivityResumeTarget.safeWebURL(frame.url)?.absoluteString

        if previous == nil {
            bind(sessionID.rawValue, at: 1, to: insertStatement)
            sqlite3_bind_double(insertStatement, 2, frame.capturedAt.timeIntervalSince1970)
            sqlite3_bind_double(insertStatement, 3, frame.capturedAt.timeIntervalSince1970)
            bind(title, at: 4, to: insertStatement)
            bind(frame.applicationName, at: 5, to: insertStatement)
            bind(frame.bundleIdentifier, at: 6, to: insertStatement)
            bind(frame.domain, at: 7, to: insertStatement)
            bind(safeURL, at: 8, to: insertStatement)
            bind(frame.id, at: 9, to: insertStatement)
            bind(representativeFrameID, at: 10, to: insertStatement)
            sqlite3_bind_double(insertStatement, 11, representativeScore)
            sqlite3_bind_int(insertStatement, 12, representativeHasMedia ? 1 : 0)
            sqlite3_bind_int(insertStatement, 13, frame.isSensitive ? 1 : 0)
            try stepDone(insertStatement, database: database)
            sqlite3_reset(insertStatement)
            sqlite3_clear_bindings(insertStatement)
        } else {
            sqlite3_bind_double(updateStatement, 1, frame.capturedAt.timeIntervalSince1970)
            bind(title, at: 2, to: updateStatement)
            bind(frame.applicationName, at: 3, to: updateStatement)
            bind(frame.bundleIdentifier, at: 4, to: updateStatement)
            bind(frame.domain, at: 5, to: updateStatement)
            bind(safeURL, at: 6, to: updateStatement)
            bind(frame.id, at: 7, to: updateStatement)
            bind(representativeFrameID, at: 8, to: updateStatement)
            sqlite3_bind_double(updateStatement, 9, representativeScore)
            sqlite3_bind_int(updateStatement, 10, representativeHasMedia ? 1 : 0)
            sqlite3_bind_int(updateStatement, 11, frame.isSensitive ? 1 : 0)
            bind(sessionID.rawValue, at: 12, to: updateStatement)
            try stepDone(updateStatement, database: database)
            sqlite3_reset(updateStatement)
            sqlite3_clear_bindings(updateStatement)
        }

        return StoredActivitySessionCursor(
            id: sessionID,
            endedAt: frame.capturedAt,
            representativeFrameID: representativeFrameID,
            representativeScore: representativeScore,
            representativeHasMedia: representativeHasMedia
        )
    }

    /// Rebuilds deterministic membership without holding the full history in
    /// process memory. This runs once for v3 migration and only on the rare path
    /// where an imported frame precedes Passage's current newest frame.
    private static func rebuildAllActivitySessions(on database: OpaquePointer) throws {
        try execute("DELETE FROM activity_sessions", on: database)
        try execute("UPDATE frames SET activity_session_id = NULL", on: database)

        let pageSQL = """
            SELECT id, captured_at, application_name, bundle_identifier, window_title,
                   url, domain, image_path, thumbnail_path, change_score, is_sensitive
            FROM frames
            WHERE captured_at > ? OR (captured_at = ? AND id > ?)
            ORDER BY captured_at ASC, id ASC
            LIMIT 2048
            """
        let frameUpdate = try prepare(
            "UPDATE frames SET activity_session_id = ? WHERE id = ?",
            on: database
        )
        let sessionInsert = try prepare(
            """
            INSERT INTO activity_sessions (
                id, started_at, ended_at, frame_count, title,
                latest_application_name, latest_bundle_identifier, latest_domain,
                latest_url, latest_frame_id, representative_frame_id,
                representative_score, representative_has_media, contains_sensitive
            ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        )
        let sessionUpdate = try prepare(
            """
            UPDATE activity_sessions
            SET ended_at = ?, frame_count = frame_count + 1, title = ?,
                latest_application_name = ?, latest_bundle_identifier = ?, latest_domain = ?,
                latest_url = COALESCE(?, latest_url), latest_frame_id = ?,
                representative_frame_id = ?, representative_score = ?,
                representative_has_media = ?,
                contains_sensitive = MAX(contains_sensitive, ?)
            WHERE id = ?
            """,
            on: database
        )
        defer {
            sqlite3_finalize(frameUpdate)
            sqlite3_finalize(sessionInsert)
            sqlite3_finalize(sessionUpdate)
        }

        var pageAfterTime = -Double.greatestFiniteMagnitude
        var pageAfterID = ""
        var previousFrameDate: Date?
        var sessionCursor: StoredActivitySessionCursor?

        while true {
            let pageStatement = try prepare(pageSQL, on: database)
            sqlite3_bind_double(pageStatement, 1, pageAfterTime)
            sqlite3_bind_double(pageStatement, 2, pageAfterTime)
            bind(pageAfterID, at: 3, to: pageStatement)
            var records: [SessionFrameRecord] = []
            while sqlite3_step(pageStatement) == SQLITE_ROW {
                records.append(SessionFrameRecord(
                    id: string(pageStatement, column: 0) ?? "",
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(pageStatement, 1)),
                    applicationName: string(pageStatement, column: 2) ?? "Unknown",
                    bundleIdentifier: string(pageStatement, column: 3),
                    windowTitle: string(pageStatement, column: 4),
                    url: string(pageStatement, column: 5).flatMap(URL.init(string:)),
                    domain: string(pageStatement, column: 6),
                    imagePath: string(pageStatement, column: 7) ?? "",
                    thumbnailPath: string(pageStatement, column: 8),
                    changeScore: sqlite3_column_double(pageStatement, 9),
                    isSensitive: bool(pageStatement, column: 10)
                ))
            }
            sqlite3_finalize(pageStatement)
            guard !records.isEmpty else { break }

            for record in records {
                let continuesCurrent = previousFrameDate.map {
                    record.capturedAt.timeIntervalSince($0) < activitySessionGap
                } ?? false
                let sessionID = continuesCurrent
                    ? sessionCursor?.id ?? ActivitySessionID(rawValue: record.id)
                    : ActivitySessionID(rawValue: record.id)
                if !continuesCurrent { sessionCursor = nil }

                bind(sessionID.rawValue, at: 1, to: frameUpdate)
                bind(record.id, at: 2, to: frameUpdate)
                try stepDone(frameUpdate, database: database)
                sqlite3_reset(frameUpdate)
                sqlite3_clear_bindings(frameUpdate)

                sessionCursor = try writeActivitySession(
                    sessionID: sessionID,
                    frame: record,
                    previous: sessionCursor,
                    insertStatement: sessionInsert,
                    updateStatement: sessionUpdate,
                    database: database
                )
                previousFrameDate = record.capturedAt
            }
            pageAfterTime = records.last?.capturedAt.timeIntervalSince1970 ?? pageAfterTime
            pageAfterID = records.last?.id ?? pageAfterID
        }
    }

    private static func sessionTitle(for frame: SessionFrameRecord) -> String {
        for candidate in [frame.windowTitle, frame.domain, frame.applicationName] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return String(trimmed.prefix(240)) }
        }
        return "Untitled activity"
    }

    private static func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private static func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func metadataValue(key: String, database: OpaquePointer) throws -> String? {
        let statement = try prepare(
            "SELECT value FROM store_metadata WHERE key = ? LIMIT 1",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return string(statement, column: 0)
    }

    private static func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    /// Reserves a monotonic, transaction-bound range for one canonical batch.
    /// `insertBatch` already holds `BEGIN IMMEDIATE`, so concurrent writers can
    /// never observe or reuse a partially consumed range and rollback restores
    /// the sequence along with the frame inserts.
    private static func reserveFrameKeys(
        count: Int,
        on database: OpaquePointer
    ) throws -> Int64 {
        guard count > 0 else {
            throw PassageError.database("Cannot reserve an empty frame-key range.")
        }
        let first = try scalarInt(
            "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
            database: database
        )
        let increment = Int64(count)
        guard first > 0, increment > 0, first <= Int64.max - increment else {
            throw PassageError.database("Canonical frame-key sequence is exhausted.")
        }
        let update = try prepare(
            "UPDATE frame_key_sequence SET next_key = ? WHERE singleton = 1 AND next_key = ?",
            on: database
        )
        defer { sqlite3_finalize(update) }
        sqlite3_bind_int64(update, 1, first + increment)
        sqlite3_bind_int64(update, 2, first)
        try stepDone(update, database: database)
        guard sqlite3_changes(database) == 1 else {
            throw PassageError.database("Canonical frame-key reservation changed concurrently.")
        }
        return first
    }

    /// Adds the named identity used by rebuildable shadows. Hidden SQLite
    /// rowids are an FTS optimization, not a durable identity contract across
    /// copy/export tools. The column, backfill, uniqueness boundary, sequence,
    /// and fallback triggers are installed in one crash-rollback-safe writer
    /// transaction.
    private static func migrateStableFrameKeys(on database: OpaquePointer) throws {
        let marker = try metadataValue(
            key: "frame_key_schema_version",
            database: database
        )
        let existingColumns = try columnNames(in: "frames", database: database)
        let supportObjectCount = try scalarInt(
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE (type = 'table' AND name = 'frame_key_sequence')
               OR (type = 'index' AND name = 'frames_frame_key')
               OR (type = 'trigger' AND name IN (
                    'frames_assign_frame_key',
                    'frames_advance_frame_key_sequence',
                    'frames_reject_frame_key_update'
               ))
            """,
            database: database
        )
        if marker == "1",
           existingColumns.contains("frame_key"),
           supportObjectCount == 5,
           try scalarInt(
               "SELECT COUNT(*) FROM frame_key_sequence WHERE singleton = 1",
               database: database
           ) == 1 {
            // The UNIQUE index proves duplicate freedom. These two indexed
            // probes prove the additive column has no legacy/invalid holes.
            let hasInvalidKey = try scalarInt(
                """
                SELECT
                    EXISTS(
                        SELECT 1 FROM frames INDEXED BY frames_frame_key
                        WHERE frame_key IS NULL LIMIT 1
                    )
                    OR EXISTS(
                        SELECT 1 FROM frames INDEXED BY frames_frame_key
                        WHERE frame_key <= 0 LIMIT 1
                    )
                """,
                database: database
            ) != 0
            if !hasInvalidKey {
                let maximumKey = try scalarInt(
                    "SELECT COALESCE(MAX(frame_key), 0) FROM frames INDEXED BY frames_frame_key",
                    database: database
                )
                let nextKey = try scalarInt(
                    "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
                    database: database
                )
                guard maximumKey < Int64.max, nextKey < Int64.max else {
                    throw PassageError.database("Canonical frame-key sequence is exhausted.")
                }
                if nextKey > maximumKey { return }

                // Repair a stale sequence monotonically under the same writer
                // lock used by batch reservation. No frame scan/backfill or
                // trigger recreation is needed on this completed schema path.
                try execute("BEGIN IMMEDIATE", on: database)
                do {
                    let lockedMaximum = try scalarInt(
                        "SELECT COALESCE(MAX(frame_key), 0) FROM frames INDEXED BY frames_frame_key",
                        database: database
                    )
                    let lockedNext = try scalarInt(
                        "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
                        database: database
                    )
                    guard lockedMaximum < Int64.max, lockedNext < Int64.max else {
                        throw PassageError.database(
                            "Canonical frame-key sequence is exhausted."
                        )
                    }
                    if lockedNext <= lockedMaximum {
                        let repair = try prepare(
                            "UPDATE frame_key_sequence SET next_key = ? WHERE singleton = 1",
                            on: database
                        )
                        defer { sqlite3_finalize(repair) }
                        sqlite3_bind_int64(repair, 1, lockedMaximum + 1)
                        try stepDone(repair, database: database)
                    }
                    try execute("COMMIT", on: database)
                    return
                } catch {
                    try? execute("ROLLBACK", on: database)
                    throw error
                }
            }
        }

        try execute("BEGIN IMMEDIATE", on: database)
        do {
            var columns = try columnNames(in: "frames", database: database)
            var addedFrameKeyColumn = false
            if !columns.contains("frame_key") {
                try execute("ALTER TABLE frames ADD COLUMN frame_key INTEGER", on: database)
                columns.insert("frame_key")
                addedFrameKeyColumn = true
            }
            guard columns.contains("frame_key") else {
                throw PassageError.database("Canonical frame-key column is unavailable.")
            }

            try execute(
                """
                CREATE TABLE IF NOT EXISTS frame_key_sequence (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                    next_key INTEGER NOT NULL
                        CHECK(typeof(next_key) = 'integer' AND next_key > 0)
                );
                INSERT OR IGNORE INTO frame_key_sequence(singleton, next_key)
                VALUES (1, 1);
                """,
                on: database
            )

            var nextKey = max(
                try scalarInt(
                    "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
                    database: database
                ),
                try scalarInt(
                    "SELECT COALESCE(MAX(frame_key), 0) + 1 FROM frames",
                    database: database
                )
            )
            guard nextKey > 0, nextKey < Int64.max else {
                throw PassageError.database("Canonical frame-key sequence is exhausted.")
            }

            let canUseRowIDBackfill = try addedFrameKeyColumn
                && scalarInt(
                    "SELECT NOT EXISTS(SELECT 1 FROM frames WHERE rowid <= 0 LIMIT 1)",
                    database: database
                ) == 1
            if canUseRowIDBackfill {
                // A newly-added column is NULL for every legacy row. Reusing
                // the already-unique positive rowid values performs the 1M-row
                // migration as one set operation instead of retaining a
                // million identifiers and issuing a million UPDATE statements.
                let maximumRowID = try scalarInt(
                    "SELECT COALESCE(MAX(rowid), 0) FROM frames",
                    database: database
                )
                guard maximumRowID < Int64.max else {
                    throw PassageError.database("Canonical frame-key backfill is exhausted.")
                }
                try execute(
                    "UPDATE frames SET frame_key = rowid WHERE frame_key IS NULL",
                    on: database
                )
                nextKey = maximumRowID + 1
            } else {
                // A partially repaired vault can contain arbitrary explicit
                // keys. Preserve them and fill only its holes monotonically.
                let missing = try prepare(
                    "SELECT rowid FROM frames WHERE frame_key IS NULL ORDER BY rowid ASC",
                    on: database
                )
                var missingRowIDs = [Int64]()
                while true {
                    let status = sqlite3_step(missing)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else {
                        sqlite3_finalize(missing)
                        throw PassageError.database(
                            String(cString: sqlite3_errmsg(database))
                        )
                    }
                    missingRowIDs.append(sqlite3_column_int64(missing, 0))
                }
                sqlite3_finalize(missing)
                let assign = try prepare(
                    "UPDATE frames SET frame_key = ? WHERE rowid = ? AND frame_key IS NULL",
                    on: database
                )
                defer { sqlite3_finalize(assign) }
                for rowID in missingRowIDs {
                    guard nextKey < Int64.max else {
                        throw PassageError.database(
                            "Canonical frame-key backfill is exhausted."
                        )
                    }
                    sqlite3_bind_int64(assign, 1, nextKey)
                    sqlite3_bind_int64(assign, 2, rowID)
                    try stepDone(assign, database: database)
                    guard sqlite3_changes(database) == 1 else {
                        throw PassageError.database(
                            "Canonical frame-key backfill lost its target."
                        )
                    }
                    sqlite3_reset(assign)
                    sqlite3_clear_bindings(assign)
                    nextKey += 1
                }
            }

            try execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS frames_frame_key ON frames(frame_key)",
                on: database
            )
            let sequenceUpdate = try prepare(
                "UPDATE frame_key_sequence SET next_key = ? WHERE singleton = 1",
                on: database
            )
            defer { sqlite3_finalize(sequenceUpdate) }
            sqlite3_bind_int64(sequenceUpdate, 1, nextKey)
            try stepDone(sequenceUpdate, database: database)

            try execute(
                """
                DROP TRIGGER IF EXISTS frames_assign_frame_key;
                DROP TRIGGER IF EXISTS frames_advance_frame_key_sequence;
                DROP TRIGGER IF EXISTS frames_reject_frame_key_update;

                CREATE TRIGGER frames_assign_frame_key
                AFTER INSERT ON frames
                WHEN NEW.frame_key IS NULL
                BEGIN
                    SELECT CASE
                        WHEN (SELECT next_key FROM frame_key_sequence WHERE singleton = 1)
                             >= 9223372036854775807
                        THEN RAISE(ABORT, 'canonical frame-key sequence exhausted')
                    END;
                    UPDATE frame_key_sequence
                    SET next_key = next_key + 1
                    WHERE singleton = 1;
                    UPDATE frames
                    SET frame_key = (
                        SELECT next_key - 1 FROM frame_key_sequence WHERE singleton = 1
                    )
                    WHERE rowid = NEW.rowid AND frame_key IS NULL;
                    SELECT CASE
                        WHEN NOT EXISTS (
                            SELECT 1 FROM frames
                            WHERE rowid = NEW.rowid AND frame_key IS NOT NULL
                        )
                        THEN RAISE(ABORT, 'canonical frame-key assignment failed')
                    END;
                END;

                CREATE TRIGGER frames_advance_frame_key_sequence
                AFTER INSERT ON frames
                WHEN NEW.frame_key IS NOT NULL
                BEGIN
                    SELECT CASE
                        WHEN NEW.frame_key <= 0
                          OR NEW.frame_key >= 9223372036854775807
                        THEN RAISE(ABORT, 'canonical frame-key sequence exhausted')
                    END;
                    UPDATE frame_key_sequence
                    SET next_key = MAX(next_key, NEW.frame_key + 1)
                    WHERE singleton = 1;
                END;

                CREATE TRIGGER frames_reject_frame_key_update
                BEFORE UPDATE OF frame_key ON frames
                WHEN OLD.frame_key IS NOT NULL OR NEW.frame_key IS NULL
                BEGIN
                    SELECT RAISE(ABORT, 'canonical frame_key is immutable');
                END;
                """,
                on: database
            )

            let canonicalCount = try scalarInt("SELECT COUNT(*) FROM frames", database: database)
            let keyedCount = try scalarInt(
                "SELECT COUNT(frame_key) FROM frames",
                database: database
            )
            let distinctKeyCount = try scalarInt(
                "SELECT COUNT(DISTINCT frame_key) FROM frames",
                database: database
            )
            let maximumKey = try scalarInt(
                "SELECT COALESCE(MAX(frame_key), 0) FROM frames",
                database: database
            )
            let minimumKey = try scalarInt(
                "SELECT COALESCE(MIN(frame_key), 1) FROM frames",
                database: database
            )
            let persistedNextKey = try scalarInt(
                "SELECT next_key FROM frame_key_sequence WHERE singleton = 1",
                database: database
            )
            guard canonicalCount == keyedCount,
                  keyedCount == distinctKeyCount,
                  minimumKey > 0,
                  persistedNextKey > maximumKey else {
                throw PassageError.database("Canonical frame-key migration failed validation.")
            }
            try execute(
                "INSERT OR REPLACE INTO store_metadata(key, value) VALUES ('frame_key_schema_version', '1')",
                on: database
            )
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS frames (
                id TEXT PRIMARY KEY NOT NULL,
                captured_at REAL NOT NULL,
                application_name TEXT NOT NULL,
                bundle_identifier TEXT,
                window_title TEXT,
                url TEXT,
                domain TEXT,
                display_id INTEGER,
                window_id INTEGER,
                window_x REAL,
                window_y REAL,
                window_width REAL,
                window_height REAL,
                ocr_text TEXT NOT NULL,
                ocr_regions BLOB NOT NULL,
                image_path TEXT NOT NULL,
                thumbnail_path TEXT,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                visual_fingerprint INTEGER NOT NULL,
                change_score REAL NOT NULL,
                is_sensitive INTEGER NOT NULL DEFAULT 0,
                activity_session_id TEXT,
                accessibility_snapshot_hash BLOB,
                frame_key INTEGER
            );
            CREATE INDEX IF NOT EXISTS frames_captured_at
                ON frames(captured_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS frames_application
                ON frames(bundle_identifier, captured_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS frames_domain
                ON frames(domain COLLATE NOCASE, captured_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS frames_domain_application_recall
                ON frames(
                    domain COLLATE NOCASE,
                    bundle_identifier,
                    captured_at DESC,
                    id DESC
                );
            CREATE INDEX IF NOT EXISTS frames_image_path
                ON frames(image_path) WHERE image_path != '';
            CREATE INDEX IF NOT EXISTS frames_thumbnail_path
                ON frames(thumbnail_path) WHERE thumbnail_path IS NOT NULL;
            CREATE VIRTUAL TABLE IF NOT EXISTS frame_search USING fts5(
                frame_id UNINDEXED,
                ocr_text,
                window_title,
                application_name,
                url,
                accessibility_text,
                tokenize = 'porter unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS store_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS activity_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                frame_count INTEGER NOT NULL,
                title TEXT NOT NULL,
                latest_application_name TEXT NOT NULL,
                latest_bundle_identifier TEXT,
                latest_domain TEXT,
                latest_url TEXT,
                latest_frame_id TEXT NOT NULL,
                representative_frame_id TEXT NOT NULL,
                representative_score REAL NOT NULL,
                representative_has_media INTEGER NOT NULL,
                contains_sensitive INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS activity_sessions_ended_at
                ON activity_sessions(ended_at DESC, id DESC);
            """, on: database)

        // CREATE TABLE IF NOT EXISTS does not add columns to an existing
        // encrypted vault. Keep this additive migration compatible with both
        // v1 Passage stores and imported legacy plaintext stores.
        let existingColumns = try columnNames(in: "frames", database: database)
        let additions: [(String, String)] = [
            ("display_id", "INTEGER"),
            ("window_id", "INTEGER"),
            ("window_x", "REAL"),
            ("window_y", "REAL"),
            ("window_width", "REAL"),
            ("window_height", "REAL"),
            ("is_sensitive", "INTEGER NOT NULL DEFAULT 0"),
            ("activity_session_id", "TEXT"),
        ]
        for (name, type) in additions where !existingColumns.contains(name) {
            try execute("ALTER TABLE frames ADD COLUMN \(name) \(type)", on: database)
        }
        try execute(
            "CREATE INDEX IF NOT EXISTS frames_activity_session ON frames(activity_session_id, captured_at DESC, id DESC)",
            on: database
        )
        try migrateStableFrameKeys(on: database)

        let schemaVersion = try metadataValue(key: "schema_version", database: database)
        let schemaVersionNumber = schemaVersion.flatMap(Int.init) ?? 0
        let hasUnassignedFrames = try scalarInt(
            "SELECT EXISTS(SELECT 1 FROM frames WHERE activity_session_id IS NULL LIMIT 1)",
            database: database
        ) != 0
        let requiresRecallIndexUpgrade = schemaVersionNumber < 6
        if requiresRecallIndexUpgrade || hasUnassignedFrames {
            try execute("BEGIN IMMEDIATE", on: database)
            do {
                if requiresRecallIndexUpgrade {
                    // Replace the earlier two-column indexes rather than adding
                    // duplicates. The ID suffix makes cursor order deterministic
                    // while preserving the same compact index footprint.
                    try execute("DROP INDEX IF EXISTS frames_captured_at", on: database)
                    try execute("DROP INDEX IF EXISTS frames_application", on: database)
                    try execute("DROP INDEX IF EXISTS frames_domain", on: database)
                    try execute(
                        "CREATE INDEX frames_captured_at ON frames(captured_at DESC, id DESC)",
                        on: database
                    )
                    try execute(
                        "CREATE INDEX frames_application ON frames(bundle_identifier, captured_at DESC, id DESC)",
                        on: database
                    )
                    try execute(
                        "CREATE INDEX frames_domain ON frames(domain COLLATE NOCASE, captured_at DESC, id DESC)",
                        on: database
                    )
                    // Keep the FTS virtual-table rowid identical to its owning
                    // frame rowid. Recall can then join each FTS hit directly to
                    // the encrypted table row without a text-primary-key probe.
                    try execute("DROP TABLE IF EXISTS frame_search", on: database)
                    try execute(
                        """
                        CREATE VIRTUAL TABLE frame_search USING fts5(
                            frame_id UNINDEXED,
                            ocr_text,
                            window_title,
                            application_name,
                            url,
                            tokenize = 'porter unicode61 remove_diacritics 2'
                        )
                        """,
                        on: database
                    )
                    try execute(
                        """
                        INSERT INTO frame_search(
                            rowid, frame_id, ocr_text, window_title, application_name, url
                        )
                        SELECT rowid, id, ocr_text, window_title, application_name, url
                        FROM frames
                        """,
                        on: database
                    )
                }
                if hasUnassignedFrames {
                    try rebuildAllActivitySessions(on: database)
                }
                try execute(
                    "INSERT OR REPLACE INTO store_metadata(key, value) VALUES ('schema_version', '6')",
                    on: database
                )
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }

        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try VisualEmbeddingSchema.migrate(on: database)
            if schemaVersionNumber < VisualEmbeddingSchema.currentVersion {
                try execute(
                    "INSERT OR REPLACE INTO store_metadata(key, value) VALUES ('schema_version', '\(VisualEmbeddingSchema.currentVersion)')",
                    on: database
                )
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }

        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try AccessibilitySnapshotSchema.migrate(on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }

        try migrateRecallFacetTotals(on: database)
        try MemorySegmentIndex.migrate(on: database)
    }

    /// Creates the encrypted, rebuildable totals used only by Recall's empty,
    /// unfiltered browse view. SQLite triggers keep these rows in the same
    /// transaction as every frame insert, delete, or relevant metadata update.
    private static func migrateRecallFacetTotals(on database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS recall_application_facets (
                bundle_identifier TEXT PRIMARY KEY NOT NULL,
                application_name TEXT NOT NULL,
                frame_count INTEGER NOT NULL CHECK(frame_count > 0),
                latest_capture REAL NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS recall_domain_facets (
                normalized_domain TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
                frame_count INTEGER NOT NULL CHECK(frame_count > 0),
                latest_capture REAL NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS recall_application_facets_order
                ON recall_application_facets(
                    frame_count DESC,
                    latest_capture DESC,
                    bundle_identifier ASC,
                    application_name
                );
            CREATE INDEX IF NOT EXISTS recall_domain_facets_order
                ON recall_domain_facets(
                    frame_count DESC,
                    latest_capture DESC,
                    normalized_domain ASC
                );

            DROP TRIGGER IF EXISTS frames_recall_application_insert;
            DROP TRIGGER IF EXISTS frames_recall_application_delete;
            DROP TRIGGER IF EXISTS frames_recall_application_update;
            DROP TRIGGER IF EXISTS frames_recall_domain_insert;
            DROP TRIGGER IF EXISTS frames_recall_domain_delete;
            DROP TRIGGER IF EXISTS frames_recall_domain_update;

            CREATE TRIGGER frames_recall_application_insert
            AFTER INSERT ON frames
            WHEN NEW.bundle_identifier IS NOT NULL
             AND TRIM(NEW.bundle_identifier) <> ''
            BEGIN
                INSERT INTO recall_application_facets(
                    bundle_identifier, application_name, frame_count, latest_capture
                ) VALUES (
                    NEW.bundle_identifier, NEW.application_name, 1, NEW.captured_at
                )
                ON CONFLICT(bundle_identifier) DO UPDATE SET
                    application_name = MAX(application_name, excluded.application_name),
                    frame_count = frame_count + 1,
                    latest_capture = MAX(latest_capture, excluded.latest_capture);
            END;

            CREATE TRIGGER frames_recall_application_delete
            AFTER DELETE ON frames
            WHEN OLD.bundle_identifier IS NOT NULL
             AND TRIM(OLD.bundle_identifier) <> ''
            BEGIN
                DELETE FROM recall_application_facets
                WHERE bundle_identifier = OLD.bundle_identifier
                  AND frame_count = 1;
                UPDATE recall_application_facets
                SET application_name = CASE
                        WHEN OLD.application_name = application_name
                         AND NOT EXISTS (
                            SELECT 1 FROM frames
                            WHERE bundle_identifier = OLD.bundle_identifier
                              AND application_name = OLD.application_name
                            LIMIT 1
                         )
                        THEN COALESCE((
                            SELECT MAX(application_name) FROM frames
                            WHERE bundle_identifier = OLD.bundle_identifier
                        ), application_name)
                        ELSE application_name
                    END,
                    frame_count = frame_count - 1,
                    latest_capture = CASE
                        WHEN OLD.captured_at >= latest_capture
                        THEN COALESCE((
                            SELECT captured_at FROM frames
                            WHERE bundle_identifier = OLD.bundle_identifier
                            ORDER BY captured_at DESC, id DESC
                            LIMIT 1
                        ), latest_capture)
                        ELSE latest_capture
                    END
                WHERE bundle_identifier = OLD.bundle_identifier;
            END;

            CREATE TRIGGER frames_recall_application_update
            AFTER UPDATE OF application_name, bundle_identifier, captured_at ON frames
            BEGIN
                DELETE FROM recall_application_facets
                WHERE OLD.bundle_identifier IS NOT NULL
                  AND TRIM(OLD.bundle_identifier) <> ''
                  AND bundle_identifier = OLD.bundle_identifier
                  AND frame_count = 1;
                UPDATE recall_application_facets
                SET application_name = CASE
                        WHEN OLD.application_name = application_name
                         AND NOT EXISTS (
                            SELECT 1 FROM frames
                            WHERE bundle_identifier = OLD.bundle_identifier
                              AND application_name = OLD.application_name
                            LIMIT 1
                         )
                        THEN COALESCE((
                            SELECT MAX(application_name) FROM frames
                            WHERE bundle_identifier = OLD.bundle_identifier
                        ), application_name)
                        ELSE application_name
                    END,
                    frame_count = frame_count - 1,
                    latest_capture = CASE
                        WHEN OLD.captured_at >= latest_capture
                        THEN COALESCE((
                            SELECT captured_at FROM frames
                            WHERE bundle_identifier = OLD.bundle_identifier
                            ORDER BY captured_at DESC, id DESC
                            LIMIT 1
                        ), latest_capture)
                        ELSE latest_capture
                    END
                WHERE OLD.bundle_identifier IS NOT NULL
                  AND TRIM(OLD.bundle_identifier) <> ''
                  AND bundle_identifier = OLD.bundle_identifier;
                INSERT INTO recall_application_facets(
                    bundle_identifier, application_name, frame_count, latest_capture
                )
                SELECT NEW.bundle_identifier, NEW.application_name, 1, NEW.captured_at
                WHERE NEW.bundle_identifier IS NOT NULL
                  AND TRIM(NEW.bundle_identifier) <> ''
                ON CONFLICT(bundle_identifier) DO UPDATE SET
                    application_name = MAX(application_name, excluded.application_name),
                    frame_count = frame_count + 1,
                    latest_capture = MAX(latest_capture, excluded.latest_capture);
            END;

            CREATE TRIGGER frames_recall_domain_insert
            AFTER INSERT ON frames
            WHEN NEW.domain IS NOT NULL AND TRIM(NEW.domain) <> ''
            BEGIN
                INSERT INTO recall_domain_facets(
                    normalized_domain, frame_count, latest_capture
                ) VALUES (LOWER(NEW.domain), 1, NEW.captured_at)
                ON CONFLICT(normalized_domain) DO UPDATE SET
                    frame_count = frame_count + 1,
                    latest_capture = MAX(latest_capture, excluded.latest_capture);
            END;

            CREATE TRIGGER frames_recall_domain_delete
            AFTER DELETE ON frames
            WHEN OLD.domain IS NOT NULL AND TRIM(OLD.domain) <> ''
            BEGIN
                DELETE FROM recall_domain_facets
                WHERE normalized_domain = LOWER(OLD.domain)
                  AND frame_count = 1;
                UPDATE recall_domain_facets
                SET frame_count = frame_count - 1,
                    latest_capture = CASE
                        WHEN OLD.captured_at >= latest_capture
                        THEN COALESCE((
                            SELECT captured_at FROM frames
                            WHERE domain = OLD.domain COLLATE NOCASE
                            ORDER BY captured_at DESC, id DESC
                            LIMIT 1
                        ), latest_capture)
                        ELSE latest_capture
                    END
                WHERE normalized_domain = LOWER(OLD.domain);
            END;

            CREATE TRIGGER frames_recall_domain_update
            AFTER UPDATE OF domain, captured_at ON frames
            BEGIN
                DELETE FROM recall_domain_facets
                WHERE OLD.domain IS NOT NULL
                  AND TRIM(OLD.domain) <> ''
                  AND normalized_domain = LOWER(OLD.domain)
                  AND frame_count = 1;
                UPDATE recall_domain_facets
                SET frame_count = frame_count - 1,
                    latest_capture = CASE
                        WHEN OLD.captured_at >= latest_capture
                        THEN COALESCE((
                            SELECT captured_at FROM frames
                            WHERE domain = OLD.domain COLLATE NOCASE
                            ORDER BY captured_at DESC, id DESC
                            LIMIT 1
                        ), latest_capture)
                        ELSE latest_capture
                    END
                WHERE OLD.domain IS NOT NULL
                  AND TRIM(OLD.domain) <> ''
                  AND normalized_domain = LOWER(OLD.domain);
                INSERT INTO recall_domain_facets(
                    normalized_domain, frame_count, latest_capture
                )
                SELECT LOWER(NEW.domain), 1, NEW.captured_at
                WHERE NEW.domain IS NOT NULL AND TRIM(NEW.domain) <> ''
                ON CONFLICT(normalized_domain) DO UPDATE SET
                    frame_count = frame_count + 1,
                    latest_capture = MAX(latest_capture, excluded.latest_capture);
            END;
            """,
            on: database
        )

        guard try metadataValue(
            key: recallFacetTotalsMarkerKey,
            database: database
        ) != recallFacetTotalsVersion else { return }

        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try execute(
                """
                DELETE FROM recall_application_facets;
                DELETE FROM recall_domain_facets;
                INSERT INTO recall_application_facets(
                    bundle_identifier, application_name, frame_count, latest_capture
                )
                SELECT bundle_identifier, MAX(application_name), COUNT(*), MAX(captured_at)
                FROM frames
                WHERE bundle_identifier IS NOT NULL
                  AND TRIM(bundle_identifier) <> ''
                GROUP BY bundle_identifier;
                INSERT INTO recall_domain_facets(
                    normalized_domain, frame_count, latest_capture
                )
                SELECT LOWER(domain), COUNT(*), MAX(captured_at)
                FROM frames
                WHERE domain IS NOT NULL AND TRIM(domain) <> ''
                GROUP BY domain COLLATE NOCASE;
                """,
                on: database
            )
            let marker = try prepare(
                "INSERT OR REPLACE INTO store_metadata(key, value) VALUES (?, ?)",
                on: database
            )
            defer { sqlite3_finalize(marker) }
            bind(recallFacetTotalsMarkerKey, at: 1, to: marker)
            bind(recallFacetTotalsVersion, at: 2, to: marker)
            try stepDone(marker, database: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func isUnfilteredBrowseFacetScope(_ scope: RecallScope) -> Bool {
        scope.text.isEmpty
            && scope.startDate == nil
            && scope.endDate == nil
            && scope.applicationBundleIdentifiers.isEmpty
            && scope.domains.isEmpty
    }

    private static func columnNames(
        in table: String,
        database: OpaquePointer
    ) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PassageError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: pointer))
            }
        }
        return names
    }

    private static func ftsExpression(_ query: String) -> String {
        let advancedMarkers = ["\"", "*", "(", ")", " AND ", " OR ", " NOT "]
        if advancedMarkers.contains(where: query.contains) {
            return query
        }
        return query
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }

    /// Recall's user-facing field treats punctuation as a token separator rather
    /// than exposing FTS5's query language. Arbitrary pasted text therefore
    /// cannot become a malformed MATCH expression.
    private static func safeFTSExpression(_ query: String) -> String {
        let tokens = query.split { character in
            !character.isLetter && !character.isNumber
        }
        guard !tokens.isEmpty else {
            return "\"passage_no_searchable_token_7f89d8f5\""
        }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " ")
    }

    private static func validateRecallScope(_ scope: RecallScope) throws {
        if let start = scope.startDate, !start.timeIntervalSince1970.isFinite {
            throw PassageError.invalidQuery("Recall start date must be finite.")
        }
        if let end = scope.endDate, !end.timeIntervalSince1970.isFinite {
            throw PassageError.invalidQuery("Recall end date must be finite.")
        }
        if let start = scope.startDate, let end = scope.endDate, start >= end {
            throw PassageError.invalidQuery(
                "Recall end date must be later than its start date."
            )
        }
    }

    private static func encodeRecallCursor(
        _ position: FrameOrderCursor,
        scope: RecallScope
    ) throws -> RecallCursor {
        let payload = RecallCursorPayload(
            version: 1,
            capturedAt: position.capturedAt.timeIntervalSince1970,
            frameID: position.id,
            scopeFingerprint: try recallScopeFingerprint(scope)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return RecallCursor(token: base64URLEncoded(try encoder.encode(payload)))
    }

    private static func decodeRecallCursor(
        _ cursor: RecallCursor,
        expectedScope: RecallScope
    ) throws -> FrameOrderCursor {
        guard let data = base64URLDecoded(cursor.token),
              let payload = try? JSONDecoder().decode(RecallCursorPayload.self, from: data),
              payload.version == 1,
              payload.capturedAt.isFinite,
              !payload.frameID.isEmpty else {
            throw PassageError.invalidQuery("Recall cursor is malformed or unsupported.")
        }
        guard payload.scopeFingerprint == (try recallScopeFingerprint(expectedScope)) else {
            throw PassageError.invalidQuery(
                "Recall cursor belongs to a different search or filter scope."
            )
        }
        return FrameOrderCursor(
            id: payload.frameID,
            capturedAt: Date(timeIntervalSince1970: payload.capturedAt)
        )
    }

    private static func recallScopeFingerprint(_ scope: RecallScope) throws -> String {
        let payload = RecallScopeFingerprintPayload(
            text: scope.text,
            startDateBits: scope.startDate.map { $0.timeIntervalSince1970.bitPattern },
            endDateBits: scope.endDate.map { $0.timeIntervalSince1970.bitPattern },
            applicationBundleIdentifiers: scope.applicationBundleIdentifiers.sorted(),
            domains: scope.domains.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(payload)
        return Data(SHA256.hash(data: canonical)).base64EncodedString()
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        guard !value.isEmpty else { return nil }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func fileBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func directoryBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

private struct FrameOrderCursor {
    var id: String
    var capturedAt: Date
}

private struct RecallCandidate {
    var rowID: Int64
    var id: String
    var capturedAt: TimeInterval
}

private struct RecallTextMatch {
    var snippet: String
    var relevance: Double
}

private enum RecallFacetKind {
    case application
    case domain
}

private struct RecallCursorPayload: Codable {
    var version: Int
    var capturedAt: TimeInterval
    var frameID: String
    var scopeFingerprint: String
}

private struct RecallScopeFingerprintPayload: Codable {
    var text: String
    var startDateBits: UInt64?
    var endDateBits: UInt64?
    var applicationBundleIdentifiers: [String]
    var domains: [String]
}

private struct StoredActivitySessionCursor {
    var id: ActivitySessionID
    var endedAt: Date
    var representativeFrameID: String
    var representativeScore: Double
    var representativeHasMedia: Bool
}

private struct SessionFrameRecord {
    var id: String
    var capturedAt: Date
    var applicationName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var url: URL?
    var domain: String?
    var imagePath: String
    var thumbnailPath: String?
    var changeScore: Double
    var isSensitive: Bool

    init(
        id: String,
        capturedAt: Date,
        applicationName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        url: URL?,
        domain: String?,
        imagePath: String,
        thumbnailPath: String?,
        changeScore: Double,
        isSensitive: Bool
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.domain = domain
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.changeScore = changeScore
        self.isSensitive = isSensitive
    }

    init(_ frame: FrameDocument) {
        self.init(
            id: frame.id.rawValue,
            capturedAt: frame.capturedAt,
            applicationName: frame.context.applicationName,
            bundleIdentifier: frame.context.bundleIdentifier,
            windowTitle: frame.context.windowTitle,
            url: frame.context.url,
            domain: frame.context.domain,
            imagePath: frame.imageRelativePath,
            thumbnailPath: frame.thumbnailRelativePath,
            changeScore: frame.changeScore,
            isSensitive: frame.context.isSensitive
        )
    }
}

private enum BoundValue {
    case text(String)
    case integer(Int64)
    case double(Double)

    func bind(at index: Int32, to statement: OpaquePointer) {
        switch self {
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        }
    }
}
