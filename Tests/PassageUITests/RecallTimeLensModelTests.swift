@testable import PassageUI
import PassageCore
import PassageStore
import Foundation
import Testing

@Suite("Recall Time Lens model", .serialized)
@MainActor
struct RecallTimeLensModelTests {
    @Test("Bounds clamp and round-trip normalized positions")
    func boundsMapping() throws {
        let oldest = Date(timeIntervalSince1970: 100)
        let newest = Date(timeIntervalSince1970: 200)
        let bounds = try #require(RecallTimeLensBounds(oldest: oldest, newest: newest))

        #expect(bounds.date(at: -1) == oldest)
        #expect(bounds.date(at: 2) == newest)
        #expect(bounds.date(at: 0.25) == Date(timeIntervalSince1970: 125))
        #expect(bounds.fraction(for: Date(timeIntervalSince1970: 125)) == 0.25)
        #expect(bounds.fraction(for: Date(timeIntervalSince1970: 50)) == 0)
        #expect(bounds.fraction(for: Date(timeIntervalSince1970: 250)) == 1)

        let single = try #require(RecallTimeLensBounds(oldest: oldest, newest: oldest))
        #expect(single.date(at: 0.8) == oldest)
        #expect(single.fraction(for: newest) == 0)
        #expect(RecallTimeLensBounds(oldest: newest, newest: oldest) == nil)
    }

