import Darwin
import Foundation
@preconcurrency import SQLCipher

public struct SQLCipherRuntimeStatus: Equatable, Sendable {
    public let cipherVersion: String
    public let cipherStatus: String

    public init(cipherVersion: String, cipherStatus: String) {
        self.cipherVersion = cipherVersion
        self.cipherStatus = cipherStatus
    }
}

public enum EncryptedStoreError: Error, LocalizedError, Sendable {
    case plaintextDatabaseRequiresWritableMigration
    case cipherRuntimeUnavailable(String)
    case cipherInactive(String)
    case databaseVerificationFailed(String)
    case plaintextMigrationFailed(String)
    case fileProtectionFailed(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .plaintextDatabaseRequiresWritableMigration:
            "This Passage index is from an older plaintext build. Open Passage once to migrate it before using read-only tools."
        case .cipherRuntimeUnavailable(let message):
            "Passage refused to open its index because SQLCipher could not be verified: \(message)"
        case .cipherInactive(let status):
            "Passage refused to open its index because SQLCipher reported an inactive codec (\(status))."
        case .databaseVerificationFailed(let message):
            "Passage could not verify the encrypted index. The vault key may be wrong or the index may be damaged: \(message)"
        case .plaintextMigrationFailed(let message):
            "Passage preserved the original index because encrypted migration failed: \(message)"
        case .fileProtectionFailed(let path, let message):
            "Passage could not restrict storage permissions for \(path): \(message)"
        }
    }
}

/// The sole database-opening path used by PassageStore.
///
/// A connection is keyed immediately after `sqlite3_open_v2`, before any pragma,
/// schema read, timeout configuration, or prepared statement. Both the SQLCipher
/// runtime and the encrypted schema are then verified before the pointer is
/// exposed to a store.
final class SQLCipherConnection: @unchecked Sendable {
    /// A scoped capability for using the SQLite handle. Revocation prevents
    /// new leases immediately and interrupts the database, while an existing
    /// lease keeps the raw pointer alive until its operation has unwound.
    final class Lease: @unchecked Sendable {
        let pointer: OpaquePointer
        private let stateLock = NSLock()
        private var connection: SQLCipherConnection?

        fileprivate init(connection: SQLCipherConnection, pointer: OpaquePointer) {
            self.connection = connection
            self.pointer = pointer
        }

        func release() {
            stateLock.lock()
            let connection = connection
            self.connection = nil
            stateLock.unlock()
            connection?.releaseLease()
        }

        deinit {
            release()
        }
    }

