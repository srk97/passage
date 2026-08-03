import CryptoKit
import Foundation

/// Versioned constants for Passage's storage-independent memory-segment contract.
public enum MemorySegmentSchema {
    public static let currentVersion: UInt16 = 1
    public static let defaultPageLimit = 40
    public static let maximumPageLimit = 200
    public static let maximumRepresentativeEvidenceCount = 4
}

public enum MemorySegmentValidationError: Error, Hashable, Sendable {
    case invalidTimeRange
    case missingBoundedSegmentTimeRange
    case invalidIdentifier(field: String)
    case emptyLineage
    case duplicateFrameID(FrameID)
    case invalidRepresentativeEvidence
    case invalidModalityCoverage
    case cursorScopeMismatch
    case invalidPage
    case encodedIdentityMismatch
}

/// Stable identity for one logical segment.
///
/// Passage derives this from the normalized segment scope and the first frame
/// in its ordered lineage. Re-enrichment therefore preserves this identity,
/// while a changed lineage receives a new `MemorySegmentRevisionID`.
public struct MemorySegmentID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Content identity for one exact revision of a logical memory segment.
public struct MemorySegmentRevisionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Identity for one immutable retrieval snapshot across all visible segments.
///
/// Stores should derive this from every segment revision visible to the query
/// transaction, not merely the revisions returned on the current page.
public struct MemorySegmentIndexRevision: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func derived(from revisions: [MemorySegmentRevisionID]) -> Self {
        var canonical = Data()
        canonical.appendMemorySegmentString("chronicle.memory-index-revision.v1")
        let normalizedRevisions = Array(Set(revisions)).sorted { $0.rawValue < $1.rawValue }
        canonical.appendMemorySegmentInteger(normalizedRevisions.count)
        for revision in normalizedRevisions {
            canonical.appendMemorySegmentString(revision.rawValue)
        }
        return Self(rawValue: canonical.memorySegmentSHA256)
    }
}

/// Normalized metadata and time constraints shared by segment storage and retrieval.
///
/// Time bounds form a half-open interval: `startDate` is inclusive and
/// `endDate` is exclusive. Either bound may be absent for a retrieval request;
/// an actual `MemorySegment` must have both so adjacent segments never overlap.
public struct MemorySegmentScope: Codable, Hashable, Sendable {
    public let startDate: Date?
    public let endDate: Date?
    public let applicationBundleIdentifiers: [String]
    public let domains: [String]
    public let activitySessionIDs: [ActivitySessionID]

    public init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        applicationBundleIdentifiers: [String] = [],
        domains: [String] = [],
        activitySessionIDs: [ActivitySessionID] = []
    ) throws {
        guard startDate?.timeIntervalSince1970.isFinite != false,
              endDate?.timeIntervalSince1970.isFinite != false else {
            throw MemorySegmentValidationError.invalidTimeRange
        }
        if let startDate, let endDate, startDate >= endDate {
            throw MemorySegmentValidationError.invalidTimeRange
        }
        self.startDate = startDate
        self.endDate = endDate
        self.applicationBundleIdentifiers = Self.normalizedIdentifiers(
            applicationBundleIdentifiers
        )
        self.domains = Self.normalizedDomains(domains)
        self.activitySessionIDs = Self.normalizedSessionIDs(activitySessionIDs)
    }

    /// Deterministic identity used as one component of a retrieval-cursor binding.
    public var fingerprint: String {
        var canonical = Data()
        canonical.appendMemorySegmentString("chronicle.memory-segment-scope.v1")
        canonical.appendMemorySegmentOptionalDate(startDate)
        canonical.appendMemorySegmentOptionalDate(endDate)
        canonical.appendMemorySegmentInteger(applicationBundleIdentifiers.count)
        applicationBundleIdentifiers.forEach { canonical.appendMemorySegmentString($0) }
        canonical.appendMemorySegmentInteger(domains.count)
        domains.forEach { canonical.appendMemorySegmentString($0) }
        canonical.appendMemorySegmentInteger(activitySessionIDs.count)
        activitySessionIDs.forEach { canonical.appendMemorySegmentString($0.rawValue) }
        return canonical.memorySegmentSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case startDate
        case endDate
        case applicationBundleIdentifiers
        case domains
        case activitySessionIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startDate: try container.decodeIfPresent(Date.self, forKey: .startDate),
            endDate: try container.decodeIfPresent(Date.self, forKey: .endDate),
            applicationBundleIdentifiers: try container.decodeIfPresent(
                [String].self,
                forKey: .applicationBundleIdentifiers
            ) ?? [],
            domains: try container.decodeIfPresent([String].self, forKey: .domains) ?? [],
            activitySessionIDs: try container.decodeIfPresent(
                [ActivitySessionID].self,
                forKey: .activitySessionIDs
            ) ?? []
        )
    }

    private static func normalizedIdentifiers(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        })).sorted()
    }

    private static func normalizedDomains(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })).sorted()
    }

    private static func normalizedSessionIDs(_ values: [ActivitySessionID]) -> [ActivitySessionID] {
        var seen = Set<ActivitySessionID>()
        return values
            .filter { !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted { $0.rawValue < $1.rawValue }
    }
}

