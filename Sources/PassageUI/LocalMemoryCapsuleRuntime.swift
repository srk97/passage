import PassageCore
import PassageService
import PassageStore
import PassageVisualSearch
import Foundation

/// A manifest-only retrieval seam shared by Passage's audited local service
/// and its in-app handoff preview. Raw frames, media paths, and private visual
/// index rows never cross this boundary.
protocol LocalMemoryCapsuleRetrieving: AnyObject, Sendable {
    func retrieve(
        _ request: PassageMemoryCapsuleRequest
    ) async throws -> PassageMemoryCapsuleManifest

    func retrieveSession(
        _ activitySessionID: ActivitySessionID,
        resultLimit: Int,
        utf8ByteBudget: Int
    ) async throws -> PassageMemoryCapsuleManifest

    func retrieveMoment(
        _ frameID: FrameID,
        utf8ByteBudget: Int
    ) async throws -> PassageMemoryCapsuleManifest
}

actor LocalMemoryCapsuleRuntime: LocalMemoryCapsuleRetrieving {
    private let frames: SQLiteFrameStore
    private let visualRecall: AgentVisualRecallController

    private static let visualRetrievalSimilarityFloor = 0.235
    private static let minimumVisualSimilarity = 0.245
    private static let visualCandidateLimit = 2_048

    init(
        frames: SQLiteFrameStore,
        visualRecall: AgentVisualRecallController
    ) {
        self.frames = frames
        self.visualRecall = visualRecall
    }

    func retrieve(
        _ request: PassageMemoryCapsuleRequest
    ) async throws -> PassageMemoryCapsuleManifest {
        // IPC performs this validation before dispatch. The app calls this
        // runtime directly, so repeat the same public contract here rather
        // than trusting mutable request fields.
        try PassageServiceRequest.validateMemoryCapsuleRequest(request)

        return try await retrieveValidated(request)
    }

    func retrieveSession(
        _ activitySessionID: ActivitySessionID,
        resultLimit: Int = 12,
        utf8ByteBudget: Int = 16 * 1_024
    ) async throws -> PassageMemoryCapsuleManifest {
        let boundedLimit = min(
            max(resultLimit, 1),
            PassageMemoryCapsuleSchema.maximumResultLimit
        )
        let boundedBudget = min(
            max(utf8ByteBudget, PassageMemoryCapsuleSchema.minimumUTF8ByteBudget),
            PassageMemoryCapsuleSchema.maximumUTF8ByteBudget
        )
        // Empty text intentionally means the most recent moments in this exact
        // authoritative session. This private app-only path cannot be requested
        // over IPC, where Memory Capsule queries remain non-empty.
        let request = PassageMemoryCapsuleRequest(
            query: SearchQuery(
                activitySessionIDs: [activitySessionID],
                limit: boundedLimit
            ),
            retrievalModalities: [.savedText],
            resultLimit: boundedLimit,
            utf8ByteBudget: boundedBudget
        )
        return try await retrieveValidated(request)
    }

    func retrieveMoment(
        _ frameID: FrameID,
        utf8ByteBudget: Int = 16 * 1_024
    ) async throws -> PassageMemoryCapsuleManifest {
        let boundedBudget = min(
            max(utf8ByteBudget, PassageMemoryCapsuleSchema.minimumUTF8ByteBudget),
            PassageMemoryCapsuleSchema.maximumUTF8ByteBudget
        )
        let request = PassageMemoryCapsuleRequest(
            query: SearchQuery(text: "Selected moment", limit: 1),
            retrievalModalities: [.savedText],
            resultLimit: 1,
            utf8ByteBudget: boundedBudget
        )
        guard let resolved = try await frames.agentSafeFrame(id: frameID) else {
            return try PassageMemoryCapsuleBuilder.build(
                request: request,
                candidates: []
            )
        }
        let frame = resolved.frame
        let hit = SearchHit(
            id: frame.id,
            activitySessionID: resolved.activitySessionID,
            capturedAt: frame.capturedAt,
            context: frame.context,
            snippet: frame.ocrText,
            imageRelativePath: "",
            thumbnailRelativePath: nil,
            score: 0
        )
        let accessibility = frame.accessibilitySnapshot?.nodes.map { node in
            PassageMemoryAccessibilityEvidence(
                role: node.role,
                label: node.label,
                value: node.value,
                depth: node.depth,
                normalizedBounds: node.bounds
            )
        } ?? []
        return try PassageMemoryCapsuleBuilder.build(
            request: request,
            candidates: [PassageMemoryCapsuleCandidate(
                hit: hit,
                ocrText: frame.ocrText,
                accessibility: accessibility,
                savedTextRank: 1
            )]
        )
    }

    private func retrieveValidated(
        _ request: PassageMemoryCapsuleRequest
    ) async throws -> PassageMemoryCapsuleManifest {

        let requestedModalities = Set(request.retrievalModalities)
        let selectionWindow = min(
            100,
            max(request.resultLimit, request.resultLimit * 4)
        )

        var lexicalHits: [SearchHit] = []
        var lexicalHasMore = false
        if requestedModalities.contains(.savedText) {
            var query = request.query
            query.limit = selectionWindow + 1
            let fetched = try await frames.search(query, includeSensitive: false)
                .filter { !$0.context.isSensitive }
            lexicalHasMore = fetched.count > selectionWindow
            lexicalHits = Array(fetched.prefix(selectionWindow))
        }

        var visualMatches: [VisualEmbeddingMatch] = []
        var visualHasMore = false
        var extraOmissions: [PassageMemoryCapsuleOmissionSummary] = []
        if requestedModalities.contains(.visualAppearance) {
            do {
                let response = try await visualRecall.search(
                    text: request.query.text,
                    scope: RecallScope(
                        startDate: request.query.startDate,
                        endDate: request.query.endDate,
                        applicationBundleIdentifiers: request.query.applicationBundleIdentifiers,
                        domains: request.query.domains
                    ),
                    minimumSimilarity: Self.visualRetrievalSimilarityFloor,
                    // Keep a larger private re-resolution window so a stale
                    // runtime prefix cannot starve ordinary evidence. The
                    // primary vault remains authoritative below.
                    limit: min(100, max(selectionWindow + 1, selectionWindow * 4)),
                    candidateLimit: Self.visualCandidateLimit
                )
                visualMatches = response.matches.filter {
                    $0.similarity - $0.maximumSimilarityError
                        >= Self.minimumVisualSimilarity
                }
                let incomplete = response.coverage.pendingEligibleFrameCount
                    + response.coverage.staleEmbeddingCount
                if incomplete > 0 {
                    // The visual index's aggregate coverage is frame-private,
                    // not whole-session-private. Preserve the honest warning
                    // without disclosing an exact mixed-session-derived count.
                    extraOmissions.append(.init(
                        reason: .visualIndexPartial,
                        count: 1,
                        countIsLowerBound: true
                    ))
                }
            } catch {
                // True task cancellation remains cancellation. Any other local
                // model/index/runtime failure degrades honestly to saved text.
                try Task.checkCancellation()
                extraOmissions.append(.init(reason: .visualIndexUnavailable, count: 1))
            }
        }
        try Task.checkCancellation()

        struct MergedCandidate {
            var lexicalHit: SearchHit?
            var lexicalRank: Int?
            var visualMatch: VisualEmbeddingMatch?
            var visualRank: Int?
        }
        var merged = [FrameID: MergedCandidate]()
        for (offset, hit) in lexicalHits.enumerated() {
            merged[hit.id] = MergedCandidate(
                lexicalHit: hit,
                lexicalRank: offset + 1,
                visualMatch: nil,
                visualRank: nil
            )
        }
        for (offset, match) in visualMatches.enumerated() {
            var candidate = merged[match.hit.id] ?? MergedCandidate()
            candidate.visualMatch = match
            candidate.visualRank = offset + 1
            merged[match.hit.id] = candidate
        }

        let orderedCandidateIDs = merged.keys.sorted { $0.rawValue < $1.rawValue }
        let safeEvidence = try await frames.agentSafeFrames(ids: orderedCandidateIDs)
        let safeEvidenceByID = Dictionary(
            uniqueKeysWithValues: safeEvidence.map { ($0.frame.id, $0) }
        )
        var candidates: [PassageMemoryCapsuleCandidate] = []
        for frameID in orderedCandidateIDs {
            try Task.checkCancellation()
            guard let mergedCandidate = merged[frameID],
                  let resolved = safeEvidenceByID[frameID] else { continue }
            let frame = resolved.frame
            let sessionID = resolved.activitySessionID
            if !request.query.activitySessionIDs.isEmpty {
                guard request.query.activitySessionIDs.contains(sessionID) else { continue }
            }
            let safeHit = SearchHit(
                id: frame.id,
                activitySessionID: sessionID,
                capturedAt: frame.capturedAt,
                context: frame.context,
                snippet: frame.ocrText,
                imageRelativePath: "",
                thumbnailRelativePath: nil,
                score: 0
            )
            let accessibility = frame.accessibilitySnapshot?.nodes.map { node in
                PassageMemoryAccessibilityEvidence(
                    role: node.role,
                    label: node.label,
                    value: node.value,
                    depth: node.depth,
                    normalizedBounds: node.bounds
                )
            } ?? []
            let visual = mergedCandidate.visualMatch.map { match in
                PassageMemoryVisualEvidence(
                    similarity: match.similarity,
                    maximumSimilarityError: match.maximumSimilarityError,
                    associatedFrameCount: 1,
                    modelIdentifier: match.model.identifier,
                    modelRevision: match.model.revision
                )
            }
            candidates.append(PassageMemoryCapsuleCandidate(
                hit: safeHit,
                ocrText: frame.ocrText,
                accessibility: accessibility,
                savedTextRank: mergedCandidate.lexicalRank,
                visualAppearanceRank: mergedCandidate.visualRank,
                visual: visual
            ))
        }

        // Compress ranks only after authoritative re-resolution. A stale or
        // private candidate must not leak its existence as a rank gap.
        func safeOrder(
            rank: (PassageMemoryCapsuleCandidate) -> Int?
        ) -> [Int] {
            candidates.indices.filter { rank(candidates[$0]) != nil }.sorted {
                let left = rank(candidates[$0]) ?? .max
                let right = rank(candidates[$1]) ?? .max
                if left != right { return left < right }
                return candidates[$0].hit.id.rawValue
                    < candidates[$1].hit.id.rawValue
            }
        }
        for (offset, index) in safeOrder(rank: { $0.savedTextRank }).enumerated() {
            candidates[index].savedTextRank = offset + 1
        }
        for (offset, index) in safeOrder(rank: { $0.visualAppearanceRank }).enumerated() {
            candidates[index].visualAppearanceRank = offset + 1
        }
        let safeVisualCount = candidates.count {
            $0.visualAppearanceRank != nil
        }
        visualHasMore = safeVisualCount > selectionWindow
        for index in candidates.indices
        where (candidates[index].visualAppearanceRank ?? 0) > selectionWindow {
            candidates[index].visualAppearanceRank = nil
            candidates[index].visual = nil
        }
        candidates.removeAll {
            $0.savedTextRank == nil && $0.visualAppearanceRank == nil
        }

        return try PassageMemoryCapsuleBuilder.build(
            request: request,
            candidates: candidates,
            hasMoreCandidates: lexicalHasMore || visualHasMore,
            // Exact aggregate visual coverage can include ordinary frames that
            // belong to a mixed-sensitive session. Source-level coverage below
            // remains authoritative and private-safe.
            visualIndexCoverageFraction: nil,
            additionalOmissions: extraOmissions
        )
    }
}
