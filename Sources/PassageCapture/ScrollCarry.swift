import PassageCore
import CoreGraphics
import Foundation

/// Scroll-aware observation carry between two captures of the same context.
///
/// A scroll changes nearly every pixel row, so band-differential recognition
/// falls back to whole-frame OCR — yet the text itself did not change, it
/// moved. These helpers detect a uniform vertical shift by matching per-row
/// hashes of the full-resolution frames, translate the previous frame's
/// accurate observations by exactly that shift, and leave only genuinely new
/// rows (the revealed strip, changed chrome) for fresh recognition.
///
/// Soundness matches the rest of differential recognition: an observation is
/// carried only when every full-resolution pixel row it covers is
/// byte-identical to the previous frame at its position (fixed content) or
/// at the shifted position (scrolled content). Rows are hashed with the
/// trailing scrollbar sliver excluded — a moving scrollbar thumb must not
/// disqualify otherwise identical rows — and to keep that exclusion honest,
/// the whole optimization aborts when any previous observation extends into
/// that unattested sliver.
enum ScrollCarry {
    /// Trailing device pixels excluded from row hashing: the macOS overlay
    /// scrollbar region. No text observation may overlap it (see `plan`).
    static let trimmedTrailingPixels = 48
    /// Minimum sampled row-hash votes agreeing on one shift before it is
    /// trusted enough to verify exhaustively.
    static let minimumShiftVotes = 24
    /// Rows whose hash occurs more often than this on a side are too generic
    /// (blank space, repeated chrome) to vote for a shift.
    static let maximumHashMultiplicity = 6
    /// Largest detectable shift as a fraction of frame height.
    static let maximumShiftFraction = 0.6
    /// If more than this fraction of rows remains unexplained after the
    /// shift, whole-frame recognition is cheaper and simpler.
    static let maximumUnexplainedFraction = 0.35
    /// Vertical margins around the unexplained rows, as fractions of frame
    /// height; chosen to match band-differential's raster-row margins.
    static let dropMarginFraction = 0.028
    static let cropMarginFraction = 0.049

    struct Plan {
        /// Positive when content moved up (reading forward).
        var shiftPixels: Int
        /// Pixel crop (top-left origin) to recognize, nil when every row is
        /// explained and no fresh recognition is needed.
        var cropRect: CGRect?
        /// Vision-normalized vertical interval whose observations must come
        /// from fresh recognition.
        var dropBand: ClosedRange<Double>
        /// Previous observations carried forward, already translated.
        var carriedRegions: [OCRRegion]
    }

