@testable import PassageVisualModel
import PassageCore
import Foundation
import Testing

@Suite("Local visual model pack lifecycle", .serialized)
struct VisualModelPackStoreTests {
    @Test("A pinned pack installs atomically with owner-only permissions and resolves by identity")
    func installResolveAndRemove() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        let installed = try await store.install(
            from: source.directory,
            expectedManifestSHA256: source.manifestSHA256
        )

        #expect(installed.manifest == source.manifest)
        #expect(installed.reference == VisualModelPackReference(
            identifier: "openclip-vit-b32",
            revision: "laion2b-v1",
            manifestSHA256: source.manifestSHA256
        ))
        #expect(installed.identity == VisualModelIdentity(
            identifier: "openclip-vit-b32",
            revision: "laion2b-v1",
            fingerprint: source.manifestSHA256,
            preprocessingRevision: "clip-rgb-224-center-v1",
            embeddingDimension: 512
        ))
        #expect(installed.imageEncoderURL.lastPathComponent == "image.mlmodelc")
        #expect(installed.textEncoderURL.lastPathComponent == "text.mlmodelc")
        #expect(try Data(contentsOf: installed.imageEncoderURL.appendingPathComponent("weights.bin"))
            == source.imageBytes)

        try Self.expectPermissions(fixture.installedRoot, 0o700)
        try Self.expectPermissions(installed.directoryURL.deletingLastPathComponent(), 0o700)
        try Self.expectPermissions(installed.directoryURL, 0o700)
        try Self.expectPermissions(installed.imageEncoderURL, 0o700)
        try Self.expectPermissions(
            installed.imageEncoderURL.appendingPathComponent("weights.bin"),
            0o600
        )
        try Self.expectPermissions(
            installed.directoryURL.appendingPathComponent(VisualModelPackStore.manifestFilename),
            0o600
        )

        let resolved = try await store.resolve(installed.reference)
        #expect(resolved == installed)
        let idempotent = try await store.install(
            from: source.directory,
            expectedManifestSHA256: source.manifestSHA256
        )
        #expect(idempotent == installed)

        #expect(try await store.remove(
            identifier: installed.manifest.identifier,
            revision: installed.manifest.revision
        ))
        #expect(!FileManager.default.fileExists(atPath: installed.directoryURL.path))
        #expect(!(try await store.remove(
            identifier: installed.manifest.identifier,
            revision: installed.manifest.revision
        )))
    }

    @Test("A tampered artifact is rejected without publishing a partial pack")
    func rejectsTamperedArtifact() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        try Data("tampered".utf8).write(to: source.imageFile, options: .atomic)
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        await #expect(throws: VisualModelPackError.self) {
            try await store.install(
                from: source.directory,
                expectedManifestSHA256: source.manifestSHA256
            )
        }

        let destination = fixture.installedRoot
            .appendingPathComponent(source.manifest.identifier)
            .appendingPathComponent(source.manifest.revision)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.installedRoot.path)
        #expect(leftovers.allSatisfy { !$0.hasPrefix(".install-") })
    }

    @Test("The caller-supplied manifest pin is mandatory and checked before installation")
    func rejectsWrongManifestPin() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        await #expect(throws: VisualModelPackError.self) {
            try await store.install(
                from: source.directory,
                expectedManifestSHA256: String(repeating: "0", count: 64)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installedRoot.path))
    }

    @Test("Source symlinks are rejected even when their bytes match the manifest")
    func rejectsSourceSymlink() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let external = fixture.base.appendingPathComponent("outside.bin")
        try source.imageBytes.write(to: external)
        try FileManager.default.removeItem(at: source.imageFile)
        try FileManager.default.createSymbolicLink(
            at: source.imageFile,
            withDestinationURL: external
        )
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        await #expect(throws: VisualModelPackError.self) {
            try await store.install(
                from: source.directory,
                expectedManifestSHA256: source.manifestSHA256
            )
        }
    }

    @Test("Resolution detects post-install tampering and undeclared content")
    func resolveRevalidatesInstalledBytes() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)
        let installed = try await store.install(
            from: source.directory,
            expectedManifestSHA256: source.manifestSHA256
        )
        let image = installed.imageEncoderURL.appendingPathComponent("weights.bin")
        try Data("replacement bytes".utf8).write(to: image, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)

        await #expect(throws: VisualModelPackError.self) {
            try await store.resolve(installed.reference)
        }

        try source.imageBytes.write(to: image, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
        let undeclared = installed.directoryURL.appendingPathComponent("untrusted.bin")
        try Data("not in the manifest".utf8).write(to: undeclared)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: undeclared.path
        )
        await #expect(throws: VisualModelPackError.self) {
            try await store.resolve(installed.reference)
        }
    }

    @Test("An installed identifier and revision can never be overwritten in place")
    func conflictingPackDoesNotOverwrite() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)
        let installed = try await store.install(
            from: source.directory,
            expectedManifestSHA256: source.manifestSHA256
        )

        var conflictingManifest = source.manifest
        conflictingManifest.license.notice = "A different manifest with the same path identity."
        let conflictingData = try Self.encode(conflictingManifest)
        try conflictingData.write(
            to: source.directory.appendingPathComponent(VisualModelPackStore.manifestFilename),
            options: .atomic
        )
        await #expect(throws: VisualModelPackError.self) {
            try await store.install(
                from: source.directory,
                expectedManifestSHA256: VisualModelPackStore.sha256Hex(conflictingData)
            )
        }
        #expect(try await store.resolve(installed.reference) == installed)
    }

    @Test("Traversal paths and model entry points without pinned files fail closed")
    func invalidPathsFailClosed() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        var manifest = source.manifest
        manifest.artifacts[0].relativePath = "../outside.bin"
        manifest.model.imageEncoderPath = "missing.mlmodelc"
        let data = try Self.encode(manifest)
        try data.write(
            to: source.directory.appendingPathComponent(VisualModelPackStore.manifestFilename),
            options: .atomic
        )
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        await #expect(throws: VisualModelPackError.self) {
            try await store.install(
                from: source.directory,
                expectedManifestSHA256: VisualModelPackStore.sha256Hex(data)
            )
        }
    }

    @Test("A signed-bundle pack verifies in place without an install receipt or copy")
    func verifiesBundledPackWithoutWriting() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let manifestURL = source.directory.appendingPathComponent(
            VisualModelPackStore.manifestFilename
        )
        let manifestBytes = try Data(contentsOf: manifestURL)
        let store = VisualModelPackStore(
            rootDirectory: fixture.installedRoot,
            fileManager: PackProtectionFailingFileManager()
        )

        let verified = try await store.verifyBundledPack(
            at: source.directory,
            expectedManifestSHA256: source.manifestSHA256
        )

        #expect(verified.manifest == source.manifest)
        #expect(verified.directoryURL == source.directory.resolvingSymlinksInPath())
        #expect(verified.reference.manifestSHA256 == source.manifestSHA256)
        #expect(!FileManager.default.fileExists(atPath: fixture.installedRoot.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: source.directory
                    .appendingPathComponent(".chronicle-install.json")
                    .path
            )
        )
        #expect(try Data(contentsOf: manifestURL) == manifestBytes)
    }

    @Test("Installed-pack resolution surfaces strict protection failures")
    func resolveSurfacesProtectionFailure() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let installed = try await VisualModelPackStore(rootDirectory: fixture.installedRoot)
            .install(
                from: source.directory,
                expectedManifestSHA256: source.manifestSHA256
            )
        let manifestURL = installed.directoryURL.appendingPathComponent(
            VisualModelPackStore.manifestFilename
        )
        let manifestBytes = try Data(contentsOf: manifestURL)
        let store = VisualModelPackStore(
            rootDirectory: fixture.installedRoot,
            fileManager: PackProtectionFailingFileManager()
        )

        do {
            _ = try await store.resolve(installed.reference)
            Issue.record("Expected file-protection migration to fail")
        } catch let error as PassageFileProtectionError {
            #expect(error.isProtectedDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: manifestURL) == manifestBytes)
    }

    @Test("Bundled-pack verification rejects changed bytes and symbolic links")
    func bundledPackTamperingFailsClosed() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        try Data("changed bundled weights".utf8).write(to: source.imageFile, options: .atomic)
        await #expect(throws: VisualModelPackError.self) {
            _ = try await store.verifyBundledPack(
                at: source.directory,
                expectedManifestSHA256: source.manifestSHA256
            )
        }

        let external = fixture.base.appendingPathComponent("bundled-outside.bin")
        try source.imageBytes.write(to: external)
        try FileManager.default.removeItem(at: source.imageFile)
        try FileManager.default.createSymbolicLink(
            at: source.imageFile,
            withDestinationURL: external
        )
        await #expect(throws: VisualModelPackError.self) {
            _ = try await store.verifyBundledPack(
                at: source.directory,
                expectedManifestSHA256: source.manifestSHA256
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installedRoot.path))
    }

    @Test("The v1 PE safety ceiling has measured headroom and rejects implausible packs")
    func v1PackSafetyCeiling() async throws {
        let measuredV1PackBytes: Int64 = 118_182_009
        #expect(VisualModelPackStore.maximumPackBytes == 512 * 1_024 * 1_024)
        #expect(VisualModelPackStore.maximumPackBytes > measuredV1PackBytes * 4)
        #expect(VisualModelPackStore.maximumPackBytes < measuredV1PackBytes * 5)

        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        var manifest = source.manifest
        manifest.artifacts[0].byteCount = VisualModelPackStore.maximumPackBytes
        manifest.artifacts[1].byteCount = 1
        let manifestData = try Self.encode(manifest)
        try manifestData.write(
            to: source.directory.appendingPathComponent(VisualModelPackStore.manifestFilename),
            options: .atomic
        )
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)

        do {
            _ = try await store.install(
                from: source.directory,
                expectedManifestSHA256: VisualModelPackStore.sha256Hex(manifestData)
            )
            Issue.record("Expected a manifest over the v1 PE safety ceiling to fail")
        } catch let error as VisualModelPackError {
            #expect(error == .packTooLarge)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installedRoot.path))
    }

    @Test("The bundled catalog path and trust pin are immutable")
    func bundledCatalogPin() {
        let reference = BundledVisualModelCatalog.peCoreS16Reference
        #expect(reference.identifier == "meta-pe-core-s-16-384")
        #expect(reference.revision == "3249a38eb1c432ec19231c6fe1774acb6a4e4efe")
        #expect(reference.manifestSHA256 == "e8ab953b8ec53eeae643c96f35b164424f3a92977aa00b244ca74f41acee96ea")
        let resources = URL(fileURLWithPath: "/Applications/Passage.app/Contents/Resources")
        #expect(BundledVisualModelCatalog.packURL(resourcesURL: resources).path ==
            "/Applications/Passage.app/Contents/Resources/VisualModelPacks/meta-pe-core-s-16-384/3249a38eb1c432ec19231c6fe1774acb6a4e4efe")
    }

    @Test("Verified compiled models load in place without creating a duplicate cache")
    func verifiedCompiledModelsStayInPlace() async throws {
        let fixture = try ModelPackFixture()
        let source = try fixture.makeSource()
        let store = VisualModelPackStore(rootDirectory: fixture.installedRoot)
        let pack = try await store.verifyBundledPack(
            at: source.directory,
            expectedManifestSHA256: source.manifestSHA256
        )
        let cache = fixture.base.appendingPathComponent("compiled-cache", isDirectory: true)

        let prepared = try await CoreMLCompiledModelCache.prepare(
            pack: pack,
            cacheDirectory: cache
        )

        #expect(prepared.loadedInPlace)
        #expect(prepared.image == pack.imageEncoderURL)
        #expect(prepared.text == pack.textEncoderURL)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    private static func expectPermissions(_ url: URL, _ expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == expected)
    }

    fileprivate static func encode(_ manifest: VisualModelPackManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }
}

