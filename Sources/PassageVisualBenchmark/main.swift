import PassageCore
import PassageStore
import PassageVisualEvaluation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

@main
enum PassageVisualBenchmark {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showsHelp {
                print(Options.help)
                return
            }
            try await run(options: options)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "The visual benchmark could not run."
            FileHandle.standardError.write(Data("passage-visual-benchmark: \(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(options: Options) async throws {
        let fileManager = FileManager.default
        let outputURL = try options.output.map {
            try SafeOutput.resolve($0, fileManager: fileManager)
        }
        let paths = try PassagePaths.live(fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: paths.database.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw BenchmarkError.missingDatabase
        }

        let vaultKey: VaultKey
        do {
            vaultKey = try KeychainVaultKeyStore().loadExisting()
        } catch VaultKeyError.keyNotFound {
            throw BenchmarkError.missingKey
        } catch {
            throw BenchmarkError.unavailableKey
        }

        let store: SQLiteFrameStore
        do {
            store = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey, readOnly: true)
        } catch {
            throw BenchmarkError.unreadableVault
        }
        let mediaStore = MediaStore(paths: paths, vaultKey: vaultKey)

        let reportData: Data
        let summary: String
        if let localEncoder = options.localEncoder {
            let report = try await runCrossModal(
                options: options,
                localEncoder: localEncoder,
                store: store,
                mediaStore: mediaStore,
                fileManager: fileManager
            )
            reportData = try ReportEncoder.encode(report)
            summary = "Scored \(report.scoredFrameCount) of \(report.selectedFrameCount) selected moments; wrote aggregate local evaluation."
        } else {
            let report = try await runVision(
                options: options,
                store: store,
                mediaStore: mediaStore
            )
            reportData = try ReportEncoder.encode(report)
            summary = "Analyzed \(report.analyzedFrameCount) of \(report.selectedFrameCount) selected moments; wrote private local evaluation."
        }

        if let outputURL {
            try reportData.write(
                to: outputURL,
                options: PassageFileProtection.atomicWritingOptions
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
            // The output filename is intentionally omitted so stdout contains
            // no filesystem paths, even when a caller supplied one.
            print(summary)
        } else {
            FileHandle.standardOutput.write(reportData)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func runVision(
        options: Options,
        store: SQLiteFrameStore,
        mediaStore: MediaStore
    ) async throws -> VisionBenchmarkReport {
        let hits = try await selectedHits(
            from: store,
            selection: options.selection,
            maximumCount: options.maximumFrameCount
        )
        var results = [FrameAnalysis]()
        var skippedCount = 0
        for hit in hits {
            guard !hit.context.isSensitive else {
                skippedCount += 1
                continue
            }

            var inputAnalyses = [ImageAnalysis]()
            for input in options.inputs {
                guard let relativePath = input.relativePath(in: hit), !relativePath.isEmpty else {
                    continue
                }
                do {
                    // Decrypted bytes remain process memory only. Vision decodes
                    // them directly; no plaintext image is ever created.
                    let imageData = try await mediaStore.read(relativePath: relativePath)
                    let observation = try VisionAnalyzer.analyze(imageData: imageData)
                    inputAnalyses.append(ImageAnalysis(
                        inputKind: input.reportName,
                        labels: observation.labels,
                        faceCount: observation.faceCount,
                        personCount: observation.personCount
                    ))
                } catch {
                    // Individual corrupt or unsupported images must not leak
                    // paths or decoder details into this diagnostic's output.
                    continue
                }
            }
            if inputAnalyses.isEmpty {
                skippedCount += 1
            } else {
                results.append(FrameAnalysis(
                    frameID: hit.id.rawValue,
                    applicationName: hit.context.applicationName,
                    capturedAt: hit.capturedAt,
                    inputs: inputAnalyses
                ))
            }
        }

        return VisionBenchmarkReport(
            schemaVersion: 2,
            mode: "apple-vision-observation",
            selectionMode: options.selection.reportName,
            requestedLimit: options.requestedLimitReportValue,
            selectedFrameCount: hits.count,
            analyzedFrameCount: results.count,
            skippedFrameCount: skippedCount,
            frames: results
        )
    }

    private static func runCrossModal(
        options: Options,
        localEncoder: LocalEncoderOptions,
        store: SQLiteFrameStore,
        mediaStore: MediaStore,
        fileManager: FileManager
    ) async throws -> CrossModalBenchmarkReport {
        let positiveHits: [SearchHit]
        let corpusHits: [SearchHit]
        do {
            // Freeze the lexical proxy set before any visual inference begins.
            positiveHits = try await recallAll(
                from: store,
                scope: RecallScope(text: localEncoder.positiveQuery),
                maximumCount: nil
            )
            corpusHits = try await selectedHits(
                from: store,
                selection: options.selection,
                maximumCount: options.maximumFrameCount
            )
        } catch {
            throw BenchmarkError.queryFailed
        }
        let frozenPositiveIDs = Set(positiveHits.map { $0.id.rawValue })
        guard !frozenPositiveIDs.isEmpty else {
            throw BenchmarkError.noPositiveExamples
        }

        let pythonURL = RuntimePath.resolve(localEncoder.pythonPath, fileManager: fileManager)
        let scriptURL = RuntimePath.resolve(localEncoder.bridgeScriptPath, fileManager: fileManager)
        let cacheURL = RuntimePath.resolve(localEncoder.cacheDirectoryPath, fileManager: fileManager)
        let encoder: LocalVisualEncoder
        do {
            encoder = try LocalVisualEncoder(
                pythonExecutable: pythonURL,
                bridgeScript: scriptURL,
                modelReference: localEncoder.modelReference,
                cacheDirectory: cacheURL,
                device: localEncoder.device,
                fileManager: fileManager
            )
        } catch {
            throw BenchmarkError.localEncoderUnavailable
        }
        defer { encoder.close() }

        let encoderPrompts = localEncoder.prompts.map {
            VisualEncoderPrompt(label: $0.label, text: $0.text)
        }
        let queryMetrics: VisualEncoderQueryMetrics
        do {
            queryMetrics = try encoder.configure(prompts: encoderPrompts)
        } catch {
            throw BenchmarkError.localEncoderUnavailable
        }

        var frames = [VisualFrameScores]()
        var childImageLatencies = [Double]()
        var bridgeImageLatencies = [Double]()
        var peakResidentBytes = encoder.startupMetrics.peakResidentBytes
        var sensitiveFrameCount = 0
        var mediaFailureCount = 0
        for hit in corpusHits {
            guard !hit.context.isSensitive else {
                sensitiveFrameCount += 1
                continue
            }

            var bestSimilarities: [Double]?
            var scoredAnInput = false
            for input in options.inputs {
                guard let relativePath = input.relativePath(in: hit), !relativePath.isEmpty else {
                    continue
                }
                do {
                    // Authenticated plaintext exists only as this in-memory Data
                    // value and the child process pipe payload.
                    let decryptedImageData = try await mediaStore.read(relativePath: relativePath)
                    let pipeImageData = try EncoderImageNormalizer.prepare(
                        decryptedImageData,
                        input: input
                    )
                    let scores = try encoder.score(imageData: pipeImageData)
                    childImageLatencies.append(scores.encodingMilliseconds)
                    bridgeImageLatencies.append(scores.bridgeRoundTripMilliseconds)
                    peakResidentBytes = Self.maximum(peakResidentBytes, scores.peakResidentBytes)
                    if let existing = bestSimilarities {
                        bestSimilarities = zip(existing, scores.similarities).map(max)
                    } else {
                        bestSimilarities = scores.similarities
                    }
                    scoredAnInput = true
                } catch let error as LocalVisualEncoderError {
                    switch error {
                    case .childProcessEnded, .invalidChildResponse, .queryEncodingFailed:
                        throw BenchmarkError.localEncoderUnavailable
                    default:
                        continue
                    }
                } catch {
                    continue
                }
            }
            if scoredAnInput, let bestSimilarities {
                frames.append(VisualFrameScores(
                    frameID: hit.id.rawValue,
                    similarities: bestSimilarities
                ))
            } else {
                mediaFailureCount += 1
            }
        }
        guard !frames.isEmpty else { throw BenchmarkError.noScorableImages }

        let scoredIDs = Set(frames.map(\.frameID))
        let eligiblePositiveIDs = frozenPositiveIDs.intersection(scoredIDs)
        let promptReports = localEncoder.prompts.enumerated().map { index, prompt in
            CrossModalPromptReport(
                label: prompt.label,
                role: prompt.role.rawValue,
                query: prompt.text,
                evaluation: VisualRanking.evaluate(
                    frames: frames,
                    promptIndex: index,
                    positiveFrameIDs: frozenPositiveIDs,
                    recallCutoffs: [1, 5, 10, 20],
                    reportedResultLimit: 20
                )
            )
        }
        let imageLatency = LatencySummary(
            values: childImageLatencies,
            bridgeValues: bridgeImageLatencies
        )
        return CrossModalBenchmarkReport(
            schemaVersion: 1,
            mode: "offline-cross-modal-ranking",
            bridge: "framed-stdio-v1",
            model: localEncoder.reportModelLabel,
            device: encoder.startupMetrics.device,
            selectionMode: options.selection.reportName,
            requestedLimit: options.requestedLimitReportValue,
            inputKinds: options.inputs.map(\.reportName),
            selectedFrameCount: corpusHits.count,
            scoredFrameCount: frames.count,
            skippedSensitiveFrameCount: sensitiveFrameCount,
            skippedMediaFrameCount: mediaFailureCount,
            positiveSelection: PositiveSelectionReport(
                method: "lexical-fts5",
                query: localEncoder.positiveQuery,
                frozenFrameCount: frozenPositiveIDs.count,
                eligibleScoredFrameCount: eligiblePositiveIDs.count,
                frozenFrameIDs: frozenPositiveIDs.sorted()
            ),
            runtime: CrossModalRuntimeReport(
                modelLoadMilliseconds: encoder.startupMetrics.modelLoadMilliseconds,
                queryEncodingMilliseconds: queryMetrics.encodingMilliseconds,
                queryBridgeRoundTripMilliseconds: queryMetrics.bridgeRoundTripMilliseconds,
                queryCount: queryMetrics.promptCount,
                embeddingDimensions: queryMetrics.embeddingDimensions,
                image: imageLatency,
                modelParameterBytes: encoder.startupMetrics.modelParameterBytes,
                modelArtifactBytes: encoder.startupMetrics.modelArtifactBytes,
                peakResidentBytes: peakResidentBytes
            ),
            prompts: promptReports,
            limitations: [
                "Harry Potter lexical matches are a coarse proxy for relevant video frames, not verified labels that a man or eyeglasses are visible.",
                "Recall excludes sensitive, missing, corrupt, and decoder-incompatible media that was not scored.",
                "A dual encoder estimates image-text similarity; it does not identify people, transcribe audio, or prove that an attribute belongs to a particular person.",
                "This local research runtime measures a cached model through Python and is not the latency or energy profile of a production Core ML integration.",
                "Control prompts use the same lexical proxy only to expose ranking bias; high or low control recall is not standalone retrieval quality.",
            ]
        )
    }

    private static func selectedHits(
        from store: SQLiteFrameStore,
        selection: Options.Selection,
        maximumCount: Int?
    ) async throws -> [SearchHit] {
        let scope: RecallScope
        switch selection {
        case .lexicalQuery(let text):
            scope = RecallScope(text: text)
        case .recent:
            scope = RecallScope()
        }
        return try await recallAll(
            from: store,
            scope: scope,
            maximumCount: maximumCount
        )
    }

    private static func recallAll(
        from store: SQLiteFrameStore,
        scope: RecallScope,
        maximumCount: Int?
    ) async throws -> [SearchHit] {
        var hits = [SearchHit]()
        var cursor: RecallCursor?
        repeat {
            let remaining = maximumCount.map { max($0 - hits.count, 0) }
            if remaining == 0 { break }
            let pageLimit = min(remaining ?? RecallPage.maximumLimit, RecallPage.maximumLimit)
            let page = try await store.recall(scope, after: cursor, limit: pageLimit)
            hits.append(contentsOf: page.hits)
            guard page.hasMore else { break }
            guard let nextCursor = page.nextCursor, nextCursor != cursor else {
                throw BenchmarkError.queryFailed
            }
            cursor = nextCursor
        } while maximumCount.map { hits.count < $0 } ?? true
        return hits
    }

    private static func maximum(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case (.none, .none): nil
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        }
    }
}

private struct Options: Equatable {
    enum Selection: Equatable {
        case lexicalQuery(String)
        case recent

        var reportName: String {
            switch self {
            case .lexicalQuery: "lexical-query"
            case .recent: "recent"
            }
        }
    }

    static let help = """
        Usage:
          passage-visual-benchmark --query <text> [--limit <count>|--all] [--input <thumbnail|full|both>] [--output <relative-path>]
          passage-visual-benchmark --recent [--limit <count>|--all] [--input <thumbnail|full|both>] [--output <relative-path>]
          passage-visual-benchmark --local-encoder --recent [--limit <count>|--all]
              --python <executable> --bridge-script <script> --model <local-id-or-path>
              --cache-dir <directory> [--model-label <name>] [--device <auto|cpu|mps>]
              [--positive-query <text>] [--prompt <label|role|query>]...
              [--input <thumbnail|full|both>] [--output <relative-path>]

        Apple Vision mode emits local classification/detection observations.
        Local-encoder mode pages the complete requested Recall scope, decrypts
        each selected image only in memory, sends its bytes to an offline local
        child process over standard input, and receives cosine scores only.

        --all removes the default 20-frame cap. A numeric limit may be as high as
        1,000,000 and is fulfilled through stable Recall pages of at most 200.
        Prompt roles are target, hard-negative, or control. Local-encoder mode
        supplies a general people/eyeglasses/control set when --prompt is omitted.
        Output paths must be relative and remain inside the current directory.
        Reports never contain OCR text, URLs, media paths, runtime paths, pixels,
        or key material.
        """

    var selection: Selection
    var maximumFrameCount: Int?
    var inputs: [ImageInput]
    var output: String?
    var localEncoder: LocalEncoderOptions?
    var showsHelp: Bool

    var requestedLimitReportValue: String {
        maximumFrameCount.map(String.init) ?? "all"
    }

    init(arguments: [String]) throws {
        var selection: Selection?
        var maximumFrameCount: Int? = 20
        var sawLimit = false
        var inputs: [ImageInput] = [.thumbnail]
        var sawInput = false
        var output: String?
        var showsHelp = false
        var localEncoderEnabled = false
        var pythonPath: String?
        var bridgeScriptPath: String?
        var modelReference: String?
        var modelLabel: String?
        var cacheDirectoryPath: String?
        var device = VisualEncoderDevice.automatic
        var positiveQuery = "Harry Potter"
        var promptSpecs = [PromptSpec]()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "-h", "--help":
                guard arguments.count == 1 else { throw BenchmarkError.helpMustBeUsedAlone }
                showsHelp = true
                index += 1
            case "--recent":
                guard selection == nil else { throw BenchmarkError.duplicateSelection }
                selection = .recent
                index += 1
            case "--query":
                guard selection == nil else { throw BenchmarkError.duplicateSelection }
                let value = try Self.value(after: index, in: arguments, option: "--query")
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw BenchmarkError.emptyQuery }
                selection = .lexicalQuery(trimmed)
                index += 2
            case "--limit":
                guard !sawLimit else { throw BenchmarkError.duplicateLimit }
                let value = try Self.value(after: index, in: arguments, option: "--limit")
                guard let parsed = Int(value), (1...1_000_000).contains(parsed) else {
                    throw BenchmarkError.invalidLimit
                }
                maximumFrameCount = parsed
                sawLimit = true
                index += 2
            case "--all":
                guard !sawLimit else { throw BenchmarkError.duplicateLimit }
                maximumFrameCount = nil
                sawLimit = true
                index += 1
            case "--input":
                guard !sawInput else { throw BenchmarkError.duplicateInput }
                let value = try Self.value(after: index, in: arguments, option: "--input")
                switch value {
                case "thumbnail":
                    inputs = [.thumbnail]
                case "full":
                    inputs = [.fullImage]
                case "both":
                    inputs = [.thumbnail, .fullImage]
                default:
                    throw BenchmarkError.invalidInput
                }
                sawInput = true
                index += 2
            case "--output":
                guard output == nil else { throw BenchmarkError.duplicateOutput }
                let value = try Self.value(after: index, in: arguments, option: "--output")
                guard !value.isEmpty else { throw BenchmarkError.invalidOutput }
                output = value
                index += 2
            case "--local-encoder":
                guard !localEncoderEnabled else { throw BenchmarkError.duplicateLocalEncoder }
                localEncoderEnabled = true
                index += 1
            case "--python":
                guard pythonPath == nil else { throw BenchmarkError.duplicateEncoderOption }
                pythonPath = try Self.value(after: index, in: arguments, option: "--python")
                index += 2
            case "--bridge-script":
                guard bridgeScriptPath == nil else { throw BenchmarkError.duplicateEncoderOption }
                bridgeScriptPath = try Self.value(
                    after: index,
                    in: arguments,
                    option: "--bridge-script"
                )
                index += 2
            case "--model":
                guard modelReference == nil else { throw BenchmarkError.duplicateEncoderOption }
                modelReference = try Self.value(after: index, in: arguments, option: "--model")
                index += 2
            case "--model-label":
                guard modelLabel == nil else { throw BenchmarkError.duplicateEncoderOption }
                modelLabel = try Self.value(after: index, in: arguments, option: "--model-label")
                index += 2
            case "--cache-dir":
                guard cacheDirectoryPath == nil else { throw BenchmarkError.duplicateEncoderOption }
                cacheDirectoryPath = try Self.value(
                    after: index,
                    in: arguments,
                    option: "--cache-dir"
                )
                index += 2
            case "--device":
                let value = try Self.value(after: index, in: arguments, option: "--device")
                guard let parsed = VisualEncoderDevice(rawValue: value) else {
                    throw BenchmarkError.invalidDevice
                }
                device = parsed
                index += 2
            case "--positive-query":
                let value = try Self.value(
                    after: index,
                    in: arguments,
                    option: "--positive-query"
                )
                positiveQuery = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !positiveQuery.isEmpty else { throw BenchmarkError.emptyPositiveQuery }
                index += 2
            case "--prompt":
                let value = try Self.value(after: index, in: arguments, option: "--prompt")
                promptSpecs.append(try PromptSpec(argument: value))
                index += 2
            default:
                throw BenchmarkError.unknownArgument
            }
        }

