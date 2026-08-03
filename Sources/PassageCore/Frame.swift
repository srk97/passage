import Foundation

public struct FrameID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

public struct ScreenContext: Codable, Hashable, Sendable {
    public var applicationName: String
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var url: URL?
    public var domain: String?
    public var displayID: UInt32?
    public var windowID: UInt32?
    public var windowBounds: ScreenRect?
    public var isSensitive: Bool

    public init(
        applicationName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        url: URL? = nil,
        domain: String? = nil,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        windowBounds: ScreenRect? = nil,
        isSensitive: Bool = false
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.domain = domain
        self.displayID = displayID
        self.windowID = windowID
        self.windowBounds = windowBounds
        self.isSensitive = isSensitive
    }

    public var isWebBrowser: Bool {
        if domain != nil { return true }
        if let scheme = url?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return true
        }
        return Self.isKnownWebBrowserBundleIdentifier(bundleIdentifier)
    }

    /// A shared browser boundary for capture privacy, URL discovery, and
    /// recall facets. Keeping this list in one place prevents a newer browser
    /// from being recognized by the UI but missed by excluded-domain policy.
    public static func isKnownWebBrowserBundleIdentifier(
        _ bundleIdentifier: String?
    ) -> Bool {
        guard let bundle = bundleIdentifier?.lowercased() else { return false }
        return knownWebBrowserBundleIdentifiers.contains(bundle)
            || knownWebBrowserBundleIdentifierFamilies.contains {
                bundle == $0 || bundle.hasPrefix($0 + ".")
            }
    }

    public static let knownWebBrowserBundleIdentifierFamilies = [
            "com.apple.safari",
            "com.google.chrome",
            "company.thebrowser.browser",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
            "com.operasoftware.opera",
            "org.chromium.chromium",
            "com.vivaldi.vivaldi",
        ]

    public static let knownWebBrowserBundleIdentifiers = [
            "com.apple.safaritechnologypreview",
            "company.thebrowser.dia",
            "company.thebrowser.dia-beta",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
            "com.operasoftware.operagx",
            "com.kagi.kagimacos",
            "ai.perplexity.comet",
            "com.duckduckgo.macos.browser",
            "app.zen-browser.zen",
        ]
}

public struct ScreenRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRRegion: Codable, Hashable, Sendable {
    public var text: String
    public var confidence: Float
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        text: String,
        confidence: Float,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One privacy-filtered semantic item from the focused window's Accessibility
/// tree. `bounds`, when present, are clipped to the focused window and
/// normalized into its `0...1` coordinate space.
public struct AccessibilityNodeEvidence: Codable, Hashable, Sendable {
    public var role: String
    public var label: String?
    public var value: String?
    public var depth: Int
    public var bounds: ScreenRect?

    public init(
        role: String,
        label: String? = nil,
        value: String? = nil,
        depth: Int,
        bounds: ScreenRect? = nil
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.depth = depth
        self.bounds = bounds
    }
}

/// A deliberately bounded semantic snapshot of one focused window.
///
/// `visitedNodeCount` records traversal work, including nodes omitted by
/// privacy and visibility filters. `encodedByteCount` is the size of the
/// canonical payload accepted by the encrypted store. The payload can be
/// truncated by either the traversal or byte ceiling.
public struct AccessibilitySnapshot: Codable, Hashable, Sendable {
    public var nodes: [AccessibilityNodeEvidence]
    public var visitedNodeCount: Int
    public var isTruncated: Bool
    public var encodedByteCount: Int

    public init(
        nodes: [AccessibilityNodeEvidence],
        visitedNodeCount: Int,
        isTruncated: Bool,
        encodedByteCount: Int = 0
    ) {
        self.nodes = nodes
        self.visitedNodeCount = visitedNodeCount
        self.isTruncated = isTruncated
        self.encodedByteCount = encodedByteCount
    }
}

public struct FrameDocument: Codable, Hashable, Sendable, Identifiable {
    public let id: FrameID
    public var capturedAt: Date
    public var context: ScreenContext
    public var ocrText: String
    public var ocrRegions: [OCRRegion]
    public var imageRelativePath: String
    public var thumbnailRelativePath: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var visualFingerprint: UInt64
    public var changeScore: Double
    public var accessibilitySnapshot: AccessibilitySnapshot?

    public init(
        id: FrameID = FrameID(),
        capturedAt: Date,
        context: ScreenContext,
        ocrText: String,
        ocrRegions: [OCRRegion] = [],
        imageRelativePath: String,
        thumbnailRelativePath: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        visualFingerprint: UInt64,
        changeScore: Double,
        accessibilitySnapshot: AccessibilitySnapshot? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.context = context
        self.ocrText = ocrText
        self.ocrRegions = ocrRegions
        self.imageRelativePath = imageRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.visualFingerprint = visualFingerprint
        self.changeScore = changeScore
        self.accessibilitySnapshot = accessibilitySnapshot
    }
}

public struct SearchHit: Codable, Hashable, Sendable, Identifiable {
    public let id: FrameID
    public var activitySessionID: ActivitySessionID?
    public var capturedAt: Date
    public var context: ScreenContext
    public var snippet: String
    public var imageRelativePath: String
    public var thumbnailRelativePath: String?
    public var score: Double

    public init(
        id: FrameID,
        activitySessionID: ActivitySessionID? = nil,
        capturedAt: Date,
        context: ScreenContext,
        snippet: String,
        imageRelativePath: String,
        thumbnailRelativePath: String? = nil,
        score: Double
    ) {
        self.id = id
        self.activitySessionID = activitySessionID
        self.capturedAt = capturedAt
        self.context = context
        self.snippet = snippet
        self.imageRelativePath = imageRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.score = score
    }
}

public struct StoreStatistics: Codable, Hashable, Sendable {
    public var frameCount: Int
    public var oldestCapture: Date?
    public var newestCapture: Date?
    public var databaseBytes: Int64
    public var mediaBytes: Int64

    public init(
        frameCount: Int,
        oldestCapture: Date?,
        newestCapture: Date?,
        databaseBytes: Int64,
        mediaBytes: Int64
    ) {
        self.frameCount = frameCount
        self.oldestCapture = oldestCapture
        self.newestCapture = newestCapture
        self.databaseBytes = databaseBytes
        self.mediaBytes = mediaBytes
    }
}