private final class PackProtectionFailingFileManager: FileManager, @unchecked Sendable {
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

private struct ModelPackSource {
    var directory: URL
    var manifest: VisualModelPackManifest
    var manifestSHA256: String
    var imageFile: URL
    var imageBytes: Data
}

private final class ModelPackFixture {
    let base: URL
    let installedRoot: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-visual-model-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        installedRoot = base.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func makeSource() throws -> ModelPackSource {
        let directory = base.appendingPathComponent("download", isDirectory: true)
        let imageDirectory = directory.appendingPathComponent(
            "Models/image.mlmodelc",
            isDirectory: true
        )
        let textDirectory = directory.appendingPathComponent(
            "Models/text.mlmodelc",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: textDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let imageBytes = Data("image encoder weights".utf8)
        let textBytes = Data("text encoder weights".utf8)
        let imageFile = imageDirectory.appendingPathComponent("weights.bin")
        let textFile = textDirectory.appendingPathComponent("weights.bin")
        try imageBytes.write(to: imageFile)
        try textBytes.write(to: textFile)

        let manifest = VisualModelPackManifest(
            identifier: "openclip-vit-b32",
            revision: "laion2b-v1",
            model: VisualModelMetadata(
                displayName: "OpenCLIP ViT-B/32",
                provider: "LAION",
                architecture: "ViT-B-32",
                imageEncoderPath: "Models/image.mlmodelc",
                textEncoderPath: "Models/text.mlmodelc",
                preprocessingRevision: "clip-rgb-224-center-v1",
                embeddingDimension: 512,
                imageInputWidth: 224,
                imageInputHeight: 224,
                maximumTextTokens: 77,
                parameterCount: 151_277_313
            ),
            license: VisualModelLicenseMetadata(
                name: "MIT",
                spdxIdentifier: "MIT",
                sourceURL: URL(string: "https://huggingface.co/laion/CLIP-ViT-B-32-laion2B-s34B-b79K"),
                notice: "Model attribution and license notice bundled with this pack."
            ),
            artifacts: [
                VisualModelArtifact(
                    role: .imageEncoder,
                    relativePath: "Models/image.mlmodelc/weights.bin",
                    byteCount: Int64(imageBytes.count),
                    sha256: VisualModelPackStore.sha256Hex(imageBytes)
                ),
                VisualModelArtifact(
                    role: .textEncoder,
                    relativePath: "Models/text.mlmodelc/weights.bin",
                    byteCount: Int64(textBytes.count),
                    sha256: VisualModelPackStore.sha256Hex(textBytes)
                ),
            ]
        )
        let manifestData = try VisualModelPackStoreTests.encode(manifest)
        try manifestData.write(
            to: directory.appendingPathComponent(VisualModelPackStore.manifestFilename),
            options: .atomic
        )
        return ModelPackSource(
            directory: directory,
            manifest: manifest,
            manifestSHA256: VisualModelPackStore.sha256Hex(manifestData),
            imageFile: imageFile,
            imageBytes: imageBytes
        )
    }
}
