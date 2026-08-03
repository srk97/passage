import PassageCore
import Foundation
import Testing

@Suite("Screen context browser identity")
struct ScreenContextTests {
    @Test("Browser families and channel variants share one privacy boundary")
    func knownBrowserIdentifiers() {
        let identifiers = [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.google.Chrome.canary",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.brave.Browser.beta",
            "com.microsoft.edgemac.Dev",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
            "com.operasoftware.OperaGX",
            "org.chromium.Chromium",
            "com.vivaldi.Vivaldi",
            "com.kagi.kagimacOS",
            "app.zen-browser.zen",
        ]

        for identifier in identifiers {
            #expect(ScreenContext.isKnownWebBrowserBundleIdentifier(identifier))
            #expect(ScreenContext(
                applicationName: "Browser",
                bundleIdentifier: identifier
            ).isWebBrowser)
        }
    }

    @Test("Ordinary applications never enter the browser privacy path")
    func rejectsNonBrowsers() {
        #expect(!ScreenContext.isKnownWebBrowserBundleIdentifier("com.apple.Notes"))
        #expect(!ScreenContext.isKnownWebBrowserBundleIdentifier(nil))
    }

    @Test("A discovered web domain remains private even for a new browser bundle")
    func discoveredDomainIsBrowserContext() {
        let context = ScreenContext(
            applicationName: "New Browser",
            bundleIdentifier: "example.new-browser",
            url: URL(string: "https://private.example/notes"),
            domain: "private.example"
        )
        let policy = CapturePolicy(excludedDomains: ["private.example"])

        #expect(context.isWebBrowser)
        #expect(!policy.permits(context))
    }
}
