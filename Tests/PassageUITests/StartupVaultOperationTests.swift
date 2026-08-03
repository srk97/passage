import PassageCore
import PassageStore
@testable import PassageUI
import Foundation
import Testing

@Suite("Startup vault revocation")
struct StartupVaultOperationTests {
    @Test("Lock revokes every registered vault capability")
    func revokeMultipleCapabilities() throws {
        let operation = StartupVaultOperation()
        let capabilities = (0..<4).map { _ in TestStartupVaultRevocable() }
        for capability in capabilities {
            try operation.register(revocable: capability)
        }

        operation.revoke()

        #expect(capabilities.allSatisfy { $0.revokeCount == 1 })
        #expect(throws: CancellationError.self) {
            try operation.checkpoint()
        }
    }

    @Test("Registering the same capability twice is idempotent")
    func duplicateRegistrationIsIdempotent() throws {
        let operation = StartupVaultOperation()
        let capability = TestStartupVaultRevocable()

        try operation.register(revocable: capability)
        try operation.register(revocable: capability)
        operation.revoke()
        operation.revoke()

        #expect(capability.revokeCount == 1)
    }

    @Test("Lock revokes stores that registered before the boundary")
    func revokeAfterRegistration() async throws {
        let fixture = try StartupVaultFixture()
        defer { fixture.cleanUp() }
        let frameStore = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.key)
        let accessStore = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.key)
        let operation = StartupVaultOperation()
        try operation.register(frameStore: frameStore)
        try operation.register(accessEventStore: accessStore)

        operation.revoke()

        await #expect(throws: Error.self) {
            _ = try await frameStore.statistics()
        }
        await #expect(throws: Error.self) {
            _ = try await accessStore.accessEvents(limit: 1)
        }
        #expect(throws: CancellationError.self) {
            try operation.checkpoint()
        }
    }

    @Test("A generic capability finishing after lock is revoked immediately")
    func genericRevokeBeforeRegistration() {
        let operation = StartupVaultOperation()
        let capability = TestStartupVaultRevocable()
        operation.revoke()

        #expect(throws: CancellationError.self) {
            try operation.register(revocable: capability)
        }
        #expect(capability.revokeCount == 1)
    }

    @Test("A constructor finishing after lock is revoked during registration")
    func revokeBeforeRegistration() async throws {
        let fixture = try StartupVaultFixture()
        defer { fixture.cleanUp() }
        let frameStore = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.key)
        let accessStore = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.key)
        let operation = StartupVaultOperation()

        operation.revoke()

        #expect(throws: CancellationError.self) {
            try operation.register(frameStore: frameStore)
        }
        #expect(throws: CancellationError.self) {
            try operation.register(accessEventStore: accessStore)
        }
        await #expect(throws: Error.self) {
            _ = try await frameStore.statistics()
        }
        await #expect(throws: Error.self) {
            _ = try await accessStore.accessEvents(limit: 1)
        }
    }

    @Test("Publication disarms candidate ownership exactly once")
    func disarmTransfersOwnership() async throws {
        let fixture = try StartupVaultFixture()
        defer { fixture.cleanUp() }
        let frameStore = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.key)
        let accessStore = try SQLiteAccessEventStore(paths: fixture.paths, vaultKey: fixture.key)
        let operation = StartupVaultOperation()
        try operation.register(frameStore: frameStore)
        try operation.register(accessEventStore: accessStore)

        #expect(operation.disarmForPublication())
        #expect(!operation.disarmForPublication())
        operation.revoke()

        _ = try await frameStore.statistics()
        _ = try await accessStore.accessEvents(limit: 1)
        frameStore.revoke()
        accessStore.revoke()
    }

    @Test("Publication disarms all generic capabilities without revoking them")
    func disarmGenericCapabilities() throws {
        let operation = StartupVaultOperation()
        let published = (0..<3).map { _ in TestStartupVaultRevocable() }
        for capability in published {
            try operation.register(revocable: capability)
        }

        #expect(operation.disarmForPublication())
        operation.revoke()
        #expect(published.allSatisfy { $0.revokeCount == 0 })

        let lateCapability = TestStartupVaultRevocable()
        #expect(throws: CancellationError.self) {
            try operation.register(revocable: lateCapability)
        }
        #expect(lateCapability.revokeCount == 1)
    }

    @Test("Concurrent registration and lock revoke every capability exactly once")
    func concurrentRegistrationAndRevoke() async {
        let operation = StartupVaultOperation()
        let capabilities = (0..<128).map { _ in TestStartupVaultRevocable() }

        await withTaskGroup(of: Void.self) { group in
            for capability in capabilities {
                group.addTask {
                    _ = try? operation.register(revocable: capability)
                }
            }
            group.addTask {
                operation.revoke()
            }
        }

        #expect(capabilities.allSatisfy { $0.revokeCount == 1 })
    }

    @Test("Deferred website maintenance honors owner cancellation")
    func websiteMaintenanceCancellation() async throws {
        let fixture = try StartupVaultFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.key)
        let maintenance = Task {
            try await PassageStartupMaintenance.repairWebsiteFacets(
                repository: store,
                initialDelay: .seconds(30)
            )
        }

        maintenance.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await maintenance.value
        }
    }

    @Test("Deferred website maintenance crosses an unrepairable page")
    func websiteMaintenanceDrainsAllPages() async throws {
        let fixture = try StartupVaultFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.key)
        var repairable = Self.frame(id: "repairable", time: 100)
        repairable.context.url = URL(string: "https://older.example/page")
        try await store.insertBatch([
            repairable,
            Self.frame(id: "unrepairable-one", time: 200),
            Self.frame(id: "unrepairable-two", time: 300),
        ])

        let repairedCount = try await PassageStartupMaintenance.repairWebsiteFacets(
            repository: store,
            batchLimit: 2,
            initialDelay: .zero
        )

        #expect(repairedCount == 1)
        #expect(try await store.frame(id: repairable.id)?.context.domain == "older.example")
    }

    private static func frame(id: String, time: TimeInterval) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: Date(timeIntervalSince1970: time),
            context: ScreenContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                windowTitle: "Browser"
            ),
            ocrText: "browser content",
            imageRelativePath: "Media/\(id).enc",
            pixelWidth: 1_280,
            pixelHeight: 720,
            visualFingerprint: UInt64(time),
            changeScore: 1
        )
    }
}

private final class TestStartupVaultRevocable: StartupVaultRevocable, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRevokeCount = 0

    var revokeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRevokeCount
    }

    func revoke() {
        lock.lock()
        storedRevokeCount += 1
        lock.unlock()
    }
}

private struct StartupVaultFixture {
    let root: URL
    let paths: PassagePaths
    let key: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-startup-vault-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = PassagePaths(root: root)
        key = try VaultKey.testing(bytes: Data(repeating: 0x5a, count: VaultKey.byteCount))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
