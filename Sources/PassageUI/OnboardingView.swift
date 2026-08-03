import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: PassageModel
    var completion: (OnboardingCompletionChoice) -> Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("chronicle.onboarding.step.v3") private var persistedStep = 0
    @State private var movingForward = true
    @State private var screenPermissionRequested = false
    @AccessibilityFocusState private var headingFocused: Bool

    private var journey: OnboardingJourney {
        OnboardingJourney(step: OnboardingStep(rawValue: persistedStep) ?? .recall)
    }

    private var page: OnboardingPage {
        OnboardingPage.page(
            for: journey.currentStep,
            highContrast: colorSchemeContrast == .increased
        )
    }

    private var usesAccessibleLayout: Bool {
        dynamicTypeSize.isAccessibilitySize || dynamicTypeSize >= .xxLarge
    }

    private var screenPermissionState: OnboardingScreenPermissionState {
        OnboardingScreenPermissionState(
            granted: model.screenPermissionGranted,
            requestAttempted: screenPermissionRequested
        )
    }

    var body: some View {
        ZStack {
            OnboardingBackground(step: journey.currentStep)

            VStack(spacing: 0) {
                header

                GeometryReader { proxy in
                    let layout = OnboardingLayoutPolicy.decision(
                        containerWidth: proxy.size.width,
                        usesAccessibleLayout: usesAccessibleLayout
                    )
                    ScrollView {
                        if layout.usesStackedLayout {
                            VStack(alignment: .leading, spacing: 30) {
                                pageCopy
                                    .frame(maxWidth: 720, alignment: .leading)

                                onboardingVisual
                                    .frame(maxWidth: 760, minHeight: 500)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 42)
                            .padding(.vertical, 22)
                        } else {
                            HStack(spacing: 42) {
                                pageCopy
                                    .frame(
                                        width: layout.copyWidth,
                                        alignment: .leading
                                    )

                                onboardingVisual
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .padding(.horizontal, layout.horizontalInset)
                            .padding(.vertical, 24)
                            .frame(minHeight: proxy.size.height)
                        }
                    }
                    .scrollIndicators(layout.usesStackedLayout ? .automatic : .never)
                }

                footer
            }
        }
        .frame(minWidth: 800, minHeight: 580)
        .preferredColorScheme(.light)
        .onAppear {
            normalizePersistedStep()
            model.refreshPermissions()
            headingFocused = true
        }
        .onChange(of: persistedStep) { _, _ in
            headingFocused = false
            Task { @MainActor in
                headingFocused = true
            }
        }
        .task(id: journey.currentStep) {
            guard journey.currentStep == .permissions else { return }
            while !Task.isCancelled {
                model.refreshPermissions()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private var onboardingVisual: some View {
        OnboardingVisual(
            step: journey.currentStep,
            model: model,
            reduceTransparency: reduceTransparency,
            highContrast: colorSchemeContrast == .increased
        )
    }

    private var header: some View {
        Group {
            if usesAccessibleLayout {
                VStack(alignment: .leading, spacing: 12) {
                    brand
                    progress
                }
            } else {
                HStack(spacing: 14) {
                    brand
                    Spacer()
                    progress
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 23)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            PassageBrandBadge()
                .frame(width: 29, height: 29)
            Text("Passage")
                .onboardingFont(size: 15, relativeTo: .body, weight: .semibold, design: .rounded)
                .foregroundStyle(PassagePalette.ink)
        }
    }

    private var progress: some View {
        HStack(spacing: 14) {
            Text("Step \(journey.index + 1) of \(journey.count)")
                .onboardingFont(size: 11, relativeTo: .caption, weight: .semibold)
                .onboardingSecondaryText()
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule(style: .continuous)
                        .fill(progressColor(for: step))
                        .frame(width: step == journey.currentStep ? 26 : 8, height: 7)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1),
                value: journey.currentStep
            )
            .accessibilityHidden(true)
        }
    }

    private var pageCopy: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(page.eyebrow.uppercased())
                    .onboardingFont(size: 11, relativeTo: .caption, weight: .bold)
                    .tracking(1.35)
                    .foregroundStyle(page.tint)
                    .padding(.bottom, 14)

                Text(page.title)
                    .onboardingFont(size: 43, relativeTo: .largeTitle, weight: .semibold, design: .rounded)
                    .tracking(-1.35)
                    .foregroundStyle(PassagePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("\(page.title), Step \(journey.index + 1) of \(journey.count)")
                    .accessibilityFocused($headingFocused)

                Text(page.body)
                    .onboardingFont(size: 17, relativeTo: .body)
                    .foregroundStyle(PassagePalette.ink.opacity(colorSchemeContrast == .increased ? 0.88 : 0.72))
                    .lineSpacing(5)
                    .padding(.top, 18)
                    .fixedSize(horizontal: false, vertical: true)

                ProofNote(icon: page.proofIcon, text: page.proof, tint: page.tint)
                    .padding(.top, 26)

                Spacer(minLength: 12)
            }
            .id(journey.currentStep)
            .transition(pageTransition)
        }
        .frame(maxHeight: usesAccessibleLayout ? nil : .infinity, alignment: .top)
        .padding(.top, usesAccessibleLayout ? 12 : 50)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        Group {
            if usesAccessibleLayout {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        secondaryActions
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        primaryAction
                    }
                }
            } else {
                HStack(spacing: 18) {
                    secondaryActions
                    Spacer()
                    primaryAction
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(reduceTransparency ? Color.white : Color.white.opacity(0.01))
    }

    @ViewBuilder private var secondaryActions: some View {
        Group {
            if journey.canGoBack {
                Button("Back", action: goBack)
                    .buttonStyle(PressableButtonStyle())
                    .foregroundStyle(PassagePalette.ink.opacity(colorSchemeContrast == .increased ? 0.92 : 0.72))
                    .keyboardShortcut("[", modifiers: .command)
            }

            Button(journey.pausedExitTitle) {
                finish(.openPaused)
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(PassagePalette.ink.opacity(colorSchemeContrast == .increased ? 0.88 : 0.64))
            .help("Open Passage without requesting access or starting screen capture")
        }
    }

    @ViewBuilder private var primaryAction: some View {
        Group {
            if journey.isLast {
                switch screenPermissionState {
                case .granted:
                    Button("Create my first memory") {
                        finish(.startRemembering)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("Start remembering and continue the guided first-memory journey")
                case .request:
                    Button {
                        requestScreenPermission()
                    } label: {
                        Label("Allow Screen Recording", systemImage: "rectangle.dashed.badge.record")
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("Ask macOS for the permission Passage needs to remember visible changes")
                case .settings:
                    Button {
                        openPrivacySettings(anchor: "Privacy_ScreenCapture")
                    } label: {
                        Label("Open Screen Recording Settings", systemImage: "gearshape.fill")
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("Open the macOS setting where Screen Recording can be enabled for Passage")
                }
            } else {
                Button(continueTitle, action: advance)
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var continueTitle: String {
        switch journey.currentStep {
        case .recall:
            "See how it stays local"
        case .localByDesign:
            "See resumable context"
        case .contextAndAgents:
            "Choose access"
        case .permissions:
            "Continue"
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let entering = AnyTransition.opacity.combined(with: .offset(x: movingForward ? 16 : -16))
        let leaving = AnyTransition.opacity.combined(with: .offset(x: movingForward ? -10 : 10))
        return .asymmetric(insertion: entering, removal: leaving)
    }

    private func progressColor(for step: OnboardingStep) -> Color {
        if step == journey.currentStep { return PassagePalette.ink }
        if step.rawValue < journey.index { return page.tint.opacity(0.55) }
        return PassagePalette.ink.opacity(colorSchemeContrast == .increased ? 0.25 : 0.13)
    }

    private func advance() {
        var next = journey
        guard next.advance() else { return }
        movingForward = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.22)) {
            persistedStep = next.index
        }
    }

    private func goBack() {
        var next = journey
        guard next.goBack() else { return }
        movingForward = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.20)) {
            persistedStep = next.index
        }
    }

    private func finish(_ choice: OnboardingCompletionChoice) {
        guard completion(choice) else {
            if choice == .startRemembering {
                screenPermissionRequested = true
                model.refreshPermissions()
            }
            return
        }
        persistedStep = OnboardingStep.recall.rawValue
    }

    private func requestScreenPermission() {
        screenPermissionRequested = true
        model.requestScreenPermission()
    }

    private func normalizePersistedStep() {
        guard OnboardingStep(rawValue: persistedStep) == nil else { return }
        persistedStep = OnboardingStep.recall.rawValue
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct OnboardingPage {
    let eyebrow: String
    let title: String
    let body: String
    let proof: String
    let proofIcon: String
    let tint: Color

    static func page(for step: OnboardingStep, highContrast: Bool) -> OnboardingPage {
        switch step {
        case .recall:
            OnboardingPage(
                eyebrow: "Recall with evidence",
                title: "Find a detail you saw earlier.",
                body: "Choose a detail in the example. Passage compares its appearance on this Mac, then returns the exact saved moment and source. This preview needs no access.",
                proof: "The selection is used only in memory; every match keeps its original source attached.",
                proofIcon: "arrow.up.forward.app",
                tint: OnboardingColors.accentText(highContrast: highContrast)
            )
        case .localByDesign:
            OnboardingPage(
                eyebrow: "Quiet by design",
                title: "A memory, not a screen recording.",
                body: "Passage saves useful visual changes and backs off when your screen is still. Visible text, search, sessions, and previews stay on this Mac by default.",
                proof: "Repeated images are skipped before text is read or anything is saved.",
                proofIcon: "bolt.shield.fill",
                tint: OnboardingColors.mintText(highContrast: highContrast)
            )
        case .permissions:
            OnboardingPage(
                eyebrow: "Your boundaries",
                title: "Choose what Passage can see.",
                body: "Screen Recording lets Passage take still snapshots of the focused window. App Context is optional; it adds visible labels and website names. Neither permission gives Passage network access.",
                proof: "Passage will tuck itself away once capture is ready, then signal when your first real moment can be recalled. It never records itself.",
                proofIcon: "hand.raised.fill",
                tint: OnboardingColors.violetText(highContrast: highContrast)
            )
        case .contextAndAgents:
            OnboardingPage(
                eyebrow: "Continue with context",
                title: "Pick up the thread—with receipts.",
                body: "Passage groups related moments into resumable sessions. When you choose to share context with an app or assistant, it bundles only the relevant text and links every claim back to its saved moment.",
                proof: "App access starts off. Every handoff appears in Access History.",
                proofIcon: "checkmark.shield.fill",
                tint: OnboardingColors.accentText(highContrast: highContrast)
            )
        }
    }
}

private struct ProofNote: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .onboardingFont(size: 13, relativeTo: .footnote, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .onboardingFont(size: 13, relativeTo: .footnote, weight: .medium)
                .onboardingSecondaryText()
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onboardingSurface(opacity: 0.58, cornerRadius: 13)
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingBackground: View {
    let step: OnboardingStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            PassagePalette.warmWhite

            if !reduceTransparency {
                Circle()
                    .fill(activeTint.opacity(0.18))
                    .frame(width: 660, height: 660)
                    .blur(radius: 80)
                    .offset(x: 400, y: -260)

                Circle()
                    .fill(secondaryTint.opacity(0.10))
                    .frame(width: 520, height: 520)
                    .blur(radius: 100)
                    .offset(x: 80, y: 390)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.30), value: step)
        .ignoresSafeArea()
    }

    private var activeTint: Color {
        switch step {
        case .recall: PassagePalette.accent
        case .localByDesign: PassagePalette.mint
        case .permissions: PassagePalette.violet
        case .contextAndAgents: PassagePalette.accent
        }
    }

    private var secondaryTint: Color {
        switch step {
        case .recall: PassagePalette.violet
        case .localByDesign: PassagePalette.accent
        case .permissions: PassagePalette.mint
        case .contextAndAgents: PassagePalette.mint
        }
    }
}

private struct PassageBrandBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(
                    colors: [PassagePalette.accent, PassagePalette.violet],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            PassageMarkView()
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
        }
        .accessibilityHidden(true)
    }
}

private struct OnboardingVisual: View {
    let step: OnboardingStep
    @Bindable var model: PassageModel
    let reduceTransparency: Bool
    let highContrast: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(stageFill)
                .shadow(color: .black.opacity(0.10), radius: 38, y: 22)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(
                    highContrast
                        ? PassagePalette.ink.opacity(0.42)
                        : Color.white.opacity(0.78),
                    lineWidth: highContrast ? 1.5 : 1
                )

            visual
                .padding(visualPadding)
        }
        .scaleEffect(reduceMotion || appeared ? 1 : 0.985)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1)) {
                appeared = true
            }
        }
    }

    private var stageFill: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color.white.opacity(0.96))
        }
        return AnyShapeStyle(.regularMaterial)
    }

    private var visualPadding: CGFloat {
        if step == .recall {
            return dynamicTypeSize >= .xxLarge ? 26 : 22
        }
        return 30
    }

    @ViewBuilder private var visual: some View {
        switch step {
        case .recall:
            OnboardingRecallDemoView()
        case .localByDesign:
            LocalMemoryDemo()
        case .permissions:
            PermissionDemo(model: model)
        case .contextAndAgents:
            ContextAndAgentsDemo()
        }
    }
}