        if showsHelp {
            self.selection = .recent
        } else {
            guard let selection else { throw BenchmarkError.missingSelection }
            self.selection = selection
        }
        if localEncoderEnabled {
            guard let pythonPath, let bridgeScriptPath, let modelReference,
                  let cacheDirectoryPath,
                  !pythonPath.isEmpty, !bridgeScriptPath.isEmpty,
                  !modelReference.isEmpty, !cacheDirectoryPath.isEmpty else {
                throw BenchmarkError.missingEncoderOption
            }
            if promptSpecs.isEmpty { promptSpecs = PromptSpec.defaultEvaluationSet }
            guard Set(promptSpecs.map(\.label)).count == promptSpecs.count else {
                throw BenchmarkError.duplicatePromptLabel
            }
            self.localEncoder = LocalEncoderOptions(
                pythonPath: pythonPath,
                bridgeScriptPath: bridgeScriptPath,
                modelReference: modelReference,
                reportModelLabel: Self.safeModelLabel(modelLabel, modelReference: modelReference),
                cacheDirectoryPath: cacheDirectoryPath,
                device: device,
                positiveQuery: positiveQuery,
                prompts: promptSpecs
            )
        } else {
            let hasOrphanedEncoderOption = pythonPath != nil
                || bridgeScriptPath != nil
                || modelReference != nil
                || modelLabel != nil
                || cacheDirectoryPath != nil
                || !promptSpecs.isEmpty
                || positiveQuery != "Harry Potter"
                || device != .automatic
            guard !hasOrphanedEncoderOption else {
                throw BenchmarkError.missingLocalEncoderFlag
            }
            self.localEncoder = nil
        }
        self.maximumFrameCount = maximumFrameCount
        self.inputs = inputs
        self.output = output
        self.showsHelp = showsHelp
    }

    private static func value(
        after index: Int,
        in arguments: [String],
        option: String
    ) throws -> String {
        guard index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else {
            throw BenchmarkError.missingValue(option)
        }
        return arguments[index + 1]
    }

    private static func safeModelLabel(_ requested: String?, modelReference: String) -> String {
        let candidate = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty {
            return String(candidate.prefix(120))
        }
        let lastComponent = URL(fileURLWithPath: modelReference).lastPathComponent
        return lastComponent.isEmpty ? "local-visual-model" : String(lastComponent.prefix(120))
    }
}

