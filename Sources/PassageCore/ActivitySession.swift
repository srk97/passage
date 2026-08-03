import Foundation

/// A stable identifier for one continuous bout of activity.
///
/// Passage derives the identifier from the first frame in the bout. That makes
/// migration and a live append produce the same identity without storing another
/// random value outside the encrypted index.
public struct ActivitySessionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The safest source Passage can return the user to after an activity session.
/// A web URL restores the exact captured page. When no safe URL was captured, the
/// bundle identifier can only reactivate the application, so clients should make
/// that distinction clear in their copy.
public struct ActivityResumeTarget: Codable, Hashable, Sendable {
    public var url: URL?
    public var bundleIdentifier: String?
    public var applicationName: String

    public init(
        url: URL? = nil,
        bundleIdentifier: String? = nil,
        applicationName: String
    ) {
        self.url = Self.safeWebURL(url)
        self.bundleIdentifier = bundleIdentifier?.nilIfBlank
        self.applicationName = applicationName
    }

    public var restoresExactSource: Bool { url != nil }

    public static func safeWebURL(_ candidate: URL?) -> URL? {
        guard let candidate,
              let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return candidate
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case bundleIdentifier
        case applicationName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decodeIfPresent(URL.self, forKey: .url),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            applicationName: try container.decode(String.self, forKey: .applicationName)
        )
    }
}

/// The compact, indexed representation used by session lists and agent discovery.
public struct ActivitySessionSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: ActivitySessionID
    public var startedAt: Date
    public var endedAt: Date
    public var frameCount: Int
    public var title: String
    public var latestApplicationName: String
    public var latestBundleIdentifier: String?
    public var latestDomain: String?
    public var representativeFrameID: FrameID
    public var representativeThumbnailRelativePath: String?
    public var latestFrameID: FrameID
    public var latestSnippet: String
    public var resumeTarget: ActivityResumeTarget
    /// A fail-closed signal for consumers outside the private app UI. A mixed
    /// session is considered sensitive even if its latest frame was ordinary.
    public var containsSensitive: Bool

    public init(
        id: ActivitySessionID,
        startedAt: Date,
        endedAt: Date,
        frameCount: Int,
        title: String,
        latestApplicationName: String,
        latestBundleIdentifier: String? = nil,
        latestDomain: String? = nil,
        representativeFrameID: FrameID,
        representativeThumbnailRelativePath: String? = nil,
        latestFrameID: FrameID,
        latestSnippet: String,
        resumeTarget: ActivityResumeTarget,
        containsSensitive: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.frameCount = max(frameCount, 0)
        self.title = title
        self.latestApplicationName = latestApplicationName
        self.latestBundleIdentifier = latestBundleIdentifier
        self.latestDomain = latestDomain
        self.representativeFrameID = representativeFrameID
        self.representativeThumbnailRelativePath = representativeThumbnailRelativePath
        self.latestFrameID = latestFrameID
        self.latestSnippet = latestSnippet
        self.resumeTarget = resumeTarget
        self.containsSensitive = containsSensitive
    }

    public var duration: TimeInterval {
        max(endedAt.timeIntervalSince(startedAt), 0)
    }
}

public struct ActivitySessionQuery: Codable, Hashable, Sendable {
    public var startDate: Date?
    public var endDate: Date?
    public var limit: Int
    /// Private app surfaces include every locally stored session. Agent-facing
    /// callers should set this to false and omit any mixed sensitive session.
    public var includeSensitive: Bool

    public init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 30,
        includeSensitive: Bool = true
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.limit = min(max(limit, 1), 100)
        self.includeSensitive = includeSensitive
    }
}

public struct ActivitySessionDetail: Codable, Hashable, Sendable {
    public var summary: ActivitySessionSummary
    /// Newest first, bounded by the repository request.
    public var moments: [SearchHit]

    public init(summary: ActivitySessionSummary, moments: [SearchHit]) {
        self.summary = summary
        self.moments = moments
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