    @Test("Seek scope includes the target and preserves every active constraint")
    func seekScopePreservesConstraints() throws {
        let start = Date(timeIntervalSince1970: 100)
        let target = Date(timeIntervalSince1970: 150)
        let originalEnd = Date(timeIntervalSince1970: 200)
        let base = RecallScope(
            text: "  Project   Phoenix ",
            startDate: start,
            endDate: originalEnd,
            applicationBundleIdentifiers: ["com.example.Design"],
            domains: ["DESIGN.EXAMPLE"]
        )

        let scope = try #require(RecallTimeLensQuery.scope(
            atOrBefore: target,
            preserving: base
        ))
        #expect(scope.text == "Project Phoenix")
        #expect(scope.startDate == start)
        #expect(scope.endDate == RecallTimeLensQuery.exclusiveInstant(after: target))
        #expect(scope.applicationBundleIdentifiers == ["com.example.Design"])
        #expect(scope.domains == ["design.example"])

        let capped = try #require(RecallTimeLensQuery.scope(
            atOrBefore: Date(timeIntervalSince1970: 250),
            preserving: base
        ))
        #expect(capped.endDate == originalEnd)
        #expect(RecallTimeLensQuery.scope(atOrBefore: start.addingTimeInterval(-1), preserving: base) == nil)
    }

    @Test("Preview is selection-neutral and cancel restores the pointer-down selection")
    func previewAndCancelSemantics() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()

        let newest = try #require(model.results.first { $0.id.rawValue == "f300" })
        let middle = try #require(model.results.first { $0.id.rawValue == "f200" })
        model.select(newest)
        #expect(model.beginRecallTimeLensScrub() != nil)

        model.previewRecallTimeLens(at: Date(timeIntervalSince1970: 150))
        let previewed = await waitUntil {
            model.recallTimeLensPreview?.hit?.id.rawValue == "f100"
                && model.recallTimeLensPreview?.isResolving == false
        }
        #expect(previewed)
        #expect(model.recallTimeLensPreview?.resolution == .resolved)
        #expect(model.recallTimeLensPreview?.resolvedHit?.id.rawValue == "f100")
        #expect(model.selectedHit?.id == newest.id)

        // Model a result-list click racing the still-open gesture. Cancel must
        // return to the selection captured at pointer-down.
        model.select(middle)
        model.cancelRecallTimeLensScrub()
        #expect(model.selectedHit?.id == newest.id)
        #expect(!model.recallTimeLensIsScrubbing)
        #expect(model.recallTimeLensPreview == nil)
    }

    @Test("Commit performs an exact seek and selects the nearest moment at or before release")
    func commitSelectsNearestMoment() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()
        let baseline = try #require(model.results.first { $0.id.rawValue == "f300" })
        model.select(baseline)

        #expect(model.beginRecallTimeLensScrub() != nil)
        model.commitRecallTimeLens(at: Date(timeIntervalSince1970: 200))

        let committed = await waitUntil { model.selectedHit?.id.rawValue == "f200" }
        #expect(committed)
        #expect(!model.recallTimeLensIsScrubbing)
        #expect(model.recallTimeLensPreview?.requestedAt == Date(timeIntervalSince1970: 200))
        #expect(model.recallTimeLensPreview?.resolution == .resolved)
        #expect(model.recallTimeLensPreview?.resolvedHit?.id.rawValue == "f200")

        let seekScopes = await repository.seekScopes()
        let finalScope = try #require(seekScopes.last)
        #expect(
            finalScope.endDate
                == RecallTimeLensQuery.exclusiveInstant(
                    after: Date(timeIntervalSince1970: 200)
                )
        )
    }

    @Test("Commit failure remains observable and leaves selection unchanged")
    func failedCommitPreservesTerminalOutcome() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()
        let baseline = try #require(model.results.first { $0.id.rawValue == "f300" })
        model.select(baseline)

        let target = Date(timeIntervalSince1970: 200)
        await repository.failSeek(through: target)
        #expect(model.beginRecallTimeLensScrub() != nil)
        model.commitRecallTimeLens(at: target)

        let failed = await waitUntil {
            model.recallTimeLensPreview?.requestedAt == target
                && model.recallTimeLensPreview?.resolution == .failed
        }
        #expect(failed)
        #expect(model.selectedHit?.id == baseline.id)
        #expect(model.recallTimeLensPreview?.resolvedHit == nil)
        #expect(!model.recallTimeLensIsScrubbing)

        model.cancelRecallTimeLensScrub()
        #expect(model.recallTimeLensPreview == nil)
    }

    @Test("A whole-day seek keeps an unloaded committed moment on the painted rail")
    func committedUnloadedMomentJoinsVisibleMarkers() async throws {
        let frames = (1...80).map { Self.frame(timestamp: $0) }
        let repository = RecallTimeLensFakeRepository(frames: frames)
        let model = makeModel(repository: repository)
        await model.refresh()

        #expect(model.results.count == 60)
        #expect(!model.results.contains { $0.id.rawValue == "f10" })
        #expect(model.beginRecallTimeLensScrub() != nil)

        model.commitRecallTimeLens(at: Date(timeIntervalSince1970: 10))

        let committed = await waitUntil {
            model.selectedHit?.id.rawValue == "f10"
                && model.results.contains { $0.id.rawValue == "f10" }
        }
        #expect(committed)
        #expect(model.results.count == 61)
        #expect(Set(model.results.map(\.id)).count == model.results.count)
    }

    @Test("A superseded preview cannot publish after a newer target")
    func stalePreviewCannotPublish() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()
        #expect(model.beginRecallTimeLensScrub() != nil)

        let firstTarget = Date(timeIntervalSince1970: 150)
        let secondTarget = Date(timeIntervalSince1970: 250)
        await repository.suspendSeek(through: firstTarget)
        model.previewRecallTimeLens(at: firstTarget)
        let firstStarted = await waitUntil {
            await repository.hasSeekWaiter(through: firstTarget)
        }
        #expect(firstStarted)

        model.previewRecallTimeLens(at: secondTarget)
        #expect(model.recallTimeLensPreview?.requestedAt == secondTarget)
        #expect(model.recallTimeLensPreview?.resolution == .resolving)
        #expect(model.recallTimeLensPreview?.resolvedHit == nil)
        await repository.releaseSeek(through: firstTarget)

        let secondPublished = await waitUntil {
            model.recallTimeLensPreview?.requestedAt == secondTarget
                && model.recallTimeLensPreview?.hit?.id.rawValue == "f200"
                && model.recallTimeLensPreview?.isResolving == false
        }
        #expect(secondPublished)
        #expect(model.recallTimeLensPreview?.resolution == .resolved)
        #expect(model.recallTimeLensPreview?.resolvedHit?.id.rawValue == "f200")
        #expect(model.recallTimeLensPreview?.hit?.id.rawValue != "f100")
    }

    @Test("A failed newer lookup cannot relabel retained evidence as resolved")
    func failedPreviewKeepsEvidenceUncorrelated() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()
        #expect(model.beginRecallTimeLensScrub() != nil)

        let firstTarget = Date(timeIntervalSince1970: 150)
        model.previewRecallTimeLens(at: firstTarget)
        let firstResolved = await waitUntil {
            model.recallTimeLensPreview?.resolvedHit?.id.rawValue == "f100"
        }
        #expect(firstResolved)

        let failedTarget = Date(timeIntervalSince1970: 250)
        await repository.failSeek(through: failedTarget)
        model.previewRecallTimeLens(at: failedTarget)
        let failed = await waitUntil {
            model.recallTimeLensPreview?.requestedAt == failedTarget
                && model.recallTimeLensPreview?.resolution == .failed
        }

        #expect(failed)
        #expect(model.recallTimeLensPreview?.hit?.id.rawValue == "f100")
        #expect(model.recallTimeLensPreview?.resolvedHit == nil)
        model.cancelRecallTimeLensScrub()
    }

    @Test("Capture refresh cannot move frozen bounds beneath an active gesture")
    func captureRefreshPreservesFrozenBounds() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()
        let frozen = try #require(model.beginRecallTimeLensScrub())
        #expect(frozen.newest == Date(timeIntervalSince1970: 300))

        let newFrame = Self.frame(timestamp: 400)
        await repository.insert(newFrame)
        model.consume(.persisted(newFrame, continuous: true))
        let statisticsRefreshed = await waitUntil {
            model.statistics.newestCapture == newFrame.capturedAt
        }
        #expect(statisticsRefreshed)
        #expect(model.recallTimeLensBounds == frozen)

        model.cancelRecallTimeLensScrub()
        #expect(model.recallTimeLensBounds?.newest == newFrame.capturedAt)
    }

    @Test("An out-of-scope selection is baseline-only, never an initial preview")
    func outOfScopeSelectionDoesNotSeedPreview() async throws {
        let repository = RecallTimeLensFakeRepository(frames: Self.frames)
        let model = makeModel(repository: repository)
        await model.refresh()
        let oldScopeHit = try #require(model.results.first)

        model.toggleRecallApplication("com.example.Other")
        let newScopeLoaded = await waitUntil {
            !model.recallIsLoading && model.results.isEmpty
        }
        #expect(newScopeLoaded)
        model.select(oldScopeHit)

        #expect(model.beginRecallTimeLensScrub() != nil)
        #expect(model.recallTimeLensPreview == nil)
        model.cancelRecallTimeLensScrub()
        #expect(model.selectedHit?.id == oldScopeHit.id)
    }

    @Test("Preview throttling has a deterministic eighty-millisecond floor")
    func throttleMath() {
        #expect(
            RecallTimeLensThrottle.remainingDelay(after: .zero)
                == .milliseconds(80)
        )
        #expect(
            RecallTimeLensThrottle.remainingDelay(after: .milliseconds(30))
                == .milliseconds(50)
        )
        #expect(RecallTimeLensThrottle.remainingDelay(after: .milliseconds(80)) == nil)
        #expect(RecallTimeLensThrottle.remainingDelay(after: .milliseconds(120)) == nil)
    }

    private func makeModel(repository: any PassageModelRepository) -> PassageModel {
        let suiteName = "RecallTimeLensModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PassageModel(
            captureIntentStore: CaptureIntentStore(defaults: defaults),
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {},
            repository: repository
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private static let frames = [100, 200, 300].map { frame(timestamp: $0) }

    private static func frame(timestamp: Int) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: "f\(timestamp)"),
            capturedAt: Date(timeIntervalSince1970: Double(timestamp)),
            context: ScreenContext(
                applicationName: "Design",
                bundleIdentifier: "com.example.Design",
                windowTitle: "Project Phoenix",
                url: URL(string: "https://design.example/phoenix"),
                domain: "design.example"
            ),
            ocrText: "Project Phoenix evidence",
            imageRelativePath: "Media/f\(timestamp).bin",
            thumbnailRelativePath: "Thumbnails/f\(timestamp).bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: UInt64(timestamp),
            changeScore: 1
        )
    }
}