private struct LocalMemoryDemo: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var mintText: Color {
        OnboardingColors.mintText(highContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AN EXAMPLE QUIET MINUTE")
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                        .tracking(1.1)
                        .onboardingSecondaryText()
                    Text("Useful change, without the footage")
                        .onboardingFont(size: 16, relativeTo: .headline, weight: .semibold, design: .rounded)
                }
                Spacer()
                Label("Local", systemImage: "checkmark.shield.fill")
                    .onboardingFont(size: 11, relativeTo: .caption, weight: .semibold)
                    .foregroundStyle(mintText)
            }

            HStack(spacing: 10) {
                MetricCard(value: "30", label: "change checks", tint: PassagePalette.ink)
                MetricCard(value: "4", label: "memories", tint: PassagePalette.accent)
                MetricCard(value: "26", label: "duplicates skipped", tint: mintText)
                MetricCard(value: "0", label: "uploads", tint: PassagePalette.violet)
            }

            HStack(spacing: 9) {
                PipelineCard(icon: "rectangle.dashed.badge.record", title: "Visual change", detail: "Focused window")
                PipelineArrow()
                PipelineCard(icon: "text.viewfinder", title: "Visible text", detail: "Read on this Mac")
                PipelineArrow()
                PipelineCard(icon: "lock.fill", title: "Encrypted memory", detail: "Searchable locally")
            }
            .padding(.vertical, 4)

            VStack(spacing: 0) {
                SafetyRow(icon: "eye.slash.fill", title: "Common password managers", detail: "Excluded by default", tint: PassagePalette.violet)
                Divider().padding(.leading, 48).opacity(0.38)
                SafetyRow(icon: "moon.zzz.fill", title: "Still screen", detail: "Capture work backs off", tint: PassagePalette.mint)
                Divider().padding(.leading, 48).opacity(0.38)
                SafetyRow(icon: "externaldrive.fill", title: "Old images", detail: "Expire while text stays useful", tint: PassagePalette.accent)
            }
            .onboardingSurface(opacity: 0.66, cornerRadius: 16)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MetricCard: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .onboardingFont(size: 21, relativeTo: .title3, weight: .semibold, design: .rounded)
                .foregroundStyle(tint)
            Text(label)
                .onboardingFont(size: 10, relativeTo: .caption, weight: .medium)
                .onboardingSecondaryText()
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(10)
        .onboardingSurface(opacity: 0.72, cornerRadius: 13)
        .accessibilityElement(children: .combine)
    }
}

