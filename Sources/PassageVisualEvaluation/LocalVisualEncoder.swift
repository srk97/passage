import Foundation

/// A text prompt encoded once by the local visual model.
public struct VisualEncoderPrompt: Hashable, Sendable {
    public var label: String
    public var text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

public enum VisualEncoderDevice: String, Sendable {
    case automatic = "auto"
    case cpu
    case mps
}

public struct VisualEncoderStartupMetrics: Equatable, Sendable {
    public var device: String
    public var modelLoadMilliseconds: Double
    public var modelParameterBytes: Int64
    public var modelArtifactBytes: Int64?
    public var peakResidentBytes: Int64?

    public init(
        device: String,
        modelLoadMilliseconds: Double,
        modelParameterBytes: Int64,
        modelArtifactBytes: Int64?,
        peakResidentBytes: Int64?
    ) {
        self.device = device
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.modelParameterBytes = modelParameterBytes
        self.modelArtifactBytes = modelArtifactBytes
        self.peakResidentBytes = peakResidentBytes
    }
}

public struct VisualEncoderQueryMetrics: Equatable, Sendable {
    public var promptCount: Int
    public var embeddingDimensions: Int
    public var encodingMilliseconds: Double
    public var bridgeRoundTripMilliseconds: Double

    public init(
        promptCount: Int,
        embeddingDimensions: Int,
        encodingMilliseconds: Double,
        bridgeRoundTripMilliseconds: Double
    ) {
        self.promptCount = promptCount
        self.embeddingDimensions = embeddingDimensions
        self.encodingMilliseconds = encodingMilliseconds
        self.bridgeRoundTripMilliseconds = bridgeRoundTripMilliseconds
    }
}

public struct VisualEncoderImageScores: Equatable, Sendable {
    /// Cosine similarities against the configured prompts, in prompt order.
    public var similarities: [Double]
    public var encodingMilliseconds: Double
    public var bridgeRoundTripMilliseconds: Double
    public var peakResidentBytes: Int64?

    public init(
        similarities: [Double],
        encodingMilliseconds: Double,
        bridgeRoundTripMilliseconds: Double,
        peakResidentBytes: Int64?
    ) {
        self.similarities = similarities
        self.encodingMilliseconds = encodingMilliseconds
        self.bridgeRoundTripMilliseconds = bridgeRoundTripMilliseconds
        self.peakResidentBytes = peakResidentBytes
    }
}

public enum LocalVisualEncoderError: Error, LocalizedError, Sendable {
    case invalidExecutable
    case invalidBridgeScript
    case invalidCacheDirectory
    case emptyModelReference
    case launchFailed
    case modelLoadFailed
    case invalidPrompts
    case imageTooLarge
    case childProcessEnded
    case invalidChildResponse
    case queryEncodingFailed
    case imageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable:
            "The configured local Python runtime is unavailable."
        case .invalidBridgeScript:
            "The configured local encoder bridge is unavailable."
        case .invalidCacheDirectory:
            "The configured local model cache is unavailable."
        case .emptyModelReference:
            "The local model reference is empty."
        case .launchFailed:
            "The local encoder process could not start."
        case .modelLoadFailed:
            "The cached local visual model could not be loaded."
        case .invalidPrompts:
            "At least one non-empty visual query is required."
        case .imageTooLarge:
            "A selected image exceeds the local encoder safety limit."
        case .childProcessEnded:
            "The local encoder process ended unexpectedly."
        case .invalidChildResponse:
            "The local encoder returned an invalid response."
        case .queryEncodingFailed:
            "The local encoder could not encode the visual queries."
        case .imageEncodingFailed:
            "The local encoder could not score a selected image."
        }
    }
}

/// A privacy-bounded bridge to a local-only visual encoder child process.
///
/// Decrypted image bytes are written directly to the child's standard-input
/// pipe. The child returns cosine similarities and aggregate timings only. The
/// bridge never creates a plaintext image file, forwards child diagnostics, or
/// includes runtime paths in its public errors.
public final class LocalVisualEncoder {
    public static let maximumImageBytes = 128 * 1_024 * 1_024

