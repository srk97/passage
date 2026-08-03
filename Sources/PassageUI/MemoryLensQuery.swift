import PassageCore
import PassageVisualSearch
import CoreGraphics
import CoreImage
import Foundation

/// The durable identity and query-lifetime geometry for a Memory Lens search.
/// The selected pixels themselves remain only in memory and are never stored.
public struct MemoryLensSelectionDescriptor: Equatable, Sendable {
    public let sourceFrameID: FrameID
    public let sourceVisualFingerprint: UInt64
    public let bounds: NormalizedVisualRegionBounds

    public init(
        sourceFrameID: FrameID,
        sourceVisualFingerprint: UInt64,
        bounds: NormalizedVisualRegionBounds
    ) {
        self.sourceFrameID = sourceFrameID
        self.sourceVisualFingerprint = sourceVisualFingerprint
        self.bounds = bounds
    }
}

enum MemoryLensQueryError: LocalizedError {
    case invalidImage
    case selectionTooSmall
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "That saved image could not be opened."
        case .selectionTooSmall:
            "Select a slightly larger area to compare."
        case .cropFailed:
            "Passage could not prepare that selected area."
        }
    }
}

/// Produces a query-only crop from authenticated media bytes.
///
/// Core Image honors the source orientation, the normalized bounds use the
/// same bottom-left coordinate system as visual-region evidence, and the
/// decoded image never leaves process memory.
enum MemoryLensQuery {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
    ])

    static func crop(
        imageData: Data,
        within bounds: NormalizedVisualRegionBounds
    ) async throws -> CGImage {
        let cropTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try cropSynchronously(imageData: imageData, within: bounds)
        }
        return try await withTaskCancellationHandler {
            try await cropTask.value
        } onCancel: {
            cropTask.cancel()
        }
    }

    static func cropSynchronously(
        imageData: Data,
        within bounds: NormalizedVisualRegionBounds
    ) throws -> CGImage {
        try Task.checkCancellation()
        guard !imageData.isEmpty,
              let decoded = CIImage(
                data: imageData,
                options: [.applyOrientationProperty: true]
              ) else {
            throw MemoryLensQueryError.invalidImage
        }
        try Task.checkCancellation()

        let sourceExtent = decoded.extent.integral
        guard sourceExtent.width >= 8, sourceExtent.height >= 8 else {
            throw MemoryLensQueryError.invalidImage
        }
        let normalized = decoded.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.minX,
            y: -sourceExtent.minY
        ))
        let normalizedExtent = CGRect(
            x: 0,
            y: 0,
            width: sourceExtent.width,
            height: sourceExtent.height
        )
        let requested = CGRect(
            x: bounds.x * normalizedExtent.width,
            y: bounds.y * normalizedExtent.height,
            width: bounds.width * normalizedExtent.width,
            height: bounds.height * normalizedExtent.height
        ).integral.intersection(normalizedExtent)
        guard !requested.isNull,
              requested.width >= 8,
              requested.height >= 8 else {
            throw MemoryLensQueryError.selectionTooSmall
        }
        try Task.checkCancellation()
        guard let crop = context.createCGImage(
            normalized.cropped(to: requested),
            from: requested
        ) else {
            throw MemoryLensQueryError.cropFailed
        }
        try Task.checkCancellation()
        return crop
    }
}