/// The exact frames attributed to one enrichment producer and revision.
public struct MemorySegmentModalityProvenance: Codable, Hashable, Sendable {
    public let producerIdentifier: String
    public let producerRevision: String
    public let artifactFingerprint: String?
    public let frameIDs: [FrameID]

    public init(
        producerIdentifier: String,
        producerRevision: String,
        artifactFingerprint: String? = nil,
        frameIDs: [FrameID]
    ) throws {
        let identifier = producerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = producerRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "producerIdentifier")
        }
        guard !revision.isEmpty else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "producerRevision")
        }
        try Self.validateUniqueFrameIDs(frameIDs)
        guard !frameIDs.isEmpty else {
            throw MemorySegmentValidationError.invalidModalityCoverage
        }
        self.producerIdentifier = identifier
        self.producerRevision = revision
        self.artifactFingerprint = artifactFingerprint?.memorySegmentNilIfBlank
        self.frameIDs = frameIDs
    }

    private enum CodingKeys: String, CodingKey {
        case producerIdentifier
        case producerRevision
        case artifactFingerprint
        case frameIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            producerIdentifier: try container.decode(String.self, forKey: .producerIdentifier),
            producerRevision: try container.decode(String.self, forKey: .producerRevision),
            artifactFingerprint: try container.decodeIfPresent(
                String.self,
                forKey: .artifactFingerprint
            ),
            frameIDs: try container.decode([FrameID].self, forKey: .frameIDs)
        )
    }

    fileprivate static func validateUniqueFrameIDs(_ frameIDs: [FrameID]) throws {
        var seen = Set<FrameID>()
        for frameID in frameIDs {
            guard !frameID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemorySegmentValidationError.invalidIdentifier(field: "frameID")
            }
            guard seen.insert(frameID).inserted else {
                throw MemorySegmentValidationError.duplicateFrameID(frameID)
            }
        }
    }
}

public enum MemorySegmentCoverageState: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case partial
    case complete
}

/// Exact, per-frame coverage and provenance for one evidence modality.
public struct MemorySegmentModalityCoverage: Codable, Hashable, Sendable {
    public let modality: PassageMemoryEvidenceModality
    public let segmentFrameCount: Int
    public let coveredFrameIDs: [FrameID]
    public let provenance: [MemorySegmentModalityProvenance]

