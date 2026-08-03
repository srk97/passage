import Foundation

/// One-call retrieval for an agent that needs useful, directly citable memory
/// evidence without joining Passage's text and visual APIs itself.
public enum PassageMemoryCapsuleSchema {
    public static let currentVersion: UInt16 = 1
    public static let maximumQueryUTF8Bytes = 4 * 1_024
    public static let defaultResultLimit = 8
    public static let maximumResultLimit = 24
    public static let minimumUTF8ByteBudget = 2 * 1_024
    public static let defaultUTF8ByteBudget = 64 * 1_024
    public static let maximumUTF8ByteBudget = 512 * 1_024
    public static let maximumAccessibilityNodesPerSource = 8
}

public enum PassageMemoryRetrievalModality: String, Codable, CaseIterable, Hashable, Sendable {
    case savedText
    case visualAppearance
}

public enum PassageMemoryEvidenceModality: String, Codable, CaseIterable, Hashable, Sendable {
    case ocr
    case accessibility
    case visualSimilarity
}

public enum PassageMemoryCapsuleDisclosure: String, Codable, CaseIterable, Hashable, Sendable {
    /// Bounded OCR, bounded native Accessibility semantics, visual-match
    /// provenance, and source metadata. Pixel bytes, media paths, OCR geometry,
    /// embedding vectors, and display/window identifiers are excluded.
    case structuredEvidence
}

public struct PassageMemoryCapsuleRequest: Codable, Hashable, Sendable {
    public var query: SearchQuery
    public var retrievalModalities: [PassageMemoryRetrievalModality]
    public var resultLimit: Int
    public var utf8ByteBudget: Int
    public var disclosure: PassageMemoryCapsuleDisclosure

    public init(
        query: SearchQuery,
        retrievalModalities: [PassageMemoryRetrievalModality] = PassageMemoryRetrievalModality.allCases,
        resultLimit: Int = PassageMemoryCapsuleSchema.defaultResultLimit,
        utf8ByteBudget: Int = PassageMemoryCapsuleSchema.defaultUTF8ByteBudget,
        disclosure: PassageMemoryCapsuleDisclosure = .structuredEvidence
    ) {
        self.query = query
        self.retrievalModalities = retrievalModalities
        self.resultLimit = resultLimit
        self.utf8ByteBudget = utf8ByteBudget
        self.disclosure = disclosure
    }
}

/// A normalized, intentionally shallow projection of one native control or
/// visible content node. This is an agent-facing type, not a raw AX tree.
public struct PassageMemoryAccessibilityEvidence: Codable, Hashable, Sendable {
    public var role: String
    public var label: String?
    public var value: String?
    public var depth: Int
    public var normalizedBounds: ScreenRect?

    public init(
        role: String,
        label: String? = nil,
        value: String? = nil,
        depth: Int,
        normalizedBounds: ScreenRect? = nil
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.depth = depth
        self.normalizedBounds = normalizedBounds
    }
}

public struct PassageMemoryVisualEvidence: Codable, Hashable, Sendable {
    public var similarity: Double
    public var maximumSimilarityError: Double
    public var minimumPossibleSimilarity: Double
    public var associatedFrameCount: Int
    public var modelIdentifier: String
    public var modelRevision: String

    public init(
        similarity: Double,
        maximumSimilarityError: Double,
        associatedFrameCount: Int,
        modelIdentifier: String,
        modelRevision: String
    ) {
        self.similarity = similarity
        self.maximumSimilarityError = maximumSimilarityError
        minimumPossibleSimilarity = similarity - maximumSimilarityError
        self.associatedFrameCount = associatedFrameCount
        self.modelIdentifier = modelIdentifier
        self.modelRevision = modelRevision
    }
}

public enum PassageMemorySelectionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case fusedRank
    case savedTextCoverage
    case visualAppearanceCoverage
    case activitySessionDiversity
    case applicationDiversity
    case domainDiversity
}

