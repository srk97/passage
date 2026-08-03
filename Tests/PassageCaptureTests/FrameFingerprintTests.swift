import PassageCapture
import CoreGraphics
import Foundation
import Testing

@Suite("Visual change detection")
struct FrameFingerprintTests {
    @Test("Identical images produce an identical difference hash")
    func identicalImages() throws {
        let image = try #require(Self.gradient(inverted: false))
        #expect(FrameFingerprint.differenceHash(image) == FrameFingerprint.differenceHash(image))
    }

    @Test("Materially different images have a measurable distance")
    func changedImages() throws {
        let first = try #require(Self.gradient(inverted: false))
        let second = try #require(Self.gradient(inverted: true))
        let distance = FrameFingerprint.distance(
            FrameFingerprint.differenceHash(first),
            FrameFingerprint.differenceHash(second)
        )
        #expect(distance > 40)
    }

    @Test("A small local edit changes the saved-frame signature")
    func localizedChange() throws {
        let first = try #require(Self.localizedEdit(enabled: false))
        let second = try #require(Self.localizedEdit(enabled: true))
        let firstHash = FrameFingerprint.contentHash(first)
        let secondHash = FrameFingerprint.contentHash(second)

        #expect(firstHash == FrameFingerprint.contentHash(first))
        #expect(FrameFingerprint.distance(firstHash, secondHash) >= 4)
    }

    @Test("Detector saves first, changed, and heartbeat frames but skips duplicates")
    func detectorPolicy() async {
        let detector = VisualChangeDetector()
        let base = Date(timeIntervalSince1970: 100)
        let first = await detector.evaluate(fingerprint: 0, context: "A", capturedAt: base, minimumDistance: 4, heartbeat: 30)
        let retryBeforeCommit = await detector.evaluate(fingerprint: 0, context: "A", capturedAt: base.addingTimeInterval(1), minimumDistance: 4, heartbeat: 30)
        await detector.recordPersisted(fingerprint: 0, context: "A", capturedAt: base)
        let duplicate = await detector.evaluate(fingerprint: 0, context: "A", capturedAt: base.addingTimeInterval(2), minimumDistance: 4, heartbeat: 30)
        let contextChange = await detector.evaluate(fingerprint: 0, context: "B", capturedAt: base.addingTimeInterval(4), minimumDistance: 4, heartbeat: 30)
        await detector.recordPersisted(fingerprint: 0, context: "B", capturedAt: base.addingTimeInterval(4))
        let heartbeat = await detector.evaluate(fingerprint: 0, context: "B", capturedAt: base.addingTimeInterval(35), minimumDistance: 4, heartbeat: 30)
        #expect(first.shouldPersist)
        #expect(retryBeforeCommit.shouldPersist)
        #expect(!duplicate.shouldPersist)
        #expect(contextChange.shouldPersist)
        #expect(heartbeat.shouldPersist)
    }

    @Test("A two-state bounce is suppressed until the heartbeat, but a third state persists at once")
    func detectorSuppressesOscillation() async {
        let detector = VisualChangeDetector()
        let base = Date(timeIntervalSince1970: 100)
        await detector.recordPersisted(fingerprint: 1, context: "A", capturedAt: base)
        let blinkOn = await detector.evaluate(fingerprint: 2, context: "A", capturedAt: base.addingTimeInterval(2), minimumDistance: 4, heartbeat: 30)
        #expect(blinkOn.shouldPersist)
        await detector.recordPersisted(fingerprint: 2, context: "A", capturedAt: base.addingTimeInterval(2))

        // The caret blinks straight back to the state saved two frames ago.
        let blinkOff = await detector.evaluate(fingerprint: 1, context: "A", capturedAt: base.addingTimeInterval(4), minimumDistance: 4, heartbeat: 30)
        #expect(!blinkOff.shouldPersist)

        // Genuinely new content is never suppressed.
        let typed = await detector.evaluate(fingerprint: 3, context: "A", capturedAt: base.addingTimeInterval(6), minimumDistance: 4, heartbeat: 30)
        #expect(typed.shouldPersist)

        // The heartbeat still anchors a bounced state.
        let anchored = await detector.evaluate(fingerprint: 1, context: "A", capturedAt: base.addingTimeInterval(40), minimumDistance: 4, heartbeat: 30)
        #expect(anchored.shouldPersist)

        // A context change clears the bounce baseline: the same fingerprint
        // pair in a new window is fresh evidence, not a blink.
        await detector.recordPersisted(fingerprint: 4, context: "B", capturedAt: base.addingTimeInterval(42))
        let newContextReturn = await detector.evaluate(fingerprint: 2, context: "B", capturedAt: base.addingTimeInterval(44), minimumDistance: 4, heartbeat: 30)
        #expect(newContextReturn.shouldPersist)
    }

    private static func gradient(inverted: Bool) -> CGImage? {
        let width = 90
        let height = 80
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((inverted ? width - 1 - x : x) * 255 / (width - 1))
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    private static func localizedEdit(enabled: Bool) -> CGImage? {
        let width = 1_920
        let height = 1_080
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if enabled {
            // Roughly the footprint of one character in a full-size window.
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 947, y: 531, width: 11, height: 21))
        }
        return context.makeImage()
    }
}
