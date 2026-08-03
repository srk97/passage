import PassageCapture
import Foundation
import Testing

@Suite("Capture performance evidence")
struct CapturePerformanceTests {
    private let origin = CaptureMonotonicInstant(rawValue: 1_000)
    private let generatedAt = Date(timeIntervalSince1970: 1_700_000_100)

    @Test("Terminal outcomes account for every attempt exactly once")
    func terminalAccounting() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        let persisted = try await recorder.beginAttempt(at: instant(1_100))
        let unchanged = try await recorder.beginAttempt(at: instant(1_200))
        let active = try await recorder.beginAttempt(at: instant(1_300))

        try await recorder.finishAttempt(persisted, outcome: .persisted, at: instant(1_500))
        try await recorder.finishAttempt(unchanged, outcome: .unchanged, at: instant(1_800))

        var snapshot = try await recorder.snapshot(at: instant(2_000), generatedAt: generatedAt)
        #expect(snapshot.attemptsStarted == 3)
        #expect(snapshot.attemptsCompleted == 2)
        #expect(snapshot.activeAttemptCount == 1)
        #expect(!snapshot.hasCompleteTerminalAccounting)
        #expect(snapshot.outcomes.map(\.outcome) == [.persisted, .unchanged])
        #expect(snapshot.outcomes.map(\.count) == [1, 1])

