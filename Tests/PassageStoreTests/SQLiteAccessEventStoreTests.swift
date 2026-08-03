import PassageCore
import PassageStore
import Foundation
import Testing

@Suite("SQLite access event store")
struct SQLiteAccessEventStoreTests {
    @Test("Events are listed newest-first with a deterministic tie break")
    func newestFirstAndBounded() async throws {
        let fixture = try AccessStoreFixture()
        let store = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        try await store.recordAccessEvent(Self.event(id: "old", time: 100))
        try await store.recordAccessEvent(Self.event(id: "same-time-first", time: 200))
        try await store.recordAccessEvent(Self.event(id: "same-time-second", time: 200))

        let newest = try await store.accessEvents(limit: 2)
        #expect(newest.map(\.id.rawValue) == ["same-time-second", "same-time-first"])
        #expect(try await store.accessEvents(limit: 0).isEmpty)
    }

    @Test("Every access field survives a durable, parameter-bound round trip")
    func roundTrip() async throws {
        let fixture = try AccessStoreFixture()
        let store = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let original = AccessEvent(
            id: AccessEventID(rawValue: "event-with-fields"),
            occurredAt: Date(timeIntervalSince1970: 1_234.5),
            client: "Codex'; DROP TABLE access_events; --",
            command: "query search",
            capability: "frames.read",
            querySummary: "proposal \"north star\"\nsecond line",
            filterSummary: "Safari · today · café.example",
            returnedFrameIDs: [FrameID(rawValue: "frame-a"), FrameID(rawValue: "frame-b")],
            returnedFrameCount: 2,
            outcome: .success
        )
        try await store.recordAccessEvent(original)

        let reopenedStore = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let events = try await reopenedStore.accessEvents(limit: 10)
        #expect(events == [original])
    }

    @Test("Clearing returns the deletion count and leaves an empty audit trail")
    func clear() async throws {
        let fixture = try AccessStoreFixture()
        let store = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        try await store.recordAccessEvent(Self.event(id: "one", time: 100))
        try await store.recordAccessEvent(Self.event(id: "two", time: 200))

        #expect(try await store.clearAccessEvents() == 2)
        #expect(try await store.accessEvents(limit: 10).isEmpty)
        #expect(try await store.clearAccessEvents() == 0)
    }

    @Test("Frame and access stores share one encrypted index and one explicit vault key")
    func sharedEncryptedDatabase() async throws {
        let fixture = try AccessStoreFixture()
        let frameStore = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let accessStore = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        #expect(frameStore.encryptionStatus.cipherStatus == "1")
        #expect(accessStore.encryptionStatus.cipherStatus == "1")

        let event = Self.event(id: "shared-key", time: 300)
        try await accessStore.recordAccessEvent(event)
        #expect(try await accessStore.accessEvents(limit: 1) == [event])

        let wrongKey = try VaultKey.testing(bytes: Data(repeating: 0x17, count: VaultKey.byteCount))
        #expect(throws: (any Error).self) {
            _ = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: wrongKey, readOnly: true)
        }
    }

    @Test("Revocation immediately rejects later access-history reads and writes")
    func revokedStoreFailsClosed() async throws {
        let fixture = try AccessStoreFixture()
        let store = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        try await store.recordAccessEvent(Self.event(id: "before-lock", time: 100))

        store.revoke()

        await #expect(throws: Error.self) {
            _ = try await store.accessEvents(limit: 10)
        }
        await #expect(throws: Error.self) {
            try await store.recordAccessEvent(Self.event(id: "after-lock", time: 200))
        }
        await #expect(throws: Error.self) {
            _ = try await store.clearAccessEvents()
        }
    }

    private static func event(id: String, time: TimeInterval) -> AccessEvent {
        AccessEvent(
            id: AccessEventID(rawValue: id),
            occurredAt: Date(timeIntervalSince1970: time),
            client: "test-client",
            command: "query recent",
            capability: "frames.read",
            querySummary: nil,
            filterSummary: "limit=10",
            returnedFrameIDs: [FrameID(rawValue: "frame-\(id)")],
            outcome: .success
        )
    }
}

private final class AccessStoreFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-access-tests-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x72, count: VaultKey.byteCount))
        try paths.createDirectories()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
