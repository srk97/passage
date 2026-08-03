import AppKit
import Carbon.HIToolbox
import PassageUI
import OSLog

@MainActor
enum PassageNativeWindowActivator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.chronicle.local",
        category: "Activation"
    )

    @discardableResult
    static func activateExistingMainWindow() -> Bool {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.identifier == PassageSceneIdentity.mainWindowIdentifier
        }) else { return false }

        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func present(_ intent: PassageActivationIntent) {
        PassageActivationCenter.shared.request(intent)
        guard !activateExistingMainWindow() else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    logger.error("Could not reopen Passage: \(error.localizedDescription, privacy: .public)")
                    return
                }
                _ = activateExistingMainWindow()
                PassageActivationCenter.shared.request(intent)
            }
        }
    }
}

@MainActor
final class PassageApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = PassageModel()
    private var shortcutCenter: PassageGlobalShortcutCenter?
    private var startupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcutCenter = PassageGlobalShortcutCenter()
        guard UserDefaults.standard.bool(forKey: "chronicle.onboarding.v2.completed") else {
            return
        }
        startupTask = Task { [model] in
            await model.start()
            model.refreshPermissions()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissions()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if PassageNativeWindowActivator.activateExistingMainWindow() {
            return false
        }
        return true
    }
}

private enum PassageHotKey {
    static let signature: OSType = 0x4348524E // "CHRN"
    static let open: UInt32 = 1
    static let search: UInt32 = 2
}

private func passageGlobalHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == PassageHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }

    let intent: PassageActivationIntent
    switch identifier.id {
    case PassageHotKey.open:
        intent = .open
    case PassageHotKey.search:
        intent = .search
    default:
        return OSStatus(eventNotHandledErr)
    }

    Task { @MainActor in
        PassageNativeWindowActivator.present(intent)
    }
    return noErr
}

private final class PassageGlobalShortcutCenter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.chronicle.local",
        category: "GlobalShortcuts"
    )

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            passageGlobalHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            Self.logger.error("Could not install global shortcut handler: \(handlerStatus)")
            return
        }

        let modifiers = UInt32(controlKey | shiftKey)
        register(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: modifiers,
            identifier: PassageHotKey.open
        )
        register(
            keyCode: UInt32(kVK_Space),
            modifiers: modifiers,
            identifier: PassageHotKey.search
        )
    }

    deinit {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, identifier: UInt32) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: PassageHotKey.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            hotKeys.append(reference)
        } else {
            Self.logger.notice(
                "Global shortcut \(identifier) was unavailable (status \(status)); Passage will continue without it"
            )
        }
    }
}
