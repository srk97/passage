import Foundation

/// Stable schema values for Passage's provenance-first agent context bundles.
public enum PassageContextBundleSchema {
    public static let currentVersion: UInt16 = 2
    public static let defaultResultLimit = 12
    /// Kept one below the store search ceiling so every request can reserve one
    /// look-ahead match and truthfully flag candidate-window truncation.
    public static let maximumResultLimit = 99
    /// Version 2 carries explicit selection, coverage, and omission metadata.
    public static let minimumUTF8ByteBudget = 1_024
    public static let defaultUTF8ByteBudget = 16 * 1_024
    public static let maximumUTF8ByteBudget = 256 * 1_024
}

public enum PassageContextDisclosure: String, Codable, CaseIterable, Hashable, Sendable {
    /// Source metadata and OCR snippets only. Screenshots, media paths, and OCR
    /// geometry never cross the bundle boundary.
    case textOnly
}

/// The bounded retrieval payload carried by the local service protocol.
public struct PassageContextBundleRequest: Codable, Hashable, Sendable {
    public var query: SearchQuery
    public var resultLimit: Int
    public var utf8ByteBudget: Int
    public var disclosure: PassageContextDisclosure

    public init(
        query: SearchQuery,
        resultLimit: Int = PassageContextBundleSchema.defaultResultLimit,
        utf8ByteBudget: Int = PassageContextBundleSchema.defaultUTF8ByteBudget,
        disclosure: PassageContextDisclosure = .textOnly
    ) {
        self.query = query
        self.resultLimit = resultLimit
        self.utf8ByteBudget = utf8ByteBudget
        self.disclosure = disclosure
    }
}

/// Why a source survived diversity selection. Reasons describe independent
/// contributions, so a run representative can carry more than one reason.
public enum PassageContextSelectionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case retrievalRank
    case observedRunRepresentative
    case activitySessionDiversity
    case applicationDiversity
    case domainDiversity
    case transitionCoverage

    public static var rankFill: Self { .retrievalRank }
    public static var runRepresentative: Self { .observedRunRepresentative }
    public static var sessionDiversity: Self { .activitySessionDiversity }
    public static var appDiversity: Self { .applicationDiversity }
}

public typealias PassageContextSourceSelectionReason = PassageContextSelectionReason

/// A chronological, locally observed run in the supplied candidate window.
/// Runs are intentionally descriptive rather than durable session identities.
public struct PassageContextObservedRun: Codable, Hashable, Sendable {
    /// One-based chronological position in the privacy-filtered candidate window.
    public var index: Int
    public var startedAt: Date
    public var endedAt: Date
    public var candidateCount: Int
    public var representativeRetrievalRank: Int

    public init(
        index: Int,
        startedAt: Date,
        endedAt: Date,
        candidateCount: Int,
        representativeRetrievalRank: Int
    ) {
        self.index = index
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.candidateCount = candidateCount
        self.representativeRetrievalRank = representativeRetrievalRank
    }

    public var chronologicalIndex: Int { index }
    public var ordinal: Int { index }
    public var frameCount: Int { candidateCount }
}

public typealias PassageContextRun = PassageContextObservedRun

/// A stable reason that candidate evidence is absent or incomplete.
public enum PassageContextOmissionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case sensitiveContext
    case temporalDuplicate
    case resultLimit
    case byteBudget
    case snippetTruncation
    case candidateWindow

    public static var sensitive: Self { .sensitiveContext }
    public static var selectionLimit: Self { .resultLimit }
}

public typealias PassageContextBundleOmissionReason = PassageContextOmissionReason

/// Aggregate omission metadata. Candidate-window counts are lower bounds because
/// the builder deliberately does not perform an unbounded count query.
public struct PassageContextOmissionSummary: Codable, Hashable, Sendable {
    public var reason: PassageContextOmissionReason
    public var count: Int
    public var countIsLowerBound: Bool

    public init(
        reason: PassageContextOmissionReason,
        count: Int,
        countIsLowerBound: Bool = false
    ) {
        self.reason = reason
        self.count = count
        self.countIsLowerBound = countIsLowerBound
    }

    public var omittedCount: Int { count }

    private enum CodingKeys: String, CodingKey {
        case reason
        case count
        case countIsLowerBound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(PassageContextOmissionReason.self, forKey: .reason)
        count = try container.decode(Int.self, forKey: .count)
        countIsLowerBound = try container.decodeIfPresent(
            Bool.self,
            forKey: .countIsLowerBound
        ) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(count, forKey: .count)
        if countIsLowerBound {
            try container.encode(true, forKey: .countIsLowerBound)
        }
    }
}

