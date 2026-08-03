@testable import PassageUI
import PassageCore
import Foundation
import Testing

@Suite("Capture lifecycle state")
@MainActor
struct CaptureStateTests {
    @Test("Capture and privacy meaning stays identical across every app surface")
    func capturePrivacyPresentationIsTruthful() {
        let capturing = CapturePrivacyPresentation(state: .capturing)
        let privateContext = CapturePrivacyPresentation(
            state: .privateContext("Passwords")
        )
        let paused = CapturePrivacyPresentation(state: .paused)
        let unavailable = CapturePrivacyPresentation(state: .unavailable)
        let locked = CapturePrivacyPresentation(state: .locked)
        let failed = CapturePrivacyPresentation(
            state: .error("Screen Recording permission is required")
        )

        #expect(capturing.title == "Remembering")
        #expect(capturing.detail.contains("Still snapshots"))
        #expect(capturing.detail.contains("encrypted on this Mac"))
        #expect(!capturing.detail.lowercased().contains("recording"))
        #expect(capturing.tone == .remembering)

        #expect(privateContext.title == "Passwords stays private")
        #expect(privateContext.detail == "No text or image is being saved")
        #expect(privateContext.tone == .privateContext)
        #expect(privateContext.menuBarIcon == capturing.menuBarIcon)

        #expect(paused.detail == "Nothing new is being saved")
        #expect(unavailable.detail == "Nothing is being saved yet")
        #expect(locked.detail.contains("remains encrypted"))
        #expect(failed.title == "Remembering needs attention")
        #expect(failed.detail.contains("Screen Recording"))
        #expect(failed.tone == .attention)
        #expect(capturing.accessibilityLabel == "\(capturing.title). \(capturing.detail)")
    }

