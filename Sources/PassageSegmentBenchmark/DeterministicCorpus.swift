import PassageCore
import Foundation

struct DeterministicSegmentCorpus: Sendable {
    static let revision = "chronicle.memory-segment-benchmark-corpus.v2"
    static let baseTimestamp: TimeInterval = 1_700_000_000
    static let sessionStartInterval: TimeInterval = 10 * 60
    static let frameInterval: TimeInterval = 2
    static let sensitiveSessionStride = 17
    static let applicationCount = 20
    static let siteCount = 30
    static let topicCount = 128
    static let needleFrameIndex = 4_242
    static let domainlessContextKey = 3
    static let keyDistribution = [70, 20, 8, 2]

    let frameCount: Int
    let framesPerSession: Int
    let contextKeyCount: Int

    init(frameCount: Int, framesPerSession: Int, contextKeyCount: Int) {
        precondition(framesPerSession == 100)
        precondition(contextKeyCount == 4)
        precondition(frameCount >= Self.needleFrameIndex + 1)
        precondition(frameCount.isMultiple(of: framesPerSession))
        self.frameCount = frameCount
        self.framesPerSession = framesPerSession
        self.contextKeyCount = contextKeyCount
    }

    var sessionCount: Int { frameCount / framesPerSession }

    var sensitiveSessionCount: Int {
        (0..<sessionCount).filter(isSensitiveSession).count
    }

    var expectedSegmentCount: Int {
        sessionCount * Self.segmentsPerSession
    }

    var expectedAgentSafeSegmentCount: Int {
        expectedSegmentCount - sensitiveSessionCount * Self.segmentsPerSession
    }

    var expectedNeedleFrameCount: Int {
        frameCount > Self.needleFrameIndex ? 1 : 0
    }

    func expectedSegmentCount(
        topic: Int? = nil,
        application: Int? = nil,
        site: Int? = nil,
        agentSafe: Bool = false
    ) -> Int {
        var total = 0
        for sessionIndex in 0..<sessionCount {
            if let topic, sessionIndex % Self.topicCount != topic { continue }
            if agentSafe, isSensitiveSession(sessionIndex) { continue }
            for key in 0..<contextKeyCount {
                let context = Self.context(sessionIndex: sessionIndex, key: key)
                if let application, context.application != application { continue }
                if let site, context.site != site { continue }
                total += Self.segmentCount(forKey: key)
            }
        }
        return total
    }

    func expectedFrameCount(
        topic: Int? = nil,
        application: Int? = nil,
        site: Int? = nil,
        agentSafe: Bool = false
    ) -> Int {
        var total = 0
        for sessionIndex in 0..<sessionCount {
            if let topic, sessionIndex % Self.topicCount != topic { continue }
            if agentSafe, isSensitiveSession(sessionIndex) { continue }
            for key in 0..<contextKeyCount {
                let context = Self.context(sessionIndex: sessionIndex, key: key)
                if let application, context.application != application { continue }
                if let site, context.site != site { continue }
                total += Self.keyDistribution[key]
            }
        }
        return total
    }

    func frames(in range: Range<Int>) -> [FrameDocument] {
        range.map(frame)
    }

