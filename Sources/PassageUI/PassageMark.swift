import AppKit
import SwiftUI

/// The Passage mark: an arch around a lit doorway, matching the app icon's
/// silhouette.
///
/// The icon's three receding arches collapse into one stroked arch plus the
/// filled doorway here, because nested strokes turn to mush below about 20
/// points. Geometry is normalized to a unit rect with y increasing downward
/// so the same paths serve SwiftUI and the AppKit menu-bar template image.
public enum PassageMark {
    private static let archHalfWidth = 0.40
    private static let archApexTop = 0.13
    private static let doorwayHalfWidth = 0.155
    private static let doorwayApexTop = 0.45
    private static let baseline = 0.93
    /// Stroke width for `archPath`, as a fraction of the smaller dimension.
    public static let strokeFraction = 0.12

    /// The open outer arch, meant to be stroked.
    public static func archPath(in rect: CGRect) -> Path {
        arch(
            in: rect,
            halfWidth: archHalfWidth,
            apexTop: archApexTop,
            closed: false
        )
    }

    /// The inner doorway, meant to be filled.
    public static func doorwayPath(in rect: CGRect) -> Path {
        arch(
            in: rect,
            halfWidth: doorwayHalfWidth,
            apexTop: doorwayApexTop,
            closed: true
        )
    }

    private static func arch(
        in rect: CGRect,
        halfWidth: Double,
        apexTop: Double,
        closed: Bool
    ) -> Path {
        let width = rect.width
        let height = rect.height
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * width, y: rect.minY + y * height)
        }
        // The apex is a semicircle whose radius is the arch half-width, so
        // its center sits one radius below the apex. Using the horizontal
        // extent for the radius keeps the curve circular at any aspect.
        let radius = halfWidth * width
        let centerY = rect.minY + apexTop * height + radius
        let center = CGPoint(x: rect.midX, y: centerY)

        var path = Path()
        path.move(to: point(0.5 - halfWidth, baseline))
        path.addLine(to: CGPoint(x: rect.midX - radius, y: centerY))
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: point(0.5 + halfWidth, baseline))
        if closed {
            path.closeSubpath()
        }
        return path
    }
}

/// The Passage mark as a view. Inherits its color from `foregroundStyle`,
/// so one definition serves the tinted sidebar badge and any monochrome use.
public struct PassageMarkView: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let stroke = min(proxy.size.width, proxy.size.height)
                * PassageMark.strokeFraction
            ZStack {
                PassageMark.archPath(in: rect)
                    .stroke(
                        .foreground,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .butt)
                    )
                PassageMark.doorwayPath(in: rect)
                    .fill(.foreground)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

public extension PassageMark {
    /// A menu-bar template image. macOS tints template images for light,
    /// dark, and highlighted menu bars, so the drawing is pure alpha.
    static func menuBarTemplateImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(
            size: NSSize(width: pointSize, height: pointSize),
            flipped: true
        ) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(min(inset.width, inset.height) * strokeFraction)
            context.setLineCap(.butt)
            context.addPath(archPath(in: inset).cgPath)
            context.strokePath()
            context.addPath(doorwayPath(in: inset).cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
