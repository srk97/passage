import PassageCore
@testable import PassageIntelligence
import PassageStore
import CryptoKit
import Foundation
import Testing

@Suite("Encrypted session question cache")
struct SessionQuestionCacheTests {
    @Test("Round trips while question, answer, and identity stay out of plaintext")
    func encryptedRoundTrip() async throws {
        let fixture = try QuestionCacheFixture()
        defer { fixture.cleanup() }
        let cache = SessionQuestionCache(paths: fixture.paths, vaultKey: fixture.key)
        let input = Self.input(question: "What secret decision did I make?")
        let value = Self.answer(for: input, text: "The private launch decision was Tuesday.")

        try await cache.store(value)

        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.sessionQuestionCache,
            includingPropertiesForKeys: nil
        )
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.pathExtension == "bin")
        #expect(file.deletingPathExtension().lastPathComponent.count == 64)
        #expect(!file.lastPathComponent.contains(input.activitySessionID.rawValue))
        #expect(!file.lastPathComponent.contains(input.requestFingerprint))

        let ciphertext = try Data(contentsOf: file)
        #expect(ciphertext.range(of: Data(input.question.utf8)) == nil)
        #expect(ciphertext.range(of: Data(value.claims[0].text.utf8)) == nil)
        #expect(ciphertext.range(of: Data(input.sources[0].frameID.rawValue.utf8)) == nil)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber).intValue & 0o777
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(
                atPath: fixture.paths.sessionQuestionCache.path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        #expect(
            fileAttributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )

        #expect(try await cache.load(for: input) == value)
    }

    @Test("Question, evidence, provider, and model changes are cache misses")
    func requestIdentityInvalidation() async throws {
        let fixture = try QuestionCacheFixture()
        defer { fixture.cleanup() }
        let cache = SessionQuestionCache(paths: fixture.paths, vaultKey: fixture.key)
        let original = Self.input(question: "What did I decide?")
        try await cache.store(Self.answer(for: original, text: "You selected Tuesday."))

        let changedQuestion = Self.input(question: "What remained unfinished?")
        let changedEvidence = Self.input(
            question: original.question,
            sourceText: "A different captured source changes the evidence."
        )
        let changedProvider = Self.input(
            question: original.question,
            provider: "another-provider"
        )
        let changedModel = Self.input(
            question: original.question,
            model: "another-model"
        )

        #expect(try await cache.load(for: changedQuestion) == nil)
        #expect(try await cache.load(for: changedEvidence) == nil)
        #expect(try await cache.load(for: changedProvider) == nil)
        #expect(try await cache.load(for: changedModel) == nil)
        #expect(try await cache.load(for: original) != nil)
    }

    @Test("A different vault root and ciphertext tampering fail authentication")
    func authenticationFailures() async throws {
        let fixture = try QuestionCacheFixture()
        defer { fixture.cleanup() }
        let input = Self.input(question: "What did I decide?")
        let cache = SessionQuestionCache(paths: fixture.paths, vaultKey: fixture.key)
        try await cache.store(Self.answer(for: input, text: "You selected Tuesday."))

        let otherKey = try VaultKey.testing(bytes: Data(repeating: 0x99, count: VaultKey.byteCount))
        do {
            _ = try await SessionQuestionCache(paths: fixture.paths, vaultKey: otherKey)
                .load(for: input)
            Issue.record("Expected a wrong key to fail authentication")
        } catch let error as SessionIntelligenceError {
            #expect(error == .cacheAuthenticationFailed)
        }

        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.paths.sessionQuestionCache,
                includingPropertiesForKeys: nil
            ).first
        )
        var tampered = try Data(contentsOf: file)
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: file, options: .atomic)
        do {
            _ = try await cache.load(for: input)
            Issue.record("Expected modified ciphertext to fail authentication")
        } catch let error as SessionIntelligenceError {
            #expect(error == .cacheAuthenticationFailed)
        }
    }

    @Test("Loads surface protection migration failures without changing ciphertext")
    func protectionFailureIsSurfaced() async throws {
        let fixture = try QuestionCacheFixture()
        defer { fixture.cleanup() }
        let input = Self.input(question: "What protected decision did I make?")
        let value = Self.answer(for: input, text: "You selected Tuesday.")
        try await SessionQuestionCache(paths: fixture.paths, vaultKey: fixture.key).store(value)
        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.paths.sessionQuestionCache,
                includingPropertiesForKeys: nil
            ).first
        )
        let bytesBeforeLoad = try Data(contentsOf: file)
        let reader = SessionQuestionCache(
            paths: fixture.paths,
            vaultKey: fixture.key,
            fileManager: QuestionProtectionFailingFileManager()
        )

        do {
            _ = try await reader.load(for: input)
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: file) == bytesBeforeLoad)
    }

    @Test("Malformed envelopes and semantically invalid answers fail closed")
    func corruptionAndSemanticValidation() async throws {
        let fixture = try QuestionCacheFixture()
        defer { fixture.cleanup() }
        let input = Self.input(question: "What did I decide?")
        let cache = SessionQuestionCache(paths: fixture.paths, vaultKey: fixture.key)

        let emptyAnswered = SessionQuestionAnswer(
            activitySessionID: input.activitySessionID,
            question: input.question,
            status: .answered,
            claims: [],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: input.provider,
            model: input.model,
            contentFingerprint: input.contentFingerprint,
            questionFingerprint: input.questionFingerprint,
            requestFingerprint: input.requestFingerprint,
            evidenceThrough: input.sources.last?.capturedAt,
            evidenceMomentCount: input.sources.count,
            evidenceTextUTF8ByteCount: input.sourceTextUTF8ByteCount
        )
        do {
            try await cache.store(emptyAnswered)
            Issue.record("Expected an answered value without claims to fail")
        } catch let error as SessionIntelligenceError {
            #expect(error == .cacheCorrupted)
        }

        let valid = Self.answer(for: input, text: "You selected Tuesday.")
        try await cache.store(valid)
        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.paths.sessionQuestionCache,
                includingPropertiesForKeys: nil
            ).first
        )
        try Data("not a Passage envelope".utf8).write(to: file, options: .atomic)
        do {
            _ = try await cache.load(for: input)
            Issue.record("Expected malformed envelope to fail")
        } catch let error as SessionIntelligenceError {
            #expect(error == .cacheCorrupted)
        }
    }

    @Test("Targeted removal and remove-all remain scoped to question answers")
    func scopedRemoval() async throws {
        let fixture = try QuestionCacheFixture()
        defer { fixture.cleanup() }
        let cache = SessionQuestionCache(paths: fixture.paths, vaultKey: fixture.key)
        let first = Self.input(question: "What did I decide?")
        let second = Self.input(question: "What remained unfinished?")
        try await cache.store(Self.answer(for: first, text: "You selected Tuesday."))
        try await cache.store(Self.answer(for: second, text: "The checklist remained unfinished."))

        try await cache.remove(for: first)
        #expect(try await cache.load(for: first) == nil)
        #expect(try await cache.load(for: second) != nil)

        try FileManager.default.createDirectory(at: fixture.paths.root, withIntermediateDirectories: true)
        let sibling = fixture.paths.root.appendingPathComponent("must-survive.txt")
        let briefSibling = fixture.paths.sessionIntelligenceCache
        try Data("not a question answer".utf8).write(to: sibling, options: .atomic)
        try FileManager.default.createDirectory(at: briefSibling, withIntermediateDirectories: true)
        let briefFile = briefSibling.appendingPathComponent("brief.bin")
        try Data("encrypted brief placeholder".utf8).write(to: briefFile, options: .atomic)

        try await cache.removeAll()

        #expect(try await cache.load(for: second) == nil)
        #expect(try Data(contentsOf: sibling) == Data("not a question answer".utf8))
        #expect(try Data(contentsOf: briefFile) == Data("encrypted brief placeholder".utf8))
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.sessionQuestionCache,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test("Question-answer cache keys are purpose separated from session briefs")
    func purposeSeparation() throws {
        let key = try VaultKey.testing(bytes: Data(repeating: 0x41, count: VaultKey.byteCount))
        let context = String(repeating: "a", count: 64)
        let questionDigest = key.withDerivedKeyBytes(for: .sessionQuestionCache, context: context) {
            Data(SHA256.hash(data: Data($0)))
        }
        let briefDigest = key.withDerivedKeyBytes(for: .sessionIntelligenceCache, context: context) {
            Data(SHA256.hash(data: Data($0)))
        }

        #expect(questionDigest != briefDigest)
    }

    private static func input(
        question: String,
        sourceText: String = "The private decision was to launch on Tuesday.",
        provider: String = OpenAIResponsesSessionQuestionProvider.providerIdentifier,
        model: String = OpenAIResponsesSessionQuestionProvider.defaultModel
    ) -> SessionQuestionInput {
        SessionQuestionInput(
            activitySessionID: ActivitySessionID(rawValue: "private-session-id"),
            question: question,
            sourcesByPriority: [
                SessionIntelligenceSource(
                    frameID: FrameID(rawValue: "private-source-id"),
                    capturedAt: Date(timeIntervalSince1970: 100),
                    applicationName: "Notes",
                    windowTitle: "Private plan",
                    domain: "example.com",
                    urlString: "https://example.com/private-plan",
                    ocrSnippet: sourceText
                ),
            ],
            provider: provider,
            model: model
        )
    }

    private static func answer(
        for input: SessionQuestionInput,
        text: String
    ) -> SessionQuestionAnswer {
        SessionQuestionAnswer(
            activitySessionID: input.activitySessionID,
            question: input.question,
            status: .answered,
            claims: [
                SessionIntelligenceClaim(
                    text: text,
                    sourceFrameIDs: [input.sources[0].frameID]
                ),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: input.provider,
            model: input.model,
            contentFingerprint: input.contentFingerprint,
            questionFingerprint: input.questionFingerprint,
            requestFingerprint: input.requestFingerprint,
            evidenceThrough: input.sources.last?.capturedAt,
            evidenceMomentCount: input.sources.count,
            evidenceTextUTF8ByteCount: input.sourceTextUTF8ByteCount
        )
    }
}

private final class QuestionProtectionFailingFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        if attributes[.protectionKey] != nil {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileReadNoPermission.rawValue
            )
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class QuestionCacheFixture {
    let root: URL
    let paths: PassagePaths
    let key: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-question-cache-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        key = try VaultKey.testing(bytes: Data(repeating: 0x41, count: VaultKey.byteCount))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
