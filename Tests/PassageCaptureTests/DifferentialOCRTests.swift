import PassageCore
@testable import PassageCapture
import CoreGraphics
import Foundation
import Testing

@Suite("Differential OCR planning")
struct DifferentialOCRTests {
    @Test("Identical rasters report no change and mismatched sizes report full change")
    func changedRows() {
        let width = 8
        let height = 6
        let base = [UInt8](repeating: 7, count: width * height)
        #expect(DifferentialOCR.changedRowRange(
            previous: base, current: base, width: width, height: height
        ) == nil)

        var oneRow = base
        oneRow[3 * width + 2] = 9
        #expect(DifferentialOCR.changedRowRange(
            previous: base, current: oneRow, width: width, height: height
        ) == 3...3)

        var spread = base
        spread[1 * width] = 1
        spread[4 * width + 5] = 1
        #expect(DifferentialOCR.changedRowRange(
            previous: base, current: spread, width: width, height: height
        ) == 1...4)

        #expect(DifferentialOCR.changedRowRange(
            previous: [], current: base, width: width, height: height
        ) == 0...(height - 1))
    }

    @Test("Band plans add margins, clamp to the raster, and refuse large spans")
    func bandPlanning() {
        let plan = DifferentialOCR.bandPlan(changedRows: 60...62, rasterHeight: 144)
        #expect(plan == DifferentialOCR.BandPlan(
            dropTopRow: 56, dropBottomRow: 66, cropTopRow: 49, cropBottomRow: 73
        ))

        let clamped = DifferentialOCR.bandPlan(changedRows: 0...2, rasterHeight: 144)
        #expect(clamped == DifferentialOCR.BandPlan(
            dropTopRow: 0, dropBottomRow: 6, cropTopRow: 0, cropBottomRow: 13
        ))

        #expect(DifferentialOCR.bandPlan(changedRows: 10...100, rasterHeight: 144) == nil)
    }

    @Test("Crop projection round-trips band observations into full-frame coordinates")
    func projection() {
        let plan = DifferentialOCR.BandPlan(
            dropTopRow: 14, dropBottomRow: 24, cropTopRow: 10, cropBottomRow: 20
        )
        let crop = DifferentialOCR.cropRect(
            plan: plan, rasterHeight: 144, imageWidth: 2_560, imageHeight: 1_440
        )
        #expect(crop == CGRect(x: 0, y: 100, width: 2_560, height: 110))

        let bottomOfCrop = OCRRegion(
            text: "band", confidence: 0.9, x: 0.25, y: 0, width: 0.5, height: 0.2
        )
        let projected = DifferentialOCR.projectedRegions(
            [bottomOfCrop], cropRect: crop, imageHeight: 1_440
        )
        #expect(projected.count == 1)
        // Crop spans image rows 100..<210 (top-origin), so its bottom edge is
        // 210 from the top = (1440-210)/1440 in bottom-origin normalized space.
        #expect(abs(projected[0].y - (1_440.0 - 210.0) / 1_440.0) < 1e-9)
        #expect(abs(projected[0].height - 0.2 * 110.0 / 1_440.0) < 1e-9)
        #expect(projected[0].x == 0.25)
        #expect(projected[0].width == 0.5)
    }

    @Test("Merging partitions carried and fresh observations by the drop band")
    func merging() {
        let dropBand = 0.4...0.6
        let carriedAbove = OCRRegion(text: "above", confidence: 0.9, x: 0, y: 0.7, width: 1, height: 0.05)
        let carriedBelow = OCRRegion(text: "below", confidence: 0.9, x: 0, y: 0.1, width: 1, height: 0.05)
        let carriedInside = OCRRegion(text: "stale", confidence: 0.9, x: 0, y: 0.45, width: 1, height: 0.05)
        let carriedStraddling = OCRRegion(text: "edge", confidence: 0.9, x: 0, y: 0.58, width: 1, height: 0.05)
        let freshInside = OCRRegion(text: "typed", confidence: 0.9, x: 0, y: 0.5, width: 1, height: 0.05)
        let freshMarginOnly = OCRRegion(text: "margin", confidence: 0.9, x: 0, y: 0.65, width: 1, height: 0.05)

        let merged = DifferentialOCR.mergedRegions(
            carried: [carriedAbove, carriedBelow, carriedInside, carriedStraddling],
            fresh: [freshInside, freshMarginOnly],
            dropBand: dropBand
        )
        let texts = Set(merged.map(\.text))
        #expect(texts == ["above", "below", "typed"])
    }

    @Test("Raster rows and CGImage cropping share the top-origin convention")
    func orientationPins() throws {
        // A black stripe in the TOP quarter of the image must change only the
        // TOP rows of the content raster.
        let white = try #require(Self.stripeImage(stripeTopOriginRows: nil))
        let striped = try #require(Self.stripeImage(stripeTopOriginRows: 20..<40))
        let before = FrameFingerprint.contentSignature(white)
        let after = FrameFingerprint.contentSignature(striped)
        let changed = try #require(DifferentialOCR.changedRowRange(
            previous: before.raster,
            current: after.raster,
            width: FrameFingerprint.ContentSignature.rasterWidth,
            height: FrameFingerprint.ContentSignature.rasterHeight
        ))
        // Image is 512×288: stripe rows 20..<40 map to raster rows 10..<20.
        #expect(changed.lowerBound >= 8)
        #expect(changed.upperBound <= 22)

        // Cropping with a top-origin rect must return the stripe itself.
        let cropped = try #require(striped.cropping(
            to: CGRect(x: 0, y: 20, width: 512, height: 20)
        ))
        #expect(Self.meanGray(cropped) < 20)
        let belowStripe = try #require(striped.cropping(
            to: CGRect(x: 0, y: 120, width: 512, height: 20)
        ))
        #expect(Self.meanGray(belowStripe) > 235)
    }

    private static func stripeImage(stripeTopOriginRows: Range<Int>?) -> CGImage? {
        let width = 512
        let height = 288
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let rows = stripeTopOriginRows {
            // CGContext fills in bottom-origin coordinates.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(
                x: 0,
                y: height - rows.upperBound,
                width: width,
                height: rows.count
            ))
        }
        return context.makeImage()
    }

    private static func meanGray(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }
}
