import AppKit
import PassageCore
import PassageVisualSearch
import SwiftUI

enum MainWindowSection: Hashable, CaseIterable {
    case everything
    case timeline
    case sessions
    case agentActivity
}

enum MainWindowDetailRoute: Hashable {
    case historySealed
    case firstMemoryJourney
    case everything
    case timeline
    case sessions
    case agentActivity

    static func resolve(
        section: MainWindowSection,
        historyIsSealed: Bool,
        presentsFirstMemoryJourney: Bool
    ) -> MainWindowDetailRoute {
        guard !historyIsSealed else { return .historySealed }

        switch section {
        case .everything:
            return presentsFirstMemoryJourney
                ? .firstMemoryJourney
                : .everything
        case .timeline:
            return .timeline
        case .sessions:
            return .sessions
        case .agentActivity:
            return .agentActivity
        }
    }
}

struct HistorySealedPresentation: Equatable {
    static let current = HistorySealedPresentation(
        eyebrow: "PROTECTED ON THIS MAC",
        title: "History is sealed",
        message: "macOS has not made Passage’s protected files available, so Passage is keeping them sealed. If you’re already signed in, restart your Mac; Passage will try again after login.",
        status: "Waiting for protected data",
        assurance: "Your memories and Remembering choice are unchanged."
    )

    let eyebrow: String
    let title: String
    let message: String
    let status: String
    let assurance: String
}

struct WebsiteFacetEmptyPresentation: Equatable {
    enum RecoveryAction: Equatable {
        case retry
        case enableAppContext
        case clearFilters

        var title: String {
            switch self {
            case .retry: "Retry"
            case .enableAppContext: "Enable App Context…"
            case .clearFilters: "Clear filters"
            }
        }

        var systemImage: String {
            switch self {
            case .retry: "arrow.clockwise"
            case .enableAppContext: "switch.2"
            case .clearFilters: "line.3.horizontal.decrease.circle"
            }
        }
    }

    let title: String
    let message: String
    let systemImage: String
    let recoveryAction: RecoveryAction?

    static func make(
        availability: PassageModel.RecallBrowserMomentAvailability,
        appContextGranted: Bool,
        bestMatchesUseSavedTextScope: Bool,
        hasFilters: Bool,
        hasFacetError: Bool
    ) -> Self {
        if hasFacetError || availability == .error {
            return Self(
                title: "Websites unavailable",
                message: "Passage couldn’t update website choices.",
                systemImage: "exclamationmark.triangle",
                recoveryAction: .retry
            )
        }

        switch availability {
        case .unknown:
            return Self(
                title: "Website choices aren’t ready",
                message: "Passage has not checked this scope yet.",
                systemImage: "globe",
                recoveryAction: .retry
            )
        case .loading:
            return Self(
                title: "Finding websites…",
                message: "Checking saved browser moments in this scope.",
                systemImage: "globe",
                recoveryAction: nil
            )
        case .error:
            // Handled above so the compiler can keep this switch exhaustive.
            return Self(
                title: "Websites unavailable",
                message: "Passage couldn’t update website choices.",
                systemImage: "exclamationmark.triangle",
                recoveryAction: .retry
            )
        case .available(let browserMomentCount) where browserMomentCount <= 0:
            return Self(
                title: "No websites in this scope",
                message: bestMatchesUseSavedTextScope
                    ? "No matching saved-text browser moments are available; appearance-only matches may not be counted."
                    : "No browser moments match the current scope.",
                systemImage: "globe",
                recoveryAction: hasFilters ? .clearFilters : nil
            )
        case .available:
            guard appContextGranted else {
                return Self(
                    title: "Website names aren’t available",
                    message: "App Context can add website names to future saved moments.",
                    systemImage: "globe.badge.chevron.backward",
                    recoveryAction: .enableAppContext
                )
            }
            return Self(
                title: "No website names in this scope",
                message: bestMatchesUseSavedTextScope
                    ? "Matching browser moments have no saved website name; appearance-only matches may not be counted."
                    : "The browser moments in this scope have no saved website name.",
                systemImage: "globe.badge.chevron.backward",
                recoveryAction: hasFilters ? .clearFilters : nil
            )
        }
    }
}

struct WebsiteFilterChipPresentation: Equatable {
    let title: String
    let systemImage: String
    let isLoading: Bool
    let accessibilityLabel: String

    static func make(
        selectedDomains: Set<String>,
        availableDomainCount: Int,
        availability: PassageModel.RecallBrowserMomentAvailability,
        appContextGranted: Bool,
        facetsAreLoading: Bool,
        hasFacetError: Bool
    ) -> Self {
        if selectedDomains.count == 1, let domain = selectedDomains.first {
            return Self(
                title: domain,
                systemImage: "globe",
                isLoading: false,
                accessibilityLabel: "Website filter, \(domain) selected"
            )
        }
        if selectedDomains.count > 1 {
            return Self(
                title: "\(selectedDomains.count) websites",
                systemImage: "globe",
                isLoading: false,
                accessibilityLabel: "Website filter, \(selectedDomains.count) selected"
            )
        }
        if hasFacetError || availability == .error {
            return Self(
                title: "Websites unavailable",
                systemImage: "exclamationmark.triangle",
                isLoading: false,
                accessibilityLabel: "Filter by website, choices unavailable"
            )
        }
        if (facetsAreLoading || availability == .loading), availableDomainCount == 0 {
            return Self(
                title: "Counting websites…",
                systemImage: "globe",
                isLoading: true,
                accessibilityLabel: "Filter by website, counting available websites"
            )
        }
        if availableDomainCount > 0 {
            let noun = availableDomainCount == 1 ? "website" : "websites"
            return Self(
                title: "Websites · \(availableDomainCount)",
                systemImage: "globe",
                isLoading: false,
                accessibilityLabel: "Filter by website, \(availableDomainCount) \(noun) available"
            )
        }

        switch availability {
        case .available(let browserMomentCount) where browserMomentCount <= 0:
            return Self(
                title: "No websites in scope",
                systemImage: "globe",
                isLoading: false,
                accessibilityLabel: "Filter by website, no websites in this scope"
            )
        case .available where !appContextGranted:
            return Self(
                title: "App Context off",
                systemImage: "globe.badge.chevron.backward",
                isLoading: false,
                accessibilityLabel: "Filter by website, App Context is off"
            )
        case .available:
            return Self(
                title: "No website names",
                systemImage: "globe.badge.chevron.backward",
                isLoading: false,
                accessibilityLabel: "Filter by website, browser moments have no website names"
            )
        case .unknown:
            return Self(
                title: "Websites",
                systemImage: "globe",
                isLoading: false,
                accessibilityLabel: "Filter by website"
            )
        case .loading:
            return Self(
                title: "Counting websites…",
                systemImage: "globe",
                isLoading: true,
                accessibilityLabel: "Filter by website, counting available websites"
            )
        case .error:
            return Self(
                title: "Websites unavailable",
                systemImage: "exclamationmark.triangle",
                isLoading: false,
                accessibilityLabel: "Filter by website, choices unavailable"
            )
        }
    }
}

struct InspectorSourcePresentation: Equatable {
    let displayText: String
    let fullText: String

    static func make(url: URL?) -> Self? {
        guard let url else { return nil }
        let fullText = url.absoluteString
        let displayText: String
        switch url.scheme?.lowercased() {
        case "http", "https":
            if let host = url.host, !host.isEmpty {
                let path = url.path == "/" ? "" : url.path
                displayText = host + path
            } else {
                displayText = fullText
            }
        case "file":
            displayText = url.path.isEmpty ? fullText : url.path
        default:
            displayText = fullText
        }
        return Self(displayText: displayText, fullText: fullText)
    }
}

enum InspectorEvidencePresentation {
    static func appProvidedTextSummary(count: Int, isTruncated: Bool) -> String {
        guard count > 0 else { return "No visible labels" }
        if isTruncated { return "\(count)+ visible labels" }
        return count == 1 ? "1 visible label" : "\(count) visible labels"
    }

    static func ocrSummary(text: String, isImproving: Bool) -> String {
        if isImproving { return "Rereading saved image…" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No readable text"
            : "Searchable text available"
    }
}

enum RecallQueryKind: Equatable {
    case none
    case text
    case memoryLens

    static func resolve(queryText: String, hasMemoryLens: Bool) -> Self {
        if hasMemoryLens { return .memoryLens }
        return queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .none
            : .text
    }
}

struct RecallEmptyPresentation: Equatable {
    let title: String
    let systemImage: String
    let message: String

    static func make(
        queryKind: RecallQueryKind,
        hasFilters: Bool,
        searchMode: PassageModel.RecallSearchMode,
        visualState: PassageModel.VisualUnderstandingState,
        coverage: VisualEmbeddingCoverage?,
        totalMomentCount: Int,
        searchError: String?
    ) -> Self {
        if let searchError {
            return Self(
                title: "Recall couldn’t finish",
                systemImage: "exclamationmark.triangle",
                message: searchError
            )
        }

        switch queryKind {
        case .memoryLens:
            return Self(
                title: MemoryLensPresentation.emptyTitle,
                systemImage: "viewfinder",
                message: MemoryLensPresentation.emptyMessage(hasFilters: hasFilters)
            )
        case .text:
            let title = hasFilters ? "No matches in this scope" : "No matches"
            if hasFilters {
                return Self(
                    title: title,
                    systemImage: "magnifyingglass",
                    message: "Try fewer words, or change or clear a recall filter."
                )
            }
            if searchMode == .savedTextOnly {
                return Self(
                    title: title,
                    systemImage: "magnifyingglass",
                    message: "Try fewer saved words, a different phrase, or choose a time, app, or website."
                )
            }
            if visualState == .verifying || visualState == .preparing {
                return Self(
                    title: title,
                    systemImage: "magnifyingglass",
                    message: "Saved-text search is ready. Image appearance is still getting ready on this Mac."
                )
            }
            if let coverage, coverage.pendingEligibleFrameCount > 0 {
                return Self(
                    title: title,
                    systemImage: "magnifyingglass",
                    message: "No match yet. Image search can use \(coverage.indexedEligibleFrameCount.formatted()) of \(coverage.eligibleFrameCount.formatted()) saved images so far."
                )
            }
            return Self(
                title: title,
                systemImage: "magnifyingglass",
                message: "Try fewer words, a different visual description, or choose a time, app, or website."
            )
        case .none:
            if hasFilters {
                return Self(
                    title: "No memories in this scope",
                    systemImage: "line.3.horizontal.decrease.circle",
                    message: "No retained moments match these filters. Change or clear the scope."
                )
            }
            if totalMomentCount == 0 {
                return Self(
                    title: "No memories yet",
                    systemImage: "sparkles",
                    message: "Start Remembering, then use your Mac normally. Useful visual changes will appear here."
                )
            }
            return Self(
                title: "No memories available",
                systemImage: "clock.arrow.circlepath",
                message: "Passage has saved history, but no moments are available in this view. Try reopening Recall."
            )
        }
    }
}

struct MemoryLensPresentation {
    static let scopeLabel = "Looks like this"
    static let scopeRemovalLabel = "Remove selected-area appearance search"
    static let scopeRemovalHelp =
        "Remove the selected area while keeping the current time, app, and website filters"
    static let rankingFooter =
        "Ordered by appearance similarity to the selected area on this Mac"
    static let loadingMessage = "Comparing saved images on this Mac…"
    static let loadingHeading = "Comparing selected area…"
    static let loadingAccessibilityLabel = "Comparing selected area on this Mac"
    static let emptyTitle = "No similar moments found"

    static func heading(resultCount: Int) -> String {
        "Looks like selected area · \(resultCount.formatted()) shown"
    }

    static func emptyMessage(hasFilters: Bool) -> String {
        if hasFilters {
            return "No saved image in this scope looks enough like the selected area. Change a time, app, or website filter, or choose another area."
        }
        return "No saved image looks enough like the selected area. Try selecting a larger or more distinctive area."
    }

