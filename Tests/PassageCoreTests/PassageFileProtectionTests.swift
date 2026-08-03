@testable import PassageCore
import Darwin
import Foundation
import Testing

@Suite("Passage file protection")
struct PassageFileProtectionTests {
    private let url = URL(fileURLWithPath: "/tmp/passage-file-protection-test.bin")

    @Test("Atomic writes request until-first-authentication protection")
    func atomicWritingPolicy() {
        let options = PassageFileProtection.atomicWritingOptions
        #expect(options.contains(.atomic))
        #expect(options.contains(.completeFileProtectionUntilFirstUserAuthentication))
    }

    @Test("Setter failures are structured and classify Cocoa 257")
    func setterFailure() {
        let operations = FakeFileProtectionOperations(
            protectionClass: .complete,
            setterError: NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileReadNoPermission.rawValue
            )
        )

        do {
            try PassageFileProtection.prepareForBackgroundAccess(
                at: url,
                operations: operations
            )
            Issue.record("Expected the protection update to fail")
        } catch let error as PassageFileProtectionError {
            guard case .attributeUpdateFailed(let path, let failure) = error else {
                Issue.record("Unexpected protection error: \(error)")
                return
            }
            #expect(path == url.path)
            #expect(failure.domain == NSCocoaErrorDomain)
            #expect(failure.code == CocoaError.Code.fileReadNoPermission.rawValue)
            #expect(error.isProtectedDataUnavailable)
            #expect(operations.setCallCount == 1)
            #expect(operations.attributeReadCallCount == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An unchanged Complete class fails verification as protected-data unavailable")
    func unchangedCompleteClass() {
        let operations = FakeFileProtectionOperations(
            protectionClass: .complete,
            appliesProtectionUpdate: false
        )

        do {
            try PassageFileProtection.prepareForBackgroundAccess(
                at: url,
                operations: operations
            )
            Issue.record("Expected verification to reject Complete protection")
        } catch let error as PassageFileProtectionError {
            #expect(
                error == .unexpectedProtectionClass(
                    path: url.path,
                    observed: FileProtectionType.complete.rawValue
                )
            )
            #expect(error.isProtectedDataUnavailable)
            #expect(operations.setCallCount == 1)
            #expect(operations.attributeReadCallCount == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A verified migration changes metadata without rewriting bytes")
    func successDoesNotRewriteBytes() throws {
        let originalBytes = Data("authenticated ciphertext must remain byte-identical".utf8)
        let operations = FakeFileProtectionOperations(
            bytes: originalBytes,
            protectionClass: .complete
        )

        try PassageFileProtection.prepareForBackgroundAccess(
            at: url,
            operations: operations
        )

        #expect(operations.protectionClass == .completeUntilFirstUserAuthentication)
        #expect(operations.bytes == originalBytes)
        #expect(operations.setCallCount == 1)
        #expect(operations.attributeReadCallCount == 1)
    }

    @Test("A nested POSIX EPERM verification failure classifies protected data")
    func underlyingPOSIXFailure() {
        let posixFailure = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapper = NSError(
            domain: "PassageFileProtectionTests",
            code: 42,
            userInfo: [NSUnderlyingErrorKey: posixFailure]
        )
        let operations = FakeFileProtectionOperations(
            protectionClass: .complete,
            attributeReadError: wrapper
        )

        #expect(PassageFileProtection.indicatesProtectedDataUnavailable(wrapper))

        do {
            try PassageFileProtection.prepareForBackgroundAccess(
                at: url,
                operations: operations
            )
            Issue.record("Expected attribute verification to fail")
        } catch let error as PassageFileProtectionError {
            guard case .attributeVerificationFailed(_, let failure) = error else {
                Issue.record("Unexpected protection error: \(error)")
                return
            }
            #expect(failure.domain == wrapper.domain)
            #expect(failure.code == wrapper.code)
            #expect(failure.indicatesProtectedDataUnavailable)
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Ordinary POSIX permission denial is not mistaken for a locked keybag")
    func ordinaryPermissionFailureIsNotProtectedData() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(!PassageFileProtection.indicatesProtectedDataUnavailable(error))
    }
}

private final class FakeFileProtectionOperations: PassageFileProtectionFileManaging {
    private(set) var bytes: Data
    private(set) var protectionClass: FileProtectionType?
    private(set) var setCallCount = 0
    private(set) var attributeReadCallCount = 0

    private let appliesProtectionUpdate: Bool
    private let setterError: (any Error)?
    private let attributeReadError: (any Error)?

    init(
        bytes: Data = Data("unchanged".utf8),
        protectionClass: FileProtectionType?,
        appliesProtectionUpdate: Bool = true,
        setterError: (any Error)? = nil,
        attributeReadError: (any Error)? = nil
    ) {
        self.bytes = bytes
        self.protectionClass = protectionClass
        self.appliesProtectionUpdate = appliesProtectionUpdate
        self.setterError = setterError
        self.attributeReadError = attributeReadError
    }

    func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        _ = path
        setCallCount += 1
        if let setterError { throw setterError }
        if appliesProtectionUpdate {
            protectionClass = attributes[.protectionKey] as? FileProtectionType
        }
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        _ = path
        attributeReadCallCount += 1
        if let attributeReadError { throw attributeReadError }
        guard let protectionClass else { return [:] }
        return [.protectionKey: protectionClass]
    }
}
