import PassageCore
import PassageVisualModel
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum VisualRegionKind: String, Hashable, Sendable {
    case face
    case person
}

/// Unit-space image bounds with a bottom-left origin, matching Vision and
/// Core Image. Region geometry is query-lifetime evidence and is never stored.
public struct NormalizedVisualRegionBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(x: Double, y: Double, width: Double, height: Double) {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite),
              x >= 0, y >= 0,
              width > 0, height > 0,
              x + width <= 1.000_001,
              y + height <= 1.000_001 else { return nil }
        self.x = min(x, 1)
        self.y = min(y, 1)
        self.width = min(width, 1 - self.x)
        self.height = min(height, 1 - self.y)
    }

    public var area: Double { width * height }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct VisualRegionProposal: Equatable, Sendable {
    public let kind: VisualRegionKind
    public let bounds: NormalizedVisualRegionBounds
    public let confidence: Float

    public init(
        kind: VisualRegionKind,
        bounds: NormalizedVisualRegionBounds,
        confidence: Float = 1
    ) {
        self.kind = kind
        self.bounds = bounds
        self.confidence = min(max(confidence, 0), 1)
    }
}

public struct VisualRegionCrop: Sendable {
    public let proposal: VisualRegionProposal
    public let image: VisualEmbeddingImage

    public init(proposal: VisualRegionProposal, image: VisualEmbeddingImage) {
        self.proposal = proposal
        self.image = image
    }
}

public protocol VisualRegionProcessing: Sendable {
    func proposals(
        in image: VisualEmbeddingImage,
        requestedKinds: Set<VisualRegionKind>,
        maximumCount: Int
    ) async throws -> [VisualRegionProposal]

    func crops(
        from image: VisualEmbeddingImage,
        proposals: [VisualRegionProposal]
    ) async throws -> [VisualRegionCrop]
}

/// Narrow current-frame re-resolution used to ensure a shortlist hit still
/// exists, is still non-sensitive, and still names the exact media fingerprint
/// before any query-lifetime region evidence can be published.
public protocol VisualFrameResolving: Sendable {
    func resolveVisualFrame(id: FrameID) async throws -> FrameDocument?
}

