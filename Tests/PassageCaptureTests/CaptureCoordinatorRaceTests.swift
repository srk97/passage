@testable import PassageCapture
import PassageCore
import PassageStore
import CoreGraphics
import Foundation
import Testing

@Suite("Capture coordinator race boundaries", .serialized)
struct CaptureCoordinatorRaceTests {
    @Test("Pause drains a late screenshot without persistence")
    func pauseRejectsLateScreenshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.coordinator.start()
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })

        let pause = Task { await fixture.coordinator.pause() }
        #expect(await waitUntil { await fixture.snapshots.invalidationCount == 1 })

        await fixture.snapshots.releaseNext(image: Self.image())
        await pause.value

        #expect(await fixture.repository.insertCount == 0)
        #expect(await fixture.snapshots.requestCount == 1)
    }

    @Test("A replacement Capture Now waits for the cancelled request to drain")
    func replacementCaptureIsNotLost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let first = Task { try await fixture.coordinator.captureNow() }
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })

        first.cancel()
        let replacement = Task { try await fixture.coordinator.captureNow() }
        await fixture.snapshots.releaseNext(image: Self.image())
        _ = try? await first.value

        #expect(await waitUntil { await fixture.snapshots.requestCount == 2 })
        // Make the post-delivery context check discard the replacement before
        // OCR or storage. The assertion here is serialization, not persistence.
        await fixture.contexts.setWindowID(99)
        await fixture.snapshots.releaseNext(image: Self.image())
        let replacementResult = try await replacement.value

        #expect(replacementResult == nil)
        #expect(await fixture.snapshots.requestCount == 2)
        #expect(await fixture.repository.insertCount == 0)
    }

    @Test("Insert failure preserves shared media and removes new media")
    func insertFailureRollsBackOnlyCreatedMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sharedImage = Self.image()
        let seed = try await fixture.media.write(
            image: sharedImage,
            id: FrameID(rawValue: "committed-seed"),
            capturedAt: .now
        )
        let baselineFiles = Self.assetFiles(in: fixture.root)
        await fixture.repository.setInsertBehavior(.fail)

        let sharedAttempt = Task { try await fixture.coordinator.captureNow() }
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })
        await fixture.snapshots.releaseNext(image: sharedImage)
        await #expect(throws: RepositoryInsertError.self) {
            _ = try await sharedAttempt.value
        }
        #expect(Self.assetFiles(in: fixture.root) == baselineFiles)
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(seed.imagePath).path
        ))

        let newAttempt = Task { try await fixture.coordinator.captureNow() }
        #expect(await waitUntil { await fixture.snapshots.requestCount == 2 })
        await fixture.snapshots.releaseNext(image: Self.image(changingOnePixel: true))
        await #expect(throws: RepositoryInsertError.self) {
            _ = try await newAttempt.value
        }
        #expect(Self.assetFiles(in: fixture.root) == baselineFiles)
    }

    @Test("A failed insert does not suppress an identical automatic retry")
    func failedInsertRetriesSameFrame() async throws {
        let fixture = try Fixture(policy: CapturePolicy(
            activeInterval: .milliseconds(250),
            unchangedHeartbeat: .seconds(30)
        ))
        defer { fixture.cleanUp() }
        await fixture.repository.setInsertBehavior(.fail)

        await fixture.coordinator.start()
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })
        let image = Self.image()
        await fixture.snapshots.releaseNext(image: image)
        #expect(await waitUntil { await fixture.repository.insertCount == 1 })

        await fixture.repository.setInsertBehavior(.succeed)
        #expect(await waitUntil { await fixture.snapshots.requestCount == 2 })
        await fixture.snapshots.releaseNext(image: image)
        #expect(await waitUntil { await fixture.repository.insertCount == 2 })
        await fixture.coordinator.pause()
    }

    @Test("Cancellation during insert removes only the new orphan")
    func insertCancellationRollsBackOnlyCreatedMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try await fixture.media.write(
            image: Self.image(),
            id: FrameID(rawValue: "committed-seed"),
            capturedAt: .now
        )
        let baselineFiles = Self.assetFiles(in: fixture.root)
        await fixture.repository.setInsertBehavior(.waitForCancellation)

        let attempt = Task { try await fixture.coordinator.captureNow() }
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })
        await fixture.snapshots.releaseNext(image: Self.image(changingOnePixel: true))
        #expect(await waitUntil { await fixture.repository.insertCount == 1 })
        attempt.cancel()
        await fixture.repository.releasePendingInsert()

        await #expect(throws: CancellationError.self) {
            _ = try await attempt.value
        }
        #expect(Self.assetFiles(in: fixture.root) == baselineFiles)
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(seed.imagePath).path
        ))
    }

    @Test("Selected durable moments carry provider Accessibility evidence")
    func durableMomentCarriesAccessibilityEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let evidence = Self.accessibilitySnapshot()
        await fixture.contexts.setAccessibilitySnapshot(evidence)

        let attempt = Task { try await fixture.coordinator.captureNow() }
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })
        await fixture.snapshots.releaseNext(image: Self.image())
        let frame = try #require(await attempt.value)

        #expect(frame.accessibilitySnapshot == evidence)
        #expect(await fixture.repository.lastFrame?.accessibilitySnapshot == evidence)
        #expect(await fixture.contexts.accessibilityRequestCount == 1)
    }

    @Test("A context transition during Accessibility collection prevents insertion")
    func accessibilityContextTransitionFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.contexts.setAccessibilitySnapshot(
            Self.accessibilitySnapshot(),
            transitioningToWindowID: 99
        )

        let attempt = Task { try await fixture.coordinator.captureNow() }
        #expect(await waitUntil { await fixture.snapshots.requestCount == 1 })
        await fixture.snapshots.releaseNext(image: Self.image())

        #expect(try await attempt.value == nil)
        #expect(await fixture.repository.insertCount == 0)
        #expect(await fixture.contexts.accessibilityRequestCount == 1)
    }

    private static func image(changingOnePixel: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        if changingOnePixel {
            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return context.makeImage()!
    }

    private static func accessibilitySnapshot() -> AccessibilitySnapshot {
        AccessibilitySnapshot(
            nodes: [
                AccessibilityNodeEvidence(
                    role: "AXButton",
                    label: "Save draft",
                    depth: 1,
                    bounds: ScreenRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
                ),
            ],
            visitedNodeCount: 3,
            isTruncated: false,
            encodedByteCount: 180
        )
    }

    private static func assetFiles(in root: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return Set(enumerator.compactMap { element -> String? in
            guard let url = element as? URL, url.pathExtension == "bin" else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        })
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
        let snapshots = SuspendedSnapshotProvider()
        let contexts = MutableContextProvider()
        let repository = RecordingFrameRepository()
        let media: MediaStore
        let coordinator: CaptureCoordinator

        init(policy: CapturePolicy = CapturePolicy()) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PassageCaptureRaceTests-\(UUID().uuidString)")
            let paths = PassagePaths(root: root)
            try paths.createDirectories()
            let key = try VaultKey.testing(bytes: Data(repeating: 0x5A, count: VaultKey.byteCount))
            media = MediaStore(paths: paths, vaultKey: key)
            coordinator = CaptureCoordinator(
                snapshots: snapshots,
                contexts: contexts,
                ocrRecognition: { _, _ in OCRResult(text: "", regions: []) },
                media: media,
                repository: repository,
                policy: policy,
                hostBundleIdentifier: "app.passage.tests",
                // The production signal provider intentionally delays capture
                // when the Mac is idle or thermally constrained. This race
                // fixture is testing drain semantics, so host state must not
                // decide whether its first suspended screenshot starts.
                systemSignals: { .normal }
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct RepositoryInsertError: Error {}

private enum RecordingInsertBehavior: Sendable {
    case succeed
    case fail
    case waitForCancellation
}

private actor SuspendedSnapshotProvider: ScreenSnapshotProviding {
    private var waiters: [CheckedContinuation<ScreenSnapshot, Error>] = []
    private(set) var requestCount = 0
    private(set) var invalidationCount = 0

    func snapshot(
        hideCursor: Bool,
        preferredDisplayID: CGDirectDisplayID?,
        preferredWindowID: CGWindowID?,
        excludedBundleIdentifiers: Set<String>
    ) async throws -> ScreenSnapshot {
        _ = (hideCursor, preferredDisplayID, preferredWindowID, excludedBundleIdentifiers)
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func invalidatePendingCaptures() {
        invalidationCount += 1
    }

    func releaseNext(image: CGImage) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: ScreenSnapshot(
            image: image,
            capturedAt: .now,
            displayID: 1
        ))
    }
}

private actor MutableContextProvider: ActiveContextProviding {
    private var context = ScreenContext(
        applicationName: "TextEdit",
        bundleIdentifier: "com.apple.TextEdit",
        windowTitle: "Notes",
        displayID: 1,
        windowID: 7
    )
    private var evidence: AccessibilitySnapshot?
    private var transitionWindowIDDuringEvidence: UInt32?
    private(set) var accessibilityRequestCount = 0

    func current() -> ScreenContext {
        context
    }

    func setWindowID(_ windowID: UInt32) {
        context.windowID = windowID
    }

    func setAccessibilitySnapshot(
        _ snapshot: AccessibilitySnapshot?,
        transitioningToWindowID: UInt32? = nil
    ) {
        evidence = snapshot
        transitionWindowIDDuringEvidence = transitioningToWindowID
    }

    func accessibilitySnapshot(for context: ScreenContext) -> AccessibilitySnapshot? {
        _ = context
        accessibilityRequestCount += 1
        if let transitionWindowIDDuringEvidence {
            self.context.windowID = transitionWindowIDDuringEvidence
        }
        return evidence
    }
}

private actor RecordingFrameRepository: FrameRepository {
    private(set) var insertCount = 0
    private(set) var lastFrame: FrameDocument?
    private var insertBehavior = RecordingInsertBehavior.succeed
    private var pendingInsert: CheckedContinuation<Void, Never>?

    func setInsertBehavior(_ behavior: RecordingInsertBehavior) {
        insertBehavior = behavior
    }

    func releasePendingInsert() {
        pendingInsert?.resume()
        pendingInsert = nil
    }

    func insert(_ frame: FrameDocument) async throws {
        insertCount += 1
        lastFrame = frame
        switch insertBehavior {
        case .succeed:
            return
        case .fail:
            throw RepositoryInsertError()
        case .waitForCancellation:
            await withCheckedContinuation { continuation in
                pendingInsert = continuation
            }
            try Task.checkCancellation()
        }
    }

    func search(_ query: SearchQuery) -> [SearchHit] { [] }
    func recent(limit: Int) -> [SearchHit] { [] }
    func frame(id: FrameID) -> FrameDocument? { nil }
    func deleteFrames(olderThan date: Date) -> [String] { [] }
    func deleteFrames(from startDate: Date?, through endDate: Date?) -> [String] { [] }
    func deleteOldestFrames(limit: Int) -> [String] { [] }
    func expireOldestMedia(limit: Int) -> [String] { [] }
    func statistics() -> StoreStatistics {
        StoreStatistics(
            frameCount: insertCount,
            oldestCapture: nil,
            newestCapture: nil,
            databaseBytes: 0,
            mediaBytes: 0
        )
    }
}
