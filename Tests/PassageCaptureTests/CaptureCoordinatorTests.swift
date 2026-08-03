@testable import PassageCapture
import PassageCore
import Foundation
import Testing

@Suite("Capture coordinator privacy boundaries")
struct CaptureCoordinatorTests {
    @Test("Host application is recognized before pixels are requested")
    func hostApplicationRecognition() {
        let passage = ScreenContext(
            applicationName: "Passage",
            bundleIdentifier: "app.chronicle.local",
            windowTitle: "Timeline"
        )
        let notes = ScreenContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Draft"
        )

        #expect(CaptureCoordinator.isHostApplication(
            passage,
            hostBundleIdentifier: "app.chronicle.local"
        ))
        #expect(!CaptureCoordinator.isHostApplication(
            notes,
            hostBundleIdentifier: "app.chronicle.local"
        ))
        #expect(!CaptureCoordinator.isHostApplication(
            passage,
            hostBundleIdentifier: nil
        ))
    }

    @Test("Only screenshot availability races are treated as transient")
    func transientFailureClassification() {
        #expect(CaptureCoordinator.isTransientCaptureFailure(
            PassageError.captureUnavailable("The focused window is no longer available")
        ))
        #expect(!CaptureCoordinator.isTransientCaptureFailure(
            PassageError.capturePermissionDenied
        ))
        #expect(!CaptureCoordinator.isTransientCaptureFailure(
            PassageError.database("disk full")
        ))
        #expect(CaptureCoordinator.disposition(forConsecutiveTransientFailures: 1) == .retrying)
        #expect(CaptureCoordinator.disposition(forConsecutiveTransientFailures: 2) == .retrying)
        #expect(CaptureCoordinator.disposition(forConsecutiveTransientFailures: 3) == .actionRequired)
    }

    @Test("Full-display OCR cannot assign a website to the foreground browser")
    func fullDisplayWebsiteInferenceFailsClosed() {
        let browser = ScreenContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let regions = [OCRRegion(
            text: "other-window.example",
            confidence: 0.99,
            x: 0.2,
            y: 0.90,
            width: 0.4,
            height: 0.025
        )]

        #expect(CaptureCoordinator.contextByRecoveringBrowserWebsite(
            browser,
            from: regions,
            captureFocusedWindowOnly: false
        ).domain == nil)
        #expect(CaptureCoordinator.contextByRecoveringBrowserWebsite(
            browser,
            from: regions,
            captureFocusedWindowOnly: true
        ).domain == "other-window.example")

        var trustedSource = browser
        trustedSource.url = URL(string: "https://focused.example/private/path?token=redacted")
        let enrichedTrustedSource = CaptureCoordinator.contextByRecoveringBrowserWebsite(
            trustedSource,
            from: regions,
            captureFocusedWindowOnly: false
        )
        #expect(enrichedTrustedSource.domain == "focused.example")
        #expect(enrichedTrustedSource.url == trustedSource.url)
    }
}
