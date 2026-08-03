import Foundation

public struct ApplicationExclusion: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public struct PrivacyPreferences: Codable, Equatable, Sendable {
    public var captureIntervalMilliseconds: Int
    public var unchangedHeartbeatSeconds: Int
    public var retentionDays: Int
    public var maximumStorageGigabytes: Int
    public var preserveTextAfterImageExpiry: Bool
    public var hideCursor: Bool
    public var captureFocusedWindowOnly: Bool
    public var pauseAfterInactivityMinutes: Int
    public var excludedApplications: [ApplicationExclusion]
    public var excludedDomains: [String]
    public var allowedAgentClients: [String]

    public init(
        captureIntervalMilliseconds: Int = 2_000,
        unchangedHeartbeatSeconds: Int = 30,
        retentionDays: Int = 30,
        maximumStorageGigabytes: Int = 20,
        preserveTextAfterImageExpiry: Bool = true,
        hideCursor: Bool = true,
        captureFocusedWindowOnly: Bool = true,
        pauseAfterInactivityMinutes: Int = 5,
        excludedApplications: [ApplicationExclusion] = Self.defaultApplicationExclusions,
        excludedDomains: [String] = [],
        allowedAgentClients: [String] = []
    ) {
        self.captureIntervalMilliseconds = Self.allowedCaptureInterval(captureIntervalMilliseconds)
        self.unchangedHeartbeatSeconds = min(max(unchangedHeartbeatSeconds, 10), 300)
        self.retentionDays = min(max(retentionDays, 1), 365)
        self.maximumStorageGigabytes = min(max(maximumStorageGigabytes, 1), 500)
        self.preserveTextAfterImageExpiry = preserveTextAfterImageExpiry
        self.hideCursor = hideCursor
        self.captureFocusedWindowOnly = captureFocusedWindowOnly
        self.pauseAfterInactivityMinutes = Self.allowedInactivityMinutes(pauseAfterInactivityMinutes)
        self.excludedApplications = Self.normalizedApplications(excludedApplications)
        self.excludedDomains = Self.normalizedDomains(excludedDomains)
        self.allowedAgentClients = Self.normalizedAgentClients(allowedAgentClients)
    }

    public static let `default` = PrivacyPreferences()

    public static let defaultApplicationExclusions: [ApplicationExclusion] = [
        ApplicationExclusion(bundleIdentifier: "com.1password.1password", displayName: "1Password"),
        ApplicationExclusion(bundleIdentifier: "com.agilebits.onepassword7", displayName: "1Password 7"),
        ApplicationExclusion(bundleIdentifier: "com.apple.keychainaccess", displayName: "Keychain Access"),
        ApplicationExclusion(bundleIdentifier: "com.apple.Passwords", displayName: "Passwords"),
        ApplicationExclusion(bundleIdentifier: "com.bitwarden.desktop", displayName: "Bitwarden")
    ]

