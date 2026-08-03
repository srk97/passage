@testable import PassageVisualSearch
import PassageCore
import PassageVisualModel
import CoreGraphics
import Foundation
import Testing

struct VisualMemoryEngineTests {
    @Test("Backfill is off-capture, prefers thumbnails, and falls back safely")
    func backfillAndMediaFallback() async throws {
        let candidate = Self.candidate(id: "frame-1")
        let repository = StubVisualRepository(candidates: [candidate])
        let media = StubVisualMedia(
            values: ["full": Data([3, 4, 5])],
            failingPaths: ["thumb"]
        )
        let model = StubVisualModel()
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: media,
            conditions: {
                VisualIndexingConditions(
                    isLowPowerModeEnabled: false,
                    thermalState: .nominal
                )
            }
        )

        let pass = try await engine.indexNextBatch(limit: 20)
        #expect(pass.attemptedFrameCount == 1)
        #expect(pass.indexedFrameCount == 1)
        #expect(pass.skippedMediaCount == 0)
        #expect(!pass.pausedForSystemConditions)
        #expect(await media.readPaths == ["thumb", "full"])
        let writes = await repository.receivedWrites
        #expect(writes.count == 1)
        #expect(writes.first?.frameID == candidate.frameID)
        #expect(writes.first?.vector.count == 3)
    }

    @Test("Low-power and serious thermal states pause before pixels are read")
    func systemConditionPause() async throws {
        let repository = StubVisualRepository(candidates: [Self.candidate(id: "frame-1")])
        let media = StubVisualMedia(values: ["thumb": Data([1])])
        let engine = VisualMemoryEngine(
            model: StubVisualModel(),
            repository: repository,
            media: media,
            conditions: {
                VisualIndexingConditions(
                    isLowPowerModeEnabled: true,
                    thermalState: .serious
                )
            }
        )

        let pass = try await engine.indexNextBatch()
        #expect(pass.pausedForSystemConditions)
        #expect(pass.attemptedFrameCount == 0)
        #expect(await repository.candidateRequestCount == 0)
        #expect(await media.readPaths.isEmpty)
    }

    @Test("Visual queries preserve Recall's exact metadata scope")
    func scopedSearch() async throws {
        let expectedHit = Self.hit(id: "match")
        let repository = StubVisualRepository(matches: [VisualEmbeddingMatch(
            hit: expectedHit,
            similarity: 0.42,
            maximumSimilarityError: 0.01,
            model: StubVisualModel.identityValue,
            associatedFrameCount: 2
        )])
        let model = StubVisualModel()
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: StubVisualMedia(values: [:])
        )
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let scope = RecallScope(
            text: "person with glasses",
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: ["com.example.Movie"],
            domains: ["example.com"]
        )

        let response = try await engine.search(
            text: scope.text,
            scope: scope,
            minimumSimilarity: 0.2,
            limit: 12,
            candidateLimit: 512
        )
        #expect(response.matches.map(\.hit.id) == [expectedHit.id])
        #expect(response.evidenceKind == .textToImageSimilarity)
        #expect(await model.textEmbeddingCount == 1)
        #expect(await model.imageEmbeddingCount == 0)
        let query = try #require(await repository.lastQuery)
        #expect(query.startDate == start)
        #expect(query.endDate == end)
        #expect(query.applicationBundleIdentifiers == ["com.example.Movie"])
        #expect(query.domains == ["example.com"])
        #expect(query.excludedFrameIDs.isEmpty)
        #expect(query.minimumSimilarity == 0.2)
        #expect(query.limit == 12)
        #expect(query.candidateLimit == 512)
    }

    @Test("Memory Lens embeds only the in-memory image and preserves exact scope")
    func imageQueryUsesImageTowerAndExactScope() async throws {
        let expectedHit = Self.hit(id: "similar-scene")
        let repository = StubVisualRepository(matches: [VisualEmbeddingMatch(
            hit: expectedHit,
            similarity: 0.88,
            maximumSimilarityError: 0.01,
            model: StubVisualModel.identityValue,
            associatedFrameCount: 1
        )])
        let model = StubVisualModel()
        let media = StubVisualMedia(values: [:])
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: media
        )
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let sourceID = FrameID(rawValue: "selected-source")
        let scope = RecallScope(
            text: "this text must never reach the model",
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: ["com.example.Movie"],
            domains: ["example.com"]
        )

        let response = try await engine.search(
            image: Self.onePixelImage(),
            scope: scope,
            excluding: sourceID,
            minimumSimilarity: 0.25,
            limit: 12,
            candidateLimit: 512
        )

        #expect(response.matches.map(\.hit.id) == [expectedHit.id])
        #expect(response.evidenceKind == .imageToImageSimilarity)
        #expect(response.evidenceKind.rawValue == "imageToImageSimilarity")
        #expect(await model.imageEmbeddingCount == 1)
        #expect(await model.textEmbeddingCount == 0)
        #expect(await media.readPaths.isEmpty)
        #expect(await repository.receivedWrites.isEmpty)
        let query = try #require(await repository.lastQuery)
        #expect(query.startDate == start)
        #expect(query.endDate == end)
        #expect(query.applicationBundleIdentifiers == ["com.example.Movie"])
        #expect(query.domains == ["example.com"])
        #expect(query.excludedFrameIDs == [sourceID])
        #expect(query.vector == (try NormalizedVisualEmbedding(
            normalizing: [1, 2, 3]
        )).values)
        #expect(query.minimumSimilarity == 0.25)
        #expect(query.limit == 12)
        #expect(query.candidateLimit == 512)
    }

    @Test("Memory Lens source exclusion is optional")
    func imageQueryCanIncludeSource() async throws {
        let repository = StubVisualRepository()
        let engine = VisualMemoryEngine(
            model: StubVisualModel(),
            repository: repository,
            media: StubVisualMedia(values: [:])
        )

        _ = try await engine.search(
            image: Self.onePixelImage(),
            scope: RecallScope()
        )

        #expect(await repository.lastQuery?.excludedFrameIDs.isEmpty == true)
    }

    @Test("Memory Lens validates image model output before retrieval")
    func imageQueryValidatesModelOutput() async throws {
        let repository = StubVisualRepository()
        let model = StubVisualModel(imageVector: [1, 2])
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: StubVisualMedia(values: [:])
        )

        await #expect(throws: VisualEmbeddingError.incompatibleModelOutput) {
            _ = try await engine.search(
                image: Self.onePixelImage(),
                scope: RecallScope()
            )
        }
        #expect(await model.imageEmbeddingCount == 1)
        #expect(await model.textEmbeddingCount == 0)
        #expect(await repository.lastQuery == nil)
    }

    @Test("Memory Lens cancellation prevents encrypted retrieval")
    func imageQueryCancellation() async throws {
        let repository = StubVisualRepository()
        let model = BlockingVisualModel()
        let engine = VisualMemoryEngine(
            model: model,
            repository: repository,
            media: StubVisualMedia(values: [:])
        )
        let image = try Self.onePixelImage()
        let task = Task {
            try await engine.search(image: image, scope: RecallScope())
        }
        await model.waitUntilImageEmbeddingStarts()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await repository.lastQuery == nil)
    }

    @Test("Sensitive committed frames never reach media or the model")
    func sensitiveFrameFailsClosed() async throws {
        var frame = Self.frame(id: "sensitive")
        frame.context.isSensitive = true
        let repository = StubVisualRepository()
        let media = StubVisualMedia(values: ["thumb": Data([1])])
        let engine = VisualMemoryEngine(
            model: StubVisualModel(),
            repository: repository,
            media: media
        )

        let summary = try await engine.indexPersistedFrame(frame)
        #expect(summary.processedFrameCount == 0)
        #expect(await media.readPaths.isEmpty)
        #expect(await repository.receivedWrites.isEmpty)
    }

    private static func frame(id: String) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: 120),
            context: ScreenContext(applicationName: "Movie"),
            ocrText: "",
            imageRelativePath: "full",
            thumbnailRelativePath: "thumb",
            pixelWidth: 1_280,
            pixelHeight: 720,
            visualFingerprint: 42,
            changeScore: 1
        )
    }

    private static func candidate(id: String) -> VisualEmbeddingCandidate {
        let frame = frame(id: id)
        return VisualEmbeddingCandidate(
            frameID: frame.id,
            capturedAt: frame.capturedAt,
            imageRelativePath: frame.imageRelativePath,
            thumbnailRelativePath: frame.thumbnailRelativePath,
            pixelWidth: frame.pixelWidth,
            pixelHeight: frame.pixelHeight,
            visualFingerprint: frame.visualFingerprint,
            isSensitive: frame.context.isSensitive
        )
    }

    private static func hit(id: String) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: 150),
            context: ScreenContext(applicationName: "Movie"),
            snippet: "A remembered scene",
            imageRelativePath: "full",
            thumbnailRelativePath: "thumb",
            score: 0
        )
    }

    private static func onePixelImage() throws -> CGImage {
        let bytes = Data([255, 80, 20, 255])
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

private actor StubVisualModel: VisualEmbeddingModel {
    static let identityValue = VisualModelIdentity(
        identifier: "stub-visual",
        revision: "1",
        fingerprint: String(repeating: "a", count: 64),
        preprocessingRevision: "stub-v1",
        embeddingDimension: 3
    )

    nonisolated let identity = identityValue

    private let imageVector: [Float]
    private(set) var imageEmbeddingCount = 0
    private(set) var textEmbeddingCount = 0

    init(imageVector: [Float] = [1, 2, 3]) {
        self.imageVector = imageVector
    }

    func embed(image: VisualEmbeddingImage) async throws -> NormalizedVisualEmbedding {
        imageEmbeddingCount += 1
        return try NormalizedVisualEmbedding(normalizing: imageVector)
    }

    func embed(text: String) async throws -> NormalizedVisualEmbedding {
        textEmbeddingCount += 1
        return try NormalizedVisualEmbedding(normalizing: [3, 2, 1])
    }
}

private actor BlockingVisualModel: VisualEmbeddingModel {
    nonisolated let identity = StubVisualModel.identityValue

    private var didStartImageEmbedding = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func embed(image: VisualEmbeddingImage) async throws -> NormalizedVisualEmbedding {
        didStartImageEmbedding = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
        return try NormalizedVisualEmbedding(normalizing: [1, 2, 3])
    }

    func embed(text: String) async throws -> NormalizedVisualEmbedding {
        try NormalizedVisualEmbedding(normalizing: [3, 2, 1])
    }

    func waitUntilImageEmbeddingStarts() async {
        guard !didStartImageEmbedding else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor StubVisualMedia: VisualMediaReading {
    let values: [String: Data]
    let failingPaths: Set<String>
    private(set) var readPaths: [String] = []

    init(values: [String: Data], failingPaths: Set<String> = []) {
        self.values = values
        self.failingPaths = failingPaths
    }

    func read(relativePath: String) throws -> Data {
        readPaths.append(relativePath)
        if failingPaths.contains(relativePath) { throw StubError.unavailable }
        guard let value = values[relativePath] else { throw StubError.unavailable }
        return value
    }
}

private actor StubVisualRepository: VisualEmbeddingRepository {
    private let candidates: [VisualEmbeddingCandidate]
    private let matches: [VisualEmbeddingMatch]
    private(set) var receivedWrites: [VisualEmbeddingWrite] = []
    private(set) var lastQuery: VisualEmbeddingQuery?
    private(set) var candidateRequestCount = 0

    init(
        candidates: [VisualEmbeddingCandidate] = [],
        matches: [VisualEmbeddingMatch] = []
    ) {
        self.candidates = candidates
        self.matches = matches
    }

    func upsertVisualEmbeddings(
        _ writes: [VisualEmbeddingWrite]
    ) -> VisualEmbeddingWriteSummary {
        receivedWrites.append(contentsOf: writes)
        return VisualEmbeddingWriteSummary(
            processedFrameCount: writes.count,
            insertedAssociationCount: writes.count,
            insertedUniqueVectorCount: writes.count,
            storedVectorBytesDelta: Int64(writes.count * 576)
        )
    }

    func nearestVisualEmbeddings(
        _ query: VisualEmbeddingQuery
    ) -> [VisualEmbeddingMatch] {
        lastQuery = query
        return matches
    }

    func visualEmbeddingCoverage(
        for model: VisualModelIdentity
    ) -> VisualEmbeddingCoverage {
        VisualEmbeddingCoverage(
            model: model,
            eligibleFrameCount: candidates.count,
            indexedEligibleFrameCount: receivedWrites.count,
            indexedFrameCount: receivedWrites.count,
            pendingEligibleFrameCount: max(candidates.count - receivedWrites.count, 0),
            staleEmbeddingCount: 0,
            uniqueVectorCount: receivedWrites.count,
            deduplicatedFrameCount: 0,
            storedVectorPayloadBytes: Int64(receivedWrites.count * 576),
            coverageFraction: candidates.isEmpty
                ? nil
                : Double(receivedWrites.count) / Double(candidates.count)
        )
    }

    func framesNeedingVisualEmbedding(
        for model: VisualModelIdentity,
        limit: Int
    ) -> [VisualEmbeddingCandidate] {
        candidateRequestCount += 1
        return Array(candidates.prefix(limit))
    }

    func deleteVisualEmbeddings(modelFingerprint: String) -> Int {
        let count = receivedWrites.count
        receivedWrites = []
        return count
    }
}

private enum StubError: Error {
    case unavailable
}
