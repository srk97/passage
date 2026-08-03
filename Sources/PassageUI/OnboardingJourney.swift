import Foundation

enum OnboardingStep: Int, CaseIterable {
    case recall
    case localByDesign
    case contextAndAgents
    case permissions
}

enum OnboardingScreenPermissionState: Equatable {
    case request
    case settings
    case granted

    init(granted: Bool, requestAttempted: Bool) {
        if granted {
            self = .granted
        } else if requestAttempted {
            self = .settings
        } else {
            self = .request
        }
    }
}

struct OnboardingLayoutDecision: Equatable {
    let usesStackedLayout: Bool
    let horizontalInset: CGFloat
    let copyWidth: CGFloat
    let visualWidth: CGFloat
}

enum OnboardingLayoutPolicy {
    static let columnSpacing: CGFloat = 42
    static let minimumVisualWidth: CGFloat = 500

    static func decision(
        containerWidth: CGFloat,
        usesAccessibleLayout: Bool
    ) -> OnboardingLayoutDecision {
        let horizontalInset = max(42, containerWidth * 0.065)
        let copyWidth = min(max(containerWidth * 0.39, 350), 470)
        let visualWidth = max(
            containerWidth - (horizontalInset * 2) - columnSpacing - copyWidth,
            0
        )

        return OnboardingLayoutDecision(
            usesStackedLayout: usesAccessibleLayout || visualWidth < minimumVisualWidth,
            horizontalInset: horizontalInset,
            copyWidth: copyWidth,
            visualWidth: visualWidth
        )
    }
}

struct OnboardingJourney: Equatable {
    private(set) var step: OnboardingStep

    init(step: OnboardingStep = .recall) {
        self.step = step
    }

    var currentStep: OnboardingStep { step }
    var index: Int { step.rawValue }
    var count: Int { OnboardingStep.allCases.count }
    var canGoBack: Bool { index > 0 }
    var isLast: Bool { index == count - 1 }
    var pausedExitTitle: String {
        step == .recall ? "Skip and explore paused" : "Explore Passage paused"
    }

    @discardableResult
    mutating func advance() -> Bool {
        guard !isLast,
              let next = OnboardingStep(rawValue: index + 1) else {
            return false
        }
        step = next
        return true
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard canGoBack,
              let previous = OnboardingStep(rawValue: index - 1) else {
            return false
        }
        step = previous
        return true
    }
}

enum OnboardingCompletionChoice: Equatable {
    case startRemembering
    case openPaused

    var startsCapturing: Bool {
        self == .startRemembering
    }

    var beginsGuidedFirstMemoryHandoff: Bool {
        self == .startRemembering
    }
}
