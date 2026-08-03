import CoreGraphics
import SwiftUI

enum OnboardingMemoryLensFixture {
    static let coverageThreshold = 0.60
    static let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Top-left unit coordinates matching the synthetic lecture scene below.
    static let glassesHotspot = CGRect(
        x: 0.205,
        y: 0.35,
        width: 0.16,
        height: 0.19
    )
    static let glassesPreset = CGRect(
        x: 0.18,
        y: 0.325,
        width: 0.21,
        height: 0.24
    )

    static func normalized(_ rawBounds: CGRect) -> CGRect? {
        let values = [
            rawBounds.origin.x,
            rawBounds.origin.y,
            rawBounds.size.width,
            rawBounds.size.height,
        ]
        guard values.allSatisfy(\.isFinite) else { return nil }

        let bounds = rawBounds.standardized
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if bounds.minX >= unitBounds.minX,
           bounds.minY >= unitBounds.minY,
           bounds.maxX <= unitBounds.maxX,
           bounds.maxY <= unitBounds.maxY {
            return bounds
        }
        let minX = max(unitBounds.minX, bounds.minX)
        let minY = max(unitBounds.minY, bounds.minY)
        let maxX = min(unitBounds.maxX, bounds.maxX)
        let maxY = min(unitBounds.maxY, bounds.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    static func glassesCoverage(for rawSelection: CGRect) -> Double {
        guard let selection = normalized(rawSelection) else { return 0 }
        let intersection = selection.intersection(glassesHotspot)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else {
            return 0
        }
        return (intersection.width * intersection.height)
            / (glassesHotspot.width * glassesHotspot.height)
    }

    static func coversGlasses(_ selection: CGRect) -> Bool {
        glassesCoverage(for: selection) >= coverageThreshold
    }
}

enum OnboardingRecallSelectionGeometry {
    static func liveFrame(
        from start: CGPoint,
        to end: CGPoint,
        in canvas: CGRect
    ) -> CGRect? {
        MemoryLensSelectionGeometry.dragFrame(
            from: start,
            to: end,
            in: canvas
        )
    }

    static func normalizedSelection(
        from start: CGPoint,
        to end: CGPoint,
        in canvas: CGRect,
        minimumTargetSize: CGSize = MemoryLensSelectionGeometry.defaultMinimumTargetSize
    ) -> CGRect? {
        guard canvas.width.isFinite,
              canvas.height.isFinite,
              canvas.width > 0,
              canvas.height > 0,
              let selection = MemoryLensSelectionGeometry.selectionFrame(
                  from: start,
                  to: end,
                  in: canvas,
                  minimumTargetSize: minimumTargetSize
              ) else {
            return nil
        }
        return OnboardingMemoryLensFixture.normalized(CGRect(
            x: (selection.minX - canvas.minX) / canvas.width,
            y: (selection.minY - canvas.minY) / canvas.height,
            width: selection.width / canvas.width,
            height: selection.height / canvas.height
        ))
    }

    static func overlayFrame(
        for normalizedSelection: CGRect,
        in canvas: CGRect
    ) -> CGRect? {
        guard let selection = OnboardingMemoryLensFixture.normalized(normalizedSelection),
              canvas.width.isFinite,
              canvas.height.isFinite,
              canvas.width > 0,
              canvas.height > 0 else {
            return nil
        }
        return CGRect(
            x: canvas.minX + selection.minX * canvas.width,
            y: canvas.minY + selection.minY * canvas.height,
            width: selection.width * canvas.width,
            height: selection.height * canvas.height
        )
    }
}

struct OnboardingRecallDemoState: Equatable {
    enum Readiness: Equatable {
        case none
        case miss
        case ready
    }

    enum Phase: Equatable {
        case selecting(CGRect?)
        case foundMatch(CGRect)
        case sourceProof(CGRect)
    }

    enum Action: Equatable {
        case setSelection(CGRect?)
        case confirmSelection
        case showSourceProof
        case back
        case reset
    }

    private(set) var phase: Phase

    init(phase: Phase = .selecting(nil)) {
        self.phase = phase
    }

    var selection: CGRect? {
        switch phase {
        case let .selecting(bounds): bounds
        case let .foundMatch(bounds), let .sourceProof(bounds): bounds
        }
    }

    var readiness: Readiness {
        guard case let .selecting(bounds) = phase,
              let bounds else {
            return .none
        }
        return OnboardingMemoryLensFixture.coversGlasses(bounds) ? .ready : .miss
    }

    var isSelecting: Bool {
        if case .selecting = phase { return true }
        return false
    }

    @discardableResult
    mutating func send(_ action: Action) -> Bool {
        let previous = phase
        switch (phase, action) {
        case (.selecting, let .setSelection(rawBounds)):
            if let rawBounds {
                if let bounds = OnboardingMemoryLensFixture.normalized(rawBounds) {
                    phase = .selecting(bounds)
                }
            } else {
                phase = .selecting(nil)
            }
        case let (.selecting(.some(bounds)), .confirmSelection)
            where OnboardingMemoryLensFixture.coversGlasses(bounds):
            phase = .foundMatch(bounds)
        case let (.foundMatch(bounds), .showSourceProof):
            phase = .sourceProof(bounds)
        case let (.sourceProof(bounds), .back):
            phase = .foundMatch(bounds)
        case let (.foundMatch(bounds), .back):
            phase = .selecting(bounds)
        case (_, .reset):
            phase = .selecting(nil)
        default:
            break
        }
        return phase != previous
    }
}

enum OnboardingRecallDemoPresentation {
    static let selectionLabel = "Memory Lens example image"
    static let selectionHint =
        "Drag over the round glasses, or use the Select round glasses button."
    static let selectedExampleValue = "Round glasses selected"
    static let selectedExampleHint = "The selected example detail remains highlighted."
    static let presetLabel = "Select round glasses"
    static let presetHint = "Selects the example detail without dragging."
    static let confirmLabel = "Find similar moment"
    static let confirmHint = "Uses this preview only; no access is requested."
    static let foundHeading = MemoryLensPresentation.heading(resultCount: 1)
    static let foundResultLabel =
        "Found 1 similar moment. Round glasses in the lecture. Safari, Friday, 3:42 PM. Looks like selected area."
    static let foundResultHint = "Shows this result’s source proof."
    static let sourceProofLabel =
        "Source proof. Round glasses in the lecture. Safari, Friday, 3:42 PM. Exact video moment."
    static let evidenceExplanation = RecallMatchReason.selectedAreaAppearance.explanation
    static let resetLabel = "Start Memory Lens preview over"
    static let resetHint = "Returns to detail selection and clears the selected area."

    static func selectionValue(for readiness: OnboardingRecallDemoState.Readiness) -> String {
        switch readiness {
        case .none: "No detail selected"
        case .miss: "Selected area misses the round glasses"
        case .ready: "Round glasses selected"
        }
    }
}

struct OnboardingRecallDemoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var state: OnboardingRecallDemoState
    @AccessibilityFocusState private var confirmFocused: Bool
    @AccessibilityFocusState private var foundFocused: Bool
    @AccessibilityFocusState private var sourceProofFocused: Bool

    init(initialState: OnboardingRecallDemoState = OnboardingRecallDemoState()) {
        _state = State(initialValue: initialState)
    }

    var body: some View {
        VStack(spacing: 12) {
            demoHeader

            OnboardingRecallSelectionCanvas(
                selection: state.selection,
                readiness: state.readiness,
                acceptsSelection: state.isSelecting,
                onBeginSelection: clearSelection,
                onSelection: select,
                onPresetSelection: selectGlasses
            )
            .aspectRatio(16 / 9, contentMode: .fit)

            interaction
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 128, alignment: .top)
        }
    }

