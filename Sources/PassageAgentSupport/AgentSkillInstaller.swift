import Foundation

public enum AgentSkillHost: String, CaseIterable, Sendable {
    case codex
    case claude
    case cursor

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        }
    }
}

public enum AgentSkillPathResolver {
    public static func defaultSkillsDirectory(
        for host: AgentSkillHost,
        homeDirectory: URL
    ) -> URL {
        let productDirectory = switch host {
        case .codex: ".codex"
        case .claude: ".claude"
        case .cursor: ".cursor"
        }
        return homeDirectory
            .appendingPathComponent(productDirectory, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .standardizedFileURL
    }

    public static func skillsDirectory(
        for host: AgentSkillHost,
        customPath: String?,
        homeDirectory: URL,
        currentDirectory: URL
    ) throws -> URL {
        guard let customPath else {
            return defaultSkillsDirectory(for: host, homeDirectory: homeDirectory)
        }
        return try resolve(
            customPath,
            homeDirectory: homeDirectory,
            currentDirectory: currentDirectory
        )
    }

    public static func resolve(
        _ path: String,
        homeDirectory: URL,
        currentDirectory: URL
    ) throws -> URL {
        guard !path.isEmpty else {
            throw AgentSkillInstallationError.invalidPath("The directory path cannot be empty.")
        }

        if path == "~" {
            return homeDirectory.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                .standardizedFileURL
        }
        if path.hasPrefix("~") {
            throw AgentSkillInstallationError.invalidPath(
                "Home directories for other users are not supported: \(path)"
            )
        }

        return URL(fileURLWithPath: path, relativeTo: currentDirectory)
            .standardizedFileURL
    }
}

public enum AgentSkillLocator {
    public static func locate(
        executableURL: URL,
        currentDirectory: URL,
        overrideURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let overrideURL {
            let source = overrideURL.standardizedFileURL.resolvingSymlinksInPath()
            try validate(source, fileManager: fileManager)
            return source
        }

        let resolvedExecutable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let executableDirectory = resolvedExecutable.deletingLastPathComponent()
        let candidates = unique([
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("AgentSkill", isDirectory: true),
            executableDirectory.appendingPathComponent("AgentSkill", isDirectory: true),
            currentDirectory.appendingPathComponent("AgentSkill", isDirectory: true),
        ])

        for candidate in candidates {
            let source = candidate.standardizedFileURL.resolvingSymlinksInPath()
            if isDirectory(source, fileManager: fileManager) {
                try validate(source, fileManager: fileManager)
                return source
            }
        }

        throw AgentSkillInstallationError.sourceNotFound(candidates)
    }

    public static func validate(
        _ source: URL,
        fileManager: FileManager = .default
    ) throws {
        guard isDirectory(source, fileManager: fileManager) else {
            throw AgentSkillInstallationError.invalidSource(
                source,
                "The skill source is not a directory."
            )
        }

        let manifest = source.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: manifest.path) else {
            throw AgentSkillInstallationError.invalidSource(
                source,
                "SKILL.md is missing."
            )
        }

        let contents: String
        do {
            contents = try String(contentsOf: manifest, encoding: .utf8)
        } catch {
            throw AgentSkillInstallationError.invalidSource(
                source,
                "SKILL.md could not be read: \(error.localizedDescription)"
            )
        }

        guard manifestName(in: contents) == AgentSkillInstaller.skillDirectoryName else {
            throw AgentSkillInstallationError.invalidSource(
                source,
                "SKILL.md must declare name: \(AgentSkillInstaller.skillDirectoryName)."
            )
        }
    }

