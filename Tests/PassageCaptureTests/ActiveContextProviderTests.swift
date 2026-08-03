@testable import PassageCapture
import PassageCore
import CoreGraphics
import Testing

@Suite("Browser context parsing")
struct ActiveContextProviderTests {
    @Test("Address presentation without a scheme becomes a filterable web URL")
    func normalizesBrowserAddresses() {
        #expect(
            ActiveContextProvider.browserAddressURL(
                "localhost:1420/learn/v4/why-shaders"
            )?.absoluteString == "http://localhost:1420/learn/v4/why-shaders"
        )
        #expect(
            ActiveContextProvider.browserAddressURL(
                "www.example.com/project"
            )?.absoluteString == "https://www.example.com/project"
        )
        #expect(
            ActiveContextProvider.browserAddressURL(
                "https://example.com/already-complete"
            )?.host() == "example.com"
        )
    }

    @Test("Search phrases and browser-internal pages are never promoted to source URLs")
    func rejectsNonWebAddresses() {
        #expect(ActiveContextProvider.browserAddressURL("man with glasses") == nil)
        #expect(ActiveContextProvider.browserAddressURL("chrome://settings") == nil)
        #expect(ActiveContextProvider.browserAddressURL("about:blank") == nil)
        #expect(ActiveContextProvider.browserAddressURL("javascript:alert(1)") == nil)
        #expect(ActiveContextProvider.browserAddressURL("") == nil)
    }

    @Test("Browser discovery never enters webpage-owned accessibility controls")
    func webContentIsATrustBoundary() {
        #expect(ActiveContextProvider.browserTraversalDescends(into: "AXGroup"))
        #expect(!ActiveContextProvider.browserTraversalDescends(into: "AXWebArea"))
    }

    @Test("Chrome's observed address control is distinguished from ordinary page input")
    func recognizesChromeAddressIdentity() {
        #expect(ActiveContextProvider.isAddressFieldIdentity("Address and search bar"))
        #expect(!ActiveContextProvider.isAddressFieldIdentity("Ask Waymond…"))
    }

    @Test("Secure fields are removed before semantic evidence can be formed")
    func secureFieldSanitization() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(AccessibilityEvidenceSanitizer.node(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            label: "Password",
            value: "never-store-this",
            depth: 1,
            frame: CGRect(x: 200, y: 200, width: 200, height: 30),
            windowBounds: window,
            isExplicitlyVisible: true
        ) == nil)
        #expect(AccessibilityEvidenceSanitizer.node(
            role: "AXSecureTextField",
            subrole: nil,
            label: "Password",
            value: "never-store-this-either",
            depth: 1,
            frame: CGRect(x: 200, y: 200, width: 200, height: 30),
            windowBounds: window,
            isExplicitlyVisible: true
        ) == nil)
    }

    @Test("Strings and focused-window geometry are normalized and bounded")
    func semanticNormalization() throws {
        let node = try #require(AccessibilityEvidenceSanitizer.node(
            role: "AXButton",
            subrole: nil,
            label: "  Save   draft  ",
            value: String(repeating: "v", count: 700),
            depth: 2,
            frame: CGRect(x: 50, y: 120, width: 100, height: 50),
            windowBounds: CGRect(x: 100, y: 100, width: 200, height: 100),
            isExplicitlyVisible: true
        ))
        #expect(node.label == "Save draft")
        #expect(node.value?.utf8.count == 512)
        #expect(node.bounds == ScreenRect(x: 0, y: 0.2, width: 0.25, height: 0.5))

        #expect(AccessibilityEvidenceSanitizer.node(
            role: "AXButton",
            subrole: nil,
            label: "unsafe\u{0}label",
            value: nil,
            depth: 0,
            frame: CGRect(x: 100, y: 100, width: 10, height: 10),
            windowBounds: CGRect(x: 100, y: 100, width: 200, height: 100),
            isExplicitlyVisible: true
        ) == nil)
    }

    @Test("Semantic payload obeys traversal, depth, and 16 KiB ceilings")
    func accessibilityPayloadLimits() throws {
        let nodes = (0..<250).map { index in
            AccessibilityNodeEvidence(
                role: "AXStaticText",
                label: "\(index)-" + String(repeating: "e", count: 500),
                depth: index % 8,
                bounds: ScreenRect(x: 0, y: 0, width: 1, height: 1)
            )
        }
        let snapshot = try #require(AccessibilityEvidenceSanitizer.boundedSnapshot(
            nodes: nodes,
            visitedNodeCount: 250,
            isTruncated: false
        ))

        #expect(snapshot.visitedNodeCount == 192)
        #expect(snapshot.nodes.count <= 192)
        #expect(snapshot.nodes.allSatisfy { $0.depth <= 7 })
        #expect(snapshot.isTruncated)
        #expect(snapshot.encodedByteCount <= 16 * 1_024)
    }

    @Test("Context-provider default returns no Accessibility evidence")
    func defaultProviderHasNoEvidence() async {
        let provider = ContextOnlyProvider()
        let context = await provider.current()
        #expect(await provider.accessibilitySnapshot(for: context) == nil)
    }
}

private actor ContextOnlyProvider: ActiveContextProviding {
    func current() -> ScreenContext {
        ScreenContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Draft",
            windowID: 7
        )
    }
}