    private var demoHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                demoTitle
                Spacer(minLength: 12)
                previewBoundary
            }
            VStack(alignment: .leading, spacing: 7) {
                demoTitle
                previewBoundary
            }
        }
    }

    private var demoTitle: some View {
        Label("Memory Lens", systemImage: "viewfinder")
            .onboardingFont(size: 15, relativeTo: .headline, weight: .semibold, design: .rounded)
            .foregroundStyle(PassagePalette.ink)
    }

    private var previewBoundary: some View {
        Label("Built-in example · no access", systemImage: "checkmark.shield.fill")
            .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
            .foregroundStyle(OnboardingColors.mintText(highContrast: highContrast))
    }

    @ViewBuilder private var interaction: some View {
        switch state.phase {
        case .selecting:
            selectionControls
                .transition(.opacity)
        case .foundMatch:
            foundMatch
                .transition(feedbackTransition)
        case .sourceProof:
            sourceProof
                .transition(feedbackTransition)
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(selectionStatusText, systemImage: selectionStatusIcon)
                .onboardingFont(size: 11, relativeTo: .caption, weight: .medium)
                .foregroundStyle(selectionStatusColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    selectionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    selectionButtons
                }
            }
        }
        .padding(12)
        .onboardingSurface(opacity: 0.76, cornerRadius: 14)
    }

    @ViewBuilder private var selectionButtons: some View {
        Button(action: selectGlasses) {
            Label("Select glasses", systemImage: "eyeglasses")
                .onboardingFont(size: 11, relativeTo: .caption, weight: .semibold)
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel(OnboardingRecallDemoPresentation.presetLabel)
        .accessibilityHint(OnboardingRecallDemoPresentation.presetHint)

        Button(action: confirmSelection) {
            Label("Find this again", systemImage: "sparkle.magnifyingglass")
                .onboardingFont(size: 11, relativeTo: .caption, weight: .semibold)
                .frame(minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(PassagePalette.accent)
        .disabled(state.readiness != .ready)
        .accessibilityLabel(OnboardingRecallDemoPresentation.confirmLabel)
        .accessibilityHint(OnboardingRecallDemoPresentation.confirmHint)
        .accessibilityFocused($confirmFocused)
    }

    private var foundMatch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OnboardingRecallDemoPresentation.foundHeading)
                .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                .tracking(0.8)
                .foregroundStyle(OnboardingColors.mintText(highContrast: highContrast))

            Button(action: showSourceProof) {
                HStack(spacing: 11) {
                    Image(systemName: RecallMatchReason.selectedAreaAppearance.systemImage)
                        .foregroundStyle(PassagePalette.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            PassagePalette.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Round glasses in the lecture")
                            .onboardingFont(size: 13, relativeTo: .body, weight: .semibold)
                            .foregroundStyle(PassagePalette.ink)
                        Text("Safari · Friday, 3:42 PM")
                            .onboardingFont(size: 10, relativeTo: .caption)
                            .onboardingSecondaryText()
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                        .onboardingSecondaryText()
                }
                .padding(11)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingSurface(opacity: 0.88, cornerRadius: 13)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(PassagePalette.accent.opacity(0.12), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(OnboardingRecallDemoPresentation.foundResultLabel)
            .accessibilityHint(OnboardingRecallDemoPresentation.foundResultHint)
            .accessibilityFocused($foundFocused)

            Button("Back to detail selection", action: backToSelection)
                .buttonStyle(PressableButtonStyle())
                .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
                .onboardingSecondaryText()
                .accessibilityHint("Keeps the selected area so you can adjust it.")
        }
    }

    private var sourceProof: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Exact source attached", systemImage: "arrow.up.forward.app")
                    .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                    .tracking(0.6)
                    .foregroundStyle(OnboardingColors.accentText(highContrast: highContrast))
                Spacer(minLength: 8)
                Text("EXAMPLE")
                    .onboardingFont(size: 9, relativeTo: .caption2, weight: .bold)
                    .tracking(0.9)
                    .onboardingSecondaryText()
            }
            .fixedSize(horizontal: false, vertical: true)

            Text("Round glasses in the lecture")
                .onboardingFont(size: 13, relativeTo: .body, weight: .semibold)
                .foregroundStyle(PassagePalette.ink)
                .accessibilityLabel(OnboardingRecallDemoPresentation.sourceProofLabel)
                .accessibilityFocused($sourceProofFocused)

            Text("Safari · Friday, 3:42 PM · Exact video moment")
                .onboardingFont(size: 10, relativeTo: .caption, weight: .medium)
                .onboardingSecondaryText()

            Text(OnboardingRecallDemoPresentation.evidenceExplanation)
                .onboardingFont(size: 10, relativeTo: .caption)
                .onboardingSecondaryText()
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button("Back to found match", action: backToMatch)
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityHint("Returns to the similar result.")
                Button("Start over", action: reset)
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(OnboardingRecallDemoPresentation.resetLabel)
                    .accessibilityHint(OnboardingRecallDemoPresentation.resetHint)
            }
            .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
            .onboardingSecondaryText()
        }
        .padding(12)
        .onboardingSurface(opacity: 0.82, cornerRadius: 14)
    }

    private var feedbackTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: 6))
    }

    private var feedbackAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.28, dampingFraction: 1)
    }

    private var selectionStatusText: String {
        switch state.readiness {
        case .none: "Drag over the round glasses, or use the preset."
        case .miss: "That area misses the round glasses. Adjust it or use the preset."
        case .ready: "Round glasses selected. Find its similar saved moment."
        }
    }

    private var selectionStatusIcon: String {
        switch state.readiness {
        case .none: "viewfinder"
        case .miss: "arrow.uturn.backward.circle"
        case .ready: "checkmark.circle.fill"
        }
    }

    private var selectionStatusColor: Color {
        switch state.readiness {
        case .none: PassagePalette.ink.opacity(0.68)
        case .miss: OnboardingColors.violetText(highContrast: highContrast)
        case .ready: OnboardingColors.mintText(highContrast: highContrast)
        }
    }

    private var highContrast: Bool {
        colorSchemeContrast == .increased
    }

    private func clearSelection() {
        _ = state.send(.setSelection(nil))
    }

    private func select(_ bounds: CGRect) {
        _ = state.send(.setSelection(bounds))
    }

    private func selectGlasses() {
        _ = state.send(.setSelection(OnboardingMemoryLensFixture.glassesPreset))
        confirmFocused = false
        Task { @MainActor in confirmFocused = true }
    }

    private func confirmSelection() {
        withAnimation(feedbackAnimation) {
            _ = state.send(.confirmSelection)
        }
        foundFocused = false
        Task { @MainActor in foundFocused = true }
    }

    private func showSourceProof() {
        withAnimation(feedbackAnimation) {
            _ = state.send(.showSourceProof)
        }
        sourceProofFocused = false
        Task { @MainActor in sourceProofFocused = true }
    }

    private func backToSelection() {
        withAnimation(feedbackAnimation) {
            _ = state.send(.back)
        }
    }

    private func backToMatch() {
        withAnimation(feedbackAnimation) {
            _ = state.send(.back)
        }
        foundFocused = false
        Task { @MainActor in foundFocused = true }
    }

    private func reset() {
        withAnimation(feedbackAnimation) {
            _ = state.send(.reset)
        }
    }
}