    static func hidesStaleResults(
        queryKind: RecallQueryKind,
        resultsAreStale: Bool
    ) -> Bool {
        queryKind == .memoryLens && resultsAreStale
    }
}

struct MainWindowView: View {
    @Bindable var model: PassageModel
    @Binding var guidedFirstMemoryHandoffArmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var section: MainWindowSection = .everything
    @State private var guidedHandoffHasHiddenApplication = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detailSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    focusSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(model.historyIsSealed || model.firstMemoryActivationState.presentsJourney)
                .keyboardShortcut("f", modifiers: .command)
                .help("Search memories")
                Button {
                    model.captureNow()
                } label: {
                    Label("Capture now", systemImage: "camera.viewfinder")
                }
                .disabled(!model.captureControlsEnabled)
                .help(model.screenPermissionGranted
                    ? "Capture this moment"
                    : "Allow Screen Recording in Settings before capturing")
                Button {
                    model.toggleCapture()
                } label: {
                    Label(
                        captureToggleTitle,
                        systemImage: isRemembering ? "pause.fill" : "record.circle"
                    )
                }
                .disabled(!model.captureControlsEnabled)
                .help(captureToggleHelp)
            }
        }
        .background(.background)
        .frame(minWidth: 960, minHeight: 620)
        .onChange(of: model.firstMemoryActivationState) { oldValue, newValue in
            handleFirstMemoryHandoff(from: oldValue, to: newValue)
            if newValue.presentsJourney {
                searchFocused = false
            } else if oldValue.presentsJourney {
                DispatchQueue.main.async {
                    searchFocused = true
                }
            }
        }
        .onChange(of: guidedFirstMemoryHandoffArmed) { _, armed in
            if armed {
                hideForGuidedHandoffIfReady(state: model.firstMemoryActivationState)
            } else {
                guidedHandoffHasHiddenApplication = false
            }
        }
        .onChange(of: model.historyIsSealed) { _, isSealed in
            guard isSealed else { return }
            section = .everything
            searchFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: PassageActivationCenter.requestNotification
        )) { _ in
            consumeActivationIntent()
        }
        .onAppear {
            hideForGuidedHandoffIfReady(state: model.firstMemoryActivationState)
            if let intent = PassageActivationCenter.shared.takePendingIntent() {
                handleActivation(intent)
            } else if !model.firstMemoryActivationState.presentsJourney,
                      model.statistics.frameCount > 0
                        || model.firstMemoryActivationState.isTerminal {
                searchFocused = true
            } else {
                DispatchQueue.main.async {
                    searchFocused = false
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.contextHandoffState.isPresented },
                set: { isPresented in
                    if !isPresented { model.dismissContextHandoff() }
                }
            )
        ) {
            ContextHandoffSheet(model: model)
        }
    }

    private var isRemembering: Bool {
        model.captureIntent == .remembering
    }

    private var captureToggleTitle: String {
        guard model.screenPermissionGranted else { return "Permission needed" }
        return isRemembering ? "Pause" : "Resume"
    }

    private var captureToggleHelp: String {
        guard model.screenPermissionGranted else {
            return "Allow Screen Recording in Settings before remembering"
        }
        return isRemembering ? "Pause remembering" : "Resume remembering"
    }

    @ViewBuilder
    private var detailSurface: some View {
        switch MainWindowDetailRoute.resolve(
            section: section,
            historyIsSealed: model.historyIsSealed,
            presentsFirstMemoryJourney: model.firstMemoryActivationState.presentsJourney
        ) {
        case .historySealed:
            HistorySealedView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(MainWindowDetailRoute.historySealed)
        case .firstMemoryJourney:
            HSplitView {
                FirstMemoryCoachView(
                    model: model,
                    armExternalAppHandoff: armGuidedFirstMemoryHandoff,
                    hideForAnotherAttempt: hideForAnotherFirstMemoryAttempt,
                    finishJourney: finishFirstMemoryJourney
                )
                .frame(minWidth: 380, idealWidth: 430, maxWidth: 540)
                .frame(maxHeight: .infinity)

                firstMemoryProofDetail
                .frame(minWidth: 380, maxHeight: .infinity)
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.18),
                    value: firstMemoryProofDetailRoute
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(MainWindowDetailRoute.firstMemoryJourney)
        case .everything:
            HSplitView {
                resultsColumn
                    .frame(minWidth: 330, idealWidth: 430, maxWidth: 560)
                    .frame(maxHeight: .infinity)
                FrameInspector(model: model) { hit in
                    _ = model.enterTimelineWorkspace(preferredDay: hit.capturedAt)
                    section = .timeline
                }
                .frame(minWidth: 380, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(MainWindowSection.everything)
        case .timeline:
            TimelineWorkspace(model: model) { hit in
                model.select(hit)
                section = .everything
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(MainWindowSection.timeline)
        case .sessions:
            HSplitView {
                ActivitySessionList(model: model)
                    .frame(minWidth: 330, idealWidth: 430, maxWidth: 560)
                    .frame(maxHeight: .infinity)
                ActivitySessionDetailView(model: model) { hit in
                    model.select(hit)
                    section = .everything
                }
                .frame(minWidth: 380, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(MainWindowSection.sessions)
        case .agentActivity:
            HSplitView {
                AgentActivityList(model: model)
                    .frame(minWidth: 330, idealWidth: 430, maxWidth: 560)
                    .frame(maxHeight: .infinity)
                AgentActivityDetail(model: model)
                .frame(minWidth: 380, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(MainWindowSection.agentActivity)
        }
    }

    private var firstMemoryProofDetailRoute: FirstMemoryProofDetailRoute {
        FirstMemoryProofDetailRoute.resolve(
            state: model.firstMemoryActivationState,
            selectedHitID: model.selectedHit?.id,
            selectedFrameID: model.selectedFrame?.id
        )
    }

    @ViewBuilder
    private var firstMemoryProofDetail: some View {
        switch firstMemoryProofDetailRoute {
        case .companion:
            FirstMemoryCompanionView()
        case .recallProof(let presentation):
            FirstMemoryRecallProofPlaceholder(presentation: presentation)
        case .awaitingVerifiedMoment:
            FirstMemoryVerifiedMomentPlaceholder()
        case .verifiedMoment:
            VStack(spacing: 0) {
                FirstMemoryVerifiedRecallBanner(
                    query: model.queryText,
                    applicationName: model.selectedHit?.context.applicationName ?? "Saved source"
                )
                Divider()
                FrameInspector(model: model) { hit in
                    _ = model.enterTimelineWorkspace(preferredDay: hit.capturedAt)
                    section = .timeline
                }
            }
        }
    }

    private func focusSearch() {
        section = .everything
        DispatchQueue.main.async {
            searchFocused = !model.firstMemoryActivationState.presentsJourney
        }
    }

    private func armGuidedFirstMemoryHandoff() {
        guidedFirstMemoryHandoffArmed = true
        hideForGuidedHandoffIfReady(state: model.firstMemoryActivationState)
    }

    private func hideForAnotherFirstMemoryAttempt() {
        guidedFirstMemoryHandoffArmed = true
        guidedHandoffHasHiddenApplication = true
        NSApplication.shared.hide(nil)
    }

    private func hideForGuidedHandoffIfReady(state: FirstMemoryActivationState) {
        guard FirstMemoryHandoffPolicy.shouldHideApplication(
            armed: guidedFirstMemoryHandoffArmed,
            alreadyHidden: guidedHandoffHasHiddenApplication,
            state: state
        ) else { return }
        guidedHandoffHasHiddenApplication = true
        NSApplication.shared.hide(nil)
    }

    private func handleFirstMemoryHandoff(
        from previous: FirstMemoryActivationState,
        to current: FirstMemoryActivationState
    ) {
        hideForGuidedHandoffIfReady(state: current)
        if FirstMemoryHandoffPolicy.shouldRequestAttention(
            armed: guidedFirstMemoryHandoffArmed,
            from: previous,
            to: current
        ) {
            NSApplication.shared.requestUserAttention(.informationalRequest)
        }
        if FirstMemoryHandoffPolicy.shouldDisarm(state: current) {
            guidedFirstMemoryHandoffArmed = false
        }
    }

    private func finishFirstMemoryJourney() {
        guard model.finishFirstMemoryActivationJourney() else { return }
        guidedFirstMemoryHandoffArmed = false
    }

    private func consumeActivationIntent() {
        guard let intent = PassageActivationCenter.shared.takePendingIntent() else { return }
        handleActivation(intent)
    }

    private func handleActivation(_ intent: PassageActivationIntent) {
        switch intent {
        case .open:
            break
        case .search:
            focusSearch()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [PassagePalette.accent, PassagePalette.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    PassageMarkView().foregroundStyle(.white).frame(width: 15, height: 15)
                }
                .frame(width: 28, height: 28)
                Text("Passage").font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            SidebarItem(
                icon: "clock.arrow.circlepath",
                label: "Recall",
                selected: section == .everything,
                action: { section = .everything }
            )
            SidebarItem(
                icon: "timeline.selection",
                label: "Timeline",
                selected: section == .timeline,
                action: { section = .timeline }
            )
            .disabled(model.historyIsSealed)
            SidebarItem(
                icon: "square.stack.3d.forward.dottedline",
                label: "Sessions",
                selected: section == .sessions,
                action: {
                    section = .sessions
                    Task { await model.refresh() }
                }
            )
            .disabled(model.historyIsSealed)
            SidebarItem(
                icon: "checkmark.shield",
                label: "Access History",
                selected: section == .agentActivity,
                action: {
                    section = .agentActivity
                    Task { await model.refresh() }
                }
            )
            .disabled(model.historyIsSealed)

            Text("ON THIS MAC")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 15)
                .padding(.top, 24)
                .padding(.bottom, 8)
            if model.captureState == .locked {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("History sealed")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 15)
                .frame(height: 27)
            } else {
                StatRow(value: model.statistics.frameCount.formatted(), label: "moments")
                StatRow(value: ByteCountFormatter.string(fromByteCount: model.statistics.mediaBytes, countStyle: .file), label: "media")
            }

            Spacer()
            CaptureStatusPill(state: model.captureState)
                .padding(12)
        }
        .background(.regularMaterial)
    }

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            SearchField(
                text: Binding(
                    get: { model.queryText },
                    set: { model.setRecallQueryText($0) }
                ),
                focus: $searchFocused
            )
                .disabled(model.historyIsSealed)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, hasActiveRecallQuery ? 7 : 9)

            if hasTextRecallQuery, model.memoryLensSelection == nil {
                RecallSearchModeControl(model: model)
                    .disabled(model.historyIsSealed)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 9)
            }

            RecallScopeBar(model: model)
                .disabled(model.historyIsSealed)
                .padding(.horizontal, 16)
                .padding(.bottom, 11)

            recallStatusHeader
            recallNotices

            Divider().opacity(0.45)
            recallResultsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var recallStatusHeader: some View {
        HStack {
            Text(recallResultsHeading)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if model.recallIsLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        recallQueryKind == .memoryLens
                            ? MemoryLensPresentation.loadingAccessibilityLabel
                            : model.recallResultsAreStale
                            ? "Updating recall scope"
                            : "Searching Passage"
                    )
            }
            if model.visualSearchIsRefining {
                Label(
                    recallQueryKind == .memoryLens
                        ? "Comparing selected area"
                        : "Checking image appearance",
                    systemImage: recallQueryKind == .memoryLens ? "viewfinder" : "eye"
                )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text("On this Mac")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PassagePalette.mint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var recallNotices: some View {
        if let interpretation = model.recallQueryInterpretation {
            RecallInterpretationBar(
                interpretation: interpretation,
                useOriginalWording: model.searchOriginalWording
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        } else if let searchError = model.searchError {
            SearchErrorBar(message: searchError)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }

        if model.firstMemoryActivationState.recallCandidate != nil {
            FirstMemoryRecallBanner(
                state: model.firstMemoryActivationState,
                search: {
                    focusSearch()
                    model.searchFirstMemorySuggestion()
                },
                retry: {
                    focusSearch()
                    model.retryFirstMemoryActivation()
                },
                skip: { model.skipFirstMemoryActivation() }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }

    }

    @ViewBuilder
    private var recallResultsContent: some View {
        if MemoryLensPresentation.hidesStaleResults(
            queryKind: recallQueryKind,
            resultsAreStale: model.recallResultsAreStale
        ) {
            RecallLoadingView(queryKind: .memoryLens)
        } else if model.results.isEmpty {
            if model.recallIsLoading {
                RecallLoadingView(queryKind: recallQueryKind)
            } else {
                EmptyResultsView(
                    queryKind: recallQueryKind,
                    hasFilters: model.hasRecallFilters,
                    searchMode: model.recallSearchMode,
                    visualState: model.visualUnderstandingState,
                    coverage: model.visualEmbeddingCoverage,
                    totalMomentCount: model.statistics.frameCount,
                    searchError: model.searchError
                )
            }
        } else {
            recallResultsList
                .opacity(model.recallResultsAreStale ? 0.52 : 1)
                .allowsHitTesting(!model.recallResultsAreStale)
                .accessibilityHidden(model.recallResultsAreStale)
        }
    }

    private var recallResultsList: some View {
        Group {
            if model.recallPresentationMode == .chronological {
                RecallResultsList(groups: recallDayGroups, model: model)
            } else {
                RankedRecallResultsList(model: model)
            }
        }
    }

    private var recallResultsHeading: String {
        if model.captureState == .locked {
            return "History sealed on this Mac"
        }
        if model.recallResultsAreStale {
            return recallQueryKind == .memoryLens
                ? MemoryLensPresentation.loadingHeading
                : "Updating scope…"
        }
        let shown = "\(model.results.count.formatted()) shown"
        let chronologicalCount = model.recallHasMore ? "\(shown) · more available" : shown
        if recallQueryKind == .memoryLens {
            return MemoryLensPresentation.heading(resultCount: model.results.count)
        }
        if recallQueryKind == .text {
            switch model.recallPresentationMode {
            case .bestMatches:
                return "Best matches · \(shown)"
            case .savedTextOnly:
                return "Saved text only · \(shown)"
            case .chronological:
                return "Recent matches · \(chronologicalCount)"
            }
        }
        return model.hasRecallFilters
            ? "Scoped history · \(chronologicalCount)"
            : "All history · \(chronologicalCount)"
    }

    private var hasTextRecallQuery: Bool {
        !model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recallQueryKind: RecallQueryKind {
        RecallQueryKind.resolve(
            queryText: model.queryText,
            hasMemoryLens: model.memoryLensSelection != nil
        )
    }

    private var hasActiveRecallQuery: Bool {
        recallQueryKind != .none
    }

    private var recallDayGroups: [RecallDayGroup] {
        model.recallDayGroups
    }
}

private struct HistorySealedView: View {
    private let presentation = HistorySealedPresentation.current

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .opacity(0.24)
            LinearGradient(
                colors: [
                    PassagePalette.accent.opacity(0.055),
                    .clear,
                    PassagePalette.violet.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PassagePalette.accent.opacity(0.10))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(PassagePalette.accent.opacity(0.16), lineWidth: 0.5)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(PassagePalette.accent)
                }
                .frame(width: 66, height: 66)
                .padding(.bottom, 21)

                Text(presentation.eyebrow)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.25)
                    .foregroundStyle(PassagePalette.accent)
                    .padding(.bottom, 9)

                Text(presentation.title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 9)

                Text(presentation.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)

                Label(presentation.status, systemImage: "clock.badge.checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(.primary.opacity(0.045), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(.primary.opacity(0.075), lineWidth: 0.5)
                    }
                    .padding(.top, 23)

                Divider()
                    .opacity(0.42)
                    .padding(.vertical, 23)

                Label(presentation.assurance, systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 34)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.055), radius: 24, y: 10)
            .padding(36)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(presentation.title). \(presentation.message) \(presentation.status). \(presentation.assurance)"
        )
    }
}

private struct RankedRecallResultsList: View {
    @Bindable var model: PassageModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.results) { hit in
                    Button {
                        model.select(hit)
                    } label: {
                        SearchResultRow(
                            hit: hit,
                            model: model,
                            isSelected: model.selectedHit?.id == hit.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this remembered moment")
                    .accessibilityAddTraits(
                        model.selectedHit?.id == hit.id ? .isSelected : []
                    )
                }

                Label(
                    rankingExplanation,
                    systemImage: model.memoryLensSelection == nil
                        ? "checkmark.circle"
                        : "viewfinder"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var rankingExplanation: String {
        RecallRankingExplanation.text(
            mode: model.recallPresentationMode,
            isRefining: model.visualSearchIsRefining,
            hasVisualEvidence: !model.visualRecallEvidenceByFrameID.isEmpty,
            hasMemoryLensSelection: model.memoryLensSelection != nil
        )
    }
}

enum RecallRankingExplanation {
    static func text(
        mode: PassageModel.RecallPresentationMode,
        isRefining: Bool,
        hasVisualEvidence: Bool,
        hasMemoryLensSelection: Bool = false
    ) -> String {
        if hasMemoryLensSelection {
            return MemoryLensPresentation.rankingFooter
        }
        return switch mode {
        case .savedTextOnly:
            "Ordered by saved-text relevance"
        case .bestMatches where isRefining && hasVisualEvidence:
            "Saved-text and image matches shown; checking finer image detail"
        case .bestMatches where isRefining:
            "Saved-text matches shown first; checking image appearance"
        case .bestMatches where hasVisualEvidence:
            "Ordered by saved text and image appearance"
        case .bestMatches:
            "Ordered by saved-text relevance"
        case .chronological:
            "Ordered from newest to oldest"
        }
    }
}

private struct RecallResultsList: View {
    let groups: [RecallDayGroup]
    @Bindable var model: PassageModel
    @State private var expandedMemberIDs: Set<FrameID> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    RecallDaySection(
                        group: group,
                        model: model,
                        expandedMemberIDs: $expandedMemberIDs
                    )
                }

                RecallPagingFooter(model: model)
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }
}

private struct RecallScopeBar: View {
    @Bindable var model: PassageModel
    @State private var showsTimePicker = false
    @State private var showsWebsitePicker = false
    @State private var customStart = Date()
    @State private var customEnd = Date()

    private var selectedApplications: Set<String> {
        model.effectiveRecallFilterScope.applicationBundleIdentifiers
    }

    private var selectedDomains: Set<String> {
        model.effectiveRecallFilterScope.domains
    }

    var body: some View {
        HStack(spacing: 7) {
            RecallFilterFlowLayout(spacing: 7) {
                    if model.memoryLensSelection != nil {
                        MemoryLensScopeChip(
                            image: model.memoryLensQueryImage,
                            remove: model.clearMemoryLens
                        )
                    }

                    Button {
                        prepareCustomDates()
                        showsTimePicker.toggle()
                    } label: {
                        RecallFilterChip(
                            icon: "calendar",
                            title: model.recallTimeLabel,
                            active: model.effectiveRecallFilterScope.startDate != nil
                                || model.effectiveRecallFilterScope.endDate != nil,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .popover(isPresented: $showsTimePicker, arrowEdge: .bottom) {
                        RecallTimePicker(
                            model: model,
                            customStart: $customStart,
                            customEnd: $customEnd,
                            dismiss: { showsTimePicker = false }
                        )
                    }

                    Menu {
                        if model.memoryLensSelection != nil {
                            Text("Counts reflect selected-area matches and the active filters.")
                            Divider()
                        } else if model.recallPresentationMode == .bestMatches {
                            Text("Counts use saved-text matches across this scope. Current appearance-only matches may also appear.")
                            Divider()
                        }
                        if let error = model.recallFacetsError {
                            Label(error, systemImage: "exclamationmark.triangle")
                            Button {
                                model.retryRecallFacets()
                            } label: {
                                Label("Retry filter counts", systemImage: "arrow.clockwise")
                            }
                            if !model.recallFacets.applications.isEmpty {
                                Divider()
                            }
                        }
                        if model.recallFacetsAreLoading {
                            Text(model.recallFacets.applications.isEmpty
                                ? "Counting apps…"
                                : "Updating app counts…")
                            if !model.recallFacets.applications.isEmpty {
                                Divider()
                            }
                        }
                        if !model.recallFacets.applications.isEmpty {
                            ForEach(model.recallFacets.applications, id: \.bundleIdentifier) { facet in
                                Button {
                                    model.toggleRecallApplication(facet.bundleIdentifier)
                                } label: {
                                    Label(
                                        "\(facet.applicationName) · \(facet.frameCount.formatted())",
                                        systemImage: selectedApplications.contains(facet.bundleIdentifier)
                                            ? "checkmark"
                                            : "app"
                                    )
                                }
                            }
                        } else if !model.recallFacetsAreLoading,
                                  model.recallFacetsError == nil {
                            Text("No apps available in this scope")
                        }
                        let unavailableSelections = selectedApplications.subtracting(
                            Set(model.recallFacets.applications.map(\.bundleIdentifier))
                        )
                        if !unavailableSelections.isEmpty {
                            Divider()
                            ForEach(unavailableSelections.sorted(), id: \.self) { identifier in
                                Button {
                                    model.toggleRecallApplication(identifier)
                                } label: {
                                    Label(
                                        applicationDisplayName(for: identifier) ?? identifier,
                                        systemImage: "checkmark"
                                    )
                                }
                            }
                        }
                    } label: {
                        RecallFilterChip(
                            icon: "app.badge",
                            title: applicationLabel,
                            active: !selectedApplications.isEmpty,
                            showsDisclosure: true,
                            isLoading: model.recallFacetsAreLoading
                                && model.recallFacets.applications.isEmpty
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 170)
                    .accessibilityLabel(applicationAccessibilityLabel)

                    Button {
                        showsWebsitePicker.toggle()
                    } label: {
                        RecallFilterChip(
                            icon: websiteChipPresentation.systemImage,
                            title: websiteChipPresentation.title,
                            active: !selectedDomains.isEmpty,
                            showsDisclosure: true,
                            isLoading: websiteChipPresentation.isLoading
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .popover(isPresented: $showsWebsitePicker, arrowEdge: .bottom) {
                        RecallWebsitePicker(
                            model: model,
                            selectedDomains: selectedDomains,
                            emptyPresentation: emptyWebsitePresentation
                        )
                    }
                    .frame(maxWidth: 170)
                    .accessibilityLabel(websiteChipPresentation.accessibilityLabel)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if model.hasRecallFilters {
                Button {
                    model.clearRecallFilters()
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 28)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Clear all recall filters")
                .help("Clear every recall filter")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recall scope")
    }

    private var applicationLabel: String {
        switch selectedApplications.count {
        case 0:
            if model.recallFacetsError != nil,
               model.recallFacets.applications.isEmpty {
                return "Apps unavailable"
            }
            return model.recallFacetsAreLoading && model.recallFacets.applications.isEmpty
                ? "Counting apps…"
                : "Apps"
        case 1:
            let identifier = selectedApplications.first ?? ""
            return model.recallFacets.applications.first {
                $0.bundleIdentifier == identifier
            }?.applicationName ?? applicationDisplayName(for: identifier) ?? identifier
        default:
            return "\(selectedApplications.count) apps"
        }
    }

    private var websiteChipPresentation: WebsiteFilterChipPresentation {
        WebsiteFilterChipPresentation.make(
            selectedDomains: selectedDomains,
            availableDomainCount: model.recallFacets.domains.count,
            availability: model.recallBrowserMomentAvailability,
            appContextGranted: model.accessibilityPermissionGranted,
            facetsAreLoading: model.recallFacetsAreLoading,
            hasFacetError: model.recallFacetsError != nil
        )
    }

    private var applicationAccessibilityLabel: String {
        let selection = selectedApplications.isEmpty
            ? "Filter by app"
            : "App filter, \(selectedApplications.count) selected"
        if model.recallFacetsError != nil {
            return "\(selection), filter counts unavailable"
        }
        return model.recallFacetsAreLoading
            ? "\(selection), counting available apps"
            : selection
    }

    private var emptyWebsitePresentation: WebsiteFacetEmptyPresentation {
        WebsiteFacetEmptyPresentation.make(
            availability: model.recallBrowserMomentAvailability,
            appContextGranted: model.accessibilityPermissionGranted,
            bestMatchesUseSavedTextScope: model.recallPresentationMode == .bestMatches
                && model.memoryLensSelection == nil,
            hasFilters: model.hasRecallFilters,
            hasFacetError: model.recallFacetsError != nil
        )
    }

    private func applicationDisplayName(for bundleIdentifier: String) -> String? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }
        let name = FileManager.default.displayName(atPath: applicationURL.path)
        let displayName = name.lowercased().hasSuffix(".app")
            ? String(name.dropLast(4))
            : name
        return displayName.isEmpty ? nil : displayName
    }

    private func prepareCustomDates() {
        let calendar = Calendar.autoupdatingCurrent
        let scope = model.effectiveRecallFilterScope
        customStart = scope.startDate
            ?? calendar.date(byAdding: .day, value: -6, to: Date())
            ?? Date()
        if let end = scope.endDate {
            customEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        } else {
            customEnd = Date()
        }
    }
}

/// Keeps every scope control visible instead of hiding the last filter in a
/// horizontal scroller. The results column can become narrow in split-view, so
/// controls wrap into a compact second row while preserving their reading order.
private struct RecallFilterFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0
        var measuredHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedLineWidth = lineWidth == 0
                ? size.width
                : lineWidth + spacing + size.width
            if lineWidth > 0, proposedLineWidth > availableWidth {
                measuredWidth = max(measuredWidth, lineWidth)
                measuredHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth = proposedLineWidth
                lineHeight = max(lineHeight, size.height)
            }
        }

        measuredWidth = max(measuredWidth, lineWidth)
        measuredHeight += lineHeight
        return CGSize(
            width: proposal.width.map { min(measuredWidth, $0) } ?? measuredWidth,
            height: measuredHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct RecallWebsitePicker: View {
    @Bindable var model: PassageModel
    let selectedDomains: Set<String>
    let emptyPresentation: WebsiteFacetEmptyPresentation

    private var unavailableSelections: [String] {
        selectedDomains.subtracting(
            Set(model.recallFacets.domains.map(\.domain))
        ).sorted()
    }

    private var hasRows: Bool {
        !model.recallFacets.domains.isEmpty || !unavailableSelections.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PassagePalette.accent)
                    .frame(width: 28, height: 28)
                    .background(PassagePalette.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Websites")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Limit recall to moments from a website")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hasRows && websiteChoicesAreLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating website choices")
                }
            }
            .padding(14)

            Divider().opacity(0.5)

            if hasRows, let error = model.recallFacetsError {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Retry") { model.retryRecallFacets() }
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.orange.opacity(0.07))
            }

            if hasRows {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.recallFacets.domains, id: \.domain) { facet in
                            WebsiteFacetRow(
                                domain: facet.domain,
                                count: facet.frameCount,
                                selected: selectedDomains.contains(facet.domain)
                            ) {
                                model.toggleRecallDomain(facet.domain)
                            }
                        }

                        if !unavailableSelections.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                            ForEach(unavailableSelections, id: \.self) { domain in
                                WebsiteFacetRow(
                                    domain: domain,
                                    count: nil,
                                    selected: true
                                ) {
                                    model.toggleRecallDomain(domain)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 310)
            } else if !websiteChoicesAreLoading {
                VStack(alignment: .leading, spacing: 12) {
                    Label(emptyPresentation.title, systemImage: emptyPresentation.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                    Text(emptyPresentation.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let recoveryAction = emptyPresentation.recoveryAction {
                        Button {
                            perform(recoveryAction)
                        } label: {
                            Label(recoveryAction.title, systemImage: recoveryAction.systemImage)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
            } else {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Finding website names in this scope…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            if hasRows && (model.memoryLensSelection != nil
                || model.recallPresentationMode == .bestMatches) {
                Divider().opacity(0.5)
                Text(model.memoryLensSelection != nil
                    ? "Counts reflect selected-area matches and the active filters."
                    : "Counts use matching saved text; appearance-only matches may not be included.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Website recall filter")
    }

    private var websiteChoicesAreLoading: Bool {
        model.recallFacetsAreLoading || model.recallBrowserMomentAvailability == .loading
    }

    private func perform(_ recoveryAction: WebsiteFacetEmptyPresentation.RecoveryAction) {
        switch recoveryAction {
        case .retry:
            model.retryRecallFacets()
        case .enableAppContext:
            model.requestAccessibilityPermission()
        case .clearFilters:
            model.clearRecallFilters()
        }
    }
}

private struct WebsiteFacetRow: View {
    let domain: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? PassagePalette.accent : Color.secondary)
                    .frame(width: 18)
                Text(domain)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let count {
                    Text(count.formatted())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                selected
                    ? PassagePalette.accent.opacity(0.09)
                    : isHovering
                    ? Color.primary.opacity(0.045)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            "\(domain), \(count.map { "\($0) moments" } ?? "selected website")"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RecallFilterChip: View {
    let icon: String
    let title: String
    let active: Bool
    let showsDisclosure: Bool
    var isLoading = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.65)
            }
        }
        .foregroundStyle(active ? PassagePalette.accent : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            active ? PassagePalette.accent.opacity(0.10) : Color.primary.opacity(0.045),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    active ? PassagePalette.accent.opacity(0.24) : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
        }
    }
}

private struct MemoryLensScopeChip: View {
    let image: CGImage?
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PassagePalette.mint)
                    }
                }
                .frame(width: 21, height: 21)
                .background(PassagePalette.mint.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

                Text(MemoryLensPresentation.scopeLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.68)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(PassagePalette.mint)
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .frame(height: 28)
            .background(PassagePalette.mint.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(PassagePalette.mint.opacity(0.25), lineWidth: 0.5)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(MemoryLensPresentation.scopeRemovalLabel)
        .help(MemoryLensPresentation.scopeRemovalHelp)
    }
}

private struct RecallTimePicker: View {
    @Bindable var model: PassageModel
    @Binding var customStart: Date
    @Binding var customEnd: Date
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When do you remember it?")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 3) {
                quickRange("Any time", systemImage: "infinity") {
                    model.clearRecallTimeScope()
                }
                quickRange("Today", systemImage: "sun.max") {
                    model.setRecallLastDays(1)
                }
                quickRange("Yesterday", systemImage: "arrow.uturn.backward.circle") {
                    let calendar = Calendar.autoupdatingCurrent
                    model.setRecallDay(
                        calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    )
                }
                quickRange("Last 7 days", systemImage: "calendar.badge.clock") {
                    model.setRecallLastDays(7)
                }
                quickRange("Last 30 days", systemImage: "calendar") {
                    model.setRecallLastDays(30)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text("Custom range")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("Through", selection: $customEnd, displayedComponents: .date)
            }

            HStack {
                Spacer()
                Button("Apply") {
                    model.setRecallCalendarRange(startingAt: customStart, through: customEnd)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 290)
        .accessibilityElement(children: .contain)
    }

    private func quickRange(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(PassagePalette.accent)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .frame(height: 28)
        }
        .buttonStyle(.plain)
    }
}

private struct RecallDaySection: View {
    let group: RecallDayGroup
    @Bindable var model: PassageModel
    @Binding var expandedMemberIDs: Set<FrameID>

    var body: some View {
        Section {
            ForEach(group.stacks) { stack in
                if stack.count == 1, let hit = stack.hits.first {
                    RecallMomentButton(hit: hit, model: model)
                } else {
                    RecallMomentStackView(
                        stack: stack,
                        model: model,
                        expandedMemberIDs: $expandedMemberIDs
                    )
                }
            }
        } header: {
            RecallDayHeader(
                day: group.day,
                momentCount: group.rawMomentCount,
                activityCount: group.activityCount
            )
        }
    }
}

private struct RecallMomentButton: View {
    let hit: SearchHit
    @Bindable var model: PassageModel
    var isNested = false

    var body: some View {
        Button {
            model.select(hit)
        } label: {
            SearchResultRow(
                hit: hit,
                model: model,
                isSelected: model.selectedHit?.id == hit.id
            )
        }
        .buttonStyle(.plain)
        .padding(.leading, isNested ? 16 : 0)
        .accessibilityLabel(
            "\(hit.context.applicationName), \(hit.capturedAt.formatted(date: .abbreviated, time: .standard)), \(hit.context.windowTitle ?? hit.context.domain ?? "Untitled moment")"
        )
        .accessibilityHint("Opens this exact saved change")
        .accessibilityAddTraits(model.selectedHit?.id == hit.id ? .isSelected : [])
    }
}

private struct RecallMomentStackView: View {
    let stack: RecallMomentStack
    @Bindable var model: PassageModel
    @Binding var expandedMemberIDs: Set<FrameID>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool {
        !stack.memberIDs.isDisjoint(with: expandedMemberIDs)
    }

    private var containsSelection: Bool {
        stack.contains(model.selectedHit?.id)
    }

    private var displayHit: SearchHit {
        stack.representative(selectedID: model.selectedHit?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: toggleExpansion) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            isExpanded
                                ? PassagePalette.accent
                                : Color.secondary.opacity(0.62)
                        )
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide individual saved changes" : "Show every saved change")
                .accessibilityLabel(
                    "\(stack.count) saved changes from \(displayHit.context.applicationName)"
                )
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(
                    isExpanded
                        ? "Collapse this activity"
                        : "Expand to browse every exact saved change"
                )

                Button {
                    model.select(displayHit)
                } label: {
                    SearchResultRow(
                        hit: displayHit,
                        model: model,
                        isSelected: containsSelection,
                        stack: stack
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(stackAccessibilityLabel)
                .accessibilityHint(
                    isExpanded
                        ? "Opens the currently represented change"
                        : "Opens this activity; expand to browse every saved change"
                )
                .accessibilityAddTraits(containsSelection ? .isSelected : [])
            }
            .padding(.leading, 2)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(stack.hits) { hit in
                        RecallMomentButton(hit: hit, model: model, isNested: true)
                    }
                }
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(PassagePalette.accent.opacity(0.18))
                        .frame(width: 2)
                        .padding(.leading, 17)
                        .padding(.vertical, 6)
                        .accessibilityHidden(true)
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
    }

    private var stackAccessibilityLabel: String {
        let title = displayHit.context.windowTitle
            ?? displayHit.context.domain
            ?? "Untitled activity"
        return "\(displayHit.context.applicationName), \(title), \(stack.count) saved changes, \(recallStackTimeRange(stack))"
    }

    private func toggleExpansion() {
        var updated = expandedMemberIDs
        if isExpanded {
            updated.subtract(stack.memberIDs)
        } else {
            updated.formUnion(stack.memberIDs)
        }
        if reduceMotion {
            expandedMemberIDs = updated
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                expandedMemberIDs = updated
            }
        }
    }
}

private struct RecallDayHeader: View {
    let day: Date
    let momentCount: Int
    let activityCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(summary)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.055)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), \(momentCount) saved changes across \(activityCount) activities"
        )
    }

    private var summary: String {
        let changes = "\(momentCount.formatted()) \(momentCount == 1 ? "change" : "changes")"
        let activities = "\(activityCount.formatted()) \(activityCount == 1 ? "activity" : "activities")"
        return "\(changes) · \(activities)"
    }

    private var title: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct RecallPagingFooter: View {
    @Bindable var model: PassageModel

    var body: some View {
        Group {
            if model.recallIsLoadingMore {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier moments…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if model.recallHasMore {
                Button {
                    model.loadEarlierRecall()
                } label: {
                    Label("Load earlier moments", systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .help("Continue chronologically toward the oldest retained memory")
            } else if !model.results.isEmpty {
                Label("Start of this remembered scope", systemImage: "checkmark.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("All retained moments in this scope are loaded")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private struct RecallLoadingView: View {
    let queryKind: RecallQueryKind

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(
                queryKind == .memoryLens
                    ? MemoryLensPresentation.loadingMessage
                    : "Searching your encrypted history…"
            )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct SearchField: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focus.wrappedValue ? PassagePalette.accent : Color.secondary)
            TextField("Search saved words or describe what you saw", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘ F").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    focus.wrappedValue
                        ? PassagePalette.accent.opacity(0.62)
                        : Color.primary.opacity(0.09),
                    lineWidth: focus.wrappedValue ? 1.25 : 0.5
                )
        }
        .shadow(
            color: focus.wrappedValue ? PassagePalette.accent.opacity(0.10) : .clear,
            radius: 7
        )
        .help("Try words from a screen, or describe a person, object, or scene. Search stays on this Mac.")
        .accessibilityHint("Enter saved words or describe something that appeared on screen")
    }
}

private struct MomentTimelineRibbon: View {
    let hits: [SearchHit]
    let selectedID: FrameID?
    let onSelect: (SearchHit) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var orderedHits: [SearchHit] {
        hits.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id.rawValue < $1.id.rawValue }
            return $0.capturedAt < $1.capturedAt
        }
    }

    private var selectedHit: SearchHit? {
        guard let selectedID else { return nil }
        return hits.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Moment timeline", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ribbonCaption)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(orderedHits.indices, id: \.self) { index in
                            let hit = orderedHits[index]
                            if index > orderedHits.startIndex {
                                MomentGapConnector(
                                    interval: hit.capturedAt.timeIntervalSince(
                                        orderedHits[index - 1].capturedAt
                                    )
                                )
                            }
                            MomentTimelineButton(
                                hit: hit,
                                selected: hit.id == selectedID,
                                action: { onSelect(hit) }
                            )
                            .id(hit.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    guard let selectedID else { return }
                    proxy.scrollTo(selectedID, anchor: .center)
                }
                .onChange(of: selectedID) { _, nextID in
                    guard let nextID else { return }
                    if reduceMotion {
                        proxy.scrollTo(nextID, anchor: .center)
                    } else {
                        withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                            proxy.scrollTo(nextID, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var ribbonCaption: String {
        if let selectedHit {
            return selectedHit.capturedAt.formatted(date: .abbreviated, time: .shortened)
        }
        guard let first = orderedHits.first, let last = orderedHits.last else { return "" }
        if Calendar.current.isDate(first.capturedAt, inSameDayAs: last.capturedAt) {
            return first.capturedAt.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(first.capturedAt.formatted(date: .numeric, time: .omitted)) – \(last.capturedAt.formatted(date: .numeric, time: .omitted))"
    }
}

private struct MomentGapConnector: View {
    let interval: TimeInterval

    private var width: CGFloat {
        switch max(interval, 0) {
        case ..<60: 4
        case ..<600: 8
        case ..<3_600: 14
        default: 22
        }
    }

    var body: some View {
        Capsule()
            .fill(.tertiary.opacity(0.35))
            .frame(width: width, height: 1)
            .accessibilityHidden(true)
    }
}

private struct MomentTimelineButton: View {
    let hit: SearchHit
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                PassageApplicationIcon(
                    bundleIdentifier: hit.context.bundleIdentifier,
                    size: 20
                )
                Text(hit.capturedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(selected ? .primary : .secondary)
                Capsule()
                    .fill(selected ? PassagePalette.accent : .clear)
                    .frame(width: selected ? 16 : 4, height: 2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                selected ? PassagePalette.accent.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(hit.context.windowTitle ?? hit.context.domain ?? hit.context.applicationName)
        .accessibilityLabel(
            "\(hit.context.applicationName), \(hit.capturedAt.formatted(date: .abbreviated, time: .shortened)), \(hit.context.windowTitle ?? hit.context.domain ?? "Untitled moment")"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarItem: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        selected
                            ? PassagePalette.accent.opacity(0.10)
                            : isHovering
                            ? Color.primary.opacity(0.045)
                            : Color.clear
                    )

                if selected {
                    Capsule()
                        .fill(PassagePalette.accent)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                }

                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .frame(width: 18)
                        .foregroundStyle(selected ? PassagePalette.accent : Color.secondary)
                    Text(label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(selected ? [] : .isSelected)
        .accessibilityValue(selected ? "Selected" : "")
    }
}

private struct StatRow: View {
    let value: String
    let label: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 15)
        .frame(height: 27)
    }
}

private struct CaptureStatusPill: View {
    let state: PassageModel.CaptureState

    private var presentation: CapturePrivacyPresentation {
        CapturePrivacyPresentation(state: state)
    }

    var body: some View {
        let toneColor = presentation.tone.passageColor
        let detailLineLimit = state.isCaptureError ? 3 : 2

        return content(toneColor: toneColor, detailLineLimit: detailLineLimit)
            .padding(10)
            .frame(minHeight: 54)
            .background(
                toneColor.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(toneColor.opacity(0.16), lineWidth: 0.5)
            }
            .help(presentation.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func content(
        toneColor: Color,
        detailLineLimit: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(toneColor)
                .frame(width: 24, height: 24)
                .background(
                    toneColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

private extension PassageModel.CaptureState {
    var isCaptureError: Bool {
        if case .error = self { return true }
        return false
    }
}

enum RecallMatchReason: Equatable {
    case savedText
    case imageAppearance
    case personDetail
    case savedTextAndImageAppearance
    case savedTextAndPersonDetail
    case selectedAreaAppearance

    @MainActor
    static func reason(for hit: SearchHit, model: PassageModel) -> Self {
        let evidence = model.visualRecallEvidenceByFrameID[hit.id]
        return reason(
            hasVisualEvidence: evidence != nil,
            hasRegionEvidence: evidence?.region != nil,
            isVisualOnly: model.visualOnlyRecallFrameIDs.contains(hit.id),
            hasMemoryLensSelection: model.memoryLensSelection != nil
        )
    }

    static func reason(
        hasVisualEvidence: Bool,
        hasRegionEvidence: Bool,
        isVisualOnly: Bool,
        hasMemoryLensSelection: Bool = false
    ) -> Self {
        if hasMemoryLensSelection { return .selectedAreaAppearance }
        guard hasVisualEvidence else { return .savedText }
        if hasRegionEvidence {
            return isVisualOnly ? .personDetail : .savedTextAndPersonDetail
        }
        return isVisualOnly ? .imageAppearance : .savedTextAndImageAppearance
    }

    var label: String {
        switch self {
        case .savedText: "Saved text"
        case .imageAppearance: "Image appearance"
        case .personDetail: "Person detail"
        case .savedTextAndImageAppearance: "Saved text + image appearance"
        case .savedTextAndPersonDetail: "Saved text + person detail"
        case .selectedAreaAppearance: "Looks like selected area"
        }
    }

    var systemImage: String {
        switch self {
        case .savedText: "text.quote"
        case .imageAppearance: "eye"
        case .personDetail: "person.crop.rectangle"
        case .savedTextAndImageAppearance: "text.below.photo"
        case .savedTextAndPersonDetail: "person.crop.rectangle"
        case .selectedAreaAppearance: "viewfinder"
        }
    }

    var explanation: String {
        switch self {
        case .savedText:
            "Words saved from this screen or its source details matched your search."
        case .imageAppearance:
            "The saved image looked related to your search. Your search words do not need to appear in its saved text."
        case .personDetail:
            "A smaller face or person area in the saved image looked related to your search. Passage did not identify who the person is."
        case .savedTextAndImageAppearance:
            "Both the saved text and the appearance of the saved image matched your search."
        case .savedTextAndPersonDetail:
            "Both the saved text and a smaller face or person area in the image matched your search. Passage did not identify who the person is."
        case .selectedAreaAppearance:
            "Passage compared this saved image with the selected area’s appearance on this Mac. It did not identify an object or person."
        }
    }

    var usesImageAppearance: Bool {
        self != .savedText
    }

    var usesPersonDetail: Bool {
        self == .personDetail || self == .savedTextAndPersonDetail
    }

    var copiedEvidenceDetail: String? {
        switch self {
        case .personDetail, .savedTextAndPersonDetail:
            "A smaller face or person area was compared on this Mac. No crop was saved, and Passage did not identify the person."
        case .selectedAreaAppearance:
            "The selected area’s appearance was compared on this Mac. Passage did not identify an object or person."
        case .savedText, .imageAppearance, .savedTextAndImageAppearance:
            nil
        }
    }

    var color: Color {
        usesImageAppearance ? PassagePalette.mint : Color.secondary
    }
}

private func recallStackTimeRange(_ stack: RecallMomentStack) -> String {
    guard let newest = stack.hits.first?.capturedAt,
          let oldest = stack.hits.last?.capturedAt else { return "" }
    let start = oldest.formatted(date: .omitted, time: .shortened)
    let end = newest.formatted(date: .omitted, time: .shortened)
    return start == end ? start : "\(start)–\(end)"
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let model: PassageModel
    let isSelected: Bool
    let stack: RecallMomentStack?

    init(
        hit: SearchHit,
        model: PassageModel,
        isSelected: Bool,
        stack: RecallMomentStack? = nil
    ) {
        self.hit = hit
        self.model = model
        self.isSelected = isSelected
        self.stack = stack
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    PassageApplicationIcon(
                        bundleIdentifier: hit.context.bundleIdentifier,
                        size: 16
                    )
                    Text(hit.context.applicationName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(timestampLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(hit.context.windowTitle ?? hit.context.domain ?? "Untitled moment")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if hasActiveRecallQuery {
                    HStack(spacing: 6) {
                        Label(matchReason.label, systemImage: matchReason.systemImage)
                        if let evidence = model.visualRecallEvidenceByFrameID[hit.id] {
                            if evidence.associatedFrameCount > 1 {
                                Text("· same scene in \(evidence.associatedFrameCount) saved moments")
                            }
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(matchReason.color)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
                Text(highlightedSnippet)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? PassagePalette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 6)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            if stack != nil {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .frame(width: 112, height: 70)
                    .offset(x: 4, y: 4)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 112, height: 70)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                    }
                    .offset(x: 2, y: 2)
            }

            FrameThumbnail(
                relativePath: hit.thumbnailRelativePath ?? hit.imageRelativePath,
                model: model
            )
            .frame(width: 112, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }

            if let stack {
                Text(stack.count.formatted())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 19)
                    .background(PassagePalette.accent, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                    }
                    .padding(6)
            }
        }
        .frame(width: 112, height: 70)
        .accessibilityHidden(true)
    }

    private var timestampLabel: String {
        if let stack {
            return recallStackTimeRange(stack)
        }
        return hit.capturedAt.formatted(date: .omitted, time: .shortened)
    }

    private var matchReason: RecallMatchReason {
        RecallMatchReason.reason(for: hit, model: model)
    }

    private var hasActiveRecallQuery: Bool {
        (!model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.memoryLensSelection != nil)
            && model.recallPresentationMode != .chronological
            && !model.recallResultsAreStale
    }

    /// SQLite's snippet markers are presentation metadata, not text the
    /// person captured. Render them as emphasis so a result explains itself.
    private var highlightedSnippet: AttributedString {
        var output = AttributedString()
        var buffer = ""
        var isMatch = false

        func segment(_ text: String, highlighted: Bool) -> AttributedString {
            var value = AttributedString(text)
            value.font = .system(size: 11, weight: highlighted ? .semibold : .regular)
            value.foregroundColor = highlighted ? PassagePalette.accent : .secondary
            return value
        }

        if let stack {
            var prefix = AttributedString(
                "\(stack.count.formatted()) saved changes  ·  "
            )
            prefix.font = .system(size: 11, weight: .semibold)
            prefix.foregroundColor = PassagePalette.accent
            output.append(prefix)
        }

        for character in hit.snippet {
            if character == "‹" || character == "›" {
                output.append(segment(buffer, highlighted: isMatch))
                buffer.removeAll(keepingCapacity: true)
                isMatch = character == "‹"
            } else {
                buffer.append(character)
            }
        }
        output.append(segment(buffer, highlighted: isMatch))
        return output
    }
}

private struct FrameThumbnail: View {
    let relativePath: String
    let model: PassageModel
    let contentMode: ContentMode
    let missingMessage: String?
    let onImageLoaded: ((NSImage) -> Void)?

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case image(NSImage)
        case missing
    }

    private struct LoadID: Hashable {
        let relativePath: String
        let mediaRevision: UInt64
    }

    init(
        relativePath: String,
        model: PassageModel,
        contentMode: ContentMode = .fill,
        missingMessage: String? = nil,
        onImageLoaded: ((NSImage) -> Void)? = nil
    ) {
        self.relativePath = relativePath
        self.model = model
        self.contentMode = contentMode
        self.missingMessage = missingMessage
        self.onImageLoaded = onImageLoaded
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.05))
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading saved image")
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityHidden(true)
            case .missing:
                if let missingMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 22, weight: .light))
                        Text(missingMessage)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .frame(maxWidth: 280)
                    }
                    .foregroundStyle(.secondary)
                    .padding(18)
                    .accessibilityElement(children: .combine)
                } else {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.tertiary)
                        .help("Image no longer stored; searchable text remains")
                        .accessibilityHidden(true)
                }
            }
        }
        .task(id: LoadID(
            relativePath: relativePath,
            mediaRevision: model.mediaRevision
        )) {
            phase = .loading
            let data = await model.mediaData(relativePath: relativePath)
            if let data, let image = NSImage(data: data) {
                phase = .image(image)
                onImageLoaded?(image)
            } else {
                phase = .missing
            }
        }
    }
}

private struct EmptyResultsView: View {
    let queryKind: RecallQueryKind
    let hasFilters: Bool
    let searchMode: PassageModel.RecallSearchMode
    let visualState: PassageModel.VisualUnderstandingState
    let coverage: VisualEmbeddingCoverage?
    let totalMomentCount: Int
    let searchError: String?

    private var presentation: RecallEmptyPresentation {
        RecallEmptyPresentation.make(
            queryKind: queryKind,
            hasFilters: hasFilters,
            searchMode: searchMode,
            visualState: visualState,
            coverage: coverage,
            totalMomentCount: totalMomentCount,
            searchError: searchError
        )
    }

    var body: some View {
        ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.systemImage)
        } description: {
            Text(presentation.message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecallSearchModeControl: View {
    @Bindable var model: PassageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Search method", selection: Binding(
                get: { model.recallSearchMode },
                set: { model.setRecallSearchMode($0) }
            )) {
                Text("Best matches").tag(PassageModel.RecallSearchMode.bestMatches)
                Text("Saved text only").tag(PassageModel.RecallSearchMode.savedTextOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Search method")
            .accessibilityValue(
                model.recallSearchMode == .bestMatches
                    ? "Best matches"
                    : "Saved text only"
            )
            .accessibilityHint(
                "Best matches can use saved text and image appearance. Saved text only does not compare images."
            )

            if let statusNote {
                Label(statusNote.message, systemImage: statusNote.icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(statusNote.isWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private var statusNote: (message: String, icon: String, isWarning: Bool)? {
        guard model.recallSearchMode == .bestMatches else { return nil }

        if let visualSearchError = model.visualSearchError {
            return (visualSearchError, "exclamationmark.triangle", true)
        }

        if let coverage = model.visualEmbeddingCoverage,
           coverage.pendingEligibleFrameCount > 0 {
            let progress = "Image search can use \(coverage.indexedEligibleFrameCount.formatted()) of \(coverage.eligibleFrameCount.formatted()) saved images."
            if model.visualUnderstandingState == .paused {
                return ("\(progress) Background indexing is paused.", "pause.circle", false)
            }
            return ("\(progress) Indexing continues in the background.", "eye", false)
        }

        switch model.visualUnderstandingState {
        case .verifying, .preparing:
            return (
                "Image appearance is getting ready. Saved-text matches are available now.",
                "clock",
                false
            )
        case .indexing:
            return (
                "Saved images are being indexed in the background. Saved-text matches are available now.",
                "eye",
                false
            )
        case .paused:
            return (
                "Image indexing is paused. Results can still use saved text and images already indexed.",
                "pause.circle",
                false
            )
        case .error:
            return (
                "Image appearance is unavailable. Results use saved text.",
                "exclamationmark.triangle",
                true
            )
        case .unavailable:
            return (
                "Image appearance is not available. Results use saved text.",
                "eye.slash",
                false
            )
        case .ready:
            return nil
        }
    }
}

private struct RecallInterpretationBar: View {
    let interpretation: RecallQueryInterpretation
    let useOriginalWording: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(PassagePalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search understood as")
                    .font(.system(size: 10, weight: .semibold))
                Text(interpretation.displayLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Use original wording", action: useOriginalWording)
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .help("Use your words as entered while keeping the selected search method")
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 42)
        .background(PassagePalette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(PassagePalette.accent.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search understood as \(interpretation.displayLabel)")
    }
}

private struct SearchErrorBar: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search couldn’t finish")
                    .font(.system(size: 10, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FirstMemoryCoachView: View {
    @Bindable var model: PassageModel
    let armExternalAppHandoff: () -> Void
    let hideForAnotherAttempt: () -> Void
    let finishJourney: () -> Void

    private var presentation: FirstMemoryCoachPresentation {
        FirstMemoryCoachPresentation(state: model.firstMemoryActivationState)
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 28)

            FirstMemoryGlyph(state: model.firstMemoryActivationState)

            VStack(spacing: 8) {
                Text(presentation.title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(presentation.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle = presentation.actionTitle {
                Button(actionTitle) { performPrimaryAction() }
                    .buttonStyle(PrimaryActionStyle())
            } else if presentation.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(presentation.progressAccessibilityLabel)
            }

            if presentation.canSkip {
                Button("Skip walkthrough") {
                    model.skipFirstMemoryActivation()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            FirstMemoryPath(state: model.firstMemoryActivationState)

            if presentation.showsReturnShortcut {
                Text("Come back anytime with  ⌃⇧Space")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 28)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [PassagePalette.accent.opacity(0.045), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func performPrimaryAction() {
        switch model.firstMemoryActivationState {
        case .permissionRequired:
            model.requestScreenPermission()
        case .paused:
            guard model.startCapturing() == .started else { return }
            armExternalAppHandoff()
        case .waitingForAnotherApplication, .protectedApplication, .blocked:
            hideForAnotherAttempt()
        case .resumeFailed:
            model.retryFirstMemoryActivation()
        case .recallReady:
            model.searchFirstMemorySuggestion()
        case .recallFailed:
            model.retryFirstMemoryActivation()
        case .verified:
            finishJourney()
        case .preparing, .processing, .recallSearching, .skipped, .complete:
            break
        }
    }
}

private struct FirstMemoryCompanionView: View {
    private let promises: [(icon: String, title: String, detail: String)] = [
        (
            "macwindow",
            "Focused, not indiscriminate",
            "The focused window is the default boundary; Passage never records itself."
        ),
        (
            "circle.lefthalf.filled",
            "Changes, not a video",
            "Repeated pixels back off. Useful visual changes become source-linked moments."
        ),
        (
            "lock.fill",
            "Sealed on this Mac",
            "Text, context, and visuals are encrypted locally before they become searchable."
        ),
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [PassagePalette.violet.opacity(0.07), .clear, PassagePalette.mint.opacity(0.045)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("LOCAL BY DEFAULT")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.25)
                            .foregroundStyle(PassagePalette.accent)
                        Text("A memory, not a recording.")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("Passage preserves enough evidence to help you return—without turning your day into a cloud video feed.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        ForEach(Array(promises.enumerated()), id: \.offset) { _, promise in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: promise.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(PassagePalette.accent)
                                    .frame(width: 34, height: 34)
                                    .background(PassagePalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(promise.title)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(promise.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                            }
                        }
                    }

                    Label(
                        "The first secured moment will open here with its screenshot, text, and exact source.",
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(44)
                .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct FirstMemoryCoachPresentation {
    let title: String
    let message: String
    let actionTitle: String?
    let showsReturnShortcut: Bool
    let showsProgress: Bool
    let progressAccessibilityLabel: String
    let canSkip: Bool

    init(state: FirstMemoryActivationState) {
        switch state {
        case .preparing:
            title = "Preparing your private timeline"
            message = "Opening the encrypted local vault. Nothing leaves this Mac."
            actionTitle = nil
            showsReturnShortcut = false
            showsProgress = true
            progressAccessibilityLabel = "Preparing the private timeline"
            canSkip = false
        case .permissionRequired:
            title = "One permission remains"
            message = "Allow Screen Recording so Passage can remember the focused window. Already enabled it? Fully quit and reopen Passage; closing the window is not enough. Audio and keystrokes are never captured."
            actionTitle = "Allow Screen Recording"
            showsReturnShortcut = false
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        case .paused:
            title = "Make one real memory"
            message = "Start remembering, then continue in any other app. Passage will tuck itself away once capture is ready and signal when the first useful moment can be recalled."
            actionTitle = "Create my first memory"
            showsReturnShortcut = true
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        case .waitingForAnotherApplication:
            title = "Ready for another app"
            message = "Passage never records its own windows. Hide it or switch apps; the next useful moment becomes searchable locally."
            actionTitle = "Hide Passage"
            showsReturnShortcut = true
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        case .processing(let applicationName):
            title = "Securing \(applicationName)"
            message = "Reading visible text, detecting change, and encrypting the moment on this Mac."
            actionTitle = nil
            showsReturnShortcut = false
            showsProgress = true
            progressAccessibilityLabel = "Securing the first memory"
            canSkip = false
        case .protectedApplication(let applicationName):
            title = "\(applicationName) stays private"
            message = "Passage skipped this protected context. Continue in a different app to create your first memory."
            actionTitle = "Choose another app"
            showsReturnShortcut = true
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        case .blocked:
            title = "That moment could not be secured"
            message = "Passage will keep your vault untouched. Switch to another app and try again."
            actionTitle = "Try another app"
            showsReturnShortcut = true
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        case .resumeFailed(_, let error):
            title = "Recall proof paused"
            message = error
            actionTitle = "Retry"
            showsReturnShortcut = false
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = true
        case .recallReady:
            title = "Your first memory is ready"
            message = "Passage secured a moment and prepared a local search beside this guide. Find it through the same Recall you’ll use every day."
            actionTitle = "Find this memory"
            showsReturnShortcut = false
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = true
        case .recallSearching:
            title = "Finding the exact moment"
            message = "Recall is searching the encrypted index on this Mac."
            actionTitle = nil
            showsReturnShortcut = false
            showsProgress = true
            progressAccessibilityLabel = "Finding the first memory locally"
            canSkip = true
        case .recallFailed(_, let error):
            title = "Recall needs another try"
            message = error
            actionTitle = "Retry recall"
            showsReturnShortcut = false
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = true
        case .verified:
            title = "First memory recalled"
            message = "Passage found the exact saved moment locally and kept its source attached. Your private history is ready."
            actionTitle = "Enter Passage"
            showsReturnShortcut = false
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        case .skipped, .complete:
            title = "First memory walkthrough complete"
            message = "Your local history is ready."
            actionTitle = nil
            showsReturnShortcut = false
            showsProgress = false
            progressAccessibilityLabel = ""
            canSkip = false
        }
    }
}

private struct FirstMemoryGlyph: View {
    let state: FirstMemoryActivationState

    private var symbol: String {
        switch state {
        case .preparing: "lock.rotation"
        case .permissionRequired: "rectangle.inset.filled.and.person.filled"
        case .paused: "record.circle"
        case .waitingForAnotherApplication: "rectangle.on.rectangle.angled"
        case .processing: "waveform.path.ecg.rectangle"
        case .protectedApplication: "hand.raised.fill"
        case .recallReady: "magnifyingglass"
        case .recallSearching: "magnifyingglass.circle"
        case .recallFailed, .resumeFailed: "arrow.clockwise"
        case .verified, .complete: "checkmark"
        case .skipped: "forward.fill"
        case .blocked: "exclamationmark"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [PassagePalette.accent.opacity(0.16), PassagePalette.violet.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 112, height: 92)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 76, height: 58)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 0.5)
                }
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PassagePalette.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityHidden(true)
    }
}

private struct FirstMemoryPath: View {
    let state: FirstMemoryActivationState

    private var activeStep: Int {
        switch state {
        case .recallReady, .recallSearching, .recallFailed,
             .resumeFailed, .verified, .skipped, .complete: 3
        case .processing: 2
        default: 1
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            step(1, label: "Capture")
            connector(through: 2)
            step(2, label: "Secure")
            connector(through: 3)
            step(3, label: "Recall")
        }
        .font(.system(size: 10, weight: .medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("First memory progress: step \(activeStep) of 3")
    }

    private func step(_ value: Int, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(value <= activeStep ? PassagePalette.accent : Color.secondary.opacity(0.18))
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(value <= activeStep ? .secondary : .tertiary)
        }
    }

    private func connector(through step: Int) -> some View {
        Capsule()
            .fill(step <= activeStep ? PassagePalette.accent.opacity(0.45) : Color.secondary.opacity(0.13))
            .frame(width: 20, height: 1)
    }
}

struct FirstMemoryRecallBannerPresentation: Equatable {
    enum Phase: Equatable {
        case ready
        case searching
        case failed
    }

    let phase: Phase
    let title: String
    let message: String
    let query: String
    let applicationName: String
    let sourceLabel: String
    let localityMessage: String

    init?(state: FirstMemoryActivationState) {
        let candidate: FirstMemoryRecallCandidate
        switch state {
        case .recallReady(let recallCandidate):
            candidate = recallCandidate
            phase = .ready
            title = "Prove you can find it"
            message = "Use normal Recall to return the exact saved moment. The moment stays hidden until the proof succeeds."
        case .recallSearching(let recallCandidate):
            candidate = recallCandidate
            phase = .searching
            title = "Finding the exact moment"
            message = "Recall is searching the encrypted index on this Mac."
        case .recallFailed(let recallCandidate, let error):
            candidate = recallCandidate
            phase = .failed
            title = "Recall needs another try"
            message = error
        default:
            return nil
        }
        query = candidate.query
        applicationName = candidate.applicationName
        sourceLabel = candidate.source.label
        localityMessage = "Encrypted Recall stays on this Mac."
    }
}

/// Decides whether the first-memory detail pane may reveal saved content.
///
/// The model owns proof semantics. This policy adds a presentation boundary:
/// an inspector is available only after verification and only when both the
/// visible hit and its loaded frame match the verified opaque identifier.
enum FirstMemoryProofDetailRoute: Equatable {
    case companion
    case recallProof(FirstMemoryRecallBannerPresentation)
    case awaitingVerifiedMoment(FrameID)
    case verifiedMoment(FrameID)

    var revealsMoment: Bool {
        if case .verifiedMoment = self { return true }
        return false
    }

    static func resolve(
        state: FirstMemoryActivationState,
        selectedHitID: FrameID?,
        selectedFrameID: FrameID?
    ) -> Self {
        if let presentation = FirstMemoryRecallBannerPresentation(state: state) {
            return .recallProof(presentation)
        }

        guard case .verified(let verifiedFrameID) = state else {
            return .companion
        }
        guard selectedHitID == verifiedFrameID,
              selectedFrameID == verifiedFrameID else {
            return .awaitingVerifiedMoment(verifiedFrameID)
        }
        return .verifiedMoment(verifiedFrameID)
    }
}

private struct FirstMemoryRecallProofPlaceholder: View {
    let presentation: FirstMemoryRecallBannerPresentation

    private var statusColor: Color {
        presentation.phase == .failed ? .orange : PassagePalette.accent
    }

    private var statusSystemImage: String {
        switch presentation.phase {
        case .ready: "magnifyingglass"
        case .searching: "magnifyingglass"
        case .failed: "arrow.clockwise"
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [PassagePalette.accent.opacity(0.045), .clear],
                startPoint: .top,
                endPoint: .center
            )

            VStack(spacing: 22) {
                Spacer(minLength: 28)

                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.10))
                        .frame(width: 64, height: 64)
                    if presentation.phase == .searching {
                        ProgressView()
                            .controlSize(.regular)
                            .accessibilityLabel("Searching for the exact saved moment locally")
                    } else {
                        Image(systemName: statusSystemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(statusColor)
                            .accessibilityHidden(true)
                    }
                }

                VStack(spacing: 8) {
                    Text("LOCAL RECALL PROOF")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(statusColor)
                    Text(presentation.title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(presentation.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 390)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 11) {
                    Label {
                        Text("“\(presentation.query)”")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(PassagePalette.accent)
                    }

                    Divider()

                    Label(presentation.applicationName, systemImage: "macwindow")
                    Label(presentation.sourceLabel.capitalized, systemImage: "text.quote")
                    Label(presentation.localityMessage, systemImage: "lock.fill")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .padding(16)
                .frame(maxWidth: 420, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                }

                Spacer(minLength: 28)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FirstMemoryVerifiedMomentPlaceholder: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                Text("Opening the exact moment")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Recall verified the match on this Mac. Passage is loading the secured frame before revealing it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 340)
            }
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recall found the exact saved moment. Loading its secured frame.")
    }
}

private struct FirstMemoryVerifiedRecallBanner: View {
    let query: String
    let applicationName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Found by Recall", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PassagePalette.mint)
                Spacer(minLength: 8)
                Text("\(applicationName) · on this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("“\(query)”")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(PassagePalette.mint.opacity(0.075))
        .accessibilityElement(children: .combine)
    }
}

private struct FirstMemoryRecallBanner: View {
    let state: FirstMemoryActivationState
    let search: () -> Void
    let retry: () -> Void
    let skip: () -> Void

    private var presentation: FirstMemoryRecallBannerPresentation? {
        FirstMemoryRecallBannerPresentation(state: state)
    }

    var body: some View {
        if let presentation {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if presentation.phase == .searching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: presentation.phase == .failed
                            ? "arrow.clockwise.circle.fill"
                            : "magnifyingglass.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(presentation.phase == .failed
                    ? Color.orange
                    : PassagePalette.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(presentation.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("“\(presentation.query)”")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary.opacity(0.82))
                }
                Spacer(minLength: 6)

                switch presentation.phase {
                case .ready:
                    Button("Search it", action: search)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .searching:
                    Text("Searching locally")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                case .failed:
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                Button("Skip", action: skip)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Skip the first recall walkthrough without changing saved history")
            }
            .padding(11)
            .background(
                (presentation.phase == .failed
                    ? Color.orange.opacity(0.07)
                    : PassagePalette.accent.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        presentation.phase == .failed
                            ? Color.orange.opacity(0.20)
                            : PassagePalette.accent.opacity(0.20),
                        lineWidth: 0.5
                    )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(presentation.title). Suggested search: \(presentation.query)")
        }
    }
}

private struct ActivitySessionList: View {
    @Bindable var model: PassageModel
    @State private var filterText = ""

    private var filteredSessions: [ActivitySessionSummary] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.activitySessions }
        return model.activitySessions.filter { session in
            [
                session.title,
                session.latestApplicationName,
                session.latestDomain,
                session.latestSnippet,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionFilterField(text: $filterText)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            HStack {
                Text(sessionCountLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Built locally")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PassagePalette.mint)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            Divider().opacity(0.45)

            if let error = model.activitySessionError, model.activitySessions.isEmpty {
                ContentUnavailableView {
                    Label("Sessions unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSessions.isEmpty {
                ContentUnavailableView {
                    Label(
                        filterText.isEmpty ? "No sessions yet" : "No matching sessions",
                        systemImage: filterText.isEmpty ? "square.stack.3d.forward.dottedline" : "magnifyingglass"
                    )
                } description: {
                    Text(
                        filterText.isEmpty
                            ? "As Passage remembers, related moments will gather into resumable work sessions."
                            : "Try an app, website, project name, or phrase you remember."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredSessions) { session in
                            ActivitySessionRow(
                                session: session,
                                model: model,
                                isSelected: model.selectedActivitySession?.id == session.id
                            ) {
                                model.selectActivitySession(session)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
        .onAppear { selectFirstSessionIfNeeded(from: filteredSessions) }
        .onChange(of: model.activitySessions) { _, sessions in
            selectFirstSessionIfNeeded(from: sessions)
        }
        .onChange(of: filterText) { _, _ in
            selectFirstSessionIfNeeded(from: filteredSessions)
        }
    }

    private var sessionCountLabel: String {
        if filterText.isEmpty {
            return "\(model.activitySessions.count) sessions"
        }
        return "\(filteredSessions.count) matching sessions"
    }

    private func selectFirstSessionIfNeeded(from sessions: [ActivitySessionSummary]) {
        guard let first = sessions.first else {
            if !filterText.isEmpty { model.selectActivitySession(nil) }
            return
        }
        guard model.selectedActivitySession == nil
                || !sessions.contains(where: { $0.id == model.selectedActivitySession?.id }) else {
            return
        }
        model.selectActivitySession(first)
    }
}

private struct SessionFilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter sessions", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear session filter")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.09), lineWidth: 0.5)
        }
    }
}

private struct ActivitySessionRow: View {
    let session: ActivitySessionSummary
    let model: PassageModel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let path = session.representativeThumbnailRelativePath {
                        FrameThumbnail(relativePath: path, model: model)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.primary.opacity(0.055))
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        PassageApplicationIcon(
                            bundleIdentifier: session.latestBundleIdentifier,
                            size: 16
                        )
                        Text(session.latestApplicationName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(session.endedAt, format: .dateTime.hour().minute())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if session.containsSensitive {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(PassagePalette.violet)
                                .help("Contains a locally private moment")
                        }
                    }

                    Text(displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(sessionRowMetadata(session))
                        .lineLimit(2)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? PassagePalette.accent.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel(
            "\(session.title), \(session.latestApplicationName), \(session.frameCount) moments, \(sessionDuration(session.duration))"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var displayTitle: String {
        guard let enrichment = model.selectedSessionEnrichment,
              enrichment.activitySessionID == session.id else { return session.title }
        return enrichment.title.text
    }

    private func sessionRowMetadata(_ session: ActivitySessionSummary) -> String {
        var parts = [sessionDuration(session.duration), "\(session.frameCount) moments"]
        if let domain = session.latestDomain { parts.append(domain) }
        return parts.joined(separator: " · ")
    }
}

private struct ActivitySessionDetailView: View {
    @Bindable var model: PassageModel
    let onViewMoment: (SearchHit) -> Void

    @State private var confirmingPrivateEnhancement = false
    @State private var confirmingPrivateQuestion = false
    @FocusState private var questionFieldFocused: Bool

    var body: some View {
        Group {
            if let detail = model.selectedActivitySessionDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        representativePreview(for: detail)
                        sessionHeading(for: detail.summary)
                        actionBar(for: detail)

                        intelligenceCard(for: detail)
                        sessionQuestionCard(for: detail)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Latest captured text")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(cleaned(detail.summary.latestSnippet))
                                .font(.system(size: 13))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }

                        if !detail.moments.isEmpty {
                            MomentTimelineRibbon(
                                hits: detail.moments,
                                selectedID: detail.summary.latestFrameID,
                                onSelect: onViewMoment
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Session moments")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(detail.moments.prefix(12)) { hit in
                                    Button { onViewMoment(hit) } label: {
                                        HStack(spacing: 9) {
                                            PassageApplicationIcon(
                                                bundleIdentifier: hit.context.bundleIdentifier,
                                                size: 18
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(hit.context.windowTitle ?? hit.context.domain ?? hit.context.applicationName)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                                Text(hit.capturedAt, format: .dateTime.hour().minute())
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            } else if let error = model.activitySessionError,
                      model.selectedActivitySession != nil {
                ContentUnavailableView {
                    Label("Session unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if model.selectedActivitySession != nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Gathering this session…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "square.stack.3d.forward.dottedline",
                    description: Text("Its timeline, return point, and local evidence will appear here.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.selectedActivitySession?.id) { _, _ in
            confirmingPrivateEnhancement = false
            confirmingPrivateQuestion = false
            questionFieldFocused = false
        }
        .onChange(of: model.sessionQuestionState) { _, state in
            if state == .awaitingPrivateConfirmation {
                confirmingPrivateQuestion = true
            }
        }
        .onChange(of: confirmingPrivateQuestion) { wasPresented, isPresented in
            if wasPresented,
               !isPresented,
               model.sessionQuestionState == .awaitingPrivateConfirmation {
                model.cancelPreparedSessionQuestion()
            }
        }
        .confirmationDialog(
            "Enhance this private session?",
            isPresented: $confirmingPrivateEnhancement,
            titleVisibility: .visible
        ) {
            Button("Send extracted text to OpenAI") {
                model.enhanceSelectedActivitySession(
                    forceRefresh: model.selectedSessionEnrichment != nil
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session contains history marked private. Passage will send only a bounded text transcript—never screenshots—to create a source-cited summary and next actions.")
        }
        .confirmationDialog(
            "Ask this private session?",
            isPresented: $confirmingPrivateQuestion,
            titleVisibility: .visible
        ) {
            if let preparation = model.preparedSessionQuestion {
                Button("Send question and \(preparation.selectedMomentCount) text moments to OpenAI") {
                    model.submitPreparedSessionQuestion()
                }
            }
            Button("Cancel", role: .cancel) {
                model.cancelPreparedSessionQuestion()
            }
        } message: {
            if let preparation = model.preparedSessionQuestion {
                Text("Passage will send the question you submitted and \(formattedByteCount(preparation.selectedTextUTF8ByteCount)) of extracted text from this session. Screenshots stay local. This approval applies only to this question.")
            }
        }
    }

    @ViewBuilder
    private func representativePreview(for detail: ActivitySessionDetail) -> some View {
        if let path = detail.summary.representativeThumbnailRelativePath {
            FrameThumbnail(
                relativePath: path,
                model: model,
                contentMode: .fit,
                missingMessage: "This image is no longer stored. The moment's text remains searchable."
            )
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    private func sessionHeading(for session: ActivitySessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                PassageApplicationIcon(
                    bundleIdentifier: session.latestBundleIdentifier,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle(for: session))
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(session.latestApplicationName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Text(session.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                    Text("–")
                    Text(session.endedAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text(sessionDuration(session.duration))
                    Text("·")
                    Text("\(session.frameCount) moments")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                    Text("Until \(session.endedAt.formatted(date: .omitted, time: .shortened)) · \(sessionDuration(session.duration)) · \(session.frameCount) moments")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if session.containsSensitive {
                Label("Contains private local history; excluded from agent access", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PassagePalette.violet)
            }
        }
    }

    private func actionBar(for detail: ActivitySessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Button { resume(detail.summary) } label: {
                    Label(resumeLabel(for: detail.summary), systemImage: resumeIcon(for: detail.summary))
                }
                .buttonStyle(.borderedProminent)
                .tint(PassagePalette.accent)
                .disabled(!canResume(detail.summary))
                .help(resumeHelp(for: detail.summary))

                Button { model.prepareContextHandoff(for: detail) } label: {
                    Label("Hand Off Context…", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("Preview the exact private-safe context before copying it")
            }

            HStack(spacing: 9) {
                if let representative = detail.moments.first(where: {
                    $0.id == detail.summary.representativeFrameID
                }) {
                    Button { onViewMoment(representative) } label: {
                        Label("View Moment", systemImage: "rectangle.and.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }

                if model.openAIAPIKeyConfigured {
                    Button { requestEnhancement(for: detail) } label: {
                        Label(
                            enhancementButtonLabel,
                            systemImage: model.intelligenceState == .enhancing
                                ? "hourglass"
                                : "sparkles"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.intelligenceState == .enhancing || detail.moments.isEmpty)
                    .help("Send bounded extracted text—never screenshots—to create a source-cited session brief")
                } else {
                    SettingsLink {
                        Label("Set Up Intelligence", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .help("Add a provider key; Passage never enhances sessions automatically")
                }
            }
        }
    }

    @ViewBuilder
    private func intelligenceCard(for detail: ActivitySessionDetail) -> some View {
        if let enrichment = model.selectedSessionEnrichment,
           enrichment.activitySessionID == detail.summary.id {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("Session intelligence", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(enrichment.model) · text only")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                IntelligenceClaimView(
                    label: "Summary",
                    claim: enrichment.summary,
                    moments: detail.moments,
                    onViewMoment: onViewMoment
                )
                IntelligenceClaimView(
                    label: "Where you left off",
                    claim: enrichment.whereLeftOff,
                    moments: detail.moments,
                    onViewMoment: onViewMoment
                )

                if !enrichment.nextActions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Possible next actions")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(enrichment.nextActions.enumerated()), id: \.offset) { index, action in
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(PassagePalette.accent)
                                    .frame(width: 18, height: 18)
                                    .background(
                                        PassagePalette.accent.opacity(0.10),
                                        in: Circle()
                                    )
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(action.text)
                                        .font(.system(size: 12))
                                        .lineSpacing(3)
                                    IntelligenceCitationStrip(
                                        frameIDs: action.sourceFrameIDs,
                                        moments: detail.moments,
                                        onViewMoment: onViewMoment
                                    )
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("Encrypted local cache · invalidates when source text changes")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [
                        PassagePalette.accent.opacity(0.08),
                        PassagePalette.violet.opacity(0.055),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PassagePalette.accent.opacity(0.16), lineWidth: 0.5)
            }
        } else if model.intelligenceState == .enhancing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhancing this session")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Only bounded extracted text is being sent. Screenshots remain local.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else if case .error(let message) = model.intelligenceState {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Intelligence couldn’t finish")
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private func sessionQuestionCard(for detail: ActivitySessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Label("Ask this session", systemImage: "scope")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.sessionQuestionState.isWorking {
                    Text(model.sessionQuestionState == .preparing ? "Selecting evidence" : "Answering")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if model.openAIAPIKeyConfigured {
                HStack(spacing: 8) {
                    TextField(
                        "Ask a specific question about these moments…",
                        text: $model.sessionQuestionText
                    )
                    .textFieldStyle(.plain)
                    .focused($questionFieldFocused)
                    .onSubmit { submitSessionQuestionIfPossible(detail) }
                    .disabled(model.sessionQuestionState.isWorking
                        || model.sessionQuestionState == .awaitingPrivateConfirmation)

                    if model.sessionQuestionState.isWorking {
                        Button {
                            model.cancelSessionQuestion()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .background(.primary.opacity(0.07), in: Circle())
                        .help("Cancel this question")
                        .accessibilityLabel("Cancel session question")
                    } else {
                        Button {
                            submitSessionQuestionIfPossible(detail)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .background(PassagePalette.accent, in: Circle())
                        .disabled(!canSubmitSessionQuestion(detail))
                        .help("Ask using only this session’s selected text")
                        .accessibilityLabel("Ask this session")
                    }
                }
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .frame(minHeight: 36)
                .background(.background.opacity(0.74), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(questionFieldFocused ? 0.18 : 0.09), lineWidth: 0.5)
                }
            } else {
                HStack(spacing: 9) {
                    Text("Add your provider key to ask source-cited questions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink {
                        Label("Set Up", systemImage: "key")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Up to 20 KB of text from this session; screenshots stay local")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)

            sessionQuestionStatus

            if let answer = model.selectedSessionQuestionAnswer,
               answer.activitySessionID == detail.summary.id {
                Divider().opacity(0.55)
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sessionQuestionHasError ? "Previous question" : "Question")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(answer.question)
                            .font(.system(size: 12, weight: .medium))
                            .textSelection(.enabled)
                    }

                    if answer.status == .answered {
                        ForEach(Array(answer.claims.enumerated()), id: \.offset) { index, claim in
                            IntelligenceClaimView(
                                label: index == 0 ? "Answer" : "Supporting detail",
                                claim: claim,
                                moments: detail.moments,
                                onViewMoment: onViewMoment
                            )
                        }
                    } else {
                        Label("Not enough evidence in this session", systemImage: "questionmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                        Text(answerProvenance(answer))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var sessionQuestionStatus: some View {
        switch model.sessionQuestionState {
        case .preparing, .answering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.sessionQuestionState == .preparing
                    ? "Selecting the most relevant moments locally…"
                    : "Building a source-cited answer…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        case .awaitingPrivateConfirmation:
            Label("Waiting for this question’s private-session approval", systemImage: "lock.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PassagePalette.violet)
        case .insufficientEvidence:
            Label("Not enough evidence in this session to answer that question", systemImage: "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        case .error(let message):
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedSessionQuestionAnswer == nil
                        ? "This question couldn’t finish"
                        : "The new question couldn’t finish; the previous answer is still below")
                        .font(.system(size: 10, weight: .semibold))
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .idle:
            EmptyView()
        }
    }

    private func canSubmitSessionQuestion(_ detail: ActivitySessionDetail) -> Bool {
        model.openAIAPIKeyConfigured
            && !detail.moments.isEmpty
            && !model.sessionQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.sessionQuestionState.isWorking
            && model.sessionQuestionState != .awaitingPrivateConfirmation
    }

    private func submitSessionQuestionIfPossible(_ detail: ActivitySessionDetail) {
        guard canSubmitSessionQuestion(detail) else { return }
        model.prepareSelectedSessionQuestion()
    }

    private func answerProvenance(_ answer: SessionQuestionAnswer) -> String {
        var text = "Based on \(answer.evidenceMomentCount) selected moments"
        if let date = answer.evidenceThrough {
            text += " through " + date.formatted(date: .omitted, time: .shortened)
        }
        return text + " · encrypted local cache"
    }

    private var sessionQuestionHasError: Bool {
        if case .error = model.sessionQuestionState { return true }
        return false
    }

    private func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var enhancementButtonLabel: String {
        if model.intelligenceState == .enhancing { return "Enhancing…" }
        return model.selectedSessionEnrichment == nil ? "Enhance" : "Refresh Brief"
    }

    private func requestEnhancement(for detail: ActivitySessionDetail) {
        if detail.summary.containsSensitive {
            confirmingPrivateEnhancement = true
        } else {
            model.enhanceSelectedActivitySession(
                forceRefresh: model.selectedSessionEnrichment != nil
            )
        }
    }

    private func displayTitle(for session: ActivitySessionSummary) -> String {
        guard let enrichment = model.selectedSessionEnrichment,
              enrichment.activitySessionID == session.id else { return session.title }
        return enrichment.title.text
    }

    private func canResume(_ session: ActivitySessionSummary) -> Bool {
        session.resumeTarget.url != nil || session.resumeTarget.bundleIdentifier != nil
    }

    private func resumeLabel(for session: ActivitySessionSummary) -> String {
        session.resumeTarget.restoresExactSource ? "Resume Webpage" : "Open App"
    }

    private func resumeIcon(for session: ActivitySessionSummary) -> String {
        session.resumeTarget.restoresExactSource ? "safari" : "arrow.up.forward.app"
    }

    private func resumeHelp(for session: ActivitySessionSummary) -> String {
        if let url = session.resumeTarget.url { return "Open \(url.absoluteString)" }
        if session.resumeTarget.bundleIdentifier != nil {
            return "Reactivate \(session.resumeTarget.applicationName); Passage cannot restore an exact document without a captured URL"
        }
        return "No safe return target was captured"
    }

    private func resume(_ session: ActivitySessionSummary) {
        if let url = session.resumeTarget.url {
            NSWorkspace.shared.open(url)
            return
        }
        guard let bundleIdentifier = session.resumeTarget.bundleIdentifier,
              let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
              ) else { return }
        NSWorkspace.shared.open(applicationURL)
    }

    private func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "‹", with: "")
            .replacingOccurrences(of: "›", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct IntelligenceClaimView: View {
    let label: String
    let claim: SessionIntelligenceClaim
    let moments: [SearchHit]
    let onViewMoment: (SearchHit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(claim.text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
            IntelligenceCitationStrip(
                frameIDs: claim.sourceFrameIDs,
                moments: moments,
                onViewMoment: onViewMoment
            )
        }
    }
}

private struct IntelligenceCitationStrip: View {
    let frameIDs: [FrameID]
    let moments: [SearchHit]
    let onViewMoment: (SearchHit) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(frameIDs, id: \.self) { frameID in
                    if let hit = moments.first(where: { $0.id == frameID }) {
                        Button { onViewMoment(hit) } label: {
                            HStack(spacing: 4) {
                                PassageApplicationIcon(
                                    bundleIdentifier: hit.context.bundleIdentifier,
                                    size: 12
                                )
                                Text(hit.capturedAt, format: .dateTime.hour().minute())
                                    .font(.system(size: 9, design: .monospaced))
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open source frame \(frameID.rawValue)")
                        .accessibilityLabel(sourceAccessibilityLabel(hit))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sourceAccessibilityLabel(_ hit: SearchHit) -> String {
        let time = hit.capturedAt.formatted(date: .omitted, time: .shortened)
        let title = hit.context.windowTitle ?? hit.context.domain ?? hit.context.applicationName
        return "Source, \(hit.context.applicationName), \(time), \(title)"
    }
}

private func sessionDuration(_ duration: TimeInterval) -> String {
    let seconds = max(Int(duration.rounded()), 0)
    if seconds < 60 { return "under a minute" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
}

private struct FrameInspector: View {
    private struct InspectorImageCache {
        let frameID: FrameID
        let relativePath: String
        let image: NSImage
    }

    private struct AccessibilityDetail: Identifiable {
        let id: Int
        let role: String
        let text: String
    }

    @Bindable var model: PassageModel
    let onRevisitAround: (SearchHit) -> Void
    @State private var memoryLensSelectionSourceID: FrameID?
    @State private var inspectorImageCache: InspectorImageCache?
    @State private var showsMatchProvenance = false
    @State private var showsAppProvidedText = false
    @State private var showsOCRText = false

    var body: some View {
        Group {
            if let hit = model.selectedHit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        inspectorImage(for: hit)
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 11) {
                                PassageApplicationIcon(
                                    bundleIdentifier: hit.context.bundleIdentifier,
                                    size: 34
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.context.windowTitle ?? "Untitled moment")
                                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                    Text(hit.context.applicationName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    Text(hit.capturedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                                    if let domain = hit.context.domain {
                                        Text("·")
                                        Text(domain)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.capturedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                                    if let domain = hit.context.domain {
                                        Text(domain)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            if let source = InspectorSourcePresentation.make(url: hit.context.url) {
                                inspectorSourceRow(source)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        inspectorActions(for: hit)
                        if hasActiveRecallQuery {
                            let reason = RecallMatchReason.reason(for: hit, model: model)
                            DisclosureGroup(isExpanded: $showsMatchProvenance) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(reason.explanation)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let evidence = model.visualRecallEvidenceByFrameID[hit.id],
                                       evidence.associatedFrameCount > 1 {
                                        Text("The same scene appears in \(evidence.associatedFrameCount) saved moments.")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if reason.usesImageAppearance {
                                        Text("Image comparison happened on this Mac.")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if reason.usesPersonDetail {
                                        Text("The outlined area was compared only in memory. No cropped image was saved or sent anywhere.")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.top, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                InspectorDisclosureLabel(
                                    title: "Why this matched",
                                    summary: reason.label,
                                    systemImage: reason.systemImage,
                                    accent: reason.color
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        if !selectedAccessibilityDetails.isEmpty {
                            DisclosureGroup(isExpanded: $showsAppProvidedText) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text("These labels come from visible controls in the focused window and are usually more reliable than reading pixels.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                    VStack(alignment: .leading, spacing: 7) {
                                        ForEach(selectedAccessibilityDetails) { detail in
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(detail.role)
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(PassagePalette.accent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(
                                                        PassagePalette.accent.opacity(0.08),
                                                        in: Capsule()
                                                    )
                                                Text(detail.text)
                                                    .font(.system(size: 13))
                                                    .lineSpacing(3)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .textSelection(.enabled)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    if selectedAppContextIsTruncated {
                                        Text("Passage kept this app context intentionally compact.")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.top, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                InspectorDisclosureLabel(
                                    title: "App-provided text",
                                    summary: InspectorEvidencePresentation.appProvidedTextSummary(
                                        count: selectedAccessibilityDetails.count,
                                        isTruncated: selectedAppContextIsTruncated
                                    ),
                                    systemImage: "text.viewfinder"
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        let ocrText = extractedText(for: hit)
                        DisclosureGroup(isExpanded: $showsOCRText) {
                            VStack(alignment: .leading, spacing: 8) {
                                if !model.selectedFrameTextIsImproving {
                                    Text("This text was read from pixels. Small, stylized, moving, or overlapping text can be imperfect.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if model.selectedFrameTextIsImproving {
                                    Text("Passage is rereading the saved image more carefully.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(ocrText.isEmpty ? "No readable text was found in this moment." : ocrText)
                                        .font(.system(size: 13))
                                        .foregroundStyle(ocrText.isEmpty ? .secondary : .primary)
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            InspectorDisclosureLabel(
                                title: "Text read from image",
                                summary: InspectorEvidencePresentation.ocrSummary(
                                    text: ocrText,
                                    isImproving: model.selectedFrameTextIsImproving
                                ),
                                systemImage: "text.viewfinder"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            } else if model.recallIsLoading && model.results.isEmpty {
                RecallLoadingView(queryKind: recallQueryKind)
            } else if model.results.isEmpty {
                EmptyResultsView(
                    queryKind: recallQueryKind,
                    hasFilters: model.hasRecallFilters,
                    searchMode: model.recallSearchMode,
                    visualState: model.visualUnderstandingState,
                    coverage: model.visualEmbeddingCoverage,
                    totalMomentCount: model.statistics.frameCount,
                    searchError: model.searchError
                )
            } else {
                ContentUnavailableView("Select a moment", systemImage: "rectangle.and.text.magnifyingglass", description: Text("Its saved image, source details, and visible text will appear here."))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.selectedHit?.id) { _, _ in
            inspectorImageCache = nil
            setMemoryLensSelectionVisible(false)
            collapseEvidenceDisclosures()
        }
        .onChange(of: model.mediaRevision) { _, _ in
            inspectorImageCache = nil
            setMemoryLensSelectionVisible(false)
        }
        .onChange(of: model.memoryLensCanStart) { _, canStart in
            if !canStart {
                setMemoryLensSelectionVisible(false)
            }
        }
    }

    private func inspectorSourceRow(_ source: InspectorSourcePresentation) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(source.displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(source.fullText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source \(source.fullText)")
    }

    private func inspectorActions(for hit: SearchHit) -> some View {
        ViewThatFits(in: .horizontal) {
            inspectorActionRow(for: hit, compact: false)
            inspectorActionRow(for: hit, compact: true)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorActionRow(for hit: SearchHit, compact: Bool) -> some View {
        HStack(spacing: 8) {
            openSourceButton(for: hit, compact: compact)
            contextHandoffButton(for: hit, compact: compact)
            moreActionsMenu(for: hit)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func moreActionsMenu(for hit: SearchHit) -> some View {
        Menu {
            if canOfferMemoryLensSelection {
                Button {
                    guard model.memoryLensCanStart else { return }
                    setMemoryLensSelectionVisible(true)
                } label: {
                    Label("Find this again", systemImage: "viewfinder")
                }
                Divider()
            }
            Button {
                onRevisitAround(hit)
            } label: {
                Label("Revisit around this time", systemImage: "timeline.selection")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("More actions for this remembered moment")
        .accessibilityLabel("More actions")
    }

    private var selectedAccessibilityDetails: [AccessibilityDetail] {
        guard let snapshot = selectedAccessibilitySnapshot else { return [] }
        return snapshot.nodes.prefix(20).enumerated().compactMap { offset, node in
            let text = accessibilityText(for: node)
            guard !text.isEmpty else { return nil }
            return AccessibilityDetail(
                id: offset,
                role: accessibilityRoleLabel(node.role),
                text: text
            )
        }
    }

    private var selectedAppContextIsTruncated: Bool {
        guard let snapshot = selectedAccessibilitySnapshot else { return false }
        return snapshot.isTruncated || snapshot.nodes.count > 20
    }

    private func collapseEvidenceDisclosures() {
        showsMatchProvenance = false
        showsAppProvidedText = false
        showsOCRText = false
    }

    @ViewBuilder
    private func inspectorImage(for hit: SearchHit) -> some View {
        if isSelectingMemoryLens,
           let frame = selectedRetainedFrame,
           let sourceImage = selectedCachedImage,
           frame.pixelWidth > 0,
           frame.pixelHeight > 0 {
            MemoryLensSelectionSurface(
                imageSize: CGSize(
                    width: frame.pixelWidth,
                    height: frame.pixelHeight
                ),
                onConfirm: { bounds in
                    setMemoryLensSelectionVisible(false)
                    guard model.selectedHit?.id == hit.id else { return }
                    model.findSimilarMoments(to: hit, within: bounds)
                },
                onCancel: {
                    setMemoryLensSelectionVisible(false)
                }
            ) {
                Image(nsImage: sourceImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            }
        } else {
            ZStack {
                if let sourceImage = selectedCachedImage {
                    Image(nsImage: sourceImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityHidden(true)
                } else {
                    FrameThumbnail(
                        relativePath: hit.imageRelativePath,
                        model: model,
                        contentMode: .fit,
                        missingMessage: "This image was removed by your retention settings. Its visible text remains searchable.",
                        onImageLoaded: { image in
                            cacheInspectorImage(image, for: hit)
                        }
                    )
                }
                if let region = selectedRegionEvidence {
                    VisualRegionMatchOverlay(bounds: region.bounds)
                }
            }
            .aspectRatio(selectedImageAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipped()
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        }
    }

    private var selectedRetainedFrame: FrameDocument? {
        guard let frame = model.selectedFrame,
              frame.id == model.selectedHit?.id,
              !frame.imageRelativePath.isEmpty else { return nil }
        return frame
    }

    private var selectedCachedImage: NSImage? {
        guard let cache = inspectorImageCache,
              let frame = selectedRetainedFrame,
              cache.frameID == frame.id,
              cache.relativePath == frame.imageRelativePath else { return nil }
        return cache.image
    }

    private func cacheInspectorImage(_ image: NSImage, for hit: SearchHit) {
        guard let frame = selectedRetainedFrame,
              frame.id == hit.id,
              frame.imageRelativePath == hit.imageRelativePath else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            inspectorImageCache = InspectorImageCache(
                frameID: frame.id,
                relativePath: frame.imageRelativePath,
                image: image
            )
        }
    }

    private var selectedImageAspectRatio: CGFloat {
        guard let frame = model.selectedFrame,
              frame.id == model.selectedHit?.id,
              frame.pixelWidth > 0,
              frame.pixelHeight > 0 else {
            return 16 / 10
        }
        return CGFloat(frame.pixelWidth) / CGFloat(frame.pixelHeight)
    }

    private var selectedRegionEvidence: VisualRegionRecallEvidence? {
        guard let hit = model.selectedHit,
              let frame = model.selectedFrame,
              frame.id == hit.id,
              let region = model.visualRecallEvidenceByFrameID[hit.id]?.region,
              region.sourceVisualFingerprint == frame.visualFingerprint else {
            return nil
        }
        return region
    }

    private var hasActiveRecallQuery: Bool {
        (!model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.memoryLensSelection != nil)
            && model.recallPresentationMode != .chronological
            && !model.recallResultsAreStale
    }

    private var recallQueryKind: RecallQueryKind {
        RecallQueryKind.resolve(
            queryText: model.queryText,
            hasMemoryLens: model.memoryLensSelection != nil
        )
    }

    private var isSelectingMemoryLens: Bool {
        memoryLensSelectionSourceID != nil
            && memoryLensSelectionSourceID == model.selectedHit?.id
    }

    private var canOfferMemoryLensSelection: Bool {
        model.memoryLensCanStart
            && selectedCachedImage != nil
            && !isSelectingMemoryLens
            && !(model.memoryLensSelection != nil
                && (model.recallIsLoading || model.recallResultsAreStale))
    }

    private func setMemoryLensSelectionVisible(_ isVisible: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            memoryLensSelectionSourceID = isVisible ? model.selectedHit?.id : nil
        }
    }

    private func openSourceButton(for hit: SearchHit, compact: Bool) -> some View {
        Button {
            openSource(for: hit)
        } label: {
            Label(compact ? "Open" : "Open Source", systemImage: "arrow.up.forward.square")
        }
        .buttonStyle(.borderedProminent)
        .tint(PassagePalette.accent)
        .disabled(openableSourceURL(for: hit) == nil)
        .help(openSourceHelp(for: hit))
    }

    private func contextHandoffButton(for hit: SearchHit, compact: Bool) -> some View {
        Button {
            model.prepareContextHandoff(for: hit)
        } label: {
            Label(compact ? "Hand Off…" : "Hand Off Context…", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .disabled(model.selectedFrameTextIsImproving)
        .help("Preview the exact private-safe context before copying it")
    }

    private func openableSourceURL(for hit: SearchHit) -> URL? {
        guard let url = hit.context.url,
              let scheme = url.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme) else { return nil }
        return url
    }

    private func openSource(for hit: SearchHit) {
        guard let url = openableSourceURL(for: hit) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSourceHelp(for hit: SearchHit) -> String {
        openableSourceURL(for: hit)?.absoluteString ?? "No webpage or file URL was captured"
    }

    private func extractedText(for hit: SearchHit) -> String {
        guard model.selectedFrame?.id == hit.id else { return hit.snippet }
        return model.selectedFrame?.ocrText ?? hit.snippet
    }

    private var selectedAccessibilitySnapshot: AccessibilitySnapshot? {
        guard model.selectedFrame?.id == model.selectedHit?.id else { return nil }
        return model.selectedFrame?.accessibilitySnapshot
    }

    private func accessibilityText(for node: AccessibilityNodeEvidence) -> String {
        [node.label, node.value]
            .compactMap { $0 }
            .compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
            .joined(separator: " — ")
    }

    private func accessibilityRoleLabel(_ role: String) -> String {
        switch role.lowercased() {
        case "axbutton": "Button"
        case "axcheckbox": "Checkbox"
        case "axcombobox": "Menu"
        case "axheading": "Heading"
        case "axlink": "Link"
        case "axmenuitem": "Menu item"
        case "axradiobutton": "Option"
        case "axstatictext": "Text"
        case "axtextfield", "axtextarea": "Text field"
        default:
            role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
    }
}

private struct InspectorDisclosureLabel: View {
    let title: String
    let summary: String
    let systemImage: String
    var accent: Color = .secondary

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct VisualRegionMatchOverlay: View {
    let bounds: NormalizedVisualRegionBounds

    var body: some View {
        GeometryReader { geometry in
            let frame = VisualRegionOverlayGeometry.frame(
                bounds: bounds,
                container: geometry.size
            )

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PassagePalette.mint.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PassagePalette.mint, lineWidth: 2)
                }
                .shadow(color: PassagePalette.mint.opacity(0.22), radius: 8)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum VisualRegionOverlayGeometry {
    /// Converts Vision/Core Image bottom-left unit bounds into SwiftUI's
    /// top-left container coordinates without changing the selected region.
    static func frame(
        bounds: NormalizedVisualRegionBounds,
        container: CGSize
    ) -> CGRect {
        CGRect(
            x: container.width * bounds.x,
            y: container.height * (1 - bounds.y - bounds.height),
            width: container.width * bounds.width,
            height: container.height * bounds.height
        )
    }
}