private struct PipelineCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(PassagePalette.accent)
                .frame(width: 40, height: 40)
                .background(PassagePalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .onboardingFont(size: 11, relativeTo: .caption, weight: .semibold)
            Text(detail)
                .onboardingFont(size: 10, relativeTo: .caption)
                .onboardingSecondaryText()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .padding(.vertical, 8)
        .onboardingSurface(opacity: 0.58, cornerRadius: 15)
        .accessibilityElement(children: .combine)
    }
}

private struct PipelineArrow: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(PassagePalette.ink.opacity(0.25))
            .accessibilityHidden(true)
    }
}

private struct SafetyRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .onboardingFont(size: 12, relativeTo: .callout, weight: .semibold)
            Spacer()
            Text(detail)
                .onboardingFont(size: 11, relativeTo: .caption)
                .onboardingSecondaryText()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 43)
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionDemo: View {
    @Bindable var model: PassageModel
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var mintText: Color {
        OnboardingColors.mintText(highContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MACOS PERMISSIONS")
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                        .tracking(1.1)
                        .onboardingSecondaryText()
                    Text("Nothing is requested before you choose it")
                        .onboardingFont(size: 16, relativeTo: .headline, weight: .semibold, design: .rounded)
                }
                Spacer()
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(PassagePalette.violet)
            }

            PermissionChoiceCard(
                title: "Screen Recording",
                requirement: "Required to remember",
                detail: "macOS calls it Screen Recording, but Passage takes still snapshots of the focused window—not video, audio, or keystrokes. Use the main button below; if macOS asks for a relaunch, fully quit and reopen Passage.",
                symbol: "rectangle.dashed.badge.record",
                tint: PassagePalette.accent,
                granted: model.screenPermissionGranted,
                pendingLabel: "Required",
                actionTitle: nil,
                action: nil,
                settingsAnchor: nil
            )

            PermissionChoiceCard(
                title: "App Context",
                requirement: "Optional — leave it off if you prefer",
                detail: "Appears as Accessibility in System Settings. It saves only a bounded set of visible labels and controls with each remembered window, recognizes websites, and helps avoid password fields—not keystrokes or hidden app content.",
                symbol: "text.viewfinder",
                tint: PassagePalette.violet,
                granted: model.accessibilityPermissionGranted,
                pendingLabel: "Optional",
                actionTitle: "Allow",
                action: model.requestAccessibilityPermission,
                settingsAnchor: "Privacy_Accessibility"
            )

            HStack(spacing: 9) {
                Image(systemName: "network.slash")
                    .foregroundStyle(mintText)
                Text("Granting either permission does not upload anything")
                    .onboardingFont(size: 11, relativeTo: .caption, weight: .medium)
                    .onboardingSecondaryText()
                Spacer()
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 38)
            .background(PassagePalette.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct PermissionChoiceCard: View {
    let title: String
    let requirement: String
    let detail: String
    let symbol: String
    let tint: Color
    let granted: Bool
    let pendingLabel: String
    let actionTitle: String?
    let action: (() -> Void)?
    let settingsAnchor: String?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var mintText: Color {
        OnboardingColors.mintText(highContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(granted ? mintText : tint)
                    .frame(width: 42, height: 42)
                    .background((granted ? PassagePalette.mint : tint).opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .onboardingFont(size: 13, relativeTo: .body, weight: .semibold)
                    Text(requirement)
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
                        .onboardingSecondaryText()
                }

                Spacer(minLength: 8)
                permissionStatus
            }

            Text(detail)
                .onboardingFont(size: 11, relativeTo: .caption)
                .onboardingSecondaryText()
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if !granted,
               let actionTitle,
               let action {
                HStack(spacing: 12) {
                    Button(actionTitle, action: action)
                        .onboardingFont(size: 11, relativeTo: .caption, weight: .semibold)
                        .buttonStyle(.bordered)
                        .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .small)
                        .accessibilityLabel("Allow \(title)")

                    if let settingsAnchor {
                        Button("Settings") {
                            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") else {
                                return
                            }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.plain)
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .medium)
                        .onboardingSecondaryText()
                        .accessibilityLabel("Open \(title) settings")
                    }
                }
            }
        }
        .padding(15)
        .onboardingSurface(opacity: 0.72, cornerRadius: 16)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var permissionStatus: some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(mintText)
                .padding(.horizontal, 10)
                .frame(minHeight: 29)
                .background(PassagePalette.mint.opacity(0.10), in: Capsule())
                .accessibilityLabel("\(title) permission granted")
        } else {
            Text(pendingLabel)
                .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(minHeight: 29)
                .background(tint.opacity(0.09), in: Capsule())
                .accessibilityLabel("\(title) permission: \(pendingLabel)")
        }
    }
}