public typealias PassageContextBundleOmissionSummary = PassageContextOmissionSummary

/// Diversity available in the privacy-filtered candidate window and represented
/// by the final disclosed sources. `isLowerBound` applies to available totals.
public struct PassageContextBundleCoverage: Codable, Hashable, Sendable {
    public var observedRunCount: Int
    public var disclosedObservedRunCount: Int
    public var activitySessionCount: Int
    public var disclosedActivitySessionCount: Int
    public var applicationCount: Int
    public var disclosedApplicationCount: Int
    public var domainCount: Int
    public var disclosedDomainCount: Int
    public var transitionCount: Int
    public var disclosedTransitionCount: Int
    public var isLowerBound: Bool

    public init(
        observedRunCount: Int = 0,
        disclosedObservedRunCount: Int = 0,
        activitySessionCount: Int = 0,
        disclosedActivitySessionCount: Int = 0,
        applicationCount: Int = 0,
        disclosedApplicationCount: Int = 0,
        domainCount: Int = 0,
        disclosedDomainCount: Int = 0,
        transitionCount: Int = 0,
        disclosedTransitionCount: Int = 0,
        isLowerBound: Bool = false
    ) {
        self.observedRunCount = observedRunCount
        self.disclosedObservedRunCount = disclosedObservedRunCount
        self.activitySessionCount = activitySessionCount
        self.disclosedActivitySessionCount = disclosedActivitySessionCount
        self.applicationCount = applicationCount
        self.disclosedApplicationCount = disclosedApplicationCount
        self.domainCount = domainCount
        self.disclosedDomainCount = disclosedDomainCount
        self.transitionCount = transitionCount
        self.disclosedTransitionCount = disclosedTransitionCount
        self.isLowerBound = isLowerBound
    }

    public var candidateWindowIsLowerBound: Bool { isLowerBound }
    public var selectedObservedRunCount: Int { disclosedObservedRunCount }
    public var sessionCount: Int { activitySessionCount }
    public var selectedSessionCount: Int { disclosedActivitySessionCount }
    public var appCount: Int { applicationCount }
    public var selectedAppCount: Int { disclosedApplicationCount }
    public var selectedDomainCount: Int { disclosedDomainCount }
    public var coveredTransitionCount: Int { disclosedTransitionCount }

    private enum CodingKeys: String, CodingKey {
        case observedRunCount
        case disclosedObservedRunCount
        case activitySessionCount
        case disclosedActivitySessionCount
        case applicationCount
        case disclosedApplicationCount
        case domainCount
        case disclosedDomainCount
        case transitionCount
        case disclosedTransitionCount
        case isLowerBound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedRunCount = try container.decodeIfPresent(Int.self, forKey: .observedRunCount) ?? 0
        disclosedObservedRunCount = try container.decodeIfPresent(
            Int.self,
            forKey: .disclosedObservedRunCount
        ) ?? 0
        activitySessionCount = try container.decodeIfPresent(
            Int.self,
            forKey: .activitySessionCount
        ) ?? 0
        disclosedActivitySessionCount = try container.decodeIfPresent(
            Int.self,
            forKey: .disclosedActivitySessionCount
        ) ?? 0
        applicationCount = try container.decodeIfPresent(Int.self, forKey: .applicationCount) ?? 0
        disclosedApplicationCount = try container.decodeIfPresent(
            Int.self,
            forKey: .disclosedApplicationCount
        ) ?? 0
        domainCount = try container.decodeIfPresent(Int.self, forKey: .domainCount) ?? 0
        disclosedDomainCount = try container.decodeIfPresent(
            Int.self,
            forKey: .disclosedDomainCount
        ) ?? 0
        transitionCount = try container.decodeIfPresent(Int.self, forKey: .transitionCount) ?? 0
        disclosedTransitionCount = try container.decodeIfPresent(
            Int.self,
            forKey: .disclosedTransitionCount
        ) ?? 0
        isLowerBound = try container.decodeIfPresent(Bool.self, forKey: .isLowerBound) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeNonzero(observedRunCount, forKey: .observedRunCount, into: &container)
        try encodeNonzero(
            disclosedObservedRunCount,
            forKey: .disclosedObservedRunCount,
            into: &container
        )
        try encodeNonzero(activitySessionCount, forKey: .activitySessionCount, into: &container)
        try encodeNonzero(
            disclosedActivitySessionCount,
            forKey: .disclosedActivitySessionCount,
            into: &container
        )
        try encodeNonzero(applicationCount, forKey: .applicationCount, into: &container)
        try encodeNonzero(
            disclosedApplicationCount,
            forKey: .disclosedApplicationCount,
            into: &container
        )
        try encodeNonzero(domainCount, forKey: .domainCount, into: &container)
        try encodeNonzero(disclosedDomainCount, forKey: .disclosedDomainCount, into: &container)
        try encodeNonzero(transitionCount, forKey: .transitionCount, into: &container)
        try encodeNonzero(
            disclosedTransitionCount,
            forKey: .disclosedTransitionCount,
            into: &container
        )
        if isLowerBound {
            try container.encode(true, forKey: .isLowerBound)
        }
    }

