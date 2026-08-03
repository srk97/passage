import AppKit
import ApplicationServices
import PassageCore
import PassageStore
import CoreGraphics
import Foundation

public actor ActiveContextProvider {
    public init() {}

    public func current() async -> ScreenContext {
        let application = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        guard let application else {
            return ScreenContext(applicationName: "Unknown")
        }

        let metadata = focusedWindowMetadata(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
        let windowServer = windowServerMetadata(
            processIdentifier: application.processIdentifier,
            focusedTitle: metadata.title
        )
        let title = metadata.title ?? windowServer.title
        let url = metadata.url
        return ScreenContext(
            applicationName: application.localizedName ?? "Unknown",
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: title,
            url: url,
            domain: url?.host(percentEncoded: false)?.lowercased(),
            displayID: windowServer.displayID,
            windowID: windowServer.windowID,
            windowBounds: windowServer.bounds,
            isSensitive: Self.isPotentiallySensitive(
                bundleIdentifier: application.bundleIdentifier,
                title: title
            ) || metadata.hasFocusedSecureField
        )
    }

    /// Collects a bounded semantic snapshot only while the same non-sensitive
    /// focused window remains authoritative. Permission is never prompted from
    /// capture; onboarding owns that user-visible decision.
    public func accessibilitySnapshot(
        for context: ScreenContext
    ) async -> AccessibilitySnapshot? {
        await validatedAccessibilityCapture(for: context).snapshot
    }

    /// Same collection, but also hands back the post-walk live context so the
    /// capture pipeline can use it for its final pre-insert validation
    /// instead of enumerating the window server and Accessibility tree again.
    public func validatedAccessibilityCapture(
        for context: ScreenContext
    ) async -> ValidatedAccessibilityCapture {
        guard Self.accessibilityPermissionGranted(), !context.isSensitive else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
        }
        let application = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        guard let application else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
        }

        let before = await current()
        let stillFrontmostBeforeWalk = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
        }
        guard Self.contextsMatchForAccessibility(expected: context, live: before),
              stillFrontmostBeforeWalk,
              application.processIdentifier != 0,
              application.bundleIdentifier == before.bundleIdentifier else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindowValue else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
        }
        let focusedWindow = unsafeDowncast(focusedWindowValue, to: AXUIElement.self)
        guard let windowBounds = Self.elementFrame(focusedWindow)
                ?? Self.cgRect(before.windowBounds)
                ?? Self.cgRect(context.windowBounds),
              windowBounds.width > 0,
              windowBounds.height > 0 else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
        }

        let snapshot = Self.collectAccessibilitySnapshot(
            from: focusedWindow,
            windowBounds: windowBounds
        )
        guard snapshot != nil else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: nil)
        }

        // AX calls can take long enough for a focus change. Recheck after the
        // walk so evidence from the old window can never be attached to pixels
        // labeled with a newly focused or sensitive context.
        let after = await current()
        let stillFrontmostAfterWalk = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
        }
        guard stillFrontmostAfterWalk,
              Self.contextsMatchForAccessibility(expected: context, live: after) else {
            return ValidatedAccessibilityCapture(snapshot: nil, liveContext: after)
        }
        return ValidatedAccessibilityCapture(snapshot: snapshot, liveContext: after)
    }

    public static func accessibilityPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func focusedWindowMetadata(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> (title: String?, url: URL?, hasFocusedSecureField: Bool) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue else {
            return (nil, nil, Self.hasFocusedSecureField(in: applicationElement))
        }

        let windowElement = unsafeDowncast(windowValue, to: AXUIElement.self)
        var titleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        var documentValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            windowElement,
            kAXDocumentAttribute as CFString,
            &documentValue
        )
        let directURL: URL?
        if let value = documentValue as? URL {
            directURL = Self.webURL(value)
        } else if let value = documentValue as? String,
                  let candidate = URL(string: value) {
            directURL = Self.webURL(candidate)
        } else {
            directURL = nil
        }
        let url = directURL ?? Self.browserURL(
            in: windowElement,
            bundleIdentifier: bundleIdentifier
        )
        return (
            titleValue as? String,
            url,
            Self.hasFocusedSecureField(in: applicationElement)
        )
    }

    private func windowServerMetadata(
        processIdentifier: pid_t,
        focusedTitle: String?
    ) -> (
        title: String?,
        displayID: CGDirectDisplayID?,
        windowID: CGWindowID?,
        bounds: ScreenRect?
    ) {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return (nil, nil, nil, nil) }

        let candidates = windows.filter { window in
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            return owner == processIdentifier && layer == 0
        }
        let window = focusedTitle.flatMap { focusedTitle in
            candidates.first { candidate in
                (candidate[kCGWindowName as String] as? String) == focusedTitle
            }
        } ?? candidates.first
        guard let window else { return (nil, nil, nil, nil) }

        let title = window[kCGWindowName as String] as? String
        let displayID: CGDirectDisplayID?
        let bounds: CGRect?
        if let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
           let windowBounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            bounds = windowBounds
            displayID = Self.displayContainingLargestArea(of: windowBounds)
        } else {
            bounds = nil
            displayID = nil
        }
        let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        return (
            title,
            displayID,
            windowID,
            bounds.map {
                ScreenRect(
                    x: $0.origin.x,
                    y: $0.origin.y,
                    width: $0.width,
                    height: $0.height
                )
            }
        )
    }

    /// Accessibility marks password fields with a secure subrole. Treating the
    /// whole foreground context as private means pixels never reach capture,
    /// OCR, hashing, or persistence while one of those fields has focus.
    private static func hasFocusedSecureField(in applicationElement: AXUIElement) -> Bool {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else { return false }

        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success else { return false }
        return (subroleValue as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private static func displayContainingLargestArea(of window: CGRect) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).max { first, second in
            let firstArea = CGDisplayBounds(first).intersection(window)
            let secondArea = CGDisplayBounds(second).intersection(window)
            return firstArea.width * firstArea.height < secondArea.width * secondArea.height
        }
    }

    static func contextsMatchForAccessibility(
        expected: ScreenContext,
        live: ScreenContext
    ) -> Bool {
        guard !expected.isSensitive, !live.isSensitive else { return false }
        if let expectedBundle = expected.bundleIdentifier {
            guard live.bundleIdentifier == expectedBundle else { return false }
        } else {
            guard live.bundleIdentifier == nil,
                  live.applicationName == expected.applicationName else { return false }
        }
        if let expectedTitle = expected.windowTitle {
            guard live.windowTitle == expectedTitle else { return false }
        }
        if let expectedWindowID = expected.windowID {
            return live.windowID == expectedWindowID
        }
        guard let expectedTitle = expected.windowTitle, !expectedTitle.isEmpty else {
            // An app identity alone is not enough to bind AX evidence to one
            // of several open windows.
            return false
        }
        return live.windowTitle == expectedTitle
    }

    private static func collectAccessibilitySnapshot(
        from focusedWindow: AXUIElement,
        windowBounds: CGRect
    ) -> AccessibilitySnapshot? {
        let initial = childElements(
            of: focusedWindow,
            limit: AccessibilitySnapshotCodec.maximumVisitedNodeCount
        )
        var queue = initial.elements.map { (element: $0, depth: 0) }
        var nextIndex = 0
        var visitedElements = [AXUIElement]()
        var nodes = [AccessibilityNodeEvidence]()
        var identities = Set<AccessibilityNodeIdentity>()
        var truncated = initial.wasTruncated

        while nextIndex < queue.count,
              visitedElements.count < AccessibilitySnapshotCodec.maximumVisitedNodeCount {
            let item = queue[nextIndex]
            nextIndex += 1
            guard !visitedElements.contains(where: { CFEqual($0, item.element) }) else {
                continue
            }
            visitedElements.append(item.element)

            let hidden = boolAttribute(kAXHiddenAttribute as String, in: item.element) == true
            let explicitlyVisible = boolAttribute(
                "AXVisible",
                in: item.element
            )
            guard !hidden, explicitlyVisible != false else { continue }

            // Role and subrole are the only attributes read before the secure
            // boundary. Secure fields are neither inspected nor traversed.
            let role = stringAttribute(kAXRoleAttribute, in: item.element)
            let subrole = stringAttribute(kAXSubroleAttribute, in: item.element)
            guard !AccessibilitySnapshotCodec.isSecureRole(role, subrole: subrole) else {
                continue
            }

            let frame = elementFrame(item.element)
            let label = firstStringAttribute(
                [
                    kAXTitleAttribute as String,
                    kAXDescriptionAttribute as String,
                    kAXHelpAttribute as String,
                ],
                in: item.element
            )
            let value = semanticValue(in: item.element)
            if let node = AccessibilityEvidenceSanitizer.node(
                role: role,
                subrole: subrole,
                label: label,
                value: value,
                depth: item.depth,
                frame: frame,
                windowBounds: windowBounds,
                isExplicitlyVisible: explicitlyVisible == true
            ) {
                let identity = AccessibilityNodeIdentity(node: node)
                if identities.insert(identity).inserted {
                    nodes.append(node)
                }
            }

            if item.depth >= AccessibilitySnapshotCodec.maximumDepth {
                if attributeValueCount(kAXChildrenAttribute as String, in: item.element) > 0 {
                    truncated = true
                }
                continue
            }

            let remaining = AccessibilitySnapshotCodec.maximumVisitedNodeCount - queue.count
            if remaining <= 0 {
                if attributeValueCount(kAXChildrenAttribute as String, in: item.element) > 0 {
                    truncated = true
                }
                continue
            }
            let children = childElements(of: item.element, limit: remaining)
            truncated = truncated || children.wasTruncated
            queue.append(contentsOf: children.elements.map {
                (element: $0, depth: item.depth + 1)
            })
        }
        if nextIndex < queue.count { truncated = true }

        return try? AccessibilitySnapshotCodec.boundedSnapshot(
            nodes: nodes,
            visitedNodeCount: visitedElements.count,
            isTruncated: truncated
        )
    }

    private static func firstStringAttribute(
        _ attributes: [String],
        in element: AXUIElement
    ) -> String? {
        for attribute in attributes {
            if let value = stringAttribute(attribute, in: element),
               AccessibilitySnapshotCodec.normalizedText(
                   value,
                   maximumBytes: AccessibilitySnapshotCodec.maximumTextBytes
               ) != nil {
                return value
            }
        }
        return nil
    }

    private static func semanticValue(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success,
        let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(
        _ attribute: String,
        in element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var frameValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            "AXFrame" as CFString,
            &frameValue
        ) == .success,
        let frameValue,
        CFGetTypeID(frameValue) == AXValueGetTypeID() {
            let value = unsafeDowncast(frameValue, to: AXValue.self)
            var frame = CGRect.zero
            if AXValueGetValue(value, .cgRect, &frame),
               frame.width.isFinite, frame.height.isFinite {
                return frame
            }
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAXValue = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func attributeValueCount(
        _ attribute: String,
        in element: AXUIElement
    ) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(
            element,
            attribute as CFString,
            &count
        ) == .success else { return 0 }
        return max(Int(count), 0)
    }

    private static func childElements(
        of element: AXUIElement,
        limit: Int
    ) -> (elements: [AXUIElement], wasTruncated: Bool) {
        let count = attributeValueCount(kAXChildrenAttribute as String, in: element)
        guard count > 0, limit > 0 else {
            return ([], count > 0)
        }
        let requested = min(count, limit)
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            requested,
            &values
        ) == .success,
        let elements = values as? [AXUIElement] else {
            return ([], count > 0)
        }
        return (elements, count > requested)
    }

    private static func cgRect(_ rect: ScreenRect?) -> CGRect? {
        guard let rect,
              [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite) else {
            return nil
        }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func isPotentiallySensitive(bundleIdentifier: String?, title: String?) -> Bool {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        let title = title?.lowercased() ?? ""
        let sensitiveBundles = ["1password", "keychain", "password", "bitwarden", "lastpass"]
        let sensitiveTitles = ["private browsing", "incognito", "passwords", "credit card"]
        return sensitiveBundles.contains(where: bundle.contains)
            || sensitiveTitles.contains(where: title.contains)
    }

    private static func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    /// Chromium and Firefox do not consistently place the active page URL on
    /// the focused window's AXDocument attribute. Search a small, bounded slice
    /// of known browser accessibility trees for either a web-area URL or a
    /// field explicitly identified as an address/location control. Values from
    /// ordinary text and secure fields are never inspected.
    private static func browserURL(
        in windowElement: AXUIElement,
        bundleIdentifier: String?
    ) -> URL? {
        guard isKnownBrowser(bundleIdentifier) else { return nil }
        let maximumElements = 192
        let maximumDepth = 7
        var queue: [(element: AXUIElement, depth: Int)] = [(windowElement, 0)]
        var nextIndex = 0
        var visited = Set<CFHashCode>()

        while nextIndex < queue.count, nextIndex < maximumElements {
            let item = queue[nextIndex]
            nextIndex += 1
            let identity = CFHash(item.element)
            guard visited.insert(identity).inserted else { continue }

            let role = stringAttribute(kAXRoleAttribute, in: item.element)
            if role == "AXWebArea" {
                for attribute in [kAXURLAttribute as String, kAXDocumentAttribute as String] {
                    if let url = urlAttribute(attribute, in: item.element) { return url }
                }
                // Web content is untrusted. Never inspect controls below the
                // web area: a page can label one of its own text fields
                // "address bar", which must not be promoted to source metadata
                // or used to bypass an excluded-domain rule.
            } else if role == kAXTextFieldRole as String,
                      isAddressField(item.element),
                      let value = stringAttribute(kAXValueAttribute, in: item.element),
                      let url = browserAddressURL(value) {
                return url
            }

            guard browserTraversalDescends(into: role),
                  item.depth < maximumDepth,
                  let children = elementsAttribute(kAXChildrenAttribute, in: item.element) else {
                continue
            }
            for child in children.prefix(maximumElements - queue.count) {
                queue.append((child, item.depth + 1))
            }
        }
        return nil
    }

    /// Kept internal so the browser-chrome trust boundary has a deterministic
    /// regression test without requiring a live browser accessibility tree.
    static func browserTraversalDescends(into role: String?) -> Bool {
        role != "AXWebArea"
    }

    private static func isKnownBrowser(_ bundleIdentifier: String?) -> Bool {
        ScreenContext.isKnownWebBrowserBundleIdentifier(bundleIdentifier)
    }

    private static func isAddressField(_ element: AXUIElement) -> Bool {
        let identifyingAttributes = [
            kAXIdentifierAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXTitleAttribute as String,
            kAXRoleDescriptionAttribute as String,
        ]
        let identity = identifyingAttributes
            .compactMap { stringAttribute($0, in: element) }
            .joined(separator: " ")
        return isAddressFieldIdentity(identity)
    }

    static func isAddressFieldIdentity(_ identity: String) -> Bool {
        let normalizedIdentity = identity.lowercased()
        let addressTerms = [
            "address and search",
            "address bar",
            "location bar",
            "location field",
            "omnibox",
            "url field",
            "search or enter",
            "search or type",
        ]
        return addressTerms.contains(where: normalizedIdentity.contains)
    }

    private static func stringAttribute(
        _ attribute: String,
        in element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    private static func urlAttribute(
        _ attribute: String,
        in element: AXUIElement
    ) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return webURL(url) }
        if let string = value as? String { return browserAddressURL(string) }
        return nil
    }

    private static func elementsAttribute(
        _ attribute: String,
        in element: AXUIElement
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? [AXUIElement]
    }

    /// Accepts address-bar presentation that omits the scheme while rejecting
    /// search phrases and browser-internal pages. Kept internal for deterministic
    /// parser tests; capture calls it only after recognizing an address control.
    static func browserAddressURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.properties.isWhitespace }) else {
            return nil
        }
        if let direct = URL(string: value), let web = webURL(direct) { return web }

        let lowercased = value.lowercased()
        let isLocal = lowercased == "localhost"
            || lowercased.hasPrefix("localhost:")
            || lowercased.hasPrefix("localhost/")
            || lowercased == "127.0.0.1"
            || lowercased.hasPrefix("127.0.0.1:")
            || lowercased.hasPrefix("127.0.0.1/")
        let hostCandidate = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let hostWithoutPort = hostCandidate.split(separator: ":", maxSplits: 1).first.map(String.init)
            ?? hostCandidate
        let looksLikePublicHost = hostWithoutPort.contains(".")
            && !hostWithoutPort.hasPrefix(".")
            && !hostWithoutPort.hasSuffix(".")
        guard isLocal || looksLikePublicHost else { return nil }
        let scheme = isLocal ? "http" : "https"
        guard let candidate = URL(string: "\(scheme)://\(value)") else { return nil }
        return webURL(candidate)
    }
}

