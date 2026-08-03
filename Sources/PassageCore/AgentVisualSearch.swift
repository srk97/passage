import Foundation

/// Stable bounds for Passage's metadata-only agent visual-search surface.
public enum PassageAgentVisualSearchSchema {
    public static let currentVersion: UInt16 = 1
    public static let maximumDescriptionUTF8Bytes = 4 * 1_024
    public static let minimumResultLimit = 1
    public static let defaultResultLimit = 6
    public static let maximumResultLimit = 20
    public static let minimumUTF8ByteBudget = 1 * 1_024
    public static let defaultUTF8ByteBudget = 64 * 1_024
    public static let maximumUTF8ByteBudget = 256 * 1_024
}

public enum PassageAgentVisualSearchDisclosure: String, Codable, CaseIterable, Hashable, Sendable {
    /// Source metadata and bounded OCR text only. Screenshot bytes, embedding
    /// vectors, media paths, display/window identifiers, and geometry are absent.
    case metadataOnly
}

/// A bounded request for locally derived image-appearance matches.
public struct PassageAgentVisualSearchRequest: Codable, Hashable, Sendable {
    public var description: String
    public var scope: RecallScope
    public var resultLimit: Int
    public var utf8ByteBudget: Int
    public var disclosure: PassageAgentVisualSearchDisclosure

    public init(
        description: String,
        scope: RecallScope = RecallScope(),
        resultLimit: Int = PassageAgentVisualSearchSchema.defaultResultLimit,
        utf8ByteBudget: Int = PassageAgentVisualSearchSchema.defaultUTF8ByteBudget,
        disclosure: PassageAgentVisualSearchDisclosure = .metadataOnly
    ) {
        self.description = description
        self.scope = scope
        self.resultLimit = resultLimit
        self.utf8ByteBudget = utf8ByteBudget
        self.disclosure = disclosure
    }
}

/// Aggregate, non-sensitive index state relevant to interpreting a visual
/// result set. Paths and embedding-vector contents are deliberately absent.
public struct PassageAgentVisualSearchCoverageSummary: Codable, Hashable, Sendable {
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

    public init(coverage: VisualEmbeddingCoverage) {
        self.init(
            model: coverage.model,
            eligibleFrameCount: coverage.eligibleFrameCount,
            indexedEligibleFrameCount: coverage.indexedEligibleFrameCount,
            indexedFrameCount: coverage.indexedFrameCount,
            pendingEligibleFrameCount: coverage.pendingEligibleFrameCount,
            staleEmbeddingCount: coverage.staleEmbeddingCount,
            uniqueVectorCount: coverage.uniqueVectorCount,
            deduplicatedFrameCount: coverage.deduplicatedFrameCount,
            storedVectorPayloadBytes: coverage.storedVectorPayloadBytes,
            coverageFraction: coverage.coverageFraction
        )
    }
}

/// One citable, path-free source admitted by the fixed visual relevance policy.
public struct PassageAgentVisualSearchSource: Codable, Hashable, Sendable {
    public var frameID: FrameID
    public var capturedAt: Date
    public var applicationName: String
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var domain: String?
    public var url: String?
    public var ocrSnippet: String
    public var snippetTruncated: Bool
    public var similarity: Double
    public var maximumSimilarityError: Double
    public var minimumPossibleSimilarity: Double
    public var associatedFrameCount: Int
    public var model: VisualModelIdentity

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
        similarity: Double,
        maximumSimilarityError: Double,
        minimumPossibleSimilarity: Double,
        associatedFrameCount: Int,
        model: VisualModelIdentity
    ) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.domain = domain
        self.url = url
        self.ocrSnippet = ocrSnippet
        self.snippetTruncated = snippetTruncated
        self.similarity = similarity
        self.maximumSimilarityError = maximumSimilarityError
        self.minimumPossibleSimilarity = minimumPossibleSimilarity
        self.associatedFrameCount = associatedFrameCount
        self.model = model
    }
}