private enum RecallTimeLensFakeError: Error {
    case requestedFailure
}

private actor RecallTimeLensFakeRepository: PassageModelRepository {
    private var frames: [FrameDocument]
    private var suspendedSeekEnds = Set<UInt64>()
    private var failedSeekEnds = Set<UInt64>()
    private var seekWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var recordedSeekScopes: [RecallScope] = []

    init(frames: [FrameDocument]) {
        self.frames = frames
    }

    func suspendSeek(through target: Date) {
        suspendedSeekEnds.insert(Self.seekEndKey(through: target))
    }

    func failSeek(through target: Date) {
        failedSeekEnds.insert(Self.seekEndKey(through: target))
    }

    func hasSeekWaiter(through target: Date) -> Bool {
        !(seekWaiters[Self.seekEndKey(through: target)] ?? []).isEmpty
    }

    func releaseSeek(through target: Date) {
        let key = Self.seekEndKey(through: target)
        suspendedSeekEnds.remove(key)
        let waiters = seekWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
    }

    func seekScopes() -> [RecallScope] {
        recordedSeekScopes
    }

    func insert(_ frame: FrameDocument) {
        frames.removeAll { $0.id == frame.id }
        frames.append(frame)
    }

    func search(_ query: SearchQuery) -> [SearchHit] {
        filtered(
            RecallScope(
                text: query.text,
                startDate: query.startDate,
                endDate: query.endDate,
                applicationBundleIdentifiers: query.applicationBundleIdentifiers,
                domains: query.domains
            )
        ).prefix(query.limit).map(Self.hit)
    }

    func recent(limit: Int) -> [SearchHit] {
        frames.sorted { $0.capturedAt > $1.capturedAt }.prefix(limit).map(Self.hit)
    }

    func recall(
        _ scope: RecallScope,
        after cursor: RecallCursor?,
        limit: Int
    ) async throws -> RecallPage {
        if let end = scope.endDate {
            let key = end.timeIntervalSince1970.bitPattern
            recordedSeekScopes.append(scope)
            if failedSeekEnds.contains(key) {
                throw RecallTimeLensFakeError.requestedFailure
            }
            if suspendedSeekEnds.contains(key) {
                await withCheckedContinuation { continuation in
                    seekWaiters[key, default: []].append(continuation)
                }
            }
        }
        let hits = filtered(scope).prefix(limit).map(Self.hit)
        return RecallPage(hits: hits, nextCursor: nil, hasMore: false)
    }

    func recallFacets(_ scope: RecallScope, limitPerKind: Int) -> RecallFacets {
        RecallFacets()
    }

    func frame(id: FrameID) -> FrameDocument? {
        frames.first { $0.id == id }
    }

    func deleteFrames(olderThan date: Date) -> [String] { [] }
    func deleteFrames(from startDate: Date?, through endDate: Date?) -> [String] { [] }
    func deleteOldestFrames(limit: Int) -> [String] { [] }
    func expireOldestMedia(limit: Int) -> [String] { [] }

    func statistics() -> StoreStatistics {
        StoreStatistics(
            frameCount: frames.count,
            oldestCapture: frames.map(\.capturedAt).min(),
            newestCapture: frames.map(\.capturedAt).max(),
            databaseBytes: 0,
            mediaBytes: 0
        )
    }

    func activitySessions(_ query: ActivitySessionQuery) -> [ActivitySessionSummary] { [] }
    func activitySession(id: ActivitySessionID, momentLimit: Int) -> ActivitySessionDetail? { nil }

    private func filtered(_ scope: RecallScope) -> [FrameDocument] {
        frames.filter { frame in
            if let start = scope.startDate, frame.capturedAt < start { return false }
            if let end = scope.endDate, frame.capturedAt >= end { return false }
            if !scope.applicationBundleIdentifiers.isEmpty,
               !scope.applicationBundleIdentifiers.contains(frame.context.bundleIdentifier ?? "") {
                return false
            }
            if !scope.domains.isEmpty,
               !scope.domains.contains(frame.context.domain?.lowercased() ?? "") {
                return false
            }
            let tokens = scope.text.lowercased().split(whereSeparator: \.isWhitespace)
            return tokens.allSatisfy { frame.ocrText.lowercased().contains($0) }
        }.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.id.rawValue > $1.id.rawValue
            }
            return $0.capturedAt > $1.capturedAt
        }
    }

    private static func hit(_ frame: FrameDocument) -> SearchHit {
        SearchHit(
            id: frame.id,
            capturedAt: frame.capturedAt,
            context: frame.context,
            snippet: frame.ocrText,
            imageRelativePath: frame.imageRelativePath,
            thumbnailRelativePath: frame.thumbnailRelativePath,
            score: 0
        )
    }

    private static func seekEndKey(through target: Date) -> UInt64 {
        RecallTimeLensQuery.exclusiveInstant(after: target)?
            .timeIntervalSince1970.bitPattern ?? 0
    }
}
