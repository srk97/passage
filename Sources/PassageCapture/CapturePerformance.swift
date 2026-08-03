import Dispatch
import Foundation

/// A monotonic timestamp used only for measuring elapsed capture work.
///
/// Wall-clock `Date` values remain useful evidence metadata, but they can jump when
/// the system clock changes. Capture durations therefore use uptime nanoseconds.
public struct CaptureMonotonicInstant: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func now() -> CaptureMonotonicInstant {
        CaptureMonotonicInstant(rawValue: DispatchTime.now().uptimeNanoseconds)
    }

    public static func < (lhs: CaptureMonotonicInstant, rhs: CaptureMonotonicInstant) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate func nanoseconds(through end: CaptureMonotonicInstant) throws -> UInt64 {
        guard end >= self else {
            throw CapturePerformanceError.nonMonotonicTimestamp(
                earlier: rawValue,
                later: end.rawValue
            )
        }
        return end.rawValue - rawValue
    }
}

/// Stable capture-pipeline stages. New cases require a snapshot schema revision.
public enum CapturePerformanceStage: String, Codable, CaseIterable, Hashable, Sendable {
    case initialContext = "initial_context"
    case snapshotDelivery = "snapshot_delivery"
    case validationContext = "validation_context"
    case fingerprint = "fingerprint"
    case ocr = "ocr"
    case mediaWrite = "media_write"
    case indexCommit = "index_commit"
    case retention = "retention"
    case captureToIndex = "capture_to_index"
    case firstMemoryVisible = "first_memory_visible"
}

/// A terminal result for one requested capture candidate.
///
/// An attempt begins only after cadence and initial privacy checks decide that a
/// snapshot should be requested. Private/host/inactive checks are counters rather
/// than attempts. Every begun attempt must receive exactly one terminal outcome.
public enum CaptureTerminalOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case persisted
    case unchanged
    case discardedContextTransition = "discarded_context_transition"
    case unavailable
    case failed
    case cancelled
}

/// Independent event counters that do not necessarily belong to one attempt.
public enum CapturePerformanceCounter: String, Codable, CaseIterable, Hashable, Sendable {
    case contextChecks = "context_checks"
    case skippedHostApplication = "skipped_host_application"
    case skippedPrivateContext = "skipped_private_context"
    case skippedForInactivity = "skipped_for_inactivity"
    case snapshotRequests = "snapshot_requests"
    case coalescedCaptureRequests = "coalesced_capture_requests"
    case staleScreenshotsRejected = "stale_screenshots_rejected"
    case eligibleCaptureOpportunities = "eligible_capture_opportunities"
    case droppedEligibleCaptures = "dropped_eligible_captures"
}

/// Opaque identity returned by `CapturePerformanceRecorder.beginAttempt`.
public struct CapturePerformanceAttempt: Codable, Hashable, Sendable {
    public let sequence: UInt64

    fileprivate init(sequence: UInt64) {
        self.sequence = sequence
    }
}

/// Describes one local evidence run without coupling the recorder to the filesystem.
public struct CapturePerformanceRunDescriptor: Codable, Equatable, Sendable {
    public var runID: String
    public var startedAt: Date
    public var attributes: [String: String]

    public init(
        runID: String = UUID().uuidString.lowercased(),
        startedAt: Date = .now,
        attributes: [String: String] = [:]
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.attributes = attributes
    }
}

/// Raw samples plus reproducible nearest-rank summaries.
///
/// Samples are sorted in snapshots so an evidence consumer can independently
/// recalculate every field. Percentiles use the nearest-rank definition:
/// `ceil(percentile * sampleCount)`, with a one-based rank.
public struct CaptureDurationDistribution: Codable, Equatable, Sendable {
    public let samplesNanoseconds: [UInt64]
    public let sampleCount: UInt64
    public let totalNanoseconds: UInt64
    public let minimumNanoseconds: UInt64?
    public let maximumNanoseconds: UInt64?
    public let p50Nanoseconds: UInt64?
    public let p95Nanoseconds: UInt64?
    public let p99Nanoseconds: UInt64?

