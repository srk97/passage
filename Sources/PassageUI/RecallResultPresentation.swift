import PassageCore
import Foundation

/// A reversible presentation group for nearby changes from the same visible
/// activity. Every exact `SearchHit` remains available and selectable.
struct RecallMomentStack: Identifiable, Hashable, Sendable {
    let hits: [SearchHit]

    init(hits: [SearchHit]) {
        precondition(!hits.isEmpty, "A Recall moment stack must not be empty.")
        self.hits = hits
    }

    var id: FrameID { hits[0].id }
    var count: Int { hits.count }
    var memberIDs: Set<FrameID> { Set(hits.map(\.id)) }

    func contains(_ frameID: FrameID?) -> Bool {
        guard let frameID else { return false }
        return hits.contains { $0.id == frameID }
    }

    /// Keep an exact selected change visible when its surrounding activity is
    /// collapsed; otherwise represent the stack with its newest change.
    func representative(selectedID: FrameID?) -> SearchHit {
        if let selectedID, let selected = hits.first(where: { $0.id == selectedID }) {
            return selected
        }
        return hits[0]
    }
}

struct RecallDayGroup: Identifiable, Hashable, Sendable {
    let day: Date
    let stacks: [RecallMomentStack]
    let rawMomentCount: Int

    var id: Date { day }
    var activityCount: Int { stacks.count }
}

/// Projects raw chronological Recall results into calm, expandable activity
/// stacks. This never mutates retrieval order, pagination, ranking, or IDs.
enum RecallResultPresentation {
    static let maximumAdjacentGap: TimeInterval = 60
    static let maximumStackSpan: TimeInterval = 5 * 60
    static let maximumStackCount = 180

    static func dayGroups(
        hits: [SearchHit],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [RecallDayGroup] {
        let ordered = hits.sorted(by: chronologicallyPrecedes)
        var days: [(day: Date, hits: [SearchHit])] = []

        for hit in ordered {
            let day = calendar.startOfDay(for: hit.capturedAt)
            if days.last?.day == day {
                days[days.count - 1].hits.append(hit)
            } else {
                days.append((day: day, hits: [hit]))
            }
        }

        return days.map { value in
            RecallDayGroup(
                day: value.day,
                stacks: stacks(hits: value.hits),
                rawMomentCount: value.hits.count
            )
        }
    }

    static func stacks(hits: [SearchHit]) -> [RecallMomentStack] {
        let ordered = hits.sorted(by: chronologicallyPrecedes)
        var groups: [[SearchHit]] = []

        for hit in ordered {
            if let current = groups.last, canAppend(hit, to: current) {
                groups[groups.count - 1].append(hit)
            } else {
                groups.append([hit])
            }
        }

        return groups.map(RecallMomentStack.init(hits:))
    }

    private static func canAppend(_ candidate: SearchHit, to hits: [SearchHit]) -> Bool {
        guard let newest = hits.first, let adjacent = hits.last else { return false }
        guard hits.count < maximumStackCount else { return false }

        let gap = adjacent.capturedAt.timeIntervalSince(candidate.capturedAt)
        guard gap >= 0, gap < maximumAdjacentGap else { return false }
        let span = newest.capturedAt.timeIntervalSince(candidate.capturedAt)
        guard span >= 0, span <= maximumStackSpan else { return false }

        guard let currentSession = normalized(adjacent.activitySessionID?.rawValue),
              let candidateSession = normalized(candidate.activitySessionID?.rawValue),
              currentSession == candidateSession else { return false }
        guard applicationIdentity(adjacent.context) == applicationIdentity(candidate.context)
        else { return false }
        guard normalizedDomain(adjacent.context.domain)
            == normalizedDomain(candidate.context.domain) else { return false }
        guard normalizedText(adjacent.context.windowTitle)
            == normalizedText(candidate.context.windowTitle) else { return false }
        guard canonicalURL(adjacent.context.url) == canonicalURL(candidate.context.url)
        else { return false }

        if let left = adjacent.context.windowID,
           let right = candidate.context.windowID,
           left != right {
            return false
        }
        if let left = adjacent.context.displayID,
           let right = candidate.context.displayID,
           left != right {
            return false
        }
        return true
    }

    private static func chronologicallyPrecedes(_ left: SearchHit, _ right: SearchHit) -> Bool {
        if left.capturedAt != right.capturedAt {
            return left.capturedAt > right.capturedAt
        }
        return left.id.rawValue > right.id.rawValue
    }

    private static func applicationIdentity(_ context: ScreenContext) -> String? {
        if let bundleIdentifier = normalized(context.bundleIdentifier) {
            return "bundle:\(bundleIdentifier)"
        }
        return normalized(context.applicationName).map { "name:\($0)" }
    }

    private static func normalizedDomain(_ value: String?) -> String? {
        normalized(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return result.isEmpty ? nil : result
    }

    private static func canonicalURL(_ value: URL?) -> String? {
        guard let value else { return nil }
        guard var components = URLComponents(
            url: value.absoluteURL,
            resolvingAgainstBaseURL: false
        ) else {
            return value.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string
    }
}
