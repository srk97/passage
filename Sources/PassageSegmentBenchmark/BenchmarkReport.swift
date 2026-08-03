import Foundation

struct MemorySegmentBenchmarkReport: Codable, Sendable {
    static let schemaVersion = 3
    static let protocolRevision = "chronicle.memory-segment-benchmark-protocol.v3"

    var schemaVersion: Int
    var protocolRevision: String
    var benchmark: String
    var claimScope: String
    var cacheState: String
    var corpusKind: String
    var mediaFixture: String
    var excludedClaims: [String]
    var generatedAt: String
    var system: BenchmarkSystemReport
    var configuration: BenchmarkConfigurationReport
    var corpus: BenchmarkCorpusReport
    var seed: BenchmarkSeedReport
    var storage: BenchmarkStorageReport
    var index: BenchmarkIndexReport
    var workloads: [BenchmarkWorkloadReport]
    var cursorWalks: [BenchmarkCursorWalkReport]
    var freshConnection: BenchmarkFreshConnectionReport
    var captureProbe: BenchmarkCaptureProbeReport
    var maintenance: BenchmarkMaintenanceReport
    var validations: [String: Bool]
}

struct BenchmarkSystemReport: Codable, Sendable {
    var operatingSystem: String
    var architecture: String
    var processorCount: Int
}

struct BenchmarkConfigurationReport: Codable, Sendable {
    var profile: String
    var runOrdinal: Int
    var requiredRunCount: Int
    var frameCount: Int
    var sampleCount: Int
    var freshConnectionSampleCount: Int
    var batchSize: Int
    var framesPerSession: Int
    var contextKeyCount: Int
    var pageLimit: Int
    var captureProbeCount: Int
}

struct BenchmarkCorpusReport: Codable, Sendable {
    var revision: String
    var sessionCount: Int
    var sensitiveSessionCount: Int
    var applicationCount: Int
    var siteCount: Int
    var topicCount: Int
    var contextKeyFrameDistribution: [Int]
    var domainlessContextKey: Int
    var needleFrameIndex: Int
    var needleFrameCount: Int
    var expectedSegmentCount: Int
    var expectedAgentSafeSegmentCount: Int
    var expectedTopic42SegmentCount: Int
    var expectedTopic42FrameCount: Int
    var expectedTopic42App2Site12SegmentCount: Int
    var expectedTopic42App2Site12FrameCount: Int
    var expectedApp2Site12SegmentCount: Int
    var expectedApp2Site12FrameCount: Int
    var expectedAgentSafeTopic42SegmentCount: Int
    var expectedAgentSafeTopic42FrameCount: Int
}

struct BenchmarkSeedReport: Codable, Sendable {
    var totalMilliseconds: Double
    var framesPerSecond: Double
    var batchLatency: BenchmarkLatencySummary
    var checkpointMilliseconds: Double
}

struct BenchmarkStorageReport: Codable, Sendable {
    var measurement: String
    var accountingNotes: [String]
    var beforeIndex: BenchmarkStorageSnapshotReport
    var afterInitialIndex: BenchmarkStorageSnapshotReport
    var afterVerificationIndex: BenchmarkStorageSnapshotReport
    var shadowBytesPerFrame: Double
    var shadowOverheadRatio: Double
    var verificationShadowGrowthBytes: Int64
    var verificationShadowGrowthBudgetBytes: Int64
    var stableAcrossVerificationRebuild: Bool
    var mediaBytes: Int64
    var memorySegmentSchemaObjects: [String]
    var memorySegmentDBStatObjects: [String]
    var captureWalBytes: Int64
    var maintenanceWalBytes: Int64
    var maintenanceToCaptureWalAmplification: Double
    var writeAmplificationScope: String
}

struct BenchmarkStorageSnapshotReport: Codable, Sendable {
    var logicalMainFileBytes: Int64
    var pageSizeBytes: Int64
    var pageCount: Int64
    var freelistPageCount: Int64
    var liveDatabaseBytes: Int64
    var memorySegmentShadowBytes: Int64
    var canonicalLiveBytes: Int64
    var memorySegmentObjectLiveBytes: [BenchmarkStorageObjectReport]
}

struct BenchmarkStorageObjectReport: Codable, Sendable {
    var name: String
    var liveBytes: Int64
}

struct BenchmarkIndexReport: Codable, Sendable {
    var lifecycle: String
    var lastFullRebuildRevision: String?
    var canonicalFrameCount: Int
    var segmentCount: Int
    var pendingSessionCount: Int?
    var initialRebuildMilliseconds: Double
    var initialCheckpointMilliseconds: Double
    var verificationRebuildMilliseconds: Double
    var verificationCheckpointMilliseconds: Double
    var deterministicLastFullRebuildRevision: Bool
}

