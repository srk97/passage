import PassageCapture
import Foundation
import Testing

@Suite("Adaptive capture cadence")
struct AdaptiveCaptureCadenceTests {
    private let origin = Date(timeIntervalSince1970: 1_000)

    @Test("Uses the configured active interval and captures the first context immediately")
    func activeInterval() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )

        let first = cadence.decision(
            now: origin,
            contextKey: "com.example.editor|Draft",
            isPermitted: true
        )
        #expect(first.shouldCapture)
        #expect(first.resetForContextChange)

        cadence.record(.persisted, at: origin)
        #expect(cadence.nextCheckInterval(now: origin, isPermitted: true) == .seconds(2))

        let early = cadence.decision(
            now: origin.addingTimeInterval(1),
            contextKey: "com.example.editor|Draft",
            isPermitted: true
        )
        #expect(!early.shouldCapture)
        #expect(early.nextCheckAfter == .seconds(1))

        let due = cadence.decision(
            now: origin.addingTimeInterval(2),
            contextKey: "com.example.editor|Draft",
            isPermitted: true
        )
        #expect(due.shouldCapture)
    }

    @Test("Unchanged frames progressively back off without missing the heartbeat")
    func unchangedBackoffAndHeartbeat() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(
            now: origin,
            contextKey: "editor",
            isPermitted: true
        )
        cadence.record(.persisted, at: origin)
        let idle = AdaptiveCaptureCadence.SystemSignals(userIdleSeconds: 60)

        cadence.record(.unchanged, at: origin.addingTimeInterval(2))
        #expect(cadence.nextCheckInterval(
            now: origin.addingTimeInterval(2),
            isPermitted: true,
            signals: idle
        ) == .seconds(2))

        cadence.record(.unchanged, at: origin.addingTimeInterval(4))
        // Context remains inexpensive to poll every two seconds, while the next
        // screen sample itself is now four seconds away.
        let backedOff = cadence.decision(
            now: origin.addingTimeInterval(6),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        )
        #expect(!backedOff.shouldCapture)
        #expect(backedOff.nextCheckAfter == .seconds(2))
        #expect(cadence.decision(
            now: origin.addingTimeInterval(8),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        ).shouldCapture)

        cadence.record(.unchanged, at: origin.addingTimeInterval(8))
        #expect(cadence.nextCheckInterval(
            now: origin.addingTimeInterval(8),
            isPermitted: true,
            signals: idle
        ) == .seconds(2))
        #expect(cadence.decision(
            now: origin.addingTimeInterval(16),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        ).shouldCapture)

        cadence.record(.unchanged, at: origin.addingTimeInterval(16))
        cadence.record(.unchanged, at: origin.addingTimeInterval(24))
        let justBeforeHeartbeat = cadence.decision(
            now: origin.addingTimeInterval(29),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        )
        #expect(!justBeforeHeartbeat.shouldCapture)
        #expect(justBeforeHeartbeat.nextCheckAfter == .seconds(1))
        #expect(cadence.decision(
            now: origin.addingTimeInterval(30),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        ).shouldCapture)
    }

    @Test("Recent input immediately breaks an unchanged-screen backoff")
    func inputBreaksBackoff() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(now: origin, contextKey: "editor", isPermitted: true)
        cadence.record(.persisted, at: origin)
        cadence.record(.unchanged, at: origin.addingTimeInterval(2))
        cadence.record(.unchanged, at: origin.addingTimeInterval(4))

        let idleDecision = cadence.decision(
            now: origin.addingTimeInterval(6),
            contextKey: "editor",
            isPermitted: true,
            signals: .init(userIdleSeconds: 60)
        )
        #expect(!idleDecision.shouldCapture)

        let typingDecision = cadence.decision(
            now: origin.addingTimeInterval(6),
            contextKey: "editor",
            isPermitted: true,
            signals: .init(userIdleSeconds: 0.2)
        )
        #expect(typingDecision.shouldCapture)
    }

    @Test("A changed app or window bypasses idle backoff and persistence resets it")
    func contextAndPersistenceReset() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(now: origin, contextKey: "browser|Inbox", isPermitted: true)
        cadence.record(.persisted, at: origin)
        cadence.record(.unchanged, at: origin.addingTimeInterval(2))
        cadence.record(.unchanged, at: origin.addingTimeInterval(4))

        let transition = cadence.decision(
            now: origin.addingTimeInterval(5),
            contextKey: "editor|Proposal",
            isPermitted: true
        )
        #expect(transition.shouldCapture)
        #expect(transition.resetForContextChange)

        cadence.record(.persisted, at: origin.addingTimeInterval(5))
        #expect(cadence.nextCheckInterval(
            now: origin.addingTimeInterval(5),
            isPermitted: true
        ) == .seconds(2))
    }

    @Test("Low power and thermal pressure safely lengthen work but not the heartbeat")
    func systemPressure() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(now: origin, contextKey: "editor", isPermitted: true)
        cadence.record(.persisted, at: origin)

        #expect(cadence.nextCheckInterval(
            now: origin,
            isPermitted: true,
            signals: .init(isLowPowerModeEnabled: true)
        ) == .seconds(3))
        #expect(cadence.nextCheckInterval(
            now: origin,
            isPermitted: true,
            signals: .init(thermalPressure: .serious)
        ) == .seconds(4))
        #expect(cadence.nextCheckInterval(
            now: origin,
            isPermitted: true,
            signals: .init(isLowPowerModeEnabled: true, thermalPressure: .serious)
        ) == .seconds(6))
        #expect(cadence.nextCheckInterval(
            now: origin,
            isPermitted: true,
            signals: .init(thermalPressure: .critical)
        ) == .seconds(8))

        // Even the combined multiplier yields to the configured 30-second heartbeat.
        cadence.record(.unchanged, at: origin.addingTimeInterval(27))
        #expect(cadence.nextCheckInterval(
            now: origin.addingTimeInterval(27),
            isPermitted: true,
            signals: .init(isLowPowerModeEnabled: true, thermalPressure: .critical)
        ) == .seconds(3))
    }

    @Test("Battery power halves the sampling rate and stacks with Low Power Mode")
    func batteryPower() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(now: origin, contextKey: "editor", isPermitted: true)
        cadence.record(.persisted, at: origin)

        #expect(cadence.nextCheckInterval(
            now: origin,
            isPermitted: true,
            signals: .init(isOnBatteryPower: true)
        ) == .seconds(4))
        #expect(cadence.nextCheckInterval(
            now: origin,
            isPermitted: true,
            signals: .init(isLowPowerModeEnabled: true, isOnBatteryPower: true)
        ) == .seconds(6))
    }

    @Test("Excluded contexts avoid snapshots and use a bounded low-frequency poll")
    func privateContextBackoff() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )

        let firstPrivateCheck = cadence.decision(
            now: origin,
            contextKey: "password-manager",
            isPermitted: false
        )
        #expect(!firstPrivateCheck.shouldCapture)
        #expect(firstPrivateCheck.nextCheckAfter == .seconds(4))

        let repeatedPrivateCheck = cadence.decision(
            now: origin.addingTimeInterval(4),
            contextKey: "password-manager",
            isPermitted: false
        )
        #expect(!repeatedPrivateCheck.shouldCapture)
        #expect(repeatedPrivateCheck.nextCheckAfter == .seconds(6))

        let returnedToAllowedApp = cadence.decision(
            now: origin.addingTimeInterval(5),
            contextKey: "editor",
            isPermitted: true
        )
        #expect(returnedToAllowedApp.shouldCapture)
        #expect(returnedToAllowedApp.resetForContextChange)
    }

    @Test("A failed attempt retries after the active interval instead of spinning")
    func failureRetry() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(now: origin, contextKey: "editor", isPermitted: true)
        cadence.record(.persisted, at: origin)
        cadence.record(.failed, at: origin.addingTimeInterval(30))

        #expect(cadence.nextCheckInterval(
            now: origin.addingTimeInterval(30),
            isPermitted: true
        ) == .seconds(2))
        #expect(!cadence.decision(
            now: origin.addingTimeInterval(31),
            contextKey: "editor",
            isPermitted: true
        ).shouldCapture)
        #expect(cadence.decision(
            now: origin.addingTimeInterval(32),
            contextKey: "editor",
            isPermitted: true
        ).shouldCapture)
    }

    @Test("A privacy-safe context discard retries promptly without unchanged backoff")
    func deferredRetry() {
        var cadence = AdaptiveCaptureCadence(
            activeInterval: .seconds(2),
            unchangedHeartbeat: .seconds(30)
        )
        _ = cadence.decision(now: origin, contextKey: "editor", isPermitted: true)
        cadence.record(.persisted, at: origin)
        cadence.record(.unchanged, at: origin.addingTimeInterval(2))
        cadence.record(.unchanged, at: origin.addingTimeInterval(4))
        cadence.record(.deferred, at: origin.addingTimeInterval(30))

        let idle = AdaptiveCaptureCadence.SystemSignals(userIdleSeconds: 60)
        #expect(cadence.nextCheckInterval(
            now: origin.addingTimeInterval(30),
            isPermitted: true,
            signals: idle
        ) == .seconds(2))
        #expect(!cadence.decision(
            now: origin.addingTimeInterval(31),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        ).shouldCapture)
        #expect(cadence.decision(
            now: origin.addingTimeInterval(32),
            contextKey: "editor",
            isPermitted: true,
            signals: idle
        ).shouldCapture)
    }
}