    /// Hashes each pixel row of the image, excluding the trailing sliver.
    /// Returns nil when the backing bytes are unavailable or the image is
    /// too narrow to trim meaningfully.
    static func rowHashes(of image: CGImage) -> [UInt64]? {
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel > 0,
              image.width > trimmedTrailingPixels * 2,
              let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        let hashedBytesPerRow = (image.width - trimmedTrailingPixels) * bytesPerPixel
        guard hashedBytesPerRow > 0,
              bytesPerRow * image.height <= data.count else { return nil }

        var hashes = [UInt64](repeating: 0, count: image.height)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<image.height {
                hashes[row] = Self.hashBytes(
                    base.advanced(by: row * bytesPerRow),
                    count: hashedBytesPerRow
                )
            }
        }
        return hashes
    }

    static func plan(
        previousHashes: [UInt64],
        currentHashes: [UInt64],
        previousRegions: [OCRRegion],
        imageWidth: Int,
        imageHeight: Int
    ) -> Plan? {
        let height = imageHeight
        guard height > 0,
              previousHashes.count == height,
              currentHashes.count == height else { return nil }

        // The sliver is unattested; carrying any observation that overlaps
        // it would claim text whose pixels were never compared.
        let sliverStart = 1 - Double(trimmedTrailingPixels) / Double(imageWidth)
        guard !previousRegions.contains(where: { $0.x + $0.width > sliverStart }) else {
            return nil
        }

        var explainedFixed = [Bool](repeating: false, count: height)
        for row in 0..<height where previousHashes[row] == currentHashes[row] {
            explainedFixed[row] = true
        }

        guard let shift = detectShift(
            previousHashes: previousHashes,
            currentHashes: currentHashes,
            explainedFixed: explainedFixed,
            height: height
        ) else { return nil }

        // current[row] == previous[row + shift]: content moved up by `shift`.
        var explainedMoved = [Bool](repeating: false, count: height)
        for row in 0..<height {
            let source = row + shift
            if source >= 0, source < height, currentHashes[row] == previousHashes[source] {
                explainedMoved[row] = true
            }
        }

        var firstUnexplained = -1
        var lastUnexplained = -1
        var unexplainedCount = 0
        for row in 0..<height where !explainedFixed[row] && !explainedMoved[row] {
            if firstUnexplained < 0 { firstUnexplained = row }
            lastUnexplained = row
            unexplainedCount += 1
        }
        guard Double(unexplainedCount) / Double(height) <= maximumUnexplainedFraction else {
            return nil
        }

        let dropBand: ClosedRange<Double>
        let cropRect: CGRect?
        if firstUnexplained < 0 {
            // Pure scroll: every row is attested somewhere. An empty band
            // below the frame keeps the merge a no-op for fresh regions.
            dropBand = -1.0...(-1.0)
            cropRect = nil
        } else {
            let dropMargin = Int((Double(height) * dropMarginFraction).rounded(.up))
            let cropMargin = Int((Double(height) * cropMarginFraction).rounded(.up))
            let dropTop = max(firstUnexplained - dropMargin, 0)
            let dropBottom = min(lastUnexplained + dropMargin, height - 1)
            let cropTop = max(dropTop - cropMargin, 0)
            let cropBottom = min(dropBottom + cropMargin, height - 1)
            dropBand = Double(height - 1 - dropBottom) / Double(height)
                ... Double(height - dropTop) / Double(height)
            cropRect = CGRect(
                x: 0,
                y: Double(cropTop),
                width: Double(imageWidth),
                height: Double(cropBottom - cropTop + 1)
            )
        }

        let normalizedShift = Double(shift) / Double(height)
        var carried = [OCRRegion]()
        carried.reserveCapacity(previousRegions.count)
        for region in previousRegions {
            guard let span = pixelRowSpan(of: region, imageHeight: height) else { continue }
            if span.allSatisfy({ explainedFixed[$0] }) {
                carried.append(region)
                continue
            }
            let movedSpan = span.compactMap { source -> Int? in
                let destination = source - shift
                return destination >= 0 && destination < height ? destination : nil
            }
            guard movedSpan.count == span.count,
                  movedSpan.allSatisfy({ explainedMoved[$0] }) else { continue }
            var moved = region
            moved.y += normalizedShift
            if moved.y >= -1e-9, moved.y + moved.height <= 1 + 1e-9 {
                carried.append(moved)
            }
        }

        return Plan(
            shiftPixels: shift,
            cropRect: cropRect,
            dropBand: dropBand,
            carriedRegions: carried
        )
    }

    /// Votes for the dominant nonzero shift using distinctive row hashes.
    private static func detectShift(
        previousHashes: [UInt64],
        currentHashes: [UInt64],
        explainedFixed: [Bool],
        height: Int
    ) -> Int? {
        var previousRowsByHash = [UInt64: [Int]]()
        for (row, hash) in previousHashes.enumerated() {
            previousRowsByHash[hash, default: []].append(row)
        }

        let maximumShift = Int(Double(height) * maximumShiftFraction)
        var votes = [Int: Int]()
        var sampled = 0
        var row = 0
        while row < height {
            defer { row += 2 }
            guard !explainedFixed[row],
                  let sources = previousRowsByHash[currentHashes[row]],
                  sources.count <= maximumHashMultiplicity else { continue }
            sampled += 1
            for source in sources {
                let shift = source - row
                guard shift != 0, abs(shift) <= maximumShift else { continue }
                votes[shift, default: 0] += 1
            }
        }
        _ = sampled
        guard let best = votes.max(by: { $0.value < $1.value }),
              best.value >= minimumShiftVotes else { return nil }
        return best.key
    }

    /// Inclusive top-origin pixel rows a normalized (bottom-left origin)
    /// observation covers.
    private static func pixelRowSpan(
        of region: OCRRegion,
        imageHeight: Int
    ) -> ClosedRange<Int>? {
        let height = Double(imageHeight)
        let top = Int((( 1 - (region.y + region.height)) * height).rounded(.down))
        let bottom = Int(((1 - region.y) * height).rounded(.up)) - 1
        let clampedTop = max(top, 0)
        let clampedBottom = min(bottom, imageHeight - 1)
        guard clampedTop <= clampedBottom else { return nil }
        return clampedTop...clampedBottom
    }

    private static func hashBytes(_ base: UnsafeRawPointer, count: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var offset = 0
        while offset + 8 <= count {
            let word = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            hash = (hash ^ word) &* 0x0000_0100_0000_01B3
            offset += 8
        }
        while offset < count {
            let byte = base.load(fromByteOffset: offset, as: UInt8.self)
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            offset += 1
        }
        return hash
    }
}