    public init(
        modality: PassageMemoryEvidenceModality,
        segmentFrameCount: Int,
        coveredFrameIDs: [FrameID],
        provenance: [MemorySegmentModalityProvenance]
    ) throws {
        guard segmentFrameCount > 0, coveredFrameIDs.count <= segmentFrameCount else {
            throw MemorySegmentValidationError.invalidModalityCoverage
        }
        try MemorySegmentModalityProvenance.validateUniqueFrameIDs(coveredFrameIDs)

        var attributed = Set<FrameID>()
        for source in provenance {
            for frameID in source.frameIDs {
                guard attributed.insert(frameID).inserted else {
                    throw MemorySegmentValidationError.invalidModalityCoverage
                }
            }
        }
        guard attributed == Set(coveredFrameIDs),
              coveredFrameIDs.isEmpty == provenance.isEmpty else {
            throw MemorySegmentValidationError.invalidModalityCoverage
        }

        self.modality = modality
        self.segmentFrameCount = segmentFrameCount
        self.coveredFrameIDs = coveredFrameIDs
        self.provenance = provenance.sorted(by: Self.provenancePrecedes)
    }

    public var state: MemorySegmentCoverageState {
        if coveredFrameIDs.isEmpty { return .unavailable }
        return coveredFrameIDs.count == segmentFrameCount ? .complete : .partial
    }

    public var coveredFraction: Double {
        Double(coveredFrameIDs.count) / Double(segmentFrameCount)
    }

    private enum CodingKeys: String, CodingKey {
        case modality
        case segmentFrameCount
        case coveredFrameIDs
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modality: try container.decode(
                PassageMemoryEvidenceModality.self,
                forKey: .modality
            ),
            segmentFrameCount: try container.decode(Int.self, forKey: .segmentFrameCount),
            coveredFrameIDs: try container.decode([FrameID].self, forKey: .coveredFrameIDs),
            provenance: try container.decode(
                [MemorySegmentModalityProvenance].self,
                forKey: .provenance
            )
        )
    }

    private static func provenancePrecedes(
        _ lhs: MemorySegmentModalityProvenance,
        _ rhs: MemorySegmentModalityProvenance
    ) -> Bool {
        let lhsKey = [
            lhs.producerIdentifier,
            lhs.producerRevision,
            lhs.artifactFingerprint ?? "",
            lhs.frameIDs.first?.rawValue ?? "",
        ]
        let rhsKey = [
            rhs.producerIdentifier,
            rhs.producerRevision,
            rhs.artifactFingerprint ?? "",
            rhs.frameIDs.first?.rawValue ?? "",
        ]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }
}

/// A bounded, path-free representative that both private and policy-filtered
/// agent surfaces can cite back to an exact Passage frame.
public struct MemorySegmentRepresentativeEvidence: Codable, Hashable, Sendable, Identifiable {
    public let frameID: FrameID
    public let capturedAt: Date
    public let applicationName: String
    public let bundleIdentifier: String?
    public let domain: String?
    public let activitySessionID: ActivitySessionID?
    public let snippet: String
    public let modalities: [PassageMemoryEvidenceModality]

    public var id: FrameID { frameID }

    public init(
        frameID: FrameID,
        capturedAt: Date,
        applicationName: String,
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        activitySessionID: ActivitySessionID? = nil,
        snippet: String,
        modalities: [PassageMemoryEvidenceModality]
    ) throws {
        guard !frameID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "frameID")
        }
        let normalizedApplicationName = applicationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedApplicationName.isEmpty else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "applicationName")
        }
        let normalizedModalities = Array(Set(modalities)).sorted { $0.rawValue < $1.rawValue }
        guard !normalizedModalities.isEmpty else {
            throw MemorySegmentValidationError.invalidRepresentativeEvidence
        }
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.applicationName = normalizedApplicationName
        self.bundleIdentifier = bundleIdentifier?.memorySegmentNilIfBlank
        self.domain = domain?.memorySegmentNilIfBlank?.lowercased()
        self.activitySessionID = activitySessionID
        self.snippet = snippet.memorySegmentCollapsedWhitespace
        self.modalities = normalizedModalities
    }

    private enum CodingKeys: String, CodingKey {
        case frameID
        case capturedAt
        case applicationName
        case bundleIdentifier
        case domain
        case activitySessionID
        case snippet
        case modalities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            frameID: try container.decode(FrameID.self, forKey: .frameID),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            applicationName: try container.decode(String.self, forKey: .applicationName),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            domain: try container.decodeIfPresent(String.self, forKey: .domain),
            activitySessionID: try container.decodeIfPresent(
                ActivitySessionID.self,
                forKey: .activitySessionID
            ),
            snippet: try container.decode(String.self, forKey: .snippet),
            modalities: try container.decode(
                [PassageMemoryEvidenceModality].self,
                forKey: .modalities
            )
        )
    }
}