/// Why otherwise relevant candidate evidence was not fully disclosed.
public enum PassageAgentVisualSearchOmissionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case sensitiveContext
    case belowMinimumSimilarity
    case resultLimit
    case utf8ByteBudget
    case ocrSnippetTruncated
}

/// Canonical metadata-only response to an agent visual-search request.
public struct PassageAgentVisualSearchManifest: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16
    public var disclosure: PassageAgentVisualSearchDisclosure
    public var minimumSimilarity: Double
    public var coverage: PassageAgentVisualSearchCoverageSummary
    public var requestedCount: Int
    public var matchedCount: Int
    public var disclosedCount: Int
    public var hasMore: Bool
    public var truncated: Bool
    public var encodedUTF8Bytes: Int
    public var utf8ByteBudget: Int
    public var omissionReasons: [PassageAgentVisualSearchOmissionReason]
    public var sources: [PassageAgentVisualSearchSource]

    public init(
        schemaVersion: UInt16 = PassageAgentVisualSearchSchema.currentVersion,
        disclosure: PassageAgentVisualSearchDisclosure = .metadataOnly,
        minimumSimilarity: Double,
        coverage: PassageAgentVisualSearchCoverageSummary,
        requestedCount: Int,
        matchedCount: Int,
        disclosedCount: Int? = nil,
        hasMore: Bool,
        truncated: Bool,
        encodedUTF8Bytes: Int = 0,
        utf8ByteBudget: Int,
        omissionReasons: [PassageAgentVisualSearchOmissionReason],
        sources: [PassageAgentVisualSearchSource]
    ) {
        self.schemaVersion = schemaVersion
        self.disclosure = disclosure
        self.minimumSimilarity = minimumSimilarity
        self.coverage = coverage
        self.requestedCount = requestedCount
        self.matchedCount = matchedCount
        self.disclosedCount = disclosedCount ?? sources.count
        self.hasMore = hasMore
        self.truncated = truncated
        self.encodedUTF8Bytes = encodedUTF8Bytes
        self.utf8ByteBudget = utf8ByteBudget
        self.omissionReasons = omissionReasons
        self.sources = sources
    }

    /// Canonical representation used for exact, formatting-independent byte
    /// accounting on both sides of the local service boundary.
    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum PassageAgentVisualSearchBuildError: Error, LocalizedError, Sendable {
    case invalidMinimumSimilarity
    case byteBudgetTooSmall(minimumBytes: Int)
    case couldNotStabilizeEncodedSize

    public var errorDescription: String? {
        switch self {
        case .invalidMinimumSimilarity:
            "The visual-search admission threshold must be a finite value between -1 and 1."
        case .byteBudgetTooSmall(let minimumBytes):
            "The visual-search byte budget is too small; the manifest needs at least \(minimumBytes) UTF-8 bytes."
        case .couldNotStabilizeEncodedSize:
            "Passage could not determine a stable encoded visual-search size."
        }
    }
}

/// Projects already bounded local embedding matches into a deterministic,
/// metadata-only disclosure. The caller owns the calibrated fixed admission
/// threshold; this boundary rechecks it using the conservative similarity lower
/// bound and independently filters sensitive records.
public enum PassageAgentVisualSearchBuilder {
    public static func build(
        request: PassageAgentVisualSearchRequest,
        candidates: [VisualEmbeddingMatch],
        coverage: VisualEmbeddingCoverage,
        minimumSimilarity: Double
    ) throws -> PassageAgentVisualSearchManifest {
        guard minimumSimilarity.isFinite, (-1...1).contains(minimumSimilarity) else {
            throw PassageAgentVisualSearchBuildError.invalidMinimumSimilarity
        }

        var omissionReasons = Set<PassageAgentVisualSearchOmissionReason>()
        var admitted: [VisualEmbeddingMatch] = []
        admitted.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard !candidate.hit.context.isSensitive else {
                omissionReasons.insert(.sensitiveContext)
                continue
            }
            guard candidate.similarity.isFinite,
                  candidate.maximumSimilarityError.isFinite,
                  candidate.maximumSimilarityError >= 0,
                  candidate.similarity - candidate.maximumSimilarityError >= minimumSimilarity else {
                omissionReasons.insert(.belowMinimumSimilarity)
                continue
            }
            admitted.append(candidate)
        }

