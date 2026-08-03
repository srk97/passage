import PassageCore
import PassageStore
import PassageVisualModel
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol VisualMediaReading: Sendable {
    func read(relativePath: String) async throws -> Data
}

extension MediaStore: VisualMediaReading {}

extension SQLiteFrameStore: VisualFrameResolving {
    public func resolveVisualFrame(id: FrameID) async throws -> FrameDocument? {
        try frame(id: id)
    }
}

private struct VisualRegionRerankFailure: @unchecked Sendable {
    let error: any Error
}

private enum VisualRegionRerankDeadlineOutcome: Sendable {
    case response(VisualRegionRerankResponse)
    case failure(VisualRegionRerankFailure)
    case timedOut
    case cancelled
}

public enum VisualIndexingThermalState: Int, Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct VisualIndexingConditions: Equatable, Sendable {
    public var isLowPowerModeEnabled: Bool
    public var thermalState: VisualIndexingThermalState

    public init(
        isLowPowerModeEnabled: Bool,
        thermalState: VisualIndexingThermalState
    ) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    public var permitsBackgroundIndexing: Bool {
        !isLowPowerModeEnabled && thermalState < .serious
    }

    public static func current() -> Self {
        let process = ProcessInfo.processInfo
        let thermal: VisualIndexingThermalState = switch process.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        return Self(
            isLowPowerModeEnabled: process.isLowPowerModeEnabled,
            thermalState: thermal
        )
    }
}

public struct VisualIndexingPass: Equatable, Sendable {
    public var attemptedFrameCount: Int
    public var indexedFrameCount: Int
    public var skippedMediaCount: Int
    public var pausedForSystemConditions: Bool
    public var writeSummary: VisualEmbeddingWriteSummary
    public var coverage: VisualEmbeddingCoverage
    public var elapsedMilliseconds: Double

    public init(
        attemptedFrameCount: Int,
        indexedFrameCount: Int,
        skippedMediaCount: Int,
        pausedForSystemConditions: Bool,
        writeSummary: VisualEmbeddingWriteSummary,
        coverage: VisualEmbeddingCoverage,
        elapsedMilliseconds: Double
    ) {
        self.attemptedFrameCount = attemptedFrameCount
        self.indexedFrameCount = indexedFrameCount
        self.skippedMediaCount = skippedMediaCount
        self.pausedForSystemConditions = pausedForSystemConditions
        self.writeSummary = writeSummary
        self.coverage = coverage
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// Describes the actual relation used to rank a visual result. Neither case is
/// an object, demographic, or person-identity assertion.
public enum VisualSearchEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case textToImageSimilarity
    case imageToImageSimilarity
}

public struct VisualSearchResponse: Equatable, Sendable {
    public var matches: [VisualEmbeddingMatch]
    public var coverage: VisualEmbeddingCoverage
    public var evidenceKind: VisualSearchEvidenceKind
    public var queryEmbeddingMilliseconds: Double
    public var retrievalMilliseconds: Double

