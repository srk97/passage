import Foundation
import CoreGraphics
import IOKit.ps

/// Pure scheduling state for Passage's capture loop.
///
/// The coordinator continues to check lightweight foreground context regularly, while
/// expensive snapshots back off when the screen remains unchanged. All time and
/// system-pressure inputs are explicit so the behavior can be tested without sleeping.
public struct AdaptiveCaptureCadence: Sendable {
    public enum ThermalPressure: Int, Sendable, Equatable {
        case nominal
        case fair
        case serious
        case critical
    }

    public struct SystemSignals: Sendable, Equatable {
        public var isLowPowerModeEnabled: Bool
        public var isOnBatteryPower: Bool
        public var thermalPressure: ThermalPressure
        public var userIdleSeconds: TimeInterval

        public init(
            isLowPowerModeEnabled: Bool = false,
            isOnBatteryPower: Bool = false,
            thermalPressure: ThermalPressure = .nominal,
            userIdleSeconds: TimeInterval = 0
        ) {
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.isOnBatteryPower = isOnBatteryPower
            self.thermalPressure = thermalPressure
            self.userIdleSeconds = max(userIdleSeconds, 0)
        }

        public static let normal = SystemSignals()

        public static func current() -> SystemSignals {
            let processInfo = ProcessInfo.processInfo
            let pressure: ThermalPressure
            switch processInfo.thermalState {
            case .nominal:
                pressure = .nominal
            case .fair:
                pressure = .fair
            case .serious:
                pressure = .serious
            case .critical:
                pressure = .critical
            @unknown default:
                pressure = .serious
            }
            return SystemSignals(
                isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                isOnBatteryPower: currentlyOnBatteryPower(),
                thermalPressure: pressure,
                userIdleSeconds: currentUserIdleSeconds()
            )
        }

        private static func currentlyOnBatteryPower() -> Bool {
            guard let source = IOPSGetProvidingPowerSourceType(nil)?
                .takeRetainedValue() as String? else { return false }
            return source == kIOPSBatteryPowerValue
        }

        private static func currentUserIdleSeconds() -> TimeInterval {
            let eventTypes: [CGEventType] = [
                .keyDown,
                .flagsChanged,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .mouseMoved,
                .scrollWheel,
            ]
            let value = eventTypes.map {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
            }.min() ?? 0
            return value.isFinite && value >= 0 ? value : 0
        }
    }

    public enum CaptureOutcome: Sendable, Equatable {
        case persisted
        case unchanged
        /// A candidate was discarded before change detection could reach a
        /// durable conclusion, usually because focus moved while the privacy
        /// checks were in flight. Retry at the active cadence without treating
        /// the screen as unchanged.
        case deferred
        case failed
    }

    public struct Decision: Sendable, Equatable {
        public var shouldCapture: Bool
        public var nextCheckAfter: Duration
        public var resetForContextChange: Bool

        public init(
            shouldCapture: Bool,
            nextCheckAfter: Duration,
            resetForContextChange: Bool
        ) {
            self.shouldCapture = shouldCapture
            self.nextCheckAfter = nextCheckAfter
            self.resetForContextChange = resetForContextChange
        }
    }

    private var activeIntervalSeconds: TimeInterval
    private var heartbeatSeconds: TimeInterval
    private var lastContextKey: String?
    private var lastAttemptAt: Date?
    private var lastPersistedAt: Date?
    private var lastOutcome: CaptureOutcome?
    private var unchangedStreak = 0
    private var privateContextStreak = 0

    public init(
        activeInterval: Duration = .seconds(2),
        unchangedHeartbeat: Duration = .seconds(30)
    ) {
        let active = max(Self.seconds(activeInterval), 0.25)
        activeIntervalSeconds = active
        heartbeatSeconds = max(Self.seconds(unchangedHeartbeat), active)
    }

    /// Applies a new user policy and makes it effective on the next loop iteration.
    public mutating func update(
        activeInterval: Duration,
        unchangedHeartbeat: Duration
    ) {
        let active = max(Self.seconds(activeInterval), 0.25)
        activeIntervalSeconds = active
        heartbeatSeconds = max(Self.seconds(unchangedHeartbeat), active)
        unchangedStreak = 0
        lastAttemptAt = nil
        lastOutcome = nil
    }

    /// Decides whether an expensive snapshot is due for the currently focused context.
    /// A context transition always resets backoff and captures immediately when permitted.
    public mutating func decision(
        now: Date,
        contextKey: String,
        isPermitted: Bool,
        signals: SystemSignals = .normal
    ) -> Decision {
        let contextChanged = lastContextKey != contextKey
        if contextChanged {
            lastContextKey = contextKey
            lastAttemptAt = nil
            lastOutcome = nil
            unchangedStreak = 0
            privateContextStreak = 0
        }

        guard isPermitted else {
            privateContextStreak += 1
            return Decision(
                shouldCapture: false,
                nextCheckAfter: Self.duration(
                    privacyCheckInterval(signals: signals)
                ),
                resetForContextChange: contextChanged
            )
        }

        privateContextStreak = 0
        let captureDueIn = secondsUntilCapture(now: now, signals: signals)
        let shouldCapture = contextChanged || captureDueIn <= 0
        return Decision(
            shouldCapture: shouldCapture,
            nextCheckAfter: shouldCapture
                ? .zero
                : Self.duration(min(contextCheckInterval(signals: signals), captureDueIn)),
            resetForContextChange: contextChanged
        )
    }