private struct LocalEncoderOptions: Equatable {
    var pythonPath: String
    var bridgeScriptPath: String
    var modelReference: String
    var reportModelLabel: String
    var cacheDirectoryPath: String
    var device: VisualEncoderDevice
    var positiveQuery: String
    var prompts: [PromptSpec]
}

private struct PromptSpec: Equatable {
    enum Role: String, Equatable {
        case target
        case hardNegative = "hard-negative"
        case control
    }

    static let defaultEvaluationSet = [
        PromptSpec(label: "man", role: .target, text: "a man"),
        PromptSpec(label: "man-eyeglasses", role: .target, text: "a man wearing eyeglasses"),
        PromptSpec(
            label: "movie-man-eyeglasses",
            role: .target,
            text: "a movie scene featuring a man wearing eyeglasses"
        ),
        PromptSpec(
            label: "glasses-no-person",
            role: .hardNegative,
            text: "a pair of eyeglasses with no person visible"
        ),
        PromptSpec(
            label: "woman-eyeglasses",
            role: .hardNegative,
            text: "a woman wearing eyeglasses"
        ),
        PromptSpec(
            label: "workplace-chat",
            role: .control,
            text: "a workplace chat interface filled with text"
        ),
        PromptSpec(
            label: "landscape-no-people",
            role: .control,
            text: "an outdoor landscape with no people"
        ),
    ]