/// One immutable, exactly traceable unit of retained Passage history.
public struct MemorySegment: Codable, Hashable, Sendable, Identifiable {
    public let schemaVersion: UInt16
    public let id: MemorySegmentID
    public let revisionID: MemorySegmentRevisionID
    public let scope: MemorySegmentScope
    /// Oldest first, with every retained frame represented exactly once.
    public let frameIDs: [FrameID]
    public let representativeEvidence: [MemorySegmentRepresentativeEvidence]
    public let modalityCoverage: [MemorySegmentModalityCoverage]
    /// Fail-closed signal for any consumer outside Passage's private UI.
    public let containsSensitive: Bool

    public init(
        scope: MemorySegmentScope,
        frameIDs: [FrameID],
        representativeEvidence: [MemorySegmentRepresentativeEvidence],
        modalityCoverage: [MemorySegmentModalityCoverage],
        containsSensitive: Bool
    ) throws {
        guard scope.startDate != nil, scope.endDate != nil else {
            throw MemorySegmentValidationError.missingBoundedSegmentTimeRange
        }
        try MemorySegmentModalityProvenance.validateUniqueFrameIDs(frameIDs)
        guard let firstFrameID = frameIDs.first else {
            throw MemorySegmentValidationError.emptyLineage
        }
        guard !representativeEvidence.isEmpty,
              representativeEvidence.count <= MemorySegmentSchema.maximumRepresentativeEvidenceCount else {
            throw MemorySegmentValidationError.invalidRepresentativeEvidence
        }

        let lineage = Set(frameIDs)
        let startDate = scope.startDate!
        let endDate = scope.endDate!
        var representativeIDs = Set<FrameID>()
        for evidence in representativeEvidence {
            guard lineage.contains(evidence.frameID),
                  representativeIDs.insert(evidence.frameID).inserted,
                  evidence.capturedAt >= startDate,
                  evidence.capturedAt < endDate,
                  Self.scopeContains(evidence, scope: scope) else {
                throw MemorySegmentValidationError.invalidRepresentativeEvidence
            }
        }

        var coveredModalities = Set<PassageMemoryEvidenceModality>()
        for coverage in modalityCoverage {
            guard coveredModalities.insert(coverage.modality).inserted,
                  coverage.segmentFrameCount == frameIDs.count,
                  Set(coverage.coveredFrameIDs).isSubset(of: lineage),
                  Self.followsLineage(coverage.coveredFrameIDs, lineage: frameIDs),
                  coverage.provenance.allSatisfy({ source in
                      Set(source.frameIDs).isSubset(of: lineage)
                          && Self.followsLineage(source.frameIDs, lineage: frameIDs)
                  }) else {
                throw MemorySegmentValidationError.invalidModalityCoverage
            }
        }
        for evidence in representativeEvidence {
            for modality in evidence.modalities {
                guard modalityCoverage.contains(where: {
                    $0.modality == modality && $0.coveredFrameIDs.contains(evidence.frameID)
                }) else {
                    throw MemorySegmentValidationError.invalidRepresentativeEvidence
                }
            }
        }

        let normalizedEvidence = representativeEvidence.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.frameID.rawValue < $1.frameID.rawValue }
            return $0.capturedAt < $1.capturedAt
        }
        let normalizedCoverage = modalityCoverage.sorted { $0.modality.rawValue < $1.modality.rawValue }
        let segmentID = Self.derivedID(scope: scope, firstFrameID: firstFrameID)

        schemaVersion = MemorySegmentSchema.currentVersion
        id = segmentID
        self.scope = scope
        self.frameIDs = frameIDs
        self.representativeEvidence = normalizedEvidence
        self.modalityCoverage = normalizedCoverage
        self.containsSensitive = containsSensitive
        revisionID = Self.derivedRevisionID(
            id: segmentID,
            scope: scope,
            frameIDs: frameIDs,
            representativeEvidence: normalizedEvidence,
            modalityCoverage: normalizedCoverage,
            containsSensitive: containsSensitive
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case revisionID
        case scope
        case frameIDs
        case representativeEvidence
        case modalityCoverage
        case containsSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        let encodedID = try container.decode(MemorySegmentID.self, forKey: .id)
        let encodedRevision = try container.decode(
            MemorySegmentRevisionID.self,
            forKey: .revisionID
        )
        let rebuilt = try Self(
            scope: container.decode(MemorySegmentScope.self, forKey: .scope),
            frameIDs: container.decode([FrameID].self, forKey: .frameIDs),
            representativeEvidence: container.decode(
                [MemorySegmentRepresentativeEvidence].self,
                forKey: .representativeEvidence
            ),
            modalityCoverage: container.decode(
                [MemorySegmentModalityCoverage].self,
                forKey: .modalityCoverage
            ),
            containsSensitive: container.decode(Bool.self, forKey: .containsSensitive)
        )
        guard encodedVersion == MemorySegmentSchema.currentVersion,
              encodedID == rebuilt.id,
              encodedRevision == rebuilt.revisionID else {
            throw MemorySegmentValidationError.encodedIdentityMismatch
        }
        self = rebuilt
    }

    private static func scopeContains(
        _ evidence: MemorySegmentRepresentativeEvidence,
        scope: MemorySegmentScope
    ) -> Bool {
        if !scope.applicationBundleIdentifiers.isEmpty,
           !scope.applicationBundleIdentifiers.contains(evidence.bundleIdentifier ?? "") {
            return false
        }
        if !scope.domains.isEmpty,
           !scope.domains.contains(evidence.domain ?? "") {
            return false
        }
        if !scope.activitySessionIDs.isEmpty,
           !scope.activitySessionIDs.contains(evidence.activitySessionID ?? ActivitySessionID(rawValue: "")) {
            return false
        }
        return true
    }

    private static func followsLineage(_ subset: [FrameID], lineage: [FrameID]) -> Bool {
        let positions = Dictionary(uniqueKeysWithValues: lineage.enumerated().map { ($1, $0) })
        let subsetPositions = subset.compactMap { positions[$0] }
        return subsetPositions.count == subset.count
            && zip(subsetPositions, subsetPositions.dropFirst()).allSatisfy { $0 < $1 }
    }

    private static func derivedID(
        scope: MemorySegmentScope,
        firstFrameID: FrameID
    ) -> MemorySegmentID {
        var canonical = Data()
        canonical.appendMemorySegmentString("chronicle.memory-segment.v1")
        canonical.appendMemorySegmentString(scope.fingerprint)
        canonical.appendMemorySegmentString(firstFrameID.rawValue)
        return MemorySegmentID(rawValue: canonical.memorySegmentSHA256)
    }

    private static func derivedRevisionID(
        id: MemorySegmentID,
        scope: MemorySegmentScope,
        frameIDs: [FrameID],
        representativeEvidence: [MemorySegmentRepresentativeEvidence],
        modalityCoverage: [MemorySegmentModalityCoverage],
        containsSensitive: Bool
    ) -> MemorySegmentRevisionID {
        var canonical = Data()
        canonical.appendMemorySegmentString("chronicle.memory-segment-revision.v1")
        canonical.appendMemorySegmentString(id.rawValue)
        canonical.appendMemorySegmentString(scope.fingerprint)
        canonical.appendMemorySegmentInteger(frameIDs.count)
        frameIDs.forEach { canonical.appendMemorySegmentString($0.rawValue) }
        canonical.appendMemorySegmentInteger(representativeEvidence.count)
        for evidence in representativeEvidence {
            canonical.appendMemorySegmentString(evidence.frameID.rawValue)
            canonical.appendMemorySegmentDate(evidence.capturedAt)
            canonical.appendMemorySegmentString(evidence.applicationName)
            canonical.appendMemorySegmentString(evidence.bundleIdentifier ?? "")
            canonical.appendMemorySegmentString(evidence.domain ?? "")
            canonical.appendMemorySegmentString(evidence.activitySessionID?.rawValue ?? "")
            canonical.appendMemorySegmentString(evidence.snippet)
            canonical.appendMemorySegmentInteger(evidence.modalities.count)
            evidence.modalities.forEach { canonical.appendMemorySegmentString($0.rawValue) }
        }
        canonical.appendMemorySegmentInteger(modalityCoverage.count)
        for coverage in modalityCoverage {
            canonical.appendMemorySegmentString(coverage.modality.rawValue)
            canonical.appendMemorySegmentInteger(coverage.segmentFrameCount)
            canonical.appendMemorySegmentInteger(coverage.coveredFrameIDs.count)
            coverage.coveredFrameIDs.forEach { canonical.appendMemorySegmentString($0.rawValue) }
            canonical.appendMemorySegmentInteger(coverage.provenance.count)
            for source in coverage.provenance {
                canonical.appendMemorySegmentString(source.producerIdentifier)
                canonical.appendMemorySegmentString(source.producerRevision)
                canonical.appendMemorySegmentString(source.artifactFingerprint ?? "")
                canonical.appendMemorySegmentInteger(source.frameIDs.count)
                source.frameIDs.forEach { canonical.appendMemorySegmentString($0.rawValue) }
            }
        }
        canonical.append(containsSensitive ? 1 : 0)
        return MemorySegmentRevisionID(rawValue: canonical.memorySegmentSHA256)
    }
}