    func frame(_ index: Int) -> FrameDocument {
        precondition(index >= 0)
        let sessionIndex = index / framesPerSession
        let offset = index % framesPerSession
        let key = Self.contextKey(forOffset: offset)
        let context = Self.context(sessionIndex: sessionIndex, key: key)
        let topic = sessionIndex % Self.topicCount
        let isSensitive = isSensitiveSession(sessionIndex) && offset == 0
        let siteText = context.site.map { "Site site\($0).example" }
            ?? "Native domainless context"
        let marker = index == Self.needleFrameIndex
            ? "needle4242 unique retrieval marker"
            : "Routine deterministic retrieval evidence"
        let lines = [
            "Passage deterministic memory segment evidence",
            "topic\(topic) session research",
            "Session \(sessionIndex) context \(key) iteration \(index)",
            "Application app\(context.application)",
            siteText,
            marker,
        ]
        let ocrText = lines.joined(separator: "\n")
        let domain = context.site.map { "site\($0).example" }
        return FrameDocument(
            id: frameID(index),
            capturedAt: capturedAt(index),
            context: ScreenContext(
                applicationName: "Application \(context.application)",
                bundleIdentifier: "app.fixture.\(context.application)",
                windowTitle: "topic\(topic) — session \(sessionIndex) context \(key)",
                url: domain.flatMap {
                    URL(string: "https://\($0)/session/\(sessionIndex)/frame/\(index)")
                },
                domain: domain,
                isSensitive: isSensitive
            ),
            ocrText: ocrText,
            ocrRegions: lines.enumerated().map { lineIndex, line in
                OCRRegion(
                    text: line,
                    confidence: Float(0.82 + Double(lineIndex) * 0.025),
                    x: 0.04,
                    y: 0.08 + Double(lineIndex) * 0.13,
                    width: min(0.90, 0.12 + Double(line.utf8.count) * 0.006),
                    height: 0.055
                )
            },
            imageRelativePath: "Media/fixture/\(index).jpg",
            thumbnailRelativePath: "Thumbnails/fixture/\(index).jpg",
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            visualFingerprint: UInt64(truncatingIfNeeded: index &* 2_654_435_761),
            changeScore: Double(index % 64) / 64
        )
    }

    func capturedAt(_ index: Int) -> Date {
        let sessionIndex = index / framesPerSession
        let offset = index % framesPerSession
        return Date(
            timeIntervalSince1970: Self.baseTimestamp
                + Double(sessionIndex) * Self.sessionStartInterval
                + Double(offset) * Self.frameInterval
        )
    }

    func frameID(_ index: Int) -> FrameID {
        FrameID(rawValue: String(format: "segment-benchmark-%012d", index))
    }

    func sessionID(_ sessionIndex: Int) -> ActivitySessionID {
        ActivitySessionID(rawValue: frameID(sessionIndex * framesPerSession).rawValue)
    }

    func scope(forSession sessionIndex: Int) throws -> MemorySegmentScope {
        try MemorySegmentScope(activitySessionIDs: [sessionID(sessionIndex)])
    }

    func scope(forFrameRange range: Range<Int>) throws -> MemorySegmentScope {
        precondition(!range.isEmpty)
        return try MemorySegmentScope(
            startDate: capturedAt(range.lowerBound),
            endDate: capturedAt(range.upperBound - 1).addingTimeInterval(1)
        )
    }

    func isSensitiveSession(_ sessionIndex: Int) -> Bool {
        sessionIndex.isMultiple(of: Self.sensitiveSessionStride)
    }

    static var segmentsPerSession: Int {
        keyDistribution.enumerated().reduce(0) { partial, item in
            partial + segmentCount(forKey: item.offset)
        }
    }

    static func segmentCount(forKey key: Int) -> Int {
        (keyDistribution[key] + 63) / 64
    }

    static func context(sessionIndex: Int, key: Int) -> (application: Int, site: Int?) {
        precondition((0..<4).contains(key))
        return switch key {
        case 0: (sessionIndex % applicationCount, sessionIndex % siteCount)
        case 1: ((sessionIndex + 1) % applicationCount, (sessionIndex + 7) % siteCount)
        case 2: ((sessionIndex + 2) % applicationCount, (sessionIndex + 13) % siteCount)
        default: ((sessionIndex + 3) % applicationCount, nil)
        }
    }

    private static func contextKey(forOffset offset: Int) -> Int {
        precondition(offset >= 0 && offset < 100)
        return switch offset {
        case 0..<70: 0
        case 70..<90: 1
        case 90..<98: 2
        default: 3
        }
    }
}
