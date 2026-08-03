import PassageCore
import Foundation
import Testing
@testable import PassageUI

@Suite("Previewable context handoff")
struct ContextHandoffTests {
    @Test("Preview payload cannot represent media, geometry, full URLs, or window titles")
    func projectionIsGeometryAndMediaFree() throws {
        let prepared = try preparedHandoff(
            ocrText: "Planning notes stay exact."
        )
        let json = prepared.canonicalJSON
        let markdown = prepared.markdown
        let combined = json + markdown

        for forbidden in [
            "MEDIA_PATH_SENTINEL",
            "THUMBNAIL_PATH_SENTINEL",
            "WINDOW_TITLE_SENTINEL",
            "normalizedBounds",
            "windowBounds",
            "displayID",
            "windowID",
            "pixelWidth",
            "pixelHeight",
            "person:password",
            "/private/path",
            "token=secret",
            "#state",
        ] {
            #expect(!combined.contains(forbidden))
        }

        #expect(json.contains("Planning notes stay exact."))
        #expect(json.contains("Open planning board"))
        #expect(json.contains("https://example.com"))
        #expect(prepared.payload.screenshotsIncluded == false)
        #expect(prepared.payload.mediaPathsIncluded == false)
        #expect(prepared.payload.pixelGeometryIncluded == false)
        #expect(prepared.payload.embeddingVectorsIncluded == false)
        #expect(prepared.payload.canonicalUTF8Bytes == json.utf8.count)
        #expect(try prepared.payload.canonicalJSONData().count == json.utf8.count)
    }

    @Test("Canonical JSON and Markdown stay deterministic and fence adversarial text")
    func deterministicArtifactsAndSafeMarkdownFences() throws {
        let ocr = "before\n```\n# still evidence\nafter"
        let first = try preparedHandoff(ocrText: ocr)
        let second = try preparedHandoff(ocrText: ocr)

        #expect(first == second)
        #expect(first.markdown.contains("````text\n\(ocr)\n````"))
        #expect(first.markdown.utf8.count == first.utf8ByteCount(for: .markdown))
        #expect(first.canonicalJSON.utf8.count == first.utf8ByteCount(for: .json))
    }

    @Test("A current source revalidates and changed text invalidates it")
    func sourceFreshnessCheck() throws {
        let prepared = try preparedHandoff(ocrText: "Current planning notes")
        let source = try #require(prepared.payload.sources.first)
        let current = AgentSafeFrameEvidence(
            frame: frame(ocrText: "Current planning notes"),
            activitySessionID: ActivitySessionID(rawValue: "session-safe")
        )
        let changed = AgentSafeFrameEvidence(
            frame: frame(ocrText: "Changed after preview"),
            activitySessionID: ActivitySessionID(rawValue: "session-safe")
        )

        #expect(source.matches(current))
        #expect(!source.matches(changed))
    }