private struct ContextAndAgentsDemo: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var accentText: Color {
        OnboardingColors.accentText(highContrast: colorSchemeContrast == .increased)
    }

    private var violetText: Color {
        OnboardingColors.violetText(highContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NORTHSTAR CHECKOUT")
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                        .tracking(1.1)
                        .onboardingSecondaryText()
                    Text("One resumable work session")
                        .onboardingFont(size: 16, relativeTo: .headline, weight: .semibold, design: .rounded)
                }
                Spacer()
                Text("42 min · 18 moments")
                    .onboardingFont(size: 10, relativeTo: .caption, weight: .medium)
                    .monospacedDigit()
                    .onboardingSecondaryText()
            }

            HStack(spacing: 8) {
                SessionAppPill(symbol: "safari.fill", title: "Safari", tint: .blue)
                SessionConnector()
                SessionAppPill(symbol: "rectangle.3.group.fill", title: "Figma", tint: violetText)
                SessionConnector()
                SessionAppPill(symbol: "checklist", title: "Linear", tint: accentText)
                Spacer()
                Label("Resume", systemImage: "arrow.up.forward.app")
                    .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
                    .foregroundStyle(accentText)
            }
            .padding(12)
            .onboardingSurface(opacity: 0.68, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Source-cited handoff", systemImage: "sparkles")
                        .onboardingFont(size: 12, relativeTo: .callout, weight: .semibold)
                        .foregroundStyle(violetText)
                    Spacer()
                    Text("TEXT ONLY")
                        .onboardingFont(size: 10, relativeTo: .caption, weight: .bold)
                        .tracking(0.9)
                        .onboardingSecondaryText()
                }

                Text("You compared two checkout patterns, chose the inline variant, and left the mobile error state for the next pass.")
                    .onboardingFont(size: 13, relativeTo: .body)
                    .foregroundStyle(PassagePalette.ink.opacity(0.78))
                    .lineSpacing(3)

                HStack(spacing: 7) {
                    CitationChip(time: "11:18", app: "Safari")
                    CitationChip(time: "11:36", app: "Figma")
                    CitationChip(time: "11:52", app: "Linear")
                }
            }
            .padding(16)
            .onboardingSurface(opacity: 0.76, cornerRadius: 16)
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                BoundaryBadge(symbol: "person.badge.minus", text: "Agents off by default")
                BoundaryBadge(symbol: "sparkles", text: "Intelligence optional")
                BoundaryBadge(symbol: "photo.badge.checkmark", text: "Images stay local")
            }
        }
    }
}