    public var capturePolicy: CapturePolicy {
        CapturePolicy(
            activeInterval: .milliseconds(captureIntervalMilliseconds),
            unchangedHeartbeat: .seconds(unchangedHeartbeatSeconds),
            excludedBundleIdentifiers: Set(excludedApplications.map(\.bundleIdentifier)),
            excludedDomains: Set(excludedDomains),
            hideCursor: hideCursor,
            captureFocusedWindowOnly: captureFocusedWindowOnly,
            inactivityPause: pauseAfterInactivityMinutes == 0
                ? nil
                : .seconds(pauseAfterInactivityMinutes * 60)
        )
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maximumAgeDays: retentionDays,
            maximumMediaBytes: Int64(maximumStorageGigabytes) * 1_024 * 1_024 * 1_024,
            preserveTextAfterMediaExpiry: preserveTextAfterImageExpiry
        )
    }

    public mutating func addApplication(_ exclusion: ApplicationExclusion) {
        excludedApplications.append(exclusion)
        excludedApplications = Self.normalizedApplications(excludedApplications)
    }

    public mutating func addDomain(_ domain: String) {
        excludedDomains.append(domain)
        excludedDomains = Self.normalizedDomains(excludedDomains)
    }

    public mutating func setAgentClient(_ identifier: String, allowed: Bool) {
        if allowed {
            allowedAgentClients.append(identifier)
        } else {
            allowedAgentClients.removeAll { $0.caseInsensitiveCompare(identifier) == .orderedSame }
        }
        allowedAgentClients = Self.normalizedAgentClients(allowedAgentClients)
    }

    public mutating func normalize() {
        captureIntervalMilliseconds = Self.allowedCaptureInterval(captureIntervalMilliseconds)
        unchangedHeartbeatSeconds = min(max(unchangedHeartbeatSeconds, 10), 300)
        retentionDays = min(max(retentionDays, 1), 365)
        maximumStorageGigabytes = min(max(maximumStorageGigabytes, 1), 500)
        pauseAfterInactivityMinutes = Self.allowedInactivityMinutes(pauseAfterInactivityMinutes)
        excludedApplications = Self.normalizedApplications(excludedApplications)
        excludedDomains = Self.normalizedDomains(excludedDomains)
        allowedAgentClients = Self.normalizedAgentClients(allowedAgentClients)
    }

    public static func normalizedDomain(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: candidate)?.host(percentEncoded: false) else { return nil }
        let withoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return withoutWWW.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func allowedCaptureInterval(_ value: Int) -> Int {
        [1_000, 2_000, 5_000].min(by: { abs($0 - value) < abs($1 - value) }) ?? 2_000
    }

    private static func allowedInactivityMinutes(_ value: Int) -> Int {
        [0, 5, 10, 30].min(by: { abs($0 - value) < abs($1 - value) }) ?? 5
    }

    private static func normalizedApplications(_ values: [ApplicationExclusion]) -> [ApplicationExclusion] {
        var byIdentifier: [String: ApplicationExclusion] = [:]
        for value in values {
            let identifier = value.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            let name = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            byIdentifier[identifier] = ApplicationExclusion(
                bundleIdentifier: identifier,
                displayName: name.isEmpty ? identifier : name
            )
        }
        return byIdentifier.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func normalizedDomains(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(normalizedDomain))).sorted()
    }

    private static func normalizedAgentClients(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { value -> String? in
            let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !identifier.isEmpty, identifier.utf8.count <= 128 else { return nil }
            return identifier
        })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case captureIntervalMilliseconds
        case unchangedHeartbeatSeconds
        case retentionDays
        case maximumStorageGigabytes
        case preserveTextAfterImageExpiry
        case hideCursor
        case captureFocusedWindowOnly
        case pauseAfterInactivityMinutes
        case excludedApplications
        case excludedDomains
        case allowedAgentClients
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            captureIntervalMilliseconds: try container.decodeIfPresent(Int.self, forKey: .captureIntervalMilliseconds) ?? 2_000,
            unchangedHeartbeatSeconds: try container.decodeIfPresent(Int.self, forKey: .unchangedHeartbeatSeconds) ?? 30,
            retentionDays: try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30,
            maximumStorageGigabytes: try container.decodeIfPresent(Int.self, forKey: .maximumStorageGigabytes) ?? 20,
            preserveTextAfterImageExpiry: try container.decodeIfPresent(Bool.self, forKey: .preserveTextAfterImageExpiry) ?? true,
            hideCursor: try container.decodeIfPresent(Bool.self, forKey: .hideCursor) ?? true,
            captureFocusedWindowOnly: try container.decodeIfPresent(Bool.self, forKey: .captureFocusedWindowOnly) ?? true,
            pauseAfterInactivityMinutes: try container.decodeIfPresent(Int.self, forKey: .pauseAfterInactivityMinutes) ?? 5,
            excludedApplications: try container.decodeIfPresent([ApplicationExclusion].self, forKey: .excludedApplications) ?? Self.defaultApplicationExclusions,
            excludedDomains: try container.decodeIfPresent([String].self, forKey: .excludedDomains) ?? [],
            allowedAgentClients: try container.decodeIfPresent([String].self, forKey: .allowedAgentClients) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureIntervalMilliseconds, forKey: .captureIntervalMilliseconds)
        try container.encode(unchangedHeartbeatSeconds, forKey: .unchangedHeartbeatSeconds)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encode(maximumStorageGigabytes, forKey: .maximumStorageGigabytes)
        try container.encode(preserveTextAfterImageExpiry, forKey: .preserveTextAfterImageExpiry)
        try container.encode(hideCursor, forKey: .hideCursor)
        try container.encode(captureFocusedWindowOnly, forKey: .captureFocusedWindowOnly)
        try container.encode(pauseAfterInactivityMinutes, forKey: .pauseAfterInactivityMinutes)
        try container.encode(excludedApplications, forKey: .excludedApplications)
        try container.encode(excludedDomains, forKey: .excludedDomains)
        try container.encode(allowedAgentClients, forKey: .allowedAgentClients)
    }
}
