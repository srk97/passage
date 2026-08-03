import PassageCore
import CoreGraphics
import Foundation

/// Plans banded "differential" text recognition between two captures of the
/// same context.
///
/// Recognition cost scales with frame area, but consecutive saved moments
/// usually differ in a narrow horizontal band (typing, a status change, a
/// small panel update). The change raster already decides *whether* a frame
/// persists; these helpers reuse it to decide *where* recognition must run.
/// Regions over unchanged raster rows keep the previous frame's accurate
/// observations verbatim — the existing dedup gate already treats
/// raster-identical pixels as an unchanged screen, so carrying their text is
/// exactly as sound as skipping the frame would have been. This is a cost
/// optimization only: the same accurate recognition runs over every changed
/// pixel, and whole-frame recognition still anchors context switches, large
/// changes, and a periodic interval.
enum DifferentialOCR {
    /// Extra raster rows around the changed span that are re-recognized, so
    /// a text line straddling the change boundary is never stitched from two
    /// passes. Four rows of the 144-row raster is ~2.8% of frame height —
    /// more than one ordinary text line.
    static let dropMarginRows = 4
    /// Additional rows included in the recognition crop beyond the drop
    /// band, so any observation intersecting the drop band lies fully inside
    /// the cropped pixels rather than being clipped at the crop edge.
    static let cropMarginRows = 7
    /// Above this fraction of frame height, banding saves too little and
    /// whole-frame recognition runs instead (scrolls, page loads).
    static let wholeFrameSpanFraction = 0.5
    /// Every Nth consecutive differential frame re-runs whole-frame
    /// recognition as drift insurance.
    static let anchorInterval = 25

    struct BandPlan: Equatable, Sendable {
        /// Raster rows (top-origin, inclusive) whose observations must be
        /// replaced by fresh recognition.
        var dropTopRow: Int
        var dropBottomRow: Int
        /// Raster rows (top-origin, inclusive) of the pixels recognized.
        var cropTopRow: Int
        var cropBottomRow: Int
    }

    /// The inclusive top-origin range of raster rows whose bytes differ, or
    /// nil when the rasters are byte-identical.
    static func changedRowRange(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int
    ) -> ClosedRange<Int>? {
        guard previous.count == width * height,
              current.count == width * height else {
            return 0...(height - 1)
        }
        var first = -1
        var last = -1
        for row in 0..<height {
            let start = row * width
            let range = start..<(start + width)
            if !previous[range].elementsEqual(current[range]) {
                if first < 0 { first = row }
                last = row
            }
        }
        guard first >= 0 else { return nil }
        return first...last
    }

    /// Nil when the change spans too much of the frame for banding to help.
    static func bandPlan(changedRows: ClosedRange<Int>, rasterHeight: Int) -> BandPlan? {
        let spanFraction = Double(changedRows.count) / Double(rasterHeight)
        guard spanFraction <= wholeFrameSpanFraction else { return nil }
        let dropTop = max(changedRows.lowerBound - dropMarginRows, 0)
        let dropBottom = min(changedRows.upperBound + dropMarginRows, rasterHeight - 1)
        return BandPlan(
            dropTopRow: dropTop,
            dropBottomRow: dropBottom,
            cropTopRow: max(dropTop - cropMarginRows, 0),
            cropBottomRow: min(dropBottom + cropMarginRows, rasterHeight - 1)
        )
    }

    /// Converts inclusive top-origin raster rows into the Vision-normalized
    /// (bottom-left origin) vertical interval they cover.
    static func normalizedBand(
        topRow: Int,
        bottomRow: Int,
        rasterHeight: Int
    ) -> ClosedRange<Double> {
        let low = Double(rasterHeight - 1 - bottomRow) / Double(rasterHeight)
        let high = Double(rasterHeight - topRow) / Double(rasterHeight)
        return low...high
    }

    /// The pixel crop for a plan, in `CGImage.cropping` coordinates
    /// (top-left origin).
    static func cropRect(
        plan: BandPlan,
        rasterHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let top = (Double(imageHeight) * Double(plan.cropTopRow) / Double(rasterHeight))
            .rounded(.down)
        let bottom = (Double(imageHeight) * Double(plan.cropBottomRow + 1) / Double(rasterHeight))
            .rounded(.up)
        let clampedBottom = min(bottom, Double(imageHeight))
        return CGRect(
            x: 0,
            y: top,
            width: Double(imageWidth),
            height: clampedBottom - top
        )
    }

    /// Projects observations recognized inside the crop back into full-frame
    /// normalized coordinates.
    static func projectedRegions(
        _ regions: [OCRRegion],
        cropRect: CGRect,
        imageHeight: Int
    ) -> [OCRRegion] {
        let fullHeight = Double(imageHeight)
        guard fullHeight > 0, cropRect.height > 0 else { return [] }
        let cropBottomNormalized = (fullHeight - cropRect.maxY) / fullHeight
        let scale = cropRect.height / fullHeight
        return regions.map { region in
            var projected = region
            projected.y = cropBottomNormalized + region.y * scale
            projected.height = region.height * scale
            return projected
        }
    }

    /// Carries forward previous observations lying entirely outside the drop
    /// band and adopts fresh ones intersecting it. The two sets partition by
    /// the same predicate, so no observation is double-counted or lost.
    static func mergedRegions(
        carried: [OCRRegion],
        fresh: [OCRRegion],
        dropBand: ClosedRange<Double>
    ) -> [OCRRegion] {
        func outsideDropBand(_ region: OCRRegion) -> Bool {
            region.y >= dropBand.upperBound
                || (region.y + region.height) <= dropBand.lowerBound
        }
        return carried.filter(outsideDropBand) + fresh.filter { !outsideDropBand($0) }
    }
}