/// Pure privacy/shape boundary for deterministic tests that do not require a
/// live Accessibility tree.
struct AccessibilityEvidenceSanitizer {
    static func boundedSnapshot(
        nodes: [AccessibilityNodeEvidence],
        visitedNodeCount: Int,
        isTruncated: Bool
    ) -> AccessibilitySnapshot? {
        try? AccessibilitySnapshotCodec.boundedSnapshot(
            nodes: nodes,
            visitedNodeCount: visitedNodeCount,
            isTruncated: isTruncated
        )
    }

    static func node(
        role rawRole: String?,
        subrole: String?,
        label rawLabel: String?,
        value rawValue: String?,
        depth: Int,
        frame: CGRect?,
        windowBounds: CGRect,
        isExplicitlyVisible: Bool
    ) -> AccessibilityNodeEvidence? {
        guard !AccessibilitySnapshotCodec.isSecureRole(rawRole, subrole: subrole),
              depth >= 0,
              depth <= AccessibilitySnapshotCodec.maximumDepth,
              let rawRole,
              let role = AccessibilitySnapshotCodec.normalizedText(
                  rawRole,
                  maximumBytes: AccessibilitySnapshotCodec.maximumRoleBytes
              ) else { return nil }

        let bounds: ScreenRect?
        if let frame {
            guard let normalized = normalizedBounds(frame, within: windowBounds) else {
                return nil
            }
            bounds = normalized
        } else {
            guard isExplicitlyVisible else { return nil }
            bounds = nil
        }

        let label = rawLabel.flatMap {
            AccessibilitySnapshotCodec.normalizedText(
                $0,
                maximumBytes: AccessibilitySnapshotCodec.maximumTextBytes
            )
        }
        var value = rawValue.flatMap {
            AccessibilitySnapshotCodec.normalizedText(
                $0,
                maximumBytes: AccessibilitySnapshotCodec.maximumTextBytes
            )
        }
        if value == label { value = nil }
        guard label != nil || value != nil else { return nil }
        return AccessibilityNodeEvidence(
            role: role,
            label: label,
            value: value,
            depth: depth,
            bounds: bounds
        )
    }

