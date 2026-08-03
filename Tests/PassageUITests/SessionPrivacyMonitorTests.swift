import AppKit
@testable import PassageUI
import Testing

@Suite("Session privacy signals")
@MainActor
struct SessionPrivacyMonitorTests {
    @Test("Initial protected-data unavailability keeps the vault closed")
    func initiallyUnavailableProtectedDataStaysLockedUntilAvailable() {
        var state = SessionPrivacyState(protectedDataIsAvailable: false)

        #expect(!state.permitsVaultAccess)
        #expect(state.consume(.protectedDataWillBecomeUnavailable) == nil)
        #expect(state.consume(.protectedDataDidBecomeAvailable) == .unlock)
        #expect(state.permitsVaultAccess)
    }

    @Test("Wake cannot reopen the vault while the user session is inactive")
    func wakeAtLoginScreenStaysLocked() {
        var state = SessionPrivacyState()

        #expect(state.consume(.sessionResignedActive) == .lock)
        #expect(state.consume(.screenSlept) == nil)
        #expect(state.consume(.screenWoke) == nil)
        #expect(!state.permitsVaultAccess)
        #expect(state.consume(.sessionBecameActive) == .unlock)
        #expect(state.permitsVaultAccess)
    }

    @Test("Duplicate screen and session notifications coalesce")
    func duplicateSignalsCoalesce() {
        var state = SessionPrivacyState()

        #expect(state.consume(.protectedDataWillBecomeUnavailable) == .lock)
        #expect(state.consume(.protectedDataWillBecomeUnavailable) == nil)
        #expect(state.consume(.screenSlept) == nil)
        #expect(state.consume(.screenSlept) == nil)
        #expect(state.consume(.sessionResignedActive) == nil)
        #expect(state.consume(.screenWoke) == nil)
        #expect(state.consume(.protectedDataDidBecomeAvailable) == nil)
        #expect(state.consume(.protectedDataDidBecomeAvailable) == nil)
        #expect(state.consume(.sessionBecameActive) == .unlock)
        #expect(state.consume(.sessionBecameActive) == nil)
        #expect(state.consume(.screenWoke) == nil)
    }

    @Test("Application protected-data notifications fire one transition each")
    func protectedDataNotificationsAreObservedAndCoalesced() {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        var transitions: [SessionPrivacyTransition] = []
        let monitor = SessionPrivacyMonitor(
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter,
            onLock: { transitions.append(.lock) },
            onUnlock: { transitions.append(.unlock) }
        )

        applicationCenter.post(
            name: .NSApplicationProtectedDataWillBecomeUnavailable,
            object: nil
        )
        applicationCenter.post(
            name: .NSApplicationProtectedDataWillBecomeUnavailable,
            object: nil
        )
        #expect(transitions == [.lock])

        applicationCenter.post(
            name: .NSApplicationProtectedDataDidBecomeAvailable,
            object: nil
        )
        applicationCenter.post(
            name: .NSApplicationProtectedDataDidBecomeAvailable,
            object: nil
        )
        #expect(transitions == [.lock, .unlock])
        withExtendedLifetime(monitor) {}
    }

    @Test("A failed protected read repairs an optimistic startup preflight")
    func detectedProtectedDataFailureMakesAvailabilityRetryable() {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        var transitions: [SessionPrivacyTransition] = []
        let monitor = SessionPrivacyMonitor(
            initialProtectedDataAvailable: true,
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter,
            onLock: { transitions.append(.lock) },
            onUnlock: { transitions.append(.unlock) }
        )

        monitor.markProtectedDataUnavailable()
        monitor.markProtectedDataUnavailable()
        #expect(transitions.isEmpty)

        applicationCenter.post(
            name: .NSApplicationProtectedDataDidBecomeAvailable,
            object: nil
        )
        applicationCenter.post(
            name: .NSApplicationProtectedDataDidBecomeAvailable,
            object: nil
        )
        #expect(transitions == [.unlock])
        withExtendedLifetime(monitor) {}
    }

    @Test("Application activation repairs a stale locked launch preflight")
    func applicationActivationReconcilesProtectedData() {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        var protectedDataAvailable = false
        var transitions: [SessionPrivacyTransition] = []
        let monitor = SessionPrivacyMonitor(
            initialProtectedDataAvailable: false,
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter,
            protectedDataAvailable: { protectedDataAvailable },
            onLock: { transitions.append(.lock) },
            onUnlock: { transitions.append(.unlock) }
        )

        applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(transitions.isEmpty)

        protectedDataAvailable = true
        applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(transitions == [.unlock])
        withExtendedLifetime(monitor) {}
    }

    @Test("Availability reconciliation cannot reopen an inactive user session")
    func reconciliationHonorsIndependentSessionLock() {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        var protectedDataAvailable = false
        var transitions: [SessionPrivacyTransition] = []
        let monitor = SessionPrivacyMonitor(
            initialProtectedDataAvailable: true,
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter,
            protectedDataAvailable: { protectedDataAvailable },
            onLock: { transitions.append(.lock) },
            onUnlock: { transitions.append(.unlock) }
        )

        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        protectedDataAvailable = true
        applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(transitions == [.lock])

        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(transitions == [.lock, .unlock])
        withExtendedLifetime(monitor) {}
    }
}
