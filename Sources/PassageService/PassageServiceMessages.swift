import PassageCore
import Foundation

/// Stable values shared by Passage's app-hosted service and its local clients.
public enum PassageServiceProtocol {
    public static let currentVersion: UInt16 = 5
    public static let serviceVersion = "0.9.0"
}

/// A caller-supplied identity used for policy decisions and the access log.
///
/// This is descriptive rather than authoritative. The service separately obtains the
/// peer's effective user and group IDs from the Unix-domain socket.
public struct PassageServiceClientIdentity: Codable, Hashable, Sendable {
    public var identifier: String
    public var displayName: String
    public var version: String?

    public init(identifier: String, displayName: String, version: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName
        self.version = version
    }
}

public struct PassageServicePeer: Codable, Hashable, Sendable {
    public let userID: UInt32
    public let groupID: UInt32

    public init(userID: UInt32, groupID: UInt32) {
        self.userID = userID
        self.groupID = groupID
    }
}

public enum PassageServiceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case capabilities
    case health
    case bundle
    case visualSearch
    case memoryCapsule
    case search
    case recent
    case sessions
    case frame
    case statistics
}

public struct PassageServiceCapabilities: Codable, Hashable, Sendable {
    public var serviceVersion: String
    public var protocolVersion: UInt16
    public var bundleSchemaVersion: UInt16
    public var capabilities: [PassageServiceCapability]
    public var disclosureModes: [PassageContextDisclosure]
    public var defaultBundleResultLimit: Int
    public var maximumBundleResultLimit: Int
    public var minimumBundleUTF8ByteBudget: Int
    public var defaultBundleUTF8ByteBudget: Int
    public var maximumBundleUTF8ByteBudget: Int
    public var visualSearchSchemaVersion: UInt16
    public var visualSearchDisclosureModes: [PassageAgentVisualSearchDisclosure]
    public var maximumVisualSearchDescriptionUTF8Bytes: Int
    public var defaultVisualSearchResultLimit: Int
    public var maximumVisualSearchResultLimit: Int
    public var minimumVisualSearchUTF8ByteBudget: Int
    public var defaultVisualSearchUTF8ByteBudget: Int
    public var maximumVisualSearchUTF8ByteBudget: Int
    public var memoryCapsuleSchemaVersion: UInt16
    public var memoryCapsuleRetrievalModalities: [PassageMemoryRetrievalModality]
    public var memoryCapsuleDisclosureModes: [PassageMemoryCapsuleDisclosure]
    public var defaultMemoryCapsuleResultLimit: Int
    public var maximumMemoryCapsuleResultLimit: Int
    public var minimumMemoryCapsuleUTF8ByteBudget: Int
    public var defaultMemoryCapsuleUTF8ByteBudget: Int
    public var maximumMemoryCapsuleUTF8ByteBudget: Int
    public var defaultDeny: Bool
    public var auditBeforeResponse: Bool

