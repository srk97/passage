import PassageCore
import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct OCRResult: Sendable {
    public var text: String
    public var regions: [OCRRegion]

    public init(text: String, regions: [OCRRegion]) {
        self.text = text
        self.regions = regions
    }
}

public enum VisionOCRServiceError: Error, LocalizedError, Sendable {
    case imageDecodingFailed

    public var errorDescription: String? {
        switch self {
        case .imageDecodingFailed:
            "The saved image could not be read for text recognition."
        }
    }
}

public actor VisionOCRService {
    public enum Mode: Sendable {
        case fast
        case accurate
    }

    private static let fastMinimumConfidence: Float = 0.20
    public static let accurateMinimumConfidence: Float = 0.55
    /// Vision's minimum text height is normalized to the input image height.
    /// Callers recognizing a cropped band must scale this up so the absolute
    /// glyph-height floor stays constant — otherwise Vision upsamples the
    /// crop hunting for proportionally tinier text and a small band costs
    /// more inference than the whole frame.
    public static let defaultMinimumTextHeight = 0.008

    typealias ImageRecognizer = @Sendable (CGImage, Mode, [String], Double) throws -> OCRResult

    private let languages: [String]
    private let imageRecognizer: ImageRecognizer

    public init(languages: [String] = ["en-US"]) {
        self.languages = languages
        imageRecognizer = { image, mode, languages, minimumTextHeight in
            try Self.recognize(
                image,
                mode: mode,
                languages: languages,
                minimumTextHeight: minimumTextHeight
            )
        }
    }

    init(
        languages: [String] = ["en-US"],
        imageRecognizer: @escaping ImageRecognizer
    ) {
        self.languages = languages
        self.imageRecognizer = imageRecognizer
    }

    public func recognize(
        _ image: CGImage,
        mode: Mode = .accurate,
        minimumTextHeight: Double = VisionOCRService.defaultMinimumTextHeight
    ) throws -> OCRResult {
        try imageRecognizer(image, mode, languages, minimumTextHeight)
    }

    /// Decodes and recognizes authenticated image bytes entirely in memory.
    /// The actor intentionally remains occupied during Vision's synchronous
    /// request. Callers still suspend off the main actor, while rapid selection
    /// changes cannot leave an unbounded tail of detached, uncancellable Vision
    /// jobs competing with live capture.
    public func recognize(_ imageData: Data, mode: Mode = .accurate) async throws -> OCRResult {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisionOCRServiceError.imageDecodingFailed
        }
        let result = try imageRecognizer(
            image,
            mode,
            languages,
            Self.defaultMinimumTextHeight
        )
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func recognize(
        _ image: CGImage,
        mode: Mode,
        languages: [String],
        minimumTextHeight: Double
    ) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = mode == .fast ? .fast : .accurate
        request.usesLanguageCorrection = mode == .accurate
        request.recognitionLanguages = languages
        request.minimumTextHeight = Float(min(
            max(minimumTextHeight, Self.defaultMinimumTextHeight),
            0.45
        ))

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        let regions = observations.compactMap { observation -> OCRRegion? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let box = observation.boundingBox
            return OCRRegion(
                text: candidate.string,
                confidence: candidate.confidence,
                x: box.minX,
                y: box.minY,
                width: box.width,
                height: box.height
            )
        }
        let minimumConfidence = mode == .accurate
            ? Self.accurateMinimumConfidence
            : Self.fastMinimumConfidence
        return OCRPostProcessor.process(
            regions,
            minimumConfidence: minimumConfidence
        )
    }
}

/// Cleans Vision's line observations without trying to invent corrected text.
///
/// Language correction belongs to Vision, which has the image evidence. This
/// deterministic pass only removes observations that are not useful searchable
/// text, normalizes invisible whitespace, and gives multi-panel app windows a
/// coherent reading order while keeping each observation's original geometry.
enum OCRPostProcessor {
    private static let columnOriginGap = 0.16
    private static let minimumColumnOverlap = 0.30

    static func process(
        _ regions: [OCRRegion],
        minimumConfidence: Float
    ) -> OCRResult {
        let cleaned = regions.enumerated().compactMap { index, region -> IndexedRegion? in
            guard region.confidence >= minimumConfidence,
                  let text = normalizedSearchableText(region.text) else {
                return nil
            }
            var region = region
            region.text = text
            return IndexedRegion(originalIndex: index, region: region)
        }

        let columns = readingOrderColumns(cleaned)
        let ordered = columns.flatMap { $0 }.map(\.region)
        let text = columns
            .map { $0.map(\.region.text).joined(separator: "\n") }
            .joined(separator: "\n\n")
        return OCRResult(text: text, regions: ordered)
    }

