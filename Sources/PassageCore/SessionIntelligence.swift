import CryptoKit
import Foundation

/// One text-only observation supplied to a session-intelligence provider.
///
/// Deliberately absent are image bytes, media paths, thumbnails, OCR geometry,
/// and screen dimensions. A provider accepting this type cannot accidentally
/// receive Passage's screenshots through its public input contract.
public struct SessionIntelligenceSource: Codable, Hashable, Sendable {
    public static let maximumApplicationNameUTF8Bytes = 160
    public static let maximumWindowTitleUTF8Bytes = 320
    public static let maximumDomainUTF8Bytes = 255
    public static let maximumURLUTF8Bytes = 1_024
    public static let maximumOCRSnippetUTF8Bytes = 1_200

    public let frameID: FrameID
    public let capturedAt: Date
    public let applicationName: String
    public let windowTitle: String?
    public let domain: String?
    public let urlString: String?
    public let ocrSnippet: String

    public init(
        frameID: FrameID,
        capturedAt: Date,
        applicationName: String,
        windowTitle: String? = nil,
        domain: String? = nil,
        urlString: String? = nil,
        ocrSnippet: String
    ) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.applicationName = Self.normalized(
            applicationName,
            maximumUTF8Bytes: Self.maximumApplicationNameUTF8Bytes,
            fallback: "Unknown application"
        )
        self.windowTitle = Self.normalizedOptional(
            windowTitle,
            maximumUTF8Bytes: Self.maximumWindowTitleUTF8Bytes
        )
        self.domain = Self.normalizedOptional(
            domain,
            maximumUTF8Bytes: Self.maximumDomainUTF8Bytes
        )
        self.urlString = Self.normalizedOptional(
            urlString,
            maximumUTF8Bytes: Self.maximumURLUTF8Bytes
        )
        self.ocrSnippet = Self.normalized(
            ocrSnippet,
            maximumUTF8Bytes: Self.maximumOCRSnippetUTF8Bytes,
            fallback: ""
        )
    }

    public var textUTF8ByteCount: Int {
        let applicationBytes = applicationName.utf8.count
        let windowBytes = windowTitle?.utf8.count ?? 0
        let domainBytes = domain?.utf8.count ?? 0
        let urlBytes = urlString?.utf8.count ?? 0
        let ocrBytes = ocrSnippet.utf8.count
        return applicationBytes + windowBytes + domainBytes + urlBytes + ocrBytes
    }

    fileprivate func fitting(totalTextUTF8Bytes budget: Int) -> SessionIntelligenceSource? {
        let applicationBytes = applicationName.utf8.count
        let windowBytes = windowTitle?.utf8.count ?? 0
        let domainBytes = domain?.utf8.count ?? 0
        let urlBytes = urlString?.utf8.count ?? 0
        let metadataBytes = applicationBytes + windowBytes + domainBytes + urlBytes
        guard budget >= metadataBytes else { return nil }
        return SessionIntelligenceSource(
            frameID: frameID,
            capturedAt: capturedAt,
            applicationName: applicationName,
            windowTitle: windowTitle,
            domain: domain,
            urlString: urlString,
            ocrSnippet: ocrSnippet.passagePrefix(maximumUTF8Bytes: budget - metadataBytes)
        )
    }

    private static func normalized(
        _ value: String,
        maximumUTF8Bytes: Int,
        fallback: String
    ) -> String {
        let collapsed = value.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let nonempty = collapsed.isEmpty ? fallback : collapsed
        return nonempty.passagePrefix(maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private static func normalizedOptional(
        _ value: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard let value else { return nil }
        let normalized = normalized(value, maximumUTF8Bytes: maximumUTF8Bytes, fallback: "")
        return normalized.isEmpty ? nil : normalized
    }
}

/// A deterministically bounded, chronological text-only provider request.
public struct SessionIntelligenceInput: Codable, Hashable, Sendable {
    public static let maximumSourceCount = 20
    public static let maximumTotalTextUTF8Bytes = 20_000
    public static let maximumIdentifierUTF8Bytes = 160

    public let activitySessionID: ActivitySessionID
    public let sources: [SessionIntelligenceSource]
    public let contentFingerprint: String

    public init(
        activitySessionID: ActivitySessionID,
        sources: [SessionIntelligenceSource]
    ) {
        self.activitySessionID = activitySessionID

        var seen = Set<FrameID>()
        let normalized = sources
            .map {
                SessionIntelligenceSource(
                    frameID: $0.frameID,
                    capturedAt: $0.capturedAt,
                    applicationName: $0.applicationName,
                    windowTitle: $0.windowTitle,
                    domain: $0.domain,
                    urlString: $0.urlString,
                    ocrSnippet: $0.ocrSnippet
                )
            }
            .sorted {
                if $0.capturedAt == $1.capturedAt {
                    return $0.frameID.rawValue < $1.frameID.rawValue
                }
                return $0.capturedAt < $1.capturedAt
            }
            .filter {
                let identifier = $0.frameID.rawValue
                guard !identifier.isEmpty,
                      identifier.utf8.count <= Self.maximumIdentifierUTF8Bytes,
                      seen.insert($0.frameID).inserted else { return false }
                return true
            }

        // Prefer the latest evidence because the primary product question is
        // where the person left off. Reverse traversal gives the newest sources
        // first claim on the byte budget; the stored result remains chronological.
        var remaining = Self.maximumTotalTextUTF8Bytes
        var retainedNewestFirst: [SessionIntelligenceSource] = []
        for source in normalized.suffix(Self.maximumSourceCount).reversed() {
            guard let fitted = source.fitting(totalTextUTF8Bytes: remaining) else { continue }
            retainedNewestFirst.append(fitted)
            remaining -= fitted.textUTF8ByteCount
        }
        self.sources = retainedNewestFirst.reversed()
        contentFingerprint = Self.fingerprint(
            activitySessionID: activitySessionID,
            sources: self.sources
        )
    }

    private enum CodingKeys: String, CodingKey {
        case activitySessionID
        case sources
        case contentFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            activitySessionID: try container.decode(ActivitySessionID.self, forKey: .activitySessionID),
            sources: try container.decode([SessionIntelligenceSource].self, forKey: .sources)
        )
    }

    private static func fingerprint(
        activitySessionID: ActivitySessionID,
        sources: [SessionIntelligenceSource]
    ) -> String {
        var canonical = Data()
        canonical.appendLengthPrefixed(activitySessionID.rawValue)
        for source in sources {
            canonical.appendLengthPrefixed(source.frameID.rawValue)
            var timestamp = source.capturedAt.timeIntervalSince1970.bitPattern.bigEndian
            Swift.withUnsafeBytes(of: &timestamp) { canonical.append(contentsOf: $0) }
            canonical.appendLengthPrefixed(source.applicationName)
            canonical.appendLengthPrefixed(source.windowTitle ?? "")
            canonical.appendLengthPrefixed(source.domain ?? "")
            canonical.appendLengthPrefixed(source.urlString ?? "")
            canonical.appendLengthPrefixed(source.ocrSnippet)
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

/// A short statement whose factual basis is explicit and locally navigable.
public struct SessionIntelligenceClaim: Codable, Hashable, Sendable {
    public let text: String
    public let sourceFrameIDs: [FrameID]

    public init(text: String, sourceFrameIDs: [FrameID]) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceFrameIDs = sourceFrameIDs.passageUniqued().prefix(6).map { $0 }
    }

    fileprivate func bounded(maximumUTF8Bytes: Int) -> SessionIntelligenceClaim {
        SessionIntelligenceClaim(
            text: text.passagePrefix(maximumUTF8Bytes: maximumUTF8Bytes),
            sourceFrameIDs: sourceFrameIDs
        )
    }
}

public struct SessionIntelligenceNextAction: Codable, Hashable, Sendable {
    public let text: String
    public let sourceFrameIDs: [FrameID]

    public init(text: String, sourceFrameIDs: [FrameID]) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .passagePrefix(maximumUTF8Bytes: 320)
        self.sourceFrameIDs = sourceFrameIDs.passageUniqued().prefix(4).map { $0 }
    }
}

/// Provider-generated, source-cited understanding of one local activity session.
public struct SessionEnrichment: Codable, Hashable, Sendable {
    public static let maximumNextActionCount = 3

    public let activitySessionID: ActivitySessionID
    public let title: SessionIntelligenceClaim
    public let summary: SessionIntelligenceClaim
    public let whereLeftOff: SessionIntelligenceClaim
    public let nextActions: [SessionIntelligenceNextAction]
    public let generatedAt: Date
    public let provider: String
    public let model: String
    public let contentFingerprint: String

    public init(
        activitySessionID: ActivitySessionID,
        title: SessionIntelligenceClaim,
        summary: SessionIntelligenceClaim,
        whereLeftOff: SessionIntelligenceClaim,
        nextActions: [SessionIntelligenceNextAction],
        generatedAt: Date,
        provider: String,
        model: String,
        contentFingerprint: String
    ) {
        self.activitySessionID = activitySessionID
        self.title = title.bounded(maximumUTF8Bytes: 200)
        self.summary = summary.bounded(maximumUTF8Bytes: 1_200)
        self.whereLeftOff = whereLeftOff.bounded(maximumUTF8Bytes: 800)
        self.nextActions = nextActions.prefix(Self.maximumNextActionCount).map { $0 }
        self.generatedAt = generatedAt
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            .passagePrefix(maximumUTF8Bytes: 120)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            .passagePrefix(maximumUTF8Bytes: 120)
        self.contentFingerprint = contentFingerprint
    }
}

public protocol SessionIntelligenceProvider: Sendable {
    func enrich(_ input: SessionIntelligenceInput) async throws -> SessionEnrichment
}

/// One explicit question over one explicitly selected activity session.
///
/// The question and evidence share one byte budget. Sources are accepted in
/// priority order (relevant matches first, then recent context), fitted to that
/// budget, and stored chronologically so the provider receives a coherent
/// transcript. Fingerprints are recomputed when decoding rather than trusted.
public struct SessionQuestionInput: Codable, Hashable, Sendable {
    public static let schemaVersion = "chronicle-session-question/v1"
    public static let maximumQuestionUTF8Bytes = 1_000
    public static let maximumSourceCount = 20
    public static let maximumTotalTextUTF8Bytes = 20_000
    public static let maximumProviderIdentifierUTF8Bytes = 120

    public let activitySessionID: ActivitySessionID
    public let question: String
    public let sources: [SessionIntelligenceSource]
    public let provider: String
    public let model: String
    public let contentFingerprint: String
    public let questionFingerprint: String
    public let requestFingerprint: String

    public init(
        activitySessionID: ActivitySessionID,
        question: String,
        sourcesByPriority: [SessionIntelligenceSource],
        provider: String,
        model: String
    ) {
        let normalizedQuestion = Self.normalizedQuestion(question)
        let normalizedProvider = Self.normalizedIdentifier(provider)
        let normalizedModel = Self.normalizedIdentifier(model)
        self.activitySessionID = activitySessionID
        self.question = normalizedQuestion
        self.provider = normalizedProvider
        self.model = normalizedModel

        var remaining = max(
            Self.maximumTotalTextUTF8Bytes - normalizedQuestion.utf8.count,
            0
        )
        var seen = Set<FrameID>()
        var retained: [SessionIntelligenceSource] = []
        for source in sourcesByPriority {
            guard retained.count < Self.maximumSourceCount,
                  !source.frameID.rawValue.isEmpty,
                  source.frameID.rawValue.utf8.count <= SessionIntelligenceInput.maximumIdentifierUTF8Bytes,
                  seen.insert(source.frameID).inserted,
                  let fitted = source.fitting(totalTextUTF8Bytes: remaining) else { continue }
            retained.append(fitted)
            remaining -= fitted.textUTF8ByteCount
        }
        let normalizedSources = retained.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.frameID.rawValue < $1.frameID.rawValue
            }
            return $0.capturedAt < $1.capturedAt
        }
        sources = normalizedSources
        let computedContentFingerprint = Self.contentFingerprint(
            activitySessionID: activitySessionID,
            sources: normalizedSources
        )
        contentFingerprint = computedContentFingerprint
        let computedQuestionFingerprint = Self.hashing { data in
            data.appendLengthPrefixed(normalizedQuestion)
        }
        questionFingerprint = computedQuestionFingerprint
        requestFingerprint = Self.hashing { data in
            data.appendLengthPrefixed(Self.schemaVersion)
            data.appendLengthPrefixed(activitySessionID.rawValue)
            data.appendLengthPrefixed(computedContentFingerprint)
            data.appendLengthPrefixed(computedQuestionFingerprint)
            data.appendLengthPrefixed(normalizedProvider)
            data.appendLengthPrefixed(normalizedModel)
        }
    }

    public var sourceTextUTF8ByteCount: Int {
        sources.reduce(0) { $0 + $1.textUTF8ByteCount }
    }

    public var totalTextUTF8ByteCount: Int {
        question.utf8.count + sourceTextUTF8ByteCount
    }

    private enum CodingKeys: String, CodingKey {
        case activitySessionID
        case question
        case sources
        case provider
        case model
        case contentFingerprint
        case questionFingerprint
        case requestFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            activitySessionID: try container.decode(ActivitySessionID.self, forKey: .activitySessionID),
            question: try container.decode(String.self, forKey: .question),
            sourcesByPriority: try container.decode([SessionIntelligenceSource].self, forKey: .sources),
            provider: try container.decode(String.self, forKey: .provider),
            model: try container.decode(String.self, forKey: .model)
        )
    }

    private static func normalizedQuestion(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .passagePrefix(maximumUTF8Bytes: maximumQuestionUTF8Bytes)
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .passagePrefix(maximumUTF8Bytes: maximumProviderIdentifierUTF8Bytes)
    }

    private static func contentFingerprint(
        activitySessionID: ActivitySessionID,
        sources: [SessionIntelligenceSource]
    ) -> String {
        hashing { canonical in
            canonical.appendLengthPrefixed(activitySessionID.rawValue)
            for source in sources {
                canonical.appendLengthPrefixed(source.frameID.rawValue)
                var timestamp = source.capturedAt.timeIntervalSince1970.bitPattern.bigEndian
                Swift.withUnsafeBytes(of: &timestamp) { canonical.append(contentsOf: $0) }
                canonical.appendLengthPrefixed(source.applicationName)
                canonical.appendLengthPrefixed(source.windowTitle ?? "")
                canonical.appendLengthPrefixed(source.domain ?? "")
                canonical.appendLengthPrefixed(source.urlString ?? "")
                canonical.appendLengthPrefixed(source.ocrSnippet)
            }
        }
    }

    private static func hashing(_ append: (inout Data) -> Void) -> String {
        var canonical = Data()
        append(&canonical)
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

/// The exact local disclosure prepared before any network request is possible.
public struct SessionQuestionPreparation: Codable, Hashable, Sendable {
    public let input: SessionQuestionInput
    public let selectedMomentCount: Int
    public let selectedTextUTF8ByteCount: Int
    public let evidenceThrough: Date?

    public init(input: SessionQuestionInput) {
        self.input = input
        selectedMomentCount = input.sources.count
        selectedTextUTF8ByteCount = input.sourceTextUTF8ByteCount
        evidenceThrough = input.sources.map(\.capturedAt).max()
    }
}

public enum SessionQuestionDisclosureDecision: Equatable, Sendable {
    case noEvidence
    case submit
    case requirePrivateConfirmation
}

/// Pure policy used by every UI surface before it can reach the provider.
public struct SessionQuestionDisclosurePolicy: Sendable {
    public init() {}

    public func decision(
        for preparation: SessionQuestionPreparation,
        sessionContainsSensitiveHistory: Bool
    ) -> SessionQuestionDisclosureDecision {
        guard !preparation.input.question.isEmpty,
              !preparation.input.sources.isEmpty else { return .noEvidence }
        return sessionContainsSensitiveHistory ? .requirePrivateConfirmation : .submit
    }
}

public enum SessionQuestionAnswerStatus: String, Codable, Hashable, Sendable {
    case answered
    case insufficientEvidence = "insufficient_evidence"
}

/// Source-cited claims answering one question, or an honest evidence miss.
public struct SessionQuestionAnswer: Codable, Hashable, Sendable {
    public static let maximumClaimCount = 4

    public let activitySessionID: ActivitySessionID
    public let question: String
    public let status: SessionQuestionAnswerStatus
    public let claims: [SessionIntelligenceClaim]
    public let generatedAt: Date
    public let provider: String
    public let model: String
    public let contentFingerprint: String
    public let questionFingerprint: String
    public let requestFingerprint: String
    public let evidenceThrough: Date?
    public let evidenceMomentCount: Int
    public let evidenceTextUTF8ByteCount: Int

    public init(
        activitySessionID: ActivitySessionID,
        question: String,
        status: SessionQuestionAnswerStatus,
        claims: [SessionIntelligenceClaim],
        generatedAt: Date,
        provider: String,
        model: String,
        contentFingerprint: String,
        questionFingerprint: String,
        requestFingerprint: String,
        evidenceThrough: Date?,
        evidenceMomentCount: Int = 0,
        evidenceTextUTF8ByteCount: Int = 0
    ) {
        self.activitySessionID = activitySessionID
        self.question = question
        self.status = status
        self.claims = Array(claims.prefix(Self.maximumClaimCount))
        self.generatedAt = generatedAt
        self.provider = provider
        self.model = model
        self.contentFingerprint = contentFingerprint
        self.questionFingerprint = questionFingerprint
        self.requestFingerprint = requestFingerprint
        self.evidenceThrough = evidenceThrough
        self.evidenceMomentCount = max(evidenceMomentCount, 0)
        self.evidenceTextUTF8ByteCount = max(evidenceTextUTF8ByteCount, 0)
    }
}

public protocol SessionQuestionAnsweringProvider: Sendable {
    func answer(_ input: SessionQuestionInput) async throws -> SessionQuestionAnswer
}

/// Deterministically combines session-filtered search matches with a small
/// recent-context tail. It never accepts a matched frame from another session.
public struct SessionQuestionEvidenceSelector: Sendable {
    public static let maximumSearchTermCount = 6
    public static let maximumMatchedMomentCount = 12
    public static let maximumRecentContextCount = 8

    public init() {}

    public func searchText(for question: String) -> String {
        let normalized = question.precomposedStringWithCanonicalMapping.lowercased()
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        var seen = Set<String>()
        var retained: [String] = []
        for token in tokens {
            guard token.count >= 2,
                  !Self.stopWords.contains(token),
                  seen.insert(token).inserted else { continue }
            retained.append(token)
            if retained.count == Self.maximumSearchTermCount { break }
        }
        return retained.joined(separator: " ")
    }

    public func prepare(
        question: String,
        session: ActivitySessionDetail,
        matchedMoments: [SearchHit],
        provider: String,
        model: String
    ) -> SessionQuestionPreparation {
        let sessionID = session.summary.id
        let matched = matchedMoments
            .filter { $0.activitySessionID == sessionID }
            .prefix(Self.maximumMatchedMomentCount)
        let recent = session.moments
            .filter { $0.activitySessionID == sessionID }
            .prefix(Self.maximumRecentContextCount)
        var seen = Set<FrameID>()
        let prioritized = (Array(matched) + Array(recent))
            .filter { seen.insert($0.id).inserted }
            .map(Self.source)
        return SessionQuestionPreparation(
            input: SessionQuestionInput(
                activitySessionID: sessionID,
                question: question,
                sourcesByPriority: prioritized,
                provider: provider,
                model: model
            )
        )
    }

    private static func source(_ hit: SearchHit) -> SessionIntelligenceSource {
        SessionIntelligenceSource(
            frameID: hit.id,
            capturedAt: hit.capturedAt,
            applicationName: hit.context.applicationName,
            windowTitle: hit.context.windowTitle,
            domain: hit.context.domain,
            urlString: sanitizedProviderURLString(hit.context.url),
            ocrSnippet: hit.snippet
                .replacingOccurrences(of: "‹", with: "")
                .replacingOccurrences(of: "›", with: "")
        )
    }

    /// Query strings, fragments, and embedded credentials often contain access
    /// tokens or form state. They are not needed to answer a session question.
    private static func sanitizedProviderURLString(_ url: URL?) -> String? {
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

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "did", "do", "does",
        "for", "from", "had", "has", "have", "how", "i", "in", "is", "it", "me", "my",
        "of", "on", "or", "that", "the", "this", "to", "was", "were", "what", "when",
        "where", "which", "who", "why", "with", "you", "your",
    ]
}

private extension String {
    func passagePrefix(maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard utf8.count > maximumUTF8Bytes else { return self }
        var result = ""
        result.reserveCapacity(min(count, maximumUTF8Bytes))
        var used = 0
        for character in self {
            let text = String(character)
            let byteCount = text.utf8.count
            guard used + byteCount <= maximumUTF8Bytes else { break }
            result.append(character)
            used += byteCount
        }
        return result
    }
}

private extension Array where Element == FrameID {
    func passageUniqued() -> [FrameID] {
        var seen = Set<FrameID>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }
}
