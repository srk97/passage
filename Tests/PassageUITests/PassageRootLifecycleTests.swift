@testable import PassageUI
import Foundation
import Testing

@Suite("Onboarding capture safety")
@MainActor
struct PassageRootLifecycleTests {
    @Test("Encrypted stores stay closed until onboarding completes")
    func onboardingGatesModelInitialization() {
        #expect(!PassageRootLifecycle.allowsModelInitialization(onboardingCompleted: false))
        #expect(PassageRootLifecycle.allowsModelInitialization(onboardingCompleted: true))
    }

    @Test("Test construction assumes protected data is available")
    func testModelStartsUnavailableRatherThanLockedByDefault() {
        let fixture = RootDefaultsFixture()
        defer { fixture.cleanUp() }
        let model = makeModel(
            store: CaptureIntentStore(defaults: fixture.defaults),
            screenPermissionGranted: true,
            firstMemoryStore: FirstMemoryActivationStore(defaults: fixture.defaults)
        )

        #expect(model.captureState == .unavailable)
    }

    @Test("A launch while protected data is unavailable leaves the vault unopened")
    func lockedLaunchDoesNotInitializeVault() async {
        let fixture = RootDefaultsFixture()
        defer { fixture.cleanUp() }
        var availabilityCheckCount = 0
        let model = PassageModel(
            captureIntentStore: CaptureIntentStore(defaults: fixture.defaults),
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {},
            firstMemoryActivationStore: FirstMemoryActivationStore(defaults: fixture.defaults),
            protectedDataAvailable: {
                availabilityCheckCount += 1
                return false
            }
        )

        #expect(availabilityCheckCount == 1)
        #expect(model.captureState == .locked)
        await model.start()
        model.refreshPermissions()
        #expect(model.captureState == .locked)
        #expect(model.firstMemoryActivationState == .preparing)
        #expect(model.rootURL == nil)
        #expect(model.startupError == nil)
    }

    @Test("Incomplete onboarding clears a persisted remembering intent before startup")
    func incompleteOnboardingForcesPausedIntent() {
        let fixture = RootDefaultsFixture()
        defer { fixture.cleanUp() }
        let store = CaptureIntentStore(defaults: fixture.defaults)
        store.save(.remembering)
        let model = makeModel(
            store: store,
            screenPermissionGranted: true,
            firstMemoryStore: FirstMemoryActivationStore(defaults: fixture.defaults)
        )

        PassageRootLifecycle.prepareForStartup(
            onboardingCompleted: false,
            model: model
        )

        #expect(model.captureIntent == .paused)
        #expect(store.load() == .paused)
    }

    @Test("Open Paused enters the normal workspace without a first-memory coach")
    func openPausedEntersNormalWorkspace() {
        let fixture = RootDefaultsFixture()
        defer { fixture.cleanUp() }
        let store = CaptureIntentStore(defaults: fixture.defaults)
        let firstMemoryStore = FirstMemoryActivationStore(defaults: fixture.defaults)
        store.save(.remembering)
        let model = makeModel(
            store: store,
            screenPermissionGranted: true,
            firstMemoryStore: firstMemoryStore
        )

        let completed = PassageRootLifecycle.completeOnboarding(
            .openPaused,
            model: model
        )

        #expect(completed)
        #expect(model.captureIntent == .paused)
        #expect(store.load() == .paused)
        #expect(firstMemoryStore.load() == .skipped)
        #expect(model.firstMemoryActivationState == .skipped)
        #expect(!model.firstMemoryActivationState.presentsJourney)
        #expect(
            MainWindowDetailRoute.resolve(
                section: .everything,
                historyIsSealed: false,
                presentsFirstMemoryJourney: model.firstMemoryActivationState.presentsJourney
            ) == .everything
        )
    }

    @Test("Paused exploration requests neither permission")
    func pausedExplorationRequestsNoAccess() {
        let fixture = RootDefaultsFixture()
        defer { fixture.cleanUp() }
        var screenRequestCount = 0
        var accessibilityRequestCount = 0
        let model = PassageModel(
            captureIntentStore: CaptureIntentStore(defaults: fixture.defaults),
            screenPermissionStatus: { false },
            screenPermissionRequest: {
                screenRequestCount += 1
                return false
            },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {
                accessibilityRequestCount += 1
            },
            firstMemoryActivationStore: FirstMemoryActivationStore(defaults: fixture.defaults)
        )

        let completed = PassageRootLifecycle.completeOnboarding(
            .openPaused,
            model: model
        )

        #expect(completed)
        #expect(model.captureIntent == .paused)
        #expect(model.firstMemoryActivationState == .skipped)
        #expect(screenRequestCount == 0)
        #expect(accessibilityRequestCount == 0)
    }

    @Test("Start Remembering completes only with Screen Recording permission")
    func startRememberingRequiresPermission() {
        let deniedFixture = RootDefaultsFixture()
        defer { deniedFixture.cleanUp() }
        let deniedStore = CaptureIntentStore(defaults: deniedFixture.defaults)
        let deniedModel = makeModel(
            store: deniedStore,
            screenPermissionGranted: false,
            firstMemoryStore: FirstMemoryActivationStore(defaults: deniedFixture.defaults)
        )

        let deniedCompletion = PassageRootLifecycle.completeOnboarding(
            .startRemembering,
            model: deniedModel
        )

        #expect(!deniedCompletion)
        #expect(deniedModel.captureIntent == .paused)
        #expect(deniedStore.load() == .paused)

        let grantedFixture = RootDefaultsFixture()
        defer { grantedFixture.cleanUp() }
        let grantedStore = CaptureIntentStore(defaults: grantedFixture.defaults)
        let grantedModel = makeModel(
            store: grantedStore,
            screenPermissionGranted: true,
            firstMemoryStore: FirstMemoryActivationStore(defaults: grantedFixture.defaults)
        )

        let grantedCompletion = PassageRootLifecycle.completeOnboarding(
            .startRemembering,
            model: grantedModel
        )

        #expect(grantedCompletion)
        #expect(grantedModel.captureIntent == .remembering)
        #expect(grantedStore.load() == .remembering)
    }

    private func makeModel(
        store: CaptureIntentStore,
        screenPermissionGranted: Bool,
        firstMemoryStore: FirstMemoryActivationStore
    ) -> PassageModel {
        PassageModel(
            captureIntentStore: store,
            screenPermissionStatus: { screenPermissionGranted },
            screenPermissionRequest: { screenPermissionGranted },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {},
            firstMemoryActivationStore: firstMemoryStore
        )
    }
}

private struct RootDefaultsFixture {
    let suiteName = "PassageRootLifecycleTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