    var label: String
    var role: Role
    var text: String

    init(label: String, role: Role, text: String) {
        self.label = label
        self.role = role
        self.text = text
    }

    init(argument: String) throws {
        let pieces = argument.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { throw BenchmarkError.invalidPrompt }
        let label = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let roleText = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let text = pieces[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedLabelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !label.isEmpty, label.count <= 64,
              label.unicodeScalars.allSatisfy(allowedLabelCharacters.contains),
              let role = Role(rawValue: roleText),
              !text.isEmpty, text.count <= 2_048 else {
            throw BenchmarkError.invalidPrompt
        }
        self.init(label: label, role: role, text: text)
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case missingSelection
    case duplicateSelection
    case emptyQuery
    case duplicateLimit
    case invalidLimit
    case duplicateInput
    case invalidInput
    case duplicateOutput
    case invalidOutput
    case duplicateLocalEncoder
    case duplicateEncoderOption
    case missingEncoderOption
    case missingLocalEncoderFlag
    case invalidDevice
    case emptyPositiveQuery
    case invalidPrompt
    case duplicatePromptLabel
    case unknownArgument
    case missingValue(String)
    case helpMustBeUsedAlone
    case missingDatabase
    case missingKey
    case unavailableKey
    case unreadableVault
    case queryFailed
    case noPositiveExamples
    case noScorableImages
    case localEncoderUnavailable

    var errorDescription: String? {
        switch self {
        case .missingSelection:
            "Choose exactly one of --query <text> or --recent."
        case .duplicateSelection:
            "Use only one --query or --recent selection."
        case .emptyQuery:
            "--query requires non-empty text."
        case .duplicateLimit:
            "Use only one --limit or --all selection."
        case .invalidLimit:
            "--limit must be a whole number from 1 through 1,000,000."
        case .duplicateInput:
            "--input may be provided only once."
        case .invalidInput:
            "--input must be thumbnail, full, or both."
        case .duplicateOutput:
            "--output may be provided only once."
        case .invalidOutput:
            "--output must name a regular file inside the current directory."
        case .duplicateLocalEncoder:
            "--local-encoder may be provided only once."
        case .duplicateEncoderOption:
            "A local encoder option was provided more than once."
        case .missingEncoderOption:
            "Local-encoder mode requires --python, --bridge-script, --model, and --cache-dir."
        case .missingLocalEncoderFlag:
            "Local encoder options require --local-encoder."
        case .invalidDevice:
            "--device must be auto, cpu, or mps."
        case .emptyPositiveQuery:
            "--positive-query requires non-empty text."
        case .invalidPrompt:
            "--prompt must use label|target|query, label|hard-negative|query, or label|control|query."
        case .duplicatePromptLabel:
            "Each --prompt label must be unique."
        case .unknownArgument:
            "An argument was not recognized. Run with --help for usage."
        case .missingValue(let option):
            "\(option) requires a value."
        case .helpMustBeUsedAlone:
            "--help must be used by itself."
        case .missingDatabase:
            "No existing Passage database was found. Open Passage first."
        case .missingKey:
            "No existing Passage vault key was found. Open Passage first."
        case .unavailableKey:
            "Passage's existing vault key is unavailable to this process."
        case .unreadableVault:
            "Passage's existing vault could not be opened read-only."
        case .queryFailed:
            "Passage could not select benchmark moments from the read-only vault."
        case .noPositiveExamples:
            "The lexical positive query did not select any benchmark moments."
        case .noScorableImages:
            "None of the selected, non-sensitive images could be scored locally."
        case .localEncoderUnavailable:
            "The offline local visual encoder could not complete the evaluation."
        }
    }
}

private enum SafeOutput {
    static func resolve(_ path: String, fileManager: FileManager) throws -> URL {
        guard !path.hasPrefix("/") else { throw BenchmarkError.invalidOutput }
        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let proposed = currentDirectory
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
        let parent = proposed.deletingLastPathComponent().resolvingSymlinksInPath()
        guard isInside(parent, root: currentDirectory) else {
            throw BenchmarkError.invalidOutput
        }

        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw BenchmarkError.invalidOutput
        }

        let destination = parent.appendingPathComponent(proposed.lastPathComponent)
        guard destination.lastPathComponent != ".",
              destination.lastPathComponent != ".." else {
            throw BenchmarkError.invalidOutput
        }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BenchmarkError.invalidOutput
            }
        }
        return destination
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}

