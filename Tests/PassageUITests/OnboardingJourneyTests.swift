@testable import PassageUI
import Testing

@Suite("Onboarding journey")
struct OnboardingJourneyTests {
    @Test("Steps have a stable product order")
    func orderedSteps() {
        #expect(OnboardingStep.allCases == [
            .recall,
            .localByDesign,
            .contextAndAgents,
            .permissions,
        ])
    }

    @Test("Advancing is bounded at the final step")
    func advanceBounds() {
        var journey = OnboardingJourney()

        #expect(journey.step == .recall)
        #expect(journey.index == 0)
        #expect(journey.count == 4)
        #expect(!journey.canGoBack)
        #expect(!journey.isLast)

        let advancedToLocal = journey.advance()
        #expect(advancedToLocal)
        #expect(journey.step == .localByDesign)
        let advancedToContext = journey.advance()
        #expect(advancedToContext)
        #expect(journey.step == .contextAndAgents)
        let advancedToPermissions = journey.advance()
        #expect(advancedToPermissions)
        #expect(journey.step == .permissions)
        #expect(journey.isLast)
        let advancedPastEnd = journey.advance()
        #expect(!advancedPastEnd)
        #expect(journey.step == .permissions)
    }

    @Test("Going back is bounded at the first step")
    func backBounds() {
        var journey = OnboardingJourney(step: .permissions)

        #expect(journey.canGoBack)
        let returnedToContext = journey.goBack()
        #expect(returnedToContext)
        #expect(journey.step == .contextAndAgents)
        let returnedToLocal = journey.goBack()
        #expect(returnedToLocal)
        #expect(journey.step == .localByDesign)
        let returnedToRecall = journey.goBack()
        #expect(returnedToRecall)
        #expect(journey.step == .recall)
        #expect(!journey.canGoBack)
        let returnedPastStart = journey.goBack()
        #expect(!returnedPastStart)
        #expect(journey.step == .recall)
    }

    @Test("Only the explicit remembering choice starts capture")
    func completionChoice() {
        #expect(OnboardingCompletionChoice.startRemembering.startsCapturing)
        #expect(OnboardingCompletionChoice.startRemembering.beginsGuidedFirstMemoryHandoff)
        #expect(!OnboardingCompletionChoice.openPaused.startsCapturing)
        #expect(!OnboardingCompletionChoice.openPaused.beginsGuidedFirstMemoryHandoff)
    }

    @Test("Every step offers an honest paused exit")
    func pausedExit() {
        for step in OnboardingStep.allCases {
            let journey = OnboardingJourney(step: step)
            let expectedTitle = step == .recall
                ? "Skip and explore paused"
                : "Explore Passage paused"

            #expect(journey.pausedExitTitle == expectedTitle)
        }
    }

    @Test("Screen permission presentation covers every permission state")
    func screenPermissionState() {
        #expect(OnboardingScreenPermissionState(
            granted: false,
            requestAttempted: false
        ) == .request)
        #expect(OnboardingScreenPermissionState(
            granted: false,
            requestAttempted: true
        ) == .settings)
        #expect(OnboardingScreenPermissionState(
            granted: true,
            requestAttempted: false
        ) == .granted)
        #expect(OnboardingScreenPermissionState(
            granted: true,
            requestAttempted: true
        ) == .granted)
    }

    @Test("Two-column onboarding preserves enough room for its proof")
    func responsiveLayout() {
        let width940 = OnboardingLayoutPolicy.decision(
            containerWidth: 940,
            usesAccessibleLayout: false
        )
        let width1129 = OnboardingLayoutPolicy.decision(
            containerWidth: 1_129,
            usesAccessibleLayout: false
        )
        let width1130 = OnboardingLayoutPolicy.decision(
            containerWidth: 1_130,
            usesAccessibleLayout: false
        )
        let defaultWindow = OnboardingLayoutPolicy.decision(
            containerWidth: 1_180,
            usesAccessibleLayout: false
        )

        #expect(width940.usesStackedLayout)
        #expect(width1129.usesStackedLayout)
        #expect(!width1130.usesStackedLayout)
        #expect(!defaultWindow.usesStackedLayout)
        #expect(width1130.visualWidth >= OnboardingLayoutPolicy.minimumVisualWidth)
        #expect(defaultWindow.visualWidth >= OnboardingLayoutPolicy.minimumVisualWidth)
    }

    @Test("Accessibility text sizes always use the stacked onboarding layout")
    func accessibleLayout() {
        let decision = OnboardingLayoutPolicy.decision(
            containerWidth: 1_180,
            usesAccessibleLayout: true
        )

        #expect(decision.usesStackedLayout)
    }
}
