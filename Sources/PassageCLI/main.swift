import PassageAgentSupport
import PassageCore
import PassageService
import Foundation

@main
enum PassageCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, !["help", "-h", "--help"].contains(command) else {
                print(help)
                return
            }
            if arguments.dropFirst().contains(where: { ["help", "-h", "--help"].contains($0) }) {
                print(command == "install-skill" ? installSkillHelp : help)
                return
            }

            switch command {
            case "version", "--version":
                printVersion()
            case "install-skill":
                try installSkill(arguments: Array(arguments.dropFirst()))
            case "capabilities":
                let client = try openClient()
                try capabilities(arguments: Array(arguments.dropFirst()), client: client)
            case "health":
                let client = try openClient()
                try health(arguments: Array(arguments.dropFirst()), client: client)
            case "bundle":
                let client = try openClient()
                try bundle(arguments: Array(arguments.dropFirst()), client: client)
            case "remember":
                let client = try openClient()
                try remember(arguments: Array(arguments.dropFirst()), client: client)
            case "visual":
                let client = try openClient()
                try visual(arguments: Array(arguments.dropFirst()), client: client)
            case "search":
                let client = try openClient()
                try await search(arguments: Array(arguments.dropFirst()), client: client)
            case "recent":
                let client = try openClient()
                try await recent(arguments: Array(arguments.dropFirst()), client: client)
            case "sessions":
                let client = try openClient()
                try sessions(arguments: Array(arguments.dropFirst()), client: client)
            case "frame":
                let client = try openClient()
                try await frame(arguments: Array(arguments.dropFirst()), client: client)
            case "stats":
                let client = try openClient()
                try await stats(arguments: Array(arguments.dropFirst()), client: client)
            default:
                throw PassageError.invalidQuery("Unknown command “\(command)”. Run passage help.")
            }
        } catch {
            FileHandle.standardError.write(Data("passage: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func openClient() throws -> PassageLocalServiceClient {
        let environment = ProcessInfo.processInfo.environment
        // CHRONICLE_* forms remain accepted so agent sessions holding the
        // pre-rename skill instructions keep working until they reload it.
        let legacyClient = environment["CHRONICLE_CLIENT"]
        let identifier = environment["PASSAGE_CLIENT_ID"]
            ?? environment["PASSAGE_CLIENT"]
            ?? environment["CHRONICLE_CLIENT_ID"]
            ?? legacyClient
            ?? "app.chronicle.cli"
        let displayName = environment["PASSAGE_CLIENT_NAME"]
            ?? environment["PASSAGE_CLIENT"]?.capitalized
            ?? environment["CHRONICLE_CLIENT_NAME"]
            ?? legacyClient?.capitalized
            ?? "Passage CLI"
        return PassageLocalServiceClient(
            endpoint: try PassageServiceEndpoint.live(),
            identity: PassageServiceClientIdentity(
                identifier: String(identifier.prefix(128)),
                displayName: String(displayName.prefix(128)),
                version: PassageServiceProtocol.serviceVersion
            )
        )
    }

    private static func installSkill(arguments: [String]) throws {
        guard let hostArgument = arguments.first else {
            throw InstallSkillCommandError.missingHost
        }
        guard !hostArgument.hasPrefix("-") else {
            throw InstallSkillCommandError.missingHost
        }
        guard let host = AgentSkillHost(rawValue: hostArgument.lowercased()) else {
            throw InstallSkillCommandError.invalidHost(hostArgument)
        }

        var customDirectory: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--directory":
                guard customDirectory == nil else {
                    throw InstallSkillCommandError.duplicateDirectory
                }
                guard index + 1 < arguments.count else {
                    throw InstallSkillCommandError.missingDirectoryValue
                }
                let value = arguments[index + 1]
                guard !value.hasPrefix("-") else {
                    throw InstallSkillCommandError.missingDirectoryValue
                }
                customDirectory = value
                index += 2
            default:
                if argument.hasPrefix("-") {
                    throw InstallSkillCommandError.unknownOption(argument)
                }
                throw InstallSkillCommandError.unexpectedArgument(argument)
            }
        }

        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let skillsDirectory = try AgentSkillPathResolver.skillsDirectory(
            for: host,
            customPath: customDirectory,
            homeDirectory: homeDirectory,
            currentDirectory: currentDirectory
        )
        let executableURL = try AgentSkillPathResolver.resolve(
            CommandLine.arguments[0],
            homeDirectory: homeDirectory,
            currentDirectory: currentDirectory
        )

        let overrideURL: URL?
        if let overridePath = ProcessInfo.processInfo.environment["PASSAGE_SKILL_SOURCE"] {
            overrideURL = try AgentSkillPathResolver.resolve(
                overridePath,
                homeDirectory: homeDirectory,
                currentDirectory: currentDirectory
            )
        } else {
            overrideURL = nil
        }

        let source = try AgentSkillLocator.locate(
            executableURL: executableURL,
            currentDirectory: currentDirectory,
            overrideURL: overrideURL,
            fileManager: fileManager
        )
        let result = try AgentSkillInstaller.install(
            host: host,
            source: source,
            skillsDirectory: skillsDirectory,
            fileManager: fileManager
        )

        switch result.status {
        case .installed:
            print("Installed Passage memory for \(host.displayName).")
        case .alreadyInstalled:
            print("Passage memory is already installed for \(host.displayName).")
        }
        print("\(result.destination.path) -> \(result.source.path)")
    }

    private static func search(arguments: [String], client: PassageLocalServiceClient) async throws {
        let options = try Options(arguments: arguments, requiresText: true)
        let hits = try client.search(SearchQuery(
            text: options.text,
            startDate: options.startDate,
            endDate: options.endDate,
            applicationBundleIdentifiers: Set(options.applications),
            domains: Set(options.domains),
            activitySessionIDs: Set(options.activitySessionIDs),
            limit: options.limit
        ))
        output(hits, asJSON: options.json)
    }

    private static func capabilities(
        arguments: [String],
        client: PassageLocalServiceClient
    ) throws {
        try validateJSONOnlyArguments(arguments, command: "capabilities")
        let value = try client.capabilities()
        if arguments.contains("--json") {
            try printJSON(value)
        } else {
            print("Passage \(value.serviceVersion)")
            print("Service protocol: \(value.protocolVersion)")
            print("Bundle schema: \(value.bundleSchemaVersion)")
            print("Capabilities: \(value.capabilities.map(\.rawValue).joined(separator: ", "))")
            print("Bundle bounds: \(value.defaultBundleResultLimit) results / \(value.defaultBundleUTF8ByteBudget) bytes by default")
            if value.capabilities.contains(.visualSearch) {
                print("Visual-search schema: \(value.visualSearchSchemaVersion)")
                print("Visual-search bounds: \(value.defaultVisualSearchResultLimit) results / \(value.defaultVisualSearchUTF8ByteBudget) bytes by default")
            }
            if value.capabilities.contains(.memoryCapsule) {
                print("Memory-capsule schema: \(value.memoryCapsuleSchemaVersion)")
                print("Memory-capsule bounds: \(value.defaultMemoryCapsuleResultLimit) results / \(value.defaultMemoryCapsuleUTF8ByteBudget) bytes by default")
            }
            print("Disclosure: bounded text/native semantics and visual-match metadata; no pixels or paths")
            print("Policy: default deny; audited before response")
        }
    }

    private static func health(
        arguments: [String],
        client: PassageLocalServiceClient
    ) throws {
        try validateJSONOnlyArguments(arguments, command: "health")
        let value = try client.health()
        if arguments.contains("--json") {
            try printJSON(value)
        } else {
            print("Passage service: \(value.status.rawValue)")
            print("Service \(value.serviceVersion), protocol \(value.protocolVersion), bundle schema \(value.bundleSchemaVersion)")
        }
    }

    private static func bundle(
        arguments: [String],
        client: PassageLocalServiceClient
    ) throws {
        let options = try Options(
            arguments: arguments,
            requiresText: false,
            defaultLimit: PassageContextBundleSchema.defaultResultLimit,
            manifestMode: .bundle
        )
        let request = PassageContextBundleRequest(
            query: SearchQuery(
                text: options.text,
                startDate: options.startDate,
                endDate: options.endDate,
                applicationBundleIdentifiers: Set(options.applications),
                domains: Set(options.domains),
                activitySessionIDs: Set(options.activitySessionIDs),
                limit: options.limit
            ),
            resultLimit: options.limit,
            utf8ByteBudget: options.byteBudget
        )
        let value = try client.bundle(request)
        if options.json {
            try printCompactJSON(value)
            return
        }

        print("Bundle schema \(value.schemaVersion): \(value.disclosedCount) disclosed / \(value.candidateCount) candidates / \(value.requestedCount) requested")
        print("Disclosure: \(value.disclosure.rawValue) — source metadata and bounded OCR only")
        print("Bounds: \(value.encodedUTF8Bytes) / \(value.utf8ByteBudget) UTF-8 bytes; truncated: \(value.truncated); more candidates: \(value.hasMoreCandidates)")
        let lowerBound = value.coverage.isLowerBound ? "at least " : ""
        print(
            "Coverage (disclosed/available): "
                + "\(value.coverage.disclosedObservedRunCount)/\(lowerBound)\(value.coverage.observedRunCount) runs · "
                + "\(value.coverage.disclosedActivitySessionCount)/\(lowerBound)\(value.coverage.activitySessionCount) sessions · "
                + "\(value.coverage.disclosedApplicationCount)/\(lowerBound)\(value.coverage.applicationCount) apps · "
                + "\(value.coverage.disclosedDomainCount)/\(lowerBound)\(value.coverage.domainCount) domains · "
                + "\(value.coverage.disclosedTransitionCount)/\(lowerBound)\(value.coverage.transitionCount) transitions"
        )
        if value.omissions.isEmpty {
            print("Omissions: none")
        } else {
            let omissions = value.omissions.map { omission in
                let suffix = omission.countIsLowerBound ? "+" : ""
                return "\(omission.reason.rawValue)=\(omission.count)\(suffix)"
            }
            print("Omissions: \(omissions.joined(separator: ", "))")
        }
        for source in value.sources {
            let timestamp = source.capturedAt.formatted(.iso8601)
            let title = source.windowTitle ?? source.domain ?? "Untitled"
            var provenance = "frame \(source.frameID.rawValue) @ \(timestamp); rank \(source.retrievalRank)"
            if let run = source.run {
                provenance += "; run \(run.index)"
            }
            print("[\(provenance)] \(source.applicationName) — \(title)")
            if let run = source.run {
                let startedAt = run.startedAt.formatted(.iso8601)
                let endedAt = run.endedAt.formatted(.iso8601)
                print("  Observed run: \(startedAt) – \(endedAt); \(run.candidateCount) candidates; representative rank \(run.representativeRetrievalRank)")
            }
            if let sessionID = source.activitySessionID {
                print("  Session: \(sessionID.rawValue)")
            }
            if !source.reasons.isEmpty {
                print("  Selected for: \(source.reasons.map(\.rawValue).joined(separator: ", "))")
            }
            if let domain = source.domain { print("  Domain: \(domain)") }
            if let url = source.url { print("  URL: \(url)") }
            if !source.ocrSnippet.isEmpty {
                let suffix = source.snippetTruncated ? " [snippet truncated]" : ""
                print("  \(source.ocrSnippet)\(suffix)")
            }
        }
    }

    private static func visual(
        arguments: [String],
        client: PassageLocalServiceClient
    ) throws {
        let options = try Options(
            arguments: arguments,
            requiresText: true,
            defaultLimit: PassageAgentVisualSearchSchema.defaultResultLimit,
            manifestMode: .visual,
            requiredTextCommand: "visual"
        )
        let request = PassageAgentVisualSearchRequest(
            description: options.text,
            scope: RecallScope(
                startDate: options.startDate,
                endDate: options.endDate,
                applicationBundleIdentifiers: Set(options.applications),
                domains: Set(options.domains)
            ),
            resultLimit: options.limit,
            utf8ByteBudget: options.byteBudget
        )
        let value = try client.visualSearch(request)
        if options.json {
            try printCompactJSON(value)
            return
        }

        print("Visual-search schema \(value.schemaVersion): \(value.disclosedCount) disclosed / \(value.matchedCount) matched / \(value.requestedCount) requested")
        print("Disclosure: metadata only — no screenshot pixels, file paths, embedding vectors, geometry, or display/window IDs")
        print("Bounds: \(value.encodedUTF8Bytes) / \(value.utf8ByteBudget) UTF-8 bytes; truncated: \(value.truncated); more matches: \(value.hasMore)")
        print("Admission threshold: \(String(format: "%.3f", value.minimumSimilarity)) minimum possible similarity")
        let coverage = value.coverage
        let coveragePercent = coverage.coverageFraction.map {
            String(format: "%.1f%%", $0 * 100)
        } ?? "unknown"
        print(
            "Index coverage: \(coverage.indexedEligibleFrameCount)/\(coverage.eligibleFrameCount) eligible (\(coveragePercent)); "
                + "\(coverage.pendingEligibleFrameCount) pending; \(coverage.staleEmbeddingCount) stale"
        )
        let vectorBytes = ByteCountFormatter.string(
            fromByteCount: coverage.storedVectorPayloadBytes,
            countStyle: .file
        )
        print(
            "Index shape: \(coverage.indexedFrameCount) frame associations; "
                + "\(coverage.uniqueVectorCount) unique vectors; "
                + "\(coverage.deduplicatedFrameCount) deduplicated frames; \(vectorBytes) vector payload"
        )
        print("Model: \(coverage.model.identifier) \(coverage.model.revision) · \(coverage.model.embeddingDimension) dimensions")
        if value.omissionReasons.isEmpty {
            print("Omissions: none")
        } else {
            print("Omissions: \(value.omissionReasons.map(\.rawValue).joined(separator: ", "))")
        }
        for source in value.sources {
            let timestamp = source.capturedAt.formatted(.iso8601)
            let title = source.windowTitle ?? source.domain ?? "Untitled"
            let similarity = String(format: "%.3f", source.similarity)
            let lowerBound = String(format: "%.3f", source.minimumPossibleSimilarity)
            let maximumError = String(format: "%.3f", source.maximumSimilarityError)
            print("[visual frame \(source.frameID.rawValue) @ \(timestamp)] \(source.applicationName) — \(title)")
            print("  Similarity: \(similarity) (lower bound \(lowerBound); maximum error \(maximumError))")
            if let domain = source.domain { print("  Domain: \(domain)") }
            if let url = source.url { print("  URL: \(url)") }
            if source.associatedFrameCount > 1 {
                print("  Represents \(source.associatedFrameCount) retained frames of this scene")
            }
            if !source.ocrSnippet.isEmpty {
                let suffix = source.snippetTruncated ? " [snippet truncated]" : ""
                print("  \(source.ocrSnippet)\(suffix)")
            }
        }
    }

    private static func remember(
        arguments: [String],
        client: PassageLocalServiceClient
    ) throws {
        let options = try Options(
            arguments: arguments,
            requiresText: true,
            defaultLimit: PassageMemoryCapsuleSchema.defaultResultLimit,
            manifestMode: .memoryCapsule,
            requiredTextCommand: "remember"
        )
        let request = PassageMemoryCapsuleRequest(
            query: SearchQuery(
                text: options.text,
                startDate: options.startDate,
                endDate: options.endDate,
                applicationBundleIdentifiers: Set(options.applications),
                domains: Set(options.domains),
                activitySessionIDs: Set(options.activitySessionIDs),
                limit: options.limit
            ),
            resultLimit: options.limit,
            utf8ByteBudget: options.byteBudget
        )
        let value = try client.memoryCapsule(request)
        if options.json {
            try printCompactJSON(value)
            return
        }

        print("Memory Capsule schema \(value.schemaVersion): \(value.disclosedCount) disclosed / \(value.candidateCount) candidates / \(value.requestedCount) requested")
        print("Retrieval: \(value.retrievalModalities.map(\.rawValue).joined(separator: " + "))")
        print("Disclosure: bounded OCR, native app semantics, visual-match provenance, and source metadata — no pixels, paths, or vectors")
        print("Bounds: \(value.encodedUTF8Bytes) / \(value.utf8ByteBudget) UTF-8 bytes; truncated: \(value.truncated); more candidates: \(value.hasMoreCandidates)")
        print(
            "Coverage: \(value.coverage.savedTextCandidateCount) saved-text · "
                + "\(value.coverage.visualAppearanceCandidateCount) visual · "
                + "\(value.coverage.multimodalCandidateCount) found by both"
        )
        if let fraction = value.coverage.visualIndexCoverageFraction {
            print("Visual index coverage: \(String(format: "%.1f%%", fraction * 100))")
        }
        if value.omissions.isEmpty {
            print("Omissions: none")
        } else {
            let omissions = value.omissions.map { omission in
                "\(omission.reason.rawValue)=\(omission.count)\(omission.countIsLowerBound ? "+" : "")"
            }
            print("Omissions: \(omissions.joined(separator: ", "))")
        }
        for source in value.sources {
            let timestamp = source.capturedAt.formatted(.iso8601)
            let title = source.windowTitle ?? source.domain ?? "Untitled"
            let ranks = [
                source.savedTextRank.map { "text \($0)" },
                source.visualAppearanceRank.map { "visual \($0)" }
            ].compactMap { $0 }.joined(separator: ", ")
            print("[frame \(source.frameID.rawValue) @ \(timestamp); fused \(source.fusedRank); \(ranks)] \(source.applicationName) — \(title)")
            if let sessionID = source.activitySessionID { print("  Session: \(sessionID.rawValue)") }
            if let domain = source.domain { print("  Domain: \(domain)") }
            if let url = source.url { print("  URL: \(url)") }
            if let visual = source.visual {
                print("  Visual similarity: \(String(format: "%.3f", visual.similarity)) (lower bound \(String(format: "%.3f", visual.minimumPossibleSimilarity)))")
            }
            for node in source.accessibility {
                let detail = [node.label, node.value].compactMap { $0 }.joined(separator: ": ")
                print("  [\(node.role)] \(detail)")
            }
            if !source.ocrText.isEmpty {
                print("  \(source.ocrText)\(source.ocrTextTruncated ? " [OCR truncated]" : "")")
            }
        }
    }

    private static func recent(arguments: [String], client: PassageLocalServiceClient) async throws {
        let options = try Options(arguments: arguments, requiresText: false)
        let hits = try client.search(SearchQuery(
            startDate: options.startDate,
            endDate: options.endDate,
            applicationBundleIdentifiers: Set(options.applications),
            domains: Set(options.domains),
            activitySessionIDs: Set(options.activitySessionIDs),
            limit: options.limit
        ))
        output(hits, asJSON: options.json)
    }

    private static func sessions(
        arguments: [String],
        client: PassageLocalServiceClient
    ) throws {
        let options = try SessionOptions(arguments: arguments)
        let sessions = try client.sessions(ActivitySessionQuery(
            startDate: options.startDate,
            endDate: options.endDate,
            limit: options.limit,
            includeSensitive: false
        ))
        output(sessions, asJSON: options.json)
    }

    private static func frame(arguments: [String], client: PassageLocalServiceClient) async throws {
        guard let identifier = arguments.first, !identifier.hasPrefix("-") else {
            throw PassageError.invalidQuery("frame requires a frame ID")
        }
        guard let value = try client.frame(id: FrameID(rawValue: identifier)) else {
            throw PassageError.frameNotFound(FrameID(rawValue: identifier))
        }
        try printJSON(value)
    }

    private static func stats(arguments: [String], client: PassageLocalServiceClient) async throws {
        let value = try client.statistics()
        if arguments.contains("--json") {
            try printJSON(value)
        } else {
            print("Frames: \(value.frameCount)")
            print("Database: \(ByteCountFormatter.string(fromByteCount: value.databaseBytes, countStyle: .file))")
            print("Media: \(ByteCountFormatter.string(fromByteCount: value.mediaBytes, countStyle: .file))")
            if let oldest = value.oldestCapture { print("Oldest: \(oldest.formatted(.iso8601))") }
            if let newest = value.newestCapture { print("Newest: \(newest.formatted(.iso8601))") }
        }
    }

    private static func output(_ hits: [SearchHit], asJSON: Bool) {
        if asJSON {
            do { try printJSON(hits) }
            catch { FileHandle.standardError.write(Data("passage: \(error.localizedDescription)\n".utf8)) }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for hit in hits {
            let title = hit.context.windowTitle ?? hit.context.domain ?? "Untitled"
            let excerpt = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            print("\(hit.id.rawValue)  \(formatter.string(from: hit.capturedAt))  \(hit.context.applicationName)  \(title)")
            if !excerpt.isEmpty { print("  \(excerpt)") }
        }
    }

    private static func output(_ sessions: [ActivitySessionSummary], asJSON: Bool) {
        if asJSON {
            do { try printJSON(sessions) }
            catch { FileHandle.standardError.write(Data("passage: \(error.localizedDescription)\n".utf8)) }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for session in sessions {
            let end = formatter.string(from: session.endedAt)
            print("\(session.id.rawValue)  \(formatter.string(from: session.startedAt)) – \(end)  \(session.title)")
            var details = ["\(session.frameCount) moments", session.latestApplicationName]
            if let domain = session.latestDomain { details.append(domain) }
            print("  \(details.joined(separator: " · "))")
            let snippet = session.latestSnippet.replacingOccurrences(of: "\n", with: " ")
            if !snippet.isEmpty { print("  \(snippet)") }
            if let url = session.resumeTarget.url {
                print("  Resume: \(url.absoluteString)")
            } else if let bundleIdentifier = session.resumeTarget.bundleIdentifier {
                print("  Resume app: \(session.resumeTarget.applicationName) [\(bundleIdentifier)]")
            }
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printCompactJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printVersion() {
        print("Passage \(PassageServiceProtocol.serviceVersion)")
        print("Service protocol \(PassageServiceProtocol.currentVersion)")
        print("Bundle schema \(PassageContextBundleSchema.currentVersion)")
        print("Visual-search schema \(PassageAgentVisualSearchSchema.currentVersion)")
        print("Memory-capsule schema \(PassageMemoryCapsuleSchema.currentVersion)")
    }

    private static func validateJSONOnlyArguments(_ arguments: [String], command: String) throws {
        for argument in arguments where argument != "--json" {
            throw PassageError.invalidQuery("Unknown \(command) option \(argument)")
        }
    }

    private static let help = """
        Passage — local visual memory

        Usage:
          passage version
          passage capabilities [--json]
          passage health [--json]
          passage sessions [--since DATE] [--until DATE] [--limit N] [--json]
          passage bundle [words] [--since DATE] [--until DATE] [--app BUNDLE] [--domain DOMAIN] [--session ID] [--max-results N] [--max-bytes N] [--json]
          passage remember <description> [--since DATE] [--until DATE] [--app BUNDLE] [--domain DOMAIN] [--session ID] [--max-results N] [--max-bytes N] [--json]
          passage visual <description> [--since DATE] [--until DATE] [--app BUNDLE] [--domain DOMAIN] [--max-results N] [--max-bytes N] [--json]
          passage search <words> [--since DATE] [--until DATE] [--app BUNDLE] [--domain DOMAIN] [--session ID] [--limit N] [--json]
          passage recent [--since DATE] [--until DATE] [--app BUNDLE] [--domain DOMAIN] [--session ID] [--limit N] [--json]
          passage frame <FRAME_ID>
          passage stats [--json]
          passage install-skill <codex|claude|cursor> [--directory PATH]

        Dates accept ISO-8601 timestamps, YYYY-MM-DD, or a relative duration such
        as 3h, 45m, or 2d meaning that long before now. Search supports SQLite FTS5
        phrases and operators such as AND, OR, NOT, prefix*, and quoted phrases.
        sessions lists private-safe activity spans; pass a returned ID to --session
        to scope bundle, search, or recent to that exact span.
        version and help are offline. capabilities and health query the running app.
        remember is the preferred agent path: it performs saved-text and visual
        retrieval together, then returns one compact, source-cited Memory Capsule
        with bounded OCR, native app semantics, and visual-match provenance. bundle
        remains the lower-cost text-only path. visual
        searches local image appearance for objects, people, and scenes, but returns
        only bounded metadata, OCR snippets, similarity, and index coverage—never
        screenshot pixels, embedding vectors, or file paths.

        Captured data is returned by Passage's audited local service; the CLI never
        receives the vault key or opens raw storage. Keep the Passage app running.
        install-skill links Passage's bundled skill into the selected agent's local
        skills directory.
        """

    private static let installSkillHelp = """
        Install Passage memory for an agent

        Usage:
          passage install-skill <codex|claude|cursor> [--directory PATH]

        Without --directory, Passage installs into the selected agent's standard
        local skills directory. PATH selects a skills directory; the installer adds
        a passage-memory link beneath it. Existing unrelated content is never replaced.
        """
}

private enum InstallSkillCommandError: Error, LocalizedError {
    case missingHost
    case invalidHost(String)
    case missingDirectoryValue
    case duplicateDirectory
    case unknownOption(String)
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingHost:
            "install-skill requires a host: codex, claude, or cursor."
        case .invalidHost(let host):
            "Unsupported agent host “\(host)”. Choose codex, claude, or cursor."
        case .missingDirectoryValue:
            "--directory requires a path to a skills directory."
        case .duplicateDirectory:
            "--directory may only be provided once."
        case .unknownOption(let option):
            "Unknown install-skill option \(option). Run passage install-skill --help."
        case .unexpectedArgument(let argument):
            "Unexpected install-skill argument “\(argument)”. Run passage install-skill --help."
        }
    }
}

private enum ManifestCommandMode: Equatable {
    case bundle
    case visual
    case memoryCapsule

    var commandName: String {
        switch self {
        case .bundle: "bundle"
        case .visual: "visual"
        case .memoryCapsule: "remember"
        }
    }

    var maximumResultLimit: Int {
        switch self {
        case .bundle: PassageContextBundleSchema.maximumResultLimit
        case .visual: PassageAgentVisualSearchSchema.maximumResultLimit
        case .memoryCapsule: PassageMemoryCapsuleSchema.maximumResultLimit
        }
    }

    var minimumUTF8ByteBudget: Int {
        switch self {
        case .bundle: PassageContextBundleSchema.minimumUTF8ByteBudget
        case .visual: PassageAgentVisualSearchSchema.minimumUTF8ByteBudget
        case .memoryCapsule: PassageMemoryCapsuleSchema.minimumUTF8ByteBudget
        }
    }

    var defaultUTF8ByteBudget: Int {
        switch self {
        case .bundle: PassageContextBundleSchema.defaultUTF8ByteBudget
        case .visual: PassageAgentVisualSearchSchema.defaultUTF8ByteBudget
        case .memoryCapsule: PassageMemoryCapsuleSchema.defaultUTF8ByteBudget
        }
    }

    var maximumUTF8ByteBudget: Int {
        switch self {
        case .bundle: PassageContextBundleSchema.maximumUTF8ByteBudget
        case .visual: PassageAgentVisualSearchSchema.maximumUTF8ByteBudget
        case .memoryCapsule: PassageMemoryCapsuleSchema.maximumUTF8ByteBudget
        }
    }
}

private struct Options {
    var text = ""
    var startDate: Date?
    var endDate: Date?
    var applications: [String] = []
    var domains: [String] = []
    var activitySessionIDs: [ActivitySessionID] = []
    var limit: Int
    var byteBudget: Int
    var json = false

    init(
        arguments: [String],
        requiresText: Bool,
        defaultLimit: Int = 50,
        manifestMode: ManifestCommandMode? = nil,
        requiredTextCommand: String = "search"
    ) throws {
        limit = defaultLimit
        byteBudget = manifestMode?.defaultUTF8ByteBudget
            ?? PassageContextBundleSchema.defaultUTF8ByteBudget
        var textParts: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--since", "--until", "--app", "--domain", "--session", "--limit", "--max-results", "--max-bytes":
                guard index + 1 < arguments.count else {
                    throw PassageError.invalidQuery("\(argument) requires a value")
                }
                let value = arguments[index + 1]
                switch argument {
                case "--since": startDate = try Self.date(value, endOfDay: false)
                case "--until": endDate = try Self.date(value, endOfDay: true)
                case "--app": applications.append(value)
                case "--domain": domains.append(value)
                case "--session":
                    guard manifestMode != .visual else {
                        throw PassageError.invalidQuery(
                            "--session is not supported by visual search; use time, app, or domain scope"
                        )
                    }
                    guard !value.isEmpty, value.utf8.count <= 128 else {
                        throw PassageError.invalidQuery("--session requires an ID of at most 128 UTF-8 bytes")
                    }
                    activitySessionIDs.append(ActivitySessionID(rawValue: value))
                case "--limit":
                    guard manifestMode == nil else {
                        throw PassageError.invalidQuery(
                            "Use --max-results for \(manifestMode?.commandName ?? "manifest") requests"
                        )
                    }
                    guard let parsed = Int(value), parsed > 0 else {
                        throw PassageError.invalidQuery("--limit must be a positive integer")
                    }
                    limit = min(parsed, 100)
                case "--max-results":
                    guard let manifestMode else {
                        throw PassageError.invalidQuery(
                            "--max-results is only valid for bundle, remember, and visual requests"
                        )
                    }
                    guard let parsed = Int(value),
                          (1...manifestMode.maximumResultLimit).contains(parsed) else {
                        throw PassageError.invalidQuery(
                            "--max-results must be between 1 and \(manifestMode.maximumResultLimit) for \(manifestMode.commandName) requests"
                        )
                    }
                    limit = parsed
                case "--max-bytes":
                    guard let manifestMode else {
                        throw PassageError.invalidQuery(
                            "--max-bytes is only valid for bundle, remember, and visual requests"
                        )
                    }
                    guard let parsed = Int(value),
                          parsed >= manifestMode.minimumUTF8ByteBudget,
                          parsed <= manifestMode.maximumUTF8ByteBudget else {
                        throw PassageError.invalidQuery(
                            "--max-bytes must be between \(manifestMode.minimumUTF8ByteBudget) and \(manifestMode.maximumUTF8ByteBudget) for \(manifestMode.commandName) requests"
                        )
                    }
                    byteBudget = parsed
                default: break
                }
                index += 2
            case "--json":
                json = true
                index += 1
            default:
                if argument.hasPrefix("-") {
                    throw PassageError.invalidQuery("Unknown option \(argument)")
                }
                textParts.append(argument)
                index += 1
            }
        }
        text = textParts.joined(separator: " ")
        if requiresText && text.isEmpty {
            throw PassageError.invalidQuery("\(requiredTextCommand) requires one or more words")
        }
        if manifestMode == .visual,
           text.utf8.count > PassageAgentVisualSearchSchema.maximumDescriptionUTF8Bytes {
            throw PassageError.invalidQuery(
                "visual descriptions must not exceed \(PassageAgentVisualSearchSchema.maximumDescriptionUTF8Bytes) UTF-8 bytes"
            )
        }
        if manifestMode == .memoryCapsule,
           text.utf8.count > PassageMemoryCapsuleSchema.maximumQueryUTF8Bytes {
            throw PassageError.invalidQuery(
                "remember descriptions must not exceed \(PassageMemoryCapsuleSchema.maximumQueryUTF8Bytes) UTF-8 bytes"
            )
        }
        if activitySessionIDs.count > 100 {
            throw PassageError.invalidQuery("At most 100 --session filters may be supplied")
        }
    }

    private static func date(_ value: String, endOfDay: Bool) throws -> Date {
        try parseCLIDate(value, endOfDay: endOfDay)
    }
}