    /// Records the result of an attempted snapshot. Persistence immediately clears idle
    /// backoff; unchanged frames progressively reduce future snapshot frequency.
    public mutating func record(_ outcome: CaptureOutcome, at date: Date) {
        lastAttemptAt = date
        lastOutcome = outcome
        switch outcome {
        case .persisted:
            lastPersistedAt = date
            unchangedStreak = 0
        case .unchanged:
            unchangedStreak += 1
        case .deferred, .failed:
            unchangedStreak = 0
        }
    }

    /// Returns the lightweight context polling interval after the latest outcome.
    public func nextCheckInterval(
        now: Date,
        isPermitted: Bool,
        signals: SystemSignals = .normal
    ) -> Duration {
        if !isPermitted {
            return Self.duration(privacyCheckInterval(signals: signals))
        }
        return Self.duration(
            min(contextCheckInterval(signals: signals), max(secondsUntilCapture(now: now, signals: signals), 0))
        )
    }

    public mutating func reset() {
        lastContextKey = nil
        lastAttemptAt = nil
        lastPersistedAt = nil
        lastOutcome = nil
        unchangedStreak = 0
        privateContextStreak = 0
    }

    private func secondsUntilCapture(now: Date, signals: SystemSignals) -> TimeInterval {
        guard let lastAttemptAt else { return 0 }

        let retryInterval: TimeInterval
        switch lastOutcome {
        case .unchanged:
            if signals.hasRecentUserInput(activeIntervalSeconds: activeIntervalSeconds) {
                // Keyboard or pointer activity can change a small part of an
                // otherwise stable window. Resume the configured cadence at
                // once so typing is not hidden behind an old idle backoff.
                retryInterval = effectiveActiveInterval(signals: signals)
            } else {
                // Keep the first retry quick, then sample at 2x/4x/8x only
                // while the person is genuinely idle.
                let exponent = min(max(unchangedStreak - 1, 0), 3)
                retryInterval = effectiveActiveInterval(signals: signals) * pow(2, Double(exponent))
            }
        case .deferred, .failed:
            // Errors retry deliberately; they never create a zero-delay failure loop.
            retryInterval = effectiveActiveInterval(signals: signals)
        case .persisted, .none:
            retryInterval = effectiveActiveInterval(signals: signals)
        }

        var dueAt = lastAttemptAt.addingTimeInterval(retryInterval)
        if lastOutcome != .failed,
           lastOutcome != .deferred,
           let lastPersistedAt {
            let heartbeatAt = lastPersistedAt.addingTimeInterval(heartbeatSeconds)
            dueAt = min(dueAt, heartbeatAt)
        }
        return dueAt.timeIntervalSince(now)
    }

    private func contextCheckInterval(signals: SystemSignals) -> TimeInterval {
        effectiveActiveInterval(signals: signals)
    }

    private func privacyCheckInterval(signals: SystemSignals) -> TimeInterval {
        // No screen frames are consumed in excluded contexts. A modest, bounded context
        // backoff avoids hot polling while still noticing an app transition promptly.
        let multiplier = privateContextStreak >= 2 ? 3.0 : 2.0
        return min(max(effectiveActiveInterval(signals: signals) * multiplier, 4), 8)
    }

    private func effectiveActiveInterval(signals: SystemSignals) -> TimeInterval {
        activeIntervalSeconds * signals.multiplier
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func duration(_ seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((max(seconds, 0) * 1_000).rounded()))
    }
}

private extension AdaptiveCaptureCadence.SystemSignals {
    func hasRecentUserInput(activeIntervalSeconds: TimeInterval) -> Bool {
        userIdleSeconds < max(activeIntervalSeconds * 1.5, 3)
    }

    var multiplier: Double {
        let thermalMultiplier: Double = switch thermalPressure {
        case .nominal: 1
        case .fair: 1.25
        case .serious: 2
        case .critical: 4
        }
        // Unplugged operation halves the sampling rate outright: every saved
        // moment costs OCR inference, encoding, and encryption, and battery
        // discharge is the one power signal macOS reports continuously
        // rather than only after the person opts into Low Power Mode.
        let powerMultiplier = (isOnBatteryPower ? 2.0 : 1.0)
            * (isLowPowerModeEnabled ? 1.5 : 1.0)
        return thermalMultiplier * powerMultiplier
    }
}
