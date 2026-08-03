import PassageCore
@testable import PassageStore
import Foundation
@preconcurrency import SQLCipher
import Testing

@Suite("SQLite frame-store cancellation")
struct SQLiteFrameStoreCancellationTests {
    @Test("A write canceled while queued cannot begin a transaction")
    func canceledQueuedInsertDoesNotPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-canceled-insert-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x71, count: VaultKey.byteCount))
        let store = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
        let gate = InsertCancellationGate()

        let write = Task {
            await gate.wait()
            try await store.insert(Self.frame)
        }
        await gate.waitUntilParked()
        write.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await write.value
        }
        let statistics = try await store.statistics()
        #expect(statistics.frameCount == 0)
    }

    @Test("Session revocation closes the encrypted capability immediately")
    func revokedStoreRejectsLaterReads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-revoked-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x72, count: VaultKey.byteCount))
        let store = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
        try await store.insert(Self.frame)

        store.revoke()

        await #expect(throws: Error.self) {
            _ = try await store.statistics()
        }
        await #expect(throws: Error.self) {
            _ = try await store.frame(id: Self.frame.id)
        }
    }

    @Test("Revocation interrupts an active lease and closes only after it unwinds")
    func revocationDrainsActiveConnectionLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-revoked-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x73, count: VaultKey.byteCount))
        _ = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
        let connection = try SQLCipherConnection(
            paths: paths,
            vaultKey: vaultKey,
            readOnly: true
        )
        let gate = SQLiteProgressGate()

        let activeRead = Task.detached { () throws -> Int32 in
            guard let lease = connection.lease() else {
                throw PassageError.database("Connection unexpectedly closed")
            }
            defer { lease.release() }
            let database = lease.pointer
            let context = Unmanaged.passUnretained(gate).toOpaque()
            sqlite3_progress_handler(database, 1, { context in
                guard let context else { return 1 }
                return Unmanaged<SQLiteProgressGate>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .reportStartedOnce()
            }, context)
            defer { sqlite3_progress_handler(database, 0, nil, nil) }

            var statement: OpaquePointer?
            let sql = """
                WITH RECURSIVE counter(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM counter
                    WHERE value < 100000000
                ) SELECT sum(value) FROM counter
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw PassageError.database(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            await gate.holdLeaseAfterStatement()
            return status
        }

        await gate.waitUntilStarted()
        #expect(connection.debugActiveLeaseCount == 1)
        connection.revoke()
        await gate.waitUntilStatementFinished()
        #expect(connection.lease() == nil)
        #expect(connection.debugHasOpenHandle)
        #expect(connection.debugActiveLeaseCount == 1)
        gate.releaseLease()

        #expect(try await activeRead.value == SQLITE_INTERRUPT)
        #expect(!connection.debugHasOpenHandle)
        #expect(connection.debugActiveLeaseCount == 0)
    }

    private static let frame = FrameDocument(
        id: FrameID(rawValue: "must-not-persist"),
        capturedAt: Date(timeIntervalSince1970: 500),
        context: ScreenContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Canceled evidence"
        ),
        ocrText: "Canceled evidence",
        ocrRegions: [
            OCRRegion(text: "Canceled evidence", confidence: 0.99, x: 0, y: 0, width: 1, height: 1),
        ],
        imageRelativePath: "Media/must-not-persist.jpg",
        thumbnailRelativePath: nil,
        pixelWidth: 1,
        pixelHeight: 1,
        visualFingerprint: 1,
        changeScore: 1
    )
}

private final class SQLiteProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false
    private var hasFinished = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var finishedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func reportStartedOnce() -> Int32 {
        lock.lock()
        guard !hasStarted else {
            lock.unlock()
            return 0
        }
        hasStarted = true
        let waiter = startedWaiter
        startedWaiter = nil
        lock.unlock()
        waiter?.resume()
        return 0
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasStarted {
                lock.unlock()
                continuation.resume()
            } else {
                startedWaiter = continuation
                lock.unlock()
            }
        }
    }

    func holdLeaseAfterStatement() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            hasFinished = true
            let waiter = finishedWaiter
            finishedWaiter = nil
            releaseWaiter = continuation
            lock.unlock()
            waiter?.resume()
        }
    }

    func waitUntilStatementFinished() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasFinished {
                lock.unlock()
                continuation.resume()
            } else {
                finishedWaiter = continuation
                lock.unlock()
            }
        }
    }

    func releaseLease() {
        lock.lock()
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

private actor InsertCancellationGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            parked = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilParked() async {
        guard parked == nil else { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}