/// Native, on-device proposal and crop processing. Vision sees only an
/// authenticated in-memory image; crops are JPEG-encoded in memory and are
/// never written to a temporary file or Passage's vault.
public actor VisionVisualRegionProcessor: VisualRegionProcessing {
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func proposals(
        in image: VisualEmbeddingImage,
        requestedKinds: Set<VisualRegionKind>,
        maximumCount: Int
    ) async throws -> [VisualRegionProposal] {
        guard maximumCount > 0, !requestedKinds.isEmpty else { return [] }
        try Task.checkCancellation()

        let faces = VNDetectFaceRectanglesRequest()
        faces.revision = VNDetectFaceRectanglesRequestRevision3
        faces.preferBackgroundProcessing = true
        let people = VNDetectHumanRectanglesRequest()
        people.revision = VNDetectHumanRectanglesRequestRevision2
        people.upperBodyOnly = false
        people.preferBackgroundProcessing = true
        let handler = VNImageRequestHandler(data: image.encodedBytes, options: [:])
        let requests: [VNRequest] = [faces, people].filter { request in
            (request === faces && requestedKinds.contains(.face))
                || (request === people && requestedKinds.contains(.person))
        }
        let cancellation = VisionRequestCancellationGate(requests: requests)
        try await withTaskCancellationHandler {
            try handler.perform(requests)
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()

        let imageSize = CIImage(
            data: image.encodedBytes,
            options: [.applyOrientationProperty: true]
        )?.extent.size ?? .zero
        let faceProposals = requestedKinds.contains(.face)
            ? Self.filteredProposals(
                (faces.results ?? []).map { ($0.boundingBox, $0.confidence) },
                kind: .face,
                paddingFactor: 2.20,
                minimumPixels: 10,
                imageSize: imageSize
            )
            : []
        let personProposals = requestedKinds.contains(.person)
            ? Self.filteredProposals(
                (people.results ?? []).map { ($0.boundingBox, $0.confidence) },
                kind: .person,
                paddingFactor: 1.10,
                minimumPixels: 18,
                imageSize: imageSize
            )
            : []

        // One face and one person proposal give attribute queries both detail
        // and clothing/context before additional same-kind regions use budget.
        var ordered = [VisualRegionProposal]()
        if let face = faceProposals.first { ordered.append(face) }
        if let person = personProposals.first { ordered.append(person) }
        ordered.append(contentsOf: faceProposals.dropFirst())
        ordered.append(contentsOf: personProposals.dropFirst())
        return Array(ordered.prefix(min(maximumCount, 8)))
    }

    public func crops(
        from image: VisualEmbeddingImage,
        proposals: [VisualRegionProposal]
    ) throws -> [VisualRegionCrop] {
        guard !proposals.isEmpty else { return [] }
        try Task.checkCancellation()
        guard let source = CIImage(
            data: image.encodedBytes,
            options: [.applyOrientationProperty: true]
        ), source.extent.width > 0, source.extent.height > 0 else {
            throw VisualEmbeddingError.invalidImage
        }
        let normalized = source.transformed(by: CGAffineTransform(
            translationX: -source.extent.minX,
            y: -source.extent.minY
        ))
        let imageExtent = CGRect(origin: .zero, size: source.extent.size)

        var result = [VisualRegionCrop]()
        result.reserveCapacity(proposals.count)
        for proposal in proposals {
            try Task.checkCancellation()
            let bounds = proposal.bounds.cgRect
            let proposedPixels = CGRect(
                x: bounds.minX * imageExtent.width,
                y: bounds.minY * imageExtent.height,
                width: bounds.width * imageExtent.width,
                height: bounds.height * imageExtent.height
            )
            let pixelBounds = proposedPixels.integral.intersection(imageExtent)
            guard pixelBounds.width >= 8,
                  pixelBounds.height >= 8,
                  let cropped = context.createCGImage(normalized, from: pixelBounds) else {
                continue
            }
            let bytes = try Self.jpegData(from: cropped)
            result.append(VisualRegionCrop(
                proposal: proposal,
                image: try VisualEmbeddingImage(encodedBytes: bytes)
            ))
        }
        return result
    }

    static func paddedBounds(
        _ observedBounds: CGRect,
        factor: Double
    ) -> NormalizedVisualRegionBounds? {
        guard observedBounds.width > 0,
              observedBounds.height > 0,
              factor.isFinite,
              factor >= 1 else { return nil }
        let width = min(Double(observedBounds.width) * factor, 1)
        let height = min(Double(observedBounds.height) * factor, 1)
        let centerX = Double(observedBounds.midX)
        let centerY = Double(observedBounds.midY)
        let x = min(max(centerX - width / 2, 0), 1 - width)
        let y = min(max(centerY - height / 2, 0), 1 - height)
        return NormalizedVisualRegionBounds(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private static func proposal(
        kind: VisualRegionKind,
        observedBounds: CGRect,
        confidence: Float,
        paddingFactor: Double
    ) -> VisualRegionProposal? {
        guard confidence.isFinite, confidence >= 0.45 else { return nil }
        guard let bounds = paddedBounds(observedBounds, factor: paddingFactor) else {
            return nil
        }
        return VisualRegionProposal(kind: kind, bounds: bounds, confidence: confidence)
    }

    private static func largerRegionFirst(
        _ lhs: VisualRegionProposal,
        _ rhs: VisualRegionProposal
    ) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.bounds.area != rhs.bounds.area {
            return lhs.bounds.area > rhs.bounds.area
        }
        if lhs.bounds.y != rhs.bounds.y { return lhs.bounds.y > rhs.bounds.y }
        return lhs.bounds.x < rhs.bounds.x
    }

    private static func filteredProposals(
        _ observations: [(bounds: CGRect, confidence: Float)],
        kind: VisualRegionKind,
        paddingFactor: Double,
        minimumPixels: CGFloat,
        imageSize: CGSize
    ) -> [VisualRegionProposal] {
        let sorted = observations.compactMap { observation -> VisualRegionProposal? in
            guard observation.bounds.width * imageSize.width >= minimumPixels,
                  observation.bounds.height * imageSize.height >= minimumPixels else {
                return nil
            }
            return proposal(
                kind: kind,
                observedBounds: observation.bounds,
                confidence: observation.confidence,
                paddingFactor: paddingFactor
            )
        }.sorted(by: largerRegionFirst)
        var accepted = [VisualRegionProposal]()
        for proposal in sorted where !accepted.contains(where: {
            intersectionOverUnion($0.bounds.cgRect, proposal.bounds.cgRect) >= 0.85
        }) {
            accepted.append(proposal)
        }
        return accepted
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = Double(intersection.width * intersection.height)
        let union = Double(lhs.width * lhs.height + rhs.width * rhs.height)
            - intersectionArea
        return union > 0 ? intersectionArea / union : 0
    }

    private static func jpegData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw VisualEmbeddingError.invalidImage }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw VisualEmbeddingError.invalidImage
        }
        return output as Data
    }
}

public struct VisualRegionRerankingPolicy: Equatable, Sendable {
    public var candidateFrameLimit: Int
    public var embeddingLimit: Int
    public var regionsPerFrameLimit: Int
    public var minimumRegionSimilarity: Double
    public var minimumSimilarityGain: Double
    /// Progressive refinement is useful only while it still feels immediate.
    /// The default leaves a small scheduling margin inside one second while
    /// keeping this query-time work well below capture/background workloads.
    public var maximumDurationMilliseconds: Int

    public init(
        candidateFrameLimit: Int = 12,
        embeddingLimit: Int = 8,
        regionsPerFrameLimit: Int = 2,
        minimumRegionSimilarity: Double = 0.245,
        minimumSimilarityGain: Double = 0.01,
        maximumDurationMilliseconds: Int = 850
    ) {
        self.candidateFrameLimit = min(max(candidateFrameLimit, 1), 24)
        self.embeddingLimit = min(max(embeddingLimit, 1), 16)
        self.regionsPerFrameLimit = min(max(regionsPerFrameLimit, 1), 4)
        self.minimumRegionSimilarity = min(max(minimumRegionSimilarity, -1), 1)
        self.minimumSimilarityGain = min(max(minimumSimilarityGain, 0), 2)
        self.maximumDurationMilliseconds = min(
            max(maximumDurationMilliseconds, 25),
            1_000
        )
    }
}

