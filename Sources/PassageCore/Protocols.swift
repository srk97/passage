import Foundation

public protocol FrameRepository: Sendable {
    func insert(_ frame: FrameDocument) async throws
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func recent(limit: Int) async throws -> [SearchHit]
    func frame(id: FrameID) async throws -> FrameDocument?
    func deleteFrames(olderThan date: Date) async throws -> [String]
    func deleteFrames(from startDate: Date?, through endDate: Date?) async throws -> [String]
    func deleteOldestFrames(limit: Int) async throws -> [String]
    func expireOldestMedia(limit: Int) async throws -> [String]
    func statistics() async throws -> StoreStatistics
}

/// One frame resolved together with its authoritative, currently materialized
/// activity-session identity. Values of this type are safe for agent-facing
/// projection only when produced by `AgentSafeFrameRepository`: constructing a
/// value directly does not perform Passage's privacy checks.
public struct AgentSafeFrameEvidence: Codable, Hashable, Sendable {
    public var frame: FrameDocument
    public var activitySessionID: ActivitySessionID

    public init(frame: FrameDocument, activitySessionID: ActivitySessionID) {
        self.frame = frame
        self.activitySessionID = activitySessionID
    }
}

/// Bounded authoritative resolution for agent-facing retrieval surfaces.
///
/// Implementations must make sensitive and missing identifiers
/// indistinguishable: a returned frame must itself be ordinary, belong to a
/// currently materialized activity session, and that entire session must be
/// ordinary. Batch results preserve the first-occurrence order of the request
/// while removing duplicate identifiers.
public protocol AgentSafeFrameRepository: Sendable {
    /// The raw request is bounded before deduplication. This stays below
    /// SQLite's conservative host-parameter floor and covers Passage's
    /// largest supported agent candidate windows without query chunking.
    static var maximumAgentSafeFrameRequestCount: Int { get }

    func agentSafeFrame(id: FrameID) async throws -> AgentSafeFrameEvidence?

    func agentSafeFrames(ids: [FrameID]) async throws -> [AgentSafeFrameEvidence]
}

/// A deliberately narrow mutation used to repair OCR that was produced by an
/// older, lower-quality recognizer. Implementations must replace the canonical
/// text, compact regions, and search-index row atomically. The fingerprint is
/// an optimistic concurrency guard: a missing, deleted, or changed frame must
/// return `nil` without creating or modifying any record.
public protocol OCRRefinementRepository: Sendable {
    @discardableResult
    func replaceOCR(
        for id: FrameID,
        expectedVisualFingerprint: UInt64,
        text: String,
        regions: [OCRRegion]
    ) async throws -> FrameDocument?
}

/// Full-history navigation is separated from capture's narrow frame contract so
/// capture writers do not acquire UI-oriented paging and facet responsibilities.
public protocol RecallNavigationRepository: Sendable {
    /// Returns newest-first history using a stable `(capturedAt, id)` ordering.
    /// The cursor is exclusive and `limit` is clamped to `1...200`.
    func recall(
        _ scope: RecallScope,
        after cursor: RecallCursor?,
        limit: Int
    ) async throws -> RecallPage

    /// Aggregates filter choices locally. Each facet kind ignores only its own
    /// selected values, allowing users to discover a different app or website.
    /// Implementations should also supply the uncapped known-browser count for
    /// the website facet's drill-sideways scope when they can do so from trusted
    /// persisted app metadata. A missing count means unknown, never zero.
    func recallFacets(
        _ scope: RecallScope,
        limitPerKind: Int
    ) async throws -> RecallFacets
}

/// Relevance-ordered lexical recall for bounded search result sets.
///
/// This is deliberately separate from `RecallNavigationRepository`: browsing
/// needs a stable chronological cursor, while a search that says “Best
/// matches” must preserve the FTS ranking it was given.
public protocol RankedRecallRepository: Sendable {
    func rankedRecall(
        _ scope: RecallScope,
        limit: Int
    ) async throws -> [SearchHit]
}

/// Immutable identity for one compatible image/text embedding space.
///
/// `fingerprint` is the manifest or content pin for the actual model artifacts,
/// while `preprocessingRevision` covers resize, crop, color, and normalization
/// behavior. Changing either creates a different index namespace.
public struct VisualModelIdentity: Codable, Hashable, Sendable {
    public var identifier: String
    public var revision: String
    public var fingerprint: String
    public var preprocessingRevision: String
    public var embeddingDimension: Int

    public init(
        identifier: String,
        revision: String,
        fingerprint: String,
        preprocessingRevision: String,
        embeddingDimension: Int
    ) {
        self.identifier = identifier
        self.revision = revision
        self.fingerprint = fingerprint
        self.preprocessingRevision = preprocessingRevision
        self.embeddingDimension = embeddingDimension
    }
}

