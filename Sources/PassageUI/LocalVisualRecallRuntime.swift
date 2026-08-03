import PassageCore
import PassageStore
import PassageVisualModel
import PassageVisualSearch
import CoreGraphics
import Foundation

protocol PassageAgentVisualSearchServing: Sendable {
    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse
}

protocol PassageVisualRecallServing: PassageAgentVisualSearchServing {
    /// Synchronously revoke encrypted storage capabilities at the session-lock
    /// boundary. Test doubles without a vault can use the default no-op.
    func revoke()
    func indexPersistedFrame(_ frame: FrameDocument) async throws
        -> VisualEmbeddingWriteSummary
    func indexNextBatch(limit: Int) async throws -> VisualIndexingPass
    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse
    /// Query-by-example for Memory Lens. The image exists only for the lifetime
    /// of the in-memory request; the source frame is excluded before visual
    /// representative selection so another retained copy may still match.
    func search(
        image: CGImage,
        scope: RecallScope,
        excluding sourceFrameID: FrameID?,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse
    /// Query-time, zero-storage refinement for person/appearance queries.
    /// Test doubles may retain the already-published global order.
    func rerankRegions(
        text: String,
        matches: [VisualEmbeddingMatch],
        policy: VisualRegionRerankingPolicy
    ) async throws -> VisualRegionRerankResponse
    func coverage() async throws -> VisualEmbeddingCoverage
    /// Loads the encrypted angular snapshot away from the first interactive
    /// query. Test doubles and non-SQLite engines can keep the default no-op.
    func prewarmIndex() async throws
}

enum AgentVisualRecallControllerError: Error, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Passage's local visual search is still preparing."
        }
    }
}

/// A synchronous generation gate between the always-available agent service
/// and Passage's later-starting visual runtime.
///
/// `clear()` is intentionally synchronous so session lock can invalidate an
/// in-flight visual response before its first suspension point. The encrypted
/// runtime is revoked separately by PassageModel at the same boundary.
final class AgentVisualRecallController: @unchecked Sendable {
    private struct State {
        var generation: UInt64 = 0
        var runtime: (any PassageAgentVisualSearchServing)?
    }

    private let lock = NSLock()
    private var state = State()

    func install(_ runtime: any PassageAgentVisualSearchServing) {
        lock.withLock {
            state.generation &+= 1
            state.runtime = runtime
        }
    }

    func clear() {
        lock.withLock {
            state.generation &+= 1
            state.runtime = nil
        }
    }

    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        let snapshot: (UInt64, any PassageAgentVisualSearchServing) = try lock.withLock {
            guard let runtime = state.runtime else {
                throw AgentVisualRecallControllerError.unavailable
            }
            return (state.generation, runtime)
        }
        let response = try await snapshot.1.search(
            text: text,
            scope: scope,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit
        )
        try Task.checkCancellation()
        guard lock.withLock({ state.generation == snapshot.0 && state.runtime != nil }) else {
            throw CancellationError()
        }
        return response
    }
}

extension PassageVisualRecallServing {
    func revoke() {}
    func prewarmIndex() async throws {}
    func search(
        image: CGImage,
        scope: RecallScope,
        excluding sourceFrameID: FrameID?,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        _ = (image, scope, sourceFrameID, minimumSimilarity, limit, candidateLimit)
        throw AgentVisualRecallControllerError.unavailable
    }
    func rerankRegions(
        text: String,
        matches: [VisualEmbeddingMatch],
        policy: VisualRegionRerankingPolicy
    ) async throws -> VisualRegionRerankResponse {
        VisualRegionRerankResponse(matches: matches)
    }
}

extension VisualMemoryEngine: PassageVisualRecallServing {}

enum LocalVisualRuntimeError: Error, LocalizedError, Sendable {
    case bundledResourcesUnavailable

    var errorDescription: String? {
        switch self {
        case .bundledResourcesUnavailable:
            "The built-in visual search model is unavailable. Text search still works."
        }
    }
}

