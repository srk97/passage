@testable import PassageUI
import PassageVisualSearch
import CoreGraphics
import Testing

@Suite("Memory Lens selection geometry")
struct MemoryLensSelectionTests {
    @Test("Aspect fitting excludes horizontal and vertical letterboxing")
    func aspectFitFrame() {
        let landscape = MemoryLensSelectionGeometry.aspectFitFrame(
            imageSize: CGSize(width: 1_600, height: 900),
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        expectRect(
            landscape,
            equals: CGRect(x: 0, y: 87.5, width: 400, height: 225)
        )

        let portrait = MemoryLensSelectionGeometry.aspectFitFrame(
            imageSize: CGSize(width: 600, height: 1_200),
            in: CGRect(x: 20, y: 30, width: 300, height: 200)
        )
        expectRect(
            portrait,
            equals: CGRect(x: 120, y: 30, width: 100, height: 200)
        )
    }

    @Test("Top-left drag converts to bottom-left normalized bounds")
    func topLeftToBottomLeftConversion() throws {
        let bounds = try #require(MemoryLensSelectionGeometry.normalizedBounds(
            from: CGPoint(x: 300, y: 100),
            to: CGPoint(x: 700, y: 250),
            in: CGRect(x: 100, y: 50, width: 800, height: 400),
            minimumTargetSize: CGSize(width: 1, height: 1)
        ))

