import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("Recall FTS rowid migration")
struct RecallRowIDMigrationTests {
    @Test("Legacy read-only recall falls back safely and writable open aligns FTS rowids")
    func legacyFallbackAndMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-recall-rowid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x6f, count: VaultKey.byteCount))

        var store: SQLiteFrameStore? = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
        try await store?.insertBatch([
            Self.frame(id: "target", time: 200, text: "Phoenix launch plan"),
            Self.frame(id: "other", time: 100, text: "Atlas launch plan"),
        ])
        store = nil

        // Model a v5 vault whose independent virtual-table rowids no longer
        // happen to match the owning frame rowids.
        var legacyConnection: SQLCipherConnection? = try SQLCipherConnection(
            paths: paths,
            vaultKey: vaultKey,
            readOnly: false
        )
        try Self.execute(
            "UPDATE frame_search SET rowid = rowid + 1000",
            on: try #require(legacyConnection?.pointer)
        )
        try Self.execute(
            "UPDATE store_metadata SET value = '5' WHERE key = 'schema_version'",
            on: try #require(legacyConnection?.pointer)
        )
        legacyConnection = nil

        // Read-only tools cannot migrate. They must retain the legacy text-ID
        // join until Passage next opens the vault for writing.
        var readOnlyStore: SQLiteFrameStore? = try SQLiteFrameStore(
            paths: paths,
            vaultKey: vaultKey,
            readOnly: true
        )
        let legacyPage = try await readOnlyStore?.recall(Self.scope, after: nil, limit: 20)
        #expect(legacyPage?.hits.map(\.id.rawValue) == ["target"])
        readOnlyStore = nil

        let migratedStore = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
        let migratedPage = try await migratedStore.recall(Self.scope, after: nil, limit: 20)
        #expect(migratedPage.hits.map(\.id.rawValue) == ["target"])
        #expect(migratedPage.hits.first?.snippet.contains("Phoenix") == true)
    }

    private static let scope = RecallScope(
        text: "Phoenix",
        applicationBundleIdentifiers: ["com.example.Design"],
        domains: ["design.example"]
    )

    private static func frame(id: String, time: Double, text: String) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: "Design",
                bundleIdentifier: "com.example.Design",
                windowTitle: "Design · \(id)",
                url: URL(string: "https://design.example/\(id)"),
                domain: "design.example"
            ),
            ocrText: text,
            ocrRegions: [
                OCRRegion(text: text, confidence: 0.99, x: 0, y: 0, width: 1, height: 1),
            ],
            imageRelativePath: "Media/\(id).jpg",
            thumbnailRelativePath: "Thumbnails/\(id).jpg",
            pixelWidth: 1_280,
            pixelHeight: 720,
            visualFingerprint: id.utf8.reduce(UInt64.zero) { $0 &+ UInt64($1) },
            changeScore: 0.5
        )
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw PassageError.database(message)
        }
    }
}
