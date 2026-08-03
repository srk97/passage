import PassageCore
import CoreGraphics
import Foundation

/// The narrow screenshot boundary used by the capture coordinator.
///
/// Keeping the OS implementation behind an actor protocol lets lifecycle and
/// overlap behavior be exercised with suspended deliveries in tests, without
/// changing the production ScreenCaptureKit path.
public protocol ScreenSnapshotProviding: Actor {
    func snapshot(
        hideCursor: Bool,
        preferredDisplayID: CGDirectDisplayID?,
        preferredWindowID: CGWindowID?,
        excludedBundleIdentifiers: Set<String>
    ) async throws -> ScreenSnapshot

    func invalidatePendingCaptures()
}

extension ScreenSnapshotService: ScreenSnapshotProviding {}

/// An accessibility snapshot together with the live foreground context the
/// provider observed after its element walk. Reusing that context spares the
/// caller one full window-server and Accessibility round trip per persisted
/// frame; a nil `liveContext` means the caller must probe freshly itself.
public struct ValidatedAccessibilityCapture: Sendable {
    public var snapshot: AccessibilitySnapshot?
    public var liveContext: ScreenContext?

    public init(snapshot: AccessibilitySnapshot?, liveContext: ScreenContext?) {
        self.snapshot = snapshot
        self.liveContext = liveContext
    }
}

/// Supplies the foreground context immediately before and after pixel delivery.
public protocol ActiveContextProviding: Actor {
    func current() async -> ScreenContext
    func accessibilitySnapshot(
        for context: ScreenContext
    ) async -> AccessibilitySnapshot?
    func validatedAccessibilityCapture(
        for context: ScreenContext
    ) async -> ValidatedAccessibilityCapture
}

public extension ActiveContextProviding {
    /// Existing providers and privacy-focused test doubles opt out by default.
    func accessibilitySnapshot(
        for context: ScreenContext
    ) async -> AccessibilitySnapshot? {
        _ = context
        return nil
    }

    /// Providers that do not derive a post-walk context leave `liveContext`
    /// nil, which preserves the caller's original fresh-probe behavior.
    func validatedAccessibilityCapture(
        for context: ScreenContext
    ) async -> ValidatedAccessibilityCapture {
        ValidatedAccessibilityCapture(
            snapshot: await accessibilitySnapshot(for: context),
            liveContext: nil
        )
    }
}

extension ActiveContextProvider: ActiveContextProviding {}
