import Foundation

public struct SearchQuery: Codable, Hashable, Sendable {
    public var text: String
    public var startDate: Date?
    public var endDate: Date?
    public var applicationBundleIdentifiers: Set<String>
    public var domains: Set<String>
    public var activitySessionIDs: Set<ActivitySessionID>
    public var limit: Int

    public init(
        text: String = "",
        startDate: Date? = nil,
        endDate: Date? = nil,
        applicationBundleIdentifiers: Set<String> = [],
        domains: Set<String> = [],
        activitySessionIDs: Set<ActivitySessionID> = [],
        limit: Int = 50
    ) {
        self.text = text
        self.startDate = startDate
        self.endDate = endDate
        self.applicationBundleIdentifiers = applicationBundleIdentifiers
        self.domains = domains
        self.activitySessionIDs = activitySessionIDs
        self.limit = min(max(limit, 1), 100)
    }
}

/// A normalized, local-only slice of Passage's retained history.
///
/// Date bounds use a half-open interval: `startDate` is inclusive and
/// `endDate` is exclusive. This makes adjacent calendar-day scopes compose
/// without duplicating a frame at midnight.
public struct RecallScope: Codable, Hashable, Sendable {
    public var text: String
    public var startDate: Date?
    public var endDate: Date?
    public var applicationBundleIdentifiers: Set<String>
    public var domains: Set<String>

    public init(
        text: String = "",
        startDate: Date? = nil,
        endDate: Date? = nil,
        applicationBundleIdentifiers: Set<String> = [],
        domains: Set<String> = []
    ) {
        self.text = Self.normalizeText(text)
        self.startDate = startDate
        self.endDate = endDate
        self.applicationBundleIdentifiers = Self.normalizeIdentifiers(
            applicationBundleIdentifiers
        )
        self.domains = Self.normalizeDomains(domains)
    }

    /// Re-applies Passage's canonicalization after callers mutate a scope.
    public var normalized: RecallScope {
        RecallScope(
            text: text,
            startDate: startDate,
            endDate: endDate,
            applicationBundleIdentifiers: applicationBundleIdentifiers,
            domains: domains
        )
    }

    private static func normalizeText(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizeIdentifiers(_ values: Set<String>) -> Set<String> {
        Set(values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    private static func normalizeDomains(_ values: Set<String>) -> Set<String> {
        Set(values.compactMap { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }
}

/// An exclusive position in a Recall Navigator result stream.
///
/// `token` is intentionally opaque. A cursor is versioned and bound to the
/// normalized scope that produced it; clients should only pass it back to the
/// repository unchanged.
public struct RecallCursor: Codable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public struct RecallPage: Codable, Hashable, Sendable {
    public static let minimumLimit = 1
    public static let maximumLimit = 200

    public var hits: [SearchHit]
    public var nextCursor: RecallCursor?
    public var hasMore: Bool

    public init(
        hits: [SearchHit],
        nextCursor: RecallCursor?,
        hasMore: Bool
    ) {
        self.hits = hits
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RecallApplicationFacet: Codable, Hashable, Sendable, Identifiable {
    public var bundleIdentifier: String
    public var applicationName: String
    public var frameCount: Int

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, applicationName: String, frameCount: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.frameCount = frameCount
    }
}

public struct RecallDomainFacet: Codable, Hashable, Sendable, Identifiable {
    public var domain: String
    public var frameCount: Int

    public var id: String { domain }

    public init(domain: String, frameCount: Int) {
        self.domain = domain
        self.frameCount = frameCount
    }
}

/// Locally aggregated filter choices for a recall scope.
///
/// Repositories use drill-sideways facets: application choices ignore the
/// scope's current application selection, and domain choices ignore its current
/// domain selection. All other filters remain active.
public struct RecallFacets: Codable, Hashable, Sendable {
    public static let maximumLimitPerKind = 100

    public var applications: [RecallApplicationFacet]
    public var domains: [RecallDomainFacet]
    /// The uncapped number of known-browser moments in the domain facet's
    /// drill-sideways scope. `nil` means the repository did not provide the
    /// aggregate; it must never be interpreted as zero.
    public var browserMomentCount: Int?

    public init(
        applications: [RecallApplicationFacet] = [],
        domains: [RecallDomainFacet] = [],
        browserMomentCount: Int? = nil
    ) {
        self.applications = applications
        self.domains = domains
        self.browserMomentCount = browserMomentCount
    }
}

public struct RetentionPolicy: Codable, Hashable, Sendable {
    /// `nil` means no age limit: history is governed only by the media cap,
    /// which deletes the oldest images while text can remain searchable.
    public var maximumAgeDays: Int?
    public var maximumMediaBytes: Int64
    public var preserveTextAfterMediaExpiry: Bool

    public init(
        maximumAgeDays: Int? = nil,
        maximumMediaBytes: Int64 = 20 * 1_024 * 1_024 * 1_024,
        preserveTextAfterMediaExpiry: Bool = true
    ) {
        self.maximumAgeDays = maximumAgeDays.map { max($0, 1) }
        self.maximumMediaBytes = max(maximumMediaBytes, 512 * 1_024 * 1_024)
        self.preserveTextAfterMediaExpiry = preserveTextAfterMediaExpiry
    }
}

public struct CapturePolicy: Codable, Hashable, Sendable {
    public var activeInterval: Duration
    public var unchangedHeartbeat: Duration
    public var minimumFingerprintDistance: Int
    public var excludedBundleIdentifiers: Set<String>
    public var excludedDomains: Set<String>
    public var hideCursor: Bool
    public var captureFocusedWindowOnly: Bool
    public var inactivityPause: Duration?

    public init(
        activeInterval: Duration = .seconds(2),
        unchangedHeartbeat: Duration = .seconds(30),
        minimumFingerprintDistance: Int = 4,
        excludedBundleIdentifiers: Set<String> = [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.apple.keychainaccess",
            "com.apple.Passwords"
        ],
        excludedDomains: Set<String> = [],
        hideCursor: Bool = true,
        captureFocusedWindowOnly: Bool = true,
        inactivityPause: Duration? = .seconds(300)
    ) {
        self.activeInterval = activeInterval
        self.unchangedHeartbeat = unchangedHeartbeat
        self.minimumFingerprintDistance = min(max(minimumFingerprintDistance, 0), 64)
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.excludedDomains = excludedDomains
        self.hideCursor = hideCursor
        self.captureFocusedWindowOnly = captureFocusedWindowOnly
        self.inactivityPause = inactivityPause
    }

    public func permits(_ context: ScreenContext) -> Bool {
        guard !context.isSensitive else { return false }
        if let bundleIdentifier = context.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        if !excludedDomains.isEmpty, context.isWebBrowser {
            guard let domain = context.domain?.lowercased() else {
                return false
            }
            if excludedDomains.contains(where: { excluded in
                domain == excluded || domain.hasSuffix("." + excluded)
            }) {
                return false
            }
        }
        return true
    }
}
