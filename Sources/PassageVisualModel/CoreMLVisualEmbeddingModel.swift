import CoreGraphics
import CoreImage
@preconcurrency import CoreML
import CoreVideo
import PassageCore
import Foundation

public enum CoreMLVisualEmbeddingError: Error, LocalizedError, Sendable {
    case unsupportedModelPack
    case modelCompilationFailed
    case modelLoadFailed
    case incompatibleModelInterface
    case imageDecodeFailed
    case pixelBufferCreationFailed
    case predictionFailed
    case invalidModelOutput

    public var errorDescription: String? {
        switch self {
        case .unsupportedModelPack:
            "This visual model pack is not compatible with Passage's local runtime."
        case .modelCompilationFailed:
            "Passage could not prepare the visual model for this Mac."
        case .modelLoadFailed:
            "Passage could not load the local visual model."
        case .incompatibleModelInterface:
            "The visual model's inputs or outputs do not match its manifest."
        case .imageDecodeFailed:
            "Passage could not decode this remembered image for visual search."
        case .pixelBufferCreationFailed:
            "Passage could not prepare this remembered image for visual search."
        case .predictionFailed:
            "The local visual model could not understand this memory."
        case .invalidModelOutput:
            "The local visual model returned an incompatible embedding."
        }
    }
}

public struct CoreMLVisualModelLoadMetrics: Equatable, Sendable {
    public var compilationMilliseconds: Double
    public var modelLoadMilliseconds: Double
    public var modelsLoadedInPlace: Bool

    public init(
        compilationMilliseconds: Double,
        modelLoadMilliseconds: Double,
        modelsLoadedInPlace: Bool = false
    ) {
        self.compilationMilliseconds = compilationMilliseconds
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.modelsLoadedInPlace = modelsLoadedInPlace
    }
}

