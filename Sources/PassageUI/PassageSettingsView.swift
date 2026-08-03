import AppKit
import PassageCore
import SwiftUI
import UniformTypeIdentifiers

public struct PassageSettingsView: View {
    @Bindable private var model: PassageModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("chronicle.onboarding.v2.completed") private var onboardingCompleted = false
    @AppStorage("chronicle.onboarding.step.v3") private var onboardingStep = 0
    @State private var domainInput = ""
    @State private var domainValidationMessage: String?
    @State private var confirmingDeleteAll = false
    @State private var openAIAPIKeyInput = ""
    @State private var revealOpenAIAPIKey = false

    public init(model: PassageModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            captureSettings
                .tabItem { Label("Capture", systemImage: "record.circle") }
            Group {
                if model.historyIsSealed {
                    sealedSettings("Privacy exclusions become available after this Mac’s protected data unlocks.")
                } else {
                    privacySettings
                }
            }
                .tabItem { Label("Privacy", systemImage: "hand.raised.fill") }
            Group {
                if model.historyIsSealed {
                    sealedSettings("Image-search progress and provider settings are hidden while history is sealed.")
                } else {
                    intelligenceSettings
                }
            }
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            Group {
                if model.historyIsSealed {
                    sealedSettings("Connected-app permissions are hidden while history is sealed.")
                } else {
                    agentsSettings
                }
            }
                .tabItem { Label("Agents", systemImage: "sparkles.rectangle.stack") }
            Group {
                if model.historyIsSealed {
                    sealedSettings("Memory counts, storage use, and deletion controls unlock with your protected history.")
                } else {
                    storageSettings
                }
            }
                .tabItem { Label("Storage", systemImage: "externaldrive.fill") }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 500, idealHeight: 620)
        .task(id: onboardingCompleted) {
            guard onboardingCompleted else { return }
            await model.start()
        }
    }

    private var captureSettings: some View {
        Form {
            Section("Remembering") {
                LabeledContent("Status") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: capturePrivacyPresentation.systemImage)
                            .foregroundStyle(capturePrivacyPresentation.tone.passageColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capturePrivacyPresentation.title)
                                .fontWeight(.semibold)
                            Text(capturePrivacyPresentation.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 330, alignment: .leading)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(capturePrivacyPresentation.accessibilityLabel)
                }
                if model.historyIsSealed {
                    Label(
                        "Remembering preferences are sealed with your history",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Picker("Check for changes", selection: Binding(
                        get: { model.privacyPreferences.captureIntervalMilliseconds },
                        set: { value in model.setCaptureInterval(milliseconds: value) }
                    )) {
                        Text("Every second").tag(1_000)
                        Text("Every 2 seconds").tag(2_000)
                        Text("Every 5 seconds").tag(5_000)
                    }
                    Toggle("Hide the pointer in saved moments", isOn: Binding(
                        get: { model.privacyPreferences.hideCursor },
                        set: { value in model.setHideCursor(value) }
                    ))
                    Toggle("Remember only the window I’m using", isOn: Binding(
                        get: { model.privacyPreferences.captureFocusedWindowOnly },
                        set: { value in model.setCaptureFocusedWindowOnly(value) }
                    ))
                    Picker("Pause while inactive", selection: Binding(
                        get: { model.privacyPreferences.pauseAfterInactivityMinutes },
                        set: { value in model.setPauseAfterInactivity(minutes: value) }
                    )) {
                        Text("After 5 minutes").tag(5)
                        Text("After 10 minutes").tag(10)
                        Text("After 30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
                }
            }

            Section("Permissions") {
                PermissionSettingsRow(
                    title: "Screen Recording",
                    detail: "macOS uses this name, but Passage takes still snapshots—not video, audio, or keystrokes. Saved moments are encrypted on this Mac. If it is already enabled, fully quit and reopen Passage.",
                    granted: model.screenPermissionGranted,
                    settingsAnchor: "Privacy_ScreenCapture",
                    action: { model.requestScreenPermission() }
                )
                PermissionSettingsRow(
                    title: "App Context (Accessibility)",
                    detail: "Optional. Saves a small encrypted set of visible labels and controls for clearer search, recognizes websites, and helps avoid password fields. Passage does not record keystrokes or hidden app content.",
                    granted: model.accessibilityPermissionGranted,
                    settingsAnchor: "Privacy_Accessibility",
                    action: { model.requestAccessibilityPermission() }
                )
            }

            Section {
                Button {
                    model.pauseCapturing()
                    onboardingStep = OnboardingStep.recall.rawValue
                    onboardingCompleted = false
                    openWindow(id: PassageSceneIdentity.mainSceneID)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Review onboarding", systemImage: "sparkles.rectangle.stack")
                }
            } header: {
                Text("Getting started")
            } footer: {
                Text("Passage pauses remembering first. Your memories, permissions, exclusions, and provider key stay unchanged.")
            }
        }
        .formStyle(.grouped)
    }

    private var capturePrivacyPresentation: CapturePrivacyPresentation {
        CapturePrivacyPresentation(state: model.captureState)
    }

    private var privacySettings: some View {
        Form {
            Section {
                ForEach(model.privacyPreferences.excludedApplications) { exclusion in
                    ExclusionRow(
                        title: exclusion.displayName,
                        subtitle: exclusion.bundleIdentifier,
                        systemImage: "app.badge",
                        remove: { model.removeApplicationExclusion(exclusion) }
                    )
                }
                Button {
                    chooseApplication()
                } label: {
                    Label("Exclude an application…", systemImage: "plus")
                }
            } header: {
                Text("Applications never captured")
            } footer: {
                Text("Passage skips these apps before reading visible text or saving an image.")
            }

            Section {
                ForEach(model.privacyPreferences.excludedDomains, id: \.self) { domain in
                    ExclusionRow(
                        title: domain,
                        subtitle: nil,
                        systemImage: "globe",
                        remove: { model.removeDomainExclusion(domain) }
                    )
                }
                HStack {
                    TextField("example.com", text: $domainInput)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let domainValidationMessage {
                    Text(domainValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Focused websites excluded")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.accessibilityPermissionGranted
                        ? "Subdomains are included. If a browser hides its current address, Passage fails closed and skips that browser."
                        : "App Context (Accessibility) helps identify websites. Without it, Passage skips browsers when it cannot confirm the current address.")
                    Text("If you choose full-screen capture, an excluded site can still appear in another visible window.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var storageSettings: some View {
        Form {
            Section("Automatic cleanup") {
                Picker("Keep history for", selection: Binding(
                    get: { model.privacyPreferences.retentionDays },
                    set: { value in model.setRetention(days: value) }
                )) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Picker("Image cleanup target", selection: Binding(
                    get: { model.privacyPreferences.maximumStorageGigabytes },
                    set: { value in model.setStorageLimit(gigabytes: value) }
                )) {
                    Text("2 GiB").tag(2)
                    Text("5 GiB").tag(5)
                    Text("10 GiB").tag(10)
                    Text("20 GiB").tag(20)
                    Text("50 GiB").tag(50)
                }
                Toggle("Keep searchable text when old images expire", isOn: Binding(
                    get: { model.privacyPreferences.preserveTextAfterImageExpiry },
                    set: { value in model.setPreserveTextAfterImageExpiry(value) }
                ))
            }

            Section("Current use") {
                LabeledContent("Memories", value: model.statistics.frameCount.formatted())
                LabeledContent(
                    "Encrypted database",
                    value: ByteCountFormatter.string(fromByteCount: model.statistics.databaseBytes, countStyle: .file)
                )
                LabeledContent(
                    "Images",
                    value: ByteCountFormatter.string(fromByteCount: model.statistics.mediaBytes, countStyle: .file)
                )
            }

            Section {
                Button("Delete all history…", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .disabled(model.statistics.frameCount == 0 || model.historyDeletionInProgress)
                if model.historyDeletionInProgress {
                    ProgressView("Deleting encrypted history…")
                        .controlSize(.small)
                }
                if let error = model.historyDeletionError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Delete history")
            } footer: {
                Text("Passage pauses remembering first. App access history is kept separately.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all Passage history?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete \(model.statistics.frameCount.formatted()) memories", role: .destructive) {
                model.deleteAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every moment and saved image from Passage. App access history and copies kept by macOS or another backup app remain. This cannot be undone.")
        }
    }

    private var intelligenceSettings: some View {
        Form {
            Section {
                LabeledContent("Image search status") {
                    Label(
                        model.visualUnderstandingState.label,
                        systemImage: visualUnderstandingStatusIcon
                    )
                    .foregroundStyle(visualUnderstandingStatusColor)
                }
                if let coverage = model.visualEmbeddingCoverage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Saved images ready")
                            Spacer()
                            Text("\(coverage.indexedEligibleFrameCount.formatted()) of \(coverage.eligibleFrameCount.formatted())")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Saved images ready for image search")
                        .accessibilityValue("\(coverage.indexedEligibleFrameCount) of \(coverage.eligibleFrameCount)")
                        if let fraction = coverage.coverageFraction {
                            ProgressView(value: fraction)
                                .tint(PassagePalette.mint)
                                .accessibilityLabel("Image search indexing progress")
                                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                        }
                    }
                }
                LabeledContent("Model", value: "Meta PE-Core-S-16-384")
                LabeledContent("Bundled size", value: "118 MB")
                LabeledContent("License", value: "Apache 2.0")
                if case .error(let message) = model.visualUnderstandingState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Image search on this Mac")
            } footer: {
                Text("Passage compares the appearance of saved images entirely on this Mac. Images never leave for visual search, and the derived search data stays in the encrypted database. Background indexing may pause to keep Passage responsive or when a saved image is unavailable.")
            }

            Section {
                LabeledContent("Status") {
                    Label(
                        model.intelligenceState.label,
                        systemImage: intelligenceStatusIcon
                    )
                    .foregroundStyle(intelligenceStatusColor)
                }
                LabeledContent("Provider", value: "OpenAI Responses API")
                LabeledContent("Default model", value: "GPT-5.6 Luna")
                if case .error(let message) = model.intelligenceState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Optional session intelligence")
            } footer: {
                Text("Nothing is sent automatically. Passage only contacts the provider after you explicitly Enhance a session or Ask a question.")
            }

            Section {
                if model.openAIAPIKeyConfigured {
                    Label("API key saved in this Mac’s Keychain", systemImage: "key.fill")
                        .foregroundStyle(PassagePalette.mint)
                    Button("Remove OpenAI API key", role: .destructive) {
                        model.removeOpenAIAPIKey()
                        openAIAPIKeyInput = ""
                    }
                } else {
                    HStack {
                        Group {
                            if revealOpenAIAPIKey {
                                TextField("OpenAI API key", text: $openAIAPIKeyInput)
                            } else {
                                SecureField("OpenAI API key", text: $openAIAPIKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button(revealOpenAIAPIKey ? "Hide" : "Show") {
                            revealOpenAIAPIKey.toggle()
                        }
                    }
                    Button("Save key") {
                        if model.saveOpenAIAPIKey(openAIAPIKeyInput) {
                            openAIAPIKeyInput = ""
                            revealOpenAIAPIKey = false
                        }
                    }
                    .disabled(openAIAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Your provider key")
            } footer: {
                Text("The key is device-only, available only while your Mac is unlocked, and never written to Passage preferences, history, or logs.")
            }

            Section("What leaves your Mac") {
                IntelligenceDisclosureRow(
                    icon: "text.quote",
                    title: "Only selected text",
                    detail: "At most 20 moments and 20 KB from the session you choose"
                )
                IntelligenceDisclosureRow(
                    icon: "photo.badge.checkmark",
                    title: "Screenshots stay local",
                    detail: "Screenshots, thumbnails, and image details are never sent"
                )
                IntelligenceDisclosureRow(
                    icon: "link",
                    title: "Links back to your moments stay attached",
                    detail: "Summaries, handoffs, next actions, and answers point to their saved sources"
                )
                Link(
                    "Review OpenAI data controls",
                    destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!
                )
                Link(
                    "Review API key safety",
                    destination: URL(string: "https://help.openai.com/en/articles/5112595-best-practices-for-api-key")!
                )
            }

            Section {
                Text("OpenAI’s current API policy says API data is not used for training by default. Depending on your account’s data controls, request content may be retained in abuse-monitoring logs for up to 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Generated briefs and answers are cached locally in encrypted form. Answers refresh when the question, selected text, provider, or model changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Use a separate project key with restricted permissions, a low spend limit, and regular rotation. Passage uses only the key you save and keeps it in this Mac’s Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How this data is handled")
            }
        }
        .formStyle(.grouped)
    }

    private var agentsSettings: some View {
        Form {
            Section {
                LabeledContent("Local service") {
                    Label(
                        model.agentServiceAvailable ? "Available" : "Unavailable",
                        systemImage: model.agentServiceAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(model.agentServiceAvailable ? PassagePalette.mint : .red)
                }
                if let error = model.agentServiceError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } footer: {
                Text("Only apps in your Mac account can connect. Connected apps never receive Passage’s encryption key.")
            }

            Section {
                agentToggle(name: "Codex", identifier: "codex", icon: "terminal")
                agentToggle(name: "Claude", identifier: "claude", icon: "text.bubble")
                agentToggle(name: "Cursor", identifier: "cursor", icon: "cursorarrow.rays")
                agentToggle(name: "Manual Passage CLI", identifier: "app.chronicle.cli", icon: "chevron.left.forwardslash.chevron.right")
            } header: {
                Text("Allowed clients")
            } footer: {
                Text("App connections are off by default. Turning one on lets an app using that name in your Mac account request remembered text. Every request is added to the access history first.")
            }

            Section("Install agent memory") {
                Text("Run `passage install-skill codex`, `claude`, or `cursor` once from Terminal, then enable that client above.")
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var intelligenceStatusIcon: String {
        switch model.intelligenceState {
        case .notConfigured: "circle.dashed"
        case .ready: "checkmark.circle.fill"
        case .enhancing: "sparkles"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private func sealedSettings(_ detail: String) -> some View {
        ContentUnavailableView {
            Label("History sealed", systemImage: "lock.fill")
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visualUnderstandingStatusIcon: String {
        switch model.visualUnderstandingState {
        case .unavailable: "circle.dashed"
        case .verifying: "shield.lefthalf.filled"
        case .preparing: "cpu"
        case .indexing: "eye"
        case .ready: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var visualUnderstandingStatusColor: Color {
        switch model.visualUnderstandingState {
        case .ready: PassagePalette.mint
        case .verifying, .preparing, .indexing: PassagePalette.accent
        case .paused, .unavailable: .secondary
        case .error: .orange
        }
    }

    private var intelligenceStatusColor: Color {
        switch model.intelligenceState {
        case .notConfigured: .secondary
        case .ready: PassagePalette.mint
        case .enhancing: PassagePalette.accent
        case .error: .red
        }
    }

    private func agentToggle(name: String, identifier: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.privacyPreferences.allowedAgentClients.contains(identifier) },
            set: { allowed in model.setAgentClient(identifier, allowed: allowed) }
        )) {
            Label(name, systemImage: icon)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application Passage should never capture"
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.addApplicationExclusion(at: url)
        }
    }

    private func addDomain() {
        guard model.addDomainExclusion(domainInput) else {
            domainValidationMessage = "Enter a valid website such as example.com."
            return
        }
        domainInput = ""
        domainValidationMessage = nil
    }
}

private struct IntelligenceDisclosureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(PassagePalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let settingsAnchor: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PassagePalette.mint)
            } else {
                HStack(spacing: 8) {
                    Button("Allow", action: action)
                    Button("Settings") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") else {
                            return
                        }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

private struct ExclusionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove exclusion")
        }
    }
}
