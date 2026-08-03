import PassageCore
import PassageService
import PassageStore
import PassageVisualSearch
import Foundation

actor AgentAccessPolicyController {
    struct Authorization: Hashable, Sendable {
        fileprivate var identifier: String
        fileprivate var generation: UInt64
    }

    private var allowedIdentifiers: Set<String>
    private var generation: UInt64 = 0

    init(allowedIdentifiers: [String]) {
        self.allowedIdentifiers = Set(allowedIdentifiers.map { $0.lowercased() })
    }

    func update(allowedIdentifiers: [String]) {
        generation &+= 1
        self.allowedIdentifiers = Set(allowedIdentifiers.map { $0.lowercased() })
    }

    func authorization(
        for client: PassageServiceClientIdentity
    ) -> Authorization? {
        let identifier = client.identifier.lowercased()
        guard allowedIdentifiers.contains(identifier) else { return nil }
        return Authorization(identifier: identifier, generation: generation)
    }

    func permits(_ authorization: Authorization) -> Bool {
        authorization.generation == generation
            && allowedIdentifiers.contains(authorization.identifier)
    }
}

private struct AgentAuthorizationRevoked: Error, Sendable {}

/// The only app-side bridge from local agent requests to Passage's vault.
///
/// The transport verifies that the peer belongs to the logged-in user. This
/// handler then executes one bounded capability and commits an access receipt
/// before returning any evidence to the caller.
actor PassageCapabilityHandler: PassageServiceRequestHandling {
    private let frames: SQLiteFrameStore
    private let audit: SQLiteAccessEventStore
    private let accessPolicy: AgentAccessPolicyController
    private let visualRecall: AgentVisualRecallController
    private let memoryCapsules: any LocalMemoryCapsuleRetrieving

    private static let visualRetrievalSimilarityFloor = 0.235
    private static let minimumVisualSimilarity = 0.245
    private static let visualCandidateLimit = 2_048

    init(
        frames: SQLiteFrameStore,
        audit: SQLiteAccessEventStore,
        accessPolicy: AgentAccessPolicyController,
        visualRecall: AgentVisualRecallController = AgentVisualRecallController(),
        memoryCapsules: (any LocalMemoryCapsuleRetrieving)? = nil
    ) {
        self.frames = frames
        self.audit = audit
        self.accessPolicy = accessPolicy
        self.visualRecall = visualRecall
        self.memoryCapsules = memoryCapsules ?? LocalMemoryCapsuleRuntime(
            frames: frames,
            visualRecall: visualRecall
        )
    }

    func handle(
        _ request: PassageServiceRequest,
        peer: PassageServicePeer
    ) async throws -> PassageServiceResult {
        guard let authorization = await accessPolicy.authorization(for: request.client) else {
            let denial = AccessEvent(
                client: Self.clientDescription(request.client),
                command: request.capability.rawValue,
                capability: "memory.\(request.capability.rawValue)",
                querySummary: Self.querySummary(request),
                filterSummary: Self.filterSummary(request: request, peer: peer),
                returnedFrameCount: 0,
                outcome: .denied
            )
            try await audit.recordAccessEvent(denial)
            throw PassageServiceRejection(
                code: .denied,
                message: "\(request.client.displayName) is not enabled in Passage Settings."
            )
        }
        do {
            let result = try await perform(request)
            // A long local-model query must not outlive the Settings grant that
            // authorized it. The generation token also catches disable/enable
            // cycles that end with the same identifier set.
            guard await accessPolicy.permits(authorization) else {
                throw AgentAuthorizationRevoked()
            }
            let returnedIDs = Self.returnedFrameIDs(from: result)
            let event = AccessEvent(
                client: Self.clientDescription(request.client),
                command: request.capability.rawValue,
                capability: "memory.\(request.capability.rawValue)",
                querySummary: Self.querySummary(request),
                filterSummary: Self.filterSummary(request: request, peer: peer, result: result),
                returnedFrameIDs: returnedIDs,
                returnedFrameCount: Self.returnedCount(from: result),
                outcome: .success
            )
            // Fail closed: no result crosses IPC unless its receipt is durable.
            try await audit.recordAccessEvent(event)
            // The receipt write is itself a suspension point. Revalidate once
            // more immediately before release so revocation during that write
            // still withholds the prepared evidence.
            guard await accessPolicy.permits(authorization) else {
                throw AgentAuthorizationRevoked()
            }
            return result
        } catch is AgentAuthorizationRevoked {
            let revocation = AccessEvent(
                client: Self.clientDescription(request.client),
                command: request.capability.rawValue,
                capability: "memory.\(request.capability.rawValue)",
                querySummary: Self.querySummary(request),
                filterSummary: Self.filterSummary(request: request, peer: peer),
                returnedFrameCount: 0,
                outcome: .denied
            )
            try await audit.recordAccessEvent(revocation)
            throw PassageServiceRejection(
                code: .denied,
                message: "\(request.client.displayName) was disabled before Passage released this result."
            )
        } catch {
            let failure = AccessEvent(
                client: Self.clientDescription(request.client),
                command: request.capability.rawValue,
                capability: "memory.\(request.capability.rawValue)",
                querySummary: Self.querySummary(request),
                filterSummary: Self.filterSummary(request: request, peer: peer),
                returnedFrameCount: 0,
                outcome: .failure
            )
            // Failure responses use the same durable boundary. If the receipt
            // cannot be committed, the audit error replaces the operation error.
            try await audit.recordAccessEvent(failure)
            throw error
        }
    }

    private func perform(_ request: PassageServiceRequest) async throws -> PassageServiceResult {
        switch request.capability {
        case .capabilities:
            return .capabilities(.current)
        case .health:
            return .health(.ready)
        case .bundle:
            guard let bundleRequest = request.bundleRequest else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Bundle request is missing.")
            }
            var query = bundleRequest.query
            // A bounded diversity window lets later apps, sites, and activity
            // runs survive a repetitive relevance prefix. One additional row
            // says whether even this candidate window was truncated.
            let selectionWindow = min(
                PassageContextBundleSchema.maximumResultLimit,
                max(bundleRequest.resultLimit, bundleRequest.resultLimit * 4)
            )
            query.limit = selectionWindow + 1
            // Apply the privacy predicate inside SQLite so sensitive winners
            // cannot consume this bounded look-ahead window, then re-check the
            // projection before it crosses the audited IPC boundary.
            let fetchedHits = try await frames.search(query, includeSensitive: false)
                .filter { !$0.context.isSensitive }
            let hasMoreCandidates = fetchedHits.count > selectionWindow
            let hits = Array(fetchedHits.prefix(selectionWindow))
            return .bundle(try PassageContextBundleBuilder.build(
                request: bundleRequest,
                hits: hits,
                hasMoreCandidates: hasMoreCandidates
            ))
        case .visualSearch:
            guard let visualRequest = request.visualSearchRequest else {
                throw PassageServiceRejection(
                    code: .invalidRequest,
                    message: "Visual-search request is missing."
                )
            }
            let retrievalLimit = min(
                100,
                max(visualRequest.resultLimit + 1, visualRequest.resultLimit * 4)
            )
            let response: VisualSearchResponse
            do {
                response = try await visualRecall.search(
                    text: visualRequest.description,
                    scope: visualRequest.scope,
                    minimumSimilarity: Self.visualRetrievalSimilarityFloor,
                    limit: retrievalLimit,
                    candidateLimit: Self.visualCandidateLimit
                )
            } catch is AgentVisualRecallControllerError {
                throw PassageServiceRejection(
                    code: .busy,
                    message: "Passage's local visual search is still preparing.",
                    retryable: true
                )
            } catch is CancellationError {
                throw PassageServiceRejection(
                    code: .busy,
                    message: "Passage's local visual search changed state. Try again.",
                    retryable: true
                )
            }

            // Re-resolve every candidate through the primary vault with the
            // sensitive predicate inside SQLite. Never project the visual
            // engine's cached paths or stale context across IPC.
            let safeEvidence = try await frames.agentSafeFrames(
                ids: response.matches.map(\.hit.id)
            )
            let safeEvidenceByID = Dictionary(
                uniqueKeysWithValues: safeEvidence.map { ($0.frame.id, $0) }
            )
            var safeMatches: [VisualEmbeddingMatch] = []
            for match in response.matches {
                try Task.checkCancellation()
                guard let resolved = safeEvidenceByID[match.hit.id] else {
                    continue
                }
                let frame = resolved.frame
                let safeHit = SearchHit(
                    id: frame.id,
                    activitySessionID: resolved.activitySessionID,
                    capturedAt: frame.capturedAt,
                    context: frame.context,
                    snippet: frame.ocrText,
                    imageRelativePath: "",
                    thumbnailRelativePath: nil,
                    score: 0
                )
                safeMatches.append(VisualEmbeddingMatch(
                    hit: safeHit,
                    similarity: match.similarity,
                    maximumSimilarityError: match.maximumSimilarityError,
                    model: match.model,
                    // The private visual index can deduplicate across moments
                    // that the agent-safe boundary later withholds. Publishing
                    // that internal count would reveal their existence.
                    associatedFrameCount: 1
                ))
            }
            return .visualSearch(try PassageAgentVisualSearchBuilder.build(
                request: visualRequest,
                candidates: safeMatches,
                coverage: response.coverage,
                minimumSimilarity: Self.minimumVisualSimilarity
            ))
        case .memoryCapsule:
            guard let capsuleRequest = request.memoryCapsuleRequest else {
                throw PassageServiceRejection(
                    code: .invalidRequest,
                    message: "Memory-capsule request is missing."
                )
            }
            return .memoryCapsule(try await memoryCapsules.retrieve(capsuleRequest))
        case .search:
            guard let query = request.searchQuery else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Search query is missing.")
            }
            let hits = try await frames.search(query, includeSensitive: false)
                .filter { !$0.context.isSensitive }
            return .search(hits)
        case .recent:
            guard let limit = request.recentLimit else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Recent limit is missing.")
            }
            let hits = try await frames.recent(limit: limit, includeSensitive: false)
                .filter { !$0.context.isSensitive }
            return .recent(hits)
        case .sessions:
            guard var query = request.activitySessionQuery else {
                throw PassageServiceRejection(
                    code: .invalidRequest,
                    message: "Activity session query is missing."
                )
            }
            // Agent-facing session discovery is metadata disclosure. Force the
            // store predicate closed and filter again before constructing the
            // result so a future store regression cannot reveal a sensitive span.
            query.includeSensitive = false
            let sessions = try await frames.activitySessions(query)
                .filter { !$0.containsSensitive }
            return .sessions(sessions)
        case .frame:
            guard let id = request.frameID else {
                throw PassageServiceRejection(code: .invalidRequest, message: "Frame ID is missing.")
            }
            let frame = try await frames.frame(id: id, includeSensitive: false)
            return .frame(frame.flatMap { $0.context.isSensitive ? nil : $0 })
        case .statistics:
            return .statistics(try await frames.statistics())
        }
    }

    private static func returnedFrameIDs(from result: PassageServiceResult) -> [FrameID] {
        switch result {
        case .bundle(let bundle): bundle.sources.map(\.frameID)
        case .visualSearch(let manifest): manifest.sources.map(\.frameID)
        case .memoryCapsule(let manifest): manifest.sources.map(\.frameID)
        case .search(let hits), .recent(let hits): hits.map(\.id)
        case .frame(let frame): frame.map { [$0.id] } ?? []
        // A session-list receipt is accounted by summary count; it does not
        // expand each activity span into underlying evidence-frame receipts.
        case .capabilities, .health, .sessions, .statistics: []
        }
    }

    private static func returnedCount(from result: PassageServiceResult) -> Int {
        switch result {
        case .bundle(let bundle): bundle.disclosedCount
        case .visualSearch(let manifest): manifest.disclosedCount
        case .memoryCapsule(let manifest): manifest.disclosedCount
        case .search(let hits), .recent(let hits): hits.count
        case .sessions(let sessions): sessions.count
        case .frame(let frame): frame == nil ? 0 : 1
        case .capabilities, .health, .statistics: 0
        }
    }

    private static func querySummary(_ request: PassageServiceRequest) -> String? {
        let text = request.memoryCapsuleRequest?.query.text
            ?? request.visualSearchRequest?.description
            ?? request.searchQuery?.text
            ?? request.bundleRequest?.query.text
        return text?.nilIfEmpty.map { boundedSummary($0) }
    }

    private static func clientDescription(_ client: PassageServiceClientIdentity) -> String {
        let version = client.version.map { " \(auditToken($0))" } ?? ""
        return boundedSummary(
            "\(auditToken(client.displayName)) [\(auditToken(client.identifier))\(version)]"
        )
    }

    private static func filterSummary(
        request: PassageServiceRequest,
        peer: PassageServicePeer,
        result: PassageServiceResult? = nil
    ) -> String {
        var parts = ["uid=\(peer.userID)"]
        if let query = request.searchQuery
            ?? request.bundleRequest?.query
            ?? request.memoryCapsuleRequest?.query {
            if let start = query.startDate { parts.append("since=\(ISO8601DateFormatter().string(from: start))") }
            if let end = query.endDate { parts.append("until=\(ISO8601DateFormatter().string(from: end))") }
            if !query.applicationBundleIdentifiers.isEmpty {
                parts.append("apps=\(auditList(query.applicationBundleIdentifiers))")
            }
            if !query.domains.isEmpty {
                parts.append("domains=\(auditList(query.domains))")
            }
            if !query.activitySessionIDs.isEmpty {
                parts.append("sessions=\(auditList(query.activitySessionIDs.map(\.rawValue)))")
            }
            parts.append("limit=\(query.limit)")
        }
        if let visualRequest = request.visualSearchRequest {
            let scope = visualRequest.scope
            if let start = scope.startDate { parts.append("since=\(ISO8601DateFormatter().string(from: start))") }
            if let end = scope.endDate { parts.append("until=\(ISO8601DateFormatter().string(from: end))") }
            if !scope.applicationBundleIdentifiers.isEmpty {
                parts.append("apps=\(auditList(scope.applicationBundleIdentifiers))")
            }
            if !scope.domains.isEmpty {
                parts.append("domains=\(auditList(scope.domains))")
            }
            parts.append("requested=\(visualRequest.resultLimit)")
            parts.append("byteBudget=\(visualRequest.utf8ByteBudget)")
            parts.append("disclosure=\(visualRequest.disclosure.rawValue)")
            parts.append("minimumSimilarity=\(minimumVisualSimilarity)")
        }
        if let capsuleRequest = request.memoryCapsuleRequest {
            parts.append("requested=\(capsuleRequest.resultLimit)")
            parts.append("byteBudget=\(capsuleRequest.utf8ByteBudget)")
            parts.append("retrieval=\(capsuleRequest.retrievalModalities.map(\.rawValue).joined(separator: ","))")
            parts.append("disclosure=\(capsuleRequest.disclosure.rawValue)")
            parts.append("minimumVisualSimilarity=\(minimumVisualSimilarity)")
        }
        if let query = request.activitySessionQuery {
            if let start = query.startDate { parts.append("since=\(ISO8601DateFormatter().string(from: start))") }
            if let end = query.endDate { parts.append("until=\(ISO8601DateFormatter().string(from: end))") }
            parts.append("limit=\(query.limit)")
            parts.append("requestedSensitive=\(query.includeSensitive)")
            parts.append("sensitive=false")
        }
        if let bundleRequest = request.bundleRequest {
            parts.append("requested=\(bundleRequest.resultLimit)")
            parts.append("byteBudget=\(bundleRequest.utf8ByteBudget)")
            parts.append("disclosure=\(bundleRequest.disclosure.rawValue)")
        } else if let limit = request.recentLimit {
            parts.append("limit=\(limit)")
        }
        if request.capability == .bundle
            || request.capability == .visualSearch
            || request.capability == .memoryCapsule
            || request.capability == .search
            || request.capability == .recent
            || request.capability == .frame {
            parts.append("sensitive=false")
        }
        if case .bundle(let bundle) = result {
            parts.append("candidates=\(bundle.candidateCount)")
            parts.append("matched=\(bundle.matchedCount)")
            parts.append("disclosed=\(bundle.disclosedCount)")
            parts.append("encodedBytes=\(bundle.encodedUTF8Bytes)")
            parts.append("truncated=\(bundle.truncated)")
            if !bundle.omissions.isEmpty {
                parts.append("omissions=\(bundle.omissions.map { "\($0.reason.rawValue):\($0.count)" }.joined(separator: ","))")
            }
        } else if case .visualSearch(let manifest) = result {
            parts.append("matched=\(manifest.matchedCount)")
            parts.append("disclosed=\(manifest.disclosedCount)")
            parts.append("encodedBytes=\(manifest.encodedUTF8Bytes)")
            parts.append("indexed=\(manifest.coverage.indexedEligibleFrameCount)/\(manifest.coverage.eligibleFrameCount)")
            parts.append("truncated=\(manifest.truncated)")
        } else if case .memoryCapsule(let manifest) = result {
            parts.append("candidates=\(manifest.candidateCount)")
            parts.append("disclosed=\(manifest.disclosedCount)")
            parts.append("encodedBytes=\(manifest.encodedUTF8Bytes)")
            parts.append("textCandidates=\(manifest.coverage.savedTextCandidateCount)")
            parts.append("visualCandidates=\(manifest.coverage.visualAppearanceCandidateCount)")
            parts.append("multimodalCandidates=\(manifest.coverage.multimodalCandidateCount)")
            parts.append("truncated=\(manifest.truncated)")
            if !manifest.omissions.isEmpty {
                parts.append("omissions=\(manifest.omissions.map { "\($0.reason.rawValue):\($0.count)" }.joined(separator: ","))")
            }
        } else if case .sessions(let sessions) = result {
            parts.append("returned=\(sessions.count)")
        }
        return boundedSummary(parts.joined(separator: "; "))
    }

    private static func boundedSummary(_ value: String) -> String {
        let flattened = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(1_024))
    }

    private static func auditList<S: Sequence>(_ values: S) -> String
    where S.Element == String {
        values.map(auditToken).sorted().joined(separator: ",")
    }

    private static func auditToken(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: ".-_:/@"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "invalid"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