        await #expect(throws: CapturePerformanceError.self) {
            try await recorder.finishAttempt(persisted, outcome: .failed, at: instant(2_100))
        }

        try await recorder.finishAttempt(active, outcome: .cancelled, at: instant(2_200))
        snapshot = try await recorder.snapshot(at: instant(2_300), generatedAt: generatedAt)
        #expect(snapshot.attemptsStarted == 3)
        #expect(snapshot.attemptsCompleted == 3)
        #expect(snapshot.activeAttemptCount == 0)
        #expect(snapshot.hasCompleteTerminalAccounting)
        #expect(snapshot.allAttemptDurations.samplesNanoseconds == [400, 600, 900])
        try snapshot.validate()
    }

    @Test("Nearest-rank percentiles are exact and raw samples are sorted")
    func exactPercentiles() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        for duration in (1...20).reversed() {
            let attempt = try await recorder.beginAttempt(at: instant(2_000))
            try await recorder.beginStage(.ocr, for: attempt, at: instant(2_100))
            try await recorder.endStage(
                .ocr,
                for: attempt,
                at: instant(2_100 + UInt64(duration))
            )
            try await recorder.finishAttempt(
                attempt,
                outcome: .persisted,
                at: instant(2_200 + UInt64(duration))
            )
        }

        let snapshot = try await recorder.snapshot(at: instant(3_000), generatedAt: generatedAt)
        let ocr = try #require(snapshot.stages.first { $0.stage == .ocr })
        #expect(ocr.durations.samplesNanoseconds == Array(1...20).map(UInt64.init))
        #expect(ocr.durations.sampleCount == 20)
        #expect(ocr.durations.totalNanoseconds == 210)
        #expect(ocr.durations.minimumNanoseconds == 1)
        #expect(ocr.durations.maximumNanoseconds == 20)
        #expect(ocr.durations.p50Nanoseconds == 10)
        #expect(ocr.durations.p95Nanoseconds == 19)
        #expect(ocr.durations.p99Nanoseconds == 20)
    }

    @Test("Completed and abandoned stages remain distinct")
    func abandonedStages() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        let completed = try await recorder.beginAttempt(at: instant(1_100))
        try await recorder.beginStage(.mediaWrite, for: completed, at: instant(1_200))
        try await recorder.endStage(.mediaWrite, for: completed, at: instant(1_500))
        try await recorder.finishAttempt(completed, outcome: .persisted, at: instant(1_600))

        let failed = try await recorder.beginAttempt(at: instant(1_700))
        try await recorder.beginStage(.mediaWrite, for: failed, at: instant(1_800))
        try await recorder.finishAttempt(failed, outcome: .failed, at: instant(1_900))

        let snapshot = try await recorder.snapshot(at: instant(2_000), generatedAt: generatedAt)
        let media = try #require(snapshot.stages.first { $0.stage == .mediaWrite })
        #expect(media.durations.samplesNanoseconds == [300])
        #expect(media.abandonedSampleCount == 1)
        #expect(snapshot.outcomes.first { $0.outcome == .failed }?.count == 1)
    }

    @Test("Independent stage samples and counters are deterministic")
    func independentSamplesAndCounters() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        try await recorder.record(
            stage: .snapshotDelivery,
            from: instant(1_100),
            through: instant(1_145)
        )
        try await recorder.increment(.snapshotRequests, by: 7)
        try await recorder.increment(.snapshotRequests, by: 2)
        try await recorder.increment(.contextChecks)

        let snapshot = try await recorder.snapshot(at: instant(1_500), generatedAt: generatedAt)
        #expect(snapshot.attemptsStarted == 0)
        #expect(snapshot.hasCompleteTerminalAccounting)
        #expect(snapshot.stages.first?.stage == .snapshotDelivery)
        #expect(snapshot.stages.first?.durations.samplesNanoseconds == [45])
        #expect(snapshot.counters == [
            CaptureCounterValue(counter: .contextChecks, value: 1),
            CaptureCounterValue(counter: .snapshotRequests, value: 9),
        ])
    }

    @Test("Monotonic and stage lifecycle errors fail closed without corrupting evidence")
    func invalidLifecycle() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        await #expect(throws: CapturePerformanceError.self) {
            try await recorder.beginAttempt(at: instant(999))
        }

        let attempt = try await recorder.beginAttempt(at: instant(1_100))
        try await recorder.beginStage(.fingerprint, for: attempt, at: instant(1_200))
        await #expect(throws: CapturePerformanceError.self) {
            try await recorder.beginStage(.fingerprint, for: attempt, at: instant(1_250))
        }
        await #expect(throws: CapturePerformanceError.self) {
            try await recorder.endStage(.fingerprint, for: attempt, at: instant(1_199))
        }
        try await recorder.endStage(.fingerprint, for: attempt, at: instant(1_300))
        await #expect(throws: CapturePerformanceError.self) {
            try await recorder.endStage(.fingerprint, for: attempt, at: instant(1_400))
        }
        try await recorder.finishAttempt(attempt, outcome: .persisted, at: instant(1_500))

        let snapshot = try await recorder.snapshot(at: instant(1_600), generatedAt: generatedAt)
        #expect(snapshot.attemptsStarted == 1)
        #expect(snapshot.attemptsCompleted == 1)
        #expect(snapshot.stages.first?.durations.samplesNanoseconds == [100])
    }

    @Test("Versioned JSON round-trips and validates deterministically")
    func jsonEvidence() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        let attempt = try await recorder.beginAttempt(at: instant(1_100))
        try await recorder.finishAttempt(attempt, outcome: .persisted, at: instant(1_600))
        try await recorder.increment(.snapshotRequests)
        let snapshot = try await recorder.snapshot(at: instant(2_000), generatedAt: generatedAt)

        let first = try snapshot.encodedJSON()
        let second = try snapshot.encodedJSON()
        #expect(first == second)
        let decoded = try JSONDecoder.performanceEvidence.decode(CapturePerformanceSnapshot.self, from: first)
        #expect(decoded == snapshot)
        #expect(decoded.schema == "chronicle-capture-performance/v1")
        #expect(decoded.version == 1)
        try decoded.validate()
    }

    @Test("Decoded evidence rejects inconsistent terminal accounting")
    func tamperedEvidence() async throws {
        let recorder = CapturePerformanceRecorder(
            run: Self.run,
            startedAtMonotonic: origin
        )
        let attempt = try await recorder.beginAttempt(at: instant(1_100))
        try await recorder.finishAttempt(attempt, outcome: .persisted, at: instant(1_600))
        let snapshot = try await recorder.snapshot(at: instant(2_000), generatedAt: generatedAt)
        let encoded = try snapshot.encodedJSON()
        let original = try #require(String(data: encoded, encoding: .utf8))
        let tampered = original.replacingOccurrences(
            of: "\"attemptsCompleted\":1",
            with: "\"attemptsCompleted\":2"
        )
        #expect(tampered != original)
        let decoded = try JSONDecoder.performanceEvidence.decode(
            CapturePerformanceSnapshot.self,
            from: Data(tampered.utf8)
        )
        #expect(throws: CapturePerformanceError.self) {
            try decoded.validate()
        }
    }

    private static let run = CapturePerformanceRunDescriptor(
        runID: "trace-fixture",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        attributes: [
            "app_build": "6",
            "trace_sha256": "fixture-digest",
        ]
    )

    private func instant(_ value: UInt64) -> CaptureMonotonicInstant {
        CaptureMonotonicInstant(rawValue: value)
    }
}

private extension JSONDecoder {
    static var performanceEvidence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
