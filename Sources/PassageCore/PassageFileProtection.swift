import Darwin
import Foundation

public struct PassageFileProtectionSystemFailure: Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let message: String
    public let indicatesProtectedDataUnavailable: Bool

    init(_ error: Error) {
        let cocoaError = error as NSError
        domain = cocoaError.domain
        code = cocoaError.code
        message = cocoaError.localizedDescription
        indicatesProtectedDataUnavailable = PassageFileProtection
            .indicatesProtectedDataUnavailable(error)
    }
}

/// A structured failure to apply or verify Passage's background-access file
/// protection policy.
///
/// The UI can use `isProtectedDataUnavailable` to distinguish a locked-data
/// condition from a permanent metadata or filesystem failure without retaining
/// a non-Sendable `NSError` across concurrency domains.
public enum PassageFileProtectionError: Error, Equatable, LocalizedError, Sendable {
    case attributeUpdateFailed(path: String, failure: PassageFileProtectionSystemFailure)
    case attributeVerificationFailed(
        path: String,
        failure: PassageFileProtectionSystemFailure
    )
    case unexpectedProtectionClass(path: String, observed: String?)

    public var isProtectedDataUnavailable: Bool {
        switch self {
        case .attributeUpdateFailed(_, let failure),
             .attributeVerificationFailed(_, let failure):
            failure.indicatesProtectedDataUnavailable
        case .unexpectedProtectionClass(_, let observed):
            observed == FileProtectionType.complete.rawValue
        }
    }

    public var errorDescription: String? {
        switch self {
        case .attributeUpdateFailed(let path, let failure):
            "Passage could not update file protection for \(path): \(failure.message)"
        case .attributeVerificationFailed(let path, let failure):
            "Passage could not verify file protection for \(path): \(failure.message)"
        case .unexpectedProtectionClass(let path, let observed):
            if let observed {
                "Passage found an unsupported file-protection class (\(observed)) for \(path)."
            } else {
                "Passage could not verify a file-protection class for \(path)."
            }
        }
    }
}

protocol PassageFileProtectionFileManaging {
    func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
}

extension FileManager: PassageFileProtectionFileManaging {}

/// File-protection policy for Passage-owned data and model-pack metadata.
///
/// `completeFileProtection` makes a file unavailable whenever macOS considers
/// the session locked. That is too strict for a recorder which deliberately
/// suspends and resumes around lock events: an atomic replacement can otherwise
/// remain unreadable after the user returns. Until-first-unlock protection keeps
/// the ciphertext protected across boots while allowing Passage's background
/// work to resume reliably after the user has unlocked the Mac.
public enum PassageFileProtection {
    public static var atomicWritingOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    /// Classifies both Passage's verified-migration error and raw or nested
    /// system failures emitted by other protected-data stores.
    public static func indicatesProtectedDataUnavailable(_ error: Error) -> Bool {
        indicatesProtectedDataUnavailable(error, depth: 0)
    }

    /// Migrates a Passage-owned file's metadata without reading, rewriting,
    /// or decrypting its bytes, then verifies the resulting protection class.
    public static func prepareForBackgroundAccess(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try prepareForBackgroundAccess(at: url, operations: fileManager)
    }

    /// Signed bundle resources are immutable in production, so changing their
    /// metadata is inappropriate. This deliberately narrow compatibility path
    /// lets an unsigned development copy adopt the policy without making a
    /// signed-bundle read depend on a metadata write.
    public static func prepareImmutableBundleResourceForBackgroundAccessBestEffort(
        at url: URL,
        fileManager: FileManager = .default
    ) {
        try? prepareForBackgroundAccess(at: url, operations: fileManager)
    }

    static func prepareForBackgroundAccess(
        at url: URL,
        operations: any PassageFileProtectionFileManaging
    ) throws {
        do {
            try operations.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            throw PassageFileProtectionError.attributeUpdateFailed(
                path: url.path,
                failure: PassageFileProtectionSystemFailure(error)
            )
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try operations.attributesOfItem(atPath: url.path)
        } catch {
            throw PassageFileProtectionError.attributeVerificationFailed(
                path: url.path,
                failure: PassageFileProtectionSystemFailure(error)
            )
        }

        let observed = protectionClassName(attributes[.protectionKey])
        guard observed == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else {
            throw PassageFileProtectionError.unexpectedProtectionClass(
                path: url.path,
                observed: observed
            )
        }
    }

    private static func protectionClassName(_ value: Any?) -> String? {
        if let protection = value as? FileProtectionType {
            return protection.rawValue
        }
        return value as? String
    }

    private static func indicatesProtectedDataUnavailable(
        _ error: Error,
        depth: Int
    ) -> Bool {
        guard depth < 8 else { return false }
        if let protectionError = error as? PassageFileProtectionError {
            return protectionError.isProtectedDataUnavailable
        }

        let systemError = error as NSError
        if systemError.domain == NSCocoaErrorDomain,
           systemError.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if systemError.domain == NSPOSIXErrorDomain, systemError.code == Int(EPERM) {
            return true
        }
        guard let underlying = systemError.userInfo[NSUnderlyingErrorKey] as? any Error else {
            return false
        }
        return indicatesProtectedDataUnavailable(underlying, depth: depth + 1)
    }
}