private struct SessionAppPill: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 29)
            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
    }
}

private struct SessionConnector: View {
    var body: some View {
        Capsule()
            .fill(PassagePalette.ink.opacity(0.16))
            .frame(width: 12, height: 1)
            .accessibilityHidden(true)
    }
}

private struct CitationChip: View {
    let time: String
    let app: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(PassagePalette.accent).frame(width: 5, height: 5)
            Text("\(time) · \(app)")
                .onboardingFont(size: 10, relativeTo: .caption, weight: .medium)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(minHeight: 25)
        .background(PassagePalette.accent.opacity(0.08), in: Capsule(style: .continuous))
    }
}

private struct BoundaryBadge: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .onboardingFont(size: 10, relativeTo: .caption, weight: .semibold)
            .onboardingSecondaryText()
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 31)
            .background(PassagePalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .multilineTextAlignment(.center)
    }
}

enum OnboardingColors {
    static func accentText(highContrast: Bool) -> Color {
        highContrast
            ? Color(red: 0.12, green: 0.18, blue: 0.62)
            : Color(red: 0.20, green: 0.27, blue: 0.78)
    }

    static func violetText(highContrast: Bool) -> Color {
        highContrast
            ? Color(red: 0.28, green: 0.10, blue: 0.56)
            : Color(red: 0.40, green: 0.18, blue: 0.70)
    }

