@testable import PassageCore
import Testing

@Suite("Browser website metadata")
struct BrowserWebsiteMetadataTests {
    @Test("A high-confidence browser-chrome address repairs a missing domain")
    func enrichesMissingDomain() {
        let context = ScreenContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        let enriched = BrowserWebsiteMetadata.enriching(
            context,
            from: [region("www.youtube.com/watch?v=example", y: 0.93)]
        )

        #expect(enriched.domain == "www.youtube.com")
        #expect(enriched.url == nil)
    }

    @Test("Page text, noisy OCR, and non-browser apps are never promoted")
    func rejectsUntrustedCandidates() {
        let browser = ScreenContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let ordinaryApp = ScreenContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let candidates = [
            region("page.example", confidence: 0.99, y: 0.40),
            region("noisy.example", confidence: 0.50, y: 0.94),
            region("man with glasses", confidence: 0.99, y: 0.95),
        ]

        #expect(BrowserWebsiteMetadata.enriching(browser, from: candidates).domain == nil)
        #expect(BrowserWebsiteMetadata.enriching(
            ordinaryApp,
            from: [region("www.example.com", y: 0.95)]
        ).domain == nil)
    }

    @Test("A tab title above the address band cannot replace the active website")
    func ignoresInactiveTabDomain() {
        let browser = ScreenContext(
            applicationName: "Chrome",
            bundleIdentifier: "com.google.Chrome"
        )
        let regions = [
            region("wrong.example", y: 0.965),
            region("youtube.com/watch?v=example", y: 0.90),
        ]

        #expect(BrowserWebsiteMetadata.enriching(browser, from: regions).domain
            == "youtube.com")
    }

    @Test("Ambiguous browser chrome and filename-like text fail closed")
    func rejectsAmbiguousChromeAndFilenames() {
        let browser = ScreenContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        #expect(BrowserWebsiteMetadata.enriching(browser, from: [
            region("first.example", y: 0.90),
            region("second.example", y: 0.92),
        ]).domain == nil)
        #expect(BrowserWebsiteMetadata.enriching(
            browser,
            from: [region("index.html", y: 0.91)]
        ).domain == nil)
        #expect(BrowserWebsiteMetadata.enriching(
            browser,
            from: [region("page.example", y: 0.80)]
        ).domain == nil)
    }

    @Test("Existing source metadata wins over OCR inference")
    func preservesExistingMetadata() {
        let context = ScreenContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            domain: "trusted.example"
        )

        let enriched = BrowserWebsiteMetadata.enriching(
            context,
            from: [region("other.example", y: 0.95)]
        )

        #expect(enriched.domain == "trusted.example")
    }

    @Test("Local development addresses remain filterable")
    func supportsLocalhost() {
        #expect(BrowserWebsiteMetadata.domainCandidate(
            "localhost:1420/learn/v4/session"
        ) == "localhost")
        #expect(BrowserWebsiteMetadata.domainCandidate("chrome://settings") == nil)
        #expect(BrowserWebsiteMetadata.domainCandidate("name@example.com") == nil)
    }

    private func region(
        _ text: String,
        confidence: Float = 0.99,
        y: Double
    ) -> OCRRegion {
        OCRRegion(
            text: text,
            confidence: confidence,
            x: 0.2,
            y: y,
            width: 0.5,
            height: 0.025
        )
    }
}
