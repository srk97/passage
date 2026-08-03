@testable import PassageUI
import CoreGraphics
import Testing

@Suite("Onboarding Memory Lens proof")
struct OnboardingRecallDemoTests {
    @Test("Confirmed glasses selection walks the exact fixture path")
    func confirmedSelectionPath() {
        var state = OnboardingRecallDemoState()
        let preset = OnboardingMemoryLensFixture.glassesPreset

        #expect(state.phase == .selecting(nil))
        #expect(state.readiness == .none)
        let selected = state.send(.setSelection(preset))
        #expect(selected)
        #expect(state.phase == .selecting(preset))
        #expect(state.readiness == .ready)
        let confirmed = state.send(.confirmSelection)
        #expect(confirmed)
        #expect(state.phase == .foundMatch(preset))
        let showedProof = state.send(.showSourceProof)
        #expect(showedProof)
        #expect(state.phase == .sourceProof(preset))
    }

    @Test("A selection below sixty percent coverage cannot advance")
    func missedSelectionCannotAdvance() {
        let hotspot = OnboardingMemoryLensFixture.glassesHotspot
        let miss = CGRect(
            x: hotspot.minX,
            y: hotspot.minY,
            width: hotspot.width * 0.599,
            height: hotspot.height
        )
        var state = OnboardingRecallDemoState()

        let selected = state.send(.setSelection(miss))
        #expect(selected)
        #expect(state.readiness == .miss)
        let confirmed = state.send(.confirmSelection)
        #expect(!confirmed)
        #expect(state.phase == .selecting(miss))
    }

    @Test("Back unwinds source proof and preserves the exact selection")
    func backPreservesSelection() {
        let preset = OnboardingMemoryLensFixture.glassesPreset
        var state = OnboardingRecallDemoState(phase: .sourceProof(preset))

        let returnedToMatch = state.send(.back)
        #expect(returnedToMatch)
        #expect(state.phase == .foundMatch(preset))
        let returnedToSelection = state.send(.back)
        #expect(returnedToSelection)
        #expect(state.phase == .selecting(preset))
        let returnedPastSelection = state.send(.back)
        #expect(!returnedPastSelection)
        #expect(state.phase == .selecting(preset))
    }

    @Test("Reset always clears the fixture selection")
    func resetAlwaysClears() {
        let preset = OnboardingMemoryLensFixture.glassesPreset
        let phases: [OnboardingRecallDemoState.Phase] = [
            .selecting(preset),
            .foundMatch(preset),
            .sourceProof(preset),
        ]

        for phase in phases {
            var state = OnboardingRecallDemoState(phase: phase)
            let reset = state.send(.reset)
            #expect(reset)
            #expect(state.phase == .selecting(nil))
        }

        var initial = OnboardingRecallDemoState()
        let resetInitial = initial.send(.reset)
        #expect(!resetInitial)
        #expect(initial.phase == .selecting(nil))
    }

    @Test("Invalid phase transitions fail closed")
    func invalidTransitions() {
        var initial = OnboardingRecallDemoState()
        let confirmedInitial = initial.send(.confirmSelection)
        let showedInitialProof = initial.send(.showSourceProof)
        let returnedFromInitial = initial.send(.back)
        #expect(!confirmedInitial)
        #expect(!showedInitialProof)
        #expect(!returnedFromInitial)
        #expect(initial.phase == .selecting(nil))

        let preset = OnboardingMemoryLensFixture.glassesPreset
        var found = OnboardingRecallDemoState(phase: .foundMatch(preset))
        let changedFoundSelection = found.send(.setSelection(.zero))
        let reconfirmedFound = found.send(.confirmSelection)
        #expect(!changedFoundSelection)
        #expect(!reconfirmedFound)
        #expect(found.phase == .foundMatch(preset))

        var proof = OnboardingRecallDemoState(phase: .sourceProof(preset))
        let showedProofAgain = proof.send(.showSourceProof)
        #expect(!showedProofAgain)
        #expect(proof.phase == .sourceProof(preset))
    }