    public init(
        serviceVersion: String = PassageServiceProtocol.serviceVersion,
        protocolVersion: UInt16 = PassageServiceProtocol.currentVersion,
        bundleSchemaVersion: UInt16 = PassageContextBundleSchema.currentVersion,
        capabilities: [PassageServiceCapability] = PassageServiceCapability.allCases,
        disclosureModes: [PassageContextDisclosure] = PassageContextDisclosure.allCases,
        defaultBundleResultLimit: Int = PassageContextBundleSchema.defaultResultLimit,
        maximumBundleResultLimit: Int = PassageContextBundleSchema.maximumResultLimit,
        minimumBundleUTF8ByteBudget: Int = PassageContextBundleSchema.minimumUTF8ByteBudget,
        defaultBundleUTF8ByteBudget: Int = PassageContextBundleSchema.defaultUTF8ByteBudget,
        maximumBundleUTF8ByteBudget: Int = PassageContextBundleSchema.maximumUTF8ByteBudget,
        visualSearchSchemaVersion: UInt16 = PassageAgentVisualSearchSchema.currentVersion,
        visualSearchDisclosureModes: [PassageAgentVisualSearchDisclosure] = PassageAgentVisualSearchDisclosure.allCases,
        maximumVisualSearchDescriptionUTF8Bytes: Int = PassageAgentVisualSearchSchema.maximumDescriptionUTF8Bytes,
        defaultVisualSearchResultLimit: Int = PassageAgentVisualSearchSchema.defaultResultLimit,
        maximumVisualSearchResultLimit: Int = PassageAgentVisualSearchSchema.maximumResultLimit,
        minimumVisualSearchUTF8ByteBudget: Int = PassageAgentVisualSearchSchema.minimumUTF8ByteBudget,
        defaultVisualSearchUTF8ByteBudget: Int = PassageAgentVisualSearchSchema.defaultUTF8ByteBudget,
        maximumVisualSearchUTF8ByteBudget: Int = PassageAgentVisualSearchSchema.maximumUTF8ByteBudget,
        memoryCapsuleSchemaVersion: UInt16 = PassageMemoryCapsuleSchema.currentVersion,
        memoryCapsuleRetrievalModalities: [PassageMemoryRetrievalModality] = PassageMemoryRetrievalModality.allCases,
        memoryCapsuleDisclosureModes: [PassageMemoryCapsuleDisclosure] = PassageMemoryCapsuleDisclosure.allCases,
        defaultMemoryCapsuleResultLimit: Int = PassageMemoryCapsuleSchema.defaultResultLimit,
        maximumMemoryCapsuleResultLimit: Int = PassageMemoryCapsuleSchema.maximumResultLimit,
        minimumMemoryCapsuleUTF8ByteBudget: Int = PassageMemoryCapsuleSchema.minimumUTF8ByteBudget,
        defaultMemoryCapsuleUTF8ByteBudget: Int = PassageMemoryCapsuleSchema.defaultUTF8ByteBudget,
        maximumMemoryCapsuleUTF8ByteBudget: Int = PassageMemoryCapsuleSchema.maximumUTF8ByteBudget,
        defaultDeny: Bool = true,
        auditBeforeResponse: Bool = true
    ) {
        self.serviceVersion = serviceVersion
        self.protocolVersion = protocolVersion
        self.bundleSchemaVersion = bundleSchemaVersion
        self.capabilities = capabilities
        self.disclosureModes = disclosureModes
        self.defaultBundleResultLimit = defaultBundleResultLimit
        self.maximumBundleResultLimit = maximumBundleResultLimit
        self.minimumBundleUTF8ByteBudget = minimumBundleUTF8ByteBudget
        self.defaultBundleUTF8ByteBudget = defaultBundleUTF8ByteBudget
        self.maximumBundleUTF8ByteBudget = maximumBundleUTF8ByteBudget
        self.visualSearchSchemaVersion = visualSearchSchemaVersion
        self.visualSearchDisclosureModes = visualSearchDisclosureModes
        self.maximumVisualSearchDescriptionUTF8Bytes = maximumVisualSearchDescriptionUTF8Bytes
        self.defaultVisualSearchResultLimit = defaultVisualSearchResultLimit
        self.maximumVisualSearchResultLimit = maximumVisualSearchResultLimit
        self.minimumVisualSearchUTF8ByteBudget = minimumVisualSearchUTF8ByteBudget
        self.defaultVisualSearchUTF8ByteBudget = defaultVisualSearchUTF8ByteBudget
        self.maximumVisualSearchUTF8ByteBudget = maximumVisualSearchUTF8ByteBudget
        self.memoryCapsuleSchemaVersion = memoryCapsuleSchemaVersion
        self.memoryCapsuleRetrievalModalities = memoryCapsuleRetrievalModalities
        self.memoryCapsuleDisclosureModes = memoryCapsuleDisclosureModes
        self.defaultMemoryCapsuleResultLimit = defaultMemoryCapsuleResultLimit
        self.maximumMemoryCapsuleResultLimit = maximumMemoryCapsuleResultLimit
        self.minimumMemoryCapsuleUTF8ByteBudget = minimumMemoryCapsuleUTF8ByteBudget
        self.defaultMemoryCapsuleUTF8ByteBudget = defaultMemoryCapsuleUTF8ByteBudget
        self.maximumMemoryCapsuleUTF8ByteBudget = maximumMemoryCapsuleUTF8ByteBudget
        self.defaultDeny = defaultDeny
        self.auditBeforeResponse = auditBeforeResponse
    }

    public static let current = PassageServiceCapabilities()
}