/// Accepts an ISO-8601 timestamp, a YYYY-MM-DD day, or a relative duration
/// such as `3h`, `45m`, or `2d` meaning that long before now. Relative forms
/// let an agent scope "the last few hours" without computing a UTC timestamp.
private func parseCLIDate(_ value: String, endOfDay: Bool) throws -> Date {
    if value.count >= 2,
       let unit = value.last.map(String.init), ["m", "h", "d"].contains(unit),
       let magnitude = Double(value.dropLast()), magnitude > 0, magnitude.isFinite {
        let secondsPerUnit: Double = switch unit {
        case "m": 60
        case "h": 3_600
        default: 86_400
        }
        return Date().addingTimeInterval(-magnitude * secondsPerUnit)
    }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else {
        throw PassageError.invalidQuery("Could not parse date \(value)")
    }
    if endOfDay {
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: date) ?? date
    }
    return date
}

private struct SessionOptions {
    var startDate: Date?
    var endDate: Date?
    var limit = 30
    var json = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--since", "--until", "--limit":
                guard index + 1 < arguments.count else {
                    throw PassageError.invalidQuery("\(argument) requires a value")
                }
                let value = arguments[index + 1]
                switch argument {
                case "--since": startDate = try Self.date(value, endOfDay: false)
                case "--until": endDate = try Self.date(value, endOfDay: true)
                case "--limit":
                    guard let parsed = Int(value), (1...100).contains(parsed) else {
                        throw PassageError.invalidQuery("--limit must be between 1 and 100")
                    }
                    limit = parsed
                default: break
                }
                index += 2
            case "--json":
                json = true
                index += 1
            default:
                throw PassageError.invalidQuery("Unknown sessions option \(argument)")
            }
        }
        if let startDate, let endDate, startDate > endDate {
            throw PassageError.invalidQuery("--since must not be later than --until")
        }
    }

    private static func date(_ value: String, endOfDay: Bool) throws -> Date {
        try parseCLIDate(value, endOfDay: endOfDay)
    }
}