struct BenchmarkWorkloadReport: Codable, Sendable {
    var name: String
    var accessBoundary: String
    var requestShape: String
    var sampleCount: Int
    var expectedFirstPageSegmentCount: Int
    var expectedTotalSegmentCount: Int
    var latency: BenchmarkLatencySummary
    var minimumReturnedSegments: Int
    var maximumReturnedSegments: Int
    var firstPageHydration: BenchmarkFirstPageHydrationReport
    var omissionReasons: [String]
}

struct BenchmarkFirstPageHydrationReport: Codable, Sendable {
    var measurement: String
    var measurementCount: Int
    var canonicalFrameLimit: Int
    var minimumHydratedCanonicalFrameCount: Int
    var maximumHydratedCanonicalFrameCount: Int
    var minimumReturnedFrameCount: Int
    var maximumReturnedFrameCount: Int
    var minimumHydrationSurplus: Int
    var withinLimit: Bool
}

struct BenchmarkCursorWalkReport: Codable, Sendable {
    var name: String
    var accessBoundary: String
    var pageLimit: Int
    var expectedSegmentCount: Int
    var returnedSegmentCount: Int
    var expectedFrameCount: Int
    var returnedUniqueFrameCount: Int
    var pageCount: Int
    var accessBoundaryStable: Bool
    var revisionStable: Bool
    var strictOrder: Bool
    var noDuplicateSegments: Bool
    var noDuplicateFrames: Bool
    var agentSafeSegments: Bool
    var policyOmissionCountHidden: Bool
    var terminated: Bool
    var omissionReasons: [String]
}

struct BenchmarkFreshConnectionReport: Codable, Sendable {
    var name: String
    var accessBoundary: String
    var cacheState: String
    var sampleCount: Int
    var expectedFirstPageSegmentCount: Int
    var openLatency: BenchmarkLatencySummary
    var firstQueryLatency: BenchmarkLatencySummary
    var openAndFirstLatency: BenchmarkLatencySummary
    var minimumReturnedSegments: Int
    var maximumReturnedSegments: Int
    var firstPageHydration: BenchmarkFirstPageHydrationReport
    var retrievalAvailable: Bool
    var omissionReasons: [String]
}

struct BenchmarkCaptureProbeReport: Codable, Sendable {
    var appendedFrameCount: Int
    var expectedAppendedFrameIDCount: Int
    var retrievedAppendedFrameIDCount: Int
    var insertLatency: BenchmarkLatencySummary
    var lifecycleAfterAppend: String?
    var pendingSessionCountAfterAppend: Int?
    var dirtyOverlaySegmentCount: Int
    var dirtyOverlayFrameCount: Int
    var dirtyOverlayContainsEveryAppendedFrameID: Bool
    var dirtyOverlayRevision: String
    var retrievalAvailableAfterAppend: Bool
    var retrievalOmissionReasons: [String]
    var interferenceModel: String
}

struct BenchmarkMaintenanceReport: Codable, Sendable {
    var attemptCount: Int
    var maintainedSessionCount: Int
    var deferredSessionCount: Int
    var reachedNoWork: Bool
    var latency: BenchmarkLatencySummary
    var lifecycleAfterMaintenance: String?
    var pendingSessionCountAfterMaintenance: Int?
    var canonicalFrameCountAfterMaintenance: Int?
    var segmentCountAfterMaintenance: Int?
    var expectedSegmentCountAfterMaintenance: Int
    var postMaintenanceEqualsDirtyOverlay: Bool
    var postMaintenanceRevisionEqualsDirtyOverlay: Bool
    var retrievalAvailableAfterMaintenance: Bool
    var retrievalOmissionReasons: [String]
}

struct BenchmarkLatencySummary: Codable, Sendable {
    var minimumMilliseconds: Double
    var p50Milliseconds: Double
    var p95Milliseconds: Double
    var maximumMilliseconds: Double

    static let zero = Self(
        minimumMilliseconds: 0,
        p50Milliseconds: 0,
        p95Milliseconds: 0,
        maximumMilliseconds: 0
    )

    init(samples: [Double]) {
        guard !samples.isEmpty else {
            self = .zero
            return
        }
        let ordered = samples.sorted()
        minimumMilliseconds = ordered[0]
        p50Milliseconds = Self.percentile(ordered, 0.50)
        p95Milliseconds = Self.percentile(ordered, 0.95)
        maximumMilliseconds = ordered[ordered.count - 1]
    }

    private init(
        minimumMilliseconds: Double,
        p50Milliseconds: Double,
        p95Milliseconds: Double,
        maximumMilliseconds: Double
    ) {
        self.minimumMilliseconds = minimumMilliseconds
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }

    private static func percentile(_ ordered: [Double], _ percentile: Double) -> Double {
        let index = Int(floor(Double(ordered.count - 1) * percentile))
        return ordered[index]
    }
}

func elapsedMilliseconds(since started: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
}
