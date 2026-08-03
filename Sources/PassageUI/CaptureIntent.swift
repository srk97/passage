import Foundation

/// The durable capture choice made by the person using Passage.
///
/// This is intentionally separate from `PassageModel.CaptureState`, which is
/// transient runtime feedback (for example, a private context or a locked Mac).
public enum CaptureIntent: String, Equatable, Sendable {
    case paused
    case remembering
}

/// The immediate result of asking Passage to remember.
///
/// `pendingInitialization` and `permissionRequired` both retain the explicit
/// remembering intent so it can be fulfilled later without another click.
public enum StartCaptureOutcome: Equatable, Sendable {
    case started
    case pendingInitialization
    case permissionRequired
}

/// A deliberately tiny preferences boundary so capture intent can be restored
/// without coupling lifecycle tests to the live application domain.
public struct CaptureIntentStore {
    public static let defaultKey = "chronicle.capture.intent"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = CaptureIntentStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> CaptureIntent {
        guard let rawValue = defaults.string(forKey: key),
              let intent = CaptureIntent(rawValue: rawValue) else {
            return .paused
        }
        return intent
    }

    public func save(_ intent: CaptureIntent) {
        defaults.set(intent.rawValue, forKey: key)
    }
}

enum CaptureRuntimeDecision: Equatable {
    case none
    case start
    case pause
}

/// Pure lifecycle policy used by the model and deterministic unit tests.
enum CaptureLifecycleReducer {
    static func startOutcome(
        coordinatorInitialized: Bool,
        permissionGranted: Bool
    ) -> StartCaptureOutcome {
        guard coordinatorInitialized else { return .pendingInitialization }
        guard permissionGranted else { return .permissionRequired }
        return .started
    }

    static func initializationDecision(
        intent: CaptureIntent,
        permissionGranted: Bool
    ) -> CaptureRuntimeDecision {
        intent == .remembering && permissionGranted ? .start : .none
    }

    static func permissionRefreshDecision(
        intent: CaptureIntent,
        coordinatorInitialized: Bool,
        previouslyGranted: Bool,
        permissionGranted: Bool
    ) -> CaptureRuntimeDecision {
        guard coordinatorInitialized else { return .none }
        if previouslyGranted && !permissionGranted { return .pause }
        if permissionGranted && intent == .remembering { return .start }
        return .none
    }
}