    fileprivate init(samples: [UInt64]) throws {
        let sorted = samples.sorted()
        samplesNanoseconds = sorted
        sampleCount = UInt64(sorted.count)
        totalNanoseconds = try Self.exactTotal(sorted)
        minimumNanoseconds = sorted.first
        maximumNanoseconds = sorted.last
        p50Nanoseconds = Self.nearestRank(sorted, numerator: 50, denominator: 100)
        p95Nanoseconds = Self.nearestRank(sorted, numerator: 95, denominator: 100)
        p99Nanoseconds = Self.nearestRank(sorted, numerator: 99, denominator: 100)
    }

    fileprivate func validate() throws {
        let expected = try Self(samples: samplesNanoseconds)
        guard self == expected else {
            throw CapturePerformanceError.invalidSnapshot("A duration distribution is inconsistent with its raw samples.")
        }
    }

    private static func nearestRank(
        _ sorted: [UInt64],
        numerator: Int,
        denominator: Int
    ) -> UInt64? {
        guard !sorted.isEmpty else { return nil }
        // These fixed percentiles cannot overflow for any array Swift can allocate.
        let rank = ((sorted.count * numerator) + denominator - 1) / denominator
        return sorted[max(rank, 1) - 1]
    }

    private static func exactTotal(_ samples: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 0
        for sample in samples {
            let result = total.addingReportingOverflow(sample)
            guard !result.overflow else {
                throw CapturePerformanceError.durationOverflow
            }
            total = result.partialValue
        }
        return total
    }
}

public struct CaptureStagePerformanceSummary: Codable, Equatable, Sendable {
    public let stage: CapturePerformanceStage
    public let durations: CaptureDurationDistribution
    /// Stages left open when their attempt terminated. They never enter latency percentiles.
    public let abandonedSampleCount: UInt64

    public init(
        stage: CapturePerformanceStage,
        durations: CaptureDurationDistribution,
        abandonedSampleCount: UInt64
    ) {
        self.stage = stage
        self.durations = durations
        self.abandonedSampleCount = abandonedSampleCount
    }
}

public struct CaptureOutcomePerformanceSummary: Codable, Equatable, Sendable {
    public let outcome: CaptureTerminalOutcome
    public let count: UInt64
    public let attemptDurations: CaptureDurationDistribution

    public init(
        outcome: CaptureTerminalOutcome,
        count: UInt64,
        attemptDurations: CaptureDurationDistribution
    ) {
        self.outcome = outcome
        self.count = count
        self.attemptDurations = attemptDurations
    }
}

public struct CaptureCounterValue: Codable, Equatable, Sendable {
    public let counter: CapturePerformanceCounter
    public let value: UInt64

    public init(counter: CapturePerformanceCounter, value: UInt64) {
        self.counter = counter
        self.value = value
    }
}

/// Versioned, self-validating evidence emitted by an opt-in local trace run.
public struct CapturePerformanceSnapshot: Codable, Equatable, Sendable {
    public static let schema = "chronicle-capture-performance/v1"
    public static let schemaVersion = 1

    public let schema: String
    public let version: Int
    public let run: CapturePerformanceRunDescriptor
    public let generatedAt: Date
    public let elapsedNanoseconds: UInt64
    public let attemptsStarted: UInt64
    public let attemptsCompleted: UInt64
    public let activeAttemptCount: UInt64
    public let hasCompleteTerminalAccounting: Bool
    public let allAttemptDurations: CaptureDurationDistribution
    public let outcomes: [CaptureOutcomePerformanceSummary]
    public let stages: [CaptureStagePerformanceSummary]
    public let counters: [CaptureCounterValue]

    /// Rejects malformed or internally inconsistent evidence after decoding.
    public func validate() throws {
        guard schema == Self.schema, version == Self.schemaVersion else {
            throw CapturePerformanceError.unsupportedSnapshotSchema(schema: schema, version: version)
        }
        guard !run.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapturePerformanceError.invalidSnapshot("The run identifier is empty.")
        }
        let accounted = attemptsCompleted.addingReportingOverflow(activeAttemptCount)
        guard !accounted.overflow, accounted.partialValue == attemptsStarted else {
            throw CapturePerformanceError.invalidSnapshot("Started attempts do not equal completed plus active attempts.")
        }
        guard hasCompleteTerminalAccounting == (activeAttemptCount == 0) else {
            throw CapturePerformanceError.invalidSnapshot("The terminal-accounting flag is inconsistent.")
        }