public struct PassageMemoryCapsuleSource: Codable, Hashable, Sendable {
    public var frameID: FrameID
    public var activitySessionID: ActivitySessionID?
    public var fusedRank: Int
    public var savedTextRank: Int?
    public var visualAppearanceRank: Int?
    public var capturedAt: Date
    public var applicationName: String
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var domain: String?
    public var url: String?
    public var evidenceModalities: [PassageMemoryEvidenceModality]
    public var selectionReasons: [PassageMemorySelectionReason]
    public var ocrText: String
    public var ocrTextTruncated: Bool
    public var accessibility: [PassageMemoryAccessibilityEvidence]
    public var accessibilityTruncated: Bool
    public var visual: PassageMemoryVisualEvidence?

    public init(
        frameID: FrameID,
        activitySessionID: ActivitySessionID? = nil,
        fusedRank: Int,
        savedTextRank: Int? = nil,
        visualAppearanceRank: Int? = nil,
        capturedAt: Date,
        applicationName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        domain: String? = nil,
        url: String? = nil,
        evidenceModalities: [PassageMemoryEvidenceModality],
        selectionReasons: [PassageMemorySelectionReason],
        ocrText: String,
        ocrTextTruncated: Bool = false,
        accessibility: [PassageMemoryAccessibilityEvidence] = [],
        accessibilityTruncated: Bool = false,
        visual: PassageMemoryVisualEvidence? = nil
    ) {
        self.frameID = frameID
        self.activitySessionID = activitySessionID
        self.fusedRank = fusedRank
        self.savedTextRank = savedTextRank
        self.visualAppearanceRank = visualAppearanceRank
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.domain = domain
        self.url = url
        self.evidenceModalities = evidenceModalities
        self.selectionReasons = selectionReasons
        self.ocrText = ocrText
        self.ocrTextTruncated = ocrTextTruncated
        self.accessibility = accessibility
        self.accessibilityTruncated = accessibilityTruncated
        self.visual = visual
    }
}

public struct PassageMemoryCapsuleCoverage: Codable, Hashable, Sendable {
    public var candidateCount: Int
    public var savedTextCandidateCount: Int
    public var visualAppearanceCandidateCount: Int
    public var multimodalCandidateCount: Int
    public var disclosedSavedTextCount: Int
    public var disclosedAccessibilityCount: Int
    public var disclosedVisualAppearanceCount: Int
    public var visualIndexCoverageFraction: Double?
    public var isLowerBound: Bool

    public init(
        candidateCount: Int = 0,
        savedTextCandidateCount: Int = 0,
        visualAppearanceCandidateCount: Int = 0,
        multimodalCandidateCount: Int = 0,
        disclosedSavedTextCount: Int = 0,
        disclosedAccessibilityCount: Int = 0,
        disclosedVisualAppearanceCount: Int = 0,
        visualIndexCoverageFraction: Double? = nil,
        isLowerBound: Bool = false
    ) {
        self.candidateCount = candidateCount
        self.savedTextCandidateCount = savedTextCandidateCount
        self.visualAppearanceCandidateCount = visualAppearanceCandidateCount
        self.multimodalCandidateCount = multimodalCandidateCount
        self.disclosedSavedTextCount = disclosedSavedTextCount
        self.disclosedAccessibilityCount = disclosedAccessibilityCount
        self.disclosedVisualAppearanceCount = disclosedVisualAppearanceCount
        self.visualIndexCoverageFraction = visualIndexCoverageFraction
        self.isLowerBound = isLowerBound
    }
}

public enum PassageMemoryCapsuleOmissionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case sensitiveContext
    case resultLimit
    case byteBudget
    case candidateWindow
    case ocrTruncation
    case accessibilityTruncation
    case visualIndexUnavailable
    case visualIndexPartial
}

public struct PassageMemoryCapsuleOmissionSummary: Codable, Hashable, Sendable {
    public var reason: PassageMemoryCapsuleOmissionReason
    public var count: Int
    public var countIsLowerBound: Bool

    public init(
        reason: PassageMemoryCapsuleOmissionReason,
        count: Int,
        countIsLowerBound: Bool = false
    ) {
        self.reason = reason
        self.count = count
        self.countIsLowerBound = countIsLowerBound
    }
}

