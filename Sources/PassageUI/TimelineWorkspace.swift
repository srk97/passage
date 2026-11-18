import AppKit
import PassageCore
import SwiftUI

struct TimelineWorkspace: View {
    @Bindable var model: PassageModel
    let onOpenMoment: (SearchHit) -> Void

    @State private var fallbackSelectedID: FrameID?
    @State private var selectedDay = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var preparedInitialDay = false

    private var orderedHits: [SearchHit] {
        guard preparedInitialDay, !model.recallResultsAreStale else { return [] }
        return model.timelineHits(onDay: selectedDay, calendar: .autoupdatingCurrent)
    }

    private var selectedHit: SearchHit? {
        if let preview = model.recallTimeLensPreview {
            if preview.resolution == .resolved, preview.hit == nil {
                return nil
            }
            if let previewHit = preview.hit,
               currentScopeContains(previewHit.capturedAt) {
                return previewHit
            }
        }
        if let committedHit = model.selectedHit,
           currentScopeContains(committedHit.capturedAt) {
            return committedHit
        }
        guard let fallbackSelectedID else { return orderedHits.last }
        return orderedHits.first { $0.id == fallbackSelectedID } ?? orderedHits.last
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            Group {
                if orderedHits.isEmpty {
                    if !preparedInitialDay || model.recallIsLoading || model.recallResultsAreStale {
                        loadingState
                    } else {
                        emptyState
                    }
                } else {
                    timelineContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            prepareDayIfNeeded()
            preserveOrSelectNewest()
            loadCompleteDayIfReady()
        }
        .onDisappear {
            preparedInitialDay = false
            model.exitTimelineWorkspace()
        }
        .onChange(of: model.recallResultIDs) { _, _ in
            preserveOrSelectNewest()
        }
        .onChange(of: model.recallResultsAreStale) { _, _ in
            preserveOrSelectNewest()
        }
        .onChange(of: model.recallIsLoading) { _, isLoading in
            guard !isLoading else { return }
            loadCompleteDayIfReady()
        }
        .onChange(of: selectedDay) { _, day in
            guard preparedInitialDay else { return }
            model.cancelRecallTimeLensScrub()
            fallbackSelectedID = nil
            model.setTimelineWorkspaceDay(day)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                timelineIdentity
                Spacer(minLength: 12)
                privacyBadge
                dayControls
            }

            VStack(alignment: .leading, spacing: 10) {
                timelineIdentity
                HStack(spacing: 10) {
                    privacyBadge
                    Spacer(minLength: 8)
                    dayControls
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private var timelineIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(PassagePalette.accent)
                Text("Timeline")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            Text("Drag across saved changes. Still images, never video.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyBadge: some View {
        Label("Local & encrypted", systemImage: "lock.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PassagePalette.mint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(PassagePalette.mint.opacity(0.09), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .help("Screenshots and searchable text stay in Passage's encrypted local library")
    }

    private var dayControls: some View {
        HStack(spacing: 4) {
            Button {
                moveDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Previous day")
            .accessibilityLabel("Show previous day")

            DatePicker(
                "Timeline day",
                selection: $selectedDay,
                in: availableDayRange,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(width: 128)

            Button {
                moveDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveToNextDay)
            .help("Next day")
            .accessibilityLabel("Show next day")
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var timelineContent: some View {
        VStack(spacing: 12) {
            if let selectedHit {
                TimelineMomentPreview(
                    hit: selectedHit,
                    model: model,
                    onOpen: {
                        model.commitTimelineWorkspaceForOpeningMoment()
                        onOpenMoment(selectedHit)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let requestedAt = noResultRequestedAt {
                TimelineNoSavedMomentPreview(requestedAt: requestedAt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            MemoryCurrent(
                model: model,
                hits: orderedHits,
                displayedHit: selectedHit,
                hasEarlierMoments: model.recallHasMore,
                isLoadingEarlier: model.recallIsLoadingMore,
                loadEarlier: model.loadEarlierRecall
            )
            .frame(minHeight: 148, idealHeight: 160, maxHeight: 188)
        }
        .padding(14)
        .background {
            LinearGradient(
                colors: [PassagePalette.accent.opacity(0.025), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .overlay(alignment: .topTrailing) {
            if model.recallIsLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(18)
                    .accessibilityLabel("Loading timeline")
            }
        }
    }

    private var noResultRequestedAt: Date? {
        guard let preview = model.recallTimeLensPreview,
              preview.resolution == .resolved,
              preview.hit == nil else { return nil }
        return preview.requestedAt
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No moments on this day", systemImage: "calendar.badge.clock")
        } description: {
            Text("Choose another day, or resume remembering and use your Mac normally.")
        } actions: {
            if model.captureIntent == .paused {
                Button("Start Remembering") {
                    _ = model.startCapturing()
                }
                .buttonStyle(.borderedProminent)
                .tint(PassagePalette.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading saved moments…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading saved moments")
    }

    private var availableDayRange: ClosedRange<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let newest = calendar.startOfDay(for: model.statistics.newestCapture ?? Date())
        let oldestFallback = calendar.date(byAdding: .year, value: -1, to: newest) ?? newest
        let oldest = calendar.startOfDay(for: model.statistics.oldestCapture ?? oldestFallback)
        return min(oldest, newest)...max(oldest, newest)
    }

    private var canMoveToNextDay: Bool {
        let calendar = Calendar.autoupdatingCurrent
        let newest = calendar.startOfDay(for: model.statistics.newestCapture ?? Date())
        return selectedDay < newest
    }

    private func prepareDayIfNeeded() {
        guard !preparedInitialDay else { return }
        selectedDay = model.enterTimelineWorkspace()
        preparedInitialDay = true
    }

    private func loadCompleteDayIfReady() {
        guard preparedInitialDay,
              !model.recallIsLoading,
              !model.recallResultsAreStale else { return }
        model.loadCompleteTimelineDay()
    }

    private func moveDay(by amount: Int) {
        guard let next = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: amount,
            to: selectedDay
        ) else { return }
        selectedDay = min(max(next, availableDayRange.lowerBound), availableDayRange.upperBound)
    }

    private func preserveOrSelectNewest() {
        if let fallbackSelectedID,
           orderedHits.contains(where: { $0.id == fallbackSelectedID }) {
            return
        }
        fallbackSelectedID = orderedHits.last?.id
    }

    private func currentScopeContains(_ date: Date) -> Bool {
        let dayScope = TimelineWorkspaceScope.dayScope(for: selectedDay)
        if let startDate = dayScope.startDate, date < startDate { return false }
        if let endDate = dayScope.endDate, date >= endDate { return false }
        return true
    }
}

private struct TimelineNoSavedMomentPreview: View {
    let requestedAt: Date

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No saved moment before \(requestedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Passage only shows still moments it actually saved. Your previous selection is unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TimelineMomentPreview: View {
    let hit: SearchHit
    let model: PassageModel
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PassageApplicationIcon(
                    bundleIdentifier: hit.context.bundleIdentifier,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.context.windowTitle ?? hit.context.domain ?? hit.context.applicationName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(hit.context.applicationName)
                        Text("·")
                        Text(hit.capturedAt, format: .dateTime.hour().minute().second())
                        if let domain = hit.context.domain {
                            Text("·")
                            Text(domain).lineLimit(1)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onOpen) {
                    Label("Open details", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open this saved moment's text, source, and details")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)

            Divider().opacity(0.4)

            TimelineMediaImage(
                relativePath: preferredMediaPath,
                model: model
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(14)

            if !cleanedSnippet.isEmpty {
                Text(cleanedSnippet)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.055), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var cleanedSnippet: String {
        hit.snippet
            .replacingOccurrences(of: "‹", with: "")
            .replacingOccurrences(of: "›", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scrubbing can cross dozens of moments in a second. Keep that direct
    /// manipulation path light by decoding the small preview, then promote to
    /// the retained full-resolution image only after the handle settles.
    private var preferredMediaPath: String {
        if model.recallTimeLensIsScrubbing
            || model.recallTimeLensPreview?.isResolving == true {
            return hit.thumbnailRelativePath ?? hit.imageRelativePath
        }
        return hit.imageRelativePath
    }
}

private struct TimelineMediaImage: View {
    let relativePath: String
    let model: PassageModel

    @State private var phase: Phase = .loading
    @State private var isLoading = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        case loading
        case image(NSImage)
        case missing
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.055))

            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading saved moment")
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(1)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            case .missing:
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 24, weight: .light))
                    Text("The image is no longer stored. This moment's text is still searchable.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .foregroundStyle(.secondary)
                .padding()
                .accessibilityElement(children: .combine)
            }

            if isLoading, case .image = phase {
                ProgressView()
                    .controlSize(.small)
                    .padding(7)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Loading the next saved moment")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: relativePath) {
            isLoading = true
            if case .image = phase {
                // Keep the previous preview visible while the next small image
                // arrives. Rapid scrubbing should never flash an empty card.
            } else {
                phase = .loading
            }
            let data = await model.mediaData(relativePath: relativePath)
            let nextPhase: Phase = if let data, let image = NSImage(data: data) {
                .image(image)
            } else {
                .missing
            }
            if reduceMotion {
                phase = nextPhase
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    phase = nextPhase
                }
            }
            isLoading = false
        }
    }
}

struct TimelineScrubPresentation: Equatable {
    enum Status: Equatable {
        case idle
        case resolving
        case resolved
        case noResult
        case failed
    }

    let status: Status
    let requestedDate: Date?
    /// A saved moment proven to answer this exact requested date.
    let resolvedDate: Date?
    /// The previously shown moment retained only to avoid a blank preview.
    let lastShownDate: Date?
    let applicationName: String?
    let bundleIdentifier: String?

    var puckDate: Date? {
        resolvedDate ?? lastShownDate
    }

    var gap: TimeInterval? {
        guard status == .resolved,
              let requestedDate,
              let resolvedDate else { return nil }
        return max(requestedDate.timeIntervalSince(resolvedDate), 0)
    }

    var isExact: Bool {
        guard let gap else { return false }
        return gap < 0.5
    }

    var gapDescription: String? {
        guard let gap, !isExact else { return nil }
        return TimelineProjection.gapDescription(for: gap)
    }

    var accessibilityValue: String? {
        guard let requestedDate else { return nil }
        let chosen = requestedDate.formatted(date: .omitted, time: .standard)
        switch status {
        case .idle:
            return nil
        case .resolving:
            if let lastShownDate {
                let previous = lastShownDate.formatted(date: .omitted, time: .standard)
                return "Chosen \(chosen). Finding the latest saved moment. The previous memory at \(previous) remains visible."
            }
            return "Chosen \(chosen). Finding the latest saved moment."
        case .resolved:
            guard let resolvedDate else { return nil }
            let saved = resolvedDate.formatted(date: .omitted, time: .standard)
            let app = applicationName.map { ", \($0)" } ?? ""
            if let gapDescription {
                return "Chosen \(chosen). Showing the latest saved moment\(app) at \(saved), \(gapDescription)."
            }
            return "Chosen \(chosen). Showing the latest saved moment\(app) at \(saved)."
        case .noResult:
            return "Chosen \(chosen). No saved moment exists at or before this time."
        case .failed:
            if let lastShownDate {
                let previous = lastShownDate.formatted(date: .omitted, time: .standard)
                return "Chosen \(chosen). Passage could not check this time. The previous memory at \(previous) remains visible."
            }
            return "Chosen \(chosen). Passage could not check this time."
        }
    }
}

private struct MemoryCurrent: View {
    @Bindable var model: PassageModel
    let hits: [SearchHit]
    let displayedHit: SearchHit?
    let hasEarlierMoments: Bool
    let isLoadingEarlier: Bool
    let loadEarlier: () -> Void

    @State private var isScrubbing = false
    @State private var activeBounds: RecallTimeLensBounds?
    @State private var requestedDate: Date?
    @State private var browsesWholeDay = false
    @State private var activeRailHits: [SearchHit]?
    @FocusState private var isFocused: Bool

    private var focusedActivityRange: Range<Int> {
        TimelineProjection.activityRange(
            in: hits,
            around: displayedHit?.id
        )
    }

    private var railHits: [SearchHit] {
        guard !browsesWholeDay else { return hits }
        return Array(hits[focusedActivityRange])
    }

    private var renderedRailHits: [SearchHit] {
        activeRailHits ?? railHits
    }

    private var hiddenLoadedMomentCount: Int {
        max(hits.count - railHits.count, 0)
    }

    private var focusedHiddenMomentCount: Int {
        max(hits.count - focusedActivityRange.count, 0)
    }

    private var loadedApplicationCount: Int {
        Set(hits.map { hit in
            hit.context.bundleIdentifier ?? hit.context.applicationName
        }).count
    }

    private var hasHiddenBeforeRail: Bool {
        hasEarlierMoments || (!browsesWholeDay && focusedActivityRange.lowerBound > 0)
    }

    private var hasHiddenAfterRail: Bool {
        !browsesWholeDay && focusedActivityRange.upperBound < hits.count
    }

    /// Focused mode gives loaded moments an honest, legible scale. Whole-day
    /// mode deliberately uses the complete retained-day range so any time can
    /// be selected; its copy separately discloses that earlier moments may
    /// still be loading rather than presenting unpainted time as empty.
    private var loadedBounds: RecallTimeLensBounds? {
        let projected = TimelineProjection.focusedBounds(
            for: railHits,
            within: model.recallTimeLensBounds,
            hasUnloadedEarlier: hasEarlierMoments || hiddenLoadedMomentCount > 0
        )
        let focusedBounds = TimelineProjection.clampBounds(
            projected,
            to: railHits,
            hiddenBefore: hasHiddenBeforeRail,
            hiddenAfter: hasHiddenAfterRail
        )
        return TimelineProjection.navigationBounds(
            focusedBounds: focusedBounds,
            completeBounds: model.recallTimeLensBounds,
            browsesWholeDay: browsesWholeDay
        )
    }

    private var effectiveBounds: RecallTimeLensBounds? {
        activeBounds ?? loadedBounds ?? model.recallTimeLensBounds
    }

    private var scrubPresentation: TimelineScrubPresentation {
        TimelineProjection.scrubPresentation(
            displayedHit: displayedHit,
            requestedDate: requestedDate,
            preview: model.recallTimeLensPreview,
            newestDate: effectiveBounds?.newest,
            isScrubbing: isScrubbing && model.recallTimeLensIsScrubbing
        )
    }

    private var centerDate: Date? {
        scrubPresentation.requestedDate ?? scrubPresentation.puckDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineToolbar

            HStack {
                Text(effectiveBounds?.oldest.formatted(date: .omitted, time: .shortened) ?? "")
                Spacer()
                if let centerDate {
                    Text(centerDate, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text(effectiveBounds?.newest.formatted(date: .omitted, time: .shortened) ?? "")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)

            TimelineRail(
                hits: renderedRailHits,
                bounds: effectiveBounds,
                presentation: scrubPresentation,
                showsUnloadedEarlierRegion: browsesWholeDay && hasEarlierMoments,
                isScrubbing: $isScrubbing,
                onScrub: scrub(toFraction:),
                onCommit: commit(atFraction:)
            )
            .frame(minHeight: 52)
            .focused($isFocused)
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .left: moveSelection(by: -1)
                case .right: moveSelection(by: 1)
                default: break
                }
            }
            .onExitCommand(perform: cancelScrub)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory timeline")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(timelineAccessibilityHint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: moveSelection(by: 1)
                case .decrement: moveSelection(by: -1)
                @unknown default: break
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isFocused ? PassagePalette.accent.opacity(0.5) : .primary.opacity(0.07),
                    lineWidth: isFocused ? 1 : 0.5
                )
        }
        .onChange(of: model.recallScope) { _, _ in
            activeBounds = nil
            requestedDate = nil
            isScrubbing = false
            browsesWholeDay = false
            activeRailHits = nil
        }
        .onChange(of: model.selectedHit?.id) { _, _ in
            guard !isScrubbing else { return }
            requestedDate = nil
        }
        .onChange(of: model.recallTimeLensIsScrubbing) { _, modelIsScrubbing in
            if !modelIsScrubbing { isScrubbing = false }
            settleFrozenRailIfIdle()
        }
        .onChange(of: model.recallTimeLensPreview?.isResolving) { _, _ in
            settleFrozenRailIfIdle()
        }
    }

    private var timelineToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                railTitle
                railDescriptionLabel
                Spacer(minLength: 8)
                railActions
                loadedCount
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    railTitle
                    Spacer(minLength: 8)
                    loadedCount
                }
                HStack(spacing: 8) {
                    railDescriptionLabel
                    Spacer(minLength: 8)
                    railActions
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    railTitle
                    Spacer(minLength: 8)
                    loadedCount
                }
                railDescriptionLabel
                railActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var railTitle: some View {
        Label("Saved activity", systemImage: "dot.scope")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var railDescriptionLabel: some View {
        Text(railDescription)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var railActions: some View {
        HStack(spacing: 8) {
            Picker(
                "Timeline range",
                selection: Binding(
                    get: { browsesWholeDay },
                    set: { setWholeDayBrowsing($0) }
                )
            ) {
                Text("Activity").tag(false)
                Text("Day").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 126)
            .help(
                browsesWholeDay
                    ? "Showing the whole retained day"
                    : "Showing the continuous activity around this moment"
            )

            if isLoadingEarlier {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Loading day…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if hasEarlierMoments {
                Button("Load rest", action: loadEarlier)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
                    .help("Retry loading the rest of this day")
            }
        }
    }

    private var loadedCount: some View {
        Text(loadedCountLabel)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var railDescription: String {
        if browsesWholeDay {
            if isLoadingEarlier { return "Whole day · filling in saved activity…" }
            return hasEarlierMoments
                ? "Whole day · some earlier activity is still loading"
                : "Whole day · drag to any time"
        }
        if hiddenLoadedMomentCount > 0 {
            let noun = hiddenLoadedMomentCount == 1 ? "moment" : "moments"
            return "Continuous activity · \(hiddenLoadedMomentCount) other \(noun) today"
        }
        return hasEarlierMoments
            ? "Continuous activity · the rest of today is loading"
            : "Drag to revisit saved moments"
    }

    private var loadedCountLabel: String {
        let noun = hits.count == 1 ? "moment" : "moments"
        let appNoun = loadedApplicationCount == 1 ? "app" : "apps"
        let loadedState = "\(hits.count) \(noun) · \(loadedApplicationCount) \(appNoun)"
        guard !browsesWholeDay, hiddenLoadedMomentCount > 0 else {
            return loadedState
        }
        return "\(railHits.count) shown · \(loadedState)"
    }

    private var timelineAccessibilityHint: String {
        if browsesWholeDay {
            return "Drag, or use left and right arrows, to find the latest saved moment at or before a time in the retained day"
        }
        if hasEarlierMoments || focusedHiddenMomentCount > 0 {
            return "Drag within this activity, or choose Browse whole day to find the latest saved moment at or before a chosen time"
        }
        return "Drag, or use left and right arrows, to preview saved moments"
    }

    private var accessibilityValue: String {
        if let scrubValue = scrubPresentation.accessibilityValue {
            return scrubValue
        }
        guard let hit = displayedHit else { return "No saved moments" }
        let title = hit.context.windowTitle ?? hit.context.domain ?? "Untitled moment"
        let ordered = renderedRailHits
        let position = ordered.firstIndex(where: { $0.id == hit.id }).map { $0 + 1 }
        let ordinal = position.map { "\($0) of \(ordered.count), " } ?? ""
        return "\(ordinal)\(hit.capturedAt.formatted(date: .abbreviated, time: .standard)), \(hit.context.applicationName), \(title)"
    }

    private func beginScrubIfNeeded() -> RecallTimeLensBounds? {
        if let activeBounds,
           model.recallTimeLensIsScrubbing
            || model.recallTimeLensPreview?.isResolving == true {
            return activeBounds
        }
        // A completed terminal outcome deliberately keeps the old coordinate
        // system visible. Pointer-down begins a fresh session and dismisses it.
        activeBounds = nil
        activeRailHits = nil
        guard let completeBounds = model.beginRecallTimeLensScrub() else { return nil }
        let bounds = loadedBounds ?? completeBounds
        activeBounds = bounds
        activeRailHits = railHits
        if requestedDate == nil {
            requestedDate = bounds.clamped(displayedHit?.capturedAt ?? bounds.newest)
        }
        return bounds
    }

    private func scrub(toFraction fraction: Double) {
        guard let bounds = beginScrubIfNeeded() else { return }
        let target = bounds.date(at: fraction)
        requestedDate = target
        model.previewRecallTimeLens(at: target)
    }

    private func commit(atFraction fraction: Double) {
        guard let bounds = beginScrubIfNeeded() else {
            isScrubbing = false
            return
        }
        let target = bounds.date(at: fraction)
        requestedDate = target
        model.commitRecallTimeLens(at: target)
        // The model owns the requested release time while it resolves. Keeping
        // a second local copy can outlive a very fast drag and leave the rail
        // between saved moments after the preview has already settled.
        requestedDate = nil
        isScrubbing = false
    }

    private func moveSelection(by offset: Int) {
        let ordered = renderedRailHits
        guard !ordered.isEmpty, beginScrubIfNeeded() != nil else { return }
        let currentIndex = displayedHit.flatMap { hit in
            ordered.firstIndex(where: { $0.id == hit.id })
        } ?? ordered.indices.last ?? 0
        let targetIndex = min(max(currentIndex + offset, ordered.startIndex), ordered.index(before: ordered.endIndex))
        let target = ordered[targetIndex].capturedAt
        requestedDate = target
        model.commitRecallTimeLens(at: target)
        requestedDate = nil
    }

    private func cancelScrub() {
        if activeBounds != nil
            || model.recallTimeLensIsScrubbing
            || model.recallTimeLensPreview?.isResolving == true {
            model.cancelRecallTimeLensScrub()
        }
        activeBounds = nil
        activeRailHits = nil
        requestedDate = nil
        isScrubbing = false
    }

    private func setWholeDayBrowsing(_ visible: Bool) {
        // An accessibility press on the segmented control can be delivered
        // while AppKit is mid display-cycle flush. Mutating SwiftUI state
        // synchronously there makes NSHostingView request a constraint update
        // inside the flush, which AppKit treats as an uncaught exception and
        // crashes. Deferring one runloop turn keeps the mutation outside the
        // flush for every delivery path; a pointer click behaves identically.
        DispatchQueue.main.async {
            cancelScrub()
            browsesWholeDay = visible
        }
    }

    private func settleFrozenRailIfIdle() {
        // Keep the chosen-time versus saved-time outcome spatially stable until
        // the next gesture, day/scope change, or explicit Escape dismissal.
        guard model.recallTimeLensPreview == nil else { return }
        guard !TimelineProjection.shouldRetainFrozenRail(
            isScrubbing: model.recallTimeLensIsScrubbing,
            isResolving: model.recallTimeLensPreview?.isResolving == true
        ) else { return }
        activeBounds = nil
        activeRailHits = nil
        requestedDate = nil
    }
}

private struct TimelineRail: View {
    let hits: [SearchHit]
    let bounds: RecallTimeLensBounds?
    let presentation: TimelineScrubPresentation
    let showsUnloadedEarlierRegion: Bool
    @Binding var isScrubbing: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    private func timelineFraction(for date: Date) -> Double {
        TimelineProjection.cursorFraction(for: date, in: hits, bounds: bounds)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let horizontalInset = min(12.0, width / 2)
            let contentWidth = max(width - horizontalInset * 2, 1)
            let railY = max(geometry.size.height - 16, geometry.size.height / 2)
            let markerIndices = TimelineProjection.spacedTransitionIndices(
                in: hits,
                bounds: bounds,
                width: Double(contentWidth)
            )
            let activityLayout = TimelineProjection.railActivityLayout(in: hits)
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let y = max(size.height - 16, size.height / 2)
                    let railStart = horizontalInset
                    let railEnd = max(size.width - horizontalInset, horizontalInset)

                    if showsUnloadedEarlierRegion,
                       let firstLoaded = hits.first.map({ hitFraction(for: $0) }) {
                        let unloadedEnd = railStart + firstLoaded * contentWidth
                        if unloadedEnd > railStart {
                            let region = CGRect(
                                x: railStart,
                                y: y - 8,
                                width: unloadedEnd - railStart,
                                height: 16
                            )
                            context.fill(
                                Path(roundedRect: region, cornerRadius: 4),
                                with: .color(.secondary.opacity(0.055))
                            )
                            var stripeX = region.minX - region.height
                            while stripeX < region.maxX {
                                let unclippedEnd = stripeX + region.height
                                let startX = max(stripeX, region.minX)
                                let endX = min(unclippedEnd, region.maxX)
                                let startY = region.maxY - (startX - stripeX)
                                let endY = region.minY + (unclippedEnd - endX)
                                var stripe = Path()
                                stripe.move(to: CGPoint(x: startX, y: startY))
                                stripe.addLine(to: CGPoint(x: endX, y: endY))
                                context.stroke(
                                    stripe,
                                    with: .color(.secondary.opacity(0.12)),
                                    style: StrokeStyle(lineWidth: 1)
                                )
                                stripeX += 7
                            }
                        }
                    }

                    var baseline = Path()
                    baseline.move(to: CGPoint(x: railStart, y: y))
                    baseline.addLine(to: CGPoint(x: railEnd, y: y))
                    context.stroke(
                        baseline,
                        with: .color(.secondary.opacity(0.18)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )

                    for startIndex in activityLayout.segmentStartIndices {
                        let x1 = railPosition(
                            forFraction: hitFraction(at: startIndex),
                            inset: horizontalInset,
                            contentWidth: contentWidth
                        )
                        let x2 = railPosition(
                            forFraction: hitFraction(at: startIndex + 1),
                            inset: horizontalInset,
                            contentWidth: contentWidth
                        )
                        var segment = Path()
                        segment.move(to: CGPoint(x: x1, y: y))
                        segment.addLine(to: CGPoint(x: x2, y: y))
                        context.stroke(
                            segment,
                            with: .color(TimelineAppColor.color(for: hits[startIndex].context)),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                    }

                    for index in activityLayout.isolatedHitIndices {
                        let x = railPosition(
                            forFraction: hitFraction(at: index),
                            inset: horizontalInset,
                            contentWidth: contentWidth
                        )
                        let dot = Path(ellipseIn: CGRect(
                            x: x - 3.5,
                            y: y - 3.5,
                            width: 7,
                            height: 7
                        ))
                        context.fill(
                            dot,
                            with: .color(TimelineAppColor.color(for: hits[index].context))
                        )
                    }
                }

                ForEach(markerIndices, id: \.self) { index in
                    PassageApplicationIcon(
                        bundleIdentifier: hits[index].context.bundleIdentifier,
                        size: 15
                    )
                    .padding(3)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(.primary.opacity(0.09), lineWidth: 0.5) }
                    .opacity(presentation.requestedDate == nil ? 1 : 0.62)
                    .position(
                        x: markerPosition(at: index, width: width),
                        y: max(railY - 16, 10)
                    )
                    .accessibilityHidden(true)
                }

                if let requestedDate = presentation.requestedDate {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.primary.opacity(0.72))
                        .frame(width: 2, height: 30)
                        .overlay(alignment: .top) {
                            Circle()
                                .fill(Color.primary.opacity(0.82))
                                .frame(width: 6, height: 6)
                                .offset(y: -2)
                        }
                        .position(
                            x: railPosition(
                                forFraction: timelineFraction(for: requestedDate),
                                inset: horizontalInset,
                                contentWidth: contentWidth
                            ),
                            y: railY
                        )
                        .accessibilityHidden(true)
                }

                if let puckDate = presentation.puckDate {
                    let isCurrentResolution = presentation.status == .idle
                        || presentation.status == .resolved
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle().stroke(
                                isCurrentResolution
                                    ? PassagePalette.accent
                                    : Color.secondary.opacity(0.55),
                                lineWidth: isCurrentResolution ? 3 : 2
                            )
                        }
                        .overlay {
                            if isCurrentResolution {
                                Circle()
                                    .fill(PassagePalette.accent)
                                    .frame(width: 3, height: 3)
                            }
                        }
                        .shadow(
                            color: isCurrentResolution
                                ? PassagePalette.accent.opacity(0.22)
                                : .clear,
                            radius: 5
                        )
                        .position(
                            x: railPosition(
                                forFraction: timelineFraction(for: puckDate),
                                inset: horizontalInset,
                                contentWidth: contentWidth
                            ),
                            y: railY
                        )
                        .accessibilityHidden(true)
                }

                if let requestedDate = presentation.requestedDate {
                    let bubbleWidth = min(max(width * 0.52, 176), min(width, 330))
                    let requestedFraction = timelineFraction(for: requestedDate)
                    TimelineScrubBubble(presentation: presentation)
                        .frame(width: bubbleWidth)
                        .position(
                            x: TimelineProjection.bubbleCenter(
                                requestedFraction: requestedFraction,
                                railWidth: width,
                                bubbleWidth: bubbleWidth
                            ),
                            y: 14
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        onScrub(fraction(
                            at: value.location.x,
                            inset: horizontalInset,
                            contentWidth: contentWidth
                        ))
                    }
                    .onEnded { value in
                        onCommit(fraction(
                            at: value.location.x,
                            inset: horizontalInset,
                            contentWidth: contentWidth
                        ))
                        isScrubbing = false
                    }
            )
        }
    }

    private func fraction(at x: CGFloat, inset: CGFloat, contentWidth: CGFloat) -> Double {
        Double(min(max((x - inset) / max(contentWidth, 1), 0), 1))
    }

    private func hitFraction(at index: Int) -> Double {
        TimelineProjection.railFraction(forHitAt: index, in: hits, bounds: bounds)
    }

    private func markerPosition(at index: Int, width: CGFloat) -> CGFloat {
        let inset = min(12.0, width / 2)
        return railPosition(
            forFraction: hitFraction(at: index),
            inset: inset,
            contentWidth: max(width - inset * 2, 1)
        )
    }

    private func hitFraction(for hit: SearchHit) -> Double {
        guard let index = hits.firstIndex(where: { $0.id == hit.id }) else { return 0 }
        return hitFraction(at: index)
    }

    private func railPosition(
        forFraction fraction: Double,
        inset: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat {
        inset + CGFloat(min(max(fraction, 0), 1)) * contentWidth
    }
}

private struct TimelineScrubBubble: View {
    let presentation: TimelineScrubPresentation

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 27, maxHeight: 27, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.primary.opacity(0.09), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 7, y: 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.status {
        case .resolving:
            ProgressView()
                .controlSize(.mini)
        case .resolved:
            PassageApplicationIcon(
                bundleIdentifier: presentation.bundleIdentifier,
                size: 13
            )
        case .noResult:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var message: String {
        let chosen = presentation.requestedDate?
            .formatted(date: .omitted, time: .shortened) ?? "Chosen time"
        switch presentation.status {
        case .idle:
            return chosen
        case .resolving:
            return "\(chosen) · Finding saved moment…"
        case .resolved:
            let saved = presentation.resolvedDate?
                .formatted(date: .omitted, time: .shortened) ?? chosen
            let app = presentation.applicationName.map { " · \($0)" } ?? ""
            let gap = presentation.gapDescription.map { " · \($0)" } ?? ""
            return "Showing \(saved)\(app)\(gap)"
        case .noResult:
            return "No saved moment before \(chosen)"
        case .failed:
            return "Couldn’t check \(chosen)"
        }
    }
}

struct TimelineProjection {
    /// Automatic focus and the painted rail must agree about what constitutes
    /// one continuous activity span. Otherwise sparse breadcrumb captures can
    /// hold hours open while the useful activity collapses into a tiny tail.
    static let maximumContinuousInterval: TimeInterval = 2 * 60

    struct RailActivityLayout: Equatable {
        let segmentStartIndices: [Int]
        let isolatedHitIndices: [Int]
    }

    /// Converts saved moments into paint instructions without inventing a
    /// duration after the final hit. Every segment corresponds to one real,
    /// positive-duration interval between adjacent hits. A hit with no such
    /// neighbor is represented by a point, including a single-hit timeline.
    static func railActivityLayout(
        in hits: [SearchHit],
        maximumGap: TimeInterval = maximumContinuousInterval
    ) -> RailActivityLayout {
        guard hits.count > 1 else {
            return RailActivityLayout(
                segmentStartIndices: [],
                isolatedHitIndices: hits.isEmpty ? [] : [0]
            )
        }

        let gap = max(maximumGap, 0)
        var segmentStartIndices: [Int] = []
        var connectedIndices = Set<Int>()
        for startIndex in hits.indices.dropLast() {
            let interval = hits[startIndex + 1].capturedAt.timeIntervalSince(
                hits[startIndex].capturedAt
            )
            guard interval > 0, interval <= gap else { continue }
            segmentStartIndices.append(startIndex)
            connectedIndices.insert(startIndex)
            connectedIndices.insert(startIndex + 1)
        }
        return RailActivityLayout(
            segmentStartIndices: segmentStartIndices,
            isolatedHitIndices: hits.indices.filter { !connectedIndices.contains($0) }
        )
    }

    static func shouldRetainFrozenRail(isScrubbing: Bool, isResolving: Bool) -> Bool {
        isScrubbing || isResolving
    }

    static func navigationBounds(
        focusedBounds: RecallTimeLensBounds?,
        completeBounds: RecallTimeLensBounds?,
        browsesWholeDay: Bool
    ) -> RecallTimeLensBounds? {
        browsesWholeDay
            ? (completeBounds ?? focusedBounds)
            : (focusedBounds ?? completeBounds)
    }

    static func railFraction(
        forHitAt index: Int,
        in hits: [SearchHit],
        bounds: RecallTimeLensBounds?
    ) -> Double {
        guard !hits.isEmpty else { return 0 }
        if hits.count == 1 { return 0.5 }
        let boundedIndex = min(max(index, 0), hits.count - 1)
        if let bounds {
            return bounds.fraction(for: hits[boundedIndex].capturedAt)
        }
        return fraction(forIndex: boundedIndex, in: hits)
    }

    /// Cursor time uses real temporal bounds whenever they exist. In
    /// particular, one loaded moment on a whole-day rail must not force every
    /// requested time to the center merely because only one marker is painted.
    static func cursorFraction(
        for date: Date,
        in hits: [SearchHit],
        bounds: RecallTimeLensBounds?
    ) -> Double {
        if let bounds {
            return bounds.duration > 0 ? bounds.fraction(for: date) : 0.5
        }
        guard let index = hits.firstIndex(where: { $0.capturedAt == date }) else {
            return hits.count == 1 ? 0.5 : 1
        }
        return fraction(forIndex: index, in: hits)
    }

    static func hits(
        _ hits: [SearchHit],
        onDay day: Date,
        calendar: Calendar
    ) -> [SearchHit] {
        let scope = TimelineWorkspaceScope.dayScope(for: day, calendar: calendar)
        return ordered(hits.filter { hit in
            if let start = scope.startDate, hit.capturedAt < start { return false }
            if let end = scope.endDate, hit.capturedAt >= end { return false }
            return true
        })
    }

    /// Timeline starts with the continuous activity span containing the chosen
    /// moment. A lone old outlier should not compress dozens of recent moments
    /// into a colored tail; the user can explicitly expand to the full day.
    static func activityRange(
        in orderedHits: [SearchHit],
        around anchorID: FrameID?,
        maximumGap: TimeInterval = maximumContinuousInterval
    ) -> Range<Int> {
        guard !orderedHits.isEmpty else { return 0..<0 }
        let anchor = anchorID.flatMap { id in
            orderedHits.firstIndex(where: { $0.id == id })
        } ?? (orderedHits.count - 1)
        let gap = max(maximumGap, 0)
        var lower = anchor
        while lower > 0,
              orderedHits[lower].capturedAt.timeIntervalSince(
                orderedHits[lower - 1].capturedAt
              ) <= gap {
            lower -= 1
        }
        var upper = anchor
        while upper + 1 < orderedHits.count,
              orderedHits[upper + 1].capturedAt.timeIntervalSince(
                orderedHits[upper].capturedAt
              ) <= gap {
            upper += 1
        }
        return lower..<(upper + 1)
    }

    /// Padding is useful at a true edge, but never where it exposes time owned
    /// by a hidden activity span. Time Lens seeks at-or-before the pointer, so
    /// these clamps keep a hidden memory from replacing the visible session.
    static func clampBounds(
        _ bounds: RecallTimeLensBounds?,
        to visibleHits: [SearchHit],
        hiddenBefore: Bool,
        hiddenAfter: Bool
    ) -> RecallTimeLensBounds? {
        guard let bounds,
              let first = visibleHits.first?.capturedAt,
              let last = visibleHits.last?.capturedAt else { return bounds }
        let oldest = hiddenBefore ? max(bounds.oldest, first) : bounds.oldest
        let newest = hiddenAfter ? min(bounds.newest, last) : bounds.newest
        return RecallTimeLensBounds(oldest: oldest, newest: max(oldest, newest))
    }

    /// Produces an honest, legible scale for the moments currently drawn.
    /// A little temporal breathing room keeps the first and last moments off
    /// the hard edges. If the loaded window already covers most of the retained
    /// scope, the complete bounds remain stable instead of needlessly zooming.
    static func focusedBounds(
        for hits: [SearchHit],
        within completeBounds: RecallTimeLensBounds?,
        hasUnloadedEarlier: Bool = false
    ) -> RecallTimeLensBounds? {
        let orderedHits = ordered(hits)
        guard let first = orderedHits.first?.capturedAt,
              let last = orderedHits.last?.capturedAt else {
            return completeBounds
        }
        let rawDuration = max(last.timeIntervalSince(first), 0)
        let usefulDuration = max(rawDuration, 60)
        let padding = min(max(usefulDuration * 0.06, 30), 5 * 60)
        var oldest = first.addingTimeInterval(-padding)
        var newest = last.addingTimeInterval(padding)

        let compatibleCompleteBounds = completeBounds.flatMap { bounds in
            bounds.oldest <= first && bounds.newest >= last ? bounds : nil
        }
        if let completeBounds = compatibleCompleteBounds {
            if !hasUnloadedEarlier,
               completeBounds.duration <= (newest.timeIntervalSince(oldest) * 1.25) {
                return completeBounds
            }
            oldest = max(oldest, completeBounds.oldest)
            newest = min(newest, completeBounds.newest)
        }
        guard oldest <= newest else { return compatibleCompleteBounds }
        return RecallTimeLensBounds(oldest: oldest, newest: newest)
            ?? compatibleCompleteBounds
    }

    static func markerPosition(
        fraction: Double,
        width: Double,
        edgeInset: Double = 12
    ) -> Double {
        guard width.isFinite, width > 0 else { return 0 }
        let inset = min(max(edgeInset, 0), width / 2)
        return min(max(min(max(fraction, 0), 1) * width, inset), width - inset)
    }

    /// Keeps transition icons useful at any window width. The prior fixed
    /// count allowed many icons to occupy the same few pixels when activity was
    /// temporally clustered, and positioned their centers outside the rail.
    static func spacedTransitionIndices(
        in hits: [SearchHit],
        bounds: RecallTimeLensBounds?,
        width: Double,
        minimumSeparation: Double = 28
    ) -> [Int] {
        guard !hits.isEmpty, width.isFinite, width > 0 else { return [] }
        let transitions = hits.indices.filter { index in
            index == 0
                || applicationIdentity(for: hits[index].context)
                    != applicationIdentity(for: hits[index - 1].context)
        }
        guard transitions.count > 1 else { return transitions }

        func fraction(at index: Int) -> Double {
            if let bounds { return bounds.fraction(for: hits[index].capturedAt) }
            return Self.fraction(forIndex: index, in: hits)
        }


        func position(at index: Int) -> Double {
            markerPosition(fraction: fraction(at: index), width: width)
        }

        let separation = max(minimumSeparation, 1)
        var result = [transitions[0]]
        var lastX = position(at: transitions[0])
        for index in transitions.dropFirst().dropLast() {
            let x = position(at: index)
            if x - lastX >= separation {
                result.append(index)
                lastX = x
            }
        }

        if let last = transitions.last, last != result.last {
            let lastPosition = position(at: last)
            if lastPosition - lastX >= separation {
                result.append(last)
            } else {
                // When the available width cannot fit both candidates, keep
                // the newest app transition. Replacing the most recently
                // accepted icon cannot reduce spacing to any earlier icon.
                result[result.count - 1] = last
            }
        }
        return result
    }

    static func scrubPresentation(
        displayedHit: SearchHit?,
        requestedDate: Date?,
        preview: RecallTimeLensPreview?,
        newestDate: Date?,
        isScrubbing: Bool
    ) -> TimelineScrubPresentation {
        let hasActiveRequest = isScrubbing || requestedDate != nil || preview != nil
        guard hasActiveRequest else {
            return TimelineScrubPresentation(
                status: .idle,
                requestedDate: nil,
                resolvedDate: displayedHit?.capturedAt ?? newestDate,
                lastShownDate: nil,
                applicationName: displayedHit?.context.applicationName,
                bundleIdentifier: displayedHit?.context.bundleIdentifier
            )
        }

        let target = requestedDate ?? preview?.requestedAt
        guard let target else {
            return TimelineScrubPresentation(
                status: .idle,
                requestedDate: nil,
                resolvedDate: displayedHit?.capturedAt ?? newestDate,
                lastShownDate: nil,
                applicationName: displayedHit?.context.applicationName,
                bundleIdentifier: displayedHit?.context.bundleIdentifier
            )
        }

        let retainedDate = preview?.hit?.capturedAt ?? displayedHit?.capturedAt
        // Local pointer movement is allowed to outrun a throttled preview. A
        // result for an older target is retained visually, never promoted to
        // the resolved puck for this newer request.
        guard let preview, preview.requestedAt == target else {
            return TimelineScrubPresentation(
                status: .resolving,
                requestedDate: target,
                resolvedDate: nil,
                lastShownDate: retainedDate,
                applicationName: nil,
                bundleIdentifier: nil
            )
        }

        switch preview.resolution {
        case .resolving:
            return TimelineScrubPresentation(
                status: .resolving,
                requestedDate: target,
                resolvedDate: nil,
                lastShownDate: retainedDate,
                applicationName: nil,
                bundleIdentifier: nil
            )
        case .resolved:
            guard let hit = preview.resolvedHit else {
                return TimelineScrubPresentation(
                    status: .noResult,
                    requestedDate: target,
                    resolvedDate: nil,
                    lastShownDate: nil,
                    applicationName: nil,
                    bundleIdentifier: nil
                )
            }
            // The Time Lens contract is at-or-before. Fail closed if a future
            // repository ever violates that invariant.
            guard hit.capturedAt <= target else {
                return TimelineScrubPresentation(
                    status: .failed,
                    requestedDate: target,
                    resolvedDate: nil,
                    lastShownDate: retainedDate,
                    applicationName: nil,
                    bundleIdentifier: nil
                )
            }
            return TimelineScrubPresentation(
                status: .resolved,
                requestedDate: target,
                resolvedDate: hit.capturedAt,
                lastShownDate: nil,
                applicationName: hit.context.applicationName,
                bundleIdentifier: hit.context.bundleIdentifier
            )
        case .failed:
            return TimelineScrubPresentation(
                status: .failed,
                requestedDate: target,
                resolvedDate: nil,
                lastShownDate: retainedDate,
                applicationName: nil,
                bundleIdentifier: nil
            )
        }
    }

    static func gapDescription(for interval: TimeInterval) -> String? {
        guard interval.isFinite, interval >= 0.5 else { return nil }
        if interval < 60 {
            let seconds = max(Int(interval.rounded()), 1)
            return "\(seconds) sec earlier"
        }
        if interval < 60 * 60 {
            let minutes = max(Int((interval / 60).rounded()), 1)
            return "\(minutes) min earlier"
        }
        let hours = Int(interval / (60 * 60))
        let minutes = Int((interval.truncatingRemainder(dividingBy: 60 * 60)) / 60)
        if minutes == 0 { return "\(hours) hr earlier" }
        return "\(hours) hr \(minutes) min earlier"
    }

    static func bubbleCenter(
        requestedFraction: Double,
        railWidth: CGFloat,
        bubbleWidth: CGFloat,
        railInset: CGFloat = 12,
        edgePadding: CGFloat = 4
    ) -> CGFloat {
        guard railWidth.isFinite, railWidth > 0 else { return 0 }
        let inset = min(max(railInset, 0), railWidth / 2)
        let contentWidth = max(railWidth - inset * 2, 0)
        let fraction = min(max(requestedFraction.isFinite ? requestedFraction : 0, 0), 1)
        let anchor = inset + CGFloat(fraction) * contentWidth
        let halfBubble = min(max(bubbleWidth, 0) / 2, railWidth / 2)
        let minimum = min(halfBubble + max(edgePadding, 0), railWidth / 2)
        let maximum = max(railWidth - minimum, minimum)
        return min(max(anchor, minimum), maximum)
    }

    static func ordered(_ hits: [SearchHit]) -> [SearchHit] {
        hits.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.id.rawValue < $1.id.rawValue }
            return $0.capturedAt < $1.capturedAt
        }
    }

    static func applicationIdentity(for context: ScreenContext) -> String {
        let bundle = context.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let bundle, !bundle.isEmpty { return bundle }
        let name = context.applicationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return name.isEmpty ? "unknown" : name
    }

    static func fraction(forIndex index: Int, in orderedHits: [SearchHit]) -> Double {
        guard !orderedHits.isEmpty else { return 0 }
        let boundedIndex = min(max(index, 0), orderedHits.count - 1)
        guard orderedHits.count > 1 else { return 0.5 }
        let first = orderedHits[0].capturedAt.timeIntervalSinceReferenceDate
        let last = orderedHits[orderedHits.count - 1].capturedAt.timeIntervalSinceReferenceDate
        let duration = last - first
        guard duration > 0 else {
            return Double(boundedIndex) / Double(orderedHits.count - 1)
        }
        let value = orderedHits[boundedIndex].capturedAt.timeIntervalSinceReferenceDate
        return min(max((value - first) / duration, 0), 1)
    }

    static func nearestHit(toFraction fraction: Double, in orderedHits: [SearchHit]) -> SearchHit? {
        guard !orderedHits.isEmpty else { return nil }
        guard orderedHits.count > 1 else { return orderedHits[0] }
        let boundedFraction = min(max(fraction, 0), 1)
        let first = orderedHits[0].capturedAt.timeIntervalSinceReferenceDate
        let last = orderedHits[orderedHits.count - 1].capturedAt.timeIntervalSinceReferenceDate
        if last <= first {
            let index = Int((boundedFraction * Double(orderedHits.count - 1)).rounded())
            return orderedHits[min(max(index, 0), orderedHits.count - 1)]
        }
        let target = first + ((last - first) * boundedFraction)
        return orderedHits.min {
            abs($0.capturedAt.timeIntervalSinceReferenceDate - target)
                < abs($1.capturedAt.timeIntervalSinceReferenceDate - target)
        }
    }
}

struct TimelineWorkspaceScope {
    static func contains(_ date: Date, in scope: RecallScope) -> Bool {
        (scope.startDate.map { date >= $0 } ?? true)
            && (scope.endDate.map { date < $0 } ?? true)
    }

    static func startOfDay(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayScope(
        for day: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> RecallScope {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return RecallScope(startDate: start, endDate: end)
    }

    static func initialDay(
        preferredDay: Date?,
        visibleSelectionDate: Date?,
        recallScope: RecallScope,
        newestCapture: Date?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let candidate = preferredDay
            ?? visibleSelectionDate
            ?? exactDay(in: recallScope, calendar: calendar)
            ?? newestCapture
            ?? now
        return calendar.startOfDay(for: candidate)
    }

    static func exactDay(
        in scope: RecallScope,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        guard let requestedStart = scope.startDate,
              let requestedEnd = scope.endDate else { return nil }
        let start = calendar.startOfDay(for: requestedStart)
        guard requestedStart == start,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: start),
              requestedEnd == nextDay else { return nil }
        return start
    }
}

private enum TimelineAppColor {
    private static let colors: [Color] = [
        PassagePalette.accent,
        PassagePalette.violet,
        PassagePalette.mint,
        Color(red: 0.95, green: 0.49, blue: 0.30),
        Color(red: 0.22, green: 0.58, blue: 0.86),
        Color(red: 0.79, green: 0.38, blue: 0.68),
    ]

    static func color(for context: ScreenContext) -> Color {
        let scalarSum = TimelineProjection.applicationIdentity(for: context).unicodeScalars.reduce(0) {
            (($0 &* 31) &+ Int($1.value)) & 0x7fff_ffff
        }
        return colors[scalarSum % colors.count]
    }
}