/// An opaque continuation bound to both normalized request scope and index revision.
public struct MemorySegmentCursor: Codable, Hashable, Sendable {
    public let token: String
    public let scopeFingerprint: String
    public let revision: MemorySegmentIndexRevision

    public init(
        token: String,
        scopeFingerprint: String,
        revision: MemorySegmentIndexRevision
    ) throws {
        guard let token = token.memorySegmentNilIfBlank else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "cursor.token")
        }
        guard let scopeFingerprint = scopeFingerprint.memorySegmentNilIfBlank else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "cursor.scopeFingerprint")
        }
        guard !revision.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "cursor.revision")
        }
        self.token = token
        self.scopeFingerprint = scopeFingerprint
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case scopeFingerprint
        case revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            token: try container.decode(String.self, forKey: .token),
            scopeFingerprint: try container.decode(String.self, forKey: .scopeFingerprint),
            revision: try container.decode(MemorySegmentIndexRevision.self, forKey: .revision)
        )
    }
}

/// One normalized retrieval across the same segment snapshot used by Recall,
/// facets, context bundles, memory capsules, and session questions.
public struct MemorySegmentRequest: Codable, Hashable, Sendable {
    public let text: String
    public let scope: MemorySegmentScope
    public let retrievalModalities: [PassageMemoryRetrievalModality]
    public let after: MemorySegmentCursor?
    public let limit: Int