private enum RuntimePath {
    static func resolve(_ path: String, fileManager: FileManager) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(path)
        .standardizedFileURL
    }
}

private enum VisionAnalyzer {
    struct Observation {
        var labels: [VisualLabel]
        var faceCount: Int
        var personCount: Int
    }

    static func analyze(imageData: Data) throws -> Observation {
        let classification = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([classification, faces, people])

        let labels = (classification.results ?? [])
            .filter { $0.confidence >= 0.05 }
            .prefix(8)
            .map { VisualLabel(name: $0.identifier, confidence: $0.confidence) }
        return Observation(
            labels: Array(labels),
            faceCount: faces.results?.count ?? 0,
            personCount: people.results?.count ?? 0
        )
    }
}

private enum ImageInput: Equatable {
    case thumbnail
    case fullImage

    var reportName: String {
        switch self {
        case .thumbnail: "thumbnail"
        case .fullImage: "full-image"
        }
    }

    func relativePath(in hit: SearchHit) -> String? {
        switch self {
        case .thumbnail: hit.thumbnailRelativePath
        case .fullImage: hit.imageRelativePath
        }
    }
}

private enum EncoderImageNormalizer {
    /// Passage full images may use HEIC, which a minimal local Python/Pillow
    /// runtime cannot necessarily decode. Convert those inputs to JPEG entirely
    /// in memory before writing them to the child pipe. Thumbnails are already
    /// JPEG and stay byte-for-byte unchanged.
    static func prepare(_ data: Data, input: ImageInput) throws -> Data {
        guard input == .fullImage else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BenchmarkError.noScorableImages
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw BenchmarkError.noScorableImages
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw BenchmarkError.noScorableImages
        }
        return output as Data
    }
}

