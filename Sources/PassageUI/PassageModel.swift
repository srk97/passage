import AppKit
import PassageCapture
import PassageCore
import PassageIntelligence
import PassageService
import PassageStore
import PassageVisualModel
import PassageVisualSearch
import Foundation
import Observation

/// The read/write capabilities Passage's main window needs from its local store.
/// Keeping this boundary explicit also lets async publication rules be exercised
/// without opening the production vault in UI tests.
protocol PassageModelRepository:
    FrameRepository,
    RecallNavigationRepository,
    ActivitySessionRepository {}

extension SQLiteFrameStore: PassageModelRepository {}

struct WebsiteFacetRepairPublication {
    static func canPublish(
        repairedCount: Int,
        expectedGeneration: UUID,
        currentGeneration: UUID,
        sessionIsLocked: Bool,
        repositoryAvailable: Bool
    ) -> Bool {
        repairedCount > 0
            && expectedGeneration == currentGeneration
            && !sessionIsLocked
            && repositoryAvailable
    }
}

private enum FirstMemoryResumeError: LocalizedError {
    case noRetainedMoment

    var errorDescription: String? {
        "No retained moment is available for the recall walkthrough."
    }
}

private enum MemoryLensSearchError: Error {
    case sourceUnavailable
    case unexpectedEvidence
}

private enum ContextHandoffOperationError: LocalizedError {
    case unavailable
    case historyChanged
    case noSafeSources

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Context handoff isn't available while Passage's history is sealed or changing."
        case .historyChanged:
            "History changed after this preview was prepared. Prepare it again before copying."
        case .noSafeSources:
            "This selection has no ordinary, retained sources that Passage can hand off."
        }
    }
}

@MainActor
@Observable
public final class PassageModel {
    public enum RecallBrowserMomentAvailability: Equatable, Sendable {
        case unknown
        case loading
        case available(count: Int)
        case error
    }

    public enum RecallPresentationMode: Equatable {
        case chronological
        case bestMatches
        case savedTextOnly
    }

    public enum RecallSearchMode: Hashable, Sendable {
        case bestMatches
        case savedTextOnly
    }

    public enum VisualUnderstandingState: Equatable {
        case unavailable
        case verifying
        case preparing
        case indexing
        case ready
        case paused
        case error(String)

        public var label: String {
            switch self {
            case .unavailable: "Unavailable"
            case .verifying: "Checking visual search…"
            case .preparing: "Loading visual search…"
            case .indexing: "Indexing saved images…"
            case .ready: "Ready"
            case .paused: "Image indexing paused"
            case .error: "Visual search unavailable"
            }
        }
    }

    public enum CaptureState: Equatable {
        case unavailable
        case locked
        case paused
        case capturing
        case privateContext(String)
        case error(String)

        public var label: String {
            switch self {
            case .unavailable: "Not ready"
            case .locked: "History sealed"
            case .paused: "Paused"
            case .capturing: "Remembering"
            case .privateContext: "Private app — not captured"
            case .error: "Needs attention"
            }
        }
    }

    public enum IntelligenceState: Equatable {
        case notConfigured
        case ready
        case enhancing
        case error(String)

        public var label: String {
            switch self {
            case .notConfigured: "Not configured"
            case .ready: "Ready"
            case .enhancing: "Enhancing session…"
            case .error: "Needs attention"
            }
        }
    }

    public enum SessionQuestionState: Equatable {
        case idle
        case preparing
        case awaitingPrivateConfirmation
        case answering
        case insufficientEvidence
        case error(String)

        public var isWorking: Bool {
            self == .preparing || self == .answering
        }
    }

    public var queryText = ""
    public private(set) var results: [SearchHit] = [] {
        didSet { resultsProjectionGeneration &+= 1 }
    }
    /// SwiftUI re-evaluates result-list bodies far more often than `results`
    /// changes (capture status ticks, hover, drag). Day grouping and timeline
    /// projections are O(n log n) over the whole result set, so they are
    /// memoized against this generation instead of recomputed per body pass.
    @ObservationIgnored private var resultsProjectionGeneration: UInt64 = 0
    @ObservationIgnored private var cachedDayGroups: (generation: UInt64, groups: [RecallDayGroup])?
    @ObservationIgnored private var cachedResultIDs: (generation: UInt64, ids: [FrameID])?
    @ObservationIgnored private var cachedTimelineDayHits: (
        generation: UInt64,
        day: Date,
        hits: [SearchHit]
    )?
    public private(set) var recallSearchMode: RecallSearchMode = .bestMatches
    public private(set) var recallUsesOriginalWording = false
    public private(set) var recallPresentationMode: RecallPresentationMode = .chronological
    public private(set) var visualRecallEvidenceByFrameID: [FrameID: VisualRecallEvidence] = [:]
    public private(set) var visualOnlyRecallFrameIDs: Set<FrameID> = []
    public private(set) var memoryLensSelection: MemoryLensSelectionDescriptor?
    public private(set) var memoryLensQueryImage: CGImage?
    public private(set) var visualSearchIsRefining = false
    public private(set) var visualSearchError: String?
    public private(set) var visualUnderstandingState: VisualUnderstandingState = .unavailable
    public private(set) var visualEmbeddingCoverage: VisualEmbeddingCoverage?
    public private(set) var mediaRevision: UInt64 = 0
    public private(set) var recallScope = RecallScope()
    public private(set) var recallFacets = RecallFacets(applications: [], domains: [])
    public private(set) var recallFacetsAreLoading = false
    public private(set) var recallFacetsError: String?
    public private(set) var recallBrowserMomentAvailability:
        RecallBrowserMomentAvailability = .unknown
    public private(set) var recallHasMore = false
    public private(set) var recallIsLoading = false
    public private(set) var recallIsLoadingMore = false
    public private(set) var recallResultsAreStale = false
    public private(set) var recallQueryInterpretation: RecallQueryInterpretation?
    public private(set) var recallTimeLensBounds: RecallTimeLensBounds?
    public private(set) var recallTimeLensPreview: RecallTimeLensPreview?
    public private(set) var recallTimeLensIsScrubbing = false
    public private(set) var searchError: String?
    public var selectedHit: SearchHit?
    public private(set) var selectedFrame: FrameDocument?
    public private(set) var selectedFrameTextIsImproving = false
    public private(set) var activitySessions: [ActivitySessionSummary] = []
    public var selectedActivitySession: ActivitySessionSummary?
    public private(set) var selectedActivitySessionDetail: ActivitySessionDetail?
    public private(set) var activitySessionError: String?
    public private(set) var selectedSessionEnrichment: SessionEnrichment?
    public var sessionQuestionText = ""
    public private(set) var preparedSessionQuestion: SessionQuestionPreparation?
    public private(set) var selectedSessionQuestionAnswer: SessionQuestionAnswer?
    public private(set) var sessionQuestionState: SessionQuestionState = .idle
    public private(set) var intelligenceState: IntelligenceState = .notConfigured
    public private(set) var openAIAPIKeyConfigured = false
    public private(set) var statistics = StoreStatistics(
        frameCount: 0,
        oldestCapture: nil,
        newestCapture: nil,
        databaseBytes: 0,
        mediaBytes: 0
    )
    public private(set) var captureState: CaptureState = .unavailable
    public private(set) var captureIntent: CaptureIntent = .paused
    public private(set) var firstMemoryActivationState: FirstMemoryActivationState = .preparing
    public private(set) var accessEvents: [AccessEvent] = []
    public private(set) var agentServiceAvailable = false
    public private(set) var agentServiceError: String?
    var contextHandoffState: ContextHandoffState = .idle
    public private(set) var historyDeletionInProgress = false
    public private(set) var historyDeletionError: String?
    public private(set) var privacyPreferences = PrivacyPreferences.default
    public private(set) var rootURL: URL?
    public private(set) var startupError: String?
    public var screenPermissionGranted = false
    public var accessibilityPermissionGranted = false

    @ObservationIgnored private var repository: (any PassageModelRepository)?
    @ObservationIgnored private var vaultKey: VaultKey?
    @ObservationIgnored private var accessRepository: SQLiteAccessEventStore?
    @ObservationIgnored private var mediaStore: MediaStore?
    @ObservationIgnored private var coordinator: CaptureCoordinator?
    @ObservationIgnored private var privacyStore: PrivacyPreferencesStore?
    @ObservationIgnored private var intelligenceCache: SessionIntelligenceCache?
    @ObservationIgnored private var sessionQuestionCache: SessionQuestionCache?
    @ObservationIgnored private var intelligenceSafetyIdentifier: String?
    @ObservationIgnored private var openAIAPIKeyStore = OpenAIAPIKeyStore()
    @ObservationIgnored private var agentAccessPolicy: AgentAccessPolicyController?
    @ObservationIgnored private var agentVisualRecallController: AgentVisualRecallController?
    @ObservationIgnored private var memoryCapsules: (any LocalMemoryCapsuleRetrieving)?
    @ObservationIgnored private var serviceServer: PassageLocalServiceServer?
    @ObservationIgnored private var captureNowTask: Task<Void, Never>?
    @ObservationIgnored private var captureNowOperationID: UUID?
    @ObservationIgnored private var captureControlTask: Task<Void, Never>?
    @ObservationIgnored private var captureControlOperationID: UUID?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var visualBootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var visualIndexTask: Task<Void, Never>?
    @ObservationIgnored private var visualIndexRestartRequested = false
    @ObservationIgnored private var visualIndexPrewarmInProgress = false
    @ObservationIgnored private var visualSearchTask: Task<Void, Never>?
    @ObservationIgnored private var visualSearchOperationID: UUID?
    @ObservationIgnored private var visualRerankTask: Task<Void, Never>?
    @ObservationIgnored private var visualRecallBaseline: VisualRecallBaseline?
    @ObservationIgnored private var memoryLensTask: Task<Void, Never>?
    @ObservationIgnored private var memoryLensOperationID: UUID?
    @ObservationIgnored private var memoryLensReturnContext: MemoryLensReturnContext?
    @ObservationIgnored private var visualGenerationID = UUID()
    @ObservationIgnored private var visualRecallRuntime: (any PassageVisualRecallServing)?
    @ObservationIgnored private var visualBootstrapCandidateRuntime: (any PassageVisualRecallServing)?
    @ObservationIgnored private var visualBootstrapCandidateGeneration: UUID?
    @ObservationIgnored private var recallPageTask: Task<Void, Never>?
    @ObservationIgnored private var recallFacetsTask: Task<Void, Never>?
    @ObservationIgnored private var recallFacetsOperationID: UUID?
    /// Captures arrive every few seconds, but a ranked result list and its
    /// facet counts change meaningfully over minutes. These stamps let
    /// capture-driven refreshes keep the last published ranking and counts
    /// instead of re-running FTS ranking, CoreML reranking, and full
    /// GROUP BY facet aggregation on every saved moment. User-initiated
    /// searches and scope changes bypass them entirely.
    @ObservationIgnored private var rankedCaptureRefreshAt: ContinuousClock.Instant?
    @ObservationIgnored private var visualRerankScheduledAt: ContinuousClock.Instant?
    @ObservationIgnored private var visualRecallServedOperationID: UUID?
    @ObservationIgnored private var recallSurfaceIsDormant = false
    @ObservationIgnored private var sceneIsBackgrounded = false
    /// Starts true so a launch that never creates the main window (menu-bar
    /// use) still refreshes until the window tag reports a real state.
    @ObservationIgnored private var mainWindowIsVisible = true
    /// Pending refresh accumulated while dormant; the Bool is whether any
    /// deferred refresh required a full reload.
    @ObservationIgnored private var dormantCaptureRefresh: Bool?
    @ObservationIgnored private var recallFacetsScheduledAt: ContinuousClock.Instant?
    @ObservationIgnored private var recallFacetsScheduledScope: RecallScope?
    private static let captureDrivenRefreshInterval: Duration = .seconds(30)
    @ObservationIgnored private var recallBaseFacets = RecallFacets()
    @ObservationIgnored private var captureRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var captureRefreshOperationID: UUID?
    @ObservationIgnored private var captureRefreshRequiresFullReload = false
    @ObservationIgnored private var selectedFrameTask: Task<Void, Never>?
    @ObservationIgnored private var selectedFrameOperationID: UUID?
    @ObservationIgnored private var recallTimeLensTask: Task<Void, Never>?
    @ObservationIgnored private var recallTimeLensTaskID: UUID?
    @ObservationIgnored private var recallTimeLensSessionID: UUID?
    @ObservationIgnored private var recallTimeLensRequestSequence: UInt64 = 0
    @ObservationIgnored private var recallTimeLensPendingTarget: Date?
    @ObservationIgnored private var recallTimeLensScope: RecallScope?
    @ObservationIgnored private var recallTimeLensBaselineSelection: SearchHit?
    @ObservationIgnored private var recallTimeLensRecallOperationID: UUID?
    @ObservationIgnored private var recallTimeLensLastSeekStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private let recallTimeLensClock = ContinuousClock()
    @ObservationIgnored private var recallOperationID: UUID?
    @ObservationIgnored private var recallCursor: RecallCursor?
    @ObservationIgnored private var loadedRecallScope: RecallScope?
    @ObservationIgnored private var firstMemoryRecallOperationID: UUID?
    @ObservationIgnored private var firstMemoryResumeOperationID: UUID?
    @ObservationIgnored private var timelineWorkspaceTransaction: TimelineWorkspaceTransaction?
    @ObservationIgnored private var intelligenceTask: Task<Void, Never>?
    @ObservationIgnored private var activitySessionDetailTask: Task<Void, Never>?
    @ObservationIgnored private var accessHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var contextHandoffTask: Task<Void, Never>?
    @ObservationIgnored private var contextHandoffOperationID: UUID?
    @ObservationIgnored private var historyDeletionTask: Task<Void, Never>?
    @ObservationIgnored private var privacyUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var privacyUpdateOperationID: UUID?
    @ObservationIgnored private var sessionQuestionTask: Task<Void, Never>?
    @ObservationIgnored private var sessionQuestionOperationID: UUID?
    @ObservationIgnored private var sessionPrivacyMonitor: SessionPrivacyMonitor?
    @ObservationIgnored private let captureIntentStore: CaptureIntentStore
    @ObservationIgnored private let firstMemoryActivationStore: FirstMemoryActivationStore
    @ObservationIgnored private let screenPermissionStatus: () -> Bool
    @ObservationIgnored private let screenPermissionRequest: () -> Bool
    @ObservationIgnored private let accessibilityPermissionStatus: () -> Bool
    @ObservationIgnored private let accessibilityPermissionRequest: () -> Void
    @ObservationIgnored private var startupVaultOperation: StartupVaultOperation?
    @ObservationIgnored private var startupPreparationTask: Task<PassageStartupResources, Error>?
    @ObservationIgnored private var websiteFacetMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var websiteFacetMaintenanceOperationID: UUID?
    @ObservationIgnored private var sessionIsLocked: Bool
    @ObservationIgnored private var sessionLifecycleGeneration = UUID()
    @ObservationIgnored private var sessionTeardownTask: Task<Void, Never>?
    @ObservationIgnored private var retentionMutationInProgress = false
    @ObservationIgnored private var retentionCommitHandledByBoundary = false
    @ObservationIgnored private let ocrRefinementService: VisionOCRService
    @ObservationIgnored private let contextHandoffClipboard: any ContextHandoffClipboardWriting

    public convenience init() {
        self.init(
            captureIntentStore: CaptureIntentStore(),
            screenPermissionStatus: { ScreenSnapshotService.permissionGranted() },
            screenPermissionRequest: { ScreenSnapshotService.requestPermission() },
            accessibilityPermissionStatus: {
                ActiveContextProvider.accessibilityPermissionGranted()
            },
            accessibilityPermissionRequest: {
                ActiveContextProvider.requestAccessibilityPermission()
            },
            protectedDataAvailable: {
                // AppKit can report `false` for the entire lifetime of an
                // otherwise unlocked, non-sandboxed Developer ID app. Treat
                // that polling result as inconclusive on macOS. Explicit
                // session/screen/protected-data notifications still seal the
                // vault, and real protected-file failures fail closed below.
                true
            }
        )
    }

    init(
        captureIntentStore: CaptureIntentStore,
        screenPermissionStatus: @escaping () -> Bool,
        screenPermissionRequest: @escaping () -> Bool,
        accessibilityPermissionStatus: @escaping () -> Bool,
        accessibilityPermissionRequest: @escaping () -> Void,
        firstMemoryActivationStore: FirstMemoryActivationStore = FirstMemoryActivationStore(),
        protectedDataAvailable: @escaping @MainActor @Sendable () -> Bool = { true },
        repository: (any PassageModelRepository)? = nil,
        mediaStore: MediaStore? = nil,
        ocrRefinementService: VisionOCRService = VisionOCRService(),
        visualRecallRuntime: (any PassageVisualRecallServing)? = nil,
        contextHandoffClipboard: any ContextHandoffClipboardWriting = SystemContextHandoffClipboard()
    ) {
        self.captureIntentStore = captureIntentStore
        self.firstMemoryActivationStore = firstMemoryActivationStore
        self.screenPermissionStatus = screenPermissionStatus
        self.screenPermissionRequest = screenPermissionRequest
        self.accessibilityPermissionStatus = accessibilityPermissionStatus
        self.accessibilityPermissionRequest = accessibilityPermissionRequest
        let initialProtectedDataAvailable = protectedDataAvailable()
        sessionIsLocked = !initialProtectedDataAvailable
        self.repository = repository
        self.mediaStore = mediaStore
        self.ocrRefinementService = ocrRefinementService
        self.visualRecallRuntime = visualRecallRuntime
        self.contextHandoffClipboard = contextHandoffClipboard
        if visualRecallRuntime != nil {
            visualUnderstandingState = .ready
        }
        captureIntent = captureIntentStore.load()
        screenPermissionGranted = screenPermissionStatus()
        accessibilityPermissionGranted = accessibilityPermissionStatus()
        if sessionIsLocked {
            captureState = .locked
        }
        sessionPrivacyMonitor = SessionPrivacyMonitor(
            initialProtectedDataAvailable: initialProtectedDataAvailable,
            protectedDataAvailable: protectedDataAvailable,
            onLock: { [weak self] in
                Task { @MainActor [weak self] in await self?.suspendForSessionLock() }
            },
            onUnlock: { [weak self] in
                Task { @MainActor [weak self] in await self?.resumeAfterSessionUnlock() }
            }
        )
    }

    public func start() async {
        guard repository == nil,
              startupVaultOperation == nil,
              !sessionIsLocked else { return }
        startupError = nil
        let lifecycleGeneration = sessionLifecycleGeneration
        let startupOperation = StartupVaultOperation()
        startupVaultOperation = startupOperation
        let startupTask = Task.detached(priority: .userInitiated) {
            do {
                return try await PassageStartupResources.prepare(
                    operation: startupOperation,
                    vaultKeyStore: KeychainVaultKeyStore(),
                    openAIAPIKeyStore: OpenAIAPIKeyStore()
                )
            } catch {
                startupOperation.revoke()
                throw error
            }
        }
        startupPreparationTask = startupTask
        defer {
            // An old generation may finish after a new startup has already
            // begun. It must never clear the new generation's tracking state.
            if startupVaultOperation === startupOperation {
                startupVaultOperation = nil
                startupPreparationTask = nil
            }
        }

        do {
            let resources = try await startupTask.value
            guard startupCanPublish(
                generation: lifecycleGeneration,
                operation: startupOperation
            ) else {
                startupOperation.revoke()
                return
            }

            let coordinator = CaptureCoordinator(
                media: resources.mediaStore,
                repository: resources.repository,
                policy: resources.privacyPreferences.capturePolicy,
                retentionPolicy: resources.privacyPreferences.retentionPolicy
            )

            // Publication is one synchronous main-actor transaction. Once the
            // candidate is disarmed, the normal session-lock path owns every
            // capability and can revoke it directly.
            guard startupOperation.disarmForPublication() else {
                startupOperation.revoke()
                return
            }
            rootURL = resources.paths.root
            vaultKey = resources.vaultKey
            repository = resources.repository
            accessRepository = resources.accessRepository
            mediaStore = resources.mediaStore
            self.coordinator = coordinator
            privacyStore = resources.privacyStore
            intelligenceCache = resources.intelligenceCache
            sessionQuestionCache = resources.sessionQuestionCache
            intelligenceSafetyIdentifier = resources.intelligenceSafetyIdentifier
            privacyPreferences = resources.privacyPreferences
            switch resources.openAIKeyState {
            case .configured(let configured):
                openAIAPIKeyConfigured = configured
                intelligenceState = configured ? .ready : .notConfigured
            case .failed(let message):
                openAIAPIKeyConfigured = false
                intelligenceState = .error(message)
            }
            let agentAccessPolicy = AgentAccessPolicyController(
                allowedIdentifiers: resources.privacyPreferences.allowedAgentClients
            )
            let agentVisualRecallController = AgentVisualRecallController()
            let memoryCapsules = LocalMemoryCapsuleRuntime(
                frames: resources.repository,
                visualRecall: agentVisualRecallController
            )
            self.agentAccessPolicy = agentAccessPolicy
            self.agentVisualRecallController = agentVisualRecallController
            self.memoryCapsules = memoryCapsules
            startupVaultOperation = nil
            startupPreparationTask = nil

            await coordinator.setEventHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.consume(event)
                }
            }
            await coordinator.setRetentionMutationHandler { [weak self] boundary in
                await self?.consumeRetentionMutationBoundary(boundary)
            }
            guard startupCanContinue(generation: lifecycleGeneration) else { return }