    private func encodeNonzero(
        _ value: Int,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if value != 0 {
            try container.encode(value, forKey: key)
        }
    }
}

public typealias PassageContextCoverage = PassageContextBundleCoverage

/// One directly citable source in a context bundle. The frame ID and capture time
/// are the durable provenance key; all other fields are text-only evidence.
public struct PassageContextSource: Codable, Hashable, Sendable {
    public var frameID: FrameID
    public var activitySessionID: ActivitySessionID?
    public var retrievalRank: Int
    public var capturedAt: Date
    public var applicationName: String
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var domain: String?
    public var url: String?
    public var ocrSnippet: String
    public var snippetTruncated: Bool
    public var run: PassageContextObservedRun?
    public var reasons: [PassageContextSelectionReason]

    public init(
        frameID: FrameID,
        capturedAt: Date,
        applicationName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        domain: String? = nil,
        url: String? = nil,
        ocrSnippet: String,
        snippetTruncated: Bool = false,
        activitySessionID: ActivitySessionID? = nil,
        retrievalRank: Int = 0,
        run: PassageContextObservedRun? = nil,
        reasons: [PassageContextSelectionReason] = []
    ) {
        self.frameID = frameID
        self.activitySessionID = activitySessionID
        self.retrievalRank = retrievalRank
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.domain = domain
        self.url = url
        self.ocrSnippet = ocrSnippet
        self.snippetTruncated = snippetTruncated
        self.run = run
        self.reasons = reasons
    }

    public var observedRun: PassageContextObservedRun? { run }
    public var selectionReasons: [PassageContextSelectionReason] { reasons }
}

/// A compact, source-cited response whose canonical encoded size is part of the
/// manifest. `encodedUTF8Bytes` measures this object using `canonicalJSONData()`.
public struct PassageContextBundleManifest: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16
    public var disclosure: PassageContextDisclosure
    public var requestedCount: Int
    /// Legacy name for the number observed in the bounded candidate window.
    public var matchedCount: Int
    public var candidateCount: Int
    public var hasMoreCandidates: Bool
    public var disclosedCount: Int
    public var utf8ByteBudget: Int
    public var encodedUTF8Bytes: Int
    public var truncated: Bool
    public var coverage: PassageContextBundleCoverage
    public var omissions: [PassageContextOmissionSummary]
    public var sources: [PassageContextSource]

    public init(
        schemaVersion: UInt16 = PassageContextBundleSchema.currentVersion,
        disclosure: PassageContextDisclosure = .textOnly,
        requestedCount: Int,
        matchedCount: Int,
        candidateCount: Int? = nil,
        hasMoreCandidates: Bool = false,
        disclosedCount: Int? = nil,
        utf8ByteBudget: Int,
        encodedUTF8Bytes: Int = 0,
        truncated: Bool,
        coverage: PassageContextBundleCoverage = .init(),
        omissions: [PassageContextOmissionSummary] = [],
        sources: [PassageContextSource]
    ) {
        self.schemaVersion = schemaVersion
        self.disclosure = disclosure
        self.requestedCount = requestedCount
        self.matchedCount = matchedCount
        self.candidateCount = candidateCount ?? matchedCount
        self.hasMoreCandidates = hasMoreCandidates
        self.disclosedCount = disclosedCount ?? sources.count
        self.utf8ByteBudget = utf8ByteBudget
        self.encodedUTF8Bytes = encodedUTF8Bytes
        self.truncated = truncated
        self.coverage = coverage
        self.omissions = omissions
        self.sources = sources
    }

    /// Canonical representation used to enforce the byte budget independently of
    /// whitespace or formatting choices made by a CLI consumer.
    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var omissionSummaries: [PassageContextOmissionSummary] { omissions }
}

public enum PassageContextBundleBuildError: Error, LocalizedError, Sendable {
    case byteBudgetTooSmall(minimumBytes: Int)
    case couldNotStabilizeEncodedSize

    public var errorDescription: String? {
        switch self {
        case .byteBudgetTooSmall(let minimumBytes):
            "The context bundle byte budget is too small; the manifest needs at least \(minimumBytes) UTF-8 bytes."
        case .couldNotStabilizeEncodedSize:
            "Passage could not determine a stable encoded context bundle size."
        }
    }
}