    static func normalizedSearchableText(_ source: String) -> String? {
        var sanitized = ""
        sanitized.reserveCapacity(source.utf8.count)
        var pendingSpace = false

        for scalar in source.precomposedStringWithCanonicalMapping.unicodeScalars {
            let category = scalar.properties.generalCategory
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || category == .lineSeparator
                || category == .paragraphSeparator
                || category == .spaceSeparator {
                pendingSpace = !sanitized.isEmpty
                continue
            }
            if category == .control || category == .format || category == .privateUse {
                continue
            }
            if scalar.value == 0xFFFD { // Unicode replacement character
                pendingSpace = !sanitized.isEmpty
                continue
            }
            if pendingSpace {
                sanitized.append(" ")
                pendingSpace = false
            }
            sanitized.unicodeScalars.append(scalar)
        }

        let text = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Punctuation-only OCR is almost always a toolbar icon, cursor, divider,
        // or reaction glyph. It is also not searchable by the FTS tokenizer.
        let containsLetterOrNumber = text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return containsLetterOrNumber ? text : nil
    }

    private static func readingOrderColumns(
        _ regions: [IndexedRegion]
    ) -> [[IndexedRegion]] {
        guard regions.count >= 6 else { return [rowOrdered(regions)] }

        let xOrdered = regions.sorted {
            if $0.region.x != $1.region.x { return $0.region.x < $1.region.x }
            return $0.originalIndex < $1.originalIndex
        }
        var clusters: [[IndexedRegion]] = []
        for region in xOrdered {
            guard let startX = clusters.last?.first?.region.x,
                  region.region.x - startX < columnOriginGap else {
                clusters.append([region])
                continue
            }
            clusters[clusters.count - 1].append(region)
        }

        let minimumRegionCount = max(
            3,
            Int(ceil(Double(regions.count) * 0.08))
        )
        let substantial = clusters.indices.filter {
            clusters[$0].count >= minimumRegionCount
        }
        guard (2...4).contains(substantial.count) else {
            return [rowOrdered(regions)]
        }

        var columns = substantial.map { clusters[$0] }
        for index in clusters.indices where !substantial.contains(index) {
            for region in clusters[index] {
                let destination = columns.indices.min { lhs, rhs in
                    horizontalDistance(region, from: columns[lhs])
                        < horizontalDistance(region, from: columns[rhs])
                } ?? 0
                columns[destination].append(region)
            }
        }
        columns.sort { columnOrigin($0) < columnOrigin($1) }

        for pair in zip(columns, columns.dropFirst()) {
            guard verticalOverlap(pair.0, pair.1) >= minimumColumnOverlap else {
                return [rowOrdered(regions)]
            }
        }
        return columns.map(rowOrdered)
    }

    private static func rowOrdered(_ regions: [IndexedRegion]) -> [IndexedRegion] {
        let verticallyOrdered = regions.sorted { lhs, rhs in
            let lhsCenter = lhs.region.y + lhs.region.height / 2
            let rhsCenter = rhs.region.y + rhs.region.height / 2
            if lhsCenter != rhsCenter { return lhsCenter > rhsCenter }
            if lhs.region.x != rhs.region.x { return lhs.region.x < rhs.region.x }
            return lhs.originalIndex < rhs.originalIndex
        }

        var rows: [[IndexedRegion]] = []
        for region in verticallyOrdered {
            guard let anchor = rows.last?.first else {
                rows.append([region])
                continue
            }
            let anchorCenter = anchor.region.y + anchor.region.height / 2
            let regionCenter = region.region.y + region.region.height / 2
            let tolerance = max(
                0.006,
                min(0.02, max(anchor.region.height, region.region.height) * 0.5)
            )
            if abs(anchorCenter - regionCenter) <= tolerance {
                rows[rows.count - 1].append(region)
            } else {
                rows.append([region])
            }
        }

        return rows.flatMap { row in
            row.sorted { lhs, rhs in
                if lhs.region.x != rhs.region.x { return lhs.region.x < rhs.region.x }
                return lhs.originalIndex < rhs.originalIndex
            }
        }
    }

    private static func horizontalDistance(
        _ region: IndexedRegion,
        from column: [IndexedRegion]
    ) -> Double {
        abs(region.region.x - columnOrigin(column))
    }

    private static func columnOrigin(_ column: [IndexedRegion]) -> Double {
        let xValues = column.map(\.region.x).sorted()
        return xValues[xValues.count / 2]
    }

    private static func verticalOverlap(
        _ lhs: [IndexedRegion],
        _ rhs: [IndexedRegion]
    ) -> Double {
        guard let lhsBottom = lhs.map(\.region.y).min(),
              let lhsTop = lhs.map({ $0.region.y + $0.region.height }).max(),
              let rhsBottom = rhs.map(\.region.y).min(),
              let rhsTop = rhs.map({ $0.region.y + $0.region.height }).max() else {
            return 0
        }
        let overlap = max(0, min(lhsTop, rhsTop) - max(lhsBottom, rhsBottom))
        let shorterHeight = min(lhsTop - lhsBottom, rhsTop - rhsBottom)
        guard shorterHeight > 0 else { return 0 }
        return overlap / shorterHeight
    }

    private struct IndexedRegion {
        var originalIndex: Int
        var region: OCRRegion
    }
}