    private let stateLock = NSLock()
    private var openedPointer: OpaquePointer?
    private var revoked = false
    private var activeLeaseCount = 0
    /// Opening/migration code and test fixtures use this only while the
    /// connection is known active. Runtime store operations use scoped leases.
    var pointer: OpaquePointer {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !revoked, let openedPointer else {
            preconditionFailure("A revoked SQLCipher connection has no raw pointer")
        }
        return openedPointer
    }
    func lease() -> Lease? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !revoked, let openedPointer else { return nil }
        activeLeaseCount += 1
        return Lease(connection: self, pointer: openedPointer)
    }
    let runtimeStatus: SQLCipherRuntimeStatus
    private let paths: PassagePaths

    init(paths: PassagePaths, vaultKey: VaultKey, readOnly: Bool) throws {
        self.paths = paths
        if readOnly {
            if try Self.databaseFormat(at: paths.database) == .plaintextSQLite {
                throw EncryptedStoreError.plaintextDatabaseRequiresWritableMigration
            }
        } else {
            try paths.createDirectories()
            try Self.migratePlaintextIfNecessary(paths: paths, vaultKey: vaultKey)
        }

        var opened: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(paths.database.path, &opened, flags, nil)
        guard openResult == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned code \(openResult)."
            sqlite3_close(opened)
            throw EncryptedStoreError.databaseVerificationFailed(
                "sqlite3_open_v2 failed with code \(openResult): \(message)"
            )
        }

        do {
            try Self.applyKey(vaultKey, to: opened)
            let status = try Self.verifyCipherAndSchema(on: opened)
            // A crash after the atomic encrypted swap but before recovery-copy
            // cleanup is safe, but can leave plaintext behind. Once this handle
            // independently proves the canonical database is encrypted, finish
            // that cleanup before exposing the connection.
            try Self.cleanupStalePlaintextMigrationArtifacts(paths: paths)
            openedPointer = opened
            runtimeStatus = status

            try Self.restrictDatabaseFiles(paths: paths)
            sqlite3_extended_result_codes(opened, 1)
            sqlite3_busy_timeout(opened, 5_000)

            if !readOnly {
                // SQLCipher's full-page encryption and HMAC remain enabled. Its
                // optional locked-heap scrubbing is deliberately left at the
                // upstream default because it materially doubles interactive
                // FTS latency; Passage instead drops all handles and cached
                // evidence when the macOS session locks.
                try Self.execute("PRAGMA cipher_memory_security = OFF", on: opened)
                try Self.execute("PRAGMA secure_delete = ON", on: opened)
                try Self.execute("PRAGMA journal_mode = WAL", on: opened)
                try Self.execute("PRAGMA synchronous = NORMAL", on: opened)
                try Self.execute("PRAGMA temp_store = MEMORY", on: opened)
                try Self.execute("PRAGMA cache_size = -65536", on: opened)
                try Self.execute("PRAGMA mmap_size = 268435456", on: opened)
                try Self.restrictDatabaseFiles(paths: paths)
            }
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    deinit {
        revoke()
    }

    /// Immediately prevents this vault session from starting more SQL work and
    /// interrupts the current statement, if any. The underlying handle closes
    /// as soon as the last operation lease drains, avoiding a raw-pointer race
    /// with work that was already active when the session locked.
    func revoke() {
        stateLock.lock()
        guard !revoked else {
            stateLock.unlock()
            return
        }
        revoked = true
        let pointer = openedPointer
        let hasActiveOperation = activeLeaseCount > 0
        // Count the interrupt itself as a short lease. Otherwise the active
        // operation could unwind and close the handle in the gap between this
        // lock being released and sqlite3_interrupt reading the pointer.
        if hasActiveOperation {
            activeLeaseCount += 1
        }
        let closesImmediately = !hasActiveOperation
        if closesImmediately {
            openedPointer = nil
        }
        stateLock.unlock()
        guard let pointer else { return }
        if closesImmediately {
            sqlite3_close_v2(pointer)
        } else {
            sqlite3_interrupt(pointer)
            releaseLease()
        }
    }

    private func releaseLease() {
        stateLock.lock()
        precondition(activeLeaseCount > 0, "Unbalanced SQLCipher connection lease")
        activeLeaseCount -= 1
        let pointerToClose: OpaquePointer?
        if revoked, activeLeaseCount == 0 {
            pointerToClose = openedPointer
            openedPointer = nil
        } else {
            pointerToClose = nil
        }
        stateLock.unlock()
        if let pointerToClose {
            sqlite3_close_v2(pointerToClose)
        }
    }

#if DEBUG
    var debugHasOpenHandle: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return openedPointer != nil
    }

    var debugActiveLeaseCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeLeaseCount
    }
