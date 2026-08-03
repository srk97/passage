import PassageCore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

public struct ScreenSnapshot: @unchecked Sendable {
    public var image: CGImage
    public var capturedAt: Date
    public var displayID: CGDirectDisplayID

    public init(image: CGImage, capturedAt: Date, displayID: CGDirectDisplayID) {
        self.image = image
        self.capturedAt = capturedAt
        self.displayID = displayID
    }
}

/// Produces privacy-filtered, on-demand screenshots without opening a live
/// screen-sharing stream. A long-running `SCStream` makes macOS advertise an
/// active sharing session in the menu bar; `SCScreenshotManager` is the native
/// still-image path and gives Passage no stream lifecycle to churn.
public actor ScreenSnapshotService {
    private let maximumDimension: Int
    private var captureEpoch = UUID()

    public init(maximumDimension: Int = 1_920) {
        self.maximumDimension = maximumDimension
    }

    public static func permissionGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func snapshot(
        hideCursor: Bool,
        preferredDisplayID: CGDirectDisplayID? = nil,
        preferredWindowID: CGWindowID? = nil,
        excludedBundleIdentifiers: Set<String> = []
    ) async throws -> ScreenSnapshot {
        guard Self.permissionGranted() else {
            throw PassageError.capturePermissionDenied
        }
        let expectedEpoch = captureEpoch
        try ensureCurrent(expectedEpoch)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            try ensureCurrent(expectedEpoch)
            let target = try Self.captureTarget(
                content: content,
                preferredDisplayID: preferredDisplayID,
                preferredWindowID: preferredWindowID,
                excludedBundleIdentifiers: excludedBundleIdentifiers,
                maximumDimension: maximumDimension
            )

            let configuration = SCStreamConfiguration()
            configuration.width = target.width
            configuration.height = target.height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = !hideCursor
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: target.filter,
                configuration: configuration
            )
            try ensureCurrent(expectedEpoch)
            return ScreenSnapshot(
                image: image,
                capturedAt: Date(),
                displayID: target.displayID
            )
        } catch let error as PassageError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !Self.permissionGranted() {
                throw PassageError.capturePermissionDenied
            }
            throw PassageError.captureUnavailable(error.localizedDescription)
        }
    }

    /// Invalidates every request that crossed an asynchronous ScreenCaptureKit
    /// boundary before this call. The OS still owns any in-flight work, but its
    /// pixels can no longer leave this actor.
    public func invalidatePendingCaptures() {
        captureEpoch = UUID()
    }

    private func ensureCurrent(_ expectedEpoch: UUID) throws {
        try Task.checkCancellation()
        guard captureEpoch == expectedEpoch else { throw CancellationError() }
    }

    private struct CaptureTarget {
        var filter: SCContentFilter
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
    }

    private static func captureTarget(
        content: SCShareableContent,
        preferredDisplayID: CGDirectDisplayID?,
        preferredWindowID: CGWindowID?,
        excludedBundleIdentifiers: Set<String>,
        maximumDimension: Int
    ) throws -> CaptureTarget {
        let ownBundle = Bundle.main.bundleIdentifier
        let filter: SCContentFilter
        let display: SCDisplay
        let sourceWidth: Double
        let sourceHeight: Double

        if let preferredWindowID {
            guard let window = content.windows.first(where: { $0.windowID == preferredWindowID }) else {
                // Focused-window capture is deliberately fail-closed. Falling
                // back to a display could record unrelated or private pixels.
                throw PassageError.captureUnavailable("The focused window is no longer available")
            }
            let ownerBundle = window.owningApplication?.bundleIdentifier
            guard ownerBundle != ownBundle,
                  ownerBundle.map({ !excludedBundleIdentifiers.contains($0) }) ?? true else {
                throw PassageError.captureUnavailable("The focused window is excluded")
            }
            guard let matchingDisplay = preferredDisplayID.flatMap({ preferred in
                content.displays.first(where: { $0.displayID == preferred })
            }) ?? content.displays.max(by: { first, second in
                intersectionArea(of: first.frame, with: window.frame)
                    < intersectionArea(of: second.frame, with: window.frame)
            }) else {
                throw PassageError.captureUnavailable("No display contains the focused window")
            }
            display = matchingDisplay
            filter = SCContentFilter(desktopIndependentWindow: window)

            let horizontalScale = matchingDisplay.frame.width > 0
                ? Double(matchingDisplay.width) / matchingDisplay.frame.width
                : 1
            let verticalScale = matchingDisplay.frame.height > 0
                ? Double(matchingDisplay.height) / matchingDisplay.frame.height
                : 1
            let backingScale = max(1, min(horizontalScale, verticalScale))
            sourceWidth = max(Double(window.frame.width) * backingScale, 1)
            sourceHeight = max(Double(window.frame.height) * backingScale, 1)
        } else {
            let mainDisplayID = CGMainDisplayID()
            let matchingDisplay: SCDisplay
            if let preferredDisplayID {
                guard let preferred = content.displays.first(where: {
                    $0.displayID == preferredDisplayID
                }) else {
                    // A display-scoped request must not silently jump to another
                    // display while monitors are connecting or disconnecting.
                    throw PassageError.captureUnavailable("The requested display is no longer available")
                }
                matchingDisplay = preferred
            } else {
                guard let fallback = content.displays.first(where: {
                    $0.displayID == mainDisplayID
                }) ?? content.displays.first else {
                    throw PassageError.captureUnavailable("No displays are available")
                }
                matchingDisplay = fallback
            }
            let excludedApplications = content.applications.filter { application in
                application.bundleIdentifier == ownBundle
                    || excludedBundleIdentifiers.contains(application.bundleIdentifier)
            }
            display = matchingDisplay
            filter = SCContentFilter(
                display: matchingDisplay,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            sourceWidth = Double(matchingDisplay.width)
            sourceHeight = Double(matchingDisplay.height)
        }

        let scale = min(1, Double(maximumDimension) / max(sourceWidth, sourceHeight))
        return CaptureTarget(
            filter: filter,
            displayID: display.displayID,
            width: max(Int(sourceWidth * scale), 1),
            height: max(Int(sourceHeight * scale), 1)
        )
    }

    private static func intersectionArea(of first: CGRect, with second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