    public init(
        matches: [VisualEmbeddingMatch],
        coverage: VisualEmbeddingCoverage,
        evidenceKind: VisualSearchEvidenceKind = .textToImageSimilarity,
        queryEmbeddingMilliseconds: Double,
        retrievalMilliseconds: Double
    ) {
        self.matches = matches
        self.coverage = coverage
        self.evidenceKind = evidenceKind
        self.queryEmbeddingMilliseconds = queryEmbeddingMilliseconds
        self.retrievalMilliseconds = retrievalMilliseconds
    }
}

/// Off-capture visual indexing and retrieval.
///
/// Capture owns the durable frame boundary. This engine only consumes frames
/// after commit, prefers encrypted thumbnails, and may pause or fail without
/// changing Passage's ordinary OCR/metadata search behavior.
public actor VisualMemoryEngine {
    public typealias ConditionsProvider = @Sendable () -> VisualIndexingConditions
    public typealias RegionWorkAuthorization = @Sendable () -> Bool
    public typealias RegionDeadlineSleep = @Sendable (
        ContinuousClock.Instant
    ) async throws -> Void

    private let model: any VisualEmbeddingModel
    private let repository: any VisualEmbeddingRepository
    private let media: any VisualMediaReading
    private let conditions: ConditionsProvider
    private let frameResolver: (any VisualFrameResolving)?
    private let regionProcessor: (any VisualRegionProcessing)?
    private let regionWorkIsAuthorized: RegionWorkAuthorization
    private let regionDeadlineSleep: RegionDeadlineSleep
    private var cachedCoverage: VisualEmbeddingCoverage?
    private var coverageMeasuredAt: ContinuousClock.Instant?
    private static let coverageRefreshInterval: Duration = .seconds(60)

    public init(
        model: any VisualEmbeddingModel,
        repository: any VisualEmbeddingRepository,
        media: any VisualMediaReading,
        frameResolver: (any VisualFrameResolving)? = nil,
        regionProcessor: (any VisualRegionProcessing)? = nil,
        regionWorkIsAuthorized: @escaping RegionWorkAuthorization = { true },
        regionDeadlineSleep: @escaping RegionDeadlineSleep = {
            try await ContinuousClock().sleep(until: $0)
        },
        conditions: @escaping ConditionsProvider = VisualIndexingConditions.current
    ) {
        self.model = model
        self.repository = repository
        self.media = media
        self.frameResolver = frameResolver
        self.regionProcessor = regionProcessor
        self.regionWorkIsAuthorized = regionWorkIsAuthorized
        self.regionDeadlineSleep = regionDeadlineSleep
        self.conditions = conditions
    }

    public func indexPersistedFrame(_ frame: FrameDocument) async throws
        -> VisualEmbeddingWriteSummary {
        guard !frame.context.isSensitive else { return VisualEmbeddingWriteSummary() }
        let candidate = VisualEmbeddingCandidate(
            frameID: frame.id,
            capturedAt: frame.capturedAt,
            imageRelativePath: frame.imageRelativePath,
            thumbnailRelativePath: frame.thumbnailRelativePath,
            pixelWidth: frame.pixelWidth,
            pixelHeight: frame.pixelHeight,
            visualFingerprint: frame.visualFingerprint,
            isSensitive: frame.context.isSensitive
        )
        let identity = await model.identity
        guard let embedding = try await embedding(for: candidate) else {
            return VisualEmbeddingWriteSummary()
        }
        try Task.checkCancellation()
        return try await repository.upsertVisualEmbeddings([
            VisualEmbeddingWrite(
                frameID: frame.id,
                model: identity,
                vector: embedding.values
            ),
        ])
    }

    /// Indexes one bounded batch. A caller schedules subsequent passes at
    /// utility priority, leaving capture and UI work free to preempt it.
    public func indexNextBatch(limit: Int = 32) async throws -> VisualIndexingPass {
        let started = ContinuousClock.now
        let identity = await model.identity
        let boundedLimit = min(max(limit, 1), 256)
        guard conditions().permitsBackgroundIndexing else {
            // A paused pass must stay cheap: the coverage aggregates scan
            // whole tables and would defeat Low Power/thermal throttling.
            let coverage = try await lastKnownCoverage(identity: identity)
            return VisualIndexingPass(
                attemptedFrameCount: 0,
                indexedFrameCount: 0,
                skippedMediaCount: 0,
                pausedForSystemConditions: true,
                writeSummary: VisualEmbeddingWriteSummary(),
                coverage: coverage,
                elapsedMilliseconds: Self.milliseconds(since: started)
            )
        }

        let candidates = try await repository.framesNeedingVisualEmbedding(
            for: identity,
            limit: boundedLimit
        )
        var writes = [VisualEmbeddingWrite]()
        writes.reserveCapacity(candidates.count)
        var skipped = 0
        for candidate in candidates {
            try Task.checkCancellation()
            if !conditions().permitsBackgroundIndexing { break }
            guard !candidate.isSensitive,
                  let embedding = try await embedding(for: candidate) else {
                skipped += 1
                continue
            }
            writes.append(VisualEmbeddingWrite(
                frameID: candidate.frameID,
                model: identity,
                vector: embedding.values
            ))
        }
        let summary = writes.isEmpty
            ? VisualEmbeddingWriteSummary()
            : try await repository.upsertVisualEmbeddings(writes)
        let coverage = try await coverageAfterPass(
            identity: identity,
            candidateCount: candidates.count,
            candidateWindow: boundedLimit,
            summary: summary
        )
        return VisualIndexingPass(
            attemptedFrameCount: candidates.count,
            indexedFrameCount: writes.count,
            skippedMediaCount: skipped,
            pausedForSystemConditions: writes.count < candidates.count
                && !conditions().permitsBackgroundIndexing,
            writeSummary: summary,
            coverage: coverage,
            elapsedMilliseconds: Self.milliseconds(since: started)
        )
    }

    /// In steady state one capture indexes one new frame, so recomputing the
    /// five whole-table coverage aggregates per pass would keep per-capture
    /// cost O(history). Between periodic full measurements, coverage advances
    /// arithmetically from the transaction's own write summary; the pending
    /// count is exact whenever the candidate window was not full, because
    /// every remaining pending frame was then in this pass's candidate list.
    private func coverageAfterPass(
        identity: VisualModelIdentity,
        candidateCount: Int,
        candidateWindow: Int,
        summary: VisualEmbeddingWriteSummary
    ) async throws -> VisualEmbeddingCoverage {
        guard var adjusted = cachedCoverage,
              adjusted.model == identity,
              let measuredAt = coverageMeasuredAt,
              ContinuousClock.now - measuredAt < Self.coverageRefreshInterval else {
            return try await refreshCoverage(identity: identity)
        }
        let freshlyIndexed = summary.insertedAssociationCount + summary.replacedAssociationCount
        adjusted.indexedFrameCount += summary.insertedAssociationCount
        adjusted.indexedEligibleFrameCount += freshlyIndexed
        adjusted.staleEmbeddingCount = max(
            adjusted.staleEmbeddingCount - summary.replacedAssociationCount,
            0
        )
        adjusted.uniqueVectorCount += summary.insertedUniqueVectorCount
            - summary.reclaimedUniqueVectorCount
        adjusted.storedVectorPayloadBytes += summary.storedVectorBytesDelta
        if candidateCount < candidateWindow {
            adjusted.pendingEligibleFrameCount = max(candidateCount - summary.processedFrameCount, 0)
        } else {
            // The window was full, so unknown pending work remains beyond it.
            adjusted.pendingEligibleFrameCount = max(
                adjusted.pendingEligibleFrameCount - summary.processedFrameCount,
                1
            )
        }
        adjusted.eligibleFrameCount = adjusted.indexedEligibleFrameCount
            + adjusted.pendingEligibleFrameCount
        adjusted.deduplicatedFrameCount = max(
            adjusted.indexedFrameCount - adjusted.uniqueVectorCount,
            0
        )
        adjusted.coverageFraction = adjusted.eligibleFrameCount == 0
            ? nil
            : Double(adjusted.indexedEligibleFrameCount) / Double(adjusted.eligibleFrameCount)
        cachedCoverage = adjusted
        return adjusted
    }

    private func lastKnownCoverage(
        identity: VisualModelIdentity
    ) async throws -> VisualEmbeddingCoverage {
        if let cached = cachedCoverage, cached.model == identity { return cached }
        return try await refreshCoverage(identity: identity)
    }

    private func refreshCoverage(
        identity: VisualModelIdentity
    ) async throws -> VisualEmbeddingCoverage {
        let coverage = try await repository.visualEmbeddingCoverage(for: identity)
        cachedCoverage = coverage
        coverageMeasuredAt = ContinuousClock.now
        return coverage
    }

    public func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double = -1,
        limit: Int = 60,
        candidateLimit: Int = 2_048
    ) async throws -> VisualSearchResponse {
        let identity = await model.identity
        let queryStarted = ContinuousClock.now
        let embedding = try await model.validatedTextEmbedding(for: text)
        let queryMilliseconds = Self.milliseconds(since: queryStarted)
        try Task.checkCancellation()

        return try await retrieve(
            identity: identity,
            embedding: embedding,
            scope: scope,
            excludedFrameIDs: [],
            evidenceKind: .textToImageSimilarity,
            queryEmbeddingMilliseconds: queryMilliseconds,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit
        )
    }