public enum PassageServiceHealthStatus: String, Codable, Hashable, Sendable {
    case ready
}

public struct PassageServiceHealth: Codable, Hashable, Sendable {
    public var status: PassageServiceHealthStatus
    public var serviceVersion: String
    public var protocolVersion: UInt16
    public var bundleSchemaVersion: UInt16

    public init(
        status: PassageServiceHealthStatus = .ready,
        serviceVersion: String = PassageServiceProtocol.serviceVersion,
        protocolVersion: UInt16 = PassageServiceProtocol.currentVersion,
        bundleSchemaVersion: UInt16 = PassageContextBundleSchema.currentVersion
    ) {
        self.status = status
        self.serviceVersion = serviceVersion
        self.protocolVersion = protocolVersion
        self.bundleSchemaVersion = bundleSchemaVersion
    }

    public static let ready = PassageServiceHealth()
}

/// A single, self-contained service request. Exactly one capability-specific payload
/// is allowed; `validate()` enforces that invariant after decoding untrusted input.
public struct PassageServiceRequest: Codable, Hashable, Sendable {
    public var protocolVersion: UInt16
    public var requestID: UUID
    public var client: PassageServiceClientIdentity
    public var capability: PassageServiceCapability
    public var searchQuery: SearchQuery?
    public var recentLimit: Int?
    public var frameID: FrameID?
    public var bundleRequest: PassageContextBundleRequest?
    public var visualSearchRequest: PassageAgentVisualSearchRequest?
    public var memoryCapsuleRequest: PassageMemoryCapsuleRequest?
    public var activitySessionQuery: ActivitySessionQuery?

    public init(
        protocolVersion: UInt16 = PassageServiceProtocol.currentVersion,
        requestID: UUID = UUID(),
        client: PassageServiceClientIdentity,
        capability: PassageServiceCapability,
        searchQuery: SearchQuery? = nil,
        recentLimit: Int? = nil,
        frameID: FrameID? = nil,
        bundleRequest: PassageContextBundleRequest? = nil,
        visualSearchRequest: PassageAgentVisualSearchRequest? = nil,
        memoryCapsuleRequest: PassageMemoryCapsuleRequest? = nil,
        activitySessionQuery: ActivitySessionQuery? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.client = client
        self.capability = capability
        self.searchQuery = searchQuery
        self.recentLimit = recentLimit
        self.frameID = frameID
        self.bundleRequest = bundleRequest
        self.visualSearchRequest = visualSearchRequest
        self.memoryCapsuleRequest = memoryCapsuleRequest
        self.activitySessionQuery = activitySessionQuery
    }

    public static func capabilities(
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(requestID: requestID, client: client, capability: .capabilities)
    }

    public static func health(
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(requestID: requestID, client: client, capability: .health)
    }

    public static func bundle(
        _ bundleRequest: PassageContextBundleRequest,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(
            requestID: requestID,
            client: client,
            capability: .bundle,
            bundleRequest: bundleRequest
        )
    }

    public static func search(
        _ query: SearchQuery,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(requestID: requestID, client: client, capability: .search, searchQuery: query)
    }

    public static func visualSearch(
        _ visualSearchRequest: PassageAgentVisualSearchRequest,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(
            requestID: requestID,
            client: client,
            capability: .visualSearch,
            visualSearchRequest: visualSearchRequest
        )
    }

    public static func memoryCapsule(
        _ memoryCapsuleRequest: PassageMemoryCapsuleRequest,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(
            requestID: requestID,
            client: client,
            capability: .memoryCapsule,
            memoryCapsuleRequest: memoryCapsuleRequest
        )
    }

    public static func recent(
        limit: Int,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(requestID: requestID, client: client, capability: .recent, recentLimit: limit)
    }

    public static func sessions(
        _ query: ActivitySessionQuery,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(
            requestID: requestID,
            client: client,
            capability: .sessions,
            activitySessionQuery: query
        )
    }

    public static func frame(
        id: FrameID,
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(requestID: requestID, client: client, capability: .frame, frameID: id)
    }

    public static func statistics(
        client: PassageServiceClientIdentity,
        requestID: UUID = UUID()
    ) -> Self {
        Self(requestID: requestID, client: client, capability: .statistics)
    }