    public let startupMetrics: VisualEncoderStartupMetrics

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var configuredPromptCount = 0
    private var isClosed = false

    public init(
        pythonExecutable: URL,
        bridgeScript: URL,
        modelReference: String,
        cacheDirectory: URL,
        device: VisualEncoderDevice = .automatic,
        fileManager: FileManager = .default
    ) throws {
        guard Self.isExecutable(pythonExecutable, fileManager: fileManager) else {
            throw LocalVisualEncoderError.invalidExecutable
        }
        guard Self.isRegularFile(bridgeScript, fileManager: fileManager) else {
            throw LocalVisualEncoderError.invalidBridgeScript
        }
        guard Self.isDirectory(cacheDirectory, fileManager: fileManager) else {
            throw LocalVisualEncoderError.invalidCacheDirectory
        }
        let trimmedModel = modelReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw LocalVisualEncoderError.emptyModelReference
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = pythonExecutable.standardizedFileURL
        process.arguments = [
            bridgeScript.standardizedFileURL.path,
            "--model", trimmedModel,
            "--cache-dir", cacheDirectory.standardizedFileURL.path,
            "--device", device.rawValue,
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Library/model diagnostics can contain cache paths. They are discarded
        // instead of being copied into Passage's terminal or benchmark report.
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = cacheDirectory.standardizedFileURL.path
        environment["HF_HUB_CACHE"] = cacheDirectory
            .appendingPathComponent("hub", isDirectory: true)
            .standardizedFileURL.path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_DATASETS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw LocalVisualEncoderError.launchFailed
        }

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading

        do {
            let response: ReadyResponse = try WireCodec.readJSON(from: output)
            guard response.ok, response.kind == "ready",
                  let device = response.device,
                  let loadMilliseconds = response.modelLoadMilliseconds,
                  let parameterBytes = response.modelParameterBytes else {
                throw LocalVisualEncoderError.modelLoadFailed
            }
            self.startupMetrics = VisualEncoderStartupMetrics(
                device: device,
                modelLoadMilliseconds: loadMilliseconds,
                modelParameterBytes: parameterBytes,
                modelArtifactBytes: response.modelArtifactBytes,
                peakResidentBytes: response.peakResidentBytes
            )
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            if process.isRunning { process.terminate() }
            if let localError = error as? LocalVisualEncoderError {
                throw localError
            }
            throw LocalVisualEncoderError.modelLoadFailed
        }
    }

    deinit {
        close()
    }

    public func configure(prompts: [VisualEncoderPrompt]) throws -> VisualEncoderQueryMetrics {
        let texts = prompts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !texts.isEmpty, texts.allSatisfy({ !$0.isEmpty }) else {
            throw LocalVisualEncoderError.invalidPrompts
        }
        guard !isClosed, process.isRunning else {
            throw LocalVisualEncoderError.childProcessEnded
        }

        let request = Request(operation: "configure", prompts: texts, payloadBytes: 0)
        let startedAt = ContinuousClock.now
        do {
            try WireCodec.writeJSON(request, payload: nil, to: input)
            let response: ConfigureResponse = try WireCodec.readJSON(from: output)
            guard response.ok, response.kind == "configured",
                  response.promptCount == texts.count,
                  let dimensions = response.embeddingDimensions,
                  let encodingMilliseconds = response.encodingMilliseconds else {
                throw LocalVisualEncoderError.queryEncodingFailed
            }
            configuredPromptCount = texts.count
            return VisualEncoderQueryMetrics(
                promptCount: texts.count,
                embeddingDimensions: dimensions,
                encodingMilliseconds: encodingMilliseconds,
                bridgeRoundTripMilliseconds: Self.milliseconds(since: startedAt)
            )
        } catch let error as LocalVisualEncoderError {
            throw error
        } catch {
            throw LocalVisualEncoderError.queryEncodingFailed
        }
    }