    private static func manifestName(in contents: String) -> String? {
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil }
            guard trimmed.hasPrefix("name:") else { continue }
            return String(trimmed.dropFirst("name:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}

public enum AgentSkillInstallStatus: String, Sendable {
    case installed
    case alreadyInstalled
}

public struct AgentSkillInstallResult: Sendable {
    public let status: AgentSkillInstallStatus
    public let host: AgentSkillHost
    public let source: URL
    public let destination: URL

    public init(
        status: AgentSkillInstallStatus,
        host: AgentSkillHost,
        source: URL,
        destination: URL
    ) {
        self.status = status
        self.host = host
        self.source = source
        self.destination = destination
    }
}

public enum AgentSkillInstaller {
    public static let skillDirectoryName = "passage-memory"

    public static func install(
        host: AgentSkillHost,
        source sourceURL: URL,
        skillsDirectory skillsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> AgentSkillInstallResult {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let skillsDirectory = skillsDirectoryURL.standardizedFileURL
        let destination = skillsDirectory
            .appendingPathComponent(skillDirectoryName, isDirectory: true)
            .standardizedFileURL

        try AgentSkillLocator.validate(source, fileManager: fileManager)

        if let existingLink = symbolicLinkDestination(
            at: destination,
            fileManager: fileManager
        ) {
            let resolvedExisting = resolveLink(existingLink, at: destination)
                .resolvingSymlinksInPath()
            if resolvedExisting.path == source.path {
                return AgentSkillInstallResult(
                    status: .alreadyInstalled,
                    host: host,
                    source: source,
                    destination: destination
                )
            }
            throw AgentSkillInstallationError.destinationOccupied(
                destination,
                "It is a symbolic link to \(existingLink)."
            )
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            let kind = isDirectory.boolValue ? "directory" : "file"
            throw AgentSkillInstallationError.destinationOccupied(
                destination,
                "It is an existing \(kind) not installed by Passage."
            )
        }

        do {
            try fileManager.createDirectory(
                at: skillsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AgentSkillInstallationError.cannotCreateDirectory(
                skillsDirectory,
                error.localizedDescription
            )
        }

        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: skillsDirectory.path,
            isDirectory: &rootIsDirectory
        ), rootIsDirectory.boolValue else {
            throw AgentSkillInstallationError.cannotCreateDirectory(
                skillsDirectory,
                "A non-directory item occupies this path."
            )
        }

        do {
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
        } catch {
            if itemExistsIncludingSymbolicLink(at: destination, fileManager: fileManager) {
                throw AgentSkillInstallationError.destinationOccupied(
                    destination,
                    "Another item appeared while Passage was installing the skill."
                )
            }
            throw AgentSkillInstallationError.cannotCreateLink(
                destination,
                source,
                error.localizedDescription
            )
        }

        return AgentSkillInstallResult(
            status: .installed,
            host: host,
            source: source,
            destination: destination
        )
    }

    private static func symbolicLinkDestination(
        at url: URL,
        fileManager: FileManager
    ) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    private static func resolveLink(_ link: String, at destination: URL) -> URL {
        if link.hasPrefix("/") {
            return URL(fileURLWithPath: link).standardizedFileURL
        }
        return URL(
            fileURLWithPath: link,
            relativeTo: destination.deletingLastPathComponent()
        ).standardizedFileURL
    }

    private static func itemExistsIncludingSymbolicLink(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        if symbolicLinkDestination(at: url, fileManager: fileManager) != nil { return true }
        return fileManager.fileExists(atPath: url.path)
    }
}

public enum AgentSkillInstallationError: Error, LocalizedError {
    case invalidPath(String)
    case sourceNotFound([URL])
    case invalidSource(URL, String)
    case destinationOccupied(URL, String)
    case cannotCreateDirectory(URL, String)
    case cannotCreateLink(URL, URL, String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let reason):
            "Invalid skill directory: \(reason)"
        case .sourceNotFound(let paths):
            "Passage's bundled agent skill could not be found. Searched: "
                + paths.map(\.path).joined(separator: ", ")
                + ". Reinstall Passage and try again."
        case .invalidSource(let source, let reason):
            "Passage's agent skill at \(source.path) is invalid. \(reason)"
        case .destinationOccupied(let destination, let reason):
            "Refusing to replace \(destination.path). \(reason) Move it aside or choose another --directory."
        case .cannotCreateDirectory(let directory, let reason):
            "Could not create the skill directory at \(directory.path). \(reason)"
        case .cannotCreateLink(let destination, let source, let reason):
            "Could not link \(destination.path) to Passage's bundled skill at \(source.path). \(reason)"
        }
    }
}