    public func validate() throws {
        guard protocolVersion == PassageServiceProtocol.currentVersion else {
            throw PassageServiceTransportError.protocolVersionMismatch(
                received: protocolVersion,
                supported: PassageServiceProtocol.currentVersion
            )
        }
        try Self.validateIdentity(client)

        switch capability {
        case .capabilities, .health:
            guard searchQuery == nil, recentLimit == nil, frameID == nil,
                  bundleRequest == nil, visualSearchRequest == nil,
                  memoryCapsuleRequest == nil, activitySessionQuery == nil else {
                throw PassageServiceTransportError.invalidRequest(
                    "Capabilities and health requests do not accept a payload."
                )
            }
        case .bundle:
            guard searchQuery == nil, recentLimit == nil, frameID == nil,
                  visualSearchRequest == nil, memoryCapsuleRequest == nil,
                  activitySessionQuery == nil,
                  let bundleRequest else {
                throw PassageServiceTransportError.invalidRequest(
                    "Bundle requests must contain only a bundleRequest payload."
                )
            }
            try Self.validateSearchQuery(bundleRequest.query)
            guard (1...PassageContextBundleSchema.maximumResultLimit)
                .contains(bundleRequest.resultLimit) else {
                throw PassageServiceTransportError.invalidRequest(
                    "Bundle result limit must be between 1 and \(PassageContextBundleSchema.maximumResultLimit)."
                )
            }
            guard bundleRequest.utf8ByteBudget >= PassageContextBundleSchema.minimumUTF8ByteBudget,
                  bundleRequest.utf8ByteBudget <= PassageContextBundleSchema.maximumUTF8ByteBudget else {
                throw PassageServiceTransportError.invalidRequest(
                    "Bundle byte budget must be between \(PassageContextBundleSchema.minimumUTF8ByteBudget) and \(PassageContextBundleSchema.maximumUTF8ByteBudget) UTF-8 bytes."
                )
            }
            guard bundleRequest.disclosure == .textOnly else {
                throw PassageServiceTransportError.invalidRequest(
                    "This Passage build supports text-only context bundles."
                )
            }
        case .visualSearch:
            guard searchQuery == nil, recentLimit == nil, frameID == nil,
                  bundleRequest == nil, memoryCapsuleRequest == nil,
                  activitySessionQuery == nil,
                  let visualSearchRequest else {
                throw PassageServiceTransportError.invalidRequest(
                    "Visual-search requests must contain only a visualSearchRequest payload."
                )
            }
            try Self.validateVisualSearchRequest(visualSearchRequest)
        case .memoryCapsule:
            guard searchQuery == nil, recentLimit == nil, frameID == nil,
                  bundleRequest == nil, visualSearchRequest == nil,
                  activitySessionQuery == nil, let memoryCapsuleRequest else {
                throw PassageServiceTransportError.invalidRequest(
                    "Memory-capsule requests must contain only a memoryCapsuleRequest payload."
                )
            }
            try Self.validateMemoryCapsuleRequest(memoryCapsuleRequest)
        case .search:
            guard let searchQuery, recentLimit == nil, frameID == nil,
                  bundleRequest == nil, visualSearchRequest == nil,
                  memoryCapsuleRequest == nil, activitySessionQuery == nil else {
                throw PassageServiceTransportError.invalidRequest(
                    "Search requests must contain only a searchQuery payload."
                )
            }
            try Self.validateSearchQuery(searchQuery)
        case .recent:
            guard searchQuery == nil, frameID == nil, bundleRequest == nil,
                  visualSearchRequest == nil, memoryCapsuleRequest == nil,
                  activitySessionQuery == nil,
                  let recentLimit,
                  (1...100).contains(recentLimit) else {
                throw PassageServiceTransportError.invalidRequest(
                    "Recent requests must contain only a limit between 1 and 100."
                )
            }
        case .sessions:
            guard searchQuery == nil, recentLimit == nil, frameID == nil,
                  bundleRequest == nil, visualSearchRequest == nil,
                  memoryCapsuleRequest == nil, let activitySessionQuery else {
                throw PassageServiceTransportError.invalidRequest(
                    "Session requests must contain only an activitySessionQuery payload."
                )
            }
            try Self.validateActivitySessionQuery(activitySessionQuery)
        case .frame:
            guard searchQuery == nil, recentLimit == nil, bundleRequest == nil,
                  visualSearchRequest == nil, memoryCapsuleRequest == nil,
                  activitySessionQuery == nil,
                  let frameID,
                  !frameID.rawValue.isEmpty, frameID.rawValue.utf8.count <= 128 else {
                throw PassageServiceTransportError.invalidRequest(
                    "Frame requests must contain one non-empty frame ID of at most 128 bytes."
                )
            }
        case .statistics:
            guard searchQuery == nil, recentLimit == nil, frameID == nil,
                  bundleRequest == nil, visualSearchRequest == nil,
                  memoryCapsuleRequest == nil, activitySessionQuery == nil else {
                throw PassageServiceTransportError.invalidRequest(
                    "Statistics requests do not accept a payload."
                )
            }
        }
    }

