@testable import PassageUI
import PassageVisualSearch
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Memory Lens query crop")
struct MemoryLensQueryTests {
    @Test("Bottom-left normalized bounds select the matching source pixels")
    func bottomLeftCoordinatesArePreserved() throws {
        let source = try Self.quadrantPNG(width: 40, height: 40)
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0,
            y: 0,
            width: 0.5,
            height: 0.5
        ))

        let crop = try MemoryLensQuery.cropSynchronously(
            imageData: source,
            within: bounds
        )
        let color = try Self.sampleCenter(crop)

        #expect(crop.width == 20)
        #expect(crop.height == 20)
        #expect(color.red > 220)
        #expect(color.green < 60)
        #expect(color.blue < 60)
    }

    @Test("Top-right normalized bounds do not use SwiftUI's top-left origin")
    func topRightCoordinatesArePreserved() throws {
        let source = try Self.quadrantPNG(width: 40, height: 40)
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.5,
            y: 0.5,
            width: 0.5,
            height: 0.5
        ))

        let crop = try MemoryLensQuery.cropSynchronously(
            imageData: source,
            within: bounds
        )
        let color = try Self.sampleCenter(crop)

        #expect(color.red > 220)
        #expect(color.green > 220)
        #expect(color.blue < 35)
    }

    @Test("Invalid images and sub-eight-pixel crops fail without fallback")
    func invalidAndTinyQueriesFail() throws {
        let normalBounds = try #require(NormalizedVisualRegionBounds(
            x: 0,
            y: 0,
            width: 0.5,
            height: 0.5
        ))
        #expect(throws: MemoryLensQueryError.self) {
            _ = try MemoryLensQuery.cropSynchronously(
                imageData: Data("not an image".utf8),
                within: normalBounds
            )
        }

        let source = try Self.quadrantPNG(width: 40, height: 40)
        let tinyBounds = try #require(NormalizedVisualRegionBounds(
            x: 0,
            y: 0,
            width: 0.01,
            height: 0.01
        ))
        #expect(throws: MemoryLensQueryError.self) {
            _ = try MemoryLensQuery.cropSynchronously(
                imageData: source,
                within: tinyBounds
            )
        }
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private enum FixtureError: Error {
        case imageCreation
        case imageEncoding
        case imageSampling
    }

    private static func quadrantPNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FixtureError.imageCreation }

        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(
            x: halfWidth,
            y: halfHeight,
            width: halfWidth,
            height: halfHeight
        ))
        guard let image = context.makeImage() else { throw FixtureError.imageCreation }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw FixtureError.imageEncoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.imageEncoding
        }
        return encoded as Data
    }

    private static func sampleCenter(_ image: CGImage) throws -> RGBA {
        var bytes = [UInt8](repeating: 0, count: 4)
        let didDraw = bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard didDraw else { throw FixtureError.imageSampling }
        return RGBA(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}