    public init(
        text: String = "",
        scope: MemorySegmentScope,
        retrievalModalities: [PassageMemoryRetrievalModality] = PassageMemoryRetrievalModality.allCases,
        after: MemorySegmentCursor? = nil,
        limit: Int = MemorySegmentSchema.defaultPageLimit
    ) throws {
        let normalizedModalities = Array(Set(retrievalModalities))
            .sorted { $0.rawValue < $1.rawValue }
        guard !normalizedModalities.isEmpty else {
            throw MemorySegmentValidationError.invalidIdentifier(field: "retrievalModalities")
        }
        let normalizedText = text.memorySegmentCollapsedWhitespace
        let binding = Self.scopeFingerprint(
            text: normalizedText,
            scope: scope,
            modalities: normalizedModalities
        )
        if let after, after.scopeFingerprint != binding {
            throw MemorySegmentValidationError.cursorScopeMismatch
        }
        self.text = normalizedText
        self.scope = scope
        self.retrievalModalities = normalizedModalities
        self.after = after
        self.limit = min(max(limit, 1), MemorySegmentSchema.maximumPageLimit)
    }

    public var cursorScopeFingerprint: String {
        Self.scopeFingerprint(text: text, scope: scope, modalities: retrievalModalities)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case scope
        case retrievalModalities
        case after
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: try container.decode(String.self, forKey: .text),
            scope: try container.decode(MemorySegmentScope.self, forKey: .scope),
            retrievalModalities: try container.decode(
                [PassageMemoryRetrievalModality].self,
                forKey: .retrievalModalities
            ),
            after: try container.decodeIfPresent(MemorySegmentCursor.self, forKey: .after),
            limit: try container.decode(Int.self, forKey: .limit)
        )
    }

    private static func scopeFingerprint(
        text: String,
        scope: MemorySegmentScope,
        modalities: [PassageMemoryRetrievalModality]
    ) -> String {
        var canonical = Data()
        canonical.appendMemorySegmentString("chronicle.memory-segment-request.v1")
        canonical.appendMemorySegmentString(text)
        canonical.appendMemorySegmentString(scope.fingerprint)
        canonical.appendMemorySegmentInteger(modalities.count)
        modalities.forEach { canonical.appendMemorySegmentString($0.rawValue) }
        return canonical.memorySegmentSHA256
    }
}

