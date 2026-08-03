import Foundation

/// Immutable catalog entry for the visual model sealed into Passage's app
/// signature. The manifest fingerprint is compiled into the executable so a
/// modified resource cannot nominate its own trusted hash.
public enum BundledVisualModelCatalog {
    public static let peCoreS16Reference = VisualModelPackReference(
        identifier: "meta-pe-core-s-16-384",
        revision: "3249a38eb1c432ec19231c6fe1774acb6a4e4efe",
        manifestSHA256: "e8ab953b8ec53eeae643c96f35b164424f3a92977aa00b244ca74f41acee96ea"
    )

    public static func packURL(resourcesURL: URL) -> URL {
        resourcesURL
            .appendingPathComponent("VisualModelPacks", isDirectory: true)
            .appendingPathComponent(peCoreS16Reference.identifier, isDirectory: true)
            .appendingPathComponent(peCoreS16Reference.revision, isDirectory: true)
    }

    public static func verify(
        resourcesURL: URL,
        using store: VisualModelPackStore
    ) async throws -> InstalledVisualModelPack {
        let pack = try await store.verifyBundledPack(
            at: packURL(resourcesURL: resourcesURL),
            expectedManifestSHA256: peCoreS16Reference.manifestSHA256
        )
        guard pack.reference == peCoreS16Reference else {
            throw VisualModelPackError.unsafeInstalledPack
        }
        return pack
    }
}