/// Deterministically projects a bounded retrieval window into a privacy-filtered,
/// diversity-aware manifest. Callers that know whether the window has a next page
/// should pass that fact explicitly. A nil value preserves version 1 inference.
public enum PassageContextBundleBuilder {
    public static func build(
        request: PassageContextBundleRequest,
        hits: [SearchHit],
        hasMoreCandidates: Bool? = nil
    ) throws -> PassageContextBundleManifest {
        let candidateCount = hits.count
        let effectiveHasMoreCandidates = hasMoreCandidates
            ?? (hits.count > max(request.resultLimit, 0))
        let ranked = hits.enumerated().compactMap { offset, hit -> RankedCandidate? in
            // Defense in depth: privacy filtering precedes grouping, coverage,
            // diversity selection, and all source metadata projection.
            guard !hit.context.isSensitive else { return nil }
            return RankedCandidate(hit: hit, retrievalRank: offset + 1)
        }
        let sensitiveCount = candidateCount - ranked.count
        let observed = observeRuns(in: ranked)
        let deduplicated = suppressTemporalDuplicates(in: observed.candidates)
        let selected = select(
            deduplicated.candidates,
            resultLimit: max(request.resultLimit, 0)
        )

        var shellSources: [PassageContextSource] = []
        for choice in selected {
            let fullSource = source(from: choice)
            var shell = fullSource
            shell.ocrSnippet = ""
            shell.snippetTruncated = !fullSource.ocrSnippet.isEmpty
            let trial = try manifest(
                request: request,
                candidateCount: candidateCount,
                hasMoreCandidates: effectiveHasMoreCandidates,
                sensitiveCount: sensitiveCount,
                temporalDuplicateCount: deduplicated.omittedCount,
                candidates: observed.candidates,
                selectableCandidateCount: deduplicated.candidates.count,
                runCount: observed.runCount,
                selectedCount: selected.count,
                sources: shellSources + [shell]
            )
            if trial.encodedUTF8Bytes <= request.utf8ByteBudget {
                shellSources.append(shell)
            }
            // A source whose metadata shell cannot fit is omitted, but it never
            // prevents a later compact source from being considered.
        }

        let empty = try manifest(
            request: request,
            candidateCount: candidateCount,
            hasMoreCandidates: effectiveHasMoreCandidates,
            sensitiveCount: sensitiveCount,
            temporalDuplicateCount: deduplicated.omittedCount,
            candidates: observed.candidates,
            selectableCandidateCount: deduplicated.candidates.count,
            runCount: observed.runCount,
            selectedCount: selected.count,
            sources: []
        )
        guard empty.encodedUTF8Bytes <= request.utf8ByteBudget else {
            throw PassageContextBundleBuildError.byteBudgetTooSmall(
                minimumBytes: empty.encodedUTF8Bytes
            )
        }

        // With the final set of metadata shells known, spend remaining bytes on
        // snippets in selection order. Swift Character prefixes preserve extended
        // grapheme clusters while each probe uses the exact canonical JSON size.
        for sourceIndex in shellSources.indices {
            guard let choice = selected.first(where: {
                $0.retrievalRank == shellSources[sourceIndex].retrievalRank
            }) else { continue }
            let fullSource = source(from: choice)
            var fullTrialSources = shellSources
            fullTrialSources[sourceIndex] = fullSource
            let fullTrial = try manifest(
                request: request,
                candidateCount: candidateCount,
                hasMoreCandidates: effectiveHasMoreCandidates,
                sensitiveCount: sensitiveCount,
                temporalDuplicateCount: deduplicated.omittedCount,
                candidates: observed.candidates,
                selectableCandidateCount: deduplicated.candidates.count,
                runCount: observed.runCount,
                selectedCount: selected.count,
                sources: fullTrialSources
            )
            if fullTrial.encodedUTF8Bytes <= request.utf8ByteBudget {
                shellSources[sourceIndex] = fullSource
                continue
            }

            let characters = Array(fullSource.ocrSnippet)
            var lowerBound = 0
            var upperBound = characters.count
            var best = shellSources[sourceIndex]
            while lowerBound <= upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                var trialSource = fullSource
                trialSource.ocrSnippet = String(characters.prefix(midpoint))
                trialSource.snippetTruncated = midpoint < characters.count
                var trialSources = shellSources
                trialSources[sourceIndex] = trialSource
                let trial = try manifest(
                    request: request,
                    candidateCount: candidateCount,
                    hasMoreCandidates: effectiveHasMoreCandidates,
                    sensitiveCount: sensitiveCount,
                    temporalDuplicateCount: deduplicated.omittedCount,
                    candidates: observed.candidates,
                    selectableCandidateCount: deduplicated.candidates.count,
                    runCount: observed.runCount,
                    selectedCount: selected.count,
                    sources: trialSources
                )
                if trial.encodedUTF8Bytes <= request.utf8ByteBudget {
                    best = trialSource
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint - 1
                }
            }
            shellSources[sourceIndex] = best
        }