/// A retrieval request that is only valid for Passage's private local UI.
/// The explicit wrapper prevents an access-boundary boolean from acquiring a
/// permissive default as more call sites adopt shared segment retrieval.
public struct PrivateMemorySegmentRequest: Codable, Hashable, Sendable {
    public let retrieval: MemorySegmentRequest

    public init(_ retrieval: MemorySegmentRequest) {
        self.retrieval = retrieval
    }
}

/// A fail-closed retrieval request for third-party and agent-facing surfaces.
public struct AgentSafeMemorySegmentRequest: Codable, Hashable, Sendable {
    public let retrieval: MemorySegmentRequest

    public init(_ retrieval: MemorySegmentRequest) {
        self.retrieval = retrieval
    }
}

public enum MemorySegmentOmissionReason: String, Codable, CaseIterable, Hashable, Sendable {
    /// Access-policy filtering. Agent-safe pages must not disclose its count.
    case policyFiltered
    case incompleteIndex
    case unavailableModality
    case retention
    case resultLimit
}

/// Explicitly distinguishes an incomplete result from a complete empty result.
public struct MemorySegmentOmission: Codable, Hashable, Sendable {
    public let reason: MemorySegmentOmissionReason
    /// `nil` when even the number of omitted records would reveal private data.
    public let count: Int?

    public init(reason: MemorySegmentOmissionReason, count: Int? = nil) {
        self.reason = reason
        self.count = count.map { max($0, 0) }
    }
}

public enum MemorySegmentAccessBoundary: String, Codable, CaseIterable, Hashable, Sendable {
    case privateLocal
    case agentSafe
}