        expect(bounds.x, equals: 0.25)
        expect(bounds.y, equals: 0.50)
        expect(bounds.width, equals: 0.50)
        expect(bounds.height, equals: 0.375)
    }

    @Test("Reverse drag selects the same region")
    func reverseDrag() throws {
        let imageFrame = CGRect(x: 100, y: 50, width: 800, height: 400)
        let forward = try #require(MemoryLensSelectionGeometry.normalizedBounds(
            from: CGPoint(x: 300, y: 100),
            to: CGPoint(x: 700, y: 250),
            in: imageFrame,
            minimumTargetSize: CGSize(width: 1, height: 1)
        ))
        let reverse = try #require(MemoryLensSelectionGeometry.normalizedBounds(
            from: CGPoint(x: 700, y: 250),
            to: CGPoint(x: 300, y: 100),
            in: imageFrame,
            minimumTargetSize: CGSize(width: 1, height: 1)
        ))

        #expect(reverse == forward)
    }

    @Test("Live drag geometry follows the pointer without minimum-size easing")
    func liveDragTracksPointerOneToOne() throws {
        let imageFrame = CGRect(x: 100, y: 50, width: 800, height: 400)
        let first = try #require(MemoryLensSelectionGeometry.dragFrame(
            from: CGPoint(x: 300, y: 100),
            to: CGPoint(x: 307, y: 103),
            in: imageFrame
        ))
        let next = try #require(MemoryLensSelectionGeometry.dragFrame(
            from: CGPoint(x: 300, y: 100),
            to: CGPoint(x: 308, y: 104),
            in: imageFrame
        ))

        expectRect(first, equals: CGRect(x: 300, y: 100, width: 7, height: 3))
        expectRect(next, equals: CGRect(x: 300, y: 100, width: 8, height: 4))
    }

    @Test("Live reverse drag follows the pointer and clamps at image edges")
    func liveReverseDragTracksPointerAndClamps() throws {
        let frame = try #require(MemoryLensSelectionGeometry.dragFrame(
            from: CGPoint(x: 70, y: 60),
            to: CGPoint(x: -20, y: 500),
            in: CGRect(x: 10, y: 20, width: 100, height: 80)
        ))
        expectRect(frame, equals: CGRect(x: 10, y: 60, width: 60, height: 40))
    }

    @Test("Pointers clamp to the visible image rather than letterbox space")
    func clamping() throws {
        let imageFrame = CGRect(x: 100, y: 50, width: 800, height: 400)
        let bounds = try #require(MemoryLensSelectionGeometry.normalizedBounds(
            from: CGPoint(x: -500, y: -500),
            to: CGPoint(x: 5_000, y: 5_000),
            in: imageFrame
        ))

        expect(bounds.x, equals: 0)
        expect(bounds.y, equals: 0)
        expect(bounds.width, equals: 1)
        expect(bounds.height, equals: 1)
    }

    @Test("Small targets expand inward at image edges")
    func minimumTargetSize() throws {
        let imageFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let bottomRight = try #require(MemoryLensSelectionGeometry.selectionFrame(
            from: CGPoint(x: 95, y: 95),
            to: CGPoint(x: 96, y: 96),
            in: imageFrame,
            minimumTargetSize: CGSize(width: 20, height: 20)
        ))
        expectRect(
            bottomRight,
            equals: CGRect(x: 80, y: 80, width: 20, height: 20)
        )

        let topLeftReverse = try #require(MemoryLensSelectionGeometry.selectionFrame(
            from: CGPoint(x: 5, y: 5),
            to: CGPoint(x: 4, y: 4),
            in: imageFrame,
            minimumTargetSize: CGSize(width: 20, height: 20)
        ))
        expectRect(
            topLeftReverse,
            equals: CGRect(x: 0, y: 0, width: 20, height: 20)
        )

        let defaultTarget = try #require(MemoryLensSelectionGeometry.selectionFrame(
            from: CGPoint(x: 40, y: 40),
            to: CGPoint(x: 41, y: 41),
            in: imageFrame
        ))
        expectRect(
            defaultTarget,
            equals: CGRect(x: 40, y: 40, width: 44, height: 44)
        )
    }

    @Test("Minimum targets never exceed a small image")
    func minimumTargetClampsToImageSize() throws {
        let frame = try #require(MemoryLensSelectionGeometry.selectionFrame(
            from: CGPoint(x: 5, y: 4),
            to: CGPoint(x: 5, y: 4),
            in: CGRect(x: 0, y: 0, width: 12, height: 8),
            minimumTargetSize: CGSize(width: 44, height: 44)
        ))
        expectRect(frame, equals: CGRect(x: 0, y: 0, width: 12, height: 8))
    }

    @Test("Overlay geometry honors aspect fitting and the vertical origin flip")
    func aspectFitOverlay() throws {
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.25,
            y: 0.10,
            width: 0.50,
            height: 0.25
        ))
        let overlay = MemoryLensSelectionGeometry.overlayFrame(
            for: bounds,
            imageSize: CGSize(width: 1_600, height: 900),
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        expectRect(
            overlay,
            equals: CGRect(x: 100, y: 233.75, width: 200, height: 56.25)
        )
    }

    @Test("Invalid geometry fails closed")
    func invalidGeometry() {
        #expect(MemoryLensSelectionGeometry.aspectFitFrame(
            imageSize: .zero,
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        ) == .zero)
        #expect(MemoryLensSelectionGeometry.normalizedBounds(
            from: CGPoint(x: CGFloat.nan, y: 0),
            to: .zero,
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        ) == nil)
        #expect(MemoryLensSelectionGeometry.selectionFrame(
            from: .zero,
            to: CGPoint(x: 10, y: 10),
            in: .zero
        ) == nil)
    }

    @Test("Controls do not consume a 16:10 canvas at minimum inspector width")
    func canvasLayoutPreservesSourceAspectRatio() {
        let canvas = MemoryLensSelectionLayout.canvasSize(
            imageSize: CGSize(width: 1_600, height: 1_000),
            availableWidth: 332
        )

        expectSize(canvas, equals: CGSize(width: 332, height: 207.5))
        expect(
            Double(MemoryLensSelectionLayout.minimumSurfaceHeight(
                imageSize: CGSize(width: 1_600, height: 1_000),
                availableWidth: 332
            )),
            equals: 263.5
        )
    }

    @Test("Ultrawide canvases keep their source ratio above independent controls")
    func ultrawideCanvasLayout() {
        let imageSize = CGSize(width: 3_440, height: 1_440)
        let canvas = MemoryLensSelectionLayout.canvasSize(
            imageSize: imageSize,
            availableWidth: 332
        )

        expectSize(
            canvas,
            equals: CGSize(
                width: 332,
                height: CGFloat(332) / (CGFloat(3_440) / CGFloat(1_440))
            )
        )
        expect(
            Double(MemoryLensSelectionLayout.minimumSurfaceHeight(
                imageSize: imageSize,
                availableWidth: 332
            )),
            equals: Double(canvas.height + 56)
        )
    }

    @Test("Invalid source dimensions use a stable square canvas")
    func invalidCanvasLayoutIsStable() {
        #expect(MemoryLensSelectionLayout.canvasAspectRatio(imageSize: .zero) == 1)
        expectSize(
            MemoryLensSelectionLayout.canvasSize(
                imageSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
                availableWidth: 332
            ),
            equals: CGSize(width: 332, height: 332)
        )
        #expect(MemoryLensSelectionLayout.canvasSize(
            imageSize: CGSize(width: 1_600, height: 1_000),
            availableWidth: CGFloat.nan
        ) == .zero)
    }

    @Test("Memory Lens describes visual matching without identity claims")
    func visualMatchingCopyIsTruthful() {
        #expect(MemoryLensSelectionPresentation.confirmTitle == "Find this again")
        #expect(MemoryLensSelectionPresentation.compactConfirmTitle == "Find")
        #expect(MemoryLensSelectionPresentation.confirmAccessibilityLabel.contains("visual detail"))
        #expect(!MemoryLensSelectionPresentation.confirmAccessibilityLabel.lowercased().contains("identify"))
        #expect(!MemoryLensSelectionPresentation.confirmAccessibilityHint.lowercased().contains("person"))
    }

    private func expectRect(
        _ actual: CGRect,
        equals expected: CGRect,
        tolerance: CGFloat = 0.000_001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual.minX - expected.minX) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.minY - expected.minY) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.width - expected.width) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.height - expected.height) <= tolerance, sourceLocation: sourceLocation)
    }

    private func expectSize(
        _ actual: CGSize,
        equals expected: CGSize,
        tolerance: CGFloat = 0.000_001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual.width - expected.width) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.height - expected.height) <= tolerance, sourceLocation: sourceLocation)
    }

    private func expect(
        _ actual: Double,
        equals expected: Double,
        tolerance: Double = 0.000_001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= tolerance, sourceLocation: sourceLocation)
    }
}
