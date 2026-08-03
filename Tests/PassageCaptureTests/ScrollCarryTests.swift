import PassageCore
@testable import PassageCapture
import CoreGraphics
import Foundation
import Testing

@Suite("Scroll-aware observation carry")
struct ScrollCarryTests {
    private static let height = 1_000
    private static let width = 2_000

    /// Distinct hash per content unit so shifts are unambiguous.
    private static func contentHash(_ unit: Int) -> UInt64 {
        UInt64(bitPattern: Int64(unit)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678
    }

    /// A frame with fixed chrome rows on top, scrollable content below.
    /// `offset` is how far the content has scrolled (in rows).
    private static func hashes(chromeRows: Int, offset: Int) -> [UInt64] {
        (0..<height).map { row in
            row < chromeRows
                ? contentHash(-row - 1)
                : contentHash(row + offset)
        }
    }

    @Test("A uniform scroll is detected, chrome stays, content translates, only the strip is fresh")
    func uniformScroll() throws {
        let chromeRows = 80
        let shift = 120
        let previous = Self.hashes(chromeRows: chromeRows, offset: 0)
        let current = Self.hashes(chromeRows: chromeRows, offset: shift)

        // One observation in fixed chrome, one in scrolled content, chosen so
        // its translated position stays in frame.
        let chromeRegion = OCRRegion(
            text: "toolbar", confidence: 0.9, x: 0.1, y: 0.95, width: 0.3, height: 0.02
        )
        let contentRegion = OCRRegion(
            text: "paragraph", confidence: 0.9, x: 0.1, y: 0.3, width: 0.6, height: 0.03
        )

        let plan = try #require(ScrollCarry.plan(
            previousHashes: previous,
            currentHashes: current,
            previousRegions: [chromeRegion, contentRegion],
            imageWidth: Self.width,
            imageHeight: Self.height
        ))
        #expect(plan.shiftPixels == shift)

        let texts = Dictionary(uniqueKeysWithValues: plan.carriedRegions.map { ($0.text, $0) })
        let carriedChrome = try #require(texts["toolbar"])
        #expect(abs(carriedChrome.y - 0.95) < 1e-9)
        let carriedContent = try #require(texts["paragraph"])
        #expect(abs(carriedContent.y - (0.3 + Double(shift) / Double(Self.height))) < 1e-9)

        // Fresh recognition covers only the revealed strip at the bottom
        // (top-origin rows near the end of the frame), plus margins.
        let crop = try #require(plan.cropRect)
        #expect(crop.minY > Double(Self.height) / 2)
        #expect(crop.maxY <= Double(Self.height))
    }

    @Test("An observation translated out of frame is dropped, not clamped")
    func translationOutOfFrame() throws {
        let shift = 120
        let previous = Self.hashes(chromeRows: 0, offset: 0)
        let current = Self.hashes(chromeRows: 0, offset: shift)
        // Near the top of the screen (high normalized y): moving up by the
        // shift pushes it beyond y + height <= 1.
        let nearTop = OCRRegion(
            text: "leaving", confidence: 0.9, x: 0.1, y: 0.95, width: 0.5, height: 0.03
        )
        let plan = try #require(ScrollCarry.plan(
            previousHashes: previous,
            currentHashes: current,
            previousRegions: [nearTop],
            imageWidth: Self.width,
            imageHeight: Self.height
        ))
        #expect(plan.carriedRegions.isEmpty)
    }

    @Test("Any observation in the unattested scrollbar sliver aborts the carry")
    func sliverAborts() {
        let previous = Self.hashes(chromeRows: 0, offset: 0)
        let current = Self.hashes(chromeRows: 0, offset: 100)
        let sliverRegion = OCRRegion(
            text: "edge", confidence: 0.9, x: 0.95, y: 0.5, width: 0.05, height: 0.03
        )
        #expect(ScrollCarry.plan(
            previousHashes: previous,
            currentHashes: current,
            previousRegions: [sliverRegion],
            imageWidth: Self.width,
            imageHeight: Self.height
        ) == nil)
    }

    @Test("Unrelated frames produce no scroll plan")
    func unrelatedFrames() {
        let previous = (0..<Self.height).map { Self.contentHash($0) }
        let current = (0..<Self.height).map { Self.contentHash($0 + 100_000) }
        #expect(ScrollCarry.plan(
            previousHashes: previous,
            currentHashes: current,
            previousRegions: [],
            imageWidth: Self.width,
            imageHeight: Self.height
        ) == nil)
    }

    @Test("A pure in-place frame needs no fresh recognition band")
    func pureScrollWithoutReveal() throws {
        // Content wraps around so every current row exists in the previous
        // frame: rows are explained by the shift or fixed, nothing revealed.
        let shift = 100
        let previous = (0..<Self.height).map { Self.contentHash($0 % 300) }
        let current = (0..<Self.height).map { Self.contentHash(($0 + shift) % 300) }
        let plan = ScrollCarry.plan(
            previousHashes: previous,
            currentHashes: current,
            previousRegions: [],
            imageWidth: Self.width,
            imageHeight: Self.height
        )
        if let plan {
            #expect(plan.cropRect == nil || plan.cropRect!.height < Double(Self.height) / 2)
        }
    }

    @Test("Row hashing is stable, trim-sensitive, and detects content changes")
    func rowHashing() throws {
        let image = try #require(Self.gradientImage(width: 400, height: 60, seed: 1))
        let same = try #require(Self.gradientImage(width: 400, height: 60, seed: 1))
        let different = try #require(Self.gradientImage(width: 400, height: 60, seed: 2))

        let first = try #require(ScrollCarry.rowHashes(of: image))
        let second = try #require(ScrollCarry.rowHashes(of: same))
        let changed = try #require(ScrollCarry.rowHashes(of: different))
        #expect(first == second)
        #expect(first != changed)
        #expect(first.count == 60)
    }

    private static func gradientImage(width: Int, height: Int, seed: UInt8) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                pixels[row * width + column] = UInt8((row &+ column &* Int(seed)) % 251)
            }
        }
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