        try allAttemptDurations.validate()
        guard allAttemptDurations.sampleCount == attemptsCompleted else {
            throw CapturePerformanceError.invalidSnapshot("Completed attempts do not match total duration samples.")
        }

        var seenOutcomes: Set<CaptureTerminalOutcome> = []
        var outcomeCount: UInt64 = 0
        var outcomeSamples: [UInt64] = []
        guard outcomes.map(\.outcome.rawValue) == outcomes.map(\.outcome.rawValue).sorted() else {
            throw CapturePerformanceError.invalidSnapshot("Terminal outcomes are not in canonical order.")
        }
        for summary in outcomes {
            guard seenOutcomes.insert(summary.outcome).inserted else {
                throw CapturePerformanceError.invalidSnapshot("A terminal outcome appears more than once.")
            }
            try summary.attemptDurations.validate()
            guard summary.count == summary.attemptDurations.sampleCount else {
                throw CapturePerformanceError.invalidSnapshot("A terminal count does not match its duration samples.")
            }
            let next = outcomeCount.addingReportingOverflow(summary.count)
            guard !next.overflow else { throw CapturePerformanceError.durationOverflow }
            outcomeCount = next.partialValue
            outcomeSamples.append(contentsOf: summary.attemptDurations.samplesNanoseconds)
        }
        guard outcomeCount == attemptsCompleted,
              outcomeSamples.sorted() == allAttemptDurations.samplesNanoseconds else {
            throw CapturePerformanceError.invalidSnapshot("Terminal outcomes do not account for every completed attempt exactly once.")
        }

        var seenStages: Set<CapturePerformanceStage> = []
        guard stages.map(\.stage.rawValue) == stages.map(\.stage.rawValue).sorted() else {
            throw CapturePerformanceError.invalidSnapshot("Capture stages are not in canonical order.")
        }
        for summary in stages {
            guard seenStages.insert(summary.stage).inserted else {
                throw CapturePerformanceError.invalidSnapshot("A capture stage appears more than once.")
            }
            try summary.durations.validate()
        }

        var seenCounters: Set<CapturePerformanceCounter> = []
        guard counters.map(\.counter.rawValue) == counters.map(\.counter.rawValue).sorted() else {
            throw CapturePerformanceError.invalidSnapshot("Capture counters are not in canonical order.")
        }
        for value in counters where !seenCounters.insert(value.counter).inserted {
            throw CapturePerformanceError.invalidSnapshot("A capture counter appears more than once.")
        }
    }

    /// Stable JSON for later hashing or signing by the external release harness.
    public func encodedJSON(prettyPrinted: Bool = false) throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        // A JSON number preserves Date's binary floating-point value on round-trip;
        // ISO-8601 formatters commonly discard sub-second evidence timestamps.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum CapturePerformanceError: Error, Equatable, LocalizedError, Sendable {
    case attemptSequenceExhausted
    case unknownAttempt(UInt64)
    case stageAlreadyStarted(stage: CapturePerformanceStage, attempt: UInt64)
    case stageAlreadyCompleted(stage: CapturePerformanceStage, attempt: UInt64)
    case stageNotStarted(stage: CapturePerformanceStage, attempt: UInt64)
    case nonMonotonicTimestamp(earlier: UInt64, later: UInt64)
    case counterOverflow(CapturePerformanceCounter)
    case durationOverflow
    case unsupportedSnapshotSchema(schema: String, version: Int)
    case invalidSnapshot(String)

    public var errorDescription: String? {
        switch self {
        case .attemptSequenceExhausted:
            "The capture performance attempt sequence is exhausted."
        case .unknownAttempt(let sequence):
            "Capture performance attempt \(sequence) is not active."
        case .stageAlreadyStarted(let stage, let attempt):
            "Stage \(stage.rawValue) already started for attempt \(attempt)."
        case .stageAlreadyCompleted(let stage, let attempt):
            "Stage \(stage.rawValue) already completed for attempt \(attempt)."
        case .stageNotStarted(let stage, let attempt):
            "Stage \(stage.rawValue) has not started for attempt \(attempt)."
        case .nonMonotonicTimestamp(let earlier, let later):
            "A monotonic timestamp moved backwards from \(earlier) to \(later)."
        case .counterOverflow(let counter):
            "Capture counter \(counter.rawValue) overflowed."
        case .durationOverflow:
            "Capture duration totals overflowed."
        case .unsupportedSnapshotSchema(let schema, let version):
            "Unsupported capture performance snapshot \(schema) version \(version)."
        case .invalidSnapshot(let message):
            "Invalid capture performance snapshot: \(message)"
        }
    }
}

