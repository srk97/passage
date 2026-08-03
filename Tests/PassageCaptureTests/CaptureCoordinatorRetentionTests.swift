@testable import PassageCapture
import PassageCore
import PassageStore
import CoreGraphics
import Foundation
import Testing

@Suite("Capture coordinator retention events", .serialized)
struct CaptureCoordinatorRetentionTests {
    @Test("A no-op retention sweep emits no commit")
    func noEventForNoOpSweep() async throws {
        let fixture = try Fixture(retentionChange: .none)
        defer { fixture.cleanUp() }

        _ = try await fixture.capture()

        #expect(fixture.events.snapshot().filter { $0 == .persisted }.count == 1)
        #expect(fixture.events.snapshot().filter { $0 == .retentionCommitted }.isEmpty)
    }

    @Test("A retention change emits exactly one commit")
    func oneEventForChangedSweep() async throws {
        let fixture = try Fixture(retentionChange: .expiresMedia)
        defer { fixture.cleanUp() }

        _ = try await fixture.capture()

        #expect(fixture.events.snapshot().filter { $0 == .retentionCommitted }.count == 1)
    }

    @Test("The durable capture is announced before its retention commit")
    func persistencePrecedesRetentionCommit() async throws {
        let fixture = try Fixture(retentionChange: .deletesTextOnlyFrame)
        defer { fixture.cleanUp() }

        _ = try await fixture.capture()

        #expect(fixture.events.snapshot() == [.persisted, .retentionCommitted])
    }

    @Test("Retention waits for pre-invalidation and always closes the boundary")
    func awaitedRetentionBoundaryPrecedesMutation() async throws {
        let fixture = try Fixture(retentionChange: .expiresMedia)
        let gate = RetentionBoundaryGate()
        defer { fixture.cleanUp() }
        await fixture.coordinator.setRetentionMutationHandler { boundary in
            await gate.handle(boundary)
        }

        let capture = Task { try await fixture.capture() }
        #expect(await waitUntil { await gate.hasEntered })
        #expect(await fixture.repository.retentionAttemptCount == 0)

        await gate.release()
        _ = try await capture.value

        #expect(await fixture.repository.retentionAttemptCount > 0)
        #expect(await gate.snapshot() == [
            .willMutate,
            .finished(commitEventFollows: true),
        ])
    }

    @Test("No-op retention never opens the mutation boundary")
    func noBoundaryForNoOpSweep() async throws {
        let fixture = try Fixture(retentionChange: .none)
        let recorder = RetentionBoundaryRecorder()
        defer { fixture.cleanUp() }
        await fixture.coordinator.setRetentionMutationHandler { boundary in
            await recorder.record(boundary)
        }

        _ = try await fixture.capture()

        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("A failed retention sweep still closes the mutation boundary")
    func failedSweepClosesBoundary() async throws {
        let fixture = try Fixture(retentionChange: .failsAgeSweep)
        let recorder = RetentionBoundaryRecorder()
        defer { fixture.cleanUp() }
        await fixture.coordinator.setRetentionMutationHandler { boundary in
            await recorder.record(boundary)
        }

        await #expect(throws: RetentionSweepTestError.self) {
            _ = try await fixture.capture()
        }
        #expect(await recorder.snapshot() == [
            .willMutate,
            .finished(commitEventFollows: false),
        ])
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let events = RetentionEventRecorder()
        let repository: RetentionFrameRepository
        let coordinator: CaptureCoordinator

        init(retentionChange: RetentionChange) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PassageCaptureRetentionTests-\(UUID().uuidString)")
            let paths = PassagePaths(root: root)
            try paths.createDirectories()
            let key = try VaultKey.testing(
                bytes: Data(repeating: 0xA7, count: VaultKey.byteCount)
            )
            let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
            repository = RetentionFrameRepository(change: retentionChange)
            coordinator = CaptureCoordinator(
                snapshots: FixedSnapshotProvider(
                    snapshot: ScreenSnapshot(
                        image: Self.image(),
                        capturedAt: capturedAt,
                        displayID: 1
                    )
                ),
                contexts: FixedContextProvider(),
                ocrRecognition: { _, _ in OCRResult(text: "", regions: []) },
                media: MediaStore(paths: paths, vaultKey: key),
                repository: repository,
                retentionPolicy: RetentionPolicy(
                    maximumAgeDays: 1,
                    maximumMediaBytes: 512 * 1_024 * 1_024
                ),
                hostBundleIdentifier: "app.passage.tests"
            )
        }

        func capture() async throws -> FrameDocument? {
            let events = events
            await coordinator.setEventHandler { event in
                events.record(event)
            }
            return try await coordinator.captureNow()
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func image() -> CGImage {
            let context = CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(gray: 0.92, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return context.makeImage()!
        }
    }
}