    package static func validateMemoryCapsuleRequest(
        _ request: PassageMemoryCapsuleRequest
    ) throws {
        try validateSearchQuery(request.query)
        let query = request.query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw PassageServiceTransportError.invalidRequest(
                "Memory-capsule queries must not be empty."
            )
        }
        guard request.query.text.utf8.count <= PassageMemoryCapsuleSchema.maximumQueryUTF8Bytes else {
            throw PassageServiceTransportError.invalidRequest(
                "Memory-capsule queries must not exceed \(PassageMemoryCapsuleSchema.maximumQueryUTF8Bytes) UTF-8 bytes."
            )
        }
        guard (1...PassageMemoryCapsuleSchema.maximumResultLimit)
            .contains(request.resultLimit) else {
            throw PassageServiceTransportError.invalidRequest(
                "Memory-capsule result limit must be between 1 and \(PassageMemoryCapsuleSchema.maximumResultLimit)."
            )
        }
        guard (PassageMemoryCapsuleSchema.minimumUTF8ByteBudget
                ... PassageMemoryCapsuleSchema.maximumUTF8ByteBudget)
            .contains(request.utf8ByteBudget) else {
            throw PassageServiceTransportError.invalidRequest(
                "Memory-capsule byte budget must be between \(PassageMemoryCapsuleSchema.minimumUTF8ByteBudget) and \(PassageMemoryCapsuleSchema.maximumUTF8ByteBudget) UTF-8 bytes."
            )
        }
        let modalities = request.retrievalModalities
        guard !modalities.isEmpty, Set(modalities).count == modalities.count else {
            throw PassageServiceTransportError.invalidRequest(
                "Memory-capsule retrieval modalities must be non-empty and unique."
            )
        }
        guard request.disclosure == .structuredEvidence else {
            throw PassageServiceTransportError.invalidRequest(
                "This Passage build supports structured-evidence memory capsules."
            )
        }
    }

    private static func validateVisualSearchRequest(
        _ request: PassageAgentVisualSearchRequest
    ) throws {
        let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search descriptions must not be empty."
            )
        }
        guard request.description.utf8.count <= PassageAgentVisualSearchSchema.maximumDescriptionUTF8Bytes else {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search descriptions must not exceed \(PassageAgentVisualSearchSchema.maximumDescriptionUTF8Bytes) UTF-8 bytes."
            )
        }
        guard (PassageAgentVisualSearchSchema.minimumResultLimit
                ... PassageAgentVisualSearchSchema.maximumResultLimit)
            .contains(request.resultLimit) else {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search result limit must be between \(PassageAgentVisualSearchSchema.minimumResultLimit) and \(PassageAgentVisualSearchSchema.maximumResultLimit)."
            )
        }
        guard (PassageAgentVisualSearchSchema.minimumUTF8ByteBudget
                ... PassageAgentVisualSearchSchema.maximumUTF8ByteBudget)
            .contains(request.utf8ByteBudget) else {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search byte budget must be between \(PassageAgentVisualSearchSchema.minimumUTF8ByteBudget) and \(PassageAgentVisualSearchSchema.maximumUTF8ByteBudget) UTF-8 bytes."
            )
        }
        guard request.disclosure == .metadataOnly else {
            throw PassageServiceTransportError.invalidRequest(
                "This Passage build supports metadata-only visual search."
            )
        }
        let scope = request.scope
        guard scope.text.isEmpty else {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search scope text must be empty; use the description as the visual query."
            )
        }
        guard scope.applicationBundleIdentifiers.count <= 100,
              scope.domains.count <= 100 else {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search filters may contain at most 100 applications and domains."
            )
        }
        try validateFilterValues(
            scope.applicationBundleIdentifiers,
            label: "Application filters",
            maximumUTF8Bytes: 512
        )
        try validateFilterValues(
            scope.domains,
            label: "Domain filters",
            maximumUTF8Bytes: 253
        )
        if let startDate = scope.startDate,
           let endDate = scope.endDate,
           startDate > endDate {
            throw PassageServiceTransportError.invalidRequest(
                "Visual-search startDate must not be later than endDate."
            )
        }
    }

    private static func validateSearchQuery(_ searchQuery: SearchQuery) throws {
        guard (1...100).contains(searchQuery.limit) else {
            throw PassageServiceTransportError.invalidRequest(
                "Search result limit must be between 1 and 100."
            )
        }
        guard searchQuery.text.utf8.count <= 64 * 1_024 else {
            throw PassageServiceTransportError.invalidRequest(
                "Search text exceeds the 64 KiB protocol limit."
            )
        }
        guard searchQuery.applicationBundleIdentifiers.count <= 100,
              searchQuery.domains.count <= 100,
              searchQuery.activitySessionIDs.count <= 100 else {
            throw PassageServiceTransportError.invalidRequest(
                "Search filters may contain at most 100 applications, domains, and activity sessions."
            )
        }
        try validateFilterValues(
            searchQuery.applicationBundleIdentifiers,
            label: "Application filters",
            maximumUTF8Bytes: 512
        )
        try validateFilterValues(
            searchQuery.domains,
            label: "Domain filters",
            maximumUTF8Bytes: 253
        )
        guard searchQuery.activitySessionIDs.allSatisfy({
            isCanonicalFilterValue($0.rawValue, maximumUTF8Bytes: 128)
        }) else {
            throw PassageServiceTransportError.invalidRequest(
                "Activity session IDs must be trimmed, contain no control or delimiter characters, and use between 1 and 128 UTF-8 bytes."
            )
        }
        if let startDate = searchQuery.startDate,
           let endDate = searchQuery.endDate,
           startDate > endDate {
            throw PassageServiceTransportError.invalidRequest(
                "Search startDate must not be later than endDate."
            )
        }
    }

    private static func validateActivitySessionQuery(_ query: ActivitySessionQuery) throws {
        guard (1...100).contains(query.limit) else {
            throw PassageServiceTransportError.invalidRequest(
                "Session result limit must be between 1 and 100."
            )
        }
        if let startDate = query.startDate,
           let endDate = query.endDate,
           startDate > endDate {
            throw PassageServiceTransportError.invalidRequest(
                "Session startDate must not be later than endDate."
            )
        }
    }

    private static func validateIdentity(_ identity: PassageServiceClientIdentity) throws {
        let identifier = identity.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = identity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.utf8.count <= 128 else {
            throw PassageServiceTransportError.invalidRequest(
                "Client identifiers must contain between 1 and 128 UTF-8 bytes."
            )
        }
        guard !displayName.isEmpty, displayName.utf8.count <= 128 else {
            throw PassageServiceTransportError.invalidRequest(
                "Client display names must contain between 1 and 128 UTF-8 bytes."
            )
        }
        if let version = identity.version, version.utf8.count > 64 {
            throw PassageServiceTransportError.invalidRequest(
                "Client versions must not exceed 64 UTF-8 bytes."
            )
        }
    }

    /// SearchQuery is decoded from an untrusted wire payload, bypassing the
    /// normalizing initializers used by Passage's own UI. Reject values that
    /// a downstream RecallScope would silently trim or drop; otherwise the
    /// lexical half can remain narrowly scoped while visual retrieval widens.
    private static func validateFilterValues(
        _ values: Set<String>,
        label: String,
        maximumUTF8Bytes: Int
    ) throws {
        guard values.allSatisfy({
            isCanonicalFilterValue($0, maximumUTF8Bytes: maximumUTF8Bytes)
        }) else {
            throw PassageServiceTransportError.invalidRequest(
                "\(label) must be trimmed, contain no control or delimiter characters, and use between 1 and \(maximumUTF8Bytes) UTF-8 bytes each."
            )
        }
    }

    private static func isCanonicalFilterValue(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.utf8.count <= maximumUTF8Bytes,
              !value.contains(";"),
              !value.contains(",") else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// The typed success body of a response. Coding is explicitly tagged so the wire
/// representation remains readable and does not depend on Swift enum synthesis.
public enum PassageServiceResult: Hashable, Sendable {
    case capabilities(PassageServiceCapabilities)
    case health(PassageServiceHealth)
    case bundle(PassageContextBundleManifest)
    case visualSearch(PassageAgentVisualSearchManifest)
    case memoryCapsule(PassageMemoryCapsuleManifest)
    case search([SearchHit])
    case recent([SearchHit])
    case sessions([ActivitySessionSummary])
    case frame(FrameDocument?)
    case statistics(StoreStatistics)

    public var capability: PassageServiceCapability {
        switch self {
        case .capabilities: .capabilities
        case .health: .health
        case .bundle: .bundle
        case .visualSearch: .visualSearch
        case .memoryCapsule: .memoryCapsule
        case .search: .search
        case .recent: .recent
        case .sessions: .sessions
        case .frame: .frame
        case .statistics: .statistics
        }
    }
}

extension PassageServiceResult: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case hits
        case frame
        case statistics
        case capabilities
        case health
        case bundle
        case visualSearch
        case memoryCapsule
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PassageServiceCapability.self, forKey: .kind)
        switch kind {
        case .capabilities:
            try Self.rejectMixedPayload(in: container, expected: .capabilities)
            self = .capabilities(try container.decode(PassageServiceCapabilities.self, forKey: .capabilities))
        case .health:
            try Self.rejectMixedPayload(in: container, expected: .health)
            self = .health(try container.decode(PassageServiceHealth.self, forKey: .health))
        case .bundle:
            try Self.rejectMixedPayload(in: container, expected: .bundle)
            self = .bundle(try container.decode(PassageContextBundleManifest.self, forKey: .bundle))
        case .visualSearch:
            try Self.rejectMixedPayload(in: container, expected: .visualSearch)
            self = .visualSearch(try container.decode(
                PassageAgentVisualSearchManifest.self,
                forKey: .visualSearch
            ))
        case .memoryCapsule:
            try Self.rejectMixedPayload(in: container, expected: .memoryCapsule)
            self = .memoryCapsule(try container.decode(
                PassageMemoryCapsuleManifest.self,
                forKey: .memoryCapsule
            ))
        case .search:
            try Self.rejectMixedPayload(in: container, expected: .hits)
            self = .search(try container.decode([SearchHit].self, forKey: .hits))
        case .recent:
            try Self.rejectMixedPayload(in: container, expected: .hits)
            self = .recent(try container.decode([SearchHit].self, forKey: .hits))
        case .sessions:
            try Self.rejectMixedPayload(in: container, expected: .sessions)
            self = .sessions(try container.decode([ActivitySessionSummary].self, forKey: .sessions))
        case .frame:
            try Self.rejectMixedPayload(in: container, expected: .frame)
            self = .frame(try container.decodeIfPresent(FrameDocument.self, forKey: .frame))
        case .statistics:
            try Self.rejectMixedPayload(in: container, expected: .statistics)
            self = .statistics(try container.decode(StoreStatistics.self, forKey: .statistics))
        }
    }

    private static func rejectMixedPayload(
        in container: KeyedDecodingContainer<CodingKeys>,
        expected: CodingKeys
    ) throws {
        let unexpected = CodingKeys.allCases.filter {
            $0 != .kind && $0 != expected && container.contains($0)
        }
        guard unexpected.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "A Passage service result must contain only its tagged payload."
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capability, forKey: .kind)
        switch self {
        case .capabilities(let capabilities):
            try container.encode(capabilities, forKey: .capabilities)
        case .health(let health):
            try container.encode(health, forKey: .health)
        case .bundle(let bundle):
            try container.encode(bundle, forKey: .bundle)
        case .visualSearch(let manifest):
            try container.encode(manifest, forKey: .visualSearch)
        case .memoryCapsule(let manifest):
            try container.encode(manifest, forKey: .memoryCapsule)
        case .search(let hits), .recent(let hits):
            try container.encode(hits, forKey: .hits)
        case .sessions(let sessions):
            try container.encode(sessions, forKey: .sessions)
        case .frame(let frame):
            try container.encodeIfPresent(frame, forKey: .frame)
        case .statistics(let statistics):
            try container.encode(statistics, forKey: .statistics)
        }
    }
}

