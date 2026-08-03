import PassageCore
import PassageIntelligence
import PassageStore
import Foundation
import OSLog

private let passageStartupLogger = Logger(
    subsystem: "app.passage.desktop",
    category: "startup"
)

/// A synchronously revocable capability whose lifetime is bounded by the
/// unlocked vault session. Implementations must make repeated `revoke()` calls
/// harmless because the underlying lock path is intentionally fail-closed.
protocol StartupVaultRevocable: AnyObject, Sendable {
    func revoke()
}

extension SQLiteFrameStore: StartupVaultRevocable {}
extension SQLiteAccessEventStore: StartupVaultRevocable {}

/// Owns every SQLCipher capability created before startup resources become the
/// model's responsibility. A macOS session lock can revoke this object without
/// waiting for the detached preparation task to reach a cancellation point.
final class StartupVaultOperation: @unchecked Sendable {
    private enum State {
        case active
        case cancelled
        case disarmed
    }

    private let lock = NSLock()
    private var state = State.active
    private var revocables: [ObjectIdentifier: any StartupVaultRevocable] = [:]

    func checkpoint() throws {
        try Task.checkCancellation()
        lock.lock()
        let isActive: Bool
        if case .active = state {
            isActive = true
        } else {
            isActive = false
        }
        lock.unlock()
        guard isActive else { throw CancellationError() }
    }

    func register(frameStore: SQLiteFrameStore) throws {
        try register(revocable: frameStore)
    }

    func register(accessEventStore: SQLiteAccessEventStore) throws {
        try register(revocable: accessEventStore)
    }

    /// Retains an arbitrary vault-scoped capability until publication or lock.
    /// Registering the same object identity more than once while active is an
    /// idempotent no-op; distinct objects are all retained and revoked.
    func register(revocable candidate: any StartupVaultRevocable) throws {
        if Task.isCancelled {
            candidate.revoke()
            revoke()
            throw CancellationError()
        }

        lock.lock()
        guard case .active = state else {
            lock.unlock()
            candidate.revoke()
            throw CancellationError()
        }
        revocables[ObjectIdentifier(candidate)] = candidate
        lock.unlock()
    }

    /// Transfers ownership to the model. A disarmed operation deliberately no
    /// longer retains or revokes the stores; the lock path revokes the model's
    /// published capabilities directly from this point onward.
    func disarmForPublication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .active = state else { return false }
        state = .disarmed
        revocables.removeAll(keepingCapacity: false)
        return true
    }

    /// Synchronously closes any store that has already registered. Constructors
    /// that finish later observe `.cancelled`, revoke their new store themselves,
    /// and fail registration.
    func revoke() {
        lock.lock()
        guard case .active = state else {
            lock.unlock()
            return
        }
        state = .cancelled
        let revocables = Array(revocables.values)
        self.revocables.removeAll(keepingCapacity: false)
        lock.unlock()

        for revocable in revocables {
            revocable.revoke()
        }
    }
}

enum PassageStartupMaintenance {
    /// Drains encrypted derived-metadata pages after the model has published its
    /// first UI state. The caller owns the task so session lock can cancel and
    /// await it together with other vault work.
    static func repairWebsiteFacets(
        repository: SQLiteFrameStore,
        batchLimit: Int = 2_000,
        initialDelay: Duration = .milliseconds(250)
    ) async throws -> Int {
        try await Task.sleep(for: initialDelay)
        return try await repository.drainMissingBrowserDomains(
            batchLimit: batchLimit
        )
    }

    static func reportWebsiteFacetRepairFailure() {
        // Do not log row content, URLs, domains, or frame identifiers.
        passageStartupLogger.error(
            "Website metadata maintenance stopped; Passage will retry on next launch."
        )
    }
}

enum StartupOpenAIKeyState: Sendable {
    case configured(Bool)
    case failed(String)
}

/// A concrete, Sendable handoff from detached preparation to the main-actor
/// model. Keeping concrete store types here prevents a non-Sendable protocol
/// existential from crossing the executor boundary.
struct PassageStartupResources: Sendable {
    let paths: PassagePaths
    let vaultKey: VaultKey
    let repository: SQLiteFrameStore
    let accessRepository: SQLiteAccessEventStore
    let mediaStore: MediaStore
    let privacyStore: PrivacyPreferencesStore
    let intelligenceCache: SessionIntelligenceCache
    let sessionQuestionCache: SessionQuestionCache
    let intelligenceSafetyIdentifier: String
    let privacyPreferences: PrivacyPreferences
    let openAIKeyState: StartupOpenAIKeyState

    static func prepare(
        operation: StartupVaultOperation,
        vaultKeyStore: KeychainVaultKeyStore,
        openAIAPIKeyStore: OpenAIAPIKeyStore
    ) async throws -> PassageStartupResources {
        try operation.checkpoint()
        let paths = try PassagePaths.live()

        try operation.checkpoint()
        let vaultKey = try vaultKeyStore.loadOrCreate()

        try operation.checkpoint()
        let repository = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)
        try operation.register(frameStore: repository)

        try operation.checkpoint()
        let accessRepository = try SQLiteAccessEventStore(paths: paths, vaultKey: vaultKey)
        try operation.register(accessEventStore: accessRepository)

        try operation.checkpoint()
        let mediaStore = MediaStore(paths: paths, vaultKey: vaultKey)
        let privacyStore = PrivacyPreferencesStore(paths: paths, vaultKey: vaultKey)
        let intelligenceCache = SessionIntelligenceCache(paths: paths, vaultKey: vaultKey)
        let sessionQuestionCache = SessionQuestionCache(paths: paths, vaultKey: vaultKey)
        let intelligenceSafetyIdentifier = vaultKey.sessionIntelligenceSafetyIdentifier()

        try operation.checkpoint()
        let privacyPreferences = try await privacyStore.load()

        try operation.checkpoint()
        _ = try await mediaStore.migrateLegacyPlaintext()

        try operation.checkpoint()
        let openAIKeyState: StartupOpenAIKeyState
        do {
            openAIKeyState = .configured(try openAIAPIKeyStore.load() != nil)
        } catch {
            openAIKeyState = .failed(error.localizedDescription)
        }

        try operation.checkpoint()
        let resources = PassageStartupResources(
            paths: paths,
            vaultKey: vaultKey,
            repository: repository,
            accessRepository: accessRepository,
            mediaStore: mediaStore,
            privacyStore: privacyStore,
            intelligenceCache: intelligenceCache,
            sessionQuestionCache: sessionQuestionCache,
            intelligenceSafetyIdentifier: intelligenceSafetyIdentifier,
            privacyPreferences: privacyPreferences,
            openAIKeyState: openAIKeyState
        )
        try operation.checkpoint()
        return resources
    }
}