    /// Finds retained screens that look like an in-memory image example.
    ///
    /// The query is encoded only into temporary memory, embedded with the
    /// model's image tower (never its text tower), and sent through the same
    /// encrypted exact-vector retrieval used by text-driven visual Recall.
    /// Supplying a source frame omits that frame before shortlist and
    /// representative selection, while preserving any other eligible frame
    /// associated with the same scene vector. This is appearance similarity,
    /// not evidence that a person or object has the same identity.
    public func search(
        image: CGImage,
        scope: RecallScope,
        excluding sourceFrameID: FrameID? = nil,
        minimumSimilarity: Double = -1,
        limit: Int = 60,
        candidateLimit: Int = 2_048
    ) async throws -> VisualSearchResponse {
        try Task.checkCancellation()
        let identity = await model.identity
        let queryStarted = ContinuousClock.now
        let embeddingImage = try Self.inMemoryEmbeddingImage(from: image)
        try Task.checkCancellation()
        let embedding = try await model.validatedImageEmbedding(for: embeddingImage)
        let queryMilliseconds = Self.milliseconds(since: queryStarted)
        try Task.checkCancellation()

        return try await retrieve(
            identity: identity,
            embedding: embedding,
            scope: scope,
            excludedFrameIDs: sourceFrameID.map { [$0] } ?? [],
            evidenceKind: .imageToImageSimilarity,
            queryEmbeddingMilliseconds: queryMilliseconds,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit
        )
    }