        let resultLimit = max(request.resultLimit, 0)
        let hasMore = admitted.count > resultLimit
        if hasMore { omissionReasons.insert(.resultLimit) }
        let projectedSources = admitted.prefix(resultLimit).map(source(from:))

        let empty = try candidateManifest(
            request: request,
            minimumSimilarity: minimumSimilarity,
            coverage: coverage,
            matchedCount: admitted.count,
            hasMore: hasMore,
            omissionReasons: omissionReasons,
            sources: []
        )
        guard empty.encodedUTF8Bytes <= request.utf8ByteBudget else {
            throw PassageAgentVisualSearchBuildError.byteBudgetTooSmall(
                minimumBytes: empty.encodedUTF8Bytes
            )
        }

        let complete = try candidateManifest(
            request: request,
            minimumSimilarity: minimumSimilarity,
            coverage: coverage,
            matchedCount: admitted.count,
            hasMore: hasMore,
            omissionReasons: omissionReasons,
            sources: projectedSources
        )
        if complete.encodedUTF8Bytes <= request.utf8ByteBudget {
            return complete
        }

        omissionReasons.insert(.utf8ByteBudget)
        let byteLimitedEmpty = try candidateManifest(
            request: request,
            minimumSimilarity: minimumSimilarity,
            coverage: coverage,
            matchedCount: admitted.count,
            hasMore: hasMore,
            omissionReasons: omissionReasons,
            sources: []
        )
        guard byteLimitedEmpty.encodedUTF8Bytes <= request.utf8ByteBudget else {
            throw PassageAgentVisualSearchBuildError.byteBudgetTooSmall(
                minimumBytes: byteLimitedEmpty.encodedUTF8Bytes
            )
        }