#endif

    func hardenFilePermissions() throws {
        try Self.restrictDatabaseFiles(paths: paths)
    }

    private static func applyKey(_ vaultKey: VaultKey, to database: OpaquePointer) throws {
        let result = withSQLCipherRawKey(vaultKey) { keyBytes in
            sqlite3_key(database, keyBytes.baseAddress, Int32(keyBytes.count))
        }
        guard result == SQLITE_OK else {
            throw EncryptedStoreError.databaseVerificationFailed(
                "SQLCipher rejected the vault key with code \(result)."
            )
        }
    }

    /// SQLCipher's raw-key form is the ASCII sequence `x'<64 hex digits>'`.
    /// Supplying arbitrary binary to sqlite3_key invokes passphrase handling;
    /// using the documented raw form both preserves our exact HKDF output and
    /// avoids redundant PBKDF work on every connection open.
    private static func withSQLCipherRawKey<Result>(
        _ vaultKey: VaultKey,
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try vaultKey.withDerivedKeyBytes(for: .databaseIndex) { derivedBytes in
            let hexDigits = Array("0123456789abcdef".utf8)
            var encoded = [UInt8]()
            encoded.reserveCapacity(2 + (derivedBytes.count * 2) + 1)
            encoded.append(contentsOf: "x'".utf8)
            for byte in derivedBytes {
                encoded.append(hexDigits[Int(byte >> 4)])
                encoded.append(hexDigits[Int(byte & 0x0f)])
            }
            encoded.append(contentsOf: "'".utf8)
            defer {
                _ = encoded.withUnsafeMutableBytes { bytes in
                    bytes.initializeMemory(as: UInt8.self, repeating: 0)
                }
            }
            return try encoded.withUnsafeBytes(body)
        }
    }

    private static func verifyCipherAndSchema(on database: OpaquePointer) throws -> SQLCipherRuntimeStatus {
        let version: String
        do {
            version = try scalarText("PRAGMA cipher_version", on: database)
        } catch {
            throw EncryptedStoreError.cipherRuntimeUnavailable(error.localizedDescription)
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EncryptedStoreError.cipherRuntimeUnavailable("cipher_version was empty.")
        }

        let cipherStatus: String
        do {
            cipherStatus = try scalarText("PRAGMA cipher_status", on: database)
        } catch {
            throw EncryptedStoreError.cipherRuntimeUnavailable(error.localizedDescription)
        }
        let normalizedStatus = cipherStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["1", "on", "true", "active"].contains(normalizedStatus) else {
            throw EncryptedStoreError.cipherInactive(cipherStatus)
        }

        // This is deliberately not replaced by a pragma. Reading sqlite_schema
        // forces page 1 through the codec and therefore rejects wrong keys and
        // plaintext/corrupt files before migrations or application queries run.
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT count(*) FROM sqlite_schema",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw EncryptedStoreError.databaseVerificationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw EncryptedStoreError.databaseVerificationFailed(String(cString: sqlite3_errmsg(database)))
        }
        return SQLCipherRuntimeStatus(cipherVersion: version, cipherStatus: cipherStatus)
    }

    private static func scalarText(_ sql: String, on database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw EncryptedStoreError.databaseVerificationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else {
            throw EncryptedStoreError.databaseVerificationFailed(
                "\(sql) returned no value (\(String(cString: sqlite3_errmsg(database))))."
            )
        }
        return String(cString: bytes)
    }

    private static func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw EncryptedStoreError.databaseVerificationFailed("\(sql) failed: \(message)")
        }
    }
}

private extension SQLCipherConnection {
    enum DatabaseFormat {
        case missingOrEmpty
        case plaintextSQLite
        case encryptedOrUnknown
    }

    static let sqliteHeader = Data("SQLite format 3\0".utf8)