    private func retrieve(
        identity: VisualModelIdentity,
        embedding: NormalizedVisualEmbedding,
        scope: RecallScope,
        excludedFrameIDs: Set<FrameID>,
        evidenceKind: VisualSearchEvidenceKind,
        queryEmbeddingMilliseconds: Double,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        let retrievalStarted = ContinuousClock.now
        async let coverage = repository.visualEmbeddingCoverage(for: identity)
        async let matches = repository.nearestVisualEmbeddings(VisualEmbeddingQuery(
            modelFingerprint: identity.fingerprint,
            vector: embedding.values,
            startDate: scope.startDate,
            endDate: scope.endDate,
            applicationBundleIdentifiers: scope.applicationBundleIdentifiers,
            domains: scope.domains,
            excludedFrameIDs: excludedFrameIDs,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit
        ))
        let response = try await (matches, coverage)
        return VisualSearchResponse(
            matches: response.0,
            coverage: response.1,
            evidenceKind: evidenceKind,
            queryEmbeddingMilliseconds: queryEmbeddingMilliseconds,
            retrievalMilliseconds: Self.milliseconds(since: retrievalStarted)
        )
    }

    public func coverage() async throws -> VisualEmbeddingCoverage {
        try await refreshCoverage(identity: await model.identity)
    }