    public func score(imageData: Data) throws -> VisualEncoderImageScores {
        guard configuredPromptCount > 0 else {
            throw LocalVisualEncoderError.invalidPrompts
        }
        guard !imageData.isEmpty, imageData.count <= Self.maximumImageBytes else {
            throw LocalVisualEncoderError.imageTooLarge
        }
        guard !isClosed, process.isRunning else {
            throw LocalVisualEncoderError.childProcessEnded
        }

        let request = Request(
            operation: "score-image",
            prompts: nil,
            payloadBytes: imageData.count
        )
        let startedAt = ContinuousClock.now
        do {
            try WireCodec.writeJSON(request, payload: imageData, to: input)
            let response: ScoreResponse = try WireCodec.readJSON(from: output)
            guard response.ok, response.kind == "scores",
                  let similarities = response.similarities,
                  similarities.count == configuredPromptCount,
                  similarities.allSatisfy({ $0.isFinite && (-1.000_001...1.000_001).contains($0) }),
                  let encodingMilliseconds = response.encodingMilliseconds else {
                throw LocalVisualEncoderError.imageEncodingFailed
            }
            return VisualEncoderImageScores(
                similarities: similarities.map { min(max($0, -1), 1) },
                encodingMilliseconds: encodingMilliseconds,
                bridgeRoundTripMilliseconds: Self.milliseconds(since: startedAt),
                peakResidentBytes: response.peakResidentBytes
            )
        } catch let error as LocalVisualEncoderError {
            throw error
        } catch {
            throw LocalVisualEncoderError.imageEncodingFailed
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if process.isRunning {
            let request = Request(operation: "shutdown", prompts: nil, payloadBytes: 0)
            try? WireCodec.writeJSON(request, payload: nil, to: input)
        }
        input.closeFile()
        output.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    private static func isExecutable(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) && fileManager.isExecutableFile(atPath: url.path)
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private struct Request: Codable {
    var operation: String
    var prompts: [String]?
    var payloadBytes: Int
}

private struct ReadyResponse: Decodable {
    var ok: Bool
    var kind: String?
    var device: String?
    var modelLoadMilliseconds: Double?
    var modelParameterBytes: Int64?
    var modelArtifactBytes: Int64?
    var peakResidentBytes: Int64?
}

private struct ConfigureResponse: Decodable {
    var ok: Bool
    var kind: String?
    var promptCount: Int?
    var embeddingDimensions: Int?
    var encodingMilliseconds: Double?
}

private struct ScoreResponse: Decodable {
    var ok: Bool
    var kind: String?
    var similarities: [Double]?
    var encodingMilliseconds: Double?
    var peakResidentBytes: Int64?
}

enum WireCodec {
    static let maximumJSONBytes = 8 * 1_024 * 1_024

    static func writeJSON<Value: Encodable>(
        _ value: Value,
        payload: Data?,
        to handle: FileHandle
    ) throws {
        let data = try JSONEncoder().encode(value)
        guard !data.isEmpty, data.count <= maximumJSONBytes else {
            throw LocalVisualEncoderError.invalidChildResponse
        }
        var length = UInt32(data.count).bigEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        try handle.write(contentsOf: prefix)
        try handle.write(contentsOf: data)
        if let payload, !payload.isEmpty {
            try handle.write(contentsOf: payload)
        }
    }

    static func readJSON<Value: Decodable>(
        _ type: Value.Type = Value.self,
        from handle: FileHandle
    ) throws -> Value {
        let prefix = try readExactly(4, from: handle)
        let encodedLength = prefix.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let length = Int(UInt32(bigEndian: encodedLength))
        guard (1...maximumJSONBytes).contains(length) else {
            throw LocalVisualEncoderError.invalidChildResponse
        }
        let data = try readExactly(length, from: handle)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LocalVisualEncoderError.invalidChildResponse
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count),
                  !chunk.isEmpty else {
                throw LocalVisualEncoderError.childProcessEnded
            }
            result.append(chunk)
        }
        return result
    }
}
