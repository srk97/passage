@testable import PassageVisualSearch
import PassageCore
import PassageVisualModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Query-time visual region reranking")
struct VisualRegionRerankingTests {
    @Test("Person and appearance intent uses exact tokens and generic geometry")
    func queryIntentIsBoundedAndExact() {
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "a man") == [.person])
        #expect(
            VisualRegionQueryEligibility.requestedKinds(for: "a man with glasses")
                == [.face, .person]
        )
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "eyeglasses") == [.face])
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "red shirt") == [.person])
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "manual") == [])
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "personality") == [])
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "womanizer") == [])
        #expect(VisualRegionQueryEligibility.requestedKinds(for: "walnut desk") == [])
    }

    @Test("Only measured man intents use narrower similarity thresholds")
    func calibratedThresholdsStayNarrow() {
        #expect(
            VisualRegionQueryEligibility.similarityThresholds(for: "a man")
                == VisualRegionSimilarityThresholds(
                    minimumSimilarity: 0.245,
                    minimumGain: 0.003
                )
        )
        #expect(
            VisualRegionQueryEligibility.similarityThresholds(
                for: "a man with glasses"
            ) == VisualRegionSimilarityThresholds(
                minimumSimilarity: 0.26,
                minimumGain: 0.01
            )
        )
        #expect(
            VisualRegionQueryEligibility.similarityThresholds(
                for: "a woman with glasses"
            ) == VisualRegionSimilarityThresholds(
                minimumSimilarity: 0.275,
                minimumGain: 0.02
            )
        )
        #expect(
            VisualRegionQueryEligibility.similarityThresholds(for: "manual")
                == VisualRegionSimilarityThresholds(
                    minimumSimilarity: 0.275,
                    minimumGain: 0.02
                )
        )
    }

    @Test("Progressive refinement defaults below one second and cannot exceed it")
    func deadlinePolicyIsTightlyBounded() {
        #expect(VisualRegionRerankingPolicy().maximumDurationMilliseconds == 850)
        #expect(
            VisualRegionRerankingPolicy(maximumDurationMilliseconds: 50_000)
                .maximumDurationMilliseconds == 1_000
        )
    }

    @Test("Padded region bounds clamp to every image edge")
    func paddedBoundsClamp() throws {
        let center = try #require(VisionVisualRegionProcessor.paddedBounds(
            CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            factor: 2
        ))
        #expect(abs(center.x - 0.3) < 0.000_001)
        #expect(abs(center.y - 0.3) < 0.000_001)
        #expect(abs(center.width - 0.4) < 0.000_001)
        #expect(abs(center.height - 0.4) < 0.000_001)

        let edge = try #require(VisionVisualRegionProcessor.paddedBounds(
            CGRect(x: 0.92, y: 0.02, width: 0.08, height: 0.10),
            factor: 2.5
        ))
        #expect(edge.x + edge.width <= 1.000_001)
        #expect(edge.y >= 0)
        #expect(edge.width > 0)
        #expect(edge.height > 0)
    }

    @Test("In-memory crop geometry preserves the requested outward pixel bounds")
    func cropGeometry() async throws {
        let source = try VisualEmbeddingImage(encodedBytes: Self.jpeg(width: 100, height: 80))
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.10,
            y: 0.25,
            width: 0.30,
            height: 0.50
        ))
        let processor = VisionVisualRegionProcessor()

        let crops = try await processor.crops(
            from: source,
            proposals: [VisualRegionProposal(kind: .face, bounds: bounds)]
        )

        let crop = try #require(crops.first)
        let imageSource = try #require(CGImageSourceCreateWithData(
            crop.image.encodedBytes as CFData,
            nil
        ))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width == 30)
        #expect(image.height == 40)
    }

    @Test("Region crops use Vision's bottom-left origin across asymmetric quadrants")
    func cropCoordinatesUseBottomLeftOrigin() async throws {
        let source = try VisualEmbeddingImage(
            encodedBytes: Self.asymmetricQuadrantPNG(width: 96, height: 64)
        )
        let proposals = [
            Self.proposal(x: 0, y: 0, width: 0.5, height: 0.5),
            Self.proposal(x: 0.5, y: 0, width: 0.5, height: 0.5),
            Self.proposal(x: 0, y: 0.5, width: 0.5, height: 0.5),
            Self.proposal(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ]

        let crops = try await VisionVisualRegionProcessor().crops(
            from: source,
            proposals: proposals
        )

        #expect(crops.count == 4)
        let colors = try crops.map { try Self.centerPixel(in: $0.image.encodedBytes) }
        // The encoded fixture is red/green across the visual top and
        // blue/yellow across the visual bottom. A top-left-origin crop
        // implementation swaps these two rows and fails these assertions.
        Self.expectBlue(colors[0])
        Self.expectYellow(colors[1])
        Self.expectRed(colors[2])
        Self.expectGreen(colors[3])

        for crop in crops {
            let dimensions = try Self.imageDimensions(crop.image.encodedBytes)
            #expect(dimensions.width == 48)
            #expect(dimensions.height == 32)
        }
    }

    @Test("A crop touching the top-right edge keeps its side and exact pixels")
    func cropAtTopRightEdge() async throws {
        let source = try VisualEmbeddingImage(
            encodedBytes: Self.asymmetricQuadrantPNG(width: 96, height: 64)
        )
        let edge = Self.proposal(
            x: 0.875,
            y: 0.875,
            width: 0.125,
            height: 0.125
        )

        let crop = try #require(
            try await VisionVisualRegionProcessor().crops(
                from: source,
                proposals: [edge]
            ).first
        )

        let dimensions = try Self.imageDimensions(crop.image.encodedBytes)
        #expect(dimensions.width == 12)
        #expect(dimensions.height == 8)
        Self.expectGreen(try Self.centerPixel(in: crop.image.encodedBytes))
    }

    @Test("Native Vision handles a blank local image without inventing a person")
    func nativeVisionBlankImageSmoke() async throws {
        let source = try VisualEmbeddingImage(encodedBytes: Self.jpeg(width: 128, height: 96))
        let processor = VisionVisualRegionProcessor()

        let proposals = try await processor.proposals(
            in: source,
            requestedKinds: [.face, .person],
            maximumCount: 4
        )

        #expect(proposals.isEmpty)
    }

    @Test("Region refinement is shortlist-bounded, byte-persistent-write-free, and exact")
    func boundedReadOnlyReranking() async throws {
        let frames = [Self.frame("one"), Self.frame("two"), Self.frame("three")]
        let repository = RegionRepositoryStub()
        let media = RegionMediaStub(values: [
            "one-thumb": Data([1]), "one-full": Data([1]),
            "two-thumb": Data([1]), "two-full": Data([1]),
            "three-thumb": Data([1]), "three-full": Data([1]),
        ])
        let resolver = RegionFrameResolver(frames: Dictionary(
            uniqueKeysWithValues: frames.map { ($0.id, [$0]) }
        ))
        let processor = RegionProcessorStub()
        let model = RegionModelStub()
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: media,
            frameResolver: resolver,
            regionProcessor: processor,
            regionDeadlineSleep: Self.waitOnlyForDeadlineCancellation,
            conditions: {
                VisualIndexingConditions(
                    isLowPowerModeEnabled: false,
                    thermalState: .nominal
                )
            }
        )
        let matches = frames.map { Self.match($0, similarity: 0.20) }

        let response = try await engine.rerankRegions(
            text: "a man with glasses",
            matches: matches,
            policy: VisualRegionRerankingPolicy(
                candidateFrameLimit: 2,
                embeddingLimit: 3,
                regionsPerFrameLimit: 2,
                minimumRegionSimilarity: 0.25,
                minimumSimilarityGain: 0.01
            )
        )

        #expect(response.candidateFrameCount == 2)
        #expect(response.embeddedRegionCount == 3)
        #expect(response.evidenceByFrameID.count == 2)
        #expect(response.matches.first?.similarity == 1)
        #expect(response.matches.first?.associatedFrameCount == 1)
        #expect(response.matches.first?.sourceVisualFingerprint == 42)
        #expect(await model.imageEmbeddingCount == 3)
        #expect(await model.textEmbeddingCount == 1)
        #expect(!(await media.readPaths).contains("three-thumb"))
        #expect(!(await media.readPaths).contains("three-full"))
        #expect(await repository.writeCount == 0)
        #expect(await processor.requestedKinds == [.face, .person])
    }

    @Test("A fingerprint change after inference discards the region result")
    func finalFingerprintMismatchFailsClosed() async throws {
        let original = Self.frame("changing", fingerprint: 42)
        let changed = Self.frame("changing", fingerprint: 43)
        let resolver = RegionFrameResolver(frames: [original.id: [original, changed]])
        let media = RegionMediaStub(values: [
            "changing-thumb": Data([1]),
            "changing-full": Data([1]),
        ])
        let model = RegionModelStub()
        let engine = VisualMemoryEngine(
            model: model,
            repository: RegionRepositoryStub(),
            media: media,
            frameResolver: resolver,
            regionProcessor: RegionProcessorStub(),
            regionDeadlineSleep: Self.waitOnlyForDeadlineCancellation
        )
        let match = Self.match(original, similarity: 0.20)

        let response = try await engine.rerankRegions(
            text: "person with glasses",
            matches: [match],
            policy: VisualRegionRerankingPolicy(
                candidateFrameLimit: 1,
                embeddingLimit: 2,
                regionsPerFrameLimit: 2,
                minimumRegionSimilarity: 0.25,
                minimumSimilarityGain: 0.01
            )
        )

        #expect(response.evidenceByFrameID.isEmpty)
        #expect(response.matches.isEmpty)
        #expect(await model.imageEmbeddingCount == 2)
    }

    @Test("Final validation drops an untouched match that expires during refinement")
    func finalValidationDropsExpiredUntouchedMatch() async throws {
        let winner = Self.frame("winner")
        let expired = Self.frame("expired")
        let resolver = RegionFrameResolver(frames: [
            winner.id: [winner, winner, winner],
            // The untouched global hit has been removed before the region
            // phase's final whole-shortlist validation reaches it.
        ])
        let engine = VisualMemoryEngine(
            model: RegionModelStub(),
            repository: RegionRepositoryStub(),
            media: RegionMediaStub(values: [
                "winner-thumb": Data([1]),
                "winner-full": Data([1]),
                "expired-thumb": Data([1]),
                "expired-full": Data([1]),
            ]),
            frameResolver: resolver,
            regionProcessor: RegionProcessorStub(),
            regionDeadlineSleep: Self.waitOnlyForDeadlineCancellation
        )

        let response = try await engine.rerankRegions(
            text: "a man",
            matches: [Self.match(winner), Self.match(expired)],
            policy: VisualRegionRerankingPolicy(
                candidateFrameLimit: 1,
                embeddingLimit: 1,
                regionsPerFrameLimit: 1,
                minimumRegionSimilarity: 0.25,
                minimumSimilarityGain: 0.01
            )
        )

        #expect(response.matches.map(\.hit.id) == [winner.id])
        #expect(response.evidenceByFrameID.keys.contains(winner.id))
        #expect(!response.evidenceByFrameID.keys.contains(expired.id))
    }

    @Test("A stale global fingerprint is rejected before pixels")
    func initialFingerprintMismatchSkipsPixels() async throws {
        let current = Self.frame("stale", fingerprint: 43)
        let media = RegionMediaStub(values: [
            "stale-thumb": Data([1]),
            "stale-full": Data([1]),
        ])
        var staleMatch = Self.match(current, similarity: 0.20)
        staleMatch.sourceVisualFingerprint = 42
        let engine = VisualMemoryEngine(
            model: RegionModelStub(),
            repository: RegionRepositoryStub(),
            media: media,
            frameResolver: RegionFrameResolver(frames: [current.id: [current]]),
            regionProcessor: RegionProcessorStub(),
            regionDeadlineSleep: Self.waitOnlyForDeadlineCancellation
        )

        let response = try await engine.rerankRegions(
            text: "a man",
            matches: [staleMatch]
        )

        #expect(response.evidenceByFrameID.isEmpty)
        #expect(await media.readPaths.isEmpty)
    }

    @Test("Low power skips every pixel and model operation")
    func lowPowerSkipsRegionWork() async throws {
        let frame = Self.frame("low-power")
        let media = RegionMediaStub(values: ["low-power-thumb": Data([1])])
        let model = RegionModelStub()
        let engine = VisualMemoryEngine(
            model: model,
            repository: RegionRepositoryStub(),
            media: media,
            frameResolver: RegionFrameResolver(frames: [frame.id: [frame]]),
            regionProcessor: RegionProcessorStub(),
            conditions: {
                VisualIndexingConditions(
                    isLowPowerModeEnabled: true,
                    thermalState: .nominal
                )
            }
        )

        let response = try await engine.rerankRegions(
            text: "person",
            matches: [Self.match(frame)]
        )

        #expect(response.skippedForSystemConditions)
        #expect(await media.readPaths.isEmpty)
        #expect(await model.textEmbeddingCount == 0)
        #expect(await model.imageEmbeddingCount == 0)
    }

    @Test("Synchronous revocation stops a cancellation-insensitive proposer")
    func revocationGateStopsLateProposal() async throws {
        let frame = Self.frame("revoked")
        let media = RegionMediaStub(values: [
            "revoked-thumb": Data([1]),
            "revoked-full": Data([1]),
        ])
        let processor = SuspendedRegionProcessor()
        let authorization = RegionAuthorizationProbe()
        let model = RegionModelStub()
        let engine = VisualMemoryEngine(
            model: model,
            repository: RegionRepositoryStub(),
            media: media,
            frameResolver: RegionFrameResolver(frames: [frame.id: [frame]]),
            regionProcessor: processor,
            regionWorkIsAuthorized: { authorization.isAuthorized },
            regionDeadlineSleep: Self.waitOnlyForDeadlineCancellation
        )
        let work = Task {
            try await engine.rerankRegions(
                text: "person",
                matches: [Self.match(frame)]
            )
        }
        await processor.waitUntilProposing()
        authorization.revoke()
        await processor.release()

        do {
            _ = try await work.value
            Issue.record("Revoked region work unexpectedly returned")
        } catch is CancellationError {
            // Expected: revocation is a synchronous capability boundary.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await model.imageEmbeddingCount == 0)
    }

    @Test("Deadline exits while a cancellation-insensitive proposer remains suspended")
    func deadlineBoundsCancellationInsensitiveProposal() async throws {
        let frame = Self.frame("deadline")
        let repository = RegionRepositoryStub()
        let media = RegionMediaStub(values: [
            "deadline-thumb": Data([1]),
            "deadline-full": Data([1]),
        ])
        let processor = SuspendedRegionProcessor()
        let deadline = ManualRegionDeadline()
        let model = RegionModelStub()
        let globalMatch = Self.match(frame)
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: media,
            frameResolver: RegionFrameResolver(frames: [frame.id: [frame]]),
            regionProcessor: processor,
            regionDeadlineSleep: { instant in
                try await deadline.sleep(until: instant)
            }
        )
        let work = Task {
            try await engine.rerankRegions(
                text: "person",
                matches: [globalMatch],
                policy: VisualRegionRerankingPolicy(
                    candidateFrameLimit: 1,
                    embeddingLimit: 1,
                    regionsPerFrameLimit: 1,
                    maximumDurationMilliseconds: 850
                )
            )
        }

        await processor.waitUntilProposing()
        await deadline.waitUntilArmed()
        await deadline.fire()

        // This must complete before releasing the cancellation-insensitive
        // proposal call. A structured timeout would remain stuck here.
        let response = try await work.value
        #expect(response.timedOut)
        #expect(response.matches == [globalMatch])
        #expect(response.evidenceByFrameID.isEmpty)
        #expect(response.candidateFrameCount == 0)
        #expect(response.embeddedRegionCount == 0)
        #expect(await repository.writeCount == 0)
        #expect(await model.imageEmbeddingCount == 0)

        // Let the intentionally suspended worker unwind. Its cancelled late
        // result cannot run crop inference, write, or reach the closed result
        // channel after the deadline response has been returned.
        await processor.release()
        await processor.waitUntilProposalReturned()
        await Task.yield()
        #expect(await model.imageEmbeddingCount == 0)
        #expect(await repository.writeCount == 0)
    }

    private static func waitOnlyForDeadlineCancellation(
        _ instant: ContinuousClock.Instant
    ) async throws {
        _ = instant
        try await Task<Never, Never>.sleep(for: .seconds(86_400))
    }

    private static func frame(
        _ id: String,
        fingerprint: UInt64 = 42
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: 100),
            context: ScreenContext(applicationName: "Movie"),
            ocrText: "",
            imageRelativePath: "\(id)-full",
            thumbnailRelativePath: "\(id)-thumb",
            pixelWidth: 1_280,
            pixelHeight: 720,
            visualFingerprint: fingerprint,
            changeScore: 1
        )
    }

    private static func match(
        _ frame: FrameDocument,
        similarity: Double = 0.20
    ) -> VisualEmbeddingMatch {
        VisualEmbeddingMatch(
            hit: SearchHit(
                id: frame.id,
                capturedAt: frame.capturedAt,
                context: frame.context,
                snippet: "",
                imageRelativePath: frame.imageRelativePath,
                thumbnailRelativePath: frame.thumbnailRelativePath,
                score: similarity
            ),
            similarity: similarity,
            maximumSimilarityError: 0.005,
            model: RegionModelStub.identityValue,
            associatedFrameCount: 3,
            sourceVisualFingerprint: frame.visualFingerprint
        )
    }

    private static func jpeg(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RegionTestError.imageEncoding }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw RegionTestError.imageEncoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw RegionTestError.imageEncoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RegionTestError.imageEncoding
        }
        return data as Data
    }

    private static func proposal(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> VisualRegionProposal {
        VisualRegionProposal(
            kind: .face,
            bounds: NormalizedVisualRegionBounds(
                x: x,
                y: y,
                width: width,
                height: height
            )!
        )
    }

    /// A deliberately non-square image whose encoded scanlines are red/green
    /// on top and blue/yellow on the bottom. Building the pixels directly
    /// keeps the fixture independent from Core Graphics drawing coordinates.
    private static func asymmetricQuadrantPNG(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for rowFromTop in 0..<height {
            for x in 0..<width {
                let color: Pixel
                switch (rowFromTop < height / 2, x < width / 2) {
                case (true, true):
                    color = Pixel(red: 255, green: 0, blue: 0)
                case (true, false):
                    color = Pixel(red: 0, green: 255, blue: 0)
                case (false, true):
                    color = Pixel(red: 0, green: 0, blue: 255)
                case (false, false):
                    color = Pixel(red: 255, green: 255, blue: 0)
                }
                let offset = (rowFromTop * width + x) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { throw RegionTestError.imageEncoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw RegionTestError.imageEncoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RegionTestError.imageEncoding
        }
        return data as Data
    }

    private static func imageDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private static func centerPixel(in data: Data) throws -> Pixel {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        ) else { throw RegionTestError.imageEncoding }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return Pixel(
            red: pixels[offset],
            green: pixels[offset + 1],
            blue: pixels[offset + 2]
        )
    }

    private static func expectRed(_ pixel: Pixel) {
        #expect(pixel.red > 200)
        #expect(pixel.green < 60)
        #expect(pixel.blue < 60)
    }

    private static func expectGreen(_ pixel: Pixel) {
        #expect(pixel.red < 60)
        #expect(pixel.green > 200)
        #expect(pixel.blue < 60)
    }

    private static func expectBlue(_ pixel: Pixel) {
        #expect(pixel.red < 60)
        #expect(pixel.green < 60)
        #expect(pixel.blue > 200)
    }

    private static func expectYellow(_ pixel: Pixel) {
        #expect(pixel.red > 200)
        #expect(pixel.green > 200)
        #expect(pixel.blue < 60)
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }
}

private actor RegionModelStub: VisualEmbeddingModel {
    static let identityValue = VisualModelIdentity(
        identifier: "region-stub",
        revision: "1",
        fingerprint: String(repeating: "c", count: 64),
        preprocessingRevision: "region-v1",
        embeddingDimension: 3
    )

    nonisolated let identity = identityValue
    private(set) var textEmbeddingCount = 0
    private(set) var imageEmbeddingCount = 0

    func embed(image: VisualEmbeddingImage) throws -> NormalizedVisualEmbedding {
        imageEmbeddingCount += 1
        return try NormalizedVisualEmbedding(normalizing: [1, 0, 0])
    }

    func embed(text: String) throws -> NormalizedVisualEmbedding {
        textEmbeddingCount += 1
        return try NormalizedVisualEmbedding(normalizing: [1, 0, 0])
    }
}

private actor RegionMediaStub: VisualMediaReading {
    private let values: [String: Data]
    private(set) var readPaths: [String] = []

    init(values: [String: Data]) {
        self.values = values
    }

    func read(relativePath: String) throws -> Data {
        readPaths.append(relativePath)
        guard let value = values[relativePath] else { throw RegionTestError.missing }
        return value
    }
}

private actor RegionFrameResolver: VisualFrameResolving {
    private var frames: [FrameID: [FrameDocument]]

    init(frames: [FrameID: [FrameDocument]]) {
        self.frames = frames
    }

    func resolveVisualFrame(id: FrameID) -> FrameDocument? {
        guard var sequence = frames[id], !sequence.isEmpty else { return nil }
        let next = sequence.count == 1 ? sequence[0] : sequence.removeFirst()
        frames[id] = sequence
        return next
    }
}

private actor RegionProcessorStub: VisualRegionProcessing {
    private(set) var requestedKinds = Set<VisualRegionKind>()

    func proposals(
        in image: VisualEmbeddingImage,
        requestedKinds: Set<VisualRegionKind>,
        maximumCount: Int
    ) -> [VisualRegionProposal] {
        self.requestedKinds.formUnion(requestedKinds)
        let face = VisualRegionProposal(
            kind: .face,
            bounds: NormalizedVisualRegionBounds(
                x: 0.1, y: 0.2, width: 0.3, height: 0.3
            )!
        )
        let person = VisualRegionProposal(
            kind: .person,
            bounds: NormalizedVisualRegionBounds(
                x: 0.2, y: 0.1, width: 0.5, height: 0.8
            )!
        )
        return Array([face, person].filter {
            requestedKinds.contains($0.kind)
        }.prefix(maximumCount))
    }

    func crops(
        from image: VisualEmbeddingImage,
        proposals: [VisualRegionProposal]
    ) throws -> [VisualRegionCrop] {
        try proposals.map {
            VisualRegionCrop(
                proposal: $0,
                image: try VisualEmbeddingImage(encodedBytes: Data([9]))
            )
        }
    }
}

private actor SuspendedRegionProcessor: VisualRegionProcessing {
    private var proposing = false
    private var proposalReturned = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilProposing() async {
        guard !proposing else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitUntilProposalReturned() async {
        guard !proposalReturned else { return }
        await withCheckedContinuation { returnWaiters.append($0) }
    }

    func proposals(
        in image: VisualEmbeddingImage,
        requestedKinds: Set<VisualRegionKind>,
        maximumCount: Int
    ) async -> [VisualRegionProposal] {
        proposing = true
        let observers = entryWaiters
        entryWaiters = []
        observers.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        proposalReturned = true
        let returnObservers = returnWaiters
        returnWaiters = []
        returnObservers.forEach { $0.resume() }
        return [VisualRegionProposal(
            kind: .person,
            bounds: NormalizedVisualRegionBounds(
                x: 0.1, y: 0.1, width: 0.8, height: 0.8
            )!
        )]
    }

    func crops(
        from image: VisualEmbeddingImage,
        proposals: [VisualRegionProposal]
    ) throws -> [VisualRegionCrop] {
        try proposals.map {
            VisualRegionCrop(
                proposal: $0,
                image: try VisualEmbeddingImage(encodedBytes: Data([9]))
            )
        }
    }
}

private actor ManualRegionDeadline {
    private var armed = false
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []
    private var deadlineWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(until instant: ContinuousClock.Instant) async throws {
        _ = instant
        armed = true
        let observers = armedWaiters
        armedWaiters = []
        observers.forEach { $0.resume() }
        // Intentionally cancellation-insensitive so the test controls the
        // deadline deterministically rather than depending on wall-clock time.
        await withCheckedContinuation { deadlineWaiters.append($0) }
    }

    func waitUntilArmed() async {
        guard !armed else { return }
        await withCheckedContinuation { armedWaiters.append($0) }
    }

    func fire() {
        let waiters = deadlineWaiters
        deadlineWaiters = []
        waiters.forEach { $0.resume() }
    }
}

private final class RegionAuthorizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var authorized = true

    var isAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authorized
    }

    func revoke() {
        lock.lock()
        authorized = false
        lock.unlock()
    }
}