public struct PassageMemoryCapsuleManifest: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16
    public var disclosure: PassageMemoryCapsuleDisclosure
    public var retrievalModalities: [PassageMemoryRetrievalModality]
    public var requestedCount: Int
    public var candidateCount: Int
    public var hasMoreCandidates: Bool
    public var disclosedCount: Int
    public var utf8ByteBudget: Int
    public var encodedUTF8Bytes: Int
    public var truncated: Bool
    public var coverage: PassageMemoryCapsuleCoverage
    public var omissions: [PassageMemoryCapsuleOmissionSummary]
    public var sources: [PassageMemoryCapsuleSource]

    public init(
        schemaVersion: UInt16 = PassageMemoryCapsuleSchema.currentVersion,
        disclosure: PassageMemoryCapsuleDisclosure = .structuredEvidence,
        retrievalModalities: [PassageMemoryRetrievalModality],
        requestedCount: Int,
        candidateCount: Int,
        hasMoreCandidates: Bool,
        disclosedCount: Int = 0,
        utf8ByteBudget: Int,
        encodedUTF8Bytes: Int = 0,
        truncated: Bool,
        coverage: PassageMemoryCapsuleCoverage,
        omissions: [PassageMemoryCapsuleOmissionSummary],
        sources: [PassageMemoryCapsuleSource]
    ) {
        self.schemaVersion = schemaVersion
        self.disclosure = disclosure
        self.retrievalModalities = retrievalModalities
        self.requestedCount = requestedCount
        self.candidateCount = candidateCount
        self.hasMoreCandidates = hasMoreCandidates
        self.disclosedCount = disclosedCount
        self.utf8ByteBudget = utf8ByteBudget
        self.encodedUTF8Bytes = encodedUTF8Bytes
        self.truncated = truncated
        self.coverage = coverage
        self.omissions = omissions
        self.sources = sources
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// A private-app candidate supplied to the deterministic projection builder.
/// Media paths in `hit` are deliberately discarded during projection.
public struct PassageMemoryCapsuleCandidate: Hashable, Sendable {
    public var hit: SearchHit
    public var ocrText: String
    public var accessibility: [PassageMemoryAccessibilityEvidence]
    public var savedTextRank: Int?
    public var visualAppearanceRank: Int?
    public var visual: PassageMemoryVisualEvidence?

    public init(
        hit: SearchHit,
        ocrText: String,
        accessibility: [PassageMemoryAccessibilityEvidence] = [],
        savedTextRank: Int? = nil,
        visualAppearanceRank: Int? = nil,
        visual: PassageMemoryVisualEvidence? = nil
    ) {
        self.hit = hit
        self.ocrText = ocrText
        self.accessibility = accessibility
        self.savedTextRank = savedTextRank
        self.visualAppearanceRank = visualAppearanceRank
        self.visual = visual
    }
}

public enum PassageMemoryCapsuleBuildError: Error, LocalizedError, Sendable {
    case byteBudgetTooSmall(minimumBytes: Int)
    case couldNotStabilizeEncodedSize

    public var errorDescription: String? {
        switch self {
        case .byteBudgetTooSmall(let minimumBytes):
            "The memory capsule byte budget is too small; its manifest needs at least \(minimumBytes) UTF-8 bytes."
        case .couldNotStabilizeEncodedSize:
            "Passage could not determine a stable encoded memory capsule size."
        }
    }
}

public enum PassageMemoryCapsuleBuilder {
    public static func build(
        request: PassageMemoryCapsuleRequest,
        candidates input: [PassageMemoryCapsuleCandidate],
        hasMoreCandidates: Bool = false,
        visualIndexCoverageFraction: Double? = nil,
        additionalOmissions: [PassageMemoryCapsuleOmissionSummary] = []
    ) throws -> PassageMemoryCapsuleManifest {
        let candidates = ranked(
            input.filter { !$0.hit.context.isSensitive },
            query: request.query.text,
            requestedModalities: Set(request.retrievalModalities)
        )
        let selected = select(
            candidates,
            requestedModalities: request.retrievalModalities,
            limit: max(request.resultLimit, 0)
        )

        let empty = try manifest(
            request: request,
            candidates: candidates,
            selectedCount: selected.count,
            hasMoreCandidates: hasMoreCandidates,
            visualIndexCoverageFraction: visualIndexCoverageFraction,
            additionalOmissions: additionalOmissions,
            sources: []
        )
        guard empty.encodedUTF8Bytes <= request.utf8ByteBudget else {
            throw PassageMemoryCapsuleBuildError.byteBudgetTooSmall(
                minimumBytes: empty.encodedUTF8Bytes
            )
        }

        var sources: [PassageMemoryCapsuleSource] = []
        for candidate in selected {
            var shell = source(from: candidate)
            shell.ocrText = ""
            shell.ocrTextTruncated = !candidate.candidate.ocrText.isEmpty
            shell.accessibility = []
            shell.accessibilityTruncated = !candidate.candidate.accessibility.isEmpty
            let trial = try manifest(
                request: request,
                candidates: candidates,
                selectedCount: selected.count,
                hasMoreCandidates: hasMoreCandidates,
                visualIndexCoverageFraction: visualIndexCoverageFraction,
                additionalOmissions: additionalOmissions,
                sources: sources + [shell]
            )
            if trial.encodedUTF8Bytes <= request.utf8ByteBudget {
                sources.append(shell)
            }
        }

        // Native semantic evidence is compact and generally more trustworthy
        // than OCR. Add only the most query-relevant nodes, with a hard per-source
        // cap, then spend the remaining exact budget on Unicode-safe OCR text.
        for index in sources.indices {
            guard let candidate = selected.first(where: {
                $0.candidate.hit.id == sources[index].frameID
            }) else { continue }
            for node in candidate.candidate.accessibility
                .prefix(PassageMemoryCapsuleSchema.maximumAccessibilityNodesPerSource) {
                var trialSources = sources
                trialSources[index].accessibility.append(node)
                trialSources[index].accessibilityTruncated =
                    trialSources[index].accessibility.count < candidate.candidate.accessibility.count
                let trial = try manifest(
                    request: request,
                    candidates: candidates,
                    selectedCount: selected.count,
                    hasMoreCandidates: hasMoreCandidates,
                    visualIndexCoverageFraction: visualIndexCoverageFraction,
                    additionalOmissions: additionalOmissions,
                    sources: trialSources
                )
                guard trial.encodedUTF8Bytes <= request.utf8ByteBudget else { break }
                sources = trialSources
            }

            let characters = Array(candidate.candidate.ocrText)
            var lower = 0
            var upper = characters.count
            var best = sources[index]
            while lower <= upper {
                let midpoint = lower + (upper - lower) / 2
                var trialSources = sources
                trialSources[index].ocrText = String(characters.prefix(midpoint))
                trialSources[index].ocrTextTruncated = midpoint < characters.count
                let trial = try manifest(
                    request: request,
                    candidates: candidates,
                    selectedCount: selected.count,
                    hasMoreCandidates: hasMoreCandidates,
                    visualIndexCoverageFraction: visualIndexCoverageFraction,
                    additionalOmissions: additionalOmissions,
                    sources: trialSources
                )
                if trial.encodedUTF8Bytes <= request.utf8ByteBudget {
                    best = trialSources[index]
                    lower = midpoint + 1
                } else {
                    upper = midpoint - 1
                }
            }
            sources[index] = best
        }

        return try manifest(
            request: request,
            candidates: candidates,
            selectedCount: selected.count,
            hasMoreCandidates: hasMoreCandidates,
            visualIndexCoverageFraction: visualIndexCoverageFraction,
            additionalOmissions: additionalOmissions,
            sources: sources
        )
    }

    private struct RankedCandidate {
        var candidate: PassageMemoryCapsuleCandidate
        var fusedScore: Double
        var fusedRank: Int
        var reasons: Set<PassageMemorySelectionReason> = []
    }

    private static func ranked(
        _ input: [PassageMemoryCapsuleCandidate],
        query: String,
        requestedModalities: Set<PassageMemoryRetrievalModality>
    ) -> [RankedCandidate] {
        let queryTokens = normalizedTokens(query)
        return input.map { candidate in
            var normalizedCandidate = candidate
            if !requestedModalities.contains(.savedText) {
                normalizedCandidate.savedTextRank = nil
            }
            if !requestedModalities.contains(.visualAppearance) {
                normalizedCandidate.visualAppearanceRank = nil
                normalizedCandidate.visual = nil
            }
            let textContribution = normalizedCandidate.savedTextRank.map {
                reciprocalRank($0)
            } ?? 0
            let visualContribution = normalizedCandidate.visualAppearanceRank.map {
                reciprocalRank($0)
            } ?? 0
            normalizedCandidate.accessibility = normalizedAccessibility(
                candidate.accessibility,
                queryTokens: queryTokens
            )
            return RankedCandidate(
                candidate: normalizedCandidate,
                fusedScore: textContribution + visualContribution,
                fusedRank: 0
            )
        }.filter {
            $0.candidate.savedTextRank != nil || $0.candidate.visualAppearanceRank != nil
        }.sorted(by: rankPrecedes).enumerated().map { offset, value in
            var value = value
            value.fusedRank = offset + 1
            return value
        }
    }

    private static func reciprocalRank(_ rank: Int) -> Double {
        1 / Double(60 + max(rank, 1))
    }

    private static func select(
        _ candidates: [RankedCandidate],
        requestedModalities: [PassageMemoryRetrievalModality],
        limit: Int
    ) -> [RankedCandidate] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        var selected: [Int] = []
        var selectedSet = Set<Int>()
        var coveredModalities = Set<PassageMemoryRetrievalModality>()
        var coveredSessions = Set<String>()
        var coveredApplications = Set<String>()
        var coveredDomains = Set<String>()
        var reasonsByIndex = [Int: Set<PassageMemorySelectionReason>]()

        func record(_ index: Int, reasons: Set<PassageMemorySelectionReason>) {
            guard selectedSet.insert(index).inserted else {
                reasonsByIndex[index, default: []].formUnion(reasons)
                return
            }
            selected.append(index)
            reasonsByIndex[index, default: []].formUnion(reasons)
            coveredModalities.formUnion(modalities(of: candidates[index]))
            if let value = sessionIdentity(candidates[index].candidate.hit.activitySessionID) {
                coveredSessions.insert(value)
            }
            if let value = applicationIdentity(candidates[index].candidate.hit.context) {
                coveredApplications.insert(value)
            }
            if let value = domainIdentity(candidates[index].candidate.hit.context.domain) {
                coveredDomains.insert(value)
            }
        }

        record(0, reasons: [.fusedRank])
        for modality in orderedUnique(requestedModalities) where selected.count < limit {
            guard !coveredModalities.contains(modality),
                  let index = candidates.indices.first(where: {
                      !selectedSet.contains($0) && modalities(of: candidates[$0]).contains(modality)
                  }) else { continue }
            let reason: PassageMemorySelectionReason = modality == .savedText
                ? .savedTextCoverage
                : .visualAppearanceCoverage
            record(index, reasons: [reason])
        }

        while selected.count < min(limit, candidates.count) {
            let remaining = candidates.indices.filter { !selectedSet.contains($0) }
            guard let best = remaining.max(by: { left, right in
                let leftGain = diversityGain(
                    candidates[left],
                    coveredModalities: coveredModalities,
                    coveredSessions: coveredSessions,
                    coveredApplications: coveredApplications,
                    coveredDomains: coveredDomains
                )
                let rightGain = diversityGain(
                    candidates[right],
                    coveredModalities: coveredModalities,
                    coveredSessions: coveredSessions,
                    coveredApplications: coveredApplications,
                    coveredDomains: coveredDomains
                )
                if leftGain != rightGain { return leftGain < rightGain }
                return rankPrecedes(candidates[right], candidates[left])
            }) else { break }

            var reasons: Set<PassageMemorySelectionReason> = [.fusedRank]
            if let value = sessionIdentity(candidates[best].candidate.hit.activitySessionID),
               !coveredSessions.contains(value) {
                reasons.insert(.activitySessionDiversity)
            }
            if let value = applicationIdentity(candidates[best].candidate.hit.context),
               !coveredApplications.contains(value) {
                reasons.insert(.applicationDiversity)
            }
            if let value = domainIdentity(candidates[best].candidate.hit.context.domain),
               !coveredDomains.contains(value) {
                reasons.insert(.domainDiversity)
            }
            if candidates[best].candidate.savedTextRank != nil,
               !coveredModalities.contains(.savedText) {
                reasons.insert(.savedTextCoverage)
            }
            if candidates[best].candidate.visualAppearanceRank != nil,
               !coveredModalities.contains(.visualAppearance) {
                reasons.insert(.visualAppearanceCoverage)
            }
            record(best, reasons: reasons)
        }

        return selected.map { index in
            var result = candidates[index]
            result.reasons = reasonsByIndex[index, default: []]
            return result
        }
    }

    private static func diversityGain(
        _ candidate: RankedCandidate,
        coveredModalities: Set<PassageMemoryRetrievalModality>,
        coveredSessions: Set<String>,
        coveredApplications: Set<String>,
        coveredDomains: Set<String>
    ) -> Int {
        var gain = modalities(of: candidate).subtracting(coveredModalities).count * 2
        if let value = sessionIdentity(candidate.candidate.hit.activitySessionID),
           !coveredSessions.contains(value) { gain += 1 }
        if let value = applicationIdentity(candidate.candidate.hit.context),
           !coveredApplications.contains(value) { gain += 1 }
        if let value = domainIdentity(candidate.candidate.hit.context.domain),
           !coveredDomains.contains(value) { gain += 1 }
        return gain
    }

    private static func source(from candidate: RankedCandidate) -> PassageMemoryCapsuleSource {
        var evidence: [PassageMemoryEvidenceModality] = []
        if !candidate.candidate.ocrText.isEmpty { evidence.append(.ocr) }
        if !candidate.candidate.accessibility.isEmpty { evidence.append(.accessibility) }
        if candidate.candidate.visual != nil { evidence.append(.visualSimilarity) }
        let reasonOrder = Dictionary(uniqueKeysWithValues:
            PassageMemorySelectionReason.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        return PassageMemoryCapsuleSource(
            frameID: candidate.candidate.hit.id,
            activitySessionID: candidate.candidate.hit.activitySessionID,
            fusedRank: candidate.fusedRank,
            savedTextRank: candidate.candidate.savedTextRank,
            visualAppearanceRank: candidate.candidate.visualAppearanceRank,
            capturedAt: candidate.candidate.hit.capturedAt,
            applicationName: candidate.candidate.hit.context.applicationName,
            bundleIdentifier: candidate.candidate.hit.context.bundleIdentifier,
            windowTitle: candidate.candidate.hit.context.windowTitle,
            domain: normalizedDomain(candidate.candidate.hit.context.domain),
            url: sanitizedURLString(candidate.candidate.hit.context.url),
            evidenceModalities: evidence,
            selectionReasons: candidate.reasons.sorted {
                reasonOrder[$0, default: 0] < reasonOrder[$1, default: 0]
            },
            ocrText: candidate.candidate.ocrText,
            accessibility: candidate.candidate.accessibility,
            visual: candidate.candidate.visual
        )
    }

    private static func manifest(
        request: PassageMemoryCapsuleRequest,
        candidates: [RankedCandidate],
        selectedCount: Int,
        hasMoreCandidates: Bool,
        visualIndexCoverageFraction: Double?,
        additionalOmissions: [PassageMemoryCapsuleOmissionSummary],
        sources unsortedSources: [PassageMemoryCapsuleSource]
    ) throws -> PassageMemoryCapsuleManifest {
        let sources = unsortedSources.map { source -> PassageMemoryCapsuleSource in
            var source = source
            var disclosed: [PassageMemoryEvidenceModality] = []
            if !source.ocrText.isEmpty { disclosed.append(.ocr) }
            if !source.accessibility.isEmpty { disclosed.append(.accessibility) }
            if source.visual != nil { disclosed.append(.visualSimilarity) }
            source.evidenceModalities = disclosed
            return source
        }.sorted(by: chronologicallyPrecedes)
        var omissionCounts = [PassageMemoryCapsuleOmissionReason: (Int, Bool)]()
        func add(_ reason: PassageMemoryCapsuleOmissionReason, _ count: Int, lowerBound: Bool = false) {
            guard count > 0 else { return }
            let previous = omissionCounts[reason] ?? (0, false)
            omissionCounts[reason] = (previous.0 + count, previous.1 || lowerBound)
        }
        // The app-side query removes private rows before this builder. Do not
        // serialize even an exact count if a defense-in-depth caller supplies
        // one: the existence of filtered private history is itself private.
        add(.resultLimit, max(candidates.count - selectedCount, 0))
        add(.byteBudget, max(selectedCount - sources.count, 0))
        add(.ocrTruncation, sources.count(where: { $0.ocrTextTruncated }))
        add(.accessibilityTruncation, sources.count(where: { $0.accessibilityTruncated }))
        if hasMoreCandidates { add(.candidateWindow, 1, lowerBound: true) }
        for omission in additionalOmissions {
            add(omission.reason, omission.count, lowerBound: omission.countIsLowerBound)
        }
        let omissionOrder = Dictionary(uniqueKeysWithValues:
            PassageMemoryCapsuleOmissionReason.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        let omissions = omissionCounts.map { reason, value in
            PassageMemoryCapsuleOmissionSummary(
                reason: reason,
                count: value.0,
                countIsLowerBound: value.1
            )
        }.sorted { omissionOrder[$0.reason, default: 0] < omissionOrder[$1.reason, default: 0] }

        let coverage = PassageMemoryCapsuleCoverage(
            candidateCount: candidates.count,
            savedTextCandidateCount: candidates.count(where: { $0.candidate.savedTextRank != nil }),
            visualAppearanceCandidateCount: candidates.count(where: { $0.candidate.visualAppearanceRank != nil }),
            multimodalCandidateCount: candidates.count(where: {
                $0.candidate.savedTextRank != nil && $0.candidate.visualAppearanceRank != nil
            }),
            disclosedSavedTextCount: sources.count(where: { $0.savedTextRank != nil }),
            disclosedAccessibilityCount: sources.count(where: { !$0.accessibility.isEmpty }),
            disclosedVisualAppearanceCount: sources.count(where: { $0.visual != nil }),
            visualIndexCoverageFraction: visualIndexCoverageFraction,
            isLowerBound: hasMoreCandidates
        )
        return try stabilized(PassageMemoryCapsuleManifest(
            disclosure: request.disclosure,
            retrievalModalities: orderedUnique(request.retrievalModalities),
            requestedCount: request.resultLimit,
            candidateCount: candidates.count,
            hasMoreCandidates: hasMoreCandidates,
            utf8ByteBudget: request.utf8ByteBudget,
            truncated: !omissions.isEmpty,
            coverage: coverage,
            omissions: omissions,
            sources: sources
        ))
    }

    private static func normalizedAccessibility(
        _ nodes: [PassageMemoryAccessibilityEvidence],
        queryTokens: Set<String>
    ) -> [PassageMemoryAccessibilityEvidence] {
        let normalized = nodes.compactMap { node -> PassageMemoryAccessibilityEvidence? in
            let role = boundedText(node.role, maximumCharacters: 64) ?? ""
            let label = boundedText(node.label, maximumCharacters: 240)
            let value = boundedText(node.value, maximumCharacters: 480)
            guard !role.isEmpty, label != nil || value != nil else { return nil }
            return PassageMemoryAccessibilityEvidence(
                role: role,
                label: label,
                value: value,
                depth: min(max(node.depth, 0), 32),
                normalizedBounds: normalizedBounds(node.normalizedBounds)
            )
        }
        var seen = Set<PassageMemoryAccessibilityEvidence>()
        return normalized.filter { seen.insert($0).inserted }.sorted { left, right in
            let leftScore = semanticRelevance(left, queryTokens: queryTokens)
            let rightScore = semanticRelevance(right, queryTokens: queryTokens)
            if leftScore != rightScore { return leftScore > rightScore }
            if left.depth != right.depth { return left.depth < right.depth }
            let leftY = left.normalizedBounds?.y ?? 2
            let rightY = right.normalizedBounds?.y ?? 2
            if leftY != rightY { return leftY < rightY }
            let leftX = left.normalizedBounds?.x ?? 2
            let rightX = right.normalizedBounds?.x ?? 2
            if leftX != rightX { return leftX < rightX }
            return (left.label ?? left.value ?? left.role) < (right.label ?? right.value ?? right.role)
        }
    }

    private static func semanticRelevance(
        _ node: PassageMemoryAccessibilityEvidence,
        queryTokens: Set<String>
    ) -> Int {
        guard !queryTokens.isEmpty else { return 0 }
        let nodeTokens = normalizedTokens([node.label, node.value].compactMap { $0 }.joined(separator: " "))
        return nodeTokens.intersection(queryTokens).count
    }

    private static func boundedText(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
                return " "
            }
            return Character(scalar)
        }
        let trimmed = String(cleaned)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumCharacters))
    }

    private static func normalizedBounds(_ bounds: ScreenRect?) -> ScreenRect? {
        guard let bounds,
              bounds.x.isFinite, bounds.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let x = min(max(bounds.x, 0), 1)
        let y = min(max(bounds.y, 0), 1)
        let width = min(max(bounds.width, 0), 1 - x)
        let height = min(max(bounds.height, 0), 1 - y)
        guard width > 0, height > 0 else { return nil }
        return ScreenRect(x: x, y: y, width: width, height: height)
    }

    private static func normalizedTokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func sanitizedURLString(_ url: URL?) -> String? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        // Paths frequently contain document IDs, reset tokens, filenames, or
        // user names. Agent capsules need site provenance, not navigation state.
        components.path = ""
        return components.url?.absoluteString
    }

    private static func normalizedDomain(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    private static func modalities(
        of candidate: RankedCandidate
    ) -> Set<PassageMemoryRetrievalModality> {
        var result = Set<PassageMemoryRetrievalModality>()
        if candidate.candidate.savedTextRank != nil { result.insert(.savedText) }
        if candidate.candidate.visualAppearanceRank != nil { result.insert(.visualAppearance) }
        return result
    }

    private static func orderedUnique<T: CaseIterable & Hashable>(_ values: [T]) -> [T] where T.AllCases: Collection {
        let requested = Set(values)
        return Array(T.allCases).filter(requested.contains)
    }

    private static func sessionIdentity(_ value: ActivitySessionID?) -> String? {
        normalizedIdentity(value?.rawValue)
    }

    private static func applicationIdentity(_ context: ScreenContext) -> String? {
        if let bundle = normalizedIdentity(context.bundleIdentifier) { return "bundle:\(bundle)" }
        return normalizedIdentity(context.applicationName).map { "name:\($0)" }
    }

    private static func domainIdentity(_ value: String?) -> String? {
        normalizedIdentity(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func rankPrecedes(_ left: RankedCandidate, _ right: RankedCandidate) -> Bool {
        if left.fusedScore != right.fusedScore { return left.fusedScore > right.fusedScore }
        let leftBest = min(left.candidate.savedTextRank ?? .max, left.candidate.visualAppearanceRank ?? .max)
        let rightBest = min(right.candidate.savedTextRank ?? .max, right.candidate.visualAppearanceRank ?? .max)
        if leftBest != rightBest { return leftBest < rightBest }
        if left.candidate.hit.capturedAt != right.candidate.hit.capturedAt {
            return left.candidate.hit.capturedAt > right.candidate.hit.capturedAt
        }
        return left.candidate.hit.id.rawValue < right.candidate.hit.id.rawValue
    }

    private static func chronologicallyPrecedes(
        _ left: PassageMemoryCapsuleSource,
        _ right: PassageMemoryCapsuleSource
    ) -> Bool {
        if left.capturedAt != right.capturedAt { return left.capturedAt < right.capturedAt }
        if left.fusedRank != right.fusedRank { return left.fusedRank < right.fusedRank }
        return left.frameID.rawValue < right.frameID.rawValue
    }

    private static func stabilized(
        _ manifest: PassageMemoryCapsuleManifest
    ) throws -> PassageMemoryCapsuleManifest {
        var result = manifest
        for _ in 0..<32 {
            result.disclosedCount = result.sources.count
            let bytes = try result.canonicalJSONData().count
            if result.encodedUTF8Bytes == bytes { return result }
            result.encodedUTF8Bytes = bytes
        }
        throw PassageMemoryCapsuleBuildError.couldNotStabilizeEncodedSize
    }
}