public enum PassageServiceFailureCode: String, Codable, Hashable, Sendable {
    case denied
    case invalidRequest
    case unsupportedCapability
    case notFound
    case protocolMismatch
    case requestTooLarge
    case responseTooLarge
    case malformedMessage
    case busy
    case internalError
}

public struct PassageServiceFailure: Codable, Error, Hashable, LocalizedError, Sendable {
    public var code: PassageServiceFailureCode
    public var message: String
    public var retryable: Bool

    public init(code: PassageServiceFailureCode, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var errorDescription: String? { message }
}

/// Throw this from a request handler to return an intentional, structured denial to
/// the caller. Other errors are converted to `internalError` responses.
public struct PassageServiceRejection: Error, LocalizedError, Sendable {
    public let failure: PassageServiceFailure

    public init(_ failure: PassageServiceFailure) {
        self.failure = failure
    }

    public init(
        code: PassageServiceFailureCode,
        message: String,
        retryable: Bool = false
    ) {
        failure = PassageServiceFailure(code: code, message: message, retryable: retryable)
    }

    public var errorDescription: String? { failure.message }
}

public struct PassageServiceResponse: Codable, Hashable, Sendable {
    public var protocolVersion: UInt16
    public var requestID: UUID?
    public var result: PassageServiceResult?
    public var failure: PassageServiceFailure?