/// One normalized image embedding to associate with an existing Passage frame.
public struct VisualEmbeddingWrite: Codable, Hashable, Sendable {
    public var frameID: FrameID
    public var model: VisualModelIdentity
    public var vector: [Float]
    public var indexedAt: Date

    public init(
        frameID: FrameID,
        model: VisualModelIdentity,
        vector: [Float],
        indexedAt: Date = Date()
    ) {
        self.frameID = frameID
        self.model = model
        self.vector = vector
        self.indexedAt = indexedAt
    }
}

public struct VisualEmbeddingWriteSummary: Codable, Hashable, Sendable {
    public var processedFrameCount: Int
    public var insertedAssociationCount: Int
    public var replacedAssociationCount: Int
    public var unchangedAssociationCount: Int
    public var insertedUniqueVectorCount: Int
    public var reusedUniqueVectorCount: Int
    public var reclaimedUniqueVectorCount: Int
    public var storedVectorBytesDelta: Int64

    public init(
        processedFrameCount: Int = 0,
        insertedAssociationCount: Int = 0,
        replacedAssociationCount: Int = 0,
        unchangedAssociationCount: Int = 0,
        insertedUniqueVectorCount: Int = 0,
        reusedUniqueVectorCount: Int = 0,
        reclaimedUniqueVectorCount: Int = 0,
        storedVectorBytesDelta: Int64 = 0
    ) {
        self.processedFrameCount = processedFrameCount
        self.insertedAssociationCount = insertedAssociationCount
        self.replacedAssociationCount = replacedAssociationCount
        self.unchangedAssociationCount = unchangedAssociationCount
        self.insertedUniqueVectorCount = insertedUniqueVectorCount
        self.reusedUniqueVectorCount = reusedUniqueVectorCount
        self.reclaimedUniqueVectorCount = reclaimedUniqueVectorCount
        self.storedVectorBytesDelta = storedVectorBytesDelta
    }
}

public struct VisualEmbeddingQuery: Codable, Hashable, Sendable {
    public var modelFingerprint: String
    public var vector: [Float]
    public var startDate: Date?
    public var endDate: Date?
    public var applicationBundleIdentifiers: Set<String>
    public var domains: Set<String>
    /// Frames that may contribute neither shortlist membership nor a returned
    /// representative. Query-by-example uses this to omit the source memory
    /// without discarding a shared scene vector that has another eligible
    /// retained frame.
    public var excludedFrameIDs: Set<FrameID>
    public var minimumSimilarity: Double
    public var limit: Int
    public var candidateLimit: Int

    public init(
        modelFingerprint: String,
        vector: [Float],
        startDate: Date? = nil,
        endDate: Date? = nil,
        applicationBundleIdentifiers: Set<String> = [],
        domains: Set<String> = [],
        excludedFrameIDs: Set<FrameID> = [],
        minimumSimilarity: Double = -1,
        limit: Int = 50,
        candidateLimit: Int = 2_048
    ) {
        self.modelFingerprint = modelFingerprint
        self.vector = vector
        self.startDate = startDate
        self.endDate = endDate
        self.applicationBundleIdentifiers = Set(
            applicationBundleIdentifiers.compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )
        self.domains = Set(domains.compactMap { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })
        self.excludedFrameIDs = excludedFrameIDs
        self.minimumSimilarity = minimumSimilarity
        self.limit = limit
        self.candidateLimit = candidateLimit
    }
}

/// One bounded, media-ready backfill item. Sensitive frames are never returned.
public struct VisualEmbeddingCandidate: Codable, Hashable, Sendable {
    public var frameID: FrameID
    public var capturedAt: Date
    public var imageRelativePath: String
    public var thumbnailRelativePath: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var visualFingerprint: UInt64
    public var isSensitive: Bool

    public init(
        frameID: FrameID,
        capturedAt: Date,
        imageRelativePath: String,
        thumbnailRelativePath: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        visualFingerprint: UInt64,
        isSensitive: Bool
    ) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.imageRelativePath = imageRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.visualFingerprint = visualFingerprint
        self.isSensitive = isSensitive
    }
}