private struct VisualLabel: Codable, Equatable {
    var name: String
    var confidence: Float
}

private struct ImageAnalysis: Codable, Equatable {
    var inputKind: String
    var labels: [VisualLabel]
    var faceCount: Int
    var personCount: Int
}

private struct FrameAnalysis: Codable, Equatable {
    var frameID: String
    var applicationName: String
    var capturedAt: Date
    var inputs: [ImageAnalysis]
}

private struct VisionBenchmarkReport: Codable, Equatable {
    var schemaVersion: Int
    var mode: String
    var selectionMode: String
    var requestedLimit: String
    var selectedFrameCount: Int
    var analyzedFrameCount: Int
    var skippedFrameCount: Int
    var frames: [FrameAnalysis]
}

private struct CrossModalBenchmarkReport: Codable, Equatable {
    var schemaVersion: Int
    var mode: String
    var bridge: String
    var model: String
    var device: String
    var selectionMode: String
    var requestedLimit: String
    var inputKinds: [String]
    var selectedFrameCount: Int
    var scoredFrameCount: Int
    var skippedSensitiveFrameCount: Int
    var skippedMediaFrameCount: Int
    var positiveSelection: PositiveSelectionReport
    var runtime: CrossModalRuntimeReport
    var prompts: [CrossModalPromptReport]
    var limitations: [String]
}