    static func normalizedBounds(
        _ frame: CGRect,
        within windowBounds: CGRect
    ) -> ScreenRect? {
        guard [
            frame.minX, frame.minY, frame.width, frame.height,
            windowBounds.minX, windowBounds.minY,
            windowBounds.width, windowBounds.height,
        ].allSatisfy(\.isFinite),
        frame.width > 0,
        frame.height > 0,
        windowBounds.width > 0,
        windowBounds.height > 0 else { return nil }
        let intersection = frame.intersection(windowBounds)
        guard !intersection.isNull,
              !intersection.isEmpty,
              intersection.width > 0,
              intersection.height > 0 else { return nil }

        let x = min(max((intersection.minX - windowBounds.minX) / windowBounds.width, 0), 1)
        let y = min(max((intersection.minY - windowBounds.minY) / windowBounds.height, 0), 1)
        let width = min(max(intersection.width / windowBounds.width, 0), 1 - x)
        let height = min(max(intersection.height / windowBounds.height, 0), 1 - y)
        guard width > 0, height > 0 else { return nil }
        return ScreenRect(
            x: Double(x),
            y: Double(y),
            width: Double(width),
            height: Double(height)
        )
    }
}

private struct AccessibilityNodeIdentity: Hashable {
    var role: String
    var label: String?
    var value: String?
    var bounds: ScreenRect?

    init(node: AccessibilityNodeEvidence) {
        role = node.role
        label = node.label
        value = node.value
        bounds = node.bounds
    }
}