    static func databaseFormat(at url: URL) throws -> DatabaseFormat {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missingOrEmpty
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: sqliteHeader.count) ?? Data()
        if header.isEmpty {
            return .missingOrEmpty
        }
        return header == sqliteHeader ? .plaintextSQLite : .encryptedOrUnknown
    }

    static func migratePlaintextIfNecessary(paths: PassagePaths, vaultKey: VaultKey) throws {
        guard try databaseFormat(at: paths.database) == .plaintextSQLite else { return }

        let identifier = UUID().uuidString.lowercased()
        let encryptedTemporary = paths.root
            .appendingPathComponent(".passage-encrypted-migration-\(identifier).sqlite3")
        let plaintextBackup = paths.root
            .appendingPathComponent("chronicle-plaintext-backup-\(identifier).sqlite3")

        var source: OpaquePointer?
        var encrypted: OpaquePointer?
        var backup: OpaquePointer?
        var shouldRemoveEncryptedTemporary = true

        defer {
            sqlite3_close(backup)
            sqlite3_close(encrypted)
            sqlite3_close(source)
            if shouldRemoveEncryptedTemporary {
                try? FileManager.default.removeItem(at: encryptedTemporary)
            }
        }

        do {
            try openUnkeyedDatabase(
                at: paths.database,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                into: &source
            )
            guard let sourceDatabase = source else {
                throw EncryptedStoreError.plaintextMigrationFailed("The legacy database did not open.")
            }
            sqlite3_busy_timeout(sourceDatabase, 5_000)
            try requireIntegrity(on: sourceDatabase, label: "legacy plaintext index")

            // A checkpoint plus DELETE journal mode makes the source main file a
            // complete recovery point and prevents a plaintext WAL from being
            // mistaken for the new encrypted database's WAL after the swap.
            try executeMigrationSQL("PRAGMA wal_checkpoint(TRUNCATE)", on: sourceDatabase)
            let journalMode = try scalarMigrationText("PRAGMA journal_mode = DELETE", on: sourceDatabase)
            guard journalMode.lowercased() == "delete" else {
                throw EncryptedStoreError.plaintextMigrationFailed(
                    "Could not leave legacy WAL mode (reported \(journalMode))."
                )
            }
            let sourceSchemaCount = try scalarInt(
                "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                on: sourceDatabase
            )

            // Keep a coherent, validated, permission-restricted recovery copy.
            try openUnkeyedDatabase(
                at: plaintextBackup,
                flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                into: &backup
            )
            try restrictFile(at: plaintextBackup, permissions: 0o600)
            guard let backupDatabase = backup else {
                throw EncryptedStoreError.plaintextMigrationFailed("Could not create the recovery copy.")
            }
            try copyDatabase(from: sourceDatabase, to: backupDatabase)
            try requireIntegrity(on: backupDatabase, label: "plaintext recovery copy")
            guard try scalarInt(
                "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                on: backupDatabase
            ) == sourceSchemaCount else {
                throw EncryptedStoreError.plaintextMigrationFailed("The recovery copy schema did not match the source.")
            }
            sqlite3_close(backupDatabase)
            backup = nil

            // SQLCipher intentionally rejects SQLite's backup API when codecs
            // differ. Its supported migration path is an encrypted ATTACH plus
            // sqlcipher_export(), with both path and key parameter-bound.
            // Pre-create the file through a keyed handle because the packaged
            // SQLCipher VFS does not allow ATTACH to create a new side database.
            try openUnkeyedDatabase(
                at: encryptedTemporary,
                flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                into: &encrypted
            )
            guard let initialEncryptedDatabase = encrypted else {
                throw EncryptedStoreError.plaintextMigrationFailed("Could not create the encrypted destination.")
            }
            try applyKey(vaultKey, to: initialEncryptedDatabase)
            _ = try verifyCipherAndSchema(on: initialEncryptedDatabase)
            try restrictFile(at: encryptedTemporary, permissions: 0o600)
            sqlite3_close(initialEncryptedDatabase)
            encrypted = nil

            try attachEncryptedDatabase(
                at: encryptedTemporary,
                vaultKey: vaultKey,
                to: sourceDatabase
            )
            let attachedStatus = try scalarMigrationText(
                "PRAGMA encrypted.cipher_status",
                on: sourceDatabase
            )
            guard attachedStatus == "1" else {
                throw EncryptedStoreError.plaintextMigrationFailed(
                    "The attached migration destination did not activate SQLCipher."
                )
            }
            try executeMigrationSQL("SELECT sqlcipher_export('encrypted')", on: sourceDatabase)
            guard try scalarInt(
                "SELECT count(*) FROM encrypted.sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                on: sourceDatabase
            ) == sourceSchemaCount else {
                throw EncryptedStoreError.plaintextMigrationFailed("The encrypted schema did not match the source.")
            }
            try executeMigrationSQL("DETACH DATABASE encrypted", on: sourceDatabase)
            try restrictFile(at: encryptedTemporary, permissions: 0o600)

            // Reopen independently with the vault key. This validates that the
            // exported artifact does not depend on the migration connection.
            try openUnkeyedDatabase(
                at: encryptedTemporary,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                into: &encrypted
            )
            guard let encryptedDatabase = encrypted else {
                throw EncryptedStoreError.plaintextMigrationFailed("Could not reopen the encrypted destination.")
            }
            try applyKey(vaultKey, to: encryptedDatabase)
            _ = try verifyCipherAndSchema(on: encryptedDatabase)
            try requireIntegrity(on: encryptedDatabase, label: "encrypted migration destination")
            sqlite3_close(encryptedDatabase)
            encrypted = nil
            sqlite3_close(sourceDatabase)
            source = nil

            try quarantineLegacySidecars(paths: paths, alongside: plaintextBackup)
            guard Darwin.rename(encryptedTemporary.path, paths.database.path) == 0 else {
                throw EncryptedStoreError.plaintextMigrationFailed(
                    "Atomic database replacement failed: \(String(cString: strerror(errno)))."
                )
            }
            shouldRemoveEncryptedTemporary = false
            try restrictDatabaseFiles(paths: paths)
            try removePlaintextRecoveryArtifact(at: plaintextBackup)
            try syncDirectory(at: paths.root)
        } catch let error as EncryptedStoreError {
            throw error
        } catch {
            throw EncryptedStoreError.plaintextMigrationFailed(error.localizedDescription)
        }
    }

    static func openUnkeyedDatabase(
        at url: URL,
        flags: Int32,
        into database: inout OpaquePointer?
    ) throws {
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, database != nil else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned code \(result)."
            sqlite3_close(database)
            database = nil
            throw EncryptedStoreError.plaintextMigrationFailed(message)
        }
    }

    static func copyDatabase(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(destination)))
        }
        var result: Int32 = SQLITE_OK
        var busyAttempts = 0
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                busyAttempts += 1
                guard busyAttempts <= 200 else { break }
                sqlite3_sleep(25)
            }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED

        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(destination)))
        }
    }

    static func attachEncryptedDatabase(
        at url: URL,
        vaultKey: VaultKey,
        to database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "ATTACH DATABASE ? AS encrypted KEY ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, url.path, -1, transient) == SQLITE_OK else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
        let bindResult = withSQLCipherRawKey(vaultKey) { keyBytes in
            sqlite3_bind_text(
                statement,
                2,
                keyBytes.bindMemory(to: CChar.self).baseAddress,
                Int32(keyBytes.count),
                transient
            )
        }
        guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    static func requireIntegrity(on database: OpaquePointer, label: String) throws {
        let result = try scalarMigrationText("PRAGMA quick_check", on: database)
        guard result.lowercased() == "ok" else {
            throw EncryptedStoreError.plaintextMigrationFailed("The \(label) failed quick_check: \(result)")
        }
    }

    static func scalarMigrationText(_ sql: String, on database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw EncryptedStoreError.plaintextMigrationFailed(String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: text)
    }

    static func executeMigrationSQL(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw EncryptedStoreError.plaintextMigrationFailed(detail)
        }
    }

    static func quarantineLegacySidecars(paths: PassagePaths, alongside backup: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: paths.database.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: backup.path + suffix)
            try fileManager.moveItem(at: source, to: destination)
            try restrictFile(at: destination, permissions: 0o600)
        }
    }

    static func removePlaintextRecoveryArtifact(at backup: URL) throws {
        let fileManager = FileManager.default
        for url in [
            backup,
            URL(fileURLWithPath: backup.path + "-wal"),
            URL(fileURLWithPath: backup.path + "-shm"),
        ] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw EncryptedStoreError.plaintextMigrationFailed(
                    "Encrypted migration succeeded, but plaintext recovery cleanup failed for \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    static func cleanupStalePlaintextMigrationArtifacts(paths: PassagePaths) throws {
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: paths.root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw EncryptedStoreError.plaintextMigrationFailed(
                "Could not inspect the vault for stale plaintext recovery files: \(error.localizedDescription)"
            )
        }

        for url in contents where isMigrationRecoveryFilename(url.lastPathComponent) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else {
                throw EncryptedStoreError.plaintextMigrationFailed(
                    "Refusing to remove unexpected recovery artifact \(url.lastPathComponent)."
                )
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw EncryptedStoreError.plaintextMigrationFailed(
                    "Could not remove stale plaintext recovery file \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    static func isMigrationRecoveryFilename(_ name: String) -> Bool {
        let prefix = "chronicle-plaintext-backup-"
        guard name.hasPrefix(prefix) else { return false }
        var remainder = String(name.dropFirst(prefix.count))
        for suffix in [".sqlite3-wal", ".sqlite3-shm", ".sqlite3"] {
            if remainder.hasSuffix(suffix) {
                remainder.removeLast(suffix.count)
                break
            }
        }
        guard remainder.count == 36 else { return false }
        let hyphenOffsets = Set([8, 13, 18, 23])
        return remainder.enumerated().allSatisfy { offset, character in
            if hyphenOffsets.contains(offset) { return character == "-" }
            return character.isHexDigit
        }
    }

    static func restrictDatabaseFiles(paths: PassagePaths) throws {
        try restrictFile(at: paths.database, permissions: 0o600)
        try restrictFile(at: URL(fileURLWithPath: paths.database.path + "-wal"), permissions: 0o600)
        try restrictFile(at: URL(fileURLWithPath: paths.database.path + "-shm"), permissions: 0o600)
    }

    static func restrictFile(at url: URL, permissions: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch {
            throw EncryptedStoreError.fileProtectionFailed(path: url.path, message: error.localizedDescription)
        }
    }

    static func syncDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw EncryptedStoreError.plaintextMigrationFailed(
                "Could not open the storage directory for synchronization."
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw EncryptedStoreError.plaintextMigrationFailed(
                "Could not synchronize the migrated database directory."
            )
        }
    }
}