    @Test("Fixture matching uses sixty percent hotspot coverage")
    func hotspotCoverage() {
        let hotspot = OnboardingMemoryLensFixture.glassesHotspot
        let exactThreshold = CGRect(
            x: hotspot.minX,
            y: hotspot.minY,
            width: hotspot.width * 0.60,
            height: hotspot.height
        )
        let belowThreshold = CGRect(
            x: hotspot.minX,
            y: hotspot.minY,
            width: hotspot.width * 0.599,
            height: hotspot.height
        )

        #expect(OnboardingMemoryLensFixture.coverageThreshold == 0.60)
        #expect(OnboardingMemoryLensFixture.coversGlasses(hotspot))
        #expect(OnboardingMemoryLensFixture.coversGlasses(.init(x: 0, y: 0, width: 1, height: 1)))
        #expect(OnboardingMemoryLensFixture.coversGlasses(exactThreshold))
        #expect(!OnboardingMemoryLensFixture.coversGlasses(belowThreshold))
        #expect(!OnboardingMemoryLensFixture.coversGlasses(.zero))
        #expect(!OnboardingMemoryLensFixture.coversGlasses(CGRect(
            x: CGFloat.nan,
            y: 0,
            width: 1,
            height: 1
        )))
    }

    @Test("Drag geometry is reversible, clamped, and resize invariant")
    func selectionGeometry() throws {
        let canvas = CGRect(x: 10, y: 20, width: 440, height: 247.5)
        let forward = try #require(OnboardingRecallSelectionGeometry.normalizedSelection(
            from: CGPoint(x: 100, y: 90),
            to: CGPoint(x: 230, y: 170),
            in: canvas,
            minimumTargetSize: CGSize(width: 1, height: 1)
        ))
        let reverse = try #require(OnboardingRecallSelectionGeometry.normalizedSelection(
            from: CGPoint(x: 230, y: 170),
            to: CGPoint(x: 100, y: 90),
            in: canvas,
            minimumTargetSize: CGSize(width: 1, height: 1)
        ))
        #expect(forward == reverse)

        let clamped = try #require(OnboardingRecallSelectionGeometry.normalizedSelection(
            from: CGPoint(x: -1_000, y: -1_000),
            to: CGPoint(x: 4_000, y: 4_000),
            in: canvas
        ))
        expectRect(clamped, equals: CGRect(x: 0, y: 0, width: 1, height: 1))

        let firstOverlay = try #require(OnboardingRecallSelectionGeometry.overlayFrame(
            for: forward,
            in: canvas
        ))
        let resizedCanvas = CGRect(x: 30, y: 40, width: 880, height: 495)
        let resizedOverlay = try #require(OnboardingRecallSelectionGeometry.overlayFrame(
            for: forward,
            in: resizedCanvas
        ))
        expect((firstOverlay.minX - canvas.minX) / canvas.width, equals: forward.minX)
        expect((resizedOverlay.minX - resizedCanvas.minX) / resizedCanvas.width, equals: forward.minX)
        expect(firstOverlay.width / canvas.width, equals: forward.width)
        expect(resizedOverlay.width / resizedCanvas.width, equals: forward.width)
    }

    @Test("Accessibility presentation is complete and truthful")
    func accessibilityPresentation() {
        #expect(OnboardingRecallDemoPresentation.selectionLabel == "Memory Lens example image")
        #expect(OnboardingRecallDemoPresentation.selectionHint.contains("Select round glasses"))
        #expect(OnboardingRecallDemoPresentation.selectedExampleValue == "Round glasses selected")
        #expect(OnboardingRecallDemoPresentation.selectedExampleHint.contains("remains highlighted"))
        #expect(OnboardingRecallDemoPresentation.presetLabel == "Select round glasses")
        #expect(OnboardingRecallDemoPresentation.presetHint.contains("without dragging"))
        #expect(OnboardingRecallDemoPresentation.confirmLabel == "Find similar moment")
        #expect(OnboardingRecallDemoPresentation.confirmHint.contains("no access"))
        #expect(
            OnboardingRecallDemoPresentation.foundHeading
                == MemoryLensPresentation.heading(resultCount: 1)
        )
        #expect(OnboardingRecallDemoPresentation.foundResultLabel.contains("Looks like selected area"))
        #expect(OnboardingRecallDemoPresentation.foundResultHint.contains("source proof"))
        #expect(OnboardingRecallDemoPresentation.sourceProofLabel.contains("Exact video moment"))
        #expect(OnboardingRecallDemoPresentation.evidenceExplanation.contains("on this Mac"))
        #expect(
            OnboardingRecallDemoPresentation.evidenceExplanation
                .contains("did not identify an object or person")
        )
        #expect(OnboardingRecallDemoPresentation.resetLabel.contains("Start"))
        #expect(OnboardingRecallDemoPresentation.resetHint.contains("clears"))
        #expect(OnboardingRecallDemoPresentation.selectionValue(for: .none) == "No detail selected")
        #expect(OnboardingRecallDemoPresentation.selectionValue(for: .miss).contains("misses"))
        #expect(OnboardingRecallDemoPresentation.selectionValue(for: .ready) == "Round glasses selected")

        let allCopy = [
            OnboardingRecallDemoPresentation.selectionLabel,
            OnboardingRecallDemoPresentation.selectionHint,
            OnboardingRecallDemoPresentation.selectedExampleValue,
            OnboardingRecallDemoPresentation.selectedExampleHint,
            OnboardingRecallDemoPresentation.presetLabel,
            OnboardingRecallDemoPresentation.confirmLabel,
            OnboardingRecallDemoPresentation.foundResultLabel,
            OnboardingRecallDemoPresentation.sourceProofLabel,
            OnboardingRecallDemoPresentation.evidenceExplanation,
        ].joined(separator: " ").lowercased()
        #expect(!allCopy.contains("recognized"))
    }

    private func expectRect(
        _ actual: CGRect,
        equals expected: CGRect,
        tolerance: CGFloat = 0.000_001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual.minX - expected.minX) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.minY - expected.minY) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.width - expected.width) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.height - expected.height) <= tolerance, sourceLocation: sourceLocation)
    }

    private func expect(
        _ actual: CGFloat,
        equals expected: CGFloat,
        tolerance: CGFloat = 0.000_001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= tolerance, sourceLocation: sourceLocation)
    }
}