    /// Refines only the already-published global shortlist. It performs no
    /// repository writes and cannot admit a frame that global PE-Core did not
    /// retrieve. Every winning region is re-resolved against the current frame
    /// and fingerprint before this method returns.
    public func rerankRegions(
        text: String,
        matches: [VisualEmbeddingMatch],
        policy: VisualRegionRerankingPolicy = VisualRegionRerankingPolicy()
    ) async throws -> VisualRegionRerankResponse {
        let started = ContinuousClock.now
        try requireAuthorizedRegionWork()
        let requestedRegionKinds = VisualRegionQueryEligibility.requestedKinds(for: text)
        guard !requestedRegionKinds.isEmpty,
              !matches.isEmpty,
              let frameResolver,
              let regionProcessor else {
            return VisualRegionRerankResponse(
                matches: matches,
                elapsedMilliseconds: Self.milliseconds(since: started)
            )
        }
        guard conditions().permitsBackgroundIndexing else {
            return VisualRegionRerankResponse(
                matches: matches,
                skippedForSystemConditions: true,
                elapsedMilliseconds: Self.milliseconds(since: started)
            )
        }

        // Run the refinement behind an independently scheduled deadline. The
        // worker is deliberately unstructured: Swift task groups wait for a
        // cancelled child to exit, so a framework/model implementation that
        // ignores cancellation could otherwise keep the UI call suspended
        // past its budget. The response race is single-publication; a late
        // worker result is discarded after the stream is finished.
        let (outcomes, outcomeContinuation) = AsyncStream<
            VisualRegionRerankDeadlineOutcome
        >.makeStream(bufferingPolicy: .bufferingOldest(1))
        let worker = Task {
            do {
                let response = try await performRegionReranking(
                    text: text,
                    matches: matches,
                    requestedRegionKinds: requestedRegionKinds,
                    frameResolver: frameResolver,
                    regionProcessor: regionProcessor,
                    policy: policy,
                    started: started
                )
                try Task.checkCancellation()
                outcomeContinuation.yield(.response(response))
            } catch {
                outcomeContinuation.yield(.failure(
                    VisualRegionRerankFailure(error: error)
                ))
            }
        }
        let deadlineSleep = regionDeadlineSleep
        let expiresAt = started.advanced(
            by: .milliseconds(policy.maximumDurationMilliseconds)
        )
        let deadline = Task.detached(priority: .userInitiated) {
            do {
                try await deadlineSleep(expiresAt)
            } catch {
                guard !Task.isCancelled else { return }
                // An injected deadline source failing is treated as expiry,
                // never as permission to leave refinement unbounded.
            }
            guard !Task.isCancelled else { return }
            outcomeContinuation.yield(.timedOut)
        }

        let outcome = await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next() ?? .cancelled
        } onCancel: {
            outcomeContinuation.yield(.cancelled)
        }
        outcomeContinuation.finish()