private struct OnboardingRecallSelectionCanvas: View {
    let selection: CGRect?
    let readiness: OnboardingRecallDemoState.Readiness
    let acceptsSelection: Bool
    let onBeginSelection: () -> Void
    let onSelection: (CGRect) -> Void
    let onPresetSelection: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var dragAnchor: CGPoint?
    @State private var dragLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let canvas = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                OnboardingLectureScene()

                selectionOverlay(in: canvas)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(selectionGesture(in: canvas))
                    .allowsHitTesting(acceptsSelection)

                HStack {
                    Label("Synthetic lecture", systemImage: "play.rectangle.fill")
                    Spacer(minLength: 8)
                    Text("00:18:42")
                        .monospacedDigit()
                }
                .onboardingFont(size: 9, relativeTo: .caption2, weight: .bold)
                .foregroundStyle(.white.opacity(0.92))
                .padding(11)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                Label("Drag over the glasses", systemImage: "viewfinder")
                    .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(.black.opacity(0.60), in: Capsule())
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorSchemeContrast == .increased ? 0.72 : 0.20),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                    )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OnboardingRecallDemoPresentation.selectionLabel)
            .accessibilityValue(
                acceptsSelection
                    ? OnboardingRecallDemoPresentation.selectionValue(for: readiness)
                    : OnboardingRecallDemoPresentation.selectedExampleValue
            )
            .accessibilityHint(
                acceptsSelection
                    ? OnboardingRecallDemoPresentation.selectionHint
                    : OnboardingRecallDemoPresentation.selectedExampleHint
            )
            .accessibilityActions {
                if acceptsSelection {
                    Button(OnboardingRecallDemoPresentation.presetLabel) {
                        onPresetSelection()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionOverlay(in canvas: CGRect) -> some View {
        if let frame = displayedSelectionFrame(in: canvas),
           frame.width > 0,
           frame.height > 0 {
            OnboardingOutsideSelectionShape(
                canvasFrame: canvas,
                selectionFrame: frame
            )
            .fill(.black.opacity(0.34), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(dragAnchor == nil ? 0.04 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white, lineWidth: dragAnchor == nil ? 1.5 : 2)
                }
                .shadow(color: .black.opacity(0.32), radius: 8, y: 2)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }

        if let dragLocation {
            let point = MemoryLensSelectionGeometry.clampedPoint(dragLocation, to: canvas)
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .overlay { Circle().stroke(.black.opacity(0.5), lineWidth: 1) }
                .position(point)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func displayedSelectionFrame(in canvas: CGRect) -> CGRect? {
        if let dragAnchor, let dragLocation {
            return OnboardingRecallSelectionGeometry.liveFrame(
                from: dragAnchor,
                to: dragLocation,
                in: canvas
            )
        }
        return selection.flatMap {
            OnboardingRecallSelectionGeometry.overlayFrame(for: $0, in: canvas)
        }
    }

    private func selectionGesture(in canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if dragAnchor == nil {
                        onBeginSelection()
                    }
                    dragAnchor = MemoryLensSelectionGeometry.clampedPoint(
                        value.startLocation,
                        to: canvas
                    )
                    dragLocation = MemoryLensSelectionGeometry.clampedPoint(
                        value.location,
                        to: canvas
                    )
                }
            }
            .onEnded { value in
                let start = dragAnchor ?? value.startLocation
                let end = MemoryLensSelectionGeometry.clampedPoint(
                    value.location,
                    to: canvas
                )
                let committed = OnboardingRecallSelectionGeometry.normalizedSelection(
                    from: start,
                    to: end,
                    in: canvas
                )
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragAnchor = nil
                    dragLocation = nil
                    if let committed { onSelection(committed) }
                }
            }
    }
}

private struct OnboardingLectureScene: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.12, blue: 0.22),
                        Color(red: 0.20, green: 0.17, blue: 0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.88))
                    .frame(width: width * 0.48, height: height * 0.49)
                    .position(x: width * 0.69, y: height * 0.43)

                VStack(alignment: .leading, spacing: max(3, height * 0.018)) {
                    Text("SYSTEMS, SHAPES, SIGNALS")
                        .font(.system(size: max(6, width * 0.018), weight: .bold))
                        .foregroundStyle(PassagePalette.ink.opacity(0.82))
                    Capsule()
                        .fill(PassagePalette.accent.opacity(0.70))
                        .frame(width: width * 0.25, height: 4)
                    Capsule()
                        .fill(PassagePalette.violet.opacity(0.34))
                        .frame(width: width * 0.19, height: 4)
                    HStack(spacing: width * 0.018) {
                        Circle().fill(PassagePalette.mint.opacity(0.72))
                        RoundedRectangle(cornerRadius: 4).fill(PassagePalette.accent.opacity(0.62))
                        Capsule().fill(PassagePalette.violet.opacity(0.54))
                    }
                    .frame(height: height * 0.10)
                }
                .frame(width: width * 0.39, alignment: .leading)
                .position(x: width * 0.69, y: height * 0.43)

                Capsule(style: .continuous)
                    .fill(Color(red: 0.30, green: 0.34, blue: 0.66))
                    .frame(width: width * 0.21, height: height * 0.38)
                    .position(x: width * 0.285, y: height * 0.81)

                Ellipse()
                    .fill(Color(red: 0.11, green: 0.10, blue: 0.13))
                    .frame(width: width * 0.145, height: height * 0.22)
                    .position(x: width * 0.285, y: height * 0.34)

                Ellipse()
                    .fill(Color(red: 0.77, green: 0.56, blue: 0.42))
                    .frame(width: width * 0.125, height: height * 0.24)
                    .position(x: width * 0.285, y: height * 0.43)

                HStack(spacing: width * 0.006) {
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: max(1.5, width * 0.0045))
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: width * 0.018, height: max(1.5, height * 0.009))
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: max(1.5, width * 0.0045))
                }
                .frame(width: width * 0.13, height: height * 0.105)
                .position(x: width * 0.285, y: height * 0.425)

                Capsule()
                    .fill(Color(red: 0.54, green: 0.34, blue: 0.27))
                    .frame(width: width * 0.027, height: height * 0.008)
                    .position(x: width * 0.285, y: height * 0.49)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.15, green: 0.16, blue: 0.22))
                    .frame(width: width * 0.31, height: height * 0.19)
                    .rotationEffect(.degrees(-2))
                    .position(x: width * 0.52, y: height * 0.84)

                Rectangle()
                    .fill(Color.black.opacity(0.38))
                    .frame(width: width, height: max(2, height * 0.045))
                    .position(x: width / 2, y: height * 0.985)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct OnboardingOutsideSelectionShape: Shape {
    let canvasFrame: CGRect
    let selectionFrame: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRect(canvasFrame)
        path.addRoundedRect(
            in: selectionFrame,
            cornerSize: CGSize(width: 8, height: 8)
        )
        return path
    }
}
