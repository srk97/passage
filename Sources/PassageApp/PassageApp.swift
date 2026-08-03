import AppKit
import PassageUI
import SwiftUI

@main
struct PassageApp: App {
    @NSApplicationDelegateAdaptor(PassageApplicationDelegate.self) private var appDelegate
    @AppStorage("chronicle.onboarding.v2.completed") private var onboardingCompleted = false

    var body: some Scene {
        WindowGroup(id: PassageSceneIdentity.mainSceneID) {
            let model = appDelegate.model
            PassageRootView(model: model)
                .background(PassageMainWindowTag { visible in
                    model.setMainWindowVisible(visible)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 760)

        MenuBarExtra {
            PassageMenuBarView(model: appDelegate.model)
        } label: {
            switch menuBarIcon {
            case .mark:
                Image(nsImage: PassageMark.menuBarTemplateImage())
                    .accessibilityLabel("Passage")
            case .system(let symbol):
                Label("Passage", systemImage: symbol)
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PassageSettingsView(model: appDelegate.model)
        }
    }

    private var menuBarIcon: CapturePrivacyPresentation.MenuBarIcon {
        // Before setup the app has no capture state to describe, so the mark
        // stands alone rather than implying a running capture status.
        guard onboardingCompleted else { return .mark }
        return CapturePrivacyPresentation(
            state: appDelegate.model.captureState
        ).menuBarIcon
    }
}

@MainActor
private struct PassageMenuBarView: View {
    @Bindable var model: PassageModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("chronicle.onboarding.v2.completed") private var onboardingCompleted = false

    var body: some View {
        Label(
            onboardingCompleted ? capturePrivacyPresentation.title : "Finish setup",
            systemImage: onboardingCompleted
                ? capturePrivacyPresentation.systemImage
                : "sparkles"
        )
        Text(onboardingCompleted
            ? capturePrivacyPresentation.detail
            : "See how Passage remembers before choosing access")
        if onboardingCompleted, let libraryDetail {
            Text(libraryDetail)
        }

        Divider()

        if onboardingCompleted {
            Button {
                presentMainWindow(intent: .open)
            } label: {
                Label("Open Passage", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("c", modifiers: [.control, .shift])

            Button {
                presentMainWindow(intent: .search)
            } label: {
                Label("Search Memories", systemImage: "magnifyingglass")
            }
            .keyboardShortcut(.space, modifiers: [.control, .shift])
        } else {
            Button {
                presentMainWindow(intent: .open)
            } label: {
                Label("Finish Setup", systemImage: "hand.wave.fill")
            }
        }

        Divider()

        if onboardingCompleted {
            Button {
                model.captureNow()
            } label: {
                Label("Capture This Moment", systemImage: "camera.viewfinder")
            }
            .disabled(!model.captureControlsEnabled)

            Button {
                model.toggleCapture()
            } label: {
                Label(captureToggleTitle, systemImage: isRemembering ? "pause.fill" : "record.circle")
            }
            .disabled(!model.captureControlsEnabled)
        }

        Divider()

        Button {
            openSettings()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit Passage") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var isRemembering: Bool {
        model.captureIntent == .remembering
    }

    private var captureToggleTitle: String {
        guard model.screenPermissionGranted else { return "Screen Recording Required" }
        return isRemembering ? "Pause Remembering" : "Resume Remembering"
    }

    private var capturePrivacyPresentation: CapturePrivacyPresentation {
        CapturePrivacyPresentation(state: model.captureState)
    }

    private var memoryCountLabel: String {
        let count = model.statistics.frameCount
        return "\(count.formatted()) \(count == 1 ? "memory" : "memories")"
    }

    private var libraryDetail: String? {
        if case .locked = model.captureState { return nil }
        return "\(memoryCountLabel) · \(mediaSize)"
    }

    private var mediaSize: String {
        ByteCountFormatter.string(fromByteCount: model.statistics.mediaBytes, countStyle: .file)
    }

    private func presentMainWindow(intent: PassageActivationIntent) {
        PassageActivationCenter.shared.request(intent)
        if !PassageNativeWindowActivator.activateExistingMainWindow() {
            openWindow(id: PassageSceneIdentity.mainSceneID)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            PassageActivationCenter.shared.request(intent)
        }
    }
}

@MainActor
private struct PassageMainWindowTag: NSViewRepresentable {
    var onVisibilityChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        WindowTaggingView(onVisibilityChange: onVisibilityChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Tags the main window and reports whether any of it is actually
    /// on screen. macOS never moves an open-but-covered window's scene to
    /// `.background`, so occlusion is the only trustworthy signal that
    /// per-capture recall refreshes have no visible audience.
    private final class WindowTaggingView: NSView {
        private let onVisibilityChange: (Bool) -> Void

        init(onVisibilityChange: @escaping (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: nil
            )
            guard let window else {
                onVisibilityChange(false)
                return
            }
            window.identifier = PassageSceneIdentity.mainWindowIdentifier
            window.title = "Passage"
            onVisibilityChange(window.occlusionState.contains(.visible))
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(occlusionStateChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }

        @objc private func occlusionStateChanged(_ notification: Notification) {
            guard let window, notification.object as? NSWindow == window else { return }
            onVisibilityChange(window.occlusionState.contains(.visible))
        }
    }
}
