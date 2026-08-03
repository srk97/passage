import Foundation

/// One truthful capture-and-privacy explanation shared by every persistent
/// Passage surface. Runtime states may change often; their meaning should
/// not change between the menu bar, sidebar, and Settings.
public struct CapturePrivacyPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case remembering
        case privateContext
        case neutral
        case sealed
        case attention
    }

    /// What the persistent menu-bar item shows. Ordinary operation shows the
    /// Passage mark; states the person may need to act on replace it with an
    /// unmistakable status glyph.
    public enum MenuBarIcon: Equatable, Sendable {
        case mark
        case system(String)
    }

    public let title: String
    public let detail: String
    public let systemImage: String
    public let menuBarIcon: MenuBarIcon
    public let tone: Tone

    public var accessibilityLabel: String {
        "\(title). \(detail)"
    }

    public init(state: PassageModel.CaptureState) {
        switch state {
        case .capturing:
            title = "Remembering"
            detail = "Still snapshots—not video—encrypted on this Mac"
            systemImage = "photo.stack"
            menuBarIcon = .mark
            tone = .remembering
        case .privateContext(let applicationName):
            let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            title = name.isEmpty ? "This app stays private" : "\(name) stays private"
            detail = "No text or image is being saved"
            systemImage = "hand.raised.fill"
            // Expected privacy skips must not flash the persistent menu icon.
            menuBarIcon = .mark
            tone = .privateContext
        case .paused:
            title = "Remembering paused"
            detail = "Nothing new is being saved"
            systemImage = "pause.circle.fill"
            menuBarIcon = .system("pause.circle.fill")
            tone = .neutral
        case .unavailable:
            title = "Preparing Passage"
            detail = "Nothing is being saved yet"
            systemImage = "hourglass"
            menuBarIcon = .mark
            tone = .neutral
        case .locked:
            title = "History sealed"
            detail = "Your history remains encrypted on this Mac"
            systemImage = "lock.fill"
            menuBarIcon = .system("lock.fill")
            tone = .sealed
        case .error(let message):
            let explanation = message.trimmingCharacters(in: .whitespacesAndNewlines)
            title = "Remembering needs attention"
            detail = explanation.isEmpty
                ? "Open Passage to review capture permissions"
                : explanation
            systemImage = "exclamationmark.triangle.fill"
            menuBarIcon = .system("exclamationmark.triangle.fill")
            tone = .attention
        }
    }
}
