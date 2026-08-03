import PassageCore
import Foundation

/// The immutable time range used by one Time Lens gesture.
///
/// Passage freezes this value at pointer-down so a newly captured frame cannot
/// move the time beneath the pointer while the person is scrubbing.
public struct RecallTimeLensBounds: Hashable, Sendable {
    public let oldest: Date
    public let newest: Date

    public init?(oldest: Date, newest: Date) {
        guard oldest.timeIntervalSince1970.isFinite,
              newest.timeIntervalSince1970.isFinite,
              oldest <= newest else { return nil }
        self.oldest = oldest
        self.newest = newest
    }

    public var duration: TimeInterval {
        newest.timeIntervalSince(oldest)
    }

    /// Maps a normalized track position to time, clamping input to `0...1`.
    public func date(at fraction: Double) -> Date {
        guard fraction.isFinite, duration > 0 else { return oldest }
        let clamped = min(max(fraction, 0), 1)
        return oldest.addingTimeInterval(duration * clamped)
    }

    /// Maps a date back to a normalized track position, clamping to `0...1`.
    public func fraction(for date: Date) -> Double {
        guard date.timeIntervalSince1970.isFinite, duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(oldest) / duration, 0), 1)
    }

    public func clamped(_ date: Date) -> Date {
        guard date.timeIntervalSince1970.isFinite else { return oldest }
        return min(max(date, oldest), newest)
    }

    static func make(statistics: StoreStatistics, scope: RecallScope) -> Self? {
        guard let retainedOldest = statistics.oldestCapture,
              let retainedNewest = statistics.newestCapture else { return nil }

        let oldest = max(retainedOldest, scope.startDate ?? retainedOldest)
        let scopedNewest: Date
        if let exclusiveEnd = scope.endDate {
            scopedNewest = Date(
                timeIntervalSince1970: exclusiveEnd.timeIntervalSince1970.nextDown
            )
        } else {
            scopedNewest = retainedNewest
        }
        return Self(oldest: oldest, newest: min(retainedNewest, scopedNewest))
    }
}

/// Whether the evidence carried by a Time Lens preview has been resolved for
/// that preview's exact `requestedAt` value.
///
/// A new pointer target deliberately keeps the last visible image while the
/// next local lookup runs. Making that distinction explicit prevents a retained
/// image from being presented as the answer to a newer target after latency or
/// a repository failure.
public enum RecallTimeLensResolution: Hashable, Sendable {
    case resolving
    case resolved
    case failed
}

/// The asynchronous evidence currently shown by the Time Lens preview card.
/// `requestedAt` can move every frame while the local query is throttled. `hit`
/// may be retained to avoid flashing an empty preview; only `resolvedHit` is
/// evidence that belongs to this exact request.
public struct RecallTimeLensPreview: Hashable, Sendable {
    public let requestedAt: Date
    public let hit: SearchHit?
    public let resolution: RecallTimeLensResolution

    public init(
        requestedAt: Date,
        hit: SearchHit?,
        resolution: RecallTimeLensResolution
    ) {
        self.requestedAt = requestedAt
        self.hit = hit
        self.resolution = resolution
    }

    /// Compatibility for callers that only need the original two-state model.
    public init(requestedAt: Date, hit: SearchHit?, isResolving: Bool) {
        self.init(
            requestedAt: requestedAt,
            hit: hit,
            resolution: isResolving ? .resolving : .resolved
        )
    }

    public var isResolving: Bool {
        resolution == .resolving
    }

    public var resolvedHit: SearchHit? {
        guard resolution == .resolved else { return nil }
        return hit
    }
}

enum RecallTimeLensQuery {
    /// Builds a newest-first scope whose exclusive upper bound includes a frame
    /// captured at exactly `target`. Every other active constraint is retained.
    static func scope(atOrBefore target: Date, preserving base: RecallScope) -> RecallScope? {
        guard let targetExclusiveEnd = exclusiveInstant(after: target) else { return nil }
        let exclusiveEnd = min(base.endDate ?? targetExclusiveEnd, targetExclusiveEnd)
        if let start = base.startDate, start >= exclusiveEnd { return nil }
        return RecallScope(
            text: base.text,
            startDate: base.startDate,
            endDate: exclusiveEnd,
            applicationBundleIdentifiers: base.applicationBundleIdentifiers,
            domains: base.domains
        )
    }

    /// `Date` stores its scalar relative to the Foundation reference date.
    /// Advancing a Unix timestamp by one Double ULP can be rounded away while
    /// converting into that representation, so advance the native scalar.
    static func exclusiveInstant(after target: Date) -> Date? {
        let timestamp = target.timeIntervalSinceReferenceDate
        let successor = timestamp.nextUp
        guard timestamp.isFinite, successor.isFinite else { return nil }
        return Date(timeIntervalSinceReferenceDate: successor)
    }
}

enum RecallTimeLensThrottle {
    static let minimumInterval: Duration = .milliseconds(80)

    static func remainingDelay(after elapsed: Duration) -> Duration? {
        guard elapsed < minimumInterval else { return nil }
        return minimumInterval - elapsed
    }
}