        switch outcome {
        case let .response(response):
            deadline.cancel()
            try Task.checkCancellation()
            return response
        case let .failure(failure):
            deadline.cancel()
            throw failure.error
        case .timedOut:
            worker.cancel()
            try Task.checkCancellation()
            return VisualRegionRerankResponse(
                matches: matches,
                timedOut: true,
                elapsedMilliseconds: Self.milliseconds(since: started)
            )
        case .cancelled:
            worker.cancel()
            deadline.cancel()
            throw CancellationError()
        }
    }

    private func performRegionReranking(
        text: String,
        matches: [VisualEmbeddingMatch],
        requestedRegionKinds: Set<VisualRegionKind>,
        frameResolver: any VisualFrameResolving,
        regionProcessor: any VisualRegionProcessing,
        policy: VisualRegionRerankingPolicy,
        started: ContinuousClock.Instant
    ) async throws -> VisualRegionRerankResponse {
        let queryEmbedding = try await model.validatedTextEmbedding(for: text)
        try Task.checkCancellation()
        try requireAuthorizedRegionWork()
        var reranked = matches
        var evidenceByFrameID = [FrameID: VisualRegionRecallEvidence]()
        var examinedFrameCount = 0
        var embeddingCount = 0
        var stoppedForSystemConditions = false
        let candidateCount = min(policy.candidateFrameLimit, reranked.count)

        for index in 0..<candidateCount {
            try Task.checkCancellation()
            try requireAuthorizedRegionWork()
            guard embeddingCount < policy.embeddingLimit else { break }
            guard conditions().permitsBackgroundIndexing else {
                stoppedForSystemConditions = true
                break
            }
            examinedFrameCount += 1
            let originalMatch = reranked[index]

            do {
                guard let frame = try await frameResolver.resolveVisualFrame(
                    id: originalMatch.hit.id
                ), !frame.context.isSensitive,
                   originalMatch.sourceVisualFingerprint == frame.visualFingerprint,
                   let detectionImage = try await readableImage(
                       paths: [frame.thumbnailRelativePath, frame.imageRelativePath]
                   ) else { continue }
                try Task.checkCancellation()
                try requireAuthorizedRegionWork()

                let remainingBudget = policy.embeddingLimit - embeddingCount
                let maximumRegions = min(policy.regionsPerFrameLimit, remainingBudget)
                let proposals = try await regionProcessor.proposals(
                    in: detectionImage,
                    requestedKinds: requestedRegionKinds,
                    maximumCount: maximumRegions
                )
                guard !proposals.isEmpty else { continue }
                try Task.checkCancellation()
                try requireAuthorizedRegionWork()

                let cropSource = try await readableImage(paths: [frame.imageRelativePath])
                    ?? detectionImage
                try Task.checkCancellation()
                try requireAuthorizedRegionWork()
                let crops = try await regionProcessor.crops(
                    from: cropSource,
                    proposals: Array(proposals.prefix(maximumRegions))
                )

                var winningCrop: (crop: VisualRegionCrop, similarity: Double)?
                for crop in crops.prefix(remainingBudget) {
                    try Task.checkCancellation()
                    try requireAuthorizedRegionWork()
                    embeddingCount += 1
                    let cropEmbedding: NormalizedVisualEmbedding
                    do {
                        cropEmbedding = try await model.validatedImageEmbedding(
                            for: crop.image
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        continue
                    }
                    try Task.checkCancellation()
                    try requireAuthorizedRegionWork()
                    let similarity = Double(
                        try queryEmbedding.cosineSimilarity(to: cropEmbedding)
                    )
                    if winningCrop == nil
                        || similarity > (winningCrop?.similarity ?? -1) {
                        winningCrop = (crop, similarity)
                    }
                }

                guard let winningCrop,
                      winningCrop.similarity >= policy.minimumRegionSimilarity,
                      winningCrop.similarity
                        >= originalMatch.similarity + policy.minimumSimilarityGain,
                      let currentFrame = try await frameResolver.resolveVisualFrame(
                          id: frame.id
                      ), !currentFrame.context.isSensitive,
                      currentFrame.visualFingerprint == frame.visualFingerprint,
                      currentFrame.imageRelativePath == frame.imageRelativePath,
                      currentFrame.thumbnailRelativePath == frame.thumbnailRelativePath else {
                    continue
                }
                try Task.checkCancellation()
                try requireAuthorizedRegionWork()

                reranked[index] = VisualEmbeddingMatch(
                    hit: originalMatch.hit,
                    similarity: winningCrop.similarity,
                    maximumSimilarityError: 0,
                    model: originalMatch.model,
                    associatedFrameCount: 1,
                    sourceVisualFingerprint: frame.visualFingerprint
                )
                evidenceByFrameID[frame.id] = VisualRegionRecallEvidence(
                    kind: winningCrop.crop.proposal.kind,
                    bounds: winningCrop.crop.proposal.bounds,
                    similarity: winningCrop.similarity,
                    sourceVisualFingerprint: frame.visualFingerprint
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One undecodable/expired image or one failed Vision request
                // cannot replace the already-published global result set.
                continue
            }
        }

        // Region work can take long enough for retention, deletion, or OCR
        // repair to change an untouched shortlist row. Revalidate the entire
        // set before returning so the progressive second publication cannot
        // resurrect a frame whose global result is no longer authoritative.
        var validatedMatches = [VisualEmbeddingMatch]()
        validatedMatches.reserveCapacity(reranked.count)
        for match in reranked {
            try Task.checkCancellation()
            try requireAuthorizedRegionWork()
            guard let sourceVisualFingerprint = match.sourceVisualFingerprint,
                  let currentFrame = try await frameResolver.resolveVisualFrame(
                      id: match.hit.id
                  ), !currentFrame.context.isSensitive,
                  currentFrame.visualFingerprint == sourceVisualFingerprint else {
                evidenceByFrameID.removeValue(forKey: match.hit.id)
                continue
            }
            validatedMatches.append(match)
        }
        reranked = validatedMatches

        let originalRanks = Dictionary(uniqueKeysWithValues: matches.enumerated().map {
            ($0.element.hit.id, $0.offset)
        })
        reranked.sort { lhs, rhs in
            let lhsLowerBound = lhs.similarity - lhs.maximumSimilarityError
            let rhsLowerBound = rhs.similarity - rhs.maximumSimilarityError
            if lhsLowerBound != rhsLowerBound { return lhsLowerBound > rhsLowerBound }
            return (originalRanks[lhs.hit.id] ?? Int.max)
                < (originalRanks[rhs.hit.id] ?? Int.max)
        }
        try Task.checkCancellation()
        try requireAuthorizedRegionWork()
        return VisualRegionRerankResponse(
            matches: reranked,
            evidenceByFrameID: evidenceByFrameID,
            candidateFrameCount: examinedFrameCount,
            embeddedRegionCount: embeddingCount,
            skippedForSystemConditions: stoppedForSystemConditions,
            elapsedMilliseconds: Self.milliseconds(since: started)
        )
    }

    private func embedding(
        for candidate: VisualEmbeddingCandidate
    ) async throws -> NormalizedVisualEmbedding? {
        let paths = [candidate.thumbnailRelativePath, candidate.imageRelativePath]
            .compactMap { path -> String? in
                guard let path, !path.isEmpty else { return nil }
                return path
            }
        for path in paths {
            try Task.checkCancellation()
            do {
                let bytes = try await media.read(relativePath: path)
                let image = try VisualEmbeddingImage(encodedBytes: bytes)
                return try await model.validatedImageEmbedding(for: image)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A corrupt thumbnail can still fall back to the authenticated
                // full image. If both fail, leave this frame pending and keep
                // lexical search intact.
                continue
            }
        }
        return nil
    }

    private func readableImage(paths: [String?]) async throws -> VisualEmbeddingImage? {
        let normalizedPaths = paths.compactMap { path -> String? in
            guard let path, !path.isEmpty else { return nil }
            return path
        }
        var visited = Set<String>()
        for path in normalizedPaths where visited.insert(path).inserted {
            try Task.checkCancellation()
            try requireAuthorizedRegionWork()
            do {
                return try VisualEmbeddingImage(
                    encodedBytes: await media.read(relativePath: path)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    private func requireAuthorizedRegionWork() throws {
        guard regionWorkIsAuthorized() else { throw CancellationError() }
    }

    private nonisolated static func milliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Lossless encoding keeps the model's established encoded-image boundary
    /// without creating a crop, cache entry, temporary file, or durable asset.
    private nonisolated static func inMemoryEmbeddingImage(
        from image: CGImage
    ) throws -> VisualEmbeddingImage {
        guard image.width > 0, image.height > 0 else {
            throw VisualEmbeddingError.invalidImage
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw VisualEmbeddingError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VisualEmbeddingError.invalidImage
        }
        return try VisualEmbeddingImage(encodedBytes: encoded as Data)
    }
}
