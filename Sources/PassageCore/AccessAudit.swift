import Foundation

public struct AccessEventID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

public enum AccessEventOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case denied
    case failure
}

/// A durable receipt for one agent-facing access to Passage data.
public struct AccessEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: AccessEventID
    public var occurredAt: Date
    public var client: String
    public var command: String
    public var capability: String
    public var querySummary: String?
    public var filterSummary: String?
    public var returnedFrameIDs: [FrameID]
    public var returnedFrameCount: Int
    public var outcome: AccessEventOutcome

    public init(
        id: AccessEventID = AccessEventID(),
        occurredAt: Date = Date(),
        client: String,
        command: String,
        capability: String,
        querySummary: String? = nil,
        filterSummary: String? = nil,
        returnedFrameIDs: [FrameID] = [],
        returnedFrameCount: Int? = nil,
        outcome: AccessEventOutcome
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.client = client
        self.command = command
        self.capability = capability
        self.querySummary = querySummary
        self.filterSummary = filterSummary
        self.returnedFrameIDs = returnedFrameIDs
        self.returnedFrameCount = returnedFrameCount ?? returnedFrameIDs.count
        self.outcome = outcome
    }
}