            do {
                let service = PassageLocalServiceServer(
                    endpoint: try PassageServiceEndpoint.live(),
                    handler: PassageCapabilityHandler(
                        frames: resources.repository,
                        audit: resources.accessRepository,
                        accessPolicy: agentAccessPolicy,
                        visualRecall: agentVisualRecallController,
                        memoryCapsules: memoryCapsules
                    )
                )
                try service.start()
                serviceServer = service
                agentServiceAvailable = true
                agentServiceError = nil
            } catch {
                agentServiceAvailable = false
                agentServiceError = error.localizedDescription
            }
            screenPermissionGranted = screenPermissionStatus()
            accessibilityPermissionGranted = accessibilityPermissionStatus()
            captureState = .paused
            let loadedStatistics = try await resources.repository.statistics()
            guard startupCanContinue(generation: lifecycleGeneration) else { return }
            statistics = loadedStatistics
            refreshRecallTimeLensBoundsIfIdle()
            let firstMemoryProgress = firstMemoryActivationStore.load()
            firstMemoryActivationState = FirstMemoryActivationReducer.initial(
                frameCount: statistics.frameCount,
                intent: captureIntent,
                permissionGranted: screenPermissionGranted,
                progress: firstMemoryProgress
            )
            if firstMemoryProgress == nil, statistics.frameCount == 0 {
                firstMemoryActivationStore.save(.pending)
            }
            await restoreFirstMemoryActivationIfNeeded(
                progress: firstMemoryProgress,
                repository: resources.repository,
                generation: lifecycleGeneration
            )
            guard startupCanContinue(generation: lifecycleGeneration) else { return }
            if CaptureLifecycleReducer.initializationDecision(
                intent: captureIntent,
                permissionGranted: screenPermissionGranted
            ) == .start {
                await coordinator.start()
                guard startupCanContinue(generation: lifecycleGeneration) else { return }
            }
            guard startupCanContinue(generation: lifecycleGeneration) else { return }
            await refresh()
            guard startupCanContinue(generation: lifecycleGeneration) else { return }
            scheduleWebsiteFacetMaintenance(
                repository: resources.repository,
                generation: lifecycleGeneration
            )
            scheduleVisualBootstrap(paths: resources.paths)
        } catch is CancellationError {
            startupOperation.revoke()
        } catch {
            startupOperation.revoke()
            guard sessionLifecycleGeneration == lifecycleGeneration else { return }
            if PassageFileProtection.indicatesProtectedDataUnavailable(error) {
                // macOS can briefly report protected data as available before
                // the user's Class-A keybag is actually readable. Keep this a
                // calm, sealed state—not an empty-library or terminal error—
                // and repair the monitor so its next availability event retries.
                sessionPrivacyMonitor?.markProtectedDataUnavailable()
                await suspendForSessionLock()
                return
            }
            guard startupGenerationIsCurrent(lifecycleGeneration) else { return }
            startupError = error.localizedDescription
            captureState = .error(error.localizedDescription)
            firstMemoryActivationState = .blocked(error.localizedDescription)
        }
    }

    private func startupCanPublish(
        generation: UUID,
        operation: StartupVaultOperation
    ) -> Bool {
        !sessionIsLocked
            && sessionLifecycleGeneration == generation
            && repository == nil
            && startupVaultOperation === operation
    }

    private func startupCanContinue(generation: UUID) -> Bool {
        startupGenerationIsCurrent(generation)
            && repository != nil
    }

    private func startupGenerationIsCurrent(_ generation: UUID) -> Bool {
        !sessionIsLocked && sessionLifecycleGeneration == generation
    }

    private func scheduleWebsiteFacetMaintenance(
        repository: SQLiteFrameStore,
        generation: UUID
    ) {
        websiteFacetMaintenanceTask?.cancel()
        let operationID = UUID()
        websiteFacetMaintenanceOperationID = operationID
        websiteFacetMaintenanceTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.finishWebsiteFacetMaintenance(operationID) }
            do {
                let repairedCount = try await PassageStartupMaintenance
                    .repairWebsiteFacets(repository: repository)
                guard !Task.isCancelled,
                      WebsiteFacetRepairPublication.canPublish(
                        repairedCount: repairedCount,
                        expectedGeneration: generation,
                        currentGeneration: self.sessionLifecycleGeneration,
                        sessionIsLocked: self.sessionIsLocked,
                        repositoryAvailable: self.repository != nil
                      ) else { return }
                self.refreshRecallFacetsAfterWebsiteRepair(
                    repairedCount: repairedCount,
                    repository: repository
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.sessionLifecycleGeneration == generation,
                      !self.sessionIsLocked else { return }
                PassageStartupMaintenance.reportWebsiteFacetRepairFailure()
            }
        }
    }

    func refreshRecallFacetsAfterWebsiteRepair(
        repairedCount: Int,
        repository: any PassageModelRepository
    ) {
        guard repairedCount > 0,
              let scope = loadedRecallScope,
              let recallOperationID else { return }
        if let descriptor = memoryLensSelection {
            _ = scheduleMemoryLens(descriptor: descriptor, scope: scope)
            return
        }
        scheduleRecallFacets(
            scope: scope,
            expectedLoadedScope: scope,
            recallOperationID: recallOperationID,
            repository: repository
        )
    }

    private func finishWebsiteFacetMaintenance(_ operationID: UUID) {
        guard websiteFacetMaintenanceOperationID == operationID else { return }
        websiteFacetMaintenanceTask = nil
        websiteFacetMaintenanceOperationID = nil
    }

    public func requestScreenPermission() {
        screenPermissionGranted = screenPermissionRequest()
        reconcileFirstMemoryActivationState()
    }

    public func requestAccessibilityPermission() {
        accessibilityPermissionRequest()
        accessibilityPermissionGranted = accessibilityPermissionStatus()
    }

    public func refreshPermissions() {
        let previouslyGranted = screenPermissionGranted
        screenPermissionGranted = screenPermissionStatus()
        accessibilityPermissionGranted = accessibilityPermissionStatus()
        reconcileFirstMemoryActivationState()

        let decision = CaptureLifecycleReducer.permissionRefreshDecision(
            intent: captureIntent,
            coordinatorInitialized: coordinator != nil,
            previouslyGranted: previouslyGranted,
            permissionGranted: screenPermissionGranted
        )
        guard let coordinator else { return }
        switch decision {
        case .none:
            break
        case .start:
            scheduleCaptureControl(.remembering, coordinator: coordinator)
        case .pause:
            cancelCaptureNow()
            scheduleCaptureControl(.paused, coordinator: coordinator)
        }
    }

    @discardableResult
    public func startCapturing() -> StartCaptureOutcome {
        guard !historyDeletionInProgress, !sessionIsLocked else {
            return .pendingInitialization
        }
        captureIntent = .remembering
        captureIntentStore.save(.remembering)
        let outcome = CaptureLifecycleReducer.startOutcome(
            coordinatorInitialized: coordinator != nil,
            permissionGranted: screenPermissionGranted
        )
        if statistics.frameCount == 0,
           firstMemoryActivationState.readyFrameID == nil,
           !firstMemoryActivationState.isTerminal {
            switch outcome {
            case .started:
                firstMemoryActivationState = .waitingForAnotherApplication
            case .pendingInitialization:
                firstMemoryActivationState = .preparing
            case .permissionRequired:
                firstMemoryActivationState = .permissionRequired
            }
        }
        guard outcome == .started, let coordinator else { return outcome }
        scheduleCaptureControl(.remembering, coordinator: coordinator)
        return outcome
    }

    public func pauseCapturing() {
        captureIntent = .paused
        captureIntentStore.save(.paused)
        cancelCaptureNow()
        if statistics.frameCount == 0,
           firstMemoryActivationState.readyFrameID == nil,
           !firstMemoryActivationState.isTerminal {
            firstMemoryActivationState = screenPermissionGranted ? .paused : .permissionRequired
        }
        guard let coordinator else { return }
        scheduleCaptureControl(.paused, coordinator: coordinator)
    }

    /// Honors the onboarding promise to open the normal workspace without
    /// requesting access or immediately presenting the first-memory coach.
    /// This is a durable opt-out from that one-time guided proof, not merely a
    /// transient capture pause. It never grants permission or changes history.
    public func openPausedExploration() {
        pauseCapturing()
        guard firstMemoryActivationState.presentsJourney else { return }
        firstMemoryRecallOperationID = nil
        firstMemoryResumeOperationID = nil
        firstMemoryActivationStore.save(.skipped)
        firstMemoryActivationState = .skipped
    }

    public func toggleCapture() {
        // The model may queue durable remembering intent before runtime setup;
        // only destructive deletion and a locked session reject the action.
        guard !historyDeletionInProgress, !sessionIsLocked else { return }
        switch captureIntent {
        case .remembering:
            pauseCapturing()
        case .paused:
            startCapturing()
        }
    }

    public func captureNow() {
        guard captureControlsEnabled, let coordinator else { return }
        cancelCaptureNow()
        let operationID = UUID()
        captureNowOperationID = operationID
        captureNowTask = Task {
            defer {
                if captureNowOperationID == operationID {
                    captureNowTask = nil
                    captureNowOperationID = nil
                }
            }
            do {
                let frame = try await coordinator.captureNow()
                guard captureNowCanPublish(operationID, coordinator: coordinator) else { return }
                if frame != nil {
                    scheduleCaptureRefresh(debounce: nil)
                }
            } catch is CancellationError {
                return
            } catch {
                guard captureNowCanPublish(operationID, coordinator: coordinator) else { return }
                captureState = .error(error.localizedDescription)
            }
        }
    }

    /// Runs the same local Recall pipeline as the main search field, but arms a
    /// one-time proof that can complete only when the exact persisted frame is
    /// present in the published result set.
    public func searchFirstMemorySuggestion() {
        guard !sessionIsLocked,
              !historyDeletionInProgress,
              repository != nil,
              let candidate = firstMemoryActivationState.recallCandidate else { return }
        firstMemoryActivationStore.save(.awaitingRecall(candidate.frameID))
        firstMemoryActivationState = .recallSearching(candidate)
        queryText = candidate.query
        let scheduled = scheduleRecall(
            scope: RecallScope(text: candidate.query),
            debounce: nil,
            allowsInterpretation: false
        )
        firstMemoryRecallOperationID = scheduled.operationID
    }

    public func retryFirstMemoryActivation() {
        switch firstMemoryActivationState {
        case .recallFailed:
            searchFirstMemorySuggestion()
        case .resumeFailed(let frameID, _):
            if let frameID {
                restoreFirstMemoryActivation(frameID: frameID)
            } else {
                restorePendingFirstMemoryActivation()
            }
        default:
            break
        }
    }

    /// Leaves the one-time success surface only after the exact persisted frame
    /// has been returned by normal Recall. Durable progress intentionally stays
    /// `.verified`; it is the evidence that prevents replay on a later launch.
    @discardableResult
    public func finishFirstMemoryActivationJourney() -> Bool {
        guard case .verified = firstMemoryActivationState else { return false }
        firstMemoryActivationState = .complete
        return true
    }

    /// Skip is explicit and durable. It changes neither capture permission nor
    /// Remembering intent and never deletes or rewrites history.
    public func skipFirstMemoryActivation() {
        switch firstMemoryActivationState {
        case .recallReady, .recallSearching, .recallFailed, .resumeFailed:
            firstMemoryRecallOperationID = nil
            firstMemoryResumeOperationID = nil
            firstMemoryActivationStore.save(.skipped)
            firstMemoryActivationState = .skipped
        default:
            break
        }
    }

    private func restoreFirstMemoryActivationIfNeeded(
        progress: FirstMemoryActivationProgress?,
        repository: any PassageModelRepository,
        generation: UUID
    ) async {
        do {
            switch progress {
            case .awaitingRecall(let frameID):
                let frame = try await repository.frame(id: frameID)
                guard startupCanContinue(generation: generation) else { return }
                guard let frame,
                      let candidate = FirstMemoryRecallSuggestion.make(for: frame) else {
                    firstMemoryActivationState = .resumeFailed(
                        frameID,
                        "That saved moment is not available to search right now. Its proof can be retried or skipped."
                    )
                    return
                }
                firstMemoryActivationState = .recallReady(candidate)
                select(Self.searchHit(for: frame))
            case .pending where statistics.frameCount > 0:
                // A process can terminate after the encrypted insert commits
                // but before its capture event reaches the UI. Recover the
                // oldest retained boundary rather than falsely declaring the
                // proof complete on relaunch.
                guard let oldestCapture = statistics.oldestCapture else { return }
                let scope = RecallScope(
                    endDate: oldestCapture.addingTimeInterval(0.001)
                )
                let page = try await repository.recall(scope, after: nil, limit: 1)
                guard startupCanContinue(generation: generation) else { return }
                guard let hit = page.hits.first,
                      let candidate = FirstMemoryRecallSuggestion.make(for: hit) else {
                    firstMemoryActivationState = .resumeFailed(
                        nil,
                        "Passage found saved history but could not prepare a safe recall phrase. You can retry or skip this walkthrough."
                    )
                    return
                }
                firstMemoryActivationStore.save(.awaitingRecall(hit.id))
                firstMemoryActivationState = .recallReady(candidate)
                select(hit)
            default:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            guard startupCanContinue(generation: generation) else { return }
            let frameID: FrameID?
            if case .awaitingRecall(let persistedID) = progress {
                frameID = persistedID
            } else {
                frameID = nil
            }
            firstMemoryActivationState = .resumeFailed(
                frameID,
                "Passage could not reopen the saved moment yet: \(error.localizedDescription)"
            )
        }
    }

    private func restoreFirstMemoryActivation(frameID: FrameID) {
        guard !sessionIsLocked,
              !historyDeletionInProgress,
              let repository else { return }
        let operationID = UUID()
        firstMemoryResumeOperationID = operationID
        firstMemoryActivationState = .preparing
        Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await repository.frame(id: frameID)
                guard self.firstMemoryResumeOperationID == operationID,
                      !self.sessionIsLocked,
                      !self.historyDeletionInProgress else { return }
                self.firstMemoryResumeOperationID = nil
                guard let frame,
                      let candidate = FirstMemoryRecallSuggestion.make(for: frame) else {
                    self.firstMemoryActivationState = .resumeFailed(
                        frameID,
                        "That saved moment is not available to search right now. Its proof can be retried or skipped."
                    )
                    return
                }
                self.firstMemoryActivationStore.save(.awaitingRecall(frameID))
                self.firstMemoryActivationState = .recallReady(candidate)
                self.select(Self.searchHit(for: frame))
            } catch is CancellationError {
                return
            } catch {
                guard self.firstMemoryResumeOperationID == operationID,
                      !self.sessionIsLocked,
                      !self.historyDeletionInProgress else { return }
                self.firstMemoryResumeOperationID = nil
                self.firstMemoryActivationState = .resumeFailed(
                    frameID,
                    "Passage could not reopen the saved moment yet: \(error.localizedDescription)"
                )
            }
        }
    }

    private func restorePendingFirstMemoryActivation() {
        guard !sessionIsLocked,
              !historyDeletionInProgress,
              let repository else { return }
        let operationID = UUID()
        firstMemoryResumeOperationID = operationID
        firstMemoryActivationState = .preparing
        Task { [weak self] in
            guard let self else { return }
            do {
                let statistics = try await repository.statistics()
                guard let oldestCapture = statistics.oldestCapture else {
                    throw FirstMemoryResumeError.noRetainedMoment
                }
                let page = try await repository.recall(
                    RecallScope(endDate: oldestCapture.addingTimeInterval(0.001)),
                    after: nil,
                    limit: 1
                )
                guard self.firstMemoryResumeOperationID == operationID,
                      !self.sessionIsLocked,
                      !self.historyDeletionInProgress else { return }
                self.firstMemoryResumeOperationID = nil
                guard let hit = page.hits.first,
                      let candidate = FirstMemoryRecallSuggestion.make(for: hit) else {
                    self.firstMemoryActivationState = .resumeFailed(
                        nil,
                        "Passage could not prepare a safe recall phrase from the retained moment. You can retry or skip this walkthrough."
                    )
                    return
                }
                self.firstMemoryActivationStore.save(.awaitingRecall(hit.id))
                self.firstMemoryActivationState = .recallReady(candidate)
                self.select(hit)
            } catch is CancellationError {
                return
            } catch {
                guard self.firstMemoryResumeOperationID == operationID,
                      !self.sessionIsLocked,
                      !self.historyDeletionInProgress else { return }
                self.firstMemoryResumeOperationID = nil
                self.firstMemoryActivationState = .resumeFailed(
                    nil,
                    "Passage could not reopen the saved moment yet: \(error.localizedDescription)"
                )
            }
        }
    }

    private func cancelCaptureNow() {
        captureNowTask?.cancel()
        captureNowTask = nil
        captureNowOperationID = nil
    }

    private func captureNowCanPublish(
        _ operationID: UUID,
        coordinator expectedCoordinator: CaptureCoordinator
    ) -> Bool {
        !Task.isCancelled
            && !sessionIsLocked
            && !historyDeletionInProgress
            && captureNowOperationID == operationID
            && coordinator === expectedCoordinator
    }

    public var captureControlsEnabled: Bool {
        screenPermissionGranted
            && captureState != .unavailable
            && !historyDeletionInProgress
            && !sessionIsLocked
    }

    public var historyIsSealed: Bool {
        captureState == .locked
    }

    private func scheduleCaptureControl(
        _ intendedState: CaptureIntent,
        coordinator expectedCoordinator: CaptureCoordinator
    ) {
        captureControlTask?.cancel()
        let operationID = UUID()
        captureControlOperationID = operationID
        captureControlTask = Task {
            defer {
                if captureControlOperationID == operationID {
                    captureControlTask = nil
                    captureControlOperationID = nil
                }
            }
            guard !Task.isCancelled,
                  captureControlOperationID == operationID,
                  coordinator === expectedCoordinator,
                  !sessionIsLocked else { return }
            switch intendedState {
            case .remembering:
                guard captureIntent == .remembering,
                      !historyDeletionInProgress else { return }
                await expectedCoordinator.start(respectingCallerCancellation: true)
            case .paused:
                await expectedCoordinator.pause(respectingCallerCancellation: true)
            }
        }
    }

    private func cancelCaptureControl() {
        captureControlTask?.cancel()
        captureControlTask = nil
        captureControlOperationID = nil
    }

    public func setCaptureInterval(milliseconds: Int) {
        updatePrivacyPreferences { $0.captureIntervalMilliseconds = milliseconds }
    }

    public func setUnchangedHeartbeat(seconds: Int) {
        updatePrivacyPreferences { $0.unchangedHeartbeatSeconds = seconds }
    }

    public func setRetention(days: Int) {
        updatePrivacyPreferences { $0.retentionDays = days }
    }

    public func setStorageLimit(gigabytes: Int) {
        updatePrivacyPreferences { $0.maximumStorageGigabytes = gigabytes }
    }

    public func setPreserveTextAfterImageExpiry(_ preserve: Bool) {
        updatePrivacyPreferences { $0.preserveTextAfterImageExpiry = preserve }
    }

    public func setHideCursor(_ hidden: Bool) {
        updatePrivacyPreferences { $0.hideCursor = hidden }
    }

    public func setCaptureFocusedWindowOnly(_ focusedWindowOnly: Bool) {
        updatePrivacyPreferences { $0.captureFocusedWindowOnly = focusedWindowOnly }
    }

    public func setPauseAfterInactivity(minutes: Int) {
        updatePrivacyPreferences { $0.pauseAfterInactivityMinutes = minutes }
    }

    public func addApplicationExclusion(at url: URL) {
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else {
            startupError = "That application does not expose a bundle identifier."
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        updatePrivacyPreferences {
            $0.addApplication(ApplicationExclusion(bundleIdentifier: identifier, displayName: name))
        }
    }

    public func removeApplicationExclusion(_ exclusion: ApplicationExclusion) {
        updatePrivacyPreferences {
            $0.excludedApplications.removeAll { $0.bundleIdentifier == exclusion.bundleIdentifier }
        }
    }

    @discardableResult
    public func addDomainExclusion(_ domain: String) -> Bool {
        guard PrivacyPreferences.normalizedDomain(domain) != nil else { return false }
        updatePrivacyPreferences { $0.addDomain(domain) }
        return true
    }

    public func removeDomainExclusion(_ domain: String) {
        updatePrivacyPreferences { $0.excludedDomains.removeAll { $0 == domain } }
    }

    public func setAgentClient(_ identifier: String, allowed: Bool) {
        updatePrivacyPreferences { $0.setAgentClient(identifier, allowed: allowed) }
    }

    public func scheduleSearch() {
        recallUsesOriginalWording = false
        if memoryLensSelection != nil {
            // Clearing the text field is part of entering Memory Lens. A later
            // non-empty edit is an explicit switch back to ordinary Recall.
            guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            cancelMemoryLens(clearReturnContext: true)
        }
        scheduleRecall(
            scope: currentRecallScope(text: queryText),
            debounce: .milliseconds(75),
            allowsInterpretation: true
        )
    }

    /// Owns text-field edits so query publication and Recall scheduling remain
    /// one model transition. Programmatic query canonicalization intentionally
    /// writes `queryText` directly and schedules its already-materialized scope
    /// once, without relying on a view observation callback.
    public func setRecallQueryText(_ text: String) {
        guard queryText != text else { return }
        queryText = text
        scheduleSearch()
    }

    public var memoryLensCanStart: Bool {
        guard !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              visualRecallRuntime != nil,
              let selectedHit,
              let selectedFrame,
              selectedFrame.id == selectedHit.id,
              !selectedFrame.context.isSensitive,
              !selectedFrame.imageRelativePath.isEmpty else { return false }
        switch visualUnderstandingState {
        case .ready, .indexing, .paused:
            return true
        case .unavailable, .verifying, .preparing, .error:
            return false
        }
    }

    /// Uses a selected, retained part of one remembered image as an ephemeral
    /// appearance query. Passage never writes the crop and never interprets
    /// the result as an object or person identity claim.
    public func findSimilarMoments(
        to source: SearchHit,
        within bounds: NormalizedVisualRegionBounds
    ) {
        guard memoryLensCanStart,
              selectedHit?.id == source.id,
              let frame = selectedFrame,
              frame.id == source.id else { return }

        let sourceScope = effectiveRecallFilterScope
        if memoryLensSelection == nil {
            memoryLensReturnContext = MemoryLensReturnContext(
                queryText: queryText,
                scope: sourceScope,
                selectedHit: source
            )
        }
        let descriptor = MemoryLensSelectionDescriptor(
            sourceFrameID: frame.id,
            sourceVisualFingerprint: frame.visualFingerprint,
            bounds: bounds
        )
        if memoryLensSelection != descriptor {
            memoryLensQueryImage = nil
        }
        memoryLensSelection = descriptor
        // Publish the descriptor before clearing the field so this remains an
        // explicit programmatic transition into Memory Lens, not a text edit.
        queryText = ""
        _ = scheduleMemoryLens(
            descriptor: descriptor,
            scope: metadataOnlyScope(from: sourceScope)
        )
    }

    /// Leaves Memory Lens, restoring the prior text query while preserving any
    /// time, app, or website filters changed during visual exploration.
    public func clearMemoryLens() {
        guard memoryLensSelection != nil || memoryLensReturnContext != nil else { return }
        let returnContext = memoryLensReturnContext
        cancelMemoryLens(clearReturnContext: true)
        guard !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              let returnContext else { return }
        let currentMetadata = metadataOnlyScope(from: recallScope)
        queryText = returnContext.queryText
        let restoredScope = RecallScope(
            text: returnContext.queryText,
            startDate: currentMetadata.startDate,
            endDate: currentMetadata.endDate,
            applicationBundleIdentifiers: currentMetadata.applicationBundleIdentifiers,
            domains: currentMetadata.domains
        )
        let scheduled = scheduleRecall(
            scope: restoredScope,
            debounce: nil,
            allowsInterpretation: !recallUsesOriginalWording
        )
        let priorSelectionID = returnContext.selectedHit?.id
        // Do not expose a pre-Lens selection under filters that may now exclude
        // it. Restore only from the authoritative results that actually publish
        // for the new generation.
        select(nil)
        if let priorSelectionID {
            Task { @MainActor [weak self] in
                await scheduled.task.value
                guard let self,
                      !self.sessionIsLocked,
                      self.recallOperationID == scheduled.operationID,
                      let current = self.results.first(where: {
                        $0.id == priorSelectionID
                      }) else { return }
                self.select(current)
            }
        }
        // Keep the task alive through this run-loop turn even if a view update
        // schedules the same query again; normal Recall's generation gate makes
        // either ordering safe.
        _ = scheduled
    }

    public func setRecallSearchMode(_ mode: RecallSearchMode) {
        guard recallSearchMode != mode else { return }
        recallSearchMode = mode
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        scheduleRecall(
            scope: currentRecallScope(text: queryText),
            debounce: nil,
            allowsInterpretation: !recallUsesOriginalWording
        )
    }

    public func searchOriginalWording() {
        recallUsesOriginalWording = true
        scheduleRecall(
            scope: currentRecallScope(text: queryText),
            debounce: nil,
            allowsInterpretation: false
        )
    }

    public var hasRecallFilters: Bool {
        effectiveRecallFilterScope.startDate != nil
            || effectiveRecallFilterScope.endDate != nil
            || !effectiveRecallFilterScope.applicationBundleIdentifiers.isEmpty
            || !effectiveRecallFilterScope.domains.isEmpty
    }

    public var activeRecallFilterCount: Int {
        let scope = effectiveRecallFilterScope
        return (scope.startDate != nil || scope.endDate != nil ? 1 : 0)
            + scope.applicationBundleIdentifiers.count
            + scope.domains.count
    }

    /// The concrete scope represented by Recall's controls. A temporal suffix
    /// is visible and editable as soon as its interpretation publishes, while
    /// `recallScope` continues to preserve the user's original wording for the
    /// “Use original wording” escape hatch.
    public var effectiveRecallFilterScope: RecallScope {
        guard memoryLensSelection == nil,
              let recallQueryInterpretation else { return recallScope }
        return Self.applying(recallQueryInterpretation, to: recallScope)
    }

    public var recallTimeLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        let scope = effectiveRecallFilterScope
        switch (scope.startDate, scope.endDate) {
        case (nil, nil):
            return "Any time"
        case let (start?, end?):
            let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            if calendar.isDate(start, inSameDayAs: inclusiveEnd) {
                if calendar.isDateInToday(start) { return "Today" }
                if calendar.isDateInYesterday(start) { return "Yesterday" }
                return start.formatted(date: .abbreviated, time: .omitted)
            }
            return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(inclusiveEnd.formatted(date: .abbreviated, time: .omitted))"
        case let (start?, nil):
            return "Since \(start.formatted(date: .abbreviated, time: .omitted))"
        case let (nil, end?):
            let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            return "Through \(inclusiveEnd.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    public func setRecallLastDays(_ dayCount: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(
            byAdding: .day,
            value: -(max(dayCount, 1) - 1),
            to: today
        ), let end = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        replaceRecallTime(startDate: start, endDate: end)
    }

    public func setRecallDay(_ day: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        replaceRecallTime(startDate: start, endDate: end)
    }

    public func setRecallCalendarRange(startingAt firstDay: Date, through lastDay: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let first = calendar.startOfDay(for: min(firstDay, lastDay))
        let last = calendar.startOfDay(for: max(firstDay, lastDay))
        guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        replaceRecallTime(startDate: first, endDate: exclusiveEnd)
    }

    public func clearRecallTimeScope() {
        replaceRecallTime(startDate: nil, endDate: nil)
    }

    public func toggleRecallApplication(_ bundleIdentifier: String) {
        var applications = effectiveRecallFilterScope.applicationBundleIdentifiers
        if applications.contains(bundleIdentifier) {
            applications.remove(bundleIdentifier)
        } else {
            applications.insert(bundleIdentifier)
        }
        replaceRecallApplications(applications)
    }

    public func toggleRecallDomain(_ domain: String) {
        var domains = effectiveRecallFilterScope.domains
        if domains.contains(domain) {
            domains.remove(domain)
        } else {
            domains.insert(domain)
        }
        replaceRecallDomains(domains)
    }

    public func clearRecallFilters() {
        let base = materializeRecallInterpretationForFilterMutation()
        replaceRecallMetadata(
            startDate: nil,
            endDate: nil,
            applicationBundleIdentifiers: [],
            domains: [],
            allowsInterpretation: base.allowsInterpretation
        )
    }

    /// Opens Timeline as a reversible workspace instead of silently reusing
    /// Everything's text and source filters. Repeated appearances are
    /// idempotent and repair the day-only invariant without replacing the
    /// original snapshot.
    @discardableResult
    public func enterTimelineWorkspace(preferredDay: Date? = nil) -> Date {
        if let transaction = timelineWorkspaceTransaction {
            enforceTimelineWorkspaceScope(transaction.day)
            return transaction.day
        }

        // Timeline is reversible, while an image crop is intentionally
        // query-lifetime only. Reconstruct Everything before taking Timeline's
        // snapshot so leaving Timeline never returns to an unrepeatable blank
        // visual state.
        if let returnContext = memoryLensReturnContext {
            let currentMetadata = metadataOnlyScope(from: recallScope)
            cancelMemoryLens(clearReturnContext: true)
            queryText = returnContext.queryText
            recallScope = RecallScope(
                text: returnContext.queryText,
                startDate: currentMetadata.startDate,
                endDate: currentMetadata.endDate,
                applicationBundleIdentifiers: currentMetadata.applicationBundleIdentifiers,
                domains: currentMetadata.domains
            )
            if let selectedHit = returnContext.selectedHit {
                select(selectedHit)
            }
        }

        let visibleSelection = selectedHit.flatMap { selectedHit in
            results.contains(where: { $0.id == selectedHit.id })
                ? selectedHit
                : nil
        }
        let day = TimelineWorkspaceScope.initialDay(
            preferredDay: preferredDay,
            visibleSelectionDate: visibleSelection?.capturedAt,
            recallScope: recallScope,
            newestCapture: statistics.newestCapture,
            now: Date()
        )
        let dayScope = TimelineWorkspaceScope.dayScope(for: day)
        let anchor = visibleSelection.flatMap { selection in
            TimelineWorkspaceScope.contains(selection.capturedAt, in: dayScope)
                ? selection
                : nil
        }
        timelineWorkspaceTransaction = TimelineWorkspaceTransaction(
            everythingQueryText: queryText,
            everythingScope: effectiveRecallFilterScope,
            day: day,
            anchor: anchor
        )
        enforceTimelineWorkspaceScope(day)
        return day
    }

    /// Changes only Timeline's calendar day. Text, application, and website
    /// constraints cannot leak into this workspace even if another UI action
    /// schedules Recall while Timeline is visible.
    public func setTimelineWorkspaceDay(_ day: Date) {
        guard var transaction = timelineWorkspaceTransaction else { return }
        let normalizedDay = TimelineWorkspaceScope.startOfDay(for: day)
        transaction.day = normalizedDay
        transaction.anchor = nil
        timelineWorkspaceTransaction = transaction
        enforceTimelineWorkspaceScope(normalizedDay)
    }

    /// A normal workspace exit reconstructs the exact query and visible scope
    /// that Everything had at entry. The fresh Recall generation cancels any
    /// late day read before it can publish.
    public func exitTimelineWorkspace() {
        guard let transaction = timelineWorkspaceTransaction else { return }
        timelineWorkspaceTransaction = nil
        queryText = transaction.everythingQueryText
        scheduleRecall(
            scope: transaction.everythingScope,
            debounce: nil,
            allowsInterpretation: !recallUsesOriginalWording
        )
    }

    /// “Open details” is a deliberate commit rather than a normal exit: the
    /// clean day scope remains active in Everything so the chosen moment stays
    /// in the visible result stream.
    public func commitTimelineWorkspaceForOpeningMoment() {
        guard timelineWorkspaceTransaction != nil else { return }
        cancelRecallTimeLensScrub()
        timelineWorkspaceTransaction = nil
        queryText = ""
    }

    public func loadEarlierRecall() {
        loadRecallPages(untilExhausted: false)
    }

    /// Timeline is a day browser, not a 60-row search result. Once its first
    /// page is visible, progressively walk the remaining cursor so the rail
    /// represents the activity that was actually saved on that day. The
    /// existing page task remains the single owner of the cursor, and every
    /// publication merges with the current head so captures arriving while the
    /// walk is in flight are retained.
    public func loadCompleteTimelineDay() {
        guard timelineWorkspaceTransaction != nil else { return }
        loadRecallPages(untilExhausted: true)
    }

    private func loadRecallPages(untilExhausted: Bool) {
        guard !recallIsLoading,
              !recallIsLoadingMore,
              recallPresentationMode == .chronological,
              recallHasMore,
              let repository,
              let cursor = recallCursor,
              let scope = loadedRecallScope,
              let operationID = recallOperationID else { return }

        recallPageTask?.cancel()
        recallIsLoadingMore = true
        recallPageTask = Task {
            defer {
                if recallOperationID == operationID {
                    recallIsLoadingMore = false
                    recallPageTask = nil
                }
            }
            do {
                var pageCursor = cursor
                while true {
                    let page = try await repository.recall(
                        scope,
                        after: pageCursor,
                        limit: untilExhausted ? RecallPage.maximumLimit : 60
                    )
                    guard !Task.isCancelled,
                          recallOperationID == operationID,
                          loadedRecallScope == scope,
                          !untilExhausted || timelineWorkspaceScopeMatches(scope) else { return }
                    let publishedHits = Self.mergingNewestRecallPage(page.hits, into: results)
                    results = publishedHits
                    reconcileRecallSelection(afterPublishing: publishedHits)
                    recallCursor = page.nextCursor
                    recallHasMore = page.hasMore
                    searchError = nil

                    guard untilExhausted, page.hasMore else { break }
                    guard let nextCursor = page.nextCursor,
                          nextCursor != pageCursor else {
                        // A malformed repository page must not create an
                        // unbounded background loop. Keep `hasMore` truthful
                        // so a later retry remains available.
                        break
                    }
                    pageCursor = nextCursor
                    await Task.yield()
                }
            } catch {
                guard !Task.isCancelled, recallOperationID == operationID else { return }
                searchError = error.localizedDescription
            }
        }
    }

    private func timelineWorkspaceScopeMatches(_ scope: RecallScope) -> Bool {
        guard let transaction = timelineWorkspaceTransaction else { return false }
        return TimelineWorkspaceScope.dayScope(for: transaction.day) == scope
    }

    /// Retries the optional filter-count read without disturbing the memories
    /// that are already visible. Facets are a secondary affordance, so their
    /// failure and recovery remain independent from primary Recall.
    public func retryRecallFacets() {
        guard !recallIsLoading,
              !recallFacetsAreLoading,
              let repository,
              let scope = loadedRecallScope,
              let operationID = recallOperationID else { return }
        scheduleRecallFacets(
            scope: scope,
            expectedLoadedScope: scope,
            recallOperationID: operationID,
            repository: repository
        )
    }

    /// Freezes the currently loaded Recall scope and retained time bounds for
    /// one direct-manipulation gesture. The bounds remain stable even if a new
    /// capture arrives before the pointer is released.
    @discardableResult
    public func beginRecallTimeLensScrub() -> RecallTimeLensBounds? {
        if recallTimeLensIsScrubbing {
            return recallTimeLensBounds
        }
        guard !recallIsLoading,
              repository != nil,
              let scope = loadedRecallScope,
              let bounds = RecallTimeLensBounds.make(
                statistics: statistics,
                scope: scope
              ) else { return nil }

        invalidateRecallTimeLens(restoreBaseline: false)
        let sessionID = UUID()
        recallTimeLensSessionID = sessionID
        recallTimeLensScope = scope
        recallTimeLensRecallOperationID = recallOperationID
        recallTimeLensBaselineSelection = selectedHit
        recallTimeLensLastSeekStartedAt = nil
        recallTimeLensBounds = bounds
        recallTimeLensIsScrubbing = true
        // A selection may have been made by an older scope or from an arbitrary
        // Time Lens seek outside the currently loaded page. Use it as the first
        // preview only when the active result stream proves it belongs here;
        // the baseline is retained separately for explicit cancel semantics.
        if let selectedHit,
           results.contains(where: { $0.id == selectedHit.id }),
           selectedHit.capturedAt >= bounds.oldest,
           selectedHit.capturedAt <= bounds.newest {
            recallTimeLensPreview = RecallTimeLensPreview(
                requestedAt: bounds.clamped(selectedHit.capturedAt),
                hit: selectedHit,
                resolution: .resolved
            )
        } else {
            recallTimeLensPreview = nil
        }
        return bounds
    }

    /// Coalesces high-frequency pointer updates into at most one local seek per
    /// 80 ms. Track position can still update every frame in the view.
    public func previewRecallTimeLens(at requestedDate: Date) {
        guard recallTimeLensIsScrubbing,
              let bounds = recallTimeLensBounds,
              let sessionID = recallTimeLensSessionID else { return }
        let target = bounds.clamped(requestedDate)
        recallTimeLensRequestSequence &+= 1
        recallTimeLensPendingTarget = target
        recallTimeLensPreview = RecallTimeLensPreview(
            requestedAt: target,
            hit: recallTimeLensPreview?.hit,
            resolution: .resolving
        )
        startRecallTimeLensPreviewPumpIfNeeded(sessionID: sessionID)
    }

    /// Resolves the release position without throttling, then changes selection
    /// exactly once. A miss leaves the pre-scrub selection untouched.
    public func commitRecallTimeLens(at requestedDate: Date) {
        guard recallTimeLensIsScrubbing,
              let repository,
              let bounds = recallTimeLensBounds,
              let sessionID = recallTimeLensSessionID,
              let scope = recallTimeLensScope else { return }
        let target = bounds.clamped(requestedDate)
        recallTimeLensTask?.cancel()
        recallTimeLensTask = nil
        recallTimeLensPendingTarget = nil
        recallTimeLensRequestSequence &+= 1
        let sequence = recallTimeLensRequestSequence
        let expectedRecallOperationID = recallTimeLensRecallOperationID
        recallTimeLensIsScrubbing = false
        recallTimeLensPreview = RecallTimeLensPreview(
            requestedAt: target,
            hit: recallTimeLensPreview?.hit,
            resolution: .resolving
        )

        guard let seekScope = RecallTimeLensQuery.scope(
            atOrBefore: target,
            preserving: scope
        ) else {
            recallTimeLensPreview = RecallTimeLensPreview(
                requestedAt: target,
                hit: nil,
                resolution: .resolved
            )
            completeRecallTimeLensSession()
            return
        }
        let taskID = UUID()
        recallTimeLensTaskID = taskID
        recallTimeLensTask = Task {
            do {
                let page = try await repository.recall(seekScope, after: nil, limit: 1)
                guard recallTimeLensCanPublish(
                    sessionID: sessionID,
                    sequence: sequence,
                    scope: scope,
                    expectedRecallOperationID: expectedRecallOperationID
                ) else { return }
                let hit = page.hits.first
                recallTimeLensPreview = RecallTimeLensPreview(
                    requestedAt: target,
                    hit: hit,
                    resolution: .resolved
                )
                if let hit {
                    // A whole-day seek can land outside the newest loaded page.
                    // Keep the committed moment in the painted marker set so
                    // returning to focused activity centers the span the user
                    // actually chose instead of falling back to the newest
                    // loaded run. The paging cursor remains unchanged.
                    results = Self.mergingNewestRecallPage([hit], into: results)
                    select(hit)
                }
                completeRecallTimeLensSession()
            } catch {
                guard !Task.isCancelled,
                      recallTimeLensCanPublish(
                        sessionID: sessionID,
                        sequence: sequence,
                        scope: scope,
                        expectedRecallOperationID: expectedRecallOperationID
                      ) else { return }
                recallTimeLensPreview = RecallTimeLensPreview(
                    requestedAt: target,
                    hit: recallTimeLensPreview?.hit,
                    resolution: .failed
                )
                completeRecallTimeLensSession()
            }
        }
    }

    /// Ends an in-progress gesture and restores the selection that existed at
    /// pointer-down if another interaction changed it in the meantime.
    public func cancelRecallTimeLensScrub() {
        invalidateRecallTimeLens(restoreBaseline: true)
    }

    public func select(_ hit: SearchHit?) {
        selectedFrameTask?.cancel()
        selectedFrameTask = nil
        selectedFrameOperationID = nil
        selectedFrameTextIsImproving = false
        selectedHit = hit
        selectedFrame = nil
        guard let hit, let repository else { return }
        let requestedID = hit.id
        let operationID = UUID()
        selectedFrameOperationID = operationID
        selectedFrameTask = Task {
            defer {
                if selectedFrameOperationID == operationID {
                    selectedFrameTask = nil
                    selectedFrameOperationID = nil
                    selectedFrameTextIsImproving = false
                }
            }
            let frame = try? await repository.frame(id: requestedID)
            guard selectionCanPublish(operationID: operationID, frameID: requestedID) else {
                return
            }
            selectedFrame = frame
            guard let frame,
                  Self.shouldImproveLegacyOCR(in: frame),
                  let refinementRepository = repository as? any OCRRefinementRepository,
                  let mediaStore else { return }

            selectedFrameTextIsImproving = true
            do {
                // MediaStore authenticates and decrypts into this task's memory.
                // No decoded image or plaintext OCR is written to a temporary file.
                let imageData = try await mediaStore.read(relativePath: frame.imageRelativePath)
                guard selectionCanPublish(operationID: operationID, frameID: requestedID) else {
                    return
                }
                let recognized = try await ocrRefinementService.recognize(
                    imageData,
                    mode: .accurate
                )
                guard selectionCanPublish(operationID: operationID, frameID: requestedID) else {
                    return
                }
                let replacement = try await refinementRepository.replaceOCR(
                    for: requestedID,
                    expectedVisualFingerprint: frame.visualFingerprint,
                    text: recognized.text,
                    regions: recognized.regions
                )
                guard selectionCanPublish(operationID: operationID, frameID: requestedID),
                      let replacement else { return }
                selectedFrame = replacement
                // The inspector now has canonical text, but the visible row is
                // still the SearchHit decoded before repair. Re-read the active
                // scope so its snippet, membership, match markers, and facets
                // all agree with the atomically replaced FTS row.
                if let descriptor = memoryLensSelection {
                    _ = scheduleMemoryLens(
                        descriptor: descriptor,
                        scope: metadataOnlyScope(from: recallScope)
                    )
                } else {
                    _ = scheduleRecall(
                        scope: currentRecallScope(text: queryText),
                        debounce: nil,
                        allowsInterpretation: !recallUsesOriginalWording
                    )
                }
            } catch {
                // Repair is opportunistic. The authenticated image and original
                // searchable evidence remain intact when decoding, OCR, or a
                // retention race prevents replacement.
            }
        }
    }

    /// Reconciles the inspector only after a successful, authoritative Recall
    /// publication. Keep the same remembered moment when it remains in scope,
    /// move to the first visible result when it does not, and clear only when
    /// that successful publication is genuinely empty. Failed or stale reads
    /// deliberately never call this helper, so they cannot erase a valid
    /// selection while newer evidence is pending.
    private func reconcileRecallSelection(afterPublishing hits: [SearchHit]) {
        if let selectedID = selectedHit?.id,
           let refreshedHit = hits.first(where: { $0.id == selectedID }) {
            selectedHit = refreshedHit
            return
        }
        select(hits.first)
    }

    /// Accurate Vision OCR discards every observation below 0.55 confidence.
    /// Legacy fast captures retained those observations down to 0.20. Requiring
    /// both a meaningful low-confidence tail and weak aggregate confidence
    /// identifies old fast-mode text without repeatedly rereading current OCR.
    nonisolated static func shouldImproveLegacyOCR(in frame: FrameDocument) -> Bool {
        guard !frame.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let confidences = frame.ocrRegions.compactMap { region -> Double? in
            guard !region.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  region.confidence.isFinite else { return nil }
            return Double(region.confidence)
        }.sorted()
        guard !confidences.isEmpty else { return false }

        let accurateConfidenceFloor = Double(VisionOCRService.accurateMinimumConfidence)
        let lowConfidenceCount = confidences.prefix { $0 < accurateConfidenceFloor }.count
        let requiredLowConfidenceCount = max(1, Int(ceil(Double(confidences.count) * 0.12)))
        guard lowConfidenceCount >= requiredLowConfidenceCount else { return false }

        let mean = confidences.reduce(0, +) / Double(confidences.count)
        let middle = confidences.count / 2
        let median = confidences.count.isMultiple(of: 2)
            ? (confidences[middle - 1] + confidences[middle]) / 2
            : confidences[middle]
        return mean < 0.78 || median < 0.75
    }

    private func selectionCanPublish(operationID: UUID, frameID: FrameID) -> Bool {
        !Task.isCancelled
            && !sessionIsLocked
            && !historyDeletionInProgress
            && selectedFrameOperationID == operationID
            && selectedHit?.id == frameID
    }

    public func selectActivitySession(_ session: ActivitySessionSummary?) {
        activitySessionDetailTask?.cancel()
        activitySessionDetailTask = nil
        intelligenceTask?.cancel()
        intelligenceTask = nil
        cancelSessionQuestion(resetDraft: true, clearAnswer: true)
        if intelligenceState == .enhancing {
            intelligenceState = openAIAPIKeyConfigured ? .ready : .notConfigured
        }
        selectedActivitySession = session
        selectedActivitySessionDetail = nil
        selectedSessionEnrichment = nil
        activitySessionError = nil
        guard let session, let repository else { return }
        activitySessionDetailTask = Task {
            defer {
                if selectedActivitySession?.id == session.id {
                    activitySessionDetailTask = nil
                }
            }
            do {
                let detail = try await repository.activitySession(id: session.id, momentLimit: 100)
                guard !Task.isCancelled,
                      !sessionIsLocked,
                      selectedActivitySession?.id == session.id else { return }
                selectedActivitySessionDetail = detail
                if detail == nil {
                    activitySessionError = "This session no longer exists."
                } else if let detail {
                    await loadCachedEnrichment(for: detail)
                }
            } catch {
                guard !Task.isCancelled,
                      !sessionIsLocked,
                      selectedActivitySession?.id == session.id else { return }
                activitySessionError = error.localizedDescription
            }
        }
    }

    public func refresh() async {
        captureRefreshTask?.cancel()
        captureRefreshTask = nil
        captureRefreshOperationID = nil
        captureRefreshRequiresFullReload = false
        if let descriptor = memoryLensSelection {
            let task = scheduleMemoryLens(
                descriptor: descriptor,
                scope: metadataOnlyScope(from: recallScope)
            )
            await task?.value
            guard !Task.isCancelled,
                  memoryLensSelection == descriptor else { return }
            await refreshActivityData()
            if let accessRepository {
                accessEvents = (try? await accessRepository.accessEvents(limit: 100))
                    ?? accessEvents
            }
            return
        }
        let scheduled = scheduleRecall(
            scope: currentRecallScope(text: queryText),
            debounce: nil,
            allowsInterpretation: !recallUsesOriginalWording
        )
        await scheduled.task.value
        guard !Task.isCancelled,
              recallOperationID == scheduled.operationID else { return }
        await refreshActivityData()
        if let accessRepository {
            accessEvents = (try? await accessRepository.accessEvents(limit: 100)) ?? accessEvents
        }
    }

    public func mediaData(relativePath: String) async -> Data? {
        guard !sessionIsLocked,
              !retentionMutationInProgress,
              let mediaStore else { return nil }
        let lifecycleGeneration = sessionLifecycleGeneration
        guard let data = try? await mediaStore.read(relativePath: relativePath),
              !Task.isCancelled,
              !sessionIsLocked,
              !retentionMutationInProgress,
              sessionLifecycleGeneration == lifecycleGeneration,
              self.mediaStore === mediaStore else { return nil }
        return data
    }

    func prepareContextHandoff(for hit: SearchHit) {
        let knownSession = hit.activitySessionID.flatMap { sessionID in
            activitySessions.first(where: { $0.id == sessionID })
        }
        let retrieval: ContextHandoffRetrieval = hit.activitySessionID
            .map(ContextHandoffRetrieval.session)
            ?? .moment(hit.id)
        let scopeDescription = hit.activitySessionID == nil
            ? "Selected ordinary moment"
            : "Recent ordinary moments in this session"
        beginContextHandoff(ContextHandoffDraft(
            origin: .moment(
                frameID: hit.id,
                activitySessionID: hit.activitySessionID
            ),
            retrieval: retrieval,
            title: "\(hit.context.applicationName) · \(hit.capturedAt.formatted(date: .abbreviated, time: .shortened))",
            scopeDescription: scopeDescription,
            containsPrivateHistory: hit.context.isSensitive
                || knownSession?.containsSensitive == true
        ))
    }

    func prepareContextHandoff(for detail: ActivitySessionDetail) {
        let session = detail.summary
        beginContextHandoff(ContextHandoffDraft(
            origin: .session(session.id),
            retrieval: .session(session.id),
            title: "\(session.latestApplicationName) session · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))",
            scopeDescription: "Recent ordinary moments in this session",
            containsPrivateHistory: session.containsSensitive
        ))
    }

    func retryContextHandoff() {
        guard let draft = contextHandoffState.draft else { return }
        beginContextHandoff(draft)
    }

    func dismissContextHandoff() {
        contextHandoffTask?.cancel()
        contextHandoffTask = nil
        contextHandoffOperationID = nil
        contextHandoffState = .idle
    }

    func copyContextHandoff(format: ContextHandoffExportFormat) {
        guard case .ready(let prepared) = contextHandoffState,
              prepared.canCopy,
              !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              let frames = repository as? SQLiteFrameStore,
              let accessRepository else { return }

        contextHandoffTask?.cancel()
        let operationID = UUID()
        let lifecycleGeneration = sessionLifecycleGeneration
        contextHandoffOperationID = operationID
        contextHandoffState = .copying(prepared, format)
        let artifact = prepared.artifact(for: format)
        let artifactBytes = artifact.utf8.count
        contextHandoffTask = Task {
            defer {
                if contextHandoffOperationID == operationID {
                    contextHandoffTask = nil
                }
            }
            do {
                let resolved = try await frames.agentSafeFrames(ids: prepared.sourceIDs)
                let resolvedByID = Dictionary(
                    uniqueKeysWithValues: resolved.map { ($0.frame.id, $0) }
                )
                guard resolved.count == prepared.sourceIDs.count,
                      prepared.payload.sources.allSatisfy({ source in
                          resolvedByID[source.frameID].map(source.matches) == true
                      }) else {
                    throw ContextHandoffOperationError.historyChanged
                }
                guard contextHandoffCanPublish(
                    operationID: operationID,
                    lifecycleGeneration: lifecycleGeneration,
                    frames: frames,
                    accessRepository: accessRepository
                ) else { return }

                let event = AccessEvent(
                    client: "You [Passage]",
                    command: "copyContext",
                    capability: "memory.manualHandoff",
                    querySummary: prepared.draft.scopeDescription,
                    filterSummary: [
                        "format=\(format.rawValue)",
                        "encodedBytes=\(artifactBytes)",
                        "sources=\(prepared.sourceIDs.count)",
                        "screenshots=false",
                        "sensitive=false",
                    ].joined(separator: "; "),
                    returnedFrameIDs: prepared.sourceIDs,
                    outcome: .success
                )
                // Fail closed: the exact immutable artifact does not reach the
                // system clipboard until its receipt has committed.
                let released = try await ContextHandoffReleaseCoordinator.release(
                    artifact: artifact,
                    event: event,
                    receiptStore: accessRepository,
                    clipboard: contextHandoffClipboard,
                    canRelease: {
                        self.contextHandoffCanPublish(
                            operationID: operationID,
                            lifecycleGeneration: lifecycleGeneration,
                            frames: frames,
                            accessRepository: accessRepository
                        )
                    }
                )
                guard released else { return }
                guard contextHandoffOperationID == operationID else { return }
                contextHandoffState = .copied(prepared, format)
                accessEvents.removeAll { $0.id == event.id }
                accessEvents.insert(event, at: 0)
                if accessEvents.count > 100 {
                    accessEvents.removeLast(accessEvents.count - 100)
                }
            } catch is CancellationError {
                return
            } catch ContextHandoffOperationError.historyChanged {
                guard contextHandoffOperationID == operationID else { return }
                contextHandoffState = .invalidated(
                    prepared.draft,
                    .historyChanged
                )
            } catch {
                guard contextHandoffOperationID == operationID else { return }
                contextHandoffState = .failed(
                    prepared.draft,
                    error.localizedDescription
                )
            }
        }
    }

    private func beginContextHandoff(_ draft: ContextHandoffDraft) {
        contextHandoffTask?.cancel()
        let operationID = UUID()
        contextHandoffOperationID = operationID
        contextHandoffState = .preparing(draft)

        guard !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              let memoryCapsules,
              let frames = repository as? SQLiteFrameStore,
              accessRepository != nil else {
            contextHandoffOperationID = nil
            contextHandoffState = .failed(
                draft,
                ContextHandoffOperationError.unavailable.localizedDescription
            )
            return
        }
        let lifecycleGeneration = sessionLifecycleGeneration
        contextHandoffTask = Task {
            defer {
                if contextHandoffOperationID == operationID {
                    contextHandoffTask = nil
                }
            }
            do {
                let manifest: PassageMemoryCapsuleManifest
                switch draft.retrieval {
                case .moment(let frameID):
                    manifest = try await memoryCapsules.retrieveMoment(
                        frameID,
                        utf8ByteBudget: 16 * 1_024
                    )
                case .session(let sessionID):
                    manifest = try await memoryCapsules.retrieveSession(
                        sessionID,
                        resultLimit: 12,
                        utf8ByteBudget: 16 * 1_024
                    )
                }
                guard contextHandoffCanPublish(
                    operationID: operationID,
                    lifecycleGeneration: lifecycleGeneration,
                    frames: frames,
                    memoryCapsules: memoryCapsules
                ) else { return }
                let prepared = try PreparedContextHandoff.make(
                    draft: draft,
                    manifest: manifest
                )
                guard contextHandoffCanPublish(
                    operationID: operationID,
                    lifecycleGeneration: lifecycleGeneration,
                    frames: frames,
                    memoryCapsules: memoryCapsules
                ) else { return }
                contextHandoffState = .ready(prepared)
            } catch is CancellationError {
                return
            } catch {
                guard contextHandoffOperationID == operationID else { return }
                contextHandoffState = .failed(draft, error.localizedDescription)
            }
        }
    }

    private func contextHandoffCanPublish(
        operationID: UUID,
        lifecycleGeneration: UUID,
        frames: SQLiteFrameStore,
        memoryCapsules expectedRuntime: (any LocalMemoryCapsuleRetrieving)? = nil,
        accessRepository expectedAccessRepository: SQLiteAccessEventStore? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              contextHandoffOperationID == operationID,
              sessionLifecycleGeneration == lifecycleGeneration,
              !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              (repository as? SQLiteFrameStore) === frames else { return false }
        if let expectedRuntime, memoryCapsules !== expectedRuntime { return false }
        if let expectedAccessRepository,
           accessRepository !== expectedAccessRepository { return false }
        return true
    }

    private func invalidateContextHandoffForHistoryChange() {
        guard let draft = contextHandoffState.draft else { return }
        contextHandoffTask?.cancel()
        contextHandoffTask = nil
        contextHandoffOperationID = nil
        contextHandoffState = .invalidated(draft, .historyChanged)
    }

    @discardableResult
    public func saveOpenAIAPIKey(_ apiKey: String) -> Bool {
        do {
            try openAIAPIKeyStore.save(apiKey)
            openAIAPIKeyConfigured = true
            intelligenceState = .ready
            return true
        } catch {
            openAIAPIKeyConfigured = false
            intelligenceState = .error(error.localizedDescription)
            return false
        }
    }

    public func removeOpenAIAPIKey() {
        intelligenceTask?.cancel()
        intelligenceTask = nil
        cancelSessionQuestion(resetDraft: false, clearAnswer: false)
        do {
            try openAIAPIKeyStore.delete()
            openAIAPIKeyConfigured = false
            intelligenceState = .notConfigured
        } catch {
            intelligenceState = .error(error.localizedDescription)
        }
    }

    public func enhanceSelectedActivitySession(forceRefresh: Bool = false) {
        guard intelligenceState != .enhancing,
              let detail = selectedActivitySessionDetail,
              let intelligenceCache,
              let intelligenceSafetyIdentifier else { return }

        let sessionID = detail.summary.id
        let input = Self.intelligenceInput(for: detail)
        intelligenceTask?.cancel()
        intelligenceState = .enhancing
        intelligenceTask = Task {
            do {
                guard !input.sources.isEmpty else {
                    throw SessionIntelligenceError.emptyInput
                }
                guard let apiKey = try openAIAPIKeyStore.load() else {
                    throw SessionIntelligenceError.missingAPIKey
                }

                if !forceRefresh,
                   let cached = try await intelligenceCache.load(
                    activitySessionID: sessionID,
                    contentFingerprint: input.contentFingerprint
                   ) {
                    guard !Task.isCancelled,
                          selectedActivitySession?.id == sessionID else { return }
                    selectedSessionEnrichment = cached
                    intelligenceState = .ready
                    return
                }

                let provider = OpenAIResponsesSessionIntelligenceProvider(
                    apiKey: apiKey,
                    safetyIdentifier: intelligenceSafetyIdentifier
                )
                let enrichment = try await provider.enrich(input)
                guard !Task.isCancelled,
                      selectedActivitySession?.id == sessionID else { return }
                try await intelligenceCache.store(enrichment)
                guard !Task.isCancelled,
                      selectedActivitySession?.id == sessionID else { return }
                selectedSessionEnrichment = enrichment
                intelligenceState = .ready
            } catch is CancellationError {
                guard selectedActivitySession?.id == sessionID else { return }
                intelligenceState = openAIAPIKeyConfigured ? .ready : .notConfigured
            } catch {
                guard selectedActivitySession?.id == sessionID else { return }
                intelligenceState = .error(error.localizedDescription)
            }
        }
    }

    /// Selects the exact local evidence for the current draft. This phase is
    /// local-only; it is safe to inspect the disclosure before deciding whether
    /// to permit a private session question to leave the Mac.
    public func prepareSelectedSessionQuestion() {
        guard !sessionQuestionState.isWorking,
              sessionQuestionState != .awaitingPrivateConfirmation,
              let detail = selectedActivitySessionDetail,
              let repository else { return }

        let operationID = UUID()
        let sessionID = detail.summary.id
        let draft = sessionQuestionText
        sessionQuestionTask?.cancel()
        sessionQuestionOperationID = operationID
        preparedSessionQuestion = nil
        sessionQuestionState = .preparing

        sessionQuestionTask = Task {
            do {
                let selector = SessionQuestionEvidenceSelector()
                let searchText = selector.searchText(for: draft)
                let matches: [SearchHit]
                if searchText.isEmpty {
                    matches = []
                } else {
                    matches = try await repository.search(
                        SearchQuery(
                            text: searchText,
                            activitySessionIDs: [sessionID],
                            limit: SessionQuestionEvidenceSelector.maximumMatchedMomentCount
                        )
                    )
                }
                guard isCurrentSessionQuestion(operationID, sessionID: sessionID) else { return }

                let preparation = selector.prepare(
                    question: draft,
                    session: detail,
                    matchedMoments: matches,
                    provider: "openai-responses",
                    model: OpenAIResponsesSessionQuestionProvider.defaultModel
                )
                guard !preparation.input.question.isEmpty else {
                    preparedSessionQuestion = nil
                    sessionQuestionState = .error("Ask a specific question about this session first.")
                    finishSessionQuestionOperation(operationID)
                    return
                }
                guard !preparation.input.sources.isEmpty else {
                    preparedSessionQuestion = nil
                    sessionQuestionState = .insufficientEvidence
                    finishSessionQuestionOperation(operationID)
                    return
                }
                preparedSessionQuestion = preparation

                switch SessionQuestionDisclosurePolicy().decision(
                    for: preparation,
                    sessionContainsSensitiveHistory: detail.summary.containsSensitive
                ) {
                case .requirePrivateConfirmation:
                    sessionQuestionState = .awaitingPrivateConfirmation
                    sessionQuestionTask = nil
                case .submit:
                    await answerPreparedSessionQuestion(
                        preparation,
                        operationID: operationID,
                        sessionID: sessionID
                    )
                case .noEvidence:
                    preparedSessionQuestion = nil
                    sessionQuestionState = .insufficientEvidence
                    finishSessionQuestionOperation(operationID)
                }
            } catch is CancellationError {
                guard sessionQuestionOperationID == operationID else { return }
                sessionQuestionState = .idle
                finishSessionQuestionOperation(operationID)
            } catch {
                guard isCurrentSessionQuestion(operationID, sessionID: sessionID) else { return }
                sessionQuestionState = .error(error.localizedDescription)
                finishSessionQuestionOperation(operationID)
            }
        }
    }

    /// The sole provider boundary for a prepared question. The immutable
    /// preparation—not the current text field—is what a confirmation submits.
    public func submitPreparedSessionQuestion() {
        guard sessionQuestionState == .awaitingPrivateConfirmation,
              let preparation = preparedSessionQuestion,
              let session = selectedActivitySession,
              preparation.input.activitySessionID == session.id else { return }
        let operationID = sessionQuestionOperationID ?? UUID()
        sessionQuestionOperationID = operationID
        sessionQuestionState = .answering
        sessionQuestionTask = Task {
            await answerPreparedSessionQuestion(
                preparation,
                operationID: operationID,
                sessionID: session.id
            )
        }
    }

    public func cancelPreparedSessionQuestion() {
        cancelSessionQuestion(resetDraft: false, clearAnswer: false)
    }

    public func cancelSessionQuestion() {
        cancelSessionQuestion(resetDraft: false, clearAnswer: false)
    }

    private func answerPreparedSessionQuestion(
        _ preparation: SessionQuestionPreparation,
        operationID: UUID,
        sessionID: ActivitySessionID
    ) async {
        guard let sessionQuestionCache,
              let intelligenceSafetyIdentifier else {
            sessionQuestionState = .error("Session intelligence is not ready yet.")
            finishSessionQuestionOperation(operationID)
            return
        }
        sessionQuestionState = .answering
        do {
            guard let apiKey = try openAIAPIKeyStore.load() else {
                throw SessionIntelligenceError.missingAPIKey
            }

            if let cached = try await sessionQuestionCache.load(
                requestFingerprint: preparation.input.requestFingerprint
            ) {
                guard isCurrentSessionQuestion(operationID, sessionID: sessionID),
                      cached.activitySessionID == sessionID else { return }
                publishSessionQuestionAnswer(cached)
                finishSessionQuestionOperation(operationID)
                return
            }
            guard isCurrentSessionQuestion(operationID, sessionID: sessionID) else { return }

            let provider = OpenAIResponsesSessionQuestionProvider(
                apiKey: apiKey,
                safetyIdentifier: intelligenceSafetyIdentifier
            )
            let answer = try await provider.answer(preparation.input)
            guard isCurrentSessionQuestion(operationID, sessionID: sessionID) else { return }
            try await sessionQuestionCache.store(answer)
            guard isCurrentSessionQuestion(operationID, sessionID: sessionID) else { return }
            publishSessionQuestionAnswer(answer)
            finishSessionQuestionOperation(operationID)
        } catch is CancellationError {
            guard sessionQuestionOperationID == operationID else { return }
            sessionQuestionState = .idle
            finishSessionQuestionOperation(operationID)
        } catch {
            guard isCurrentSessionQuestion(operationID, sessionID: sessionID) else { return }
            // Keep a prior successful answer visible and tied to its question.
            sessionQuestionState = .error(error.localizedDescription)
            preparedSessionQuestion = nil
            finishSessionQuestionOperation(operationID)
        }
    }

    private func publishSessionQuestionAnswer(_ answer: SessionQuestionAnswer) {
        selectedSessionQuestionAnswer = answer
        preparedSessionQuestion = nil
        sessionQuestionState = answer.status == .answered ? .idle : .insufficientEvidence
    }

    private func isCurrentSessionQuestion(
        _ operationID: UUID,
        sessionID: ActivitySessionID
    ) -> Bool {
        !Task.isCancelled
            && sessionQuestionOperationID == operationID
            && selectedActivitySession?.id == sessionID
    }

    private func finishSessionQuestionOperation(_ operationID: UUID) {
        guard sessionQuestionOperationID == operationID else { return }
        sessionQuestionOperationID = nil
        sessionQuestionTask = nil
    }

    private func cancelSessionQuestion(resetDraft: Bool, clearAnswer: Bool) {
        sessionQuestionTask?.cancel()
        sessionQuestionTask = nil
        sessionQuestionOperationID = nil
        preparedSessionQuestion = nil
        sessionQuestionState = .idle
        if resetDraft { sessionQuestionText = "" }
        if clearAnswer { selectedSessionQuestionAnswer = nil }
    }

    public func clearAccessHistory() {
        guard let accessRepository else { return }
        accessHistoryTask?.cancel()
        accessHistoryTask = Task {
            defer { accessHistoryTask = nil }
            _ = try? await accessRepository.clearAccessEvents()
            guard !Task.isCancelled, !sessionIsLocked else { return }
            accessEvents = []
        }
    }

    public func deleteAllHistory() {
        guard !historyDeletionInProgress,
              let repository,
              let mediaStore else { return }
        dismissContextHandoff()
        agentVisualRecallController?.clear()
        historyDeletionInProgress = true
        historyDeletionError = nil
        captureIntent = .paused
        captureIntentStore.save(.paused)
        let visualTasks = cancelVisualWork()
        if visualRecallRuntime != nil {
            visualUnderstandingState = .paused
        }
        cancelCaptureControl()
        cancelCaptureNow()
        searchTask?.cancel()
        searchTask = nil
        firstMemoryRecallOperationID = nil
        firstMemoryResumeOperationID = nil
        recallPageTask?.cancel()
        recallPageTask = nil
        cancelRecallFacets()
        recallFacetsError = nil
        captureRefreshTask?.cancel()
        captureRefreshTask = nil
        captureRefreshOperationID = nil
        captureRefreshRequiresFullReload = false
        selectedFrameTask?.cancel()
        selectedFrameTask = nil
        selectedFrameOperationID = nil
        selectedFrameTextIsImproving = false
        invalidateRecallTimeLens(restoreBaseline: false)
        recallOperationID = nil
        recallCursor = nil
        loadedRecallScope = nil
        recallTimeLensBounds = nil
        recallHasMore = false
        recallIsLoading = false
        recallIsLoadingMore = false
        recallResultsAreStale = false
        recallPresentationMode = .chronological
        visualRecallEvidenceByFrameID = [:]
        visualOnlyRecallFrameIDs = []
        intelligenceTask?.cancel()
        intelligenceTask = nil
        cancelSessionQuestion(resetDraft: true, clearAnswer: true)
        intelligenceState = openAIAPIKeyConfigured ? .ready : .notConfigured
        historyDeletionTask?.cancel()
        historyDeletionTask = Task {
            defer {
                historyDeletionTask = nil
                if !sessionIsLocked {
                    if let visualRecallRuntime {
                        agentVisualRecallController?.install(visualRecallRuntime)
                    }
                    historyDeletionInProgress = false
                }
            }
            for task in visualTasks { await task.value }
            guard !Task.isCancelled, !sessionIsLocked else { return }
            await coordinator?.pause()
            do {
                try Task.checkCancellation()
                let paths = try await repository.deleteFrames(from: nil, through: nil)
                await mediaStore.delete(relativePaths: paths)
                guard !Task.isCancelled, !sessionIsLocked else { return }
                mediaRevision &+= 1
                selectedHit = nil
                selectedFrame = nil
                results = []
                recallCursor = nil
                loadedRecallScope = nil
                recallTimeLensBounds = nil
                recallHasMore = false
                recallIsLoading = false
                recallIsLoadingMore = false
                recallResultsAreStale = false
                recallBaseFacets = RecallFacets()
                recallFacets = RecallFacets(applications: [], domains: [])
                recallBrowserMomentAvailability = .unknown
                recallFacetsError = nil
                recallQueryInterpretation = nil
                searchError = nil
                activitySessions = []
                selectedActivitySession = nil
                selectedActivitySessionDetail = nil
                selectedSessionEnrichment = nil
                visualEmbeddingCoverage = try await visualRecallRuntime?.coverage()
                try await intelligenceCache?.removeAll()
                try await sessionQuestionCache?.removeAll()
                firstMemoryActivationStore.save(.pending)
                await refresh()
                firstMemoryActivationState = FirstMemoryActivationReducer.initial(
                    frameCount: statistics.frameCount,
                    intent: captureIntent,
                    permissionGranted: screenPermissionGranted,
                    progress: .pending
                )
            } catch is CancellationError {
                return
            } catch {
                guard !sessionIsLocked else { return }
                historyDeletionError = error.localizedDescription
                // The delete may fail before or after touching the store. Rebuild
                // the visible stream and its cursor instead of leaving the
                // invalidated, non-pageable state on screen.
                await refresh()
            }
            if let coverage = visualEmbeddingCoverage {
                visualUnderstandingState = coverage.pendingEligibleFrameCount == 0
                    ? .ready
                    : .indexing
                scheduleVisualIndexing()
            } else if visualRecallRuntime == nil,
                      let rootURL,
                      vaultKey != nil,
                      self.repository != nil,
                      self.mediaStore != nil {
                scheduleVisualBootstrap(paths: PassagePaths(root: rootURL))
            }
        }
    }

    public func suspendForSessionLock() async {
        if sessionIsLocked {
            if let sessionTeardownTask { await sessionTeardownTask.value }
            return
        }
        sessionIsLocked = true
        let lifecycleGeneration = UUID()
        sessionLifecycleGeneration = lifecycleGeneration

        // Startup preparation is detached and intentionally not part of the
        // teardown wait. Revoke its stores synchronously, then forget the old
        // generation so unlock can begin fresh even if Keychain or file I/O is
        // still unwinding in the cancelled task.
        let startupOperationToRevoke = startupVaultOperation
        let startupTaskToCancel = startupPreparationTask
        startupOperationToRevoke?.revoke()
        startupTaskToCancel?.cancel()
        startupVaultOperation = nil
        startupPreparationTask = nil
        let websiteFacetMaintenanceToCancel = websiteFacetMaintenanceTask
        websiteFacetMaintenanceToCancel?.cancel()
        websiteFacetMaintenanceTask = nil
        websiteFacetMaintenanceOperationID = nil
        let contextHandoffTaskToCancel = contextHandoffTask
        dismissContextHandoff()

        // Revoke encrypted database capabilities before the first suspension
        // point. Canceled tasks may take time to unwind, but they cannot issue
        // more SQL or publish decrypted evidence after this boundary.
        agentVisualRecallController?.clear()
        (repository as? SQLiteFrameStore)?.revoke()
        accessRepository?.revoke()
        mediaStore?.revoke()
        visualRecallRuntime?.revoke()

        let coordinatorToPause = coordinator
        var tasks = [
            captureNowTask,
            captureControlTask,
            searchTask,
            recallPageTask,
            recallFacetsTask,
            captureRefreshTask,
            selectedFrameTask,
            recallTimeLensTask,
            intelligenceTask,
            sessionQuestionTask,
            activitySessionDetailTask,
            accessHistoryTask,
            contextHandoffTaskToCancel,
            historyDeletionTask,
            privacyUpdateTask,
            websiteFacetMaintenanceToCancel,
        ].compactMap { $0 }
        tasks.append(contentsOf: cancelVisualWork())
        tasks.forEach { $0.cancel() }

        cancelCaptureControl()
        cancelCaptureNow()
        searchTask?.cancel()
        searchTask = nil
        firstMemoryRecallOperationID = nil
        firstMemoryResumeOperationID = nil
        recallPageTask?.cancel()
        recallPageTask = nil
        cancelRecallFacets()
        captureRefreshTask?.cancel()
        captureRefreshTask = nil
        captureRefreshOperationID = nil
        captureRefreshRequiresFullReload = false
        selectedFrameTask?.cancel()
        selectedFrameTask = nil
        selectedFrameOperationID = nil
        selectedFrameTextIsImproving = false
        invalidateRecallTimeLens(restoreBaseline: false)
        recallOperationID = nil
        intelligenceTask?.cancel()
        intelligenceTask = nil
        activitySessionDetailTask = nil
        accessHistoryTask = nil
        historyDeletionTask = nil
        privacyUpdateTask = nil
        privacyUpdateOperationID = nil
        cancelSessionQuestion(resetDraft: true, clearAnswer: true)
        serviceServer?.stop()
        serviceServer = nil
        coordinator = nil
        vaultKey = nil
        repository = nil
        accessRepository = nil
        mediaStore = nil
        privacyStore = nil
        intelligenceCache = nil
        sessionQuestionCache = nil
        intelligenceSafetyIdentifier = nil
        agentAccessPolicy = nil
        agentVisualRecallController = nil
        memoryCapsules = nil
        visualRecallRuntime = nil
        visualEmbeddingCoverage = nil
        visualUnderstandingState = .unavailable
        visualSearchError = nil
        results = []
        recallCursor = nil
        loadedRecallScope = nil
        recallTimeLensBounds = nil
        recallHasMore = false
        recallIsLoading = false
        recallIsLoadingMore = false
        recallResultsAreStale = false
        recallPresentationMode = .chronological
        recallBaseFacets = RecallFacets()
        recallFacets = RecallFacets(applications: [], domains: [])
        recallBrowserMomentAvailability = .unknown
        recallFacetsError = nil
        recallQueryInterpretation = nil
        searchError = nil
        selectedHit = nil
        selectedFrame = nil
        selectedFrameTextIsImproving = false
        mediaRevision &+= 1
        activitySessions = []
        selectedActivitySession = nil
        selectedActivitySessionDetail = nil
        selectedSessionEnrichment = nil
        activitySessionError = nil
        openAIAPIKeyConfigured = false
        intelligenceState = .notConfigured
        accessEvents = []
        rootURL = nil
        agentServiceAvailable = false
        agentServiceError = nil
        contextHandoffState = .idle
        historyDeletionInProgress = false
        retentionMutationInProgress = false
        retentionCommitHandledByBoundary = false
        captureState = .locked
        firstMemoryActivationState = .preparing

        // Detaching and pausing the old coordinator may await an in-flight
        // screenshot. The UI and every SQLCipher handle are already revoked.
        let teardown = Task {
            await coordinatorToPause?.setEventHandler(nil)
            await coordinatorToPause?.setRetentionMutationHandler(nil)
            await coordinatorToPause?.pause()
            for task in tasks { await task.value }
        }
        sessionTeardownTask = teardown
        await teardown.value
        if sessionLifecycleGeneration == lifecycleGeneration {
            sessionTeardownTask = nil
        }
    }

    public func resumeAfterSessionUnlock() async {
        guard sessionIsLocked else { return }
        sessionIsLocked = false
        captureState = .unavailable
        let lifecycleGeneration = UUID()
        sessionLifecycleGeneration = lifecycleGeneration
        let teardown = sessionTeardownTask
        if let teardown { await teardown.value }
        guard !sessionIsLocked,
              sessionLifecycleGeneration == lifecycleGeneration,
              repository == nil else { return }
        sessionTeardownTask = nil
        await start()
    }

    private func scheduleVisualBootstrap(paths: PassagePaths) {
        if visualRecallRuntime != nil {
            scheduleVisualIndexing()
            return
        }
        visualBootstrapCandidateRuntime?.revoke()
        visualBootstrapCandidateRuntime = nil
        visualBootstrapCandidateGeneration = nil
        visualBootstrapTask?.cancel()
        let generation = UUID()
        visualGenerationID = generation
        visualUnderstandingState = .verifying
        visualBootstrapTask = Task(priority: .utility) {
            defer {
                if visualGenerationID == generation {
                    visualBootstrapTask = nil
                }
            }
            do {
                guard let resourcesURL = Bundle.main.resourceURL else {
                    throw LocalVisualRuntimeError.bundledResourcesUnavailable
                }
                let packStore = VisualModelPackStore(
                    rootDirectory: resourcesURL.appendingPathComponent(
                        "VisualModelPacks",
                        isDirectory: true
                    )
                )
                let pack = try await BundledVisualModelCatalog.verify(
                    resourcesURL: resourcesURL,
                    using: packStore
                )
                guard visualBootstrapCanPublish(generation) else { return }
                visualUnderstandingState = .preparing
                // Model loading touches only signed, public bundle resources.
                // Key-bearing stores are acquired after prewarm and after the
                // current unlocked generation is revalidated.
                let model = try await LocalVisualRecallRuntime.prepareModel(
                    pack: pack,
                    paths: paths
                )
                guard visualBootstrapCanPublish(generation),
                      let vaultKey,
                      let repository = repository as? SQLiteFrameStore,
                      let media = mediaStore else { return }
                // Opening and verifying the second read-only SQLCipher handle
                // must not stall delivery of a macOS lock notification on the
                // main actor. If cancellation arrives during its synchronous
                // constructor, the completed handle is revoked before return.
                let connectTask = Task.detached(priority: .utility) {
                    let runtime = try LocalVisualRecallRuntime.connect(
                        model: model,
                        paths: paths,
                        vaultKey: vaultKey,
                        writeRepository: repository,
                        media: media
                    )
                    do {
                        try Task.checkCancellation()
                        return runtime
                    } catch {
                        runtime.revoke()
                        throw error
                    }
                }
                let runtime = try await withTaskCancellationHandler {
                    try await connectTask.value
                } onCancel: {
                    connectTask.cancel()
                }
                guard visualBootstrapCanPublish(generation) else {
                    runtime.revoke()
                    return
                }
                // Keep a revocable reference while the encrypted snapshot is
                // warming, without exposing a half-ready runtime to Recall.
                visualBootstrapCandidateRuntime = runtime
                visualBootstrapCandidateGeneration = generation
                let coverage = try await runtime.coverage()
                try await runtime.prewarmIndex()
                guard visualBootstrapCanPublish(generation) else { return }
                visualRecallRuntime = runtime
                agentVisualRecallController?.install(runtime)
                if visualBootstrapCandidateGeneration == generation {
                    visualBootstrapCandidateRuntime = nil
                    visualBootstrapCandidateGeneration = nil
                }
                visualEmbeddingCoverage = coverage
                if coverage.pendingEligibleFrameCount == 0 {
                    visualUnderstandingState = .ready
                } else {
                    visualUnderstandingState = .indexing
                }
                refineCurrentRecallWithVisualRuntimeIfNeeded()
                if coverage.pendingEligibleFrameCount > 0 {
                    scheduleVisualIndexing()
                }
            } catch is CancellationError {
                discardVisualBootstrapCandidate(for: generation)
                return
            } catch {
                guard visualBootstrapCanPublish(generation) else { return }
                discardVisualBootstrapCandidate(for: generation)
                agentVisualRecallController?.clear()
                visualRecallRuntime = nil
                visualEmbeddingCoverage = nil
                visualUnderstandingState = .error(
                    "The built-in local visual model could not start. Text search still works."
                )
            }
        }
    }

    private func discardVisualBootstrapCandidate(for generation: UUID) {
        guard visualBootstrapCandidateGeneration == generation else { return }
        visualBootstrapCandidateRuntime?.revoke()
        visualBootstrapCandidateRuntime = nil
        visualBootstrapCandidateGeneration = nil
    }

    private func visualBootstrapCanPublish(_ generation: UUID) -> Bool {
        !Task.isCancelled
            && visualGenerationID == generation
            && !sessionIsLocked
            && !historyDeletionInProgress
            && repository != nil
    }

    private func scheduleVisualIndexing() {
        guard let runtime = visualRecallRuntime,
              !sessionIsLocked,
              !historyDeletionInProgress else { return }
        if visualIndexTask != nil {
            // A persisted frame or retention commit may arrive while the
            // current task is awaiting its final prewarm. Remember that wakeup
            // and recheck coverage as soon as the current pass unwinds.
            visualIndexRestartRequested = true
            return
        }
        visualIndexRestartRequested = false
        let generation = visualGenerationID
        visualIndexTask = Task(priority: .utility) {
            defer {
                if visualGenerationID == generation {
                    visualIndexPrewarmInProgress = false
                    visualIndexTask = nil
                    let shouldRestart = visualIndexRestartRequested
                    visualIndexRestartRequested = false
                    if shouldRestart {
                        scheduleVisualIndexing()
                    }
                }
            }
            do {
                var batchLimit = 16
                var indexedSinceLastRerank = 0
                while !Task.isCancelled {
                    let pass = try await runtime.indexNextBatch(limit: batchLimit)
                    guard visualBootstrapCanPublish(generation),
                          visualRecallRuntime != nil else { return }
                    visualEmbeddingCoverage = pass.coverage
                    indexedSinceLastRerank += pass.indexedFrameCount
                    if pass.coverage.pendingEligibleFrameCount == 0 {
                        visualIndexPrewarmInProgress = true
                        try await runtime.prewarmIndex()
                        guard visualBootstrapCanPublish(generation),
                              visualRecallRuntime != nil else { return }
                        visualIndexPrewarmInProgress = false
                        // Coverage was measured before the final await. If a
                        // new durable change arrived meanwhile, let defer start
                        // a fresh pass instead of publishing stale readiness.
                        guard !visualIndexRestartRequested else { return }
                        let becameReady = visualUnderstandingState != .ready
                        visualUnderstandingState = .ready
                        if becameReady {
                            // The first ready state must refine an already
                            // published search immediately.
                            scheduleVisualRerank(debounce: nil)
                        } else {
                            scheduleVisualRerankAfterIndexing(
                                newlyIndexed: indexedSinceLastRerank
                            )
                        }
                        return
                    }
                    if pass.pausedForSystemConditions {
                        visualUnderstandingState = .paused
                        try await Task.sleep(for: .seconds(30))
                        continue
                    }
                    visualUnderstandingState = .indexing
                    if indexedSinceLastRerank >= 32 {
                        scheduleVisualRerank(debounce: .milliseconds(350))
                        indexedSinceLastRerank = 0
                    }
                    if pass.indexedFrameCount == 0 {
                        // A short run of missing/expired thumbnails must not
                        // starve older valid memories. Probe the largest bounded
                        // batch once before reporting an honest paused state.
                        if batchLimit < 256 {
                            batchLimit = 256
                            continue
                        }
                        visualUnderstandingState = .paused
                        return
                    }
                    batchLimit = 16
                    await Task.yield()
                }
            } catch is CancellationError {
                return
            } catch {
                guard visualBootstrapCanPublish(generation) else { return }
                visualUnderstandingState = .error(
                    "Image indexing stopped unexpectedly. Saved-text search still works."
                )
            }
        }
    }

    private func refineCurrentRecallWithVisualRuntimeIfNeeded() {
        guard recallPresentationMode == .bestMatches,
              let scope = loadedRecallScope,
              let operationID = recallOperationID,
              repository != nil else { return }
        let baseline = visualRecallBaseline
        let lexicalHits = baseline?.operationID == operationID
            ? (baseline?.lexicalHits ?? results)
            : results
        scheduleVisualRecall(
            lexicalHits: lexicalHits,
            scope: scope,
            operationID: operationID
        )
    }

    private func scheduleVisualRerankAfterIndexing(newlyIndexed: Int) {
        // A baseline recorded while prewarm deferred its search has never
        // produced visual evidence; refining it is first service, not a
        // steady-state refresh, and must never wait out the throttle.
        let baselineAwaitsFirstService = visualRecallBaseline != nil
            && visualRecallBaseline?.operationID != visualRecallServedOperationID
        if baselineAwaitsFirstService {
            scheduleVisualRerank(debounce: nil)
            return
        }
        // With a served baseline, a rerank can only change the published
        // ranking when new frames entered the index — and in steady state
        // that is one frame per capture, so refreshing is throttled rather
        // than re-run per saved moment.
        guard newlyIndexed > 0 else { return }
        if let scheduledAt = visualRerankScheduledAt,
           ContinuousClock.now - scheduledAt < Self.captureDrivenRefreshInterval {
            return
        }
        scheduleVisualRerank(debounce: nil)
    }

    private func scheduleVisualRerank(debounce: Duration?) {
        visualRerankTask?.cancel()
        if let descriptor = memoryLensSelection {
            visualRerankScheduledAt = ContinuousClock.now
            let generation = visualGenerationID
            visualRerankTask = Task(priority: .utility) {
                defer {
                    if visualGenerationID == generation {
                        visualRerankTask = nil
                    }
                }
                if let debounce {
                    do {
                        try await Task.sleep(for: debounce)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      visualGenerationID == generation,
                      memoryLensSelection == descriptor else { return }
                // Avoid beginRecall cancelling the task that is currently
                // handing off to the independent Memory Lens query.
                visualRerankTask = nil
                _ = scheduleMemoryLens(
                    descriptor: descriptor,
                    scope: metadataOnlyScope(from: recallScope)
                )
            }
            return
        }
        guard let baseline = visualRecallBaseline,
              recallPresentationMode == .bestMatches else { return }
        visualRerankScheduledAt = ContinuousClock.now
        let generation = visualGenerationID
        visualRerankTask = Task(priority: .utility) {
            defer {
                if visualGenerationID == generation {
                    visualRerankTask = nil
                }
            }
            if let debounce {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  visualGenerationID == generation,
                  recallOperationID == baseline.operationID,
                  loadedRecallScope == baseline.scope,
                  repository != nil else { return }
            scheduleVisualRecall(
                lexicalHits: baseline.lexicalHits,
                scope: baseline.scope,
                operationID: baseline.operationID,
                recordsBaseline: false
            )
        }
    }

    @discardableResult
    private func scheduleMemoryLens(
        descriptor: MemoryLensSelectionDescriptor,
        scope: RecallScope
    ) -> Task<Void, Never>? {
        guard memoryLensSelection == descriptor,
              !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              let repository,
              let mediaStore,
              let runtime = visualRecallRuntime else { return nil }

        searchTask?.cancel()
        searchTask = nil
        recallPageTask?.cancel()
        recallPageTask = nil
        if firstMemoryRecallOperationID != nil {
            interruptFirstMemoryRecall()
        }
        memoryLensTask?.cancel()
        let operationID = UUID()
        memoryLensOperationID = operationID
        let recallID = beginRecall(scope: metadataOnlyScope(from: scope), mode: .bestMatches)
        let effectiveScope = recallScope
        let visualGeneration = visualGenerationID
        let lifecycleGeneration = sessionLifecycleGeneration
        visualSearchIsRefining = true
        visualSearchError = nil

        let task = Task(priority: .userInitiated) {
            defer {
                if memoryLensOperationID == operationID {
                    memoryLensTask = nil
                    memoryLensOperationID = nil
                    visualSearchIsRefining = false
                    if recallOperationID == recallID {
                        recallIsLoading = false
                        recallResultsAreStale = false
                    }
                }
            }
            do {
                guard let source = try await repository.frame(id: descriptor.sourceFrameID),
                      Self.isCurrentMemoryLensSource(source, descriptor: descriptor) else {
                    throw MemoryLensSearchError.sourceUnavailable
                }
                try Task.checkCancellation()
                guard memoryLensCanPublish(
                    descriptor: descriptor,
                    operationID: operationID,
                    recallID: recallID,
                    scope: effectiveScope,
                    visualGeneration: visualGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return }
                let imageData = try await mediaStore.read(
                    relativePath: source.imageRelativePath
                )
                try Task.checkCancellation()
                guard memoryLensCanPublish(
                    descriptor: descriptor,
                    operationID: operationID,
                    recallID: recallID,
                    scope: effectiveScope,
                    visualGeneration: visualGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return }
                let queryImage = try await MemoryLensQuery.crop(
                    imageData: imageData,
                    within: descriptor.bounds
                )
                guard memoryLensCanPublish(
                    descriptor: descriptor,
                    operationID: operationID,
                    recallID: recallID,
                    scope: effectiveScope,
                    visualGeneration: visualGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return }
                memoryLensQueryImage = queryImage

                let response = try await runtime.search(
                    image: queryImage,
                    scope: effectiveScope,
                    excluding: descriptor.sourceFrameID,
                    minimumSimilarity: Self.visualRetrievalSimilarityFloor,
                    limit: 60,
                    candidateLimit: 2_048
                )
                guard response.evidenceKind == .imageToImageSimilarity else {
                    throw MemoryLensSearchError.unexpectedEvidence
                }
                guard let currentSource = try await repository.frame(
                    id: descriptor.sourceFrameID
                ), Self.isCurrentMemoryLensSource(
                    currentSource,
                    descriptor: descriptor
                ) else {
                    throw MemoryLensSearchError.sourceUnavailable
                }
                var safeMatches = [VisualEmbeddingMatch]()
                safeMatches.reserveCapacity(response.matches.count)
                for match in response.matches {
                    try Task.checkCancellation()
                    guard memoryLensCanPublish(
                        descriptor: descriptor,
                        operationID: operationID,
                        recallID: recallID,
                        scope: effectiveScope,
                        visualGeneration: visualGeneration,
                        lifecycleGeneration: lifecycleGeneration
                    ) else { return }
                    guard match.hit.id != descriptor.sourceFrameID,
                          let fingerprint = match.sourceVisualFingerprint,
                          let currentFrame = try await repository.frame(id: match.hit.id),
                          currentFrame.visualFingerprint == fingerprint,
                          Self.isEligibleMemoryLensResult(
                            currentFrame,
                            scope: effectiveScope
                          ) else { continue }
                    var currentHit = Self.searchHit(for: currentFrame)
                    // FrameRepository does not expose authoritative current
                    // session membership. Nil is safer than copying a session
                    // ID from the pre-retention visual snapshot.
                    currentHit.activitySessionID = nil
                    currentHit.score = match.hit.score
                    safeMatches.append(VisualEmbeddingMatch(
                        hit: currentHit,
                        similarity: match.similarity,
                        maximumSimilarityError: match.maximumSimilarityError,
                        model: match.model,
                        // The representative itself is revalidated here. A
                        // prior association count may have changed during
                        // retention, so do not repeat it as current evidence.
                        associatedFrameCount: 1,
                        sourceVisualFingerprint: currentFrame.visualFingerprint
                    ))
                }
                guard let finalSource = try await repository.frame(
                    id: descriptor.sourceFrameID
                ), Self.isCurrentMemoryLensSource(
                    finalSource,
                    descriptor: descriptor
                ) else {
                    throw MemoryLensSearchError.sourceUnavailable
                }
                let fused = HybridRecallRanker.fuse(
                    lexicalHits: [],
                    visualMatches: safeMatches,
                    policy: HybridRecallPolicy(
                        minimumVisualSimilarity: Self.minimumVisualRecallSimilarity,
                        resultLimit: 60
                    )
                )
                guard memoryLensCanPublish(
                    descriptor: descriptor,
                    operationID: operationID,
                    recallID: recallID,
                    scope: effectiveScope,
                    visualGeneration: visualGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return }

                results = fused.hits
                visualRecallEvidenceByFrameID = fused.visualEvidenceByFrameID
                visualOnlyRecallFrameIDs = fused.visuallyRankedFrameIDs
                recallCursor = nil
                recallHasMore = false
                loadedRecallScope = effectiveScope
                recallBaseFacets = RecallFacets()
                recallFacets = Self.facets(admittedByHybridRecall: fused.hits)
                recallBrowserMomentAvailability = .unknown
                recallFacetsError = nil
                recallQueryInterpretation = nil
                searchError = nil
                visualSearchError = nil
                refreshRecallTimeLensBoundsIfIdle()
                select(fused.hits.first)
            } catch is CancellationError {
                return
            } catch {
                guard memoryLensCanPublish(
                    descriptor: descriptor,
                    operationID: operationID,
                    recallID: recallID,
                    scope: effectiveScope,
                    visualGeneration: visualGeneration,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return }
                if let lensError = error as? MemoryLensSearchError,
                   case .sourceUnavailable = lensError {
                    memoryLensQueryImage = nil
                }
                // Never leave unrelated chronological rows underneath a failed
                // visual query as though they were similar to the selection.
                results = []
                visualRecallEvidenceByFrameID = [:]
                visualOnlyRecallFrameIDs = []
                recallCursor = nil
                recallHasMore = false
                loadedRecallScope = effectiveScope
                recallBaseFacets = RecallFacets()
                recallFacets = RecallFacets(applications: [], domains: [])
                recallBrowserMomentAvailability = .unknown
                recallFacetsError = nil
                recallQueryInterpretation = nil
                select(nil)
                searchError = "Passage couldn’t compare that selected area. Try again in a moment."
                visualSearchError = nil
            }
        }
        memoryLensTask = task
        return task
    }

    private func memoryLensCanPublish(
        descriptor: MemoryLensSelectionDescriptor,
        operationID: UUID,
        recallID: UUID,
        scope: RecallScope,
        visualGeneration: UUID,
        lifecycleGeneration: UUID
    ) -> Bool {
        !Task.isCancelled
            && !sessionIsLocked
            && !historyDeletionInProgress
            && !retentionMutationInProgress
            && memoryLensSelection == descriptor
            && memoryLensOperationID == operationID
            && recallOperationID == recallID
            && recallScope == scope
            && visualGenerationID == visualGeneration
            && sessionLifecycleGeneration == lifecycleGeneration
            && repository != nil
            && mediaStore != nil
            && visualRecallRuntime != nil
    }

    private static func isCurrentMemoryLensSource(
        _ frame: FrameDocument,
        descriptor: MemoryLensSelectionDescriptor
    ) -> Bool {
        frame.id == descriptor.sourceFrameID
            && frame.visualFingerprint == descriptor.sourceVisualFingerprint
            && !frame.context.isSensitive
            && !frame.imageRelativePath.isEmpty
    }

    private static func isEligibleMemoryLensResult(
        _ frame: FrameDocument,
        scope: RecallScope
    ) -> Bool {
        guard !frame.context.isSensitive,
              !frame.imageRelativePath.isEmpty,
              scope.startDate.map({ frame.capturedAt >= $0 }) ?? true,
              scope.endDate.map({ frame.capturedAt < $0 }) ?? true,
              scope.applicationBundleIdentifiers.isEmpty
                || frame.context.bundleIdentifier.map(
                    scope.applicationBundleIdentifiers.contains
                ) == true else { return false }
        if !scope.domains.isEmpty {
            guard let domain = frame.context.domain?.lowercased(),
                  scope.domains.contains(domain) else { return false }
        }
        return true
    }

    @discardableResult
    private func cancelMemoryLens(clearReturnContext: Bool) -> Task<Void, Never>? {
        let task = memoryLensTask
        task?.cancel()
        memoryLensTask = nil
        memoryLensOperationID = nil
        memoryLensSelection = nil
        memoryLensQueryImage = nil
        if clearReturnContext {
            memoryLensReturnContext = nil
        }
        return task
    }

    private func metadataOnlyScope(from scope: RecallScope) -> RecallScope {
        RecallScope(
            startDate: scope.startDate,
            endDate: scope.endDate,
            applicationBundleIdentifiers: scope.applicationBundleIdentifiers,
            domains: scope.domains
        )
    }

    private func cancelVisualWork() -> [Task<Void, Never>] {
        visualGenerationID = UUID()
        let tasks = [
            visualBootstrapTask,
            visualIndexTask,
            visualSearchTask,
            visualRerankTask,
            memoryLensTask,
        ].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        visualBootstrapTask = nil
        visualIndexTask = nil
        visualIndexRestartRequested = false
        visualIndexPrewarmInProgress = false
        visualBootstrapCandidateRuntime?.revoke()
        visualBootstrapCandidateRuntime = nil
        visualBootstrapCandidateGeneration = nil
        visualSearchTask = nil
        visualSearchOperationID = nil
        visualRerankTask = nil
        visualRecallBaseline = nil
        memoryLensTask = nil
        memoryLensOperationID = nil
        memoryLensSelection = nil
        memoryLensQueryImage = nil
        memoryLensReturnContext = nil
        visualSearchIsRefining = false
        visualSearchError = nil
        visualRecallEvidenceByFrameID = [:]
        visualOnlyRecallFrameIDs = []
        return tasks
    }

    @discardableResult
    private func scheduleRecall(
        scope: RecallScope,
        debounce: Duration?,
        allowsInterpretation: Bool
    ) -> (operationID: UUID, task: Task<Void, Never>) {
        if memoryLensSelection != nil {
            cancelMemoryLens(clearReturnContext: true)
        }
        let requestedScope = timelineWorkspaceTransaction.map {
            TimelineWorkspaceScope.dayScope(for: $0.day)
        } ?? scope
        let continuingFirstMemoryProof: Bool
        if case .recallSearching(let candidate) = firstMemoryActivationState {
            continuingFirstMemoryProof = requestedScope == RecallScope(text: candidate.query)
        } else {
            continuingFirstMemoryProof = false
        }
        if firstMemoryRecallOperationID != nil, !continuingFirstMemoryProof {
            interruptFirstMemoryRecall()
        }
        searchTask?.cancel()
        recallPageTask?.cancel()
        let mode: RecallPresentationMode
        if requestedScope.text.isEmpty || timelineWorkspaceTransaction != nil {
            mode = .chronological
        } else {
            mode = recallSearchMode == .bestMatches ? .bestMatches : .savedTextOnly
        }
        let shouldInterpret = mode == .bestMatches && allowsInterpretation
        let operationID = beginRecall(scope: requestedScope, mode: mode)
        if continuingFirstMemoryProof {
            firstMemoryRecallOperationID = operationID
        }
        let task = Task {
            if let debounce {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            await performRecall(
                scope: requestedScope,
                operationID: operationID,
                allowsInterpretation: shouldInterpret
            )
        }
        searchTask = task
        return (operationID, task)
    }

    @discardableResult
    private func beginRecall(
        scope: RecallScope,
        mode: RecallPresentationMode
    ) -> UUID {
        invalidateRecallTimeLens(restoreBaseline: false)
        cancelRecallFacets()
        visualSearchTask?.cancel()
        visualSearchTask = nil
        visualRerankTask?.cancel()
        visualRerankTask = nil
        visualRecallBaseline = nil
        let operationID = UUID()
        recallOperationID = operationID
        recallScope = scope
        recallPresentationMode = mode
        visualRecallEvidenceByFrameID = [:]
        visualOnlyRecallFrameIDs = []
        visualSearchIsRefining = false
        visualSearchError = nil
        recallCursor = nil
        loadedRecallScope = nil
        recallTimeLensBounds = nil
        recallHasMore = false
        recallIsLoadingMore = false
        recallQueryInterpretation = nil
        recallBaseFacets = RecallFacets()
        recallFacets = RecallFacets()
        recallBrowserMomentAvailability = .unknown
        recallFacetsError = nil
        searchError = nil
        recallResultsAreStale = !results.isEmpty
        recallIsLoading = true
        return operationID
    }

    private func performRecall(
        scope: RecallScope,
        operationID: UUID,
        allowsInterpretation: Bool
    ) async {
        guard !retentionMutationInProgress,
              let repository else {
            if recallOperationID == operationID {
                recallIsLoading = false
                recallResultsAreStale = false
            }
            return
        }
        let mode = recallPresentationMode
        defer {
            if recallOperationID == operationID {
                recallIsLoading = false
                recallResultsAreStale = false
            }
        }

        do {
            let page: RecallPage
            let interpretationUsed: RecallQueryInterpretation?
            let effectiveScope: RecallScope

            if scope.text.isEmpty {
                page = try await lexicalRecallPage(
                    repository: repository,
                    scope: scope,
                    mode: mode
                )
                interpretationUsed = nil
                effectiveScope = scope
            } else {
                let interpretation = allowsInterpretation
                    ? RecallQueryInterpreter().interpret(scope.text)
                    : nil

                if let interpretation,
                   interpretation.temporalScope != nil {
                    // Temporal wording is not an OCR term. Apply the visible,
                    // deterministic date filter directly so "last week" does
                    // not guarantee an empty strict pass first.
                    effectiveScope = Self.applying(interpretation, to: scope)
                    page = try await lexicalRecallPage(
                        repository: repository,
                        scope: effectiveScope,
                        mode: mode
                    )
                    interpretationUsed = interpretation
                } else {
                    let strict = try await lexicalRecallPage(
                        repository: repository,
                        scope: scope,
                        mode: mode
                    )
                    if strict.hits.isEmpty, let interpretation {
                        effectiveScope = Self.applying(interpretation, to: scope)
                        page = try await lexicalRecallPage(
                            repository: repository,
                            scope: effectiveScope,
                            mode: mode
                        )
                        interpretationUsed = interpretation
                    } else {
                        page = strict
                        interpretationUsed = nil
                        effectiveScope = scope
                    }
                }
            }

            var publishedHits = page.hits
            if let transaction = timelineWorkspaceTransaction,
               let anchor = transaction.anchor,
               TimelineWorkspaceScope.dayScope(for: transaction.day) == effectiveScope,
               !publishedHits.contains(where: { $0.id == anchor.id }) {
                // Timeline's newest page is intentionally small. A search
                // result can be much older, so retrieve the page ending at
                // that exact moment and merge it into the visible stream. The
                // normal newest-page cursor remains intact and can still fill
                // the interval progressively.
                let anchorContextHits: [SearchHit]
                if let anchorScope = RecallTimeLensQuery.scope(
                    atOrBefore: anchor.capturedAt,
                    preserving: effectiveScope
                ) {
                    anchorContextHits = (try? await repository.recall(
                        anchorScope,
                        after: nil,
                        limit: 60
                    ).hits) ?? []
                } else {
                    anchorContextHits = []
                }
                publishedHits = Self.mergingNewestRecallPage(
                    anchorContextHits + [anchor],
                    into: publishedHits
                )
            }

            guard !Task.isCancelled,
                  !retentionMutationInProgress,
                  recallOperationID == operationID else { return }
            results = publishedHits
            publishFirstMemoryRecallResult(
                operationID: operationID,
                hits: publishedHits
            )
            recallCursor = page.nextCursor
            recallHasMore = page.hasMore
            loadedRecallScope = effectiveScope
            recallBaseFacets = RecallFacets()
            recallFacets = RecallFacets(applications: [], domains: [])
            recallBrowserMomentAvailability = .unknown
            recallQueryInterpretation = interpretationUsed
            searchError = nil
            refreshRecallTimeLensBoundsIfIdle()
            reconcileRecallSelection(afterPublishing: publishedHits)
            scheduleRecallFacets(
                scope: effectiveScope,
                expectedLoadedScope: effectiveScope,
                recallOperationID: operationID,
                repository: repository
            )
            if mode == .bestMatches {
                scheduleVisualRecall(
                    lexicalHits: publishedHits,
                    scope: effectiveScope,
                    operationID: operationID
                )
            }
        } catch {
            guard !Task.isCancelled,
                  !retentionMutationInProgress,
                  recallOperationID == operationID else { return }
            failFirstMemoryRecall(
                operationID: operationID,
                message: "Search couldn’t finish: \(error.localizedDescription)"
            )
            results = []
            recallCursor = nil
            recallHasMore = false
            loadedRecallScope = nil
            recallTimeLensBounds = nil
            recallBaseFacets = RecallFacets()
            recallFacets = RecallFacets(applications: [], domains: [])
            recallBrowserMomentAvailability = .unknown
            recallQueryInterpretation = nil
            searchError = error.localizedDescription
        }
    }

    private func publishFirstMemoryRecallResult(
        operationID: UUID,
        hits: [SearchHit]
    ) {
        guard firstMemoryRecallOperationID == operationID,
              case .recallSearching(let candidate) = firstMemoryActivationState else { return }
        firstMemoryRecallOperationID = nil
        guard let exactHit = hits.first(where: { $0.id == candidate.frameID }) else {
            firstMemoryActivationState = .recallFailed(
                candidate,
                "Search finished, but that exact saved moment was not in the results. Your memory is still saved."
            )
            return
        }
        firstMemoryActivationStore.save(.verified(candidate.frameID))
        firstMemoryActivationState = .verified(candidate.frameID)
        select(exactHit)
    }

    private func failFirstMemoryRecall(operationID: UUID, message: String) {
        guard firstMemoryRecallOperationID == operationID,
              case .recallSearching(let candidate) = firstMemoryActivationState else { return }
        firstMemoryRecallOperationID = nil
        firstMemoryActivationState = .recallFailed(candidate, message)
    }

    private func interruptFirstMemoryRecall() {
        guard case .recallSearching(let candidate) = firstMemoryActivationState else {
            firstMemoryRecallOperationID = nil
            return
        }
        firstMemoryRecallOperationID = nil
        firstMemoryActivationState = .recallFailed(
            candidate,
            "That proof search was interrupted. Your saved memory is unchanged."
        )
    }

    private func lexicalRecallPage(
        repository: any PassageModelRepository,
        scope: RecallScope,
        mode: RecallPresentationMode
    ) async throws -> RecallPage {
        if mode != .chronological,
           let rankedRepository = repository as? any RankedRecallRepository {
            return RecallPage(
                hits: try await rankedRepository.rankedRecall(scope, limit: 60),
                nextCursor: nil,
                hasMore: false
            )
        }
        return try await repository.recall(scope, after: nil, limit: 60)
    }

    /// PE-Core-S-16-384 proxy calibration put useful appearance matches above
    /// 0.245 after accounting for the measured Int8 cosine error. The index
    /// retrieves a slightly wider band so the conservative lower bound in the
    /// ranker, rather than storage rounding, owns admission.
    private static let minimumVisualRecallSimilarity = 0.245
    private static let visualRetrievalSimilarityFloor = 0.235
    private func scheduleVisualRecall(
        lexicalHits: [SearchHit],
        scope: RecallScope,
        operationID: UUID,
        recordsBaseline: Bool = true
    ) {
        visualSearchTask?.cancel()
        visualSearchTask = nil
        visualSearchOperationID = nil
        if recordsBaseline,
           !scope.text.isEmpty,
           recallOperationID == operationID,
           recallPresentationMode == .bestMatches {
            visualRecallBaseline = VisualRecallBaseline(
                operationID: operationID,
                scope: scope,
                lexicalHits: lexicalHits
            )
        }
        guard let runtime = visualRecallRuntime,
              !scope.text.isEmpty,
              recallOperationID == operationID,
              recallPresentationMode == .bestMatches,
              !visualIndexPrewarmInProgress else { return }

        visualRecallServedOperationID = operationID
        visualSearchIsRefining = true
        visualSearchError = nil
        let visualOperationID = UUID()
        visualSearchOperationID = visualOperationID
        let lexicalIDs = Set(lexicalHits.map(\.id))
        let visualGeneration = visualGenerationID
        visualSearchTask = Task(priority: .userInitiated) {
            defer {
                if visualSearchOperationID == visualOperationID {
                    visualSearchIsRefining = false
                    visualSearchTask = nil
                    visualSearchOperationID = nil
                }
            }
            do {
                let response = try await runtime.search(
                    text: scope.text,
                    scope: scope,
                    minimumSimilarity: VisualRegionQueryEligibility.shouldRerank(scope.text)
                        ? -1
                        : Self.visualRetrievalSimilarityFloor,
                    limit: 60,
                    candidateLimit: 2_048
                )
                let fused = HybridRecallRanker.fuse(
                    lexicalHits: lexicalHits,
                    visualMatches: response.matches,
                    policy: HybridRecallPolicy(
                        minimumVisualSimilarity: Self.minimumVisualRecallSimilarity,
                        resultLimit: 60
                    )
                )
                guard publishVisualRecall(
                    fused,
                    lexicalIDs: lexicalIDs,
                    scope: scope,
                    recallOperationID: operationID,
                    visualOperationID: visualOperationID,
                    visualGeneration: visualGeneration
                ) else { return }

                let regionThresholds = VisualRegionQueryEligibility
                    .similarityThresholds(for: scope.text)
                let regionResponse = try await runtime.rerankRegions(
                    text: scope.text,
                    matches: response.matches,
                    policy: VisualRegionRerankingPolicy(
                        candidateFrameLimit: 12,
                        embeddingLimit: 8,
                        regionsPerFrameLimit: 2,
                        minimumRegionSimilarity: regionThresholds.minimumSimilarity,
                        minimumSimilarityGain: regionThresholds.minimumGain,
                        maximumDurationMilliseconds: 850
                    )
                )
                guard !regionResponse.evidenceByFrameID.isEmpty else { return }
                let regionFused = HybridRecallRanker.fuse(
                    lexicalHits: lexicalHits,
                    visualMatches: regionResponse.matches,
                    regionEvidenceByFrameID: regionResponse.evidenceByFrameID,
                    policy: HybridRecallPolicy(
                        minimumVisualSimilarity: Self.minimumVisualRecallSimilarity,
                        resultLimit: 60
                    )
                )
                _ = publishVisualRecall(
                    regionFused,
                    lexicalIDs: lexicalIDs,
                    scope: scope,
                    recallOperationID: operationID,
                    visualOperationID: visualOperationID,
                    visualGeneration: visualGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard visualSearchOperationID == visualOperationID,
                      recallOperationID == operationID,
                      loadedRecallScope == scope else { return }
                visualSearchError = "Image matching could not update. Saved-text results are shown."
            }
        }
    }

    @discardableResult
    private func publishVisualRecall(
        _ fused: HybridRecallResult,
        lexicalIDs: Set<FrameID>,
        scope: RecallScope,
        recallOperationID operationID: UUID,
        visualOperationID: UUID,
        visualGeneration: UUID
    ) -> Bool {
        guard !Task.isCancelled,
              !sessionIsLocked,
              !historyDeletionInProgress,
              !retentionMutationInProgress,
              visualGenerationID == visualGeneration,
              self.visualSearchOperationID == visualOperationID,
              self.recallOperationID == operationID,
              recallPresentationMode == .bestMatches,
              loadedRecallScope == scope else { return false }
        results = fused.hits
        visualRecallEvidenceByFrameID = fused.visualEvidenceByFrameID
        visualOnlyRecallFrameIDs = fused.visuallyRankedFrameIDs.subtracting(lexicalIDs)
        visualSearchError = nil
        recallCursor = nil
        recallHasMore = false
        reconcileRecallSelection(afterPublishing: fused.hits)
        // Keep the uncapped, drill-sideways store read alive. Facets derived
        // only from this already-filtered top-60 result set would make valid
        // alternatives disappear after choosing one app or website.
        recallFacets = Self.mergingFacetAlternatives(
            recallBaseFacets,
            admittedByHybridRecall: fused.hits,
            selectedApplications: scope.applicationBundleIdentifiers,
            selectedDomains: scope.domains
        )
        return true
    }

    /// Facets derived from hybrid hits supplement the repository's uncapped
    /// saved-text alternatives. They cannot replace that drill-sideways read:
    /// the fused set is both filtered and capped before it reaches this model.
    private static func facets(
        admittedByHybridRecall hits: [SearchHit]
    ) -> RecallFacets {
        var applications: [String: (name: String, count: Int)] = [:]
        var domains: [String: Int] = [:]
        for hit in hits {
            if let identifier = hit.context.bundleIdentifier, !identifier.isEmpty {
                let existing = applications[identifier]
                applications[identifier] = (
                    name: existing?.name ?? hit.context.applicationName,
                    count: (existing?.count ?? 0) + 1
                )
            }
            if let domain = hit.context.domain?.lowercased(), !domain.isEmpty {
                domains[domain, default: 0] += 1
            }
        }
        let applicationFacets = applications.map { identifier, value in
            RecallApplicationFacet(
                bundleIdentifier: identifier,
                applicationName: value.name,
                frameCount: value.count
            )
        }.sorted {
            if $0.frameCount == $1.frameCount {
                return $0.applicationName.localizedCaseInsensitiveCompare(
                    $1.applicationName
                ) == .orderedAscending
            }
            return $0.frameCount > $1.frameCount
        }
        let domainFacets = domains.map { domain, count in
            RecallDomainFacet(domain: domain, frameCount: count)
        }.sorted {
            if $0.frameCount == $1.frameCount { return $0.domain < $1.domain }
            return $0.frameCount > $1.frameCount
        }
        return RecallFacets(
            applications: Array(applicationFacets.prefix(40)),
            domains: Array(domainFacets.prefix(40))
        )
    }

    private static func mergingFacetAlternatives(
        _ base: RecallFacets,
        admittedByHybridRecall hits: [SearchHit],
        selectedApplications: Set<String>,
        selectedDomains: Set<String>
    ) -> RecallFacets {
        let hybrid = facets(admittedByHybridRecall: hits)
        var applications = Dictionary(uniqueKeysWithValues: base.applications.map {
            ($0.bundleIdentifier, $0)
        })
        for facet in hybrid.applications where applications[facet.bundleIdentifier] == nil {
            applications[facet.bundleIdentifier] = facet
        }
        var domains = Dictionary(uniqueKeysWithValues: base.domains.map { ($0.domain, $0) })
        for facet in hybrid.domains where domains[facet.domain] == nil {
            domains[facet.domain] = facet
        }

        let sortedApplications = applications.values.sorted {
            let lhsSelected = selectedApplications.contains($0.bundleIdentifier)
            let rhsSelected = selectedApplications.contains($1.bundleIdentifier)
            if lhsSelected != rhsSelected { return lhsSelected }
            if $0.frameCount == $1.frameCount {
                return $0.applicationName.localizedCaseInsensitiveCompare(
                    $1.applicationName
                ) == .orderedAscending
            }
            return $0.frameCount > $1.frameCount
        }
        let sortedDomains = domains.values.sorted {
            let lhsSelected = selectedDomains.contains($0.domain)
            let rhsSelected = selectedDomains.contains($1.domain)
            if lhsSelected != rhsSelected { return lhsSelected }
            if $0.frameCount == $1.frameCount { return $0.domain < $1.domain }
            return $0.frameCount > $1.frameCount
        }

        // Each source is independently capped at 40, so the union remains a
        // bounded menu (at most 80) without discarding either drill-sideways
        // alternatives or currently admitted visual-only choices.
        return RecallFacets(
            applications: sortedApplications,
            domains: sortedDomains,
            browserMomentCount: base.browserMomentCount
        )
    }

    /// While the recall surface has no visible audience — the scene is
    /// backgrounded, or the main window is closed or fully covered —
    /// per-capture recall refreshes are deferred into one pending flag;
    /// capture, encryption, and indexing are unaffected. The single
    /// coalesced refresh runs when a window returns, so a reopened surface
    /// never shows stale evidence for more than one reconciliation pass.
    func setScenePhaseBackgrounded(_ backgrounded: Bool) {
        sceneIsBackgrounded = backgrounded
        applyRecallSurfaceDormancy()
    }

    public func setMainWindowVisible(_ visible: Bool) {
        mainWindowIsVisible = visible
        applyRecallSurfaceDormancy()
    }

    private func applyRecallSurfaceDormancy() {
        let dormant = sceneIsBackgrounded || !mainWindowIsVisible
        guard recallSurfaceIsDormant != dormant else { return }
        recallSurfaceIsDormant = dormant
        guard !dormant, let pendingFullReload = dormantCaptureRefresh else { return }
        dormantCaptureRefresh = nil
        scheduleCaptureRefresh(debounce: nil, requiresFullReload: pendingFullReload)
    }

    private func scheduleCaptureRefresh(
        debounce: Duration?,
        requiresFullReload: Bool = false
    ) {
        if recallSurfaceIsDormant {
            dormantCaptureRefresh = (dormantCaptureRefresh ?? false) || requiresFullReload
            return
        }
        captureRefreshTask?.cancel()
        captureRefreshRequiresFullReload = captureRefreshRequiresFullReload || requiresFullReload
        let refreshID = UUID()
        captureRefreshOperationID = refreshID
        captureRefreshTask = Task {
            if let debounce {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  captureRefreshOperationID == refreshID else { return }
            let shouldReloadEverything = captureRefreshRequiresFullReload
            await refreshAfterCapture(
                operationID: refreshID,
                requiresFullReload: shouldReloadEverything
            )
            if captureRefreshOperationID == refreshID {
                captureRefreshTask = nil
                captureRefreshOperationID = nil
                captureRefreshRequiresFullReload = false
            }
        }
    }

    /// Refreshes the newest edge without throwing away an already-walked
    /// cursor. New captures can arrive every few seconds; replacing the whole
    /// stream here would otherwise make the oldest retained history impossible
    /// to reach while remembering is active.
    private func refreshAfterCapture(
        operationID: UUID,
        requiresFullReload: Bool
    ) async {
        guard let repository else { return }

        do {
            if memoryLensSelection != nil {
                // A capture refresh must never replace a visual query with an
                // unrelated empty-text browse. The next completed visual-index
                // pass reruns Memory Lens; this path only refreshes library
                // bounds while keeping the current similarity result stable.
                statistics = try await repository.statistics()
                refreshRecallTimeLensBoundsIfIdle()
                return
            }
            if requiresFullReload {
                let scheduled = scheduleRecall(
                    scope: currentRecallScope(text: queryText),
                    debounce: nil,
                    allowsInterpretation: !recallUsesOriginalWording
                )
                await scheduled.task.value
                guard !Task.isCancelled,
                      !sessionIsLocked,
                      captureRefreshOperationID == operationID,
                      recallOperationID == scheduled.operationID else { return }
                await refreshActivityData()
                return
            }
            guard !recallIsLoading,
                  let recallOperationID,
                  let scope = loadedRecallScope else { return }
            if recallPresentationMode != .chronological {
                let mode = recallPresentationMode
                let now = ContinuousClock.now
                if let lastRefresh = rankedCaptureRefreshAt,
                   now - lastRefresh < Self.captureDrivenRefreshInterval {
                    // The published ranking stays authoritative for its query;
                    // a new capture only advances the library bounds until the
                    // next periodic re-rank or an explicit new search.
                    let refreshedStatistics = try await repository.statistics()
                    guard captureRefreshCanPublish(
                        operationID: operationID,
                        recallOperationID: recallOperationID,
                        scope: scope
                    ) else { return }
                    statistics = refreshedStatistics
                    refreshRecallTimeLensBoundsIfIdle()
                    return
                }
                let page = try await lexicalRecallPage(
                    repository: repository,
                    scope: scope,
                    mode: mode
                )
                let refreshedStatistics = try await repository.statistics()
                guard captureRefreshCanPublish(
                    operationID: operationID,
                    recallOperationID: recallOperationID,
                    scope: scope
                ) else { return }
                rankedCaptureRefreshAt = now
                results = page.hits
                visualRecallEvidenceByFrameID = [:]
                visualOnlyRecallFrameIDs = []
                reconcileRecallSelection(afterPublishing: page.hits)
                scheduleCaptureDrivenRecallFacets(
                    scope: scope,
                    expectedLoadedScope: scope,
                    recallOperationID: recallOperationID,
                    repository: repository
                )
                if mode == .bestMatches {
                    scheduleVisualRecall(
                        lexicalHits: page.hits,
                        scope: scope,
                        operationID: recallOperationID
                    )
                }
                statistics = refreshedStatistics
                refreshRecallTimeLensBoundsIfIdle()
                return
            }
            let page = try await repository.recall(scope, after: nil, limit: 60)
            let refreshedStatistics = try await repository.statistics()
            guard captureRefreshCanPublish(
                operationID: operationID,
                recallOperationID: recallOperationID,
                scope: scope
            ) else { return }

            let publishedHits = Self.mergingNewestRecallPage(page.hits, into: results)
            results = publishedHits
            reconcileRecallSelection(afterPublishing: publishedHits)
            statistics = refreshedStatistics
            refreshRecallTimeLensBoundsIfIdle()
            scheduleCaptureDrivenRecallFacets(
                scope: scope,
                recallOperationID: recallOperationID,
                repository: repository
            )
            // A head insertion cannot invalidate the existing exclusive tail
            // cursor. Preserve it even when it is nil: nil may mean the person
            // already reached the oldest retained moment, not "first page".
        } catch {
            // Continuous capture maintenance is best effort. A foreground
            // search or explicit refresh remains the place to surface a read
            // failure; background maintenance must not replace valid results
            // with an alarming transient error.
        }
    }

    /// Capture-driven facet refreshes reuse counts that are still fresh for
    /// the same scope. With any filter active, facet aggregation is a full
    /// GROUP BY over history — too expensive to repeat for every saved
    /// moment when the visible counts drift by at most a few frames.
    private func scheduleCaptureDrivenRecallFacets(
        scope: RecallScope,
        expectedLoadedScope: RecallScope? = nil,
        recallOperationID expectedRecallOperationID: UUID,
        repository: any PassageModelRepository
    ) {
        if let scheduledAt = recallFacetsScheduledAt,
           recallFacetsScheduledScope == scope,
           ContinuousClock.now - scheduledAt < Self.captureDrivenRefreshInterval {
            return
        }
        scheduleRecallFacets(
            scope: scope,
            expectedLoadedScope: expectedLoadedScope,
            recallOperationID: expectedRecallOperationID,
            repository: repository
        )
    }

    private func scheduleRecallFacets(
        scope: RecallScope,
        expectedLoadedScope: RecallScope? = nil,
        recallOperationID expectedRecallOperationID: UUID,
        repository: any PassageModelRepository
    ) {
        cancelRecallFacets()
        recallFacetsScheduledAt = ContinuousClock.now
        recallFacetsScheduledScope = scope
        let operationID = UUID()
        recallFacetsOperationID = operationID
        recallFacetsAreLoading = true
        recallFacetsError = nil
        recallBrowserMomentAvailability = .loading
        recallFacetsTask = Task {
            defer { finishRecallFacetsOperation(operationID) }
            do {
                let facets = try await repository.recallFacets(scope, limitPerKind: 40)
                guard !Task.isCancelled,
                      recallFacetsOperationID == operationID,
                      recallOperationID == expectedRecallOperationID,
                      loadedRecallScope == (expectedLoadedScope ?? scope) else { return }
                recallBaseFacets = facets
                recallFacets = recallPresentationMode == .bestMatches
                    ? Self.mergingFacetAlternatives(
                        facets,
                        admittedByHybridRecall: results,
                        selectedApplications: scope.applicationBundleIdentifiers,
                        selectedDomains: scope.domains
                    )
                    : facets
                recallBrowserMomentAvailability = facets.browserMomentCount.map {
                    .available(count: max($0, 0))
                } ?? .unknown
                recallFacetsError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      recallFacetsOperationID == operationID,
                      recallOperationID == expectedRecallOperationID,
                      loadedRecallScope == (expectedLoadedScope ?? scope) else { return }
                // Filter counts are secondary to Recall, but silently
                // translating their failure into “no history” is misleading.
                recallFacetsError = "App and website filters couldn’t be updated."
                recallBrowserMomentAvailability = .error
            }
        }
    }

    private func cancelRecallFacets() {
        recallFacetsTask?.cancel()
        recallFacetsTask = nil
        recallFacetsOperationID = nil
        recallFacetsAreLoading = false
    }

    private func finishRecallFacetsOperation(_ operationID: UUID) {
        guard recallFacetsOperationID == operationID else { return }
        recallFacetsTask = nil
        recallFacetsOperationID = nil
        recallFacetsAreLoading = false
    }

    private func captureRefreshCanPublish(
        operationID: UUID,
        recallOperationID expectedRecallOperationID: UUID,
        scope: RecallScope
    ) -> Bool {
        !Task.isCancelled
            && captureRefreshOperationID == operationID
            && self.recallOperationID == expectedRecallOperationID
            && loadedRecallScope == scope
            && !recallIsLoading
    }

    static func mergingNewestRecallPage(
        _ newestHits: [SearchHit],
        into existingHits: [SearchHit]
    ) -> [SearchHit] {
        var seen = Set<FrameID>()
        return (newestHits + existingHits)
            .sorted(by: Self.recallHitIsNewer)
            .filter { seen.insert($0.id).inserted }
    }

    private static func recallHitIsNewer(_ lhs: SearchHit, _ rhs: SearchHit) -> Bool {
        if lhs.capturedAt == rhs.capturedAt {
            return lhs.id.rawValue > rhs.id.rawValue
        }
        return lhs.capturedAt > rhs.capturedAt
    }

    private func startRecallTimeLensPreviewPumpIfNeeded(sessionID: UUID) {
        guard recallTimeLensTask == nil,
              let repository,
              let scope = recallTimeLensScope else { return }
        let expectedRecallOperationID = recallTimeLensRecallOperationID
        let taskID = UUID()
        recallTimeLensTaskID = taskID
        recallTimeLensTask = Task {
            while !Task.isCancelled {
                guard recallTimeLensSessionID == sessionID,
                      recallTimeLensScope == scope else { return }

                if let lastStarted = recallTimeLensLastSeekStartedAt {
                    let elapsed = lastStarted.duration(to: recallTimeLensClock.now)
                    if let delay = RecallTimeLensThrottle.remainingDelay(after: elapsed) {
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            return
                        }
                    }
                }

                guard !Task.isCancelled,
                      recallTimeLensSessionID == sessionID,
                      let target = recallTimeLensPendingTarget else { break }
                let sequence = recallTimeLensRequestSequence
                recallTimeLensPendingTarget = nil
                recallTimeLensLastSeekStartedAt = recallTimeLensClock.now

                guard let seekScope = RecallTimeLensQuery.scope(
                    atOrBefore: target,
                    preserving: scope
                ) else {
                    if recallTimeLensCanPublish(
                        sessionID: sessionID,
                        sequence: sequence,
                        scope: scope,
                        expectedRecallOperationID: expectedRecallOperationID
                    ) {
                        recallTimeLensPreview = RecallTimeLensPreview(
                            requestedAt: target,
                            hit: nil,
                            resolution: .resolved
                        )
                    }
                    continue
                }

                do {
                    let page = try await repository.recall(
                        seekScope,
                        after: nil,
                        limit: 1
                    )
                    guard recallTimeLensCanPublish(
                        sessionID: sessionID,
                        sequence: sequence,
                        scope: scope,
                        expectedRecallOperationID: expectedRecallOperationID
                    ) else { continue }
                    recallTimeLensPreview = RecallTimeLensPreview(
                        requestedAt: target,
                        hit: page.hits.first,
                        resolution: .resolved
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    if recallTimeLensCanPublish(
                        sessionID: sessionID,
                        sequence: sequence,
                        scope: scope,
                        expectedRecallOperationID: expectedRecallOperationID
                    ) {
                        recallTimeLensPreview = RecallTimeLensPreview(
                            requestedAt: target,
                            hit: recallTimeLensPreview?.hit,
                            resolution: .failed
                        )
                    }
                }
            }

            if recallTimeLensTaskID == taskID {
                recallTimeLensTask = nil
                recallTimeLensTaskID = nil
            }
        }
    }

    private func recallTimeLensCanPublish(
        sessionID: UUID,
        sequence: UInt64,
        scope: RecallScope,
        expectedRecallOperationID: UUID?
    ) -> Bool {
        !Task.isCancelled
            && recallTimeLensSessionID == sessionID
            && recallTimeLensRequestSequence == sequence
            && recallTimeLensScope == scope
            && recallTimeLensRecallOperationID == expectedRecallOperationID
            && recallOperationID == expectedRecallOperationID
            && loadedRecallScope == scope
    }

    private func completeRecallTimeLensSession() {
        recallTimeLensTask = nil
        recallTimeLensTaskID = nil
        recallTimeLensPendingTarget = nil
        recallTimeLensSessionID = nil
        recallTimeLensScope = nil
        recallTimeLensBaselineSelection = nil
        recallTimeLensRecallOperationID = nil
        recallTimeLensLastSeekStartedAt = nil
        recallTimeLensIsScrubbing = false
        // Preserve the correlated terminal outcome until the next gesture,
        // scope/day change, Escape, or other invalidation. Clearing it in the
        // same actor turn as selection prevents SwiftUI and VoiceOver from ever
        // presenting the chosen-time versus saved-time result.
        refreshRecallTimeLensBoundsIfIdle()
    }

    private func invalidateRecallTimeLens(restoreBaseline: Bool) {
        let baseline = recallTimeLensBaselineSelection
        let hadActiveSession = recallTimeLensSessionID != nil
        recallTimeLensTask?.cancel()
        recallTimeLensTask = nil
        recallTimeLensTaskID = nil
        recallTimeLensPendingTarget = nil
        recallTimeLensSessionID = nil
        recallTimeLensScope = nil
        recallTimeLensBaselineSelection = nil
        recallTimeLensRecallOperationID = nil
        recallTimeLensLastSeekStartedAt = nil
        recallTimeLensRequestSequence &+= 1
        recallTimeLensIsScrubbing = false
        recallTimeLensPreview = nil

        if restoreBaseline,
           hadActiveSession,
           selectedHit?.id != baseline?.id {
            select(baseline)
        }
        refreshRecallTimeLensBoundsIfIdle()
    }

    private func refreshRecallTimeLensBoundsIfIdle() {
        guard recallTimeLensSessionID == nil else { return }
        guard let scope = loadedRecallScope else {
            recallTimeLensBounds = nil
            return
        }
        recallTimeLensBounds = RecallTimeLensBounds.make(
            statistics: statistics,
            scope: scope
        )
    }

    private func refreshActivityData() async {
        guard let repository else { return }
        statistics = (try? await repository.statistics()) ?? statistics
        refreshRecallTimeLensBoundsIfIdle()
        do {
            let sessions = try await repository.activitySessions(
                ActivitySessionQuery(limit: 60, includeSensitive: true)
            )
            guard !Task.isCancelled else { return }
            activitySessions = sessions
            activitySessionError = nil
            if let selectedActivitySession {
                if let refreshed = sessions.first(where: { $0.id == selectedActivitySession.id }) {
                    self.selectedActivitySession = refreshed
                    selectedActivitySessionDetail = try await repository.activitySession(
                        id: refreshed.id,
                        momentLimit: 100
                    )
                    if let detail = selectedActivitySessionDetail {
                        await loadCachedEnrichment(for: detail)
                    }
                } else {
                    self.selectedActivitySession = nil
                    selectedActivitySessionDetail = nil
                    selectedSessionEnrichment = nil
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            activitySessionError = error.localizedDescription
        }
    }

    private func currentRecallScope(text: String) -> RecallScope {
        RecallScope(
            text: text,
            startDate: recallScope.startDate,
            endDate: recallScope.endDate,
            applicationBundleIdentifiers: recallScope.applicationBundleIdentifiers,
            domains: recallScope.domains
        )
    }

    private func replaceRecallTime(startDate: Date?, endDate: Date?) {
        let base = materializeRecallInterpretationForFilterMutation()
        replaceRecallMetadata(
            startDate: startDate,
            endDate: endDate,
            applicationBundleIdentifiers: base.scope.applicationBundleIdentifiers,
            domains: base.scope.domains,
            allowsInterpretation: base.allowsInterpretation
        )
    }

    private func replaceRecallApplications(_ applications: Set<String>) {
        let base = materializeRecallInterpretationForFilterMutation()
        replaceRecallMetadata(
            startDate: base.scope.startDate,
            endDate: base.scope.endDate,
            applicationBundleIdentifiers: applications,
            domains: base.scope.domains,
            allowsInterpretation: base.allowsInterpretation
        )
    }

    private func replaceRecallDomains(_ domains: Set<String>) {
        let base = materializeRecallInterpretationForFilterMutation()
        replaceRecallMetadata(
            startDate: base.scope.startDate,
            endDate: base.scope.endDate,
            applicationBundleIdentifiers: base.scope.applicationBundleIdentifiers,
            domains: domains,
            allowsInterpretation: base.allowsInterpretation
        )
    }

    /// Makes an interpreted query structurally editable before a manual scope
    /// change. The interpretation's lexical text and effective metadata become
    /// ordinary model state; the caller then replaces exactly the metadata it
    /// owns (time, app, site, or all filters) and schedules one Recall request.
    private func materializeRecallInterpretationForFilterMutation() -> (
        scope: RecallScope,
        allowsInterpretation: Bool
    ) {
        guard memoryLensSelection == nil,
              let recallQueryInterpretation else {
            return (recallScope, !recallUsesOriginalWording)
        }
        let materialized = Self.applying(recallQueryInterpretation, to: recallScope)
        queryText = recallQueryInterpretation.searchText
        self.recallQueryInterpretation = nil
        return (materialized, false)
    }

    private func replaceRecallMetadata(
        startDate: Date?,
        endDate: Date?,
        applicationBundleIdentifiers: Set<String>,
        domains: Set<String>,
        allowsInterpretation: Bool
    ) {
        let scope = RecallScope(
            text: memoryLensSelection == nil ? queryText : "",
            startDate: startDate,
            endDate: endDate,
            applicationBundleIdentifiers: applicationBundleIdentifiers,
            domains: domains
        )
        if let descriptor = memoryLensSelection {
            _ = scheduleMemoryLens(descriptor: descriptor, scope: scope)
        } else {
            scheduleRecall(
                scope: scope,
                debounce: nil,
                allowsInterpretation: allowsInterpretation
            )
        }
    }

    private func enforceTimelineWorkspaceScope(_ day: Date) {
        let dayScope = TimelineWorkspaceScope.dayScope(for: day)
        guard queryText != "" || recallScope != dayScope else { return }
        queryText = ""
        scheduleRecall(
            scope: dayScope,
            debounce: nil,
            allowsInterpretation: false
        )
    }

    private static func applying(
        _ interpretation: RecallQueryInterpretation,
        to scope: RecallScope
    ) -> RecallScope {
        let interpretationEnd = interpretation.endDate.map {
            Date(timeIntervalSince1970: $0.timeIntervalSince1970.nextUp)
        }
        return RecallScope(
            text: interpretation.searchText,
            startDate: interpretation.startDate.map { start in
                scope.startDate.map { max($0, start) } ?? start
            } ?? scope.startDate,
            endDate: interpretationEnd.map { end in
                scope.endDate.map { min($0, end) } ?? end
            } ?? scope.endDate,
            applicationBundleIdentifiers: scope.applicationBundleIdentifiers,
            domains: scope.domains
        )
    }

    private func loadCachedEnrichment(for detail: ActivitySessionDetail) async {
        guard let intelligenceCache else { return }
        let input = Self.intelligenceInput(for: detail)
        guard !input.sources.isEmpty else {
            selectedSessionEnrichment = nil
            return
        }
        do {
            let cached = try await intelligenceCache.load(
                activitySessionID: detail.summary.id,
                contentFingerprint: input.contentFingerprint
            )
            guard selectedActivitySession?.id == detail.summary.id else { return }
            selectedSessionEnrichment = cached
        } catch {
            guard selectedActivitySession?.id == detail.summary.id else { return }
            selectedSessionEnrichment = nil
            intelligenceState = .error(error.localizedDescription)
        }
    }

    private static func intelligenceInput(
        for detail: ActivitySessionDetail
    ) -> SessionIntelligenceInput {
        let sources = detail.moments.map { hit in
            SessionIntelligenceSource(
                frameID: hit.id,
                capturedAt: hit.capturedAt,
                applicationName: hit.context.applicationName,
                windowTitle: hit.context.windowTitle,
                domain: hit.context.domain,
                urlString: hit.context.url?.absoluteString,
                ocrSnippet: hit.snippet
                    .replacingOccurrences(of: "‹", with: "")
                    .replacingOccurrences(of: "›", with: "")
            )
        }
        return SessionIntelligenceInput(
            activitySessionID: detail.summary.id,
            sources: sources
        )
    }

    func consumeRetentionMutationBoundary(_ boundary: RetentionMutationBoundary) {
        switch boundary {
        case .willMutate:
            guard !sessionIsLocked else { return }
            invalidateContextHandoffForHistoryChange()
            retentionMutationInProgress = true
            retentionCommitHandledByBoundary = false
            invalidateRecallForRetention()
            // Cancel decoded-image loaders at the same pre-deletion boundary.
            mediaRevision &+= 1
        case .finished(let commitEventFollows):
            guard retentionMutationInProgress else { return }
            retentionMutationInProgress = false
            retentionCommitHandledByBoundary = commitEventFollows
            guard !sessionIsLocked else { return }
            // Reconstruct on both commit and abort. A multi-step sweep may
            // have committed an early deletion before a later operation fails.
            scheduleCaptureRefresh(debounce: nil, requiresFullReload: true)
            scheduleVisualIndexing()
        }
    }

    /// Day grouping of the current results, memoized per results assignment.
    /// The `results` read is what registers SwiftUI observation; the cache
    /// only avoids re-sorting on body passes triggered by unrelated state.
    var recallDayGroups: [RecallDayGroup] {
        let hits = results
        if let cached = cachedDayGroups, cached.generation == resultsProjectionGeneration {
            return cached.groups
        }
        let groups = RecallResultPresentation.dayGroups(hits: hits)
        cachedDayGroups = (resultsProjectionGeneration, groups)
        return groups
    }

    /// A stable identity token for `results`: the same array instance is
    /// returned until results are reassigned, so `onChange` comparisons hit
    /// the copy-on-write fast path instead of allocating a fresh ID array
    /// on every body evaluation.
    var recallResultIDs: [FrameID] {
        let hits = results
        if let cached = cachedResultIDs, cached.generation == resultsProjectionGeneration {
            return cached.ids
        }
        let ids = hits.map(\.id)
        cachedResultIDs = (resultsProjectionGeneration, ids)
        return ids
    }

    /// The Timeline's day-scoped, ascending projection of `results`,
    /// memoized per (results assignment, day).
    func timelineHits(onDay day: Date, calendar: Calendar) -> [SearchHit] {
        let hits = results
        if let cached = cachedTimelineDayHits,
           cached.generation == resultsProjectionGeneration,
           cached.day == day {
            return cached.hits
        }
        let projected = TimelineProjection.hits(hits, onDay: day, calendar: calendar)
        cachedTimelineDayHits = (resultsProjectionGeneration, day, projected)
        return projected
    }

    func consume(_ event: CaptureEvent) {
        guard !sessionIsLocked else { return }
        let previousFirstMemoryState = firstMemoryActivationState
        // Most capture events (processing, unchanged, waiting) repeat the
        // current state several times per tick. Observation fires on every
        // setter call regardless of value, so only real transitions may
        // assign, or each tick invalidates every view reading these.
        let reducedFirstMemoryState = FirstMemoryActivationReducer.reduce(
            firstMemoryActivationState,
            event: event
        )
        if reducedFirstMemoryState != firstMemoryActivationState {
            firstMemoryActivationState = reducedFirstMemoryState
        }
        let nextCaptureState = Self.captureState(after: event, current: captureState)
        if nextCaptureState != captureState {
            captureState = nextCaptureState
        }
        if case .persisted(let frame, _) = event {
            if previousFirstMemoryState.readyFrameID == nil,
               !previousFirstMemoryState.isTerminal,
               case .recallReady(let candidate) = firstMemoryActivationState,
               candidate.frameID == frame.id {
                firstMemoryActivationStore.save(.awaitingRecall(frame.id))
                select(Self.searchHit(for: frame))
            }
            scheduleCaptureRefresh(debounce: .milliseconds(250))
            scheduleVisualIndexing()
        } else if case .retentionCommitted = event {
            if retentionCommitHandledByBoundary {
                retentionCommitHandledByBoundary = false
                return
            }
            // Fallback for coordinators/test seams without the awaited
            // pre-retention boundary installed.
            retentionMutationInProgress = false
            invalidateRecallForRetention()
            mediaRevision &+= 1
            scheduleCaptureRefresh(debounce: nil, requiresFullReload: true)
            // Retention advances the encrypted index generation. Re-entering
            // the indexing path reloads its final snapshot before the next query.
            scheduleVisualIndexing()
        }
    }

    /// Retention is a deletion boundary, not an ordinary head refresh. Remove
    /// every visible/deferred reference synchronously so a cancellation-
    /// insensitive read cannot republish an erased frame before the forced
    /// replacement recall completes.
    private func invalidateRecallForRetention() {
        cancelMemoryLens(clearReturnContext: true)
        searchTask?.cancel()
        searchTask = nil
        recallPageTask?.cancel()
        recallPageTask = nil
        cancelRecallFacets()
        visualSearchTask?.cancel()
        visualSearchTask = nil
        visualSearchOperationID = nil
        visualRerankTask?.cancel()
        visualRerankTask = nil
        visualRecallBaseline = nil
        invalidateRecallTimeLens(restoreBaseline: false)
        recallOperationID = nil
        recallCursor = nil
        loadedRecallScope = nil
        recallTimeLensBounds = nil
        recallHasMore = false
        recallIsLoading = false
        recallIsLoadingMore = false
        recallResultsAreStale = false
        recallQueryInterpretation = nil
        recallBaseFacets = RecallFacets()
        recallFacets = RecallFacets(applications: [], domains: [])
        recallFacetsAreLoading = false
        recallFacetsError = nil
        recallBrowserMomentAvailability = .unknown
        searchError = nil
        visualSearchIsRefining = false
        visualSearchError = nil
        visualRecallEvidenceByFrameID = [:]
        visualOnlyRecallFrameIDs = []
        results = []
        select(nil)
    }

    static func captureState(
        after event: CaptureEvent,
        current: CaptureState
    ) -> CaptureState {
        switch event {
        case .started:
            return .capturing
        case .paused:
            return .paused
        case .waitingForExternalApplication(let continuous):
            return continuous ? .capturing : current
        case .processingContext:
            // Starting a retry is not recovery. Keep any persistent error
            // visible until a capture actually succeeds or is safely skipped.
            return current
        case .skippedPrivateContext(let context, let continuous):
            return continuous ? .privateContext(context.applicationName) : current
        case .skippedUnchanged(let continuous):
            return continuous ? .capturing : current
        case .persisted(_, let continuous):
            return continuous ? .capturing : current
        case .retentionCommitted:
            return current
        case .failed(let message, let disposition):
            return disposition == .actionRequired ? .error(message) : current
        }
    }

    private func reconcileFirstMemoryActivationState() {
        // Before the vault reopens, the default zero statistics are unknown,
        // not evidence that this is a new library.
        guard !sessionIsLocked,
              statistics.frameCount == 0,
              firstMemoryActivationState.readyFrameID == nil,
              !firstMemoryActivationState.isTerminal else { return }
        firstMemoryActivationState = FirstMemoryActivationReducer.initial(
            frameCount: statistics.frameCount,
            intent: captureIntent,
            permissionGranted: screenPermissionGranted,
            progress: firstMemoryActivationStore.load()
        )
    }

    private static func searchHit(for frame: FrameDocument) -> SearchHit {
        let normalizedText = frame.ocrText
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let snippet = normalizedText.isEmpty
            ? (frame.context.windowTitle ?? frame.context.applicationName)
            : String(normalizedText.prefix(320))
        return SearchHit(
            id: frame.id,
            capturedAt: frame.capturedAt,
            context: frame.context,
            snippet: snippet,
            imageRelativePath: frame.imageRelativePath,
            thumbnailRelativePath: frame.thumbnailRelativePath,
            score: 0
        )
    }

    private func updatePrivacyPreferences(_ mutation: (inout PrivacyPreferences) -> Void) {
        var next = privacyPreferences
        mutation(&next)
        next.normalize()
        privacyPreferences = next
        guard let privacyStore, let coordinator else { return }
        privacyUpdateTask?.cancel()
        let operationID = UUID()
        privacyUpdateOperationID = operationID
        let accessPolicy = agentAccessPolicy
        privacyUpdateTask = Task {
            defer {
                if privacyUpdateOperationID == operationID {
                    privacyUpdateTask = nil
                    privacyUpdateOperationID = nil
                }
            }
            do {
                try await privacyStore.save(next)
                guard !Task.isCancelled,
                      !sessionIsLocked,
                      privacyUpdateOperationID == operationID else { return }
                await coordinator.update(policy: next.capturePolicy)
                await coordinator.update(retentionPolicy: next.retentionPolicy)
                await accessPolicy?.update(allowedIdentifiers: next.allowedAgentClients)
            } catch {
                guard !Task.isCancelled,
                      !sessionIsLocked,
                      privacyUpdateOperationID == operationID else { return }
                startupError = error.localizedDescription
            }
        }
    }
}

private struct TimelineWorkspaceTransaction {
    var everythingQueryText: String
    var everythingScope: RecallScope
    var day: Date
    var anchor: SearchHit?
}

private struct VisualRecallBaseline {
    let operationID: UUID
    let scope: RecallScope
    let lexicalHits: [SearchHit]
}

private struct MemoryLensReturnContext {
    let queryText: String
    let scope: RecallScope
    let selectedHit: SearchHit?
}