    @MainActor
    @Test("Receipt commits before the clipboard is touched")
    func receiptPrecedesClipboard() async throws {
        let trace = SynchronousReleaseTrace()
        let receipts = SuspendingAccessEventStore(trace: trace)
        let clipboard = RecordingContextHandoffClipboard(trace: trace)
        let event = AccessEvent(
            client: "You [Passage]",
            command: "copyContext",
            capability: "memory.manualHandoff",
            returnedFrameIDs: [FrameID(rawValue: "source")],
            outcome: .success
        )

        let release = Task { @MainActor in
            try await ContextHandoffReleaseCoordinator.release(
                artifact: "exact artifact",
                event: event,
                receiptStore: receipts,
                clipboard: clipboard,
                canRelease: { true }
            )
        }
        while !trace.contains("receiptStarted") { await Task.yield() }
        #expect(clipboard.writes.isEmpty)
        await receipts.commit()
        #expect(try await release.value)
        #expect(trace.snapshot() == [
            "receiptStarted",
            "receiptCommitted",
            "clipboardWrite",
        ])
        #expect(clipboard.writes == ["exact artifact"])
    }

    @MainActor
    @Test("Receipt failure or lifecycle invalidation releases nothing")
    func failureAndInvalidationFailClosed() async throws {
        let failingClipboard = RecordingContextHandoffClipboard(
            trace: SynchronousReleaseTrace()
        )
        let event = AccessEvent(
            client: "You [Passage]",
            command: "copyContext",
            capability: "memory.manualHandoff",
            outcome: .success
        )

        await #expect(throws: ReleaseTestError.failed) {
            try await ContextHandoffReleaseCoordinator.release(
                artifact: "must not copy",
                event: event,
                receiptStore: FailingAccessEventStore(),
                clipboard: failingClipboard,
                canRelease: { true }
            )
        }
        #expect(failingClipboard.writes.isEmpty)

        let committedStore = ImmediateAccessEventStore()
        let invalidatedClipboard = RecordingContextHandoffClipboard(
            trace: SynchronousReleaseTrace()
        )
        let released = try await ContextHandoffReleaseCoordinator.release(
            artifact: "also withheld",
            event: event,
            receiptStore: committedStore,
            clipboard: invalidatedClipboard,
            canRelease: { false }
        )
        #expect(!released)
        #expect(invalidatedClipboard.writes.isEmpty)
    }

    private func preparedHandoff(ocrText: String) throws -> PreparedContextHandoff {
        let hit = SearchHit(
            id: FrameID(rawValue: "handoff-source"),
            activitySessionID: ActivitySessionID(rawValue: "session-safe"),
            capturedAt: Date(timeIntervalSince1970: 123_456),
            context: sourceContext,
            snippet: ocrText,
            imageRelativePath: "MEDIA_PATH_SENTINEL",
            thumbnailRelativePath: "THUMBNAIL_PATH_SENTINEL",
            score: 1
        )
        let candidate = PassageMemoryCapsuleCandidate(
            hit: hit,
            ocrText: ocrText,
            accessibility: [
                .init(
                    role: "AXButton",
                    label: "Open planning board",
                    depth: 2,
                    normalizedBounds: ScreenRect(
                        x: 0.1,
                        y: 0.2,
                        width: 0.3,
                        height: 0.4
                    )
                )
            ],
            savedTextRank: 1,
            visualAppearanceRank: 1,
            visual: PassageMemoryVisualEvidence(
                similarity: 0.91,
                maximumSimilarityError: 0.02,
                associatedFrameCount: 1,
                modelIdentifier: "local-model",
                modelRevision: "1"
            )
        )
        let request = PassageMemoryCapsuleRequest(
            query: SearchQuery(text: "planning", limit: 1),
            resultLimit: 1,
            utf8ByteBudget: 64 * 1_024
        )
        let manifest = try PassageMemoryCapsuleBuilder.build(
            request: request,
            candidates: [candidate]
        )
        return try PreparedContextHandoff.make(
            draft: ContextHandoffDraft(
                origin: .session(ActivitySessionID(rawValue: "session-safe")),
                retrieval: .session(ActivitySessionID(rawValue: "session-safe")),
                title: "Browser session",
                scopeDescription: "Recent ordinary moments in this session",
                containsPrivateHistory: false
            ),
            manifest: manifest
        )
    }

    private var sourceContext: ScreenContext {
        ScreenContext(
            applicationName: "Browser",
            bundleIdentifier: "app.browser",
            windowTitle: "WINDOW_TITLE_SENTINEL",
            url: URL(
                string: "https://person:password@example.com/private/path?token=secret#state"
            ),
            domain: "Example.COM.",
            displayID: 88,
            windowID: 99,
            windowBounds: ScreenRect(x: 10, y: 20, width: 800, height: 600)
        )
    }

    private func frame(ocrText: String) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: "handoff-source"),
            capturedAt: Date(timeIntervalSince1970: 123_456),
            context: sourceContext,
            ocrText: ocrText,
            imageRelativePath: "MEDIA_PATH_SENTINEL",
            pixelWidth: 1_200,
            pixelHeight: 800,
            visualFingerprint: 42,
            changeScore: 1,
            accessibilitySnapshot: AccessibilitySnapshot(
                nodes: [
                    AccessibilityNodeEvidence(
                        role: "AXButton",
                        label: "Open planning board",
                        depth: 2,
                        bounds: ScreenRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
                    )
                ],
                visitedNodeCount: 1,
                isTruncated: false
            )
        )
    }
}

private enum ReleaseTestError: Error {
    case failed
}

private final class SynchronousReleaseTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func contains(_ event: String) -> Bool {
        lock.withLock { events.contains(event) }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private actor SuspendingAccessEventStore: AccessEventRepository {
    private let trace: SynchronousReleaseTrace
    private var continuation: CheckedContinuation<Void, Never>?

    init(trace: SynchronousReleaseTrace) {
        self.trace = trace
    }

    func recordAccessEvent(_ event: AccessEvent) async throws {
        _ = event
        trace.append("receiptStarted")
        await withCheckedContinuation { continuation = $0 }
        trace.append("receiptCommitted")
    }

    func commit() {
        continuation?.resume()
        continuation = nil
    }

    func accessEvents(limit: Int) async throws -> [AccessEvent] { [] }
    func clearAccessEvents() async throws -> Int { 0 }
}

private actor FailingAccessEventStore: AccessEventRepository {
    func recordAccessEvent(_ event: AccessEvent) async throws {
        _ = event
        throw ReleaseTestError.failed
    }

    func accessEvents(limit: Int) async throws -> [AccessEvent] { [] }
    func clearAccessEvents() async throws -> Int { 0 }
}

private actor ImmediateAccessEventStore: AccessEventRepository {
    func recordAccessEvent(_ event: AccessEvent) async throws { _ = event }
    func accessEvents(limit: Int) async throws -> [AccessEvent] { [] }
    func clearAccessEvents() async throws -> Int { 0 }
}

@MainActor
private final class RecordingContextHandoffClipboard: ContextHandoffClipboardWriting {
    private let trace: SynchronousReleaseTrace
    private(set) var writes: [String] = []

    init(trace: SynchronousReleaseTrace) {
        self.trace = trace
    }

    func write(_ text: String) throws {
        trace.append("clipboardWrite")
        writes.append(text)
    }
}
