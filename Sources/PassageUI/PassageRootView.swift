import SwiftUI

public struct PassageRootView: View {
    @Bindable private var model: PassageModel
    @AppStorage("chronicle.onboarding.v2.completed") private var onboardingCompleted = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var guidedFirstMemoryHandoffArmed = false

    public init(model: PassageModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if onboardingCompleted {
                MainWindowView(
                    model: model,
                    guidedFirstMemoryHandoffArmed: $guidedFirstMemoryHandoffArmed
                )
            } else {
                OnboardingView(model: model) { choice in
                    guard PassageRootLifecycle.completeOnboarding(
                        choice,
                        model: model
                    ) else { return false }
                    guidedFirstMemoryHandoffArmed = choice.beginsGuidedFirstMemoryHandoff
                    onboardingCompleted = true
                    return true
                }
            }
        }
        .onAppear {
            PassageRootLifecycle.prepareForStartup(
                onboardingCompleted: onboardingCompleted,
                model: model
            )
        }
        .task(id: onboardingCompleted) {
            PassageRootLifecycle.prepareForStartup(
                onboardingCompleted: onboardingCompleted,
                model: model
            )
            guard PassageRootLifecycle.allowsModelInitialization(
                onboardingCompleted: onboardingCompleted
            ) else { return }
            await model.start()
            model.refreshPermissions()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Only .background counts as dormant: an inactive-but-visible
            // window still shows evidence and must keep refreshing honestly.
            // Window occlusion is reported separately by the window tag.
            model.setScenePhaseBackgrounded(newPhase == .background)
            guard newPhase == .active else { return }
            model.refreshPermissions()
        }
    }
}

@MainActor
enum PassageRootLifecycle {
    /// Setup remains a lightweight, permission-only surface. In particular,
    /// it does not open the vault or touch its Keychain root before the person
    /// explicitly completes onboarding.
    static func allowsModelInitialization(onboardingCompleted: Bool) -> Bool {
        onboardingCompleted
    }

    /// An unfinished setup is always a paused state, even when a previous app
    /// version persisted a remembering intent. Enforce this before opening the
    /// encrypted stores so initialization cannot consume the stale intent.
    static func prepareForStartup(
        onboardingCompleted: Bool,
        model: PassageModel
    ) {
        guard !onboardingCompleted else { return }
        model.pauseCapturing()
    }

    /// Applies the capture choice before exposing the completed app surfaces.
    /// The permission check is intentionally repeated here so capture cannot be
    /// started by an invalid or stale onboarding callback.
    @discardableResult
    static func completeOnboarding(
        _ choice: OnboardingCompletionChoice,
        model: PassageModel
    ) -> Bool {
        switch choice {
        case .startRemembering:
            guard model.screenPermissionGranted else {
                model.pauseCapturing()
                return false
            }
            model.startCapturing()
            return true
        case .openPaused:
            model.openPausedExploration()
            return true
        }
    }
}