        var sources: [PassageAgentVisualSearchSource] = []
        for fullSource in projectedSources {
            let fullCandidate = try candidateManifest(
                request: request,
                minimumSimilarity: minimumSimilarity,
                coverage: coverage,
                matchedCount: admitted.count,
                hasMore: hasMore,
                omissionReasons: omissionReasons,
                sources: sources + [fullSource]
            )
            if fullCandidate.encodedUTF8Bytes <= request.utf8ByteBudget {
                sources.append(fullSource)
                continue
            }

            var minimalSource = fullSource
            minimalSource.ocrSnippet = ""
            minimalSource.snippetTruncated = !fullSource.ocrSnippet.isEmpty
            var truncationReasons = omissionReasons
            if minimalSource.snippetTruncated {
                truncationReasons.insert(.ocrSnippetTruncated)
            }
            let minimalCandidate = try candidateManifest(
                request: request,
                minimumSimilarity: minimumSimilarity,
                coverage: coverage,
                matchedCount: admitted.count,
                hasMore: hasMore,
                omissionReasons: truncationReasons,
                sources: sources + [minimalSource]
            )
            guard minimalCandidate.encodedUTF8Bytes <= request.utf8ByteBudget else {
                break
            }

            let characters = Array(fullSource.ocrSnippet)
            var lowerBound = 0
            var upperBound = characters.count
            var bestSource = minimalSource
            while lowerBound <= upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                var trialSource = fullSource
                trialSource.ocrSnippet = String(characters.prefix(midpoint))
                trialSource.snippetTruncated = midpoint < characters.count
                var trialReasons = omissionReasons
                if trialSource.snippetTruncated {
                    trialReasons.insert(.ocrSnippetTruncated)
                }
                let trial = try candidateManifest(
                    request: request,
                    minimumSimilarity: minimumSimilarity,
                    coverage: coverage,
                    matchedCount: admitted.count,
                    hasMore: hasMore,
                    omissionReasons: trialReasons,
                    sources: sources + [trialSource]
                )
                if trial.encodedUTF8Bytes <= request.utf8ByteBudget {
                    bestSource = trialSource
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint - 1
                }
            }
            sources.append(bestSource)
            if bestSource.snippetTruncated {
                omissionReasons.insert(.ocrSnippetTruncated)
            }
            break
        }

        return try candidateManifest(
            request: request,
            minimumSimilarity: minimumSimilarity,
            coverage: coverage,
            matchedCount: admitted.count,
            hasMore: hasMore,
            omissionReasons: omissionReasons,
            sources: sources
        )
    }

    private static func source(
        from match: VisualEmbeddingMatch
    ) -> PassageAgentVisualSearchSource {
        PassageAgentVisualSearchSource(
            frameID: match.hit.id,
            capturedAt: match.hit.capturedAt,
            applicationName: match.hit.context.applicationName,
            bundleIdentifier: match.hit.context.bundleIdentifier,
            windowTitle: match.hit.context.windowTitle,
            domain: match.hit.context.domain,
            url: sanitizedURLString(match.hit.context.url),
            ocrSnippet: match.hit.snippet,
            similarity: match.similarity,
            maximumSimilarityError: match.maximumSimilarityError,
            minimumPossibleSimilarity: match.similarity - match.maximumSimilarityError,
            associatedFrameCount: match.associatedFrameCount,
            model: match.model
        )
    }

    /// URLs can carry credentials, tokens, form state, and fragments. Visual
    /// provenance needs only the stable public page location.
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

    private static func candidateManifest(
        request: PassageAgentVisualSearchRequest,
        minimumSimilarity: Double,
        coverage: VisualEmbeddingCoverage,
        matchedCount: Int,
        hasMore: Bool,
        omissionReasons: Set<PassageAgentVisualSearchOmissionReason>,
        sources: [PassageAgentVisualSearchSource]
    ) throws -> PassageAgentVisualSearchManifest {
        try stabilized(manifest(
            request: request,
            minimumSimilarity: minimumSimilarity,
            coverage: coverage,
            matchedCount: matchedCount,
            hasMore: hasMore,
            omissionReasons: omissionReasons,
            sources: sources
        ))
    }

    private static func manifest(
        request: PassageAgentVisualSearchRequest,
        minimumSimilarity: Double,
        coverage: VisualEmbeddingCoverage,
        matchedCount: Int,
        hasMore: Bool,
        omissionReasons: Set<PassageAgentVisualSearchOmissionReason>,
        sources: [PassageAgentVisualSearchSource]
    ) -> PassageAgentVisualSearchManifest {
        let orderedReasons = PassageAgentVisualSearchOmissionReason.allCases.filter(
            omissionReasons.contains
        )
        return PassageAgentVisualSearchManifest(
            disclosure: request.disclosure,
            minimumSimilarity: minimumSimilarity,
            coverage: PassageAgentVisualSearchCoverageSummary(coverage: coverage),
            requestedCount: request.resultLimit,
            matchedCount: matchedCount,
            hasMore: hasMore,
            truncated: !orderedReasons.isEmpty || sources.count < matchedCount,
            utf8ByteBudget: request.utf8ByteBudget,
            omissionReasons: orderedReasons,
            sources: sources
        )
    }

    private static func stabilized(
        _ manifest: PassageAgentVisualSearchManifest
    ) throws -> PassageAgentVisualSearchManifest {
        var result = manifest
        for _ in 0..<16 {
            result.disclosedCount = result.sources.count
            let byteCount = try result.canonicalJSONData().count
            if result.encodedUTF8Bytes == byteCount {
                return result
            }
            result.encodedUTF8Bytes = byteCount
        }
        throw PassageAgentVisualSearchBuildError.couldNotStabilizeEncodedSize
    }
}
