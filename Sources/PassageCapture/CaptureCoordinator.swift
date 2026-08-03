import PassageCore
import PassageStore
import CoreGraphics
import Foundation

public enum CaptureFailureDisposition: Sendable, Equatable {
    /// A short-lived screenshot/window race. Passage keeps its calm
    /// remembering state while the coordinator retries automatically.
    case retrying
    /// Permission, storage, OCR, or repeatedly failing screenshots need
    /// to be surfaced rather than silently retried forever.
    case actionRequired
}

public enum CaptureEvent: Sendable {
    case started
    case paused
    /// Passage is frontmost. This is an intentional privacy wait, not a
    /// capture failure: the app never records its own windows.
    case waitingForExternalApplication(continuous: Bool)
    /// Lightweight progress emitted immediately before pixels are requested.
    /// It lets first-run UI name the app being processed without changing the
    /// steady-state capture status.
    case processingContext(ScreenContext, continuous: Bool)
    case skippedPrivateContext(ScreenContext, continuous: Bool)
    case skippedUnchanged(continuous: Bool)
    case persisted(FrameDocument, continuous: Bool)
    /// Retention changed the durable history after a capture commit. No frame
    /// identifiers or media paths leave the coordinator through this signal.
    case retentionCommitted
    case failed(String, disposition: CaptureFailureDisposition)
}

/// An awaited UI/storage publication boundary around a retention mutation.
/// The coordinator does not begin deleting until `.willMutate` returns, and
/// always emits `.finished` after that boundary, including on failure.
public enum RetentionMutationBoundary: Sendable, Equatable {
    case willMutate
    case finished(commitEventFollows: Bool)
}

private enum CaptureControlSignal: Error {
    case coalesced
}

private enum CaptureCandidateResult {
    case persisted(FrameDocument)
    case unchanged
    /// No privacy-safe conclusion was possible because lifecycle or foreground
    /// context changed while the candidate was in flight. This is retryable and
    /// must not contribute to unchanged-screen backoff.
    case deferred
}