/// Keeps writes on Passage's primary actor while large appearance scans use
/// their own read-only SQLCipher connection. WAL lets capture persistence and
/// ordinary text Recall remain responsive while visual retrieval runs.
actor LocalVisualRecallRuntime: PassageVisualRecallServing {
    private let indexingEngine: VisualMemoryEngine
    private let searchEngine: VisualMemoryEngine
    // Retaining this handle is intentional; dropping the runtime on lock closes
    // the extra key-bearing connection once in-flight calls have completed.
    private nonisolated let writeRepository: SQLiteFrameStore
    private nonisolated let readRepository: SQLiteFrameStore
    private let modelFingerprint: String
    private nonisolated let regionWorkGate: VisualRegionWorkGate

    private init(
        indexingEngine: VisualMemoryEngine,
        searchEngine: VisualMemoryEngine,
        writeRepository: SQLiteFrameStore,
        readRepository: SQLiteFrameStore,
        modelFingerprint: String,
        regionWorkGate: VisualRegionWorkGate
    ) {
        self.indexingEngine = indexingEngine
        self.searchEngine = searchEngine
        self.writeRepository = writeRepository
        self.readRepository = readRepository
        self.modelFingerprint = modelFingerprint
        self.regionWorkGate = regionWorkGate
    }

    static func prepare(
        pack: InstalledVisualModelPack,
        paths: PassagePaths,
        vaultKey: VaultKey,
        writeRepository: SQLiteFrameStore,
        media: MediaStore
    ) async throws -> LocalVisualRecallRuntime {
        let model = try await prepareModel(pack: pack, paths: paths)
        try Task.checkCancellation()
        return try connect(
            model: model,
            paths: paths,
            vaultKey: vaultKey,
            writeRepository: writeRepository,
            media: media
        )
    }

    /// Loads and prewarms only public, bundled model assets. Keeping this phase
    /// separate means Passage does not retain a vault key or encrypted-store
    /// handle during a potentially long Core ML specialization pass.
    static func prepareModel(
        pack: InstalledVisualModelPack,
        paths: PassagePaths
    ) async throws -> CoreMLVisualEmbeddingModel {
        let model = try await CoreMLVisualEmbeddingModel(
            pack: pack,
            compiledModelCacheDirectory: paths.root.appendingPathComponent(
                "VisualModelCache",
                isDirectory: true
            )
        )
        try await model.prewarm()
        try Task.checkCancellation()
        return model
    }

    /// Opens key-bearing stores only after model preparation has completed and
    /// the caller has revalidated the current unlocked vault generation.
    static func connect(
        model: CoreMLVisualEmbeddingModel,
        paths: PassagePaths,
        vaultKey: VaultKey,
        writeRepository: SQLiteFrameStore,
        media: MediaStore
    ) throws -> LocalVisualRecallRuntime {
        let readRepository = try SQLiteFrameStore(
            paths: paths,
            vaultKey: vaultKey,
            readOnly: true
        )
        let regionWorkGate = VisualRegionWorkGate()
        return LocalVisualRecallRuntime(
            indexingEngine: VisualMemoryEngine(
                model: model,
                repository: writeRepository,
                media: media
            ),
            searchEngine: VisualMemoryEngine(
                model: model,
                repository: readRepository,
                media: media,
                frameResolver: readRepository,
                regionProcessor: VisionVisualRegionProcessor(),
                regionWorkIsAuthorized: { regionWorkGate.isAuthorized }
            ),
            writeRepository: writeRepository,
            readRepository: readRepository,
            modelFingerprint: model.identity.fingerprint,
            regionWorkGate: regionWorkGate
        )
    }

    nonisolated func revoke() {
        regionWorkGate.revoke()
        writeRepository.revoke()
        readRepository.revoke()
    }

    func indexPersistedFrame(_ frame: FrameDocument) async throws
        -> VisualEmbeddingWriteSummary {
        try await indexingEngine.indexPersistedFrame(frame)
    }

    func indexNextBatch(limit: Int) async throws -> VisualIndexingPass {
        try await indexingEngine.indexNextBatch(limit: limit)
    }

    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        try await searchEngine.search(
            text: text,
            scope: scope,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit
        )
    }

    func search(
        image: CGImage,
        scope: RecallScope,
        excluding sourceFrameID: FrameID?,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        try await searchEngine.search(
            image: image,
            scope: scope,
            excluding: sourceFrameID,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit
        )
    }

    func rerankRegions(
        text: String,
        matches: [VisualEmbeddingMatch],
        policy: VisualRegionRerankingPolicy
    ) async throws -> VisualRegionRerankResponse {
        try await searchEngine.rerankRegions(
            text: text,
            matches: matches,
            policy: policy
        )
    }

    func coverage() async throws -> VisualEmbeddingCoverage {
        try await searchEngine.coverage()
    }

    func prewarmIndex() async throws {
        try await readRepository.prewarmVisualEmbeddingIndex(
            modelFingerprint: modelFingerprint
        )
    }
}

private final class VisualRegionWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var authorized = true

    var isAuthorized: Bool {
        lock.withLock { authorized }
    }

    func revoke() {
        lock.withLock { authorized = false }
    }
}
