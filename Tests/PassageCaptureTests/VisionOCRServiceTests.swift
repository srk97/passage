@testable import PassageCapture
import PassageCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("Vision OCR post-processing")
struct VisionOCRServiceTests {
    @Test("In-memory OCR rejects bytes that are not a decodable image")
    func rejectsInvalidImageData() async {
        let service = VisionOCRService()
        await #expect(throws: VisionOCRServiceError.self) {
            try await service.recognize(Data("not an image".utf8), mode: .accurate)
        }
    }

    @Test("Rapid in-memory requests cannot accumulate concurrent Vision work")
    func serializesInMemoryRecognition() async throws {
        let recorder = RecognitionConcurrencyRecorder()
        let service = VisionOCRService { _, _, _, _ in
            recorder.withRecognition {
                Thread.sleep(forTimeInterval: 0.015)
                return OCRResult(text: "ok", regions: [])
            }
        }
        let imageData = try Self.testImageData()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try await service.recognize(imageData, mode: .accurate)
                }
            }
            try await group.waitForAll()
        }

        #expect(recorder.maximumConcurrent == 1)
    }

    @Test("Low-confidence and icon-only observations are removed without rewriting code")
    func filtersObviousNoiseConservatively() throws {
        let result = OCRPostProcessor.process(
            [
                region("é- -> O Q Describewh*wuK knkin8for", confidence: 0.50),
                region(">  ~", confidence: 1.0, y: 0.8),
                region("let result = cache[key] ?? fallback()", confidence: 0.99, y: 0.7),
            ],
            minimumConfidence: 0.55
        )

        #expect(result.text == "let result = cache[key] ?? fallback()")
        let retained = try #require(result.regions.first)
        #expect(retained.text == "let result = cache[key] ?? fallback()")
        #expect(retained.confidence == 0.99)
    }

    @Test("Whitespace and invisible OCR artifacts normalize while geometry stays intact")
    func normalizesTextAndPreservesGeometry() throws {
        let source = OCRRegion(
            text: "  func\tload() {\n return Cafe\u{301}\u{200B}  }\u{FFFD} ",
            confidence: 0.98,
            x: 0.17,
            y: 0.61,
            width: 0.42,
            height: 0.04
        )

        let result = OCRPostProcessor.process([source], minimumConfidence: 0.55)
        let retained = try #require(result.regions.first)

        #expect(result.text == "func load() { return Café }")
        #expect(retained.text == "func load() { return Café }")
        #expect(retained.x == source.x)
        #expect(retained.y == source.y)
        #expect(retained.width == source.width)
        #expect(retained.height == source.height)
    }

    @Test("Dense app panels read top-to-bottom before moving across columns")
    func panelAwareReadingOrder() {
        let result = OCRPostProcessor.process(
            [
                region("right three", x: 0.67, y: 0.72),
                region("middle two", x: 0.35, y: 0.81),
                region("left one", x: 0.05, y: 0.90),
                region("right one", x: 0.67, y: 0.92),
                region("left three", x: 0.05, y: 0.70),
                region("middle one", x: 0.35, y: 0.91),
                region("left two", x: 0.05, y: 0.80),
                region("right two", x: 0.67, y: 0.82),
                region("middle three", x: 0.35, y: 0.71),
            ],
            minimumConfidence: 0.55
        )

        #expect(result.regions.map(\.text) == [
            "left one", "left two", "left three",
            "middle one", "middle two", "middle three",
            "right one", "right two", "right three",
        ])
        #expect(result.text == """
        left one
        left two
        left three

        middle one
        middle two
        middle three

        right one
        right two
        right three
        """)
    }

    @Test("Fragments on the same visual line are ordered left-to-right")
    func rowFragmentReadingOrder() {
        let result = OCRPostProcessor.process(
            [
                region("8:35 PM", x: 0.38, y: 0.899, height: 0.018),
                region("next message", x: 0.30, y: 0.84, height: 0.018),
                region("sid", x: 0.30, y: 0.90, height: 0.018),
            ],
            minimumConfidence: 0.55
        )

        #expect(result.regions.map(\.text) == ["sid", "8:35 PM", "next message"])
    }

    private func region(
        _ text: String,
        confidence: Float = 0.99,
        x: Double = 0.1,
        y: Double = 0.9,
        width: Double = 0.2,
        height: Double = 0.02
    ) -> OCRRegion {
        OCRRegion(
            text: text,
            confidence: confidence,
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private static func testImageData() throws -> Data {
        let width = 16
        let height = 16
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw VisionOCRServiceError.imageDecodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw VisionOCRServiceError.imageDecodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VisionOCRServiceError.imageDecodingFailed
        }
        return data as Data
    }
}

private final class RecognitionConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumConcurrent: Int {
        lock.withLock { maximum }
    }

    func withRecognition<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
        defer {
            lock.withLock { active -= 1 }
        }
        return try body()
    }
}