    public init(
        protocolVersion: UInt16 = PassageServiceProtocol.currentVersion,
        requestID: UUID?,
        result: PassageServiceResult? = nil,
        failure: PassageServiceFailure? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.failure = failure
    }

    public static func success(requestID: UUID, result: PassageServiceResult) -> Self {
        Self(requestID: requestID, result: result)
    }

    public static func failed(
        requestID: UUID?,
        code: PassageServiceFailureCode,
        message: String,
        retryable: Bool = false
    ) -> Self {
        Self(
            requestID: requestID,
            failure: PassageServiceFailure(code: code, message: message, retryable: retryable)
        )
    }

    public func validate(for request: PassageServiceRequest) throws {
        guard protocolVersion == PassageServiceProtocol.currentVersion else {
            throw PassageServiceTransportError.protocolVersionMismatch(
                received: protocolVersion,
                supported: PassageServiceProtocol.currentVersion
            )
        }
        if let requestID, requestID != request.requestID {
            throw PassageServiceTransportError.invalidResponse(
                "Response request ID does not match the request."
            )
        }
        guard (result == nil) != (failure == nil) else {
            throw PassageServiceTransportError.invalidResponse(
                "A response must contain exactly one of result or failure."
            )
        }
        if let result, result.capability != request.capability {
            throw PassageServiceTransportError.invalidResponse(
                "Response capability \(result.capability.rawValue) does not match request capability \(request.capability.rawValue)."
            )
        }
        if result != nil, requestID == nil {
            throw PassageServiceTransportError.invalidResponse(
                "A successful response must include the request ID."
            )
        }
    }
}

/// Storage and policy remain outside the transport. The app injects an implementation
/// that authorizes the descriptive identity against the verified local peer, performs
/// the operation, and records the access event.
public protocol PassageServiceRequestHandling: Sendable {
    func handle(
        _ request: PassageServiceRequest,
        peer: PassageServicePeer
    ) async throws -> PassageServiceResult
}

/// A convenient type eraser for app composition and focused tests.
public struct AnyPassageServiceRequestHandler: PassageServiceRequestHandling, Sendable {
    private let body: @Sendable (PassageServiceRequest, PassageServicePeer) async throws -> PassageServiceResult

    public init(
        _ body: @escaping @Sendable (
            PassageServiceRequest,
            PassageServicePeer
        ) async throws -> PassageServiceResult
    ) {
        self.body = body
    }

    public func handle(
        _ request: PassageServiceRequest,
        peer: PassageServicePeer
    ) async throws -> PassageServiceResult {
        try await body(request, peer)
    }
}
