import Foundation

public struct PassagePaths: Sendable {
    public let root: URL
    public let database: URL
    public let media: URL
    public let thumbnails: URL
    public let privacyPreferences: URL
    public let sessionIntelligenceCache: URL
    public let sessionQuestionCache: URL

    public init(root: URL) {
        self.root = root
        database = root.appendingPathComponent("chronicle.sqlite3")
        media = root.appendingPathComponent("Media", isDirectory: true)
        thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
        privacyPreferences = root.appendingPathComponent("privacy-preferences.json")
        sessionIntelligenceCache = root.appendingPathComponent(
            "SessionIntelligenceCache",
            isDirectory: true
        )
        sessionQuestionCache = root.appendingPathComponent(
            "SessionQuestionCache",
            isDirectory: true
        )
    }

    public static func live(fileManager: FileManager = .default) throws -> PassagePaths {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PassagePaths(root: applicationSupport.appendingPathComponent("Chronicle", isDirectory: true))
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sessionIntelligenceCache,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sessionQuestionCache,
            withIntermediateDirectories: true
        )
        for directory in [root, media, thumbnails, sessionIntelligenceCache, sessionQuestionCache] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