/// Native image/text inference for Passage's v1 PE/OpenCLIP model contract.
///
/// The actor serializes Core ML and tokenizer access. Decrypted image bytes and
/// embeddings never leave process memory; Core ML receives a 384×384 pixel
/// buffer, and only the normalized 512-value result crosses this boundary.
public actor CoreMLVisualEmbeddingModel: VisualEmbeddingModel {
    public nonisolated let identity: VisualModelIdentity
    public nonisolated let loadMetrics: CoreMLVisualModelLoadMetrics

    private static let imageInputName = "image"
    private static let textInputName = "tokens"
    private static let outputName = "embedding"
    private static let expectedArchitecturePrefix = "pe-core-s-16-384"

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPBPETokenizer
    private let imageWidth: Int
    private let imageHeight: Int
    private let ciContext: CIContext

    public init(
        pack: InstalledVisualModelPack,
        compiledModelCacheDirectory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws {
        let metadata = pack.manifest.model
        guard metadata.architecture.lowercased().hasPrefix(Self.expectedArchitecturePrefix),
              metadata.embeddingDimension == 512,
              metadata.imageInputWidth == 384,
              metadata.imageInputHeight == 384,
              metadata.maximumTextTokens == 32 else {
            throw CoreMLVisualEmbeddingError.unsupportedModelPack
        }
        let mergesURL = try pack.requiredArtifactURL(forRole: .tokenizerMerges)

        let compilationStarted = ContinuousClock.now
        let prepared: PreparedCoreMLModels
        do {
            prepared = try await CoreMLCompiledModelCache.prepare(
                pack: pack,
                cacheDirectory: compiledModelCacheDirectory
            )
        } catch {
            throw CoreMLVisualEmbeddingError.modelCompilationFailed
        }
        let compilationMilliseconds = Self.milliseconds(since: compilationStarted)

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let loadStarted = ContinuousClock.now
        let imageModel: MLModel
        let textModel: MLModel
        do {
            imageModel = try MLModel(contentsOf: prepared.image, configuration: configuration)
            textModel = try MLModel(contentsOf: prepared.text, configuration: configuration)
        } catch {
            throw CoreMLVisualEmbeddingError.modelLoadFailed
        }
        let modelLoadMilliseconds = Self.milliseconds(since: loadStarted)
        try Self.validateInterfaces(
            image: imageModel,
            text: textModel,
            embeddingDimension: metadata.embeddingDimension,
            contextLength: metadata.maximumTextTokens
        )

        self.identity = pack.identity
        self.loadMetrics = CoreMLVisualModelLoadMetrics(
            compilationMilliseconds: compilationMilliseconds,
            modelLoadMilliseconds: modelLoadMilliseconds,
            modelsLoadedInPlace: prepared.loadedInPlace
        )
        self.imageModel = imageModel
        self.textModel = textModel
        self.tokenizer = try CLIPBPETokenizer(
            uncompressedMergesURL: mergesURL,
            contextLength: metadata.maximumTextTokens
        )
        self.imageWidth = metadata.imageInputWidth
        self.imageHeight = metadata.imageInputHeight
        self.ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .name: "Passage local visual embedding",
        ])
    }

    /// Forces both Core ML towers to specialize away from an interactive
    /// search. The neutral image is deterministic and never touches user data.
    public func prewarm() async throws {
        _ = try await embed(text: "a remembered screen")
        let buffer = try Self.makePixelBuffer(width: imageWidth, height: imageHeight)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CoreMLVisualEmbeddingError.pixelBufferCreationFailed
        }
        base.initializeMemory(
            as: UInt8.self,
            repeating: 127,
            count: CVPixelBufferGetDataSize(buffer)
        )
        _ = try await imageEmbedding(from: buffer)
    }

    public func embed(image: VisualEmbeddingImage) async throws -> NormalizedVisualEmbedding {
        try Task.checkCancellation()
        let buffer = try pixelBuffer(from: image.encodedBytes)
        return try await imageEmbedding(from: buffer)
    }

    private func imageEmbedding(from buffer: CVPixelBuffer) async throws
        -> NormalizedVisualEmbedding {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            Self.imageInputName: MLFeatureValue(pixelBuffer: buffer),
        ])
        let prediction: any MLFeatureProvider
        do {
            prediction = try await imageModel.prediction(from: provider)
        } catch {
            throw CoreMLVisualEmbeddingError.predictionFailed
        }
        try Task.checkCancellation()
        return try embedding(from: prediction)
    }

    public func embed(text: String) async throws -> NormalizedVisualEmbedding {
        try Task.checkCancellation()
        let tokenValues = try await tokenizer.tokenize(text)
        let tokens = try MLMultiArray(
            shape: [1, NSNumber(value: tokenValues.count)],
            dataType: .int32
        )
        for (index, value) in tokenValues.enumerated() {
            tokens[index] = NSNumber(value: value)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            Self.textInputName: MLFeatureValue(multiArray: tokens),
        ])
        let prediction: any MLFeatureProvider
        do {
            prediction = try await textModel.prediction(from: provider)
        } catch {
            throw CoreMLVisualEmbeddingError.predictionFailed
        }
        try Task.checkCancellation()
        return try embedding(from: prediction)
    }

    private func embedding(
        from provider: any MLFeatureProvider
    ) throws -> NormalizedVisualEmbedding {
        guard let array = provider.featureValue(for: Self.outputName)?.multiArrayValue,
              array.count == identity.embeddingDimension else {
            throw CoreMLVisualEmbeddingError.invalidModelOutput
        }
        var values = [Float]()
        values.reserveCapacity(array.count)
        for index in 0..<array.count {
            values.append(array[index].floatValue)
        }
        do {
            return try NormalizedVisualEmbedding(normalizing: values)
        } catch {
            throw CoreMLVisualEmbeddingError.invalidModelOutput
        }
    }

    private func pixelBuffer(from data: Data) throws -> CVPixelBuffer {
        guard let image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ), image.extent.width > 0, image.extent.height > 0 else {
            throw CoreMLVisualEmbeddingError.imageDecodeFailed
        }

        // PE's official preprocessing contract is a bilinear squash, not a
        // center crop. Translate non-zero image origins before independent X/Y
        // scaling so window and full-display captures use identical geometry.
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
        let resized = normalized.transformed(by: CGAffineTransform(
            scaleX: CGFloat(imageWidth) / image.extent.width,
            y: CGFloat(imageHeight) / image.extent.height
        ))
        let buffer = try Self.makePixelBuffer(width: imageWidth, height: imageHeight)
        ciContext.render(
            resized,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return buffer
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw CoreMLVisualEmbeddingError.pixelBufferCreationFailed
        }
        return buffer
    }

    private static func validateInterfaces(
        image: MLModel,
        text: MLModel,
        embeddingDimension: Int,
        contextLength: Int
    ) throws {
        let imageDescription = image.modelDescription
        let textDescription = text.modelDescription
        guard imageDescription.inputDescriptionsByName[imageInputName]?.type == .image,
              imageDescription.outputDescriptionsByName[outputName]?.type == .multiArray,
              textDescription.inputDescriptionsByName[textInputName]?.type == .multiArray,
              textDescription.outputDescriptionsByName[outputName]?.type == .multiArray,
              imageDescription.outputDescriptionsByName[outputName]?
                .multiArrayConstraint?.shape.map(\.intValue).last == embeddingDimension,
              textDescription.outputDescriptionsByName[outputName]?
                .multiArrayConstraint?.shape.map(\.intValue).last == embeddingDimension,
              textDescription.inputDescriptionsByName[textInputName]?
                .multiArrayConstraint?.shape.map(\.intValue).last == contextLength else {
            throw CoreMLVisualEmbeddingError.incompatibleModelInterface
        }
    }

    private nonisolated static func milliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
