import PassageVisualSearch
import SwiftUI

/// Pure geometry shared by the Memory Lens canvas and its callers. SwiftUI
/// supplies top-left coordinates while visual search uses a bottom-left unit
/// space, so the conversion belongs at this interaction boundary.
public enum MemoryLensSelectionGeometry {
    /// A selection should remain easy to see and manipulate even when the
    /// initial pointer movement is only a click or a few pixels.
    public static let defaultMinimumTargetSize = CGSize(width: 44, height: 44)

    /// The exact image rect produced by aspect-fitting `imageSize` inside the
    /// caller's container. Letterbox space is deliberately excluded.
    public static func aspectFitFrame(
        imageSize: CGSize,
        in container: CGRect
    ) -> CGRect {
        guard isFinitePositive(imageSize.width),
              isFinitePositive(imageSize.height),
              isFinitePositive(container.width),
              isFinitePositive(container.height),
              container.minX.isFinite,
              container.minY.isFinite else {
            return .zero
        }

        let scale = min(
            container.width / imageSize.width,
            container.height / imageSize.height
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: container.midX - fittedSize.width / 2,
            y: container.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// The live, unexpanded drag rectangle. This is intentionally separate
    /// from `selectionFrame`: the outline must follow every pointer pixel 1:1
    /// while the minimum target size is enforced only when the drag commits.
    public static func dragFrame(
        from start: CGPoint,
        to end: CGPoint,
        in imageFrame: CGRect
    ) -> CGRect? {
        guard isFinite(start),
              isFinite(end),
              isFinitePositive(imageFrame.width),
              isFinitePositive(imageFrame.height),
              imageFrame.minX.isFinite,
              imageFrame.minY.isFinite else {
            return nil
        }
        let clampedStart = clampedPoint(start, to: imageFrame)
        let clampedEnd = clampedPoint(end, to: imageFrame)
        return CGRect(
            x: min(clampedStart.x, clampedEnd.x),
            y: min(clampedStart.y, clampedEnd.y),
            width: abs(clampedEnd.x - clampedStart.x),
            height: abs(clampedEnd.y - clampedStart.y)
        )
    }

    public static func clampedPoint(_ point: CGPoint, to imageFrame: CGRect) -> CGPoint {
        guard isFinite(point),
              isFinitePositive(imageFrame.width),
              isFinitePositive(imageFrame.height),
              imageFrame.minX.isFinite,
              imageFrame.minY.isFinite,
              imageFrame.maxX.isFinite,
              imageFrame.maxY.isFinite else {
            return .zero
        }
        return CGPoint(
            x: min(max(point.x, imageFrame.minX), imageFrame.maxX),
            y: min(max(point.y, imageFrame.minY), imageFrame.maxY)
        )
    }

    /// Returns a standardized top-left selection rect. Both pointer positions
    /// are clamped to the visible image and short drags expand in the drag
    /// direction to the minimum target size. Near an edge, the target slides
    /// inward rather than shrinking or leaving the image.
    public static func selectionFrame(
        from start: CGPoint,
        to end: CGPoint,
        in imageFrame: CGRect,
        minimumTargetSize: CGSize = defaultMinimumTargetSize
    ) -> CGRect? {
        guard isFinite(start),
              isFinite(end),
              isFinitePositive(imageFrame.width),
              isFinitePositive(imageFrame.height),
              imageFrame.minX.isFinite,
              imageFrame.minY.isFinite else {
            return nil
        }

        let minimumWidth = sanitizedMinimum(
            minimumTargetSize.width,
            available: imageFrame.width
        )
        let minimumHeight = sanitizedMinimum(
            minimumTargetSize.height,
            available: imageFrame.height
        )
        let horizontal = axisRange(
            anchor: start.x,
            current: end.x,
            lowerBound: imageFrame.minX,
            upperBound: imageFrame.maxX,
            minimumLength: minimumWidth
        )
        let vertical = axisRange(
            anchor: start.y,
            current: end.y,
            lowerBound: imageFrame.minY,
            upperBound: imageFrame.maxY,
            minimumLength: minimumHeight
        )
        return CGRect(
            x: horizontal.lowerBound,
            y: vertical.lowerBound,
            width: horizontal.upperBound - horizontal.lowerBound,
            height: vertical.upperBound - vertical.lowerBound
        )
    }

    /// Converts a top-left SwiftUI drag into the bottom-left normalized bounds
    /// consumed by visual search.
    public static func normalizedBounds(
        from start: CGPoint,
        to end: CGPoint,
        in imageFrame: CGRect,
        minimumTargetSize: CGSize = defaultMinimumTargetSize
    ) -> NormalizedVisualRegionBounds? {
        guard let selection = selectionFrame(
            from: start,
            to: end,
            in: imageFrame,
            minimumTargetSize: minimumTargetSize
        ) else { return nil }

        let x = Double((selection.minX - imageFrame.minX) / imageFrame.width)
        let top = Double((selection.minY - imageFrame.minY) / imageFrame.height)
        let width = Double(selection.width / imageFrame.width)
        let height = Double(selection.height / imageFrame.height)
        let bottom = 1 - top - height
        return NormalizedVisualRegionBounds(
            x: clampedUnit(x),
            y: clampedUnit(bottom),
            width: min(width, 1),
            height: min(height, 1)
        )
    }

    /// Converts bottom-left normalized bounds back into a top-left overlay
    /// frame inside an already-resolved image frame.
    public static func overlayFrame(
        for bounds: NormalizedVisualRegionBounds,
        in imageFrame: CGRect
    ) -> CGRect {
        guard isFinitePositive(imageFrame.width),
              isFinitePositive(imageFrame.height),
              imageFrame.minX.isFinite,
              imageFrame.minY.isFinite else {
            return .zero
        }
        return CGRect(
            x: imageFrame.minX + imageFrame.width * bounds.x,
            y: imageFrame.minY + imageFrame.height * (1 - bounds.y - bounds.height),
            width: imageFrame.width * bounds.width,
            height: imageFrame.height * bounds.height
        )
    }

    /// Aspect-fit-aware convenience for callers that only know the source
    /// image size and the available canvas.
    public static func overlayFrame(
        for bounds: NormalizedVisualRegionBounds,
        imageSize: CGSize,
        in container: CGRect
    ) -> CGRect {
        overlayFrame(
            for: bounds,
            in: aspectFitFrame(imageSize: imageSize, in: container)
        )
    }

    private static func axisRange(
        anchor: CGFloat,
        current: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat,
        minimumLength: CGFloat
    ) -> ClosedRange<CGFloat> {
        let clampedAnchor = min(max(anchor, lowerBound), upperBound)
        let clampedCurrent = min(max(current, lowerBound), upperBound)
        if abs(clampedCurrent - clampedAnchor) >= minimumLength {
            return min(clampedAnchor, clampedCurrent)...max(clampedAnchor, clampedCurrent)
        }

        if clampedCurrent < clampedAnchor {
            let proposedLower = clampedAnchor - minimumLength
            let lower = max(proposedLower, lowerBound)
            let upper = min(max(clampedAnchor, lower + minimumLength), upperBound)
            return max(lowerBound, upper - minimumLength)...upper
        }

        let proposedUpper = clampedAnchor + minimumLength
        let upper = min(proposedUpper, upperBound)
        let lower = max(min(clampedAnchor, upper - minimumLength), lowerBound)
        return lower...min(upperBound, lower + minimumLength)
    }

    private static func sanitizedMinimum(
        _ proposed: CGFloat,
        available: CGFloat
    ) -> CGFloat {
        guard proposed.isFinite else { return min(1, available) }
        return min(max(proposed, 1), available)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinitePositive(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }

    private static func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Keeps the interactive image and its controls in separate layout regions.
/// The source aspect ratio belongs to the canvas only; controls must never
/// consume image height when the inspector becomes narrow.
enum MemoryLensSelectionLayout {
    static let canvasToControlsSpacing: CGFloat = 12
    static let minimumControlHeight: CGFloat = 44

    static func canvasAspectRatio(imageSize: CGSize) -> CGFloat {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return 1
        }
        return imageSize.width / imageSize.height
    }

    static func canvasSize(
        imageSize: CGSize,
        availableWidth: CGFloat
    ) -> CGSize {
        guard availableWidth.isFinite, availableWidth > 0 else { return .zero }
        return CGSize(
            width: availableWidth,
            height: availableWidth / canvasAspectRatio(imageSize: imageSize)
        )
    }

    static func minimumSurfaceHeight(
        imageSize: CGSize,
        availableWidth: CGFloat
    ) -> CGFloat {
        let canvas = canvasSize(
            imageSize: imageSize,
            availableWidth: availableWidth
        )
        guard canvas.height > 0 else { return 0 }
        return canvas.height + canvasToControlsSpacing + minimumControlHeight
    }
}

enum MemoryLensSelectionPresentation {
    static let cancelTitle = "Cancel"
    static let confirmTitle = "Find this again"
    static let compactConfirmTitle = "Find"
    static let instruction = "Drag over what you want to find"
    static let confirmAccessibilityLabel = "Find moments matching the selected visual detail"
    static let confirmAccessibilityHint = "Searches using only the selected visual detail"
}

/// A self-contained crop-style surface for Memory Lens. It owns no image or
/// repository state: callers provide the visual content and receive only the
/// confirmed query-lifetime bounds.
public struct MemoryLensSelectionSurface<Content: View>: View {
    private let imageSize: CGSize
    private let minimumTargetSize: CGSize
    private let content: Content
    private let onConfirm: (NormalizedVisualRegionBounds) -> Void
    private let onCancel: () -> Void

    @State private var selection: NormalizedVisualRegionBounds?
    @State private var dragAnchor: CGPoint?
    @State private var dragLocation: CGPoint?
    @FocusState private var canvasIsFocused: Bool

    public init(
        imageSize: CGSize,
        initialSelection: NormalizedVisualRegionBounds? = nil,
        minimumTargetSize: CGSize = MemoryLensSelectionGeometry.defaultMinimumTargetSize,
        onConfirm: @escaping (NormalizedVisualRegionBounds) -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.imageSize = imageSize
        self.minimumTargetSize = minimumTargetSize
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.content = content()
        _selection = State(initialValue: initialSelection)
    }

    public var body: some View {
        VStack(spacing: MemoryLensSelectionLayout.canvasToControlsSpacing) {
            GeometryReader { geometry in
                let container = CGRect(origin: .zero, size: geometry.size)
                let imageFrame = MemoryLensSelectionGeometry.aspectFitFrame(
                    imageSize: imageSize,
                    in: container
                )

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.92)

                    content
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .clipped()
                        .position(x: imageFrame.midX, y: imageFrame.midY)

                    if imageFrame.width > 0, imageFrame.height > 0 {
                        selectionMask(imageFrame: imageFrame)

                        Color.clear
                            .frame(width: imageFrame.width, height: imageFrame.height)
                            .contentShape(Rectangle())
                            .position(x: imageFrame.midX, y: imageFrame.midY)
                            .gesture(selectionGesture(imageFrame: imageFrame))
                    }

                    instruction
                        .padding(14)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(dragAnchor == nil ? 0.14 : 0.34), lineWidth: 1)
                }
                .focusable()
                .focused($canvasIsFocused)
                .onExitCommand(perform: cancel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Memory Lens image selection")
                .accessibilityValue(accessibilitySelectionValue)
                .accessibilityHint(
                    "Drag across the image to select a region. Press Escape to cancel."
                )
            }
            .aspectRatio(
                MemoryLensSelectionLayout.canvasAspectRatio(imageSize: imageSize),
                contentMode: .fit
            )
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)

            controls
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            expandedControls
            compactControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedControls: some View {
        HStack(spacing: 10) {
            cancelButton

            Spacer(minLength: 12)

            Text(selection == nil ? "Drag to choose a detail" : "Selection ready")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHidden(true)

            confirmButton(
                title: MemoryLensSelectionPresentation.confirmTitle,
                minimumWidth: 128
            )
        }
    }

    private var compactControls: some View {
        HStack(spacing: 10) {
            cancelButton
            Spacer(minLength: 12)
            confirmButton(
                title: MemoryLensSelectionPresentation.compactConfirmTitle,
                minimumWidth: 82
            )
        }
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Label(MemoryLensSelectionPresentation.cancelTitle, systemImage: "xmark")
                .frame(
                    minWidth: 76,
                    minHeight: MemoryLensSelectionLayout.minimumControlHeight
                )
        }
        .buttonStyle(MemoryLensSecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Cancel Memory Lens selection")
    }

    private func confirmButton(title: String, minimumWidth: CGFloat) -> some View {
        Button {
            if let selection { onConfirm(selection) }
        } label: {
            Label(title, systemImage: "viewfinder")
                .frame(
                    minWidth: minimumWidth,
                    minHeight: MemoryLensSelectionLayout.minimumControlHeight
                )
        }
        .buttonStyle(MemoryLensConfirmButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(selection == nil)
        .accessibilityLabel(MemoryLensSelectionPresentation.confirmAccessibilityLabel)
        .accessibilityHint(MemoryLensSelectionPresentation.confirmAccessibilityHint)
    }

    private var instruction: some View {
        Label(MemoryLensSelectionPresentation.instruction, systemImage: "viewfinder")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(.black.opacity(0.62), in: Capsule())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func selectionMask(imageFrame: CGRect) -> some View {
        if let frame = displayedSelectionFrame(in: imageFrame) {
            if frame.width > 0, frame.height > 0 {
                MemoryLensOutsideSelectionShape(imageFrame: imageFrame, selectionFrame: frame)
                    .fill(.black.opacity(0.38), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(dragAnchor == nil ? 0.035 : 0.075))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white, lineWidth: dragAnchor == nil ? 1.5 : 2)
                    }
                    .shadow(color: .black.opacity(0.32), radius: 8, y: 2)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }

        if let dragLocation {
            let point = MemoryLensSelectionGeometry.clampedPoint(
                dragLocation,
                to: imageFrame
            )
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .overlay { Circle().stroke(.black.opacity(0.5), lineWidth: 1) }
                .position(point)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func displayedSelectionFrame(in imageFrame: CGRect) -> CGRect? {
        if let dragAnchor, let dragLocation {
            return MemoryLensSelectionGeometry.dragFrame(
                from: dragAnchor,
                to: dragLocation,
                in: imageFrame
            )
        }
        return selection.map {
            MemoryLensSelectionGeometry.overlayFrame(for: $0, in: imageFrame)
        }
    }

    private func selectionGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = canvasPoint(value.startLocation, in: imageFrame)
                let current = canvasPoint(value.location, in: imageFrame)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragAnchor = start
                    dragLocation = current
                    canvasIsFocused = true
                    selection = nil
                }
            }
            .onEnded { value in
                let start = dragAnchor ?? canvasPoint(value.startLocation, in: imageFrame)
                let current = canvasPoint(value.location, in: imageFrame)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selection = MemoryLensSelectionGeometry.normalizedBounds(
                        from: start,
                        to: current,
                        in: imageFrame,
                        minimumTargetSize: minimumTargetSize
                    )
                    dragAnchor = nil
                    dragLocation = nil
                }
            }
    }

    /// Gesture locations are local to the fitted hit surface; convert them to
    /// the canvas coordinate space before applying the shared geometry.
    private func canvasPoint(_ localPoint: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + localPoint.x,
            y: imageFrame.minY + localPoint.y
        )
    }

    private func cancel() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragAnchor = nil
            dragLocation = nil
        }
        onCancel()
    }

    private var accessibilitySelectionValue: String {
        if dragAnchor != nil { return "Selecting a region" }
        guard let selection else { return "No region selected" }
        let horizontal = Int((selection.width * 100).rounded())
        let vertical = Int((selection.height * 100).rounded())
        return "Selected region, \(horizontal) percent wide by \(vertical) percent high"
    }
}

private struct MemoryLensOutsideSelectionShape: Shape {
    let imageFrame: CGRect
    let selectionFrame: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRect(imageFrame)
        path.addRoundedRect(
            in: selectionFrame,
            cornerSize: CGSize(width: 8, height: 8)
        )
        return path
    }
}

private struct MemoryLensSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.10)
                    : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
            }
    }
}

private struct MemoryLensConfirmButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.62))
            .padding(.horizontal, 14)
            .background(
                Color.accentColor.opacity(
                    isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.34
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
    }
}