private struct PositiveSelectionReport: Codable, Equatable {
    var method: String
    var query: String
    var frozenFrameCount: Int
    var eligibleScoredFrameCount: Int
    var frozenFrameIDs: [String]
}

private struct CrossModalRuntimeReport: Codable, Equatable {
    var modelLoadMilliseconds: Double
    var queryEncodingMilliseconds: Double
    var queryBridgeRoundTripMilliseconds: Double
    var queryCount: Int
    var embeddingDimensions: Int
    var image: LatencySummary
    var modelParameterBytes: Int64
    var modelArtifactBytes: Int64?
    var peakResidentBytes: Int64?
}

private struct CrossModalPromptReport: Codable, Equatable {
    var label: String
    var role: String
    var query: String
    var evaluation: VisualRetrievalEvaluation
}

private struct LatencySummary: Codable, Equatable {
    var sampleCount: Int
    var totalEncodingMilliseconds: Double
    var meanEncodingMilliseconds: Double?
    var p50EncodingMilliseconds: Double?
    var p95EncodingMilliseconds: Double?
    var maximumEncodingMilliseconds: Double?
    var p50BridgeRoundTripMilliseconds: Double?
    var p95BridgeRoundTripMilliseconds: Double?

    init(values: [Double], bridgeValues: [Double]) {
        sampleCount = values.count
        totalEncodingMilliseconds = values.reduce(0, +)
        meanEncodingMilliseconds = values.isEmpty
            ? nil
            : totalEncodingMilliseconds / Double(values.count)
        p50EncodingMilliseconds = VisualRanking.percentile(values, percentile: 0.50)
        p95EncodingMilliseconds = VisualRanking.percentile(values, percentile: 0.95)
        maximumEncodingMilliseconds = values.max()
        p50BridgeRoundTripMilliseconds = VisualRanking.percentile(
            bridgeValues,
            percentile: 0.50
        )
        p95BridgeRoundTripMilliseconds = VisualRanking.percentile(
            bridgeValues,
            percentile: 0.95
        )
    }
}

private enum ReportEncoder {
    static func encode<Value: Encodable>(_ report: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