public struct MemorySegmentPage: Codable, Hashable, Sendable {
    public let accessBoundary: MemorySegmentAccessBoundary
    public let scopeFingerprint: String
    public let revision: MemorySegmentIndexRevision
    public let segments: [MemorySegment]
    public let nextCursor: MemorySegmentCursor?
    /// Independent of `segments.count`; a policy-filtered page may be empty and still continue.
    public let hasMore: Bool
    public let omissions: [MemorySegmentOmission]

    public init(
        accessBoundary: MemorySegmentAccessBoundary,
        scopeFingerprint: String,
        revision: MemorySegmentIndexRevision,
        segments: [MemorySegment],
        nextCursor: MemorySegmentCursor?,
        hasMore: Bool,
        omissions: [MemorySegmentOmission] = []
    ) throws {
        guard !scopeFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hasMore == (nextCursor != nil),
              nextCursor?.scopeFingerprint == scopeFingerprint || nextCursor == nil,
              nextCursor?.revision == revision || nextCursor == nil,
              Set(segments.map(\.id)).count == segments.count else {
            throw MemorySegmentValidationError.invalidPage
        }
        if accessBoundary == .agentSafe {
            guard segments.allSatisfy({ !$0.containsSensitive }),
                  omissions.allSatisfy({ omission in
                      omission.reason != .policyFiltered || omission.count == nil
                  }) else {
                throw MemorySegmentValidationError.invalidPage
            }
        }
        self.accessBoundary = accessBoundary
        self.scopeFingerprint = scopeFingerprint
        self.revision = revision
        self.segments = segments
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.omissions = omissions
    }

    /// False whenever more pages or an explicit coverage/policy omission remains.
    public var isComplete: Bool { !hasMore && omissions.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case accessBoundary
        case scopeFingerprint
        case revision
        case segments
        case nextCursor
        case hasMore
        case omissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accessBoundary: try container.decode(
                MemorySegmentAccessBoundary.self,
                forKey: .accessBoundary
            ),
            scopeFingerprint: try container.decode(String.self, forKey: .scopeFingerprint),
            revision: try container.decode(MemorySegmentIndexRevision.self, forKey: .revision),
            segments: try container.decode([MemorySegment].self, forKey: .segments),
            nextCursor: try container.decodeIfPresent(
                MemorySegmentCursor.self,
                forKey: .nextCursor
            ),
            hasMore: try container.decode(Bool.self, forKey: .hasMore),
            omissions: try container.decodeIfPresent(
                [MemorySegmentOmission].self,
                forKey: .omissions
            ) ?? []
        )
    }
}

/// Shared retrieval boundary for every Passage memory surface.
public protocol MemorySegmentRetrieving: Sendable {
    /// Private UI retrieval may include segments marked sensitive. Implementations
    /// must return `.privateLocal` pages and retain exact frame lineage.
    func retrievePrivateMemorySegments(
        _ request: PrivateMemorySegmentRequest
    ) async throws -> MemorySegmentPage

    /// Agent retrieval must fail closed before paging: returned segments contain
    /// no sensitive frame lineage, pages use `.agentSafe`, and policy-filtered
    /// omissions never expose a count. `hasMore` must remain accurate even when
    /// filtering produces an empty page.
    func retrieveAgentSafeMemorySegments(
        _ request: AgentSafeMemorySegmentRequest
    ) async throws -> MemorySegmentPage
}

private extension String {
    var memorySegmentNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var memorySegmentCollapsedWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension Data {
    var memorySegmentSHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendMemorySegmentString(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }

    mutating func appendMemorySegmentInteger(_ value: Int) {
        var encoded = Int64(value).bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendMemorySegmentDate(_ value: Date) {
        var encoded = value.timeIntervalSince1970.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendMemorySegmentOptionalDate(_ value: Date?) {
        guard let value else {
            append(0)
            return
        }
        append(1)
        appendMemorySegmentDate(value)
    }
}
