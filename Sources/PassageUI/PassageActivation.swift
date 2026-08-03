import AppKit
import Foundation

public enum PassageSceneIdentity {
    public static let mainSceneID = "passage-main"
    public static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("passage.main-window")
}

public enum PassageActivationIntent: String, Sendable {
    case open
    case search
}

/// Carries transient activation requests from native app surfaces into the SwiftUI window.
/// Requests stay in memory only, so a global shortcut can still focus search after reopening
/// a closed window without persisting any user activity or query data.
@MainActor
public final class PassageActivationCenter {
    public static let shared = PassageActivationCenter()
    public static let requestNotification = Notification.Name("app.passage.activation-requested")

    private var pendingIntent: PassageActivationIntent?

    private init() {}

    public func request(_ intent: PassageActivationIntent) {
        pendingIntent = intent
        NotificationCenter.default.post(name: Self.requestNotification, object: self)
    }

    public func takePendingIntent() -> PassageActivationIntent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }
}