public actor CaptureCoordinator {
    public typealias EventHandler = @Sendable (CaptureEvent) -> Void
    public typealias RetentionMutationHandler = @Sendable (RetentionMutationBoundary) async -> Void
    public typealias SystemSignalProvider = @Sendable () -> AdaptiveCaptureCadence.SystemSignals
    /// Recognizes text in an image; the second parameter is Vision's
    /// normalized minimum text height for that image, which banded
    /// differential recognition scales so the absolute glyph floor matches
    /// whole-frame recognition.
    public typealias OCRRecognition = @Sendable (CGImage, Double) async throws -> OCRResult

    private let snapshots: any ScreenSnapshotProviding
    private let contexts: any ActiveContextProviding
    private let recognizeText: OCRRecognition
    private let detector: VisualChangeDetector
    private let media: MediaStore
    private let repository: any FrameRepository
    private let systemSignals: SystemSignalProvider
    private let hostBundleIdentifier: String?
    private var policy: CapturePolicy
    private var retentionPolicy: RetentionPolicy
    private var cadence: AdaptiveCaptureCadence
    private var lastRetentionSweep = Date.distantPast
    private var consecutiveTransientFailures = 0
    private var ocrBaseline: OCRBaseline?
    private var task: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var retentionMutationHandler: RetentionMutationHandler?
    private var captureEpoch = UUID()
    private var lifecycleEpoch = UUID()
    private var policyUpdateID: UUID?
    private var captureAdmissionPaused = false
    private var captureCandidateInProgress = false
    private var captureDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        snapshots: any ScreenSnapshotProviding = ScreenSnapshotService(),
        contexts: any ActiveContextProviding = ActiveContextProvider(),
        ocr: VisionOCRService = VisionOCRService(),
        ocrRecognition: OCRRecognition? = nil,
        detector: VisualChangeDetector = VisualChangeDetector(),
        media: MediaStore,
        repository: any FrameRepository,
        policy: CapturePolicy = CapturePolicy(),
        retentionPolicy: RetentionPolicy = RetentionPolicy(),
        hostBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        systemSignals: @escaping SystemSignalProvider = {
            AdaptiveCaptureCadence.SystemSignals.current()
        }
    ) {
        self.snapshots = snapshots
        self.contexts = contexts
        recognizeText = ocrRecognition ?? { image, minimumTextHeight in
            try await ocr.recognize(image, minimumTextHeight: minimumTextHeight)
        }
        self.detector = detector
        self.media = media
        self.repository = repository
        self.systemSignals = systemSignals
        self.hostBundleIdentifier = hostBundleIdentifier
        self.policy = policy
        self.retentionPolicy = retentionPolicy
        cadence = AdaptiveCaptureCadence(
            activeInterval: policy.activeInterval,
            unchangedHeartbeat: policy.unchangedHeartbeat
        )
    }

    public func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    public func setRetentionMutationHandler(_ handler: RetentionMutationHandler?) {
        retentionMutationHandler = handler
    }

    public func update(policy nextPolicy: CapturePolicy) async {
        let updateID = UUID()
        policyUpdateID = updateID
        captureAdmissionPaused = true
        // Stop admitting work, invalidate pixels still inside ScreenCaptureKit,
        // and let an already-started database transaction reach its atomic
        // commit/rollback boundary before the new policy becomes active.
        captureEpoch = UUID()
        await snapshots.invalidatePendingCaptures()
        await waitForCaptureDrain()
        guard policyUpdateID == updateID else { return }
        policyUpdateID = nil
        self.policy = nextPolicy
        cadence.update(
            activeInterval: nextPolicy.activeInterval,
            unchangedHeartbeat: nextPolicy.unchangedHeartbeat
        )
        captureAdmissionPaused = false
    }

    public func update(retentionPolicy: RetentionPolicy) {
        self.retentionPolicy = retentionPolicy
    }

    public func start(respectingCallerCancellation: Bool = false) {
        guard (!respectingCallerCancellation || !Task.isCancelled),
              task == nil else { return }
        lifecycleEpoch = UUID()
        cadence.reset()
        consecutiveTransientFailures = 0
        eventHandler?(.started)
        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func pause(respectingCallerCancellation: Bool = false) async {
        // A superseded model control job may still reach the actor queue. If it
        // was cancelled before execution, it has no authority to change state.
        guard !respectingCallerCancellation || !Task.isCancelled else { return }
        let pauseEpoch = UUID()
        lifecycleEpoch = pauseEpoch
        let runningTask = task
        task = nil
        captureEpoch = UUID()
        runningTask?.cancel()
        await snapshots.invalidatePendingCaptures()
        if let runningTask {
            await runningTask.value
        }
        // A newer Start owns the final state if it arrived while the old loop
        // was draining. Do not cancel it or publish a stale Paused event.
        guard lifecycleEpoch == pauseEpoch else { return }
        await waitForCaptureDrain()
        guard lifecycleEpoch == pauseEpoch else { return }
        cadence.reset()
        consecutiveTransientFailures = 0
        eventHandler?(.paused)
    }

    public func captureNow() async throws -> FrameDocument? {
        let expectedEpoch = captureEpoch
        let context = await contexts.current()
        try Task.checkCancellation()
        guard captureEpoch == expectedEpoch else { return nil }
        let result: CaptureCandidateResult
        do {
            result = try await captureCandidate(
                force: true,
                context: context,
                expectedEpoch: expectedEpoch
            )
        } catch CaptureControlSignal.coalesced {
            // A policy transition briefly closes admission. This is internal
            // coordination, not a user-actionable capture failure.
            return nil
        }
        if case .persisted(let frame) = result {
            cadence.record(.persisted, at: frame.capturedAt)
            return frame
        }
        return nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let now = Date()
            let context = await contexts.current()
            guard !Task.isCancelled else { break }
            let isHostApplication = Self.isHostApplication(
                context,
                hostBundleIdentifier: hostBundleIdentifier
            )
            let permitted = !isHostApplication && policy.permits(context)
            let signals = systemSignals()
            if let inactivityPause = policy.inactivityPause,
               signals.userIdleSeconds >= Self.seconds(inactivityPause) {
                // No screenshots, hashing, OCR, or writes while the person is
                // away. Keep only a low-frequency local activity check so the
                // first interaction resumes promptly.
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    break
                }
                continue
            }
            let decision = cadence.decision(
                now: now,
                contextKey: Self.contextKey(context),
                isPermitted: permitted,
                signals: signals
            )
            var nextCheckAfter = decision.nextCheckAfter

            if isHostApplication {
                consecutiveTransientFailures = 0
                eventHandler?(.waitingForExternalApplication(continuous: task != nil))
                // Passage's own UI is never a capture error. No screenshot is
                // requested while the first-memory coach or main window is frontmost.
            } else if !permitted {
                consecutiveTransientFailures = 0
                eventHandler?(.skippedPrivateContext(context, continuous: task != nil))
            } else if decision.shouldCapture {
                do {
                    switch try await captureCandidate(force: false, context: context) {
                    case .persisted(let frame):
                        cadence.record(.persisted, at: frame.capturedAt)
                    case .unchanged:
                        cadence.record(.unchanged, at: Date())
                    case .deferred:
                        cadence.record(.deferred, at: Date())
                    }
                    consecutiveTransientFailures = 0
                } catch is CancellationError {
                    if Task.isCancelled { break }
                    // An explicit invalidation can race a newer run without
                    // cancelling that run's Task. Retry calmly on its cadence.
                } catch CaptureControlSignal.coalesced {
                    // Capture Now already owns the one-shot pipeline. Do not
                    // misclassify overlap as an unchanged or failed screen.
                } catch {
                    cadence.record(.failed, at: Date())
                    let disposition = failureDisposition(for: error)
                    eventHandler?(.failed(
                        error.localizedDescription,
                        disposition: disposition
                    ))
                }
                nextCheckAfter = cadence.nextCheckInterval(
                    now: Date(),
                    isPermitted: true,
                    signals: signals
                )
            }

            guard !Task.isCancelled else { break }
            do {
                try await Task.sleep(for: nextCheckAfter)
            } catch {
                break
            }
        }
    }

    private func captureCandidate(
        force: Bool,
        context initialContext: ScreenContext,
        expectedEpoch requestedEpoch: UUID? = nil
    ) async throws -> CaptureCandidateResult {
        try Task.checkCancellation()
        let expectedEpoch = requestedEpoch ?? captureEpoch
        guard captureEpoch == expectedEpoch else { return .deferred }
        guard !captureAdmissionPaused else { throw CaptureControlSignal.coalesced }

        var initialContext = initialContext
        while captureCandidateInProgress {
            guard force else { throw CaptureControlSignal.coalesced }
            await waitForCaptureDrain()
            guard try captureIsCurrent(expectedEpoch) else { return .deferred }
            initialContext = await contexts.current()
            guard try captureIsCurrent(expectedEpoch) else { return .deferred }
            guard !captureAdmissionPaused else { throw CaptureControlSignal.coalesced }
        }
        guard !Self.isHostApplication(
            initialContext,
            hostBundleIdentifier: hostBundleIdentifier
        ) else {
            eventHandler?(.waitingForExternalApplication(continuous: task != nil))
            return .deferred
        }
        guard policy.permits(initialContext) else {
            eventHandler?(.skippedPrivateContext(initialContext, continuous: task != nil))
            return .deferred
        }
        if policy.captureFocusedWindowOnly, initialContext.windowID == nil {
            // Never degrade a privacy-scoped window request into display
            // capture. A transiently missing window is cheaper and safer to
            // skip than to record unrelated pixels behind it.
            return .deferred
        }
        captureCandidateInProgress = true
        defer { finishCaptureCandidate() }

        let requestPolicy = policy
        eventHandler?(.processingContext(initialContext, continuous: task != nil))
        let snapshot = try await snapshots.snapshot(
            hideCursor: requestPolicy.hideCursor,
            preferredDisplayID: initialContext.displayID,
            preferredWindowID: requestPolicy.captureFocusedWindowOnly ? initialContext.windowID : nil,
            excludedBundleIdentifiers: requestPolicy.excludedBundleIdentifiers
        )
        guard try captureIsCurrent(expectedEpoch) else { return .deferred }
        var context = await contexts.current()
        guard try captureIsCurrent(expectedEpoch) else { return .deferred }
        let transitionedToHost = Self.isHostApplication(
            context,
            hostBundleIdentifier: hostBundleIdentifier
        )
        guard !transitionedToHost,
              requestPolicy.permits(context),
              Self.contextKey(context) == Self.contextKey(initialContext) else {
            if transitionedToHost {
                eventHandler?(.waitingForExternalApplication(continuous: task != nil))
            } else if !requestPolicy.permits(context) {
                eventHandler?(.skippedPrivateContext(context, continuous: task != nil))
            }
            // The foreground context changed while ScreenCaptureKit delivered a
            // frame. Discard the pixels before fingerprinting, OCR, or storage so
            // a sensitive transition can never be labeled as the previous app.
            return .deferred
        }
        let validatedContextKey = Self.contextKey(context)
        context.displayID = snapshot.displayID
        let detectorContextKey = Self.contextKey(context)
        let signature = FrameFingerprint.contentSignature(snapshot.image)
        let fingerprint = signature.hash
        let heartbeat = Self.seconds(requestPolicy.unchangedHeartbeat)
        let decision = await detector.evaluate(
            fingerprint: fingerprint,
            context: detectorContextKey,
            capturedAt: snapshot.capturedAt,
            minimumDistance: force ? 0 : requestPolicy.minimumFingerprintDistance,
            heartbeat: heartbeat
        )
        guard try captureIsCurrent(expectedEpoch) else { return .deferred }
        guard force || decision.shouldPersist else {
            eventHandler?(.skippedUnchanged(continuous: task != nil))
            return .unchanged
        }

        let recognition = try await recognizeFrameText(
            image: snapshot.image,
            signature: signature,
            contextKey: detectorContextKey
        )
        let recognized = recognition.result
        guard try captureIsCurrent(expectedEpoch) else { return .deferred }
        // OCR coordinates are trustworthy browser-chrome evidence only when
        // the image is the focused window itself. A full-display capture can
        // contain another browser window and must never donate its website to
        // the foreground context.
        context = Self.contextByRecoveringBrowserWebsite(
            context,
            from: recognized.regions,
            captureFocusedWindowOnly: requestPolicy.captureFocusedWindowOnly
        )
        let accessibilityCapture = context.isSensitive
            ? ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
            : await contexts.validatedAccessibilityCapture(for: context)
        let accessibilitySnapshot = accessibilityCapture.snapshot
        guard try captureIsCurrent(expectedEpoch) else { return .deferred }
        // The accessibility walk already observed the live context on its way
        // out; probing the window server again would only repeat that work.
        let finalContext: ScreenContext
        if let observed = accessibilityCapture.liveContext {
            finalContext = observed
        } else {
            finalContext = await contexts.current()
            guard try captureIsCurrent(expectedEpoch) else { return .deferred }
        }
        let transitionedToHostBeforeInsert = Self.isHostApplication(
            finalContext,
            hostBundleIdentifier: hostBundleIdentifier
        )
        guard !transitionedToHostBeforeInsert,
              requestPolicy.permits(finalContext),
              !finalContext.isSensitive,
              Self.contextKey(finalContext) == validatedContextKey else {
            if transitionedToHostBeforeInsert {
                eventHandler?(.waitingForExternalApplication(continuous: task != nil))
            } else if !requestPolicy.permits(finalContext) || finalContext.isSensitive {
                eventHandler?(.skippedPrivateContext(finalContext, continuous: task != nil))
            }
            return .deferred
        }
        let id = FrameID()
        let storedMedia = try await media.write(
            image: snapshot.image,
            id: id,
            capturedAt: snapshot.capturedAt
        )
        let isCurrent: Bool
        do {
            isCurrent = try captureIsCurrent(expectedEpoch)
        } catch {
            await media.rollback(storedMedia)
            throw error
        }
        guard isCurrent else {
            await media.rollback(storedMedia)
            return .deferred
        }
        let frame = FrameDocument(
            id: id,
            capturedAt: snapshot.capturedAt,
            context: context,
            ocrText: recognized.text,
            ocrRegions: recognized.regions,
            imageRelativePath: storedMedia.imagePath,
            thumbnailRelativePath: storedMedia.thumbnailPath,
            pixelWidth: snapshot.image.width,
            pixelHeight: snapshot.image.height,
            visualFingerprint: fingerprint,
            changeScore: decision.normalizedScore,
            accessibilitySnapshot: accessibilitySnapshot
        )
        do {
            try await repository.insert(frame)
        } catch {
            await media.rollback(storedMedia)
            throw error
        }
        await detector.recordPersisted(
            fingerprint: fingerprint,
            context: detectorContextKey,
            capturedAt: snapshot.capturedAt
        )
        // The durable frame is the new differential baseline: its stored
        // observations are exactly what unchanged rows of the next capture
        // may carry forward.
        ocrBaseline = OCRBaseline(
            contextKey: detectorContextKey,
            raster: signature.raster,
            rowHashes: ScrollCarry.rowHashes(of: snapshot.image),
            regions: recognized.regions,
            imageWidth: snapshot.image.width,
            imageHeight: snapshot.image.height,
            differentialRunLength: recognition.wasDifferential
                ? (ocrBaseline?.differentialRunLength ?? 0) + 1
                : 0
        )
        // The insert is the durable capture boundary. Publish it before
        // best-effort maintenance so a cancellation after commit cannot leave
        // the UI unaware of a frame that already exists.
        eventHandler?(.persisted(frame, continuous: task != nil))
        do {
            if try await runRetentionSweepIfNeeded(now: snapshot.capturedAt) {
                eventHandler?(.retentionCommitted)
            }
        } catch is CancellationError {
            return .persisted(frame)
        }
        return .persisted(frame)
    }

    private struct OCRBaseline {
        var contextKey: String
        var raster: [UInt8]
        var rowHashes: [UInt64]?
        var regions: [OCRRegion]
        var imageWidth: Int
        var imageHeight: Int
        var differentialRunLength: Int
    }

    /// Runs accurate recognition over the whole frame, or — when the change
    /// raster proves only a narrow band differs from the last persisted frame
    /// of the same context — over that band alone, splicing the fresh
    /// observations into the carried accurate ones. Same engine, same
    /// quality, a fraction of the inference cost during typing and small
    /// updates. Context switches, large changes, dimension changes, and a
    /// periodic anchor always re-recognize the whole frame.
    private func recognizeFrameText(
        image: CGImage,
        signature: FrameFingerprint.ContentSignature,
        contextKey: String
    ) async throws -> (result: OCRResult, wasDifferential: Bool) {
        let rasterWidth = FrameFingerprint.ContentSignature.rasterWidth
        let rasterHeight = FrameFingerprint.ContentSignature.rasterHeight
        if ProcessInfo.processInfo.environment["PASSAGE_DISABLE_DIFFERENTIAL_OCR"] == nil,
           let baseline = ocrBaseline,
           baseline.contextKey == contextKey,
           baseline.imageWidth == image.width,
           baseline.imageHeight == image.height,
           baseline.differentialRunLength < DifferentialOCR.anchorInterval {
            guard let changedRows = DifferentialOCR.changedRowRange(
                previous: baseline.raster,
                current: signature.raster,
                width: rasterWidth,
                height: rasterHeight
            ) else {
                // A byte-identical raster (heartbeat persist) is precisely
                // the situation the dedup gate calls an unchanged screen:
                // the previous accurate observations still describe every
                // pixel, so no recognition needs to run at all.
                let result = OCRPostProcessor.process(
                    baseline.regions,
                    minimumConfidence: VisionOCRService.accurateMinimumConfidence
                )
                return (result, true)
            }
            if let plan = DifferentialOCR.bandPlan(
                changedRows: changedRows,
                rasterHeight: rasterHeight
            ) {
                let crop = DifferentialOCR.cropRect(
                    plan: plan,
                    rasterHeight: rasterHeight,
                    imageWidth: image.width,
                    imageHeight: image.height
                )
                if let result = try await recognizeBand(
                    image: image,
                    cropRect: crop,
                    dropBand: DifferentialOCR.normalizedBand(
                        topRow: plan.dropTopRow,
                        bottomRow: plan.dropBottomRow,
                        rasterHeight: rasterHeight
                    ),
                    carried: baseline.regions
                ) {
                    return (result, true)
                }
            } else if let previousHashes = baseline.rowHashes,
                      let currentHashes = ScrollCarry.rowHashes(of: image),
                      let scroll = ScrollCarry.plan(
                        previousHashes: previousHashes,
                        currentHashes: currentHashes,
                        previousRegions: baseline.regions,
                        imageWidth: image.width,
                        imageHeight: image.height
                      ) {
                // The change spans most of the frame, but per-row hashes
                // prove it is the same content shifted vertically: carry the
                // observations to their new positions and recognize only the
                // rows no shift explains (the revealed strip).
                if let crop = scroll.cropRect {
                    if let result = try await recognizeBand(
                        image: image,
                        cropRect: crop,
                        dropBand: scroll.dropBand,
                        carried: scroll.carriedRegions
                    ) {
                        return (result, true)
                    }
                } else {
                    let result = OCRPostProcessor.process(
                        scroll.carriedRegions,
                        minimumConfidence: VisionOCRService.accurateMinimumConfidence
                    )
                    return (result, true)
                }
            }
        }
        return (
            try await recognizeText(image, VisionOCRService.defaultMinimumTextHeight),
            false
        )
    }

    /// Recognizes one horizontal band and splices its observations into the
    /// carried set. Returns nil only when the crop itself cannot be made,
    /// in which case the caller falls back to whole-frame recognition.
    private func recognizeBand(
        image: CGImage,
        cropRect: CGRect,
        dropBand: ClosedRange<Double>,
        carried: [OCRRegion]
    ) async throws -> OCRResult? {
        guard cropRect.height > 0, let banded = image.cropping(to: cropRect) else {
            return nil
        }
        // Keep the absolute glyph-height floor identical to whole-frame
        // recognition: the crop is shorter, so its normalized threshold must
        // grow by the same ratio.
        let bandMinimumTextHeight = VisionOCRService.defaultMinimumTextHeight
            * Double(image.height) / Double(cropRect.height)
        let fresh = try await recognizeText(banded, bandMinimumTextHeight)
        let projected = DifferentialOCR.projectedRegions(
            fresh.regions,
            cropRect: cropRect,
            imageHeight: image.height
        )
        let merged = DifferentialOCR.mergedRegions(
            carried: carried,
            fresh: projected,
            dropBand: dropBand
        )
        return OCRPostProcessor.process(
            merged,
            minimumConfidence: VisionOCRService.accurateMinimumConfidence
        )
    }

    /// Internal for a deterministic privacy regression test. Full-display OCR
    /// has no authority to mutate foreground website metadata.
    static func contextByRecoveringBrowserWebsite(
        _ context: ScreenContext,
        from regions: [OCRRegion],
        captureFocusedWindowOnly: Bool
    ) -> ScreenContext {
        // A trusted HTTP(S) URL came from the still-authoritative focused
        // context and can safely contribute its host in either capture mode.
        // OCR coordinates gain that authority only when the pixels themselves
        // are the focused window.
        return BrowserWebsiteMetadata.enriching(
            context,
            from: captureFocusedWindowOnly ? regions : []
        )
    }

    private func captureIsCurrent(_ expectedEpoch: UUID) throws -> Bool {
        try Task.checkCancellation()
        return captureEpoch == expectedEpoch
    }

    private func finishCaptureCandidate() {
        captureCandidateInProgress = false
        let waiters = captureDrainWaiters
        captureDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForCaptureDrain() async {
        guard captureCandidateInProgress else { return }
        await withCheckedContinuation { continuation in
            captureDrainWaiters.append(continuation)
        }
    }

    private func runRetentionSweepIfNeeded(now: Date) async throws -> Bool {
        guard now.timeIntervalSince(lastRetentionSweep) >= 3_600 else { return false }
        lastRetentionSweep = now
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionPolicy.maximumAgeDays,
            to: now
        ) ?? now.addingTimeInterval(-Double(retentionPolicy.maximumAgeDays) * 86_400)

        var statistics = try await repository.statistics()
        let ageMutationExpected = statistics.oldestCapture.map { $0 < cutoff } ?? false
        let storageMutationExpected = statistics.mediaBytes
            > retentionPolicy.maximumMediaBytes
        let boundaryHandler = (ageMutationExpected || storageMutationExpected)
            ? retentionMutationHandler
            : nil
        if let boundaryHandler {
            await boundaryHandler(.willMutate)
        }

        do {
            let frameCountBeforeAgeSweep = statistics.frameCount
            let paths = try await repository.deleteFrames(olderThan: cutoff)
            await media.delete(relativePaths: paths)
            statistics = try await repository.statistics()
            var durableStateChanged = !paths.isEmpty
                || statistics.frameCount < frameCountBeforeAgeSweep

            // Enforce the user-visible storage ceiling oldest-first. The loop is
            // bounded by actual progress: every pass must remove at least one
            // indexed frame or media reference, and filesystem size is re-measured
            // after deletion.
            while true {
                guard statistics.mediaBytes > retentionPolicy.maximumMediaBytes else { break }
                let frameCountBeforePass = statistics.frameCount
                let oldestPaths: [String]
                if retentionPolicy.preserveTextAfterMediaExpiry {
                    oldestPaths = try await repository.expireOldestMedia(limit: 1_000)
                } else {
                    oldestPaths = try await repository.deleteOldestFrames(limit: 1_000)
                }
                await media.delete(relativePaths: oldestPaths)
                statistics = try await repository.statistics()
                let passChanged = !oldestPaths.isEmpty
                    || statistics.frameCount < frameCountBeforePass
                guard passChanged else { break }
                durableStateChanged = true
            }
            if let boundaryHandler {
                await boundaryHandler(.finished(commitEventFollows: durableStateChanged))
            }
            return durableStateChanged
        } catch {
            if let boundaryHandler {
                // A sweep spans index and media operations, so an error after
                // pre-invalidation must still reconstruct UI from durable state.
                await boundaryHandler(.finished(commitEventFollows: false))
            }
            throw error
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func failureDisposition(for error: Error) -> CaptureFailureDisposition {
        guard Self.isTransientCaptureFailure(error) else {
            consecutiveTransientFailures = 0
            return .actionRequired
        }
        consecutiveTransientFailures += 1
        return Self.disposition(
            forConsecutiveTransientFailures: consecutiveTransientFailures
        )
    }

    static func isTransientCaptureFailure(_ error: Error) -> Bool {
        guard let passageError = error as? PassageError else { return false }
        if case .captureUnavailable = passageError { return true }
        return false
    }

    static func disposition(
        forConsecutiveTransientFailures count: Int
    ) -> CaptureFailureDisposition {
        count >= 3 ? .actionRequired : .retrying
    }

    private static func contextKey(_ context: ScreenContext) -> String {
        [
            context.bundleIdentifier ?? context.applicationName,
            context.windowTitle ?? "",
            context.domain ?? "",
            context.displayID.map(String.init) ?? "",
            context.windowID.map(String.init) ?? ""
        ].joined(separator: "|")
    }

    static func isHostApplication(
        _ context: ScreenContext,
        hostBundleIdentifier: String?
    ) -> Bool {
        guard let hostBundleIdentifier,
              let contextBundleIdentifier = context.bundleIdentifier else { return false }
        return contextBundleIdentifier == hostBundleIdentifier
    }
}