    @Test("Capture intent defaults paused and survives store reconstruction")
    func captureIntentPersistence() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }

        let store = CaptureIntentStore(defaults: fixture.defaults)
        #expect(store.load() == .paused)

        store.save(.remembering)
        let restored = CaptureIntentStore(defaults: fixture.defaults)
        #expect(restored.load() == .remembering)

        restored.save(.paused)
        #expect(store.load() == .paused)
    }

    @Test("Start before initialization queues intent without requesting permission")
    func preInitializationStartQueuesWithoutPrompt() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let store = CaptureIntentStore(defaults: fixture.defaults)
        var permissionRequestCount = 0
        let model = PassageModel(
            captureIntentStore: store,
            screenPermissionStatus: { false },
            screenPermissionRequest: {
                permissionRequestCount += 1
                return true
            },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {}
        )

        let outcome = model.startCapturing()

        #expect(outcome == .pendingInitialization)
        #expect(model.captureIntent == .remembering)
        #expect(store.load() == .remembering)
        #expect(permissionRequestCount == 0)
    }

    @Test("Explicit permission action prompts but never changes capture intent")
    func explicitPermissionActionOnlyRefreshesPermission() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        var permissionRequestCount = 0
        let model = PassageModel(
            captureIntentStore: CaptureIntentStore(defaults: fixture.defaults),
            screenPermissionStatus: { false },
            screenPermissionRequest: {
                permissionRequestCount += 1
                return true
            },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {}
        )

        model.requestScreenPermission()

        #expect(permissionRequestCount == 1)
        #expect(model.screenPermissionGranted)
        #expect(model.captureIntent == .paused)
    }

    @Test("Pause persists even while initialization is pending")
    func preInitializationPausePersists() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let store = CaptureIntentStore(defaults: fixture.defaults)
        let model = PassageModel(
            captureIntentStore: store,
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {}
        )

        #expect(model.startCapturing() == .pendingInitialization)
        model.pauseCapturing()

        #expect(model.captureIntent == .paused)
        #expect(store.load() == .paused)
    }

    @Test("Initialization consumes a remembered intent only with permission")
    func initializationReconciliation() {
        #expect(
            CaptureLifecycleReducer.startOutcome(
                coordinatorInitialized: false,
                permissionGranted: true
            ) == .pendingInitialization
        )
        #expect(
            CaptureLifecycleReducer.startOutcome(
                coordinatorInitialized: true,
                permissionGranted: false
            ) == .permissionRequired
        )
        #expect(
            CaptureLifecycleReducer.startOutcome(
                coordinatorInitialized: true,
                permissionGranted: true
            ) == .started
        )
        #expect(
            CaptureLifecycleReducer.initializationDecision(
                intent: .remembering,
                permissionGranted: true
            ) == .start
        )
        #expect(
            CaptureLifecycleReducer.initializationDecision(
                intent: .remembering,
                permissionGranted: false
            ) == .none
        )
        #expect(
            CaptureLifecycleReducer.initializationDecision(
                intent: .paused,
                permissionGranted: true
            ) == .none
        )
    }

    @Test("A temporary session-lock pause preserves remembering intent")
    func temporarySessionLockPausePreservesIntent() async {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let store = CaptureIntentStore(defaults: fixture.defaults)
        let model = PassageModel(
            captureIntentStore: store,
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {}
        )
        _ = model.startCapturing()

        await model.suspendForSessionLock()

        #expect(model.captureIntent == .remembering)
        #expect(store.load() == .remembering)
    }

    @Test("Toggle follows durable intent even while runtime state is unavailable")
    func toggleUsesCaptureIntent() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let store = CaptureIntentStore(defaults: fixture.defaults)
        let model = PassageModel(
            captureIntentStore: store,
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {}
        )

        model.toggleCapture()
        #expect(model.captureIntent == .remembering)
        model.toggleCapture()
        #expect(model.captureIntent == .paused)
        #expect(store.load() == .paused)
    }

    @Test("Permission refresh pauses on revocation and resumes pending intent")
    func permissionRefreshReconciliation() {
        #expect(
            CaptureLifecycleReducer.permissionRefreshDecision(
                intent: .remembering,
                coordinatorInitialized: true,
                previouslyGranted: true,
                permissionGranted: false
            ) == .pause
        )
        #expect(
            CaptureLifecycleReducer.permissionRefreshDecision(
                intent: .remembering,
                coordinatorInitialized: true,
                previouslyGranted: false,
                permissionGranted: true
            ) == .start
        )
        #expect(
            CaptureLifecycleReducer.permissionRefreshDecision(
                intent: .paused,
                coordinatorInitialized: true,
                previouslyGranted: false,
                permissionGranted: true
            ) == .none
        )
        #expect(
            CaptureLifecycleReducer.permissionRefreshDecision(
                intent: .remembering,
                coordinatorInitialized: false,
                previouslyGranted: true,
                permissionGranted: false
            ) == .none
        )
    }

    @Test("A paused one-shot persistence does not claim continuous capture")
    func pausedManualPersistenceStaysPaused() {
        let next = PassageModel.captureState(
            after: .persisted(Self.frame, continuous: false),
            current: .paused
        )

        #expect(next == .paused)
    }

    @Test("A paused one-shot private skip remains paused")
    func pausedManualPrivateSkipStaysPaused() {
        let next = PassageModel.captureState(
            after: .skippedPrivateContext(Self.frame.context, continuous: false),
            current: .paused
        )

        #expect(next == .paused)
    }

    @Test("A live persistence restores the continuous capturing state")
    func continuousPersistenceIsCapturing() {
        let next = PassageModel.captureState(
            after: .persisted(Self.frame, continuous: true),
            current: .privateContext("Passwords")
        )

        #expect(next == .capturing)
    }

    @Test("A transient capture retry does not flap the menu-bar status")
    func transientRetryKeepsCalmState() {
        let next = PassageModel.captureState(
            after: .failed(
                "The focused window is no longer available",
                disposition: .retrying
            ),
            current: .capturing
        )

        #expect(next == .capturing)
    }

    @Test("A retry attempt does not hide an unresolved persistent failure")
    func retryStartDoesNotClearPersistentFailure() {
        let error = PassageModel.CaptureState.error("Capture stream stopped")
        let processing = PassageModel.captureState(
            after: .processingContext(Self.frame.context, continuous: true),
            current: error
        )
        let recovered = PassageModel.captureState(
            after: .skippedUnchanged(continuous: true),
            current: processing
        )

        #expect(processing == error)
        #expect(recovered == .capturing)
    }

    @Test("An action-required capture failure remains visible")
    func actionRequiredFailureIsVisible() {
        let next = PassageModel.captureState(
            after: .failed("Screen Recording permission is required", disposition: .actionRequired),
            current: .capturing
        )

        #expect(next == .error("Screen Recording permission is required"))
    }

    @Test("A fresh library has an actionable first-memory state")
    func firstMemoryInitialState() {
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 0,
                intent: .paused,
                permissionGranted: true
            ) == .paused
        )
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 0,
                intent: .remembering,
                permissionGranted: true
            ) == .waitingForAnotherApplication
        )
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 0,
                intent: .remembering,
                permissionGranted: false
            ) == .permissionRequired
        )
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 1,
                intent: .paused,
                permissionGranted: false
            ) == .complete
        )
    }

    @Test("First-memory progress resumes unfinished work without replaying a verified celebration")
    func firstMemoryProgressRestoration() {
        let frameID = FrameID(rawValue: "proof-frame")
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 1,
                intent: .paused,
                permissionGranted: false,
                progress: .verified(frameID)
            ) == .complete
        )
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 1,
                intent: .remembering,
                permissionGranted: true,
                progress: .skipped
            ) == .skipped
        )
        #expect(
            FirstMemoryActivationReducer.initial(
                frameCount: 1,
                intent: .remembering,
                permissionGranted: true,
                progress: .awaitingRecall(frameID)
            ) == .preparing
        )
    }

    @Test("The first-memory journey stays visible through explicit success")
    func firstMemoryJourneyVisibility() {
        let candidate = FirstMemoryRecallCandidate(
            frameID: FrameID(rawValue: "journey-frame"),
            query: "launch checklist",
            applicationName: "Notes",
            source: .visibleText
        )
        let visibleStates: [FirstMemoryActivationState] = [
            .preparing,
            .permissionRequired,
            .paused,
            .waitingForAnotherApplication,
            .processing("Notes"),
            .protectedApplication("Passwords"),
            .recallReady(candidate),
            .recallSearching(candidate),
            .recallFailed(candidate, "Try again"),
            .resumeFailed(candidate.frameID, "Resume failed"),
            .verified(candidate.frameID),
            .blocked("Try another app"),
        ]

        for state in visibleStates {
            #expect(state.presentsJourney)
        }
        #expect(!FirstMemoryActivationState.complete.presentsJourney)
        #expect(!FirstMemoryActivationState.skipped.presentsJourney)
    }

    @Test("Guided handoff hides once and requests attention without activation")
    func firstMemoryHandoffEffects() {
        let candidate = FirstMemoryRecallCandidate(
            frameID: FrameID(rawValue: "attention-frame"),
            query: "launch checklist",
            applicationName: "Notes",
            source: .visibleText
        )

        #expect(FirstMemoryHandoffPolicy.shouldHideApplication(
            armed: true,
            alreadyHidden: false,
            state: .waitingForAnotherApplication
        ))
        #expect(!FirstMemoryHandoffPolicy.shouldHideApplication(
            armed: true,
            alreadyHidden: true,
            state: .waitingForAnotherApplication
        ))
        #expect(!FirstMemoryHandoffPolicy.shouldHideApplication(
            armed: false,
            alreadyHidden: false,
            state: .waitingForAnotherApplication
        ))
        #expect(FirstMemoryHandoffPolicy.shouldRequestAttention(
            armed: true,
            from: .processing("Notes"),
            to: .recallReady(candidate)
        ))
        #expect(FirstMemoryHandoffPolicy.shouldRequestAttention(
            armed: true,
            from: .processing("Passwords"),
            to: .protectedApplication("Passwords")
        ))
        #expect(!FirstMemoryHandoffPolicy.shouldRequestAttention(
            armed: false,
            from: .processing("Notes"),
            to: .recallReady(candidate)
        ))
        #expect(FirstMemoryHandoffPolicy.shouldDisarm(state: .complete))
        #expect(FirstMemoryHandoffPolicy.shouldDisarm(state: .skipped))
        #expect(!FirstMemoryHandoffPolicy.shouldDisarm(state: .verified(candidate.frameID)))
    }

    @Test("Resumable progress persists no title, OCR, domain, or query text")
    func firstMemoryProgressStoresOnlyOpaqueIdentity() throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let store = FirstMemoryActivationStore(defaults: fixture.defaults)
        let frameID = FrameID(rawValue: "opaque-frame-id")

        store.save(.awaitingRecall(frameID))

        #expect(store.load() == .awaitingRecall(frameID))
        let data = try #require(
            fixture.defaults.data(forKey: FirstMemoryActivationStore.defaultKey)
        )
        let serialized = String(decoding: data, as: UTF8.self)
        #expect(!serialized.contains("Quarterly roadmap"))
        #expect(!serialized.contains("private.example"))
        #expect(!serialized.contains("Safari"))
    }

    @Test("Suggested recall is deterministic, bounded, and prefers a clean indexed title")
    func firstMemorySuggestionUsesIndexedTitle() throws {
        let frame = FrameDocument(
            id: FrameID(rawValue: "title-proof"),
            capturedAt: Date(timeIntervalSince1970: 1),
            context: ScreenContext(
                applicationName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                windowTitle: "Tomas (DM) — Ambition — 3 new items — Slack"
            ),
            ocrText: "é--> O Q Describedh*wuK knkin8for",
            imageRelativePath: "Media/title-proof.bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 1,
            changeScore: 1
        )

        let first = try #require(FirstMemoryRecallSuggestion.make(for: frame))
        let second = try #require(FirstMemoryRecallSuggestion.make(for: frame))

        #expect(first == second)
        #expect(first.frameID == frame.id)
        #expect(first.source == .windowTitle)
        #expect(first.query == "Tomas DM Ambition Slack")
        #expect(first.query.count <= FirstMemoryRecallSuggestion.maximumQueryCharacters)
        #expect(first.query.split(separator: " ").count <= FirstMemoryRecallSuggestion.maximumQueryTokens)
    }

    @Test("Noisy OCR is rejected in favor of a coherent indexed line")
    func firstMemorySuggestionCleansOCR() throws {
        let frame = FrameDocument(
            id: FrameID(rawValue: "ocr-proof"),
            capturedAt: Date(timeIntervalSince1970: 1),
            context: ScreenContext(applicationName: "Notes"),
            ocrText: "é--> O Q Describedh*wuK knkin8for\nToma5 8 JO PM\nReview the launch checklist tomorrow",
            imageRelativePath: "Media/ocr-proof.bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 1,
            changeScore: 1
        )

        let candidate = try #require(FirstMemoryRecallSuggestion.make(for: frame))

        #expect(candidate.source == .visibleText)
        #expect(candidate.query == "Review launch checklist tomorrow")
        #expect(!candidate.query.contains("Toma5"))
        #expect(!candidate.query.contains("knkin8for"))
    }

    @Test("Passage frontmost is a calm wait rather than a failure")
    func ownApplicationWaitState() {
        let first = FirstMemoryActivationReducer.reduce(
            .preparing,
            event: .started
        )
        let waiting = FirstMemoryActivationReducer.reduce(
            first,
            event: .waitingForExternalApplication(continuous: true)
        )

        #expect(waiting == .waitingForAnotherApplication)
        #expect(
            PassageModel.captureState(
                after: .waitingForExternalApplication(continuous: true),
                current: .capturing
            ) == .capturing
        )
    }

    @Test("The first persisted frame becomes ready exactly once")
    func firstMemoryPersistenceIsSticky() {
        let ready = FirstMemoryActivationReducer.reduce(
            .processing("Notes"),
            event: .persisted(Self.frame, continuous: true)
        )
        let laterFrame = FrameDocument(
            id: FrameID(rawValue: "later-capture"),
            capturedAt: Date(timeIntervalSince1970: 200),
            context: Self.frame.context,
            ocrText: "A later capture",
            imageRelativePath: "Media/later-capture.bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 84,
            changeScore: 1
        )
        let stillReady = FirstMemoryActivationReducer.reduce(
            ready,
            event: .persisted(laterFrame, continuous: true)
        )

        guard case .recallReady(let candidate) = ready else {
            Issue.record("Expected the first persisted frame to await Recall proof")
            return
        }
        #expect(candidate.frameID == Self.frame.id)
        #expect(candidate.query == "One local capture")
        #expect(stillReady == ready)
    }

    @Test("The model reveals the exact first frame without stealing selection later")
    func modelRevealsExactFirstFrameOnce() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let model = PassageModel(
            captureIntentStore: CaptureIntentStore(defaults: fixture.defaults),
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {},
            firstMemoryActivationStore: FirstMemoryActivationStore(defaults: fixture.defaults)
        )
        let laterFrame = FrameDocument(
            id: FrameID(rawValue: "later-capture"),
            capturedAt: Date(timeIntervalSince1970: 200),
            context: Self.frame.context,
            ocrText: "A later capture",
            imageRelativePath: "Media/later-capture.bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 84,
            changeScore: 1
        )

        model.consume(.started)
        model.consume(.processingContext(Self.frame.context, continuous: true))
        model.consume(.persisted(Self.frame, continuous: true))
        #expect(model.selectedHit?.id == Self.frame.id)

        model.consume(.persisted(laterFrame, continuous: true))
        #expect(model.selectedHit?.id == Self.frame.id)
    }

    private static let frame = FrameDocument(
        id: FrameID(rawValue: "manual-capture"),
        capturedAt: Date(timeIntervalSince1970: 100),
        context: ScreenContext(applicationName: "Notes", bundleIdentifier: "com.apple.Notes"),
        ocrText: "One local capture",
        imageRelativePath: "Media/manual-capture.bin",
        pixelWidth: 100,
        pixelHeight: 100,
        visualFingerprint: 42,
        changeScore: 1
    )
}

private final class DefaultsFixture {
    let suiteName = "PassageUITests.capture-intent.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