private enum RetentionChange: Sendable, Equatable {
    case none
    case deletesTextOnlyFrame
    case expiresMedia
    case failsAgeSweep
}

private struct RetentionSweepTestError: Error {}

private actor RetentionBoundaryRecorder {
    private var boundaries: [RetentionMutationBoundary] = []

    func record(_ boundary: RetentionMutationBoundary) {
        boundaries.append(boundary)
    }

    func snapshot() -> [RetentionMutationBoundary] {
        boundaries
    }
}

private actor RetentionBoundaryGate {
    private var boundaries: [RetentionMutationBoundary] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var hasEntered = false

    func handle(_ boundary: RetentionMutationBoundary) async {
        boundaries.append(boundary)
        guard boundary == .willMutate else { return }
        hasEntered = true
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    func snapshot() -> [RetentionMutationBoundary] {
        boundaries
    }
}

private enum RecordedRetentionEvent: Equatable {
    case persisted
    case retentionCommitted
}

private final class RetentionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RecordedRetentionEvent] = []

    func record(_ event: CaptureEvent) {
        let recorded: RecordedRetentionEvent?
        switch event {
        case .persisted:
            recorded = .persisted
        case .retentionCommitted:
            recorded = .retentionCommitted
        default:
            recorded = nil
        }
        guard let recorded else { return }
        lock.withLock {
            events.append(recorded)
        }
    }

    func snapshot() -> [RecordedRetentionEvent] {
        lock.withLock { events }
    }
}

private actor FixedSnapshotProvider: ScreenSnapshotProviding {
    let snapshotValue: ScreenSnapshot

    init(snapshot: ScreenSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(
        hideCursor: Bool,
        preferredDisplayID: CGDirectDisplayID?,
        preferredWindowID: CGWindowID?,
        excludedBundleIdentifiers: Set<String>
    ) -> ScreenSnapshot {
        _ = (hideCursor, preferredDisplayID, preferredWindowID, excludedBundleIdentifiers)
        return snapshotValue
    }

    func invalidatePendingCaptures() {}
}

private actor FixedContextProvider: ActiveContextProviding {
    func current() -> ScreenContext {
        ScreenContext(
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            windowTitle: "Notes",
            displayID: 1,
            windowID: 7
        )
    }
}

private actor RetentionFrameRepository: FrameRepository {
    private let change: RetentionChange
    private var didRunAgeSweep = false
    private var didRunMediaSweep = false
    private var retentionAttempts = 0
    private var frameCount: Int
    private var mediaBytes: Int64
    private var oldestCapture: Date?

    init(change: RetentionChange) {
        self.change = change
        frameCount = change == .deletesTextOnlyFrame || change == .failsAgeSweep ? 1 : 0
        mediaBytes = change == .expiresMedia ? 513 * 1_024 * 1_024 : 0
        oldestCapture = change == .deletesTextOnlyFrame || change == .failsAgeSweep
            ? .distantPast
            : nil
    }

    func insert(_ frame: FrameDocument) {
        frameCount += 1
        if oldestCapture == nil || frame.capturedAt < oldestCapture! {
            oldestCapture = frame.capturedAt
        }
    }

    func search(_ query: SearchQuery) -> [SearchHit] { [] }
    func recent(limit: Int) -> [SearchHit] { [] }
    func frame(id: FrameID) -> FrameDocument? { nil }

    func deleteFrames(olderThan date: Date) throws -> [String] {
        _ = date
        retentionAttempts += 1
        if change == .failsAgeSweep { throw RetentionSweepTestError() }
        guard change == .deletesTextOnlyFrame, !didRunAgeSweep else { return [] }
        didRunAgeSweep = true
        frameCount -= 1
        oldestCapture = nil
        // A frame can outlive its screenshot under text-preserving retention.
        // Returning no path proves the commit signal follows the durable row
        // count, rather than treating filesystem paths as deletion receipts.
        return []
    }

    func deleteFrames(from startDate: Date?, through endDate: Date?) -> [String] { [] }
    func deleteOldestFrames(limit: Int) -> [String] { [] }
    func expireOldestMedia(limit: Int) -> [String] {
        _ = limit
        retentionAttempts += 1
        guard change == .expiresMedia, !didRunMediaSweep else { return [] }
        didRunMediaSweep = true
        mediaBytes = 0
        return ["Media/expired.bin"]
    }

    func statistics() -> StoreStatistics {
        StoreStatistics(
            frameCount: frameCount,
            oldestCapture: oldestCapture,
            newestCapture: nil,
            databaseBytes: 0,
            mediaBytes: mediaBytes
        )
    }

    var retentionAttemptCount: Int { retentionAttempts }
}