/// One deduplicated visual result.
///
/// `hit` is the newest non-sensitive frame associated with the matched vector;
/// `associatedFrameCount` says how many retained frames share that scene vector.
/// The plain snippet has no lexical highlight markers. Similarity metadata stays
/// outside `SearchHit` so callers can explicitly label the evidence as visual.
public struct VisualEmbeddingMatch: Codable, Hashable, Sendable {
    public var hit: SearchHit
    public var similarity: Double
    public var maximumSimilarityError: Double
    public var model: VisualModelIdentity
    public var associatedFrameCount: Int
    /// Exact frame fingerprint whose current vector produced this match.
    /// Internal query-time refiners use it as an optimistic concurrency guard;
    /// agent-safe projections deliberately omit it.
    public var sourceVisualFingerprint: UInt64?

    public init(
        hit: SearchHit,
        similarity: Double,
        maximumSimilarityError: Double,
        model: VisualModelIdentity,
        associatedFrameCount: Int,
        sourceVisualFingerprint: UInt64? = nil
    ) {
        self.hit = hit
        self.similarity = similarity
        self.maximumSimilarityError = maximumSimilarityError
        self.model = model
        self.associatedFrameCount = associatedFrameCount
        self.sourceVisualFingerprint = sourceVisualFingerprint
    }
}

public struct VisualEmbeddingCoverage: Codable, Hashable, Sendable {
    public var model: VisualModelIdentity
    public var eligibleFrameCount: Int
    public var indexedEligibleFrameCount: Int
    public var indexedFrameCount: Int
    public var pendingEligibleFrameCount: Int
    public var staleEmbeddingCount: Int
    public var uniqueVectorCount: Int
    public var deduplicatedFrameCount: Int
    public var storedVectorPayloadBytes: Int64
    public var coverageFraction: Double?

    public init(
        model: VisualModelIdentity,
        eligibleFrameCount: Int,
        indexedEligibleFrameCount: Int,
        indexedFrameCount: Int,
        pendingEligibleFrameCount: Int,
        staleEmbeddingCount: Int,
        uniqueVectorCount: Int,
        deduplicatedFrameCount: Int,
        storedVectorPayloadBytes: Int64,
        coverageFraction: Double?
    ) {
        self.model = model
        self.eligibleFrameCount = eligibleFrameCount
        self.indexedEligibleFrameCount = indexedEligibleFrameCount
        self.indexedFrameCount = indexedFrameCount
        self.pendingEligibleFrameCount = pendingEligibleFrameCount
        self.staleEmbeddingCount = staleEmbeddingCount
        self.uniqueVectorCount = uniqueVectorCount
        self.deduplicatedFrameCount = deduplicatedFrameCount
        self.storedVectorPayloadBytes = storedVectorPayloadBytes
        self.coverageFraction = coverageFraction
    }
}

public protocol VisualEmbeddingRepository: Sendable {
    func upsertVisualEmbeddings(
        _ writes: [VisualEmbeddingWrite]
    ) async throws -> VisualEmbeddingWriteSummary

    func nearestVisualEmbeddings(
        _ query: VisualEmbeddingQuery
    ) async throws -> [VisualEmbeddingMatch]

    func visualEmbeddingCoverage(
        for model: VisualModelIdentity
    ) async throws -> VisualEmbeddingCoverage

    func framesNeedingVisualEmbedding(
        for model: VisualModelIdentity,
        limit: Int
    ) async throws -> [VisualEmbeddingCandidate]

    /// Removes one model namespace and all of its frame associations/vectors.
    /// Returns the number of frame associations removed.
    func deleteVisualEmbeddings(modelFingerprint: String) async throws -> Int
}

/// Session reads are deliberately separate from FrameRepository. Capture only
/// needs the narrow frame-write contract, while UI and audited agent surfaces can
/// opt into the richer activity model.
public protocol ActivitySessionRepository: Sendable {
    func activitySessions(_ query: ActivitySessionQuery) async throws -> [ActivitySessionSummary]
    func activitySession(id: ActivitySessionID, momentLimit: Int) async throws -> ActivitySessionDetail?
}

public protocol PrivacyPolicyEvaluating: Sendable {
    func permits(_ context: ScreenContext) async -> Bool
}

public enum PassageError: Error, LocalizedError, Sendable {
    case database(String)
    case capturePermissionDenied
    case captureUnavailable(String)
    case imageEncodingFailed
    case frameNotFound(FrameID)
    case invalidQuery(String)

    public var errorDescription: String? {
        switch self {
        case .database(let message):
            "Database error: \(message)"
        case .capturePermissionDenied:
            "Screen Recording permission is required to remember your screen."
        case .captureUnavailable(let message):
            "Screen capture is unavailable: \(message)"
        case .imageEncodingFailed:
            "The captured image could not be encoded."
        case .frameNotFound(let id):
            "No frame exists with ID \(id.rawValue)."
        case .invalidQuery(let message):
            "Invalid search query: \(message)"
        }
    }
}