private actor RegionRepositoryStub: VisualEmbeddingRepository {
    private(set) var writeCount = 0

    func upsertVisualEmbeddings(
        _ writes: [VisualEmbeddingWrite]
    ) -> VisualEmbeddingWriteSummary {
        writeCount += writes.count
        return VisualEmbeddingWriteSummary(processedFrameCount: writes.count)
    }

    func nearestVisualEmbeddings(
        _ query: VisualEmbeddingQuery
    ) -> [VisualEmbeddingMatch] { [] }

    func visualEmbeddingCoverage(
        for model: VisualModelIdentity
    ) -> VisualEmbeddingCoverage {
        VisualEmbeddingCoverage(
            model: model,
            eligibleFrameCount: 0,
            indexedEligibleFrameCount: 0,
            indexedFrameCount: 0,
            pendingEligibleFrameCount: 0,
            staleEmbeddingCount: 0,
            uniqueVectorCount: 0,
            deduplicatedFrameCount: 0,
            storedVectorPayloadBytes: 0,
            coverageFraction: nil
        )
    }

    func framesNeedingVisualEmbedding(
        for model: VisualModelIdentity,
        limit: Int
    ) -> [VisualEmbeddingCandidate] { [] }

    func deleteVisualEmbeddings(modelFingerprint: String) -> Int { 0 }
}

private enum RegionTestError: Error {
    case imageEncoding
    case missing
}