    static func mintText(highContrast: Bool) -> Color {
        highContrast
            ? Color(red: 0.01, green: 0.30, blue: 0.23)
            : Color(red: 0.04, green: 0.43, blue: 0.34)
    }
}

struct OnboardingScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, relativeTo textStyle: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

struct OnboardingSecondaryTextModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content.foregroundStyle(
            PassagePalette.ink.opacity(colorSchemeContrast == .increased ? 0.88 : 0.68)
        )
    }
}

struct OnboardingSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let opacity: Double
    let cornerRadius: CGFloat

    private var effectiveOpacity: Double {
        if reduceTransparency { return 1 }
        if colorSchemeContrast == .increased { return max(opacity, 0.94) }
        return opacity
    }

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(effectiveOpacity),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if colorSchemeContrast == .increased {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(PassagePalette.ink.opacity(0.30), lineWidth: 1)
                }
            }
    }
}

extension View {
    func onboardingFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(OnboardingScaledFontModifier(
            size: size,
            relativeTo: textStyle,
            weight: weight,
            design: design
        ))
    }

    func onboardingSecondaryText() -> some View {
        modifier(OnboardingSecondaryTextModifier())
    }

    func onboardingSurface(opacity: Double, cornerRadius: CGFloat) -> some View {
        modifier(OnboardingSurfaceModifier(opacity: opacity, cornerRadius: cornerRadius))
    }
}
