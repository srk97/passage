import AppKit
import Foundation

@MainActor
final class SessionPrivacyMonitor {
    private let observerTokens = ObserverTokens()
    private let onLock: @MainActor () -> Void
    private let onUnlock: @MainActor () -> Void
    private let protectedDataAvailable: @MainActor () -> Bool
    private var state: SessionPrivacyState

    init(
        initialProtectedDataAvailable: Bool = true,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationNotificationCenter: NotificationCenter = .default,
        protectedDataAvailable: @escaping @MainActor () -> Bool = {
            NSApplication.shared.isProtectedDataAvailable
        },
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor () -> Void
    ) {
        self.onLock = onLock
        self.onUnlock = onUnlock
        self.protectedDataAvailable = protectedDataAvailable
        state = SessionPrivacyState(
            protectedDataIsAvailable: initialProtectedDataAvailable
        )
        observe(
            .sessionResignedActive,
            name: NSWorkspace.sessionDidResignActiveNotification,
            center: workspaceNotificationCenter
        )
        observe(
            .screenSlept,
            name: NSWorkspace.screensDidSleepNotification,
            center: workspaceNotificationCenter
        )
        observe(
            .sessionBecameActive,
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            center: workspaceNotificationCenter
        )
        observe(
            .screenWoke,
            name: NSWorkspace.screensDidWakeNotification,
            center: workspaceNotificationCenter
        )
        observe(
            .protectedDataWillBecomeUnavailable,
            name: .NSApplicationProtectedDataWillBecomeUnavailable,
            center: applicationNotificationCenter
        )
        observe(
            .protectedDataDidBecomeAvailable,
            name: .NSApplicationProtectedDataDidBecomeAvailable,
            center: applicationNotificationCenter
        )
        // `isProtectedDataAvailable` can be false while a SwiftUI app is still
        // being constructed even though the logged-in session is already
        // unlocked. In that launch shape there is no false-to-true protected-
        // data notification for Passage to receive. Reconcile the actual API
        // state at the first normal application lifecycle edge instead of
        // leaving the vault sealed forever.
        observeProtectedDataReconciliation(
            name: NSApplication.didFinishLaunchingNotification,
            center: applicationNotificationCenter
        )
        observeProtectedDataReconciliation(
            name: NSApplication.didBecomeActiveNotification,
            center: applicationNotificationCenter
        )
    }

    private func observe(
        _ signal: SessionPrivacySignal,
        name: Notification.Name,
        center: NotificationCenter
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.consume(signal)
            }
        }
        observerTokens.append(token, from: center)
    }

    private func consume(_ signal: SessionPrivacySignal) {
        switch state.consume(signal) {
        case .lock:
            onLock()
        case .unlock:
            onUnlock()
        case nil:
            break
        }
    }

    private func observeProtectedDataReconciliation(
        name: Notification.Name,
        center: NotificationCenter
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileProtectedDataAvailability()
            }
        }
        observerTokens.append(token, from: center)
    }

    func reconcileProtectedDataAvailability() {
        consume(
            protectedDataAvailable()
                ? .protectedDataDidBecomeAvailable
                : .protectedDataWillBecomeUnavailable
        )
    }

    /// Repairs an optimistic protected-data preflight when a real file access
    /// proves that the user's keybag is still unavailable. This is state-only:
    /// the caller owns the synchronous lock transition, avoiding a queued lock
    /// callback that could race behind a fast availability/unlock event. The
    /// later did-become-available notification remains a false-to-true edge and
    /// retries startup exactly once.
    func markProtectedDataUnavailable() {
        _ = state.consume(.protectedDataWillBecomeUnavailable)
    }
}

enum SessionPrivacySignal: Sendable {
    case sessionResignedActive
    case sessionBecameActive
    case screenSlept
    case screenWoke
    case protectedDataWillBecomeUnavailable
    case protectedDataDidBecomeAvailable
}

enum SessionPrivacyTransition: Equatable, Sendable {
    case lock
    case unlock
}

/// Coalesces the paired workspace notifications macOS emits around sleep,
/// wake, Fast User Switching, and the login screen. The vault may reopen only
/// after every independent signal says the current user can see the display
/// and macOS has made protected files available again.
struct SessionPrivacyState: Equatable, Sendable {
    private(set) var sessionIsActive: Bool
    private(set) var screenIsAwake: Bool
    private(set) var protectedDataIsAvailable: Bool

    init(
        sessionIsActive: Bool = true,
        screenIsAwake: Bool = true,
        protectedDataIsAvailable: Bool = true
    ) {
        self.sessionIsActive = sessionIsActive
        self.screenIsAwake = screenIsAwake
        self.protectedDataIsAvailable = protectedDataIsAvailable
    }

    var permitsVaultAccess: Bool {
        sessionIsActive && screenIsAwake && protectedDataIsAvailable
    }

    mutating func consume(_ signal: SessionPrivacySignal) -> SessionPrivacyTransition? {
        let permittedBefore = permitsVaultAccess
        switch signal {
        case .sessionResignedActive:
            sessionIsActive = false
        case .sessionBecameActive:
            sessionIsActive = true
        case .screenSlept:
            screenIsAwake = false
        case .screenWoke:
            screenIsAwake = true
        case .protectedDataWillBecomeUnavailable:
            protectedDataIsAvailable = false
        case .protectedDataDidBecomeAvailable:
            protectedDataIsAvailable = true
        }
        guard permitsVaultAccess != permittedBefore else { return nil }
        return permitsVaultAccess ? .unlock : .lock
    }
}

private final class ObserverTokens: @unchecked Sendable {
    private var registrations: [(NotificationCenter, NSObjectProtocol)] = []

    func append(_ token: NSObjectProtocol, from notificationCenter: NotificationCenter) {
        registrations.append((notificationCenter, token))
    }

    deinit {
        for (notificationCenter, token) in registrations {
            notificationCenter.removeObserver(token)
        }
    }
}