public struct VisualRegionSimilarityThresholds: Equatable, Sendable {
    public let minimumSimilarity: Double
    public let minimumGain: Double

    public init(minimumSimilarity: Double, minimumGain: Double) {
        self.minimumSimilarity = minimumSimilarity
        self.minimumGain = minimumGain
    }
}

public struct VisualRegionRecallEvidence: Equatable, Sendable {
    public let kind: VisualRegionKind
    public let bounds: NormalizedVisualRegionBounds
    public let similarity: Double
    public let sourceVisualFingerprint: UInt64

    public init(
        kind: VisualRegionKind,
        bounds: NormalizedVisualRegionBounds,
        similarity: Double,
        sourceVisualFingerprint: UInt64
    ) {
        self.kind = kind
        self.bounds = bounds
        self.similarity = similarity
        self.sourceVisualFingerprint = sourceVisualFingerprint
    }
}

public struct VisualRegionRerankResponse: Equatable, Sendable {
    public var matches: [VisualEmbeddingMatch]
    public var evidenceByFrameID: [FrameID: VisualRegionRecallEvidence]
    public var candidateFrameCount: Int
    public var embeddedRegionCount: Int
    public var skippedForSystemConditions: Bool
    public var timedOut: Bool
    public var elapsedMilliseconds: Double

    public init(
        matches: [VisualEmbeddingMatch],
        evidenceByFrameID: [FrameID: VisualRegionRecallEvidence] = [:],
        candidateFrameCount: Int = 0,
        embeddedRegionCount: Int = 0,
        skippedForSystemConditions: Bool = false,
        timedOut: Bool = false,
        elapsedMilliseconds: Double = 0
    ) {
        self.matches = matches
        self.evidenceByFrameID = evidenceByFrameID
        self.candidateFrameCount = candidateFrameCount
        self.embeddedRegionCount = embeddedRegionCount
        self.skippedForSystemConditions = skippedForSystemConditions
        self.timedOut = timedOut
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// A deliberately small, deterministic gate. It spends crop inference only
/// for queries that actually describe people or person-level appearance.
public enum VisualRegionQueryEligibility {
    private static let faceTerms: Set<String> = [
        "beard", "bearded", "eyeglasses", "face", "faces", "glasses", "hair",
        "moustache", "mustache", "sunglasses",
    ]
    private static let personTerms: Set<String> = [
        "boy", "boys", "coat", "coats", "dress", "dresses", "girl", "girls", "guy",
        "guys", "human", "humans", "jacket", "jackets", "lady", "ladies", "man",
        "men", "people", "person", "persons", "shirt", "shirts", "someone", "wearing",
        "woman", "women",
    ]
    private static let sharedTerms: Set<String> = ["cap", "caps", "hat", "hats"]
    private static let calibratedManTerms: Set<String> = ["man", "men"]

    public static func shouldRerank(_ text: String) -> Bool {
        !requestedKinds(for: text).isEmpty
    }

    public static func requestedKinds(for text: String) -> Set<VisualRegionKind> {
        let tokens = tokens(in: text)
        var kinds = Set<VisualRegionKind>()
        if !tokens.isDisjoint(with: faceTerms) { kinds.insert(.face) }
        if !tokens.isDisjoint(with: personTerms) { kinds.insert(.person) }
        if !tokens.isDisjoint(with: sharedTerms) {
            kinds.formUnion([.face, .person])
        }
        return kinds
    }

    /// Conservative production thresholds, with narrower values only for the
    /// two exact intents measured using the bundled PE-Core model, production
    /// two-region budget, and an owner-provided five-frame positive/hard-
    /// negative set. Unmeasured person attributes keep the stricter fallback.
    public static func similarityThresholds(
        for text: String
    ) -> VisualRegionSimilarityThresholds {
        let queryTokens = tokens(in: text)
        let describesMan = !queryTokens.isDisjoint(with: calibratedManTerms)
        let describesFaceDetail = !queryTokens.isDisjoint(with: faceTerms)
        if describesMan && describesFaceDetail {
            return VisualRegionSimilarityThresholds(
                minimumSimilarity: 0.26,
                minimumGain: 0.01
            )
        }
        if describesMan {
            return VisualRegionSimilarityThresholds(
                minimumSimilarity: 0.245,
                minimumGain: 0.003
            )
        }
        return VisualRegionSimilarityThresholds(
            minimumSimilarity: 0.275,
            minimumGain: 0.02
        )
    }

    private static func tokens(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init))
    }
}

private final class VisionRequestCancellationGate: @unchecked Sendable {
    private let requests: [VNRequest]

    init(requests: [VNRequest]) {
        self.requests = requests
    }

    func cancel() {
        requests.forEach { $0.cancel() }
    }
}