/// Opt-in, in-memory capture measurement. It performs no network or filesystem I/O.
///
/// Callers inject monotonic instants, which makes the recorder deterministic in
/// tests and keeps production measurements immune to wall-clock changes.
public actor CapturePerformanceRecorder {
    private struct ActiveAttempt {
        let startedAt: CaptureMonotonicInstant
        var openStages: [CapturePerformanceStage: CaptureMonotonicInstant] = [:]
        var completedStages: Set<CapturePerformanceStage> = []
    }

    private let run: CapturePerformanceRunDescriptor
    private let startedAtMonotonic: CaptureMonotonicInstant
    private var nextAttemptSequence: UInt64 = 0
    private var attemptsStarted: UInt64 = 0
    private var attemptsCompleted: UInt64 = 0
    private var activeAttempts: [CapturePerformanceAttempt: ActiveAttempt] = [:]
    private var attemptDurations: [UInt64] = []
    private var outcomeDurations: [CaptureTerminalOutcome: [UInt64]] = [:]
    private var stageDurations: [CapturePerformanceStage: [UInt64]] = [:]
    private var abandonedStages: [CapturePerformanceStage: UInt64] = [:]
    private var counters: [CapturePerformanceCounter: UInt64] = [:]

    public init(
        run: CapturePerformanceRunDescriptor = CapturePerformanceRunDescriptor(),
        startedAtMonotonic: CaptureMonotonicInstant = .now()
    ) {
        self.run = run
        self.startedAtMonotonic = startedAtMonotonic
    }

    @discardableResult
    public func beginAttempt(
        at instant: CaptureMonotonicInstant = .now()
    ) throws -> CapturePerformanceAttempt {
        _ = try startedAtMonotonic.nanoseconds(through: instant)
        let incremented = nextAttemptSequence.addingReportingOverflow(1)
        guard !incremented.overflow else {
            throw CapturePerformanceError.attemptSequenceExhausted
        }
        nextAttemptSequence = incremented.partialValue
        let attempt = CapturePerformanceAttempt(sequence: nextAttemptSequence)
        activeAttempts[attempt] = ActiveAttempt(startedAt: instant)
        attemptsStarted += 1
        return attempt
    }

    public func beginStage(
        _ stage: CapturePerformanceStage,
        for attempt: CapturePerformanceAttempt,
        at instant: CaptureMonotonicInstant = .now()
    ) throws {
        guard var active = activeAttempts[attempt] else {
            throw CapturePerformanceError.unknownAttempt(attempt.sequence)
        }
        _ = try active.startedAt.nanoseconds(through: instant)
        guard active.openStages[stage] == nil else {
            throw CapturePerformanceError.stageAlreadyStarted(stage: stage, attempt: attempt.sequence)
        }
        guard !active.completedStages.contains(stage) else {
            throw CapturePerformanceError.stageAlreadyCompleted(stage: stage, attempt: attempt.sequence)
        }
        active.openStages[stage] = instant
        activeAttempts[attempt] = active
    }

    public func endStage(
        _ stage: CapturePerformanceStage,
        for attempt: CapturePerformanceAttempt,
        at instant: CaptureMonotonicInstant = .now()
    ) throws {
        guard var active = activeAttempts[attempt] else {
            throw CapturePerformanceError.unknownAttempt(attempt.sequence)
        }
        guard let startedAt = active.openStages[stage] else {
            if active.completedStages.contains(stage) {
                throw CapturePerformanceError.stageAlreadyCompleted(stage: stage, attempt: attempt.sequence)
            }
            throw CapturePerformanceError.stageNotStarted(stage: stage, attempt: attempt.sequence)
        }
        let duration = try startedAt.nanoseconds(through: instant)
        stageDurations[stage, default: []].append(duration)
        active.openStages.removeValue(forKey: stage)
        active.completedStages.insert(stage)
        activeAttempts[attempt] = active
    }

    /// Adds a completed duration that is not naturally scoped to an attempt,
    /// such as an independently observed first-memory presentation delay.
    public func record(
        stage: CapturePerformanceStage,
        from start: CaptureMonotonicInstant,
        through end: CaptureMonotonicInstant
    ) throws {
        stageDurations[stage, default: []].append(try start.nanoseconds(through: end))
    }

    public func increment(
        _ counter: CapturePerformanceCounter,
        by amount: UInt64 = 1
    ) throws {
        guard amount > 0 else { return }
        let updated = counters[counter, default: 0].addingReportingOverflow(amount)
        guard !updated.overflow else {
            throw CapturePerformanceError.counterOverflow(counter)
        }
        counters[counter] = updated.partialValue
    }

    public func finishAttempt(
        _ attempt: CapturePerformanceAttempt,
        outcome: CaptureTerminalOutcome,
        at instant: CaptureMonotonicInstant = .now()
    ) throws {
        guard let active = activeAttempts[attempt] else {
            throw CapturePerformanceError.unknownAttempt(attempt.sequence)
        }
        let duration = try active.startedAt.nanoseconds(through: instant)
        for startedAt in active.openStages.values {
            _ = try startedAt.nanoseconds(through: instant)
        }

        for stage in active.openStages.keys {
            let updated = abandonedStages[stage, default: 0].addingReportingOverflow(1)
            guard !updated.overflow else { throw CapturePerformanceError.durationOverflow }
            abandonedStages[stage] = updated.partialValue
        }
        attemptDurations.append(duration)
        outcomeDurations[outcome, default: []].append(duration)
        activeAttempts.removeValue(forKey: attempt)
        attemptsCompleted += 1
    }

    public func snapshot(
        at instant: CaptureMonotonicInstant = .now(),
        generatedAt: Date = .now
    ) throws -> CapturePerformanceSnapshot {
        let elapsed = try startedAtMonotonic.nanoseconds(through: instant)
        let allDurations = try CaptureDurationDistribution(samples: attemptDurations)
        let outcomes = try outcomeDurations.map { outcome, durations in
            CaptureOutcomePerformanceSummary(
                outcome: outcome,
                count: UInt64(durations.count),
                attemptDurations: try CaptureDurationDistribution(samples: durations)
            )
        }
        .sorted { $0.outcome.rawValue < $1.outcome.rawValue }

        let representedStages = Set(stageDurations.keys).union(abandonedStages.keys)
        let stages = try representedStages.map { stage in
            CaptureStagePerformanceSummary(
                stage: stage,
                durations: try CaptureDurationDistribution(samples: stageDurations[stage, default: []]),
                abandonedSampleCount: abandonedStages[stage, default: 0]
            )
        }
        .sorted { $0.stage.rawValue < $1.stage.rawValue }

        let counterValues = counters.map { counter, value in
            CaptureCounterValue(counter: counter, value: value)
        }
        .sorted { $0.counter.rawValue < $1.counter.rawValue }

        let activeCount = UInt64(activeAttempts.count)
        let snapshot = CapturePerformanceSnapshot(
            schema: CapturePerformanceSnapshot.schema,
            version: CapturePerformanceSnapshot.schemaVersion,
            run: run,
            generatedAt: generatedAt,
            elapsedNanoseconds: elapsed,
            attemptsStarted: attemptsStarted,
            attemptsCompleted: attemptsCompleted,
            activeAttemptCount: activeCount,
            hasCompleteTerminalAccounting: activeCount == 0,
            allAttemptDurations: allDurations,
            outcomes: outcomes,
            stages: stages,
            counters: counterValues
        )
        try snapshot.validate()
        return snapshot
    }
}