        return try manifest(
            request: request,
            candidateCount: candidateCount,
            hasMoreCandidates: effectiveHasMoreCandidates,
            sensitiveCount: sensitiveCount,
            temporalDuplicateCount: deduplicated.omittedCount,
            candidates: observed.candidates,
            selectableCandidateCount: deduplicated.candidates.count,
            runCount: observed.runCount,
            selectedCount: selected.count,
            sources: shellSources
        )
    }

    private struct RankedCandidate {
        var hit: SearchHit
        var retrievalRank: Int
        var run: PassageContextObservedRun?
        var reasons: [PassageContextSelectionReason] = []
    }

    private struct ObservedCandidates {
        var candidates: [RankedCandidate]
        var runCount: Int
    }

    private struct DeduplicatedCandidates {
        var candidates: [RankedCandidate]
        var omittedCount: Int
    }

    private struct TemporalEvidenceIdentity: Hashable {
        var runIndex: Int
        var session: String
        var application: String
        var domain: String?
        var windowTitle: String?
        var url: String?
        var snippet: String
    }

    /// A deliberately short interval avoids treating periodic observations of
    /// a stable screen as one event. The strict boundary is conservative: two
    /// observations exactly this far apart remain independently selectable.
    private static let temporalDuplicateInterval: TimeInterval = 15

    private static func observeRuns(in input: [RankedCandidate]) -> ObservedCandidates {
        var candidates = input
        let chronologicalIndices = candidates.indices.sorted {
            chronologicallyPrecedes(candidates[$0], candidates[$1])
        }
        var memberGroups: [[Int]] = []
        for candidateIndex in chronologicalIndices {
            if let previousIndex = memberGroups.last?.last,
               !startsNewRun(after: candidates[previousIndex], before: candidates[candidateIndex]) {
                memberGroups[memberGroups.count - 1].append(candidateIndex)
            } else {
                memberGroups.append([candidateIndex])
            }
        }

        for (offset, members) in memberGroups.enumerated() {
            guard let firstIndex = members.first, let lastIndex = members.last else { continue }
            let representativeRank = members.map { candidates[$0].retrievalRank }.min() ?? 0
            let run = PassageContextObservedRun(
                index: offset + 1,
                startedAt: candidates[firstIndex].hit.capturedAt,
                endedAt: candidates[lastIndex].hit.capturedAt,
                candidateCount: members.count,
                representativeRetrievalRank: representativeRank
            )
            for member in members {
                candidates[member].run = run
            }
        }
        return ObservedCandidates(candidates: candidates, runCount: memberGroups.count)
    }

    /// Suppression runs after privacy filtering and run observation, but before
    /// diversity selection. That ordering prevents private metadata from
    /// influencing identity, preserves full-window run and coverage facts, and
    /// keeps duplicates out of result-limit accounting.
    private static func suppressTemporalDuplicates(
        in input: [RankedCandidate]
    ) -> DeduplicatedCandidates {
        guard input.count > 1 else {
            return DeduplicatedCandidates(candidates: input, omittedCount: 0)
        }

        let chronologicalIndices = input.indices.sorted {
            chronologicallyPrecedes(input[$0], input[$1])
        }
        var contiguousGroups: [[Int]] = []
        var previousIdentity: TemporalEvidenceIdentity?
        for index in chronologicalIndices {
            let identity = temporalEvidenceIdentity(for: input[index])
            if let identity, identity == previousIdentity {
                contiguousGroups[contiguousGroups.count - 1].append(index)
            } else {
                contiguousGroups.append([index])
            }
            previousIdentity = identity
        }

        var retainedIndices = Set<Int>()
        for group in contiguousGroups {
            // Retrieval rank is the relevance authority inside one exact
            // evidence run. Greedily retaining it first also makes every
            // suppressed observation point to a better-ranked nearby peer.
            let rankedGroup = group.sorted {
                if input[$0].retrievalRank != input[$1].retrievalRank {
                    return input[$0].retrievalRank < input[$1].retrievalRank
                }
                if input[$0].hit.capturedAt != input[$1].hit.capturedAt {
                    return input[$0].hit.capturedAt < input[$1].hit.capturedAt
                }
                return input[$0].hit.id.rawValue < input[$1].hit.id.rawValue
            }
            var accepted: [Int] = []
            for index in rankedGroup {
                let isNearDuplicate = accepted.contains { retainedIndex in
                    abs(input[index].hit.capturedAt.timeIntervalSince(
                        input[retainedIndex].hit.capturedAt
                    )) < temporalDuplicateInterval
                }
                if !isNearDuplicate {
                    accepted.append(index)
                    retainedIndices.insert(index)
                }
            }
        }

        let candidates = input.indices.compactMap { index in
            retainedIndices.contains(index) ? input[index] : nil
        }
        return DeduplicatedCandidates(
            candidates: candidates,
            omittedCount: input.count - candidates.count
        )
    }

    private static func temporalEvidenceIdentity(
        for candidate: RankedCandidate
    ) -> TemporalEvidenceIdentity? {
        guard let runIndex = candidate.run?.index,
              let session = sessionIdentity(candidate.hit.activitySessionID),
              let application = applicationIdentity(candidate.hit.context),
              let snippet = whitespaceNormalized(candidate.hit.snippet) else { return nil }
        return TemporalEvidenceIdentity(
            runIndex: runIndex,
            session: session,
            application: application,
            domain: domainIdentity(candidate.hit.context.domain),
            windowTitle: whitespaceNormalized(candidate.hit.context.windowTitle),
            // Full URL identity remains in-memory only. Keeping query and
            // fragment distinctions here prevents two private navigation
            // states from being collapsed even though disclosure later strips
            // those components.
            url: candidate.hit.context.url?.absoluteString,
            snippet: snippet
        )
    }

    private static func startsNewRun(
        after previous: RankedCandidate,
        before current: RankedCandidate
    ) -> Bool {
        let previousSession = sessionIdentity(previous.hit.activitySessionID)
        let currentSession = sessionIdentity(current.hit.activitySessionID)
        guard let previousSession, let currentSession,
              previousSession == currentSession else { return true }
        guard let previousApplication = applicationIdentity(previous.hit.context),
              let currentApplication = applicationIdentity(current.hit.context),
              previousApplication == currentApplication else { return true }
        guard domainIdentity(previous.hit.context.domain)
            == domainIdentity(current.hit.context.domain) else { return true }
        return current.hit.capturedAt.timeIntervalSince(previous.hit.capturedAt) >= 60
    }

    private static func select(
        _ candidates: [RankedCandidate],
        resultLimit: Int
    ) -> [RankedCandidate] {
        guard resultLimit > 0, !candidates.isEmpty else { return [] }
        let representatives = candidates.indices.filter { index in
            candidates[index].run?.representativeRetrievalRank == candidates[index].retrievalRank
        }
        var selectedIndices: [Int] = []
        var selectedSet: Set<Int> = []
        var coveredSessions: Set<String> = []
        var coveredApplications: Set<String> = []
        var coveredDomains: Set<String> = []
        var coveredRuns: Set<Int> = []
        var reasonByIndex: [Int: Set<PassageContextSelectionReason>] = [:]

        func diversityReasons(for index: Int) -> (Set<PassageContextSelectionReason>, Int) {
            let candidate = candidates[index]
            var reasons: Set<PassageContextSelectionReason> = []
            var gain = 0
            if let session = sessionIdentity(candidate.hit.activitySessionID),
               !coveredSessions.contains(session) {
                reasons.insert(.activitySessionDiversity)
                gain += 1
            }
            if let application = applicationIdentity(candidate.hit.context),
               !coveredApplications.contains(application) {
                reasons.insert(.applicationDiversity)
                gain += 1
            }
            if let domain = domainIdentity(candidate.hit.context.domain),
               !coveredDomains.contains(domain) {
                reasons.insert(.domainDiversity)
                gain += 1
            }
            if let run = candidate.run?.index {
                let adjacentCoveredCount = [run - 1, run + 1].filter(coveredRuns.contains).count
                if adjacentCoveredCount > 0 {
                    reasons.insert(.transitionCoverage)
                    gain += adjacentCoveredCount
                }
            }
            return (reasons, gain)
        }

        func record(_ index: Int, reasons: Set<PassageContextSelectionReason>) {
            selectedIndices.append(index)
            selectedSet.insert(index)
            reasonByIndex[index, default: []].formUnion(reasons)
            if let value = sessionIdentity(candidates[index].hit.activitySessionID) {
                coveredSessions.insert(value)
            }
            if let value = applicationIdentity(candidates[index].hit.context) {
                coveredApplications.insert(value)
            }
            if let value = domainIdentity(candidates[index].hit.context.domain) {
                coveredDomains.insert(value)
            }
            if let value = candidates[index].run?.index {
                coveredRuns.insert(value)
            }
        }

        if let first = representatives.min(by: {
            candidates[$0].retrievalRank < candidates[$1].retrievalRank
        }) {
            var reasons = diversityReasons(for: first).0
            reasons.formUnion([.retrievalRank, .observedRunRepresentative])
            record(first, reasons: reasons)
        }

        while selectedIndices.count < resultLimit {
            let remaining = representatives.filter { !selectedSet.contains($0) }
            guard !remaining.isEmpty else { break }
            let best = remaining.max { left, right in
                let leftGain = diversityReasons(for: left).1
                let rightGain = diversityReasons(for: right).1
                if leftGain != rightGain { return leftGain < rightGain }
                if candidates[left].retrievalRank != candidates[right].retrievalRank {
                    return candidates[left].retrievalRank > candidates[right].retrievalRank
                }
                return candidates[left].hit.id.rawValue > candidates[right].hit.id.rawValue
            }!
            var reasons = diversityReasons(for: best).0
            reasons.insert(.observedRunRepresentative)
            record(best, reasons: reasons)
        }

        if selectedIndices.count < resultLimit {
            let rankedRemainder = candidates.indices
                .filter { !selectedSet.contains($0) }
                .sorted {
                    if candidates[$0].retrievalRank != candidates[$1].retrievalRank {
                        return candidates[$0].retrievalRank < candidates[$1].retrievalRank
                    }
                    return candidates[$0].hit.id.rawValue < candidates[$1].hit.id.rawValue
                }
            for index in rankedRemainder.prefix(resultLimit - selectedIndices.count) {
                record(index, reasons: [.retrievalRank])
            }
        }

        let reasonOrder = Dictionary(uniqueKeysWithValues:
            PassageContextSelectionReason.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        return selectedIndices.map { index in
            var candidate = candidates[index]
            candidate.reasons = Array(reasonByIndex[index, default: []]).sorted {
                reasonOrder[$0, default: 0] < reasonOrder[$1, default: 0]
            }
            return candidate
        }
    }

    private static func source(from candidate: RankedCandidate) -> PassageContextSource {
        PassageContextSource(
            frameID: candidate.hit.id,
            capturedAt: candidate.hit.capturedAt,
            applicationName: candidate.hit.context.applicationName,
            bundleIdentifier: candidate.hit.context.bundleIdentifier,
            windowTitle: candidate.hit.context.windowTitle,
            domain: candidate.hit.context.domain,
            url: sanitizedURLString(candidate.hit.context.url),
            ocrSnippet: candidate.hit.snippet,
            activitySessionID: candidate.hit.activitySessionID,
            retrievalRank: candidate.retrievalRank,
            run: candidate.run,
            reasons: candidate.reasons
        )
    }

    /// Page URLs can contain credentials, access tokens, search terms, and UI
    /// state. A text bundle needs stable source provenance, not those secrets.
    private static func sanitizedURLString(_ url: URL?) -> String? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func manifest(
        request: PassageContextBundleRequest,
        candidateCount: Int,
        hasMoreCandidates: Bool,
        sensitiveCount: Int,
        temporalDuplicateCount: Int,
        candidates: [RankedCandidate],
        selectableCandidateCount: Int,
        runCount: Int,
        selectedCount: Int,
        sources unsortedSources: [PassageContextSource]
    ) throws -> PassageContextBundleManifest {
        let sources = unsortedSources.sorted(by: chronologicallyPrecedes)
        let resultLimitCount = max(selectableCandidateCount - selectedCount, 0)
        let byteBudgetCount = max(selectedCount - sources.count, 0)
        let snippetTruncationCount = sources.filter(\.snippetTruncated).count
        var omissions: [PassageContextOmissionSummary] = []
        if sensitiveCount > 0 {
            omissions.append(.init(reason: .sensitiveContext, count: sensitiveCount))
        }
        if temporalDuplicateCount > 0 {
            omissions.append(.init(reason: .temporalDuplicate, count: temporalDuplicateCount))
        }
        if resultLimitCount > 0 {
            omissions.append(.init(reason: .resultLimit, count: resultLimitCount))
        }
        if byteBudgetCount > 0 {
            omissions.append(.init(reason: .byteBudget, count: byteBudgetCount))
        }
        if snippetTruncationCount > 0 {
            omissions.append(.init(reason: .snippetTruncation, count: snippetTruncationCount))
        }
        if hasMoreCandidates {
            omissions.append(.init(
                reason: .candidateWindow,
                count: 1,
                countIsLowerBound: true
            ))
        }
        let coverage = coverage(
            candidates: candidates,
            runCount: runCount,
            sources: sources,
            isLowerBound: hasMoreCandidates
        )
        return try stabilized(PassageContextBundleManifest(
            disclosure: request.disclosure,
            requestedCount: request.resultLimit,
            matchedCount: candidateCount,
            candidateCount: candidateCount,
            hasMoreCandidates: hasMoreCandidates,
            utf8ByteBudget: request.utf8ByteBudget,
            truncated: !omissions.isEmpty,
            coverage: coverage,
            omissions: omissions,
            sources: sources
        ))
    }

    private static func coverage(
        candidates: [RankedCandidate],
        runCount: Int,
        sources: [PassageContextSource],
        isLowerBound: Bool
    ) -> PassageContextBundleCoverage {
        let candidateSessions = Set(candidates.compactMap { sessionIdentity($0.hit.activitySessionID) })
        let candidateApplications = Set(candidates.compactMap { applicationIdentity($0.hit.context) })
        let candidateDomains = Set(candidates.compactMap { domainIdentity($0.hit.context.domain) })
        let disclosedSessions = Set(sources.compactMap { sessionIdentity($0.activitySessionID) })
        let disclosedApplications = Set(sources.compactMap { applicationIdentity($0) })
        let disclosedDomains = Set(sources.compactMap { domainIdentity($0.domain) })
        let disclosedRuns = Set(sources.compactMap { $0.run?.index })
        let disclosedTransitions = max(runCount - 1, 0) == 0 ? 0 : (1..<runCount).reduce(0) {
            $0 + (disclosedRuns.contains($1) && disclosedRuns.contains($1 + 1) ? 1 : 0)
        }
        return PassageContextBundleCoverage(
            observedRunCount: runCount,
            disclosedObservedRunCount: disclosedRuns.count,
            activitySessionCount: candidateSessions.count,
            disclosedActivitySessionCount: disclosedSessions.count,
            applicationCount: candidateApplications.count,
            disclosedApplicationCount: disclosedApplications.count,
            domainCount: candidateDomains.count,
            disclosedDomainCount: disclosedDomains.count,
            transitionCount: max(runCount - 1, 0),
            disclosedTransitionCount: disclosedTransitions,
            isLowerBound: isLowerBound
        )
    }

    private static func sessionIdentity(_ value: ActivitySessionID?) -> String? {
        normalized(value?.rawValue)
    }

    private static func applicationIdentity(_ context: ScreenContext) -> String? {
        if let bundleIdentifier = normalized(context.bundleIdentifier) {
            return "bundle:\(bundleIdentifier)"
        }
        return normalized(context.applicationName).map { "name:\($0)" }
    }

    private static func applicationIdentity(_ source: PassageContextSource) -> String? {
        if let bundleIdentifier = normalized(source.bundleIdentifier) {
            return "bundle:\(bundleIdentifier)"
        }
        return normalized(source.applicationName).map { "name:\($0)" }
    }

    private static func domainIdentity(_ value: String?) -> String? {
        normalized(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func whitespaceNormalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func chronologicallyPrecedes(
        _ left: RankedCandidate,
        _ right: RankedCandidate
    ) -> Bool {
        if left.hit.capturedAt != right.hit.capturedAt {
            return left.hit.capturedAt < right.hit.capturedAt
        }
        if left.retrievalRank != right.retrievalRank {
            return left.retrievalRank < right.retrievalRank
        }
        return left.hit.id.rawValue < right.hit.id.rawValue
    }

    private static func chronologicallyPrecedes(
        _ left: PassageContextSource,
        _ right: PassageContextSource
    ) -> Bool {
        if left.capturedAt != right.capturedAt { return left.capturedAt < right.capturedAt }
        if left.retrievalRank != right.retrievalRank { return left.retrievalRank < right.retrievalRank }
        return left.frameID.rawValue < right.frameID.rawValue
    }

    private static func stabilized(
        _ manifest: PassageContextBundleManifest
    ) throws -> PassageContextBundleManifest {
        var result = manifest
        // The only self-reference is the decimal width of encodedUTF8Bytes, so
        // convergence takes at most a handful of digit-boundary adjustments.
        for _ in 0..<32 {
            result.disclosedCount = result.sources.count
            let byteCount = try result.canonicalJSONData().count
            if result.encodedUTF8Bytes == byteCount {
                return result
            }
            result.encodedUTF8Bytes = byteCount
        }
        throw PassageContextBundleBuildError.couldNotStabilizeEncodedSize
    }
}
