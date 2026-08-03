import CryptoKit
import CoreGraphics
import Foundation

public enum FrameFingerprint {
    public static func differenceHash(_ image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for row in 0..<height {
            for column in 0..<(width - 1) {
                let left = pixels[row * width + column]
                let right = pixels[row * width + column + 1]
                if left > right { hash |= bit }
                bit <<= 1
            }
        }
        return hash
    }

    /// A stable, detail-sensitive signature used to decide whether a frame is
    /// worth saving. The older 9x8 perceptual hash is useful for broad visual
    /// resemblance, but it can erase a caret, a typed character, or another
    /// small local edit. Hashing a modest grayscale raster keeps the comparison
    /// cheap while giving those meaningful changes enough spatial resolution.
    /// The downsampled grayscale raster behind the content hash, retained so
    /// change detection can also say *where* a frame changed, not only that
    /// it did. Raster row 0 is the top of the image.
    public struct ContentSignature: Sendable {
        public static let rasterWidth = 256
        public static let rasterHeight = 144

        public var hash: UInt64
        public var raster: [UInt8]
    }

    public static func contentHash(_ image: CGImage) -> UInt64 {
        contentSignature(image).hash
    }

    public static func contentSignature(_ image: CGImage) -> ContentSignature {
        let width = ContentSignature.rasterWidth
        let height = ContentSignature.rasterHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return ContentSignature(hash: 0, raster: pixels) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let digest = SHA256.hash(data: pixels)
        let hash = digest.prefix(MemoryLayout<UInt64>.size).reduce(UInt64.zero) { value, byte in
            (value << 8) | UInt64(byte)
        }
        return ContentSignature(hash: hash, raster: pixels)
    }

    public static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}

public actor VisualChangeDetector {
    public struct Decision: Sendable {
        public var shouldPersist: Bool
        public var distance: Int
        public var normalizedScore: Double

        public init(shouldPersist: Bool, distance: Int, normalizedScore: Double) {
            self.shouldPersist = shouldPersist
            self.distance = distance
            self.normalizedScore = normalizedScore
        }
    }

    private var lastFingerprint: UInt64?
    private var fingerprintBeforeLast: UInt64?
    private var lastContext: String?
    private var lastPersistedAt: Date?

    public init() {}

    public func evaluate(
        fingerprint: UInt64,
        context: String,
        capturedAt: Date,
        minimumDistance: Int,
        heartbeat: TimeInterval
    ) -> Decision {
        guard let previous = lastFingerprint else {
            return Decision(shouldPersist: true, distance: 64, normalizedScore: 1)
        }

        // The content hash is a cryptographic identity, so its bit pattern
        // carries no change magnitude: any real difference flips ~half the
        // bits. Distance is therefore reported as binary — 0 for an
        // identical raster, 64 for a changed one — instead of pretending a
        // Hamming comparison of SHA bits measures how much changed.
        let identicalToLast = fingerprint == previous
        let distance = identicalToLast ? 0 : 64
        let contextChanged = lastContext != context
        let heartbeatElapsed = capturedAt.timeIntervalSince(lastPersistedAt ?? .distantPast) >= heartbeat
        // A screen that flips straight back to the immediately preceding
        // persisted state (caret blink, activity-spinner alternation) adds
        // no new evidence: both states were just saved. Suppressing the
        // bounce avoids re-running OCR, encryption, and indexing several
        // times a minute on an otherwise idle screen, while the heartbeat
        // still anchors the timeline and any third state persists at once.
        let bouncedToPriorState = !identicalToLast && fingerprint == fingerprintBeforeLast
        let shouldPersist = (distance >= minimumDistance && !bouncedToPriorState)
            || contextChanged
            || heartbeatElapsed
        return Decision(
            shouldPersist: shouldPersist,
            distance: distance,
            normalizedScore: Double(distance) / 64
        )
    }

    /// Advances change detection only after the corresponding frame has crossed
    /// Passage's durable repository boundary. Evaluation deliberately does
    /// not mutate this baseline: OCR, final privacy validation, media writing,
    /// or insertion can still fail after a visual change is noticed. Treating
    /// such an attempt as persisted would suppress an identical retry and leave
    /// an avoidable hole in the timeline.
    public func recordPersisted(
        fingerprint: UInt64,
        context: String,
        capturedAt: Date
    ) {
        fingerprintBeforeLast = context == lastContext ? lastFingerprint : nil
        lastFingerprint = fingerprint
        lastContext = context
        lastPersistedAt = capturedAt
    }
}
