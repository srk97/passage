import CoreML
import Foundation

struct PreparedCoreMLModels: Sendable {
    var image: URL
    var text: URL
    var loadedInPlace: Bool
}

enum CoreMLCompiledModelCache {
    private static let maximumFingerprintLength = 128

    static func prepare(
        pack: InstalledVisualModelPack,
        cacheDirectory: URL
    ) async throws -> PreparedCoreMLModels {
        let modelFingerprint = pack.manifestSHA256
        guard modelFingerprint.count == 64,
              modelFingerprint.unicodeScalars.allSatisfy({
                  ("0"..."9").contains(Character(String($0)))
                      || ("a"..."f").contains(Character(String($0)))
              }),
              modelFingerprint.count <= maximumFingerprintLength else {
            throw CoreMLVisualEmbeddingError.modelCompilationFailed
        }
        let imageSource = pack.imageEncoderURL
        let textSource = pack.textEncoderURL
        if imageSource.pathExtension == "mlmodelc",
           textSource.pathExtension == "mlmodelc",
           try validVerifiedCompiledDirectory(imageSource, beneath: pack.directoryURL),
           try validVerifiedCompiledDirectory(textSource, beneath: pack.directoryURL) {
            return PreparedCoreMLModels(
                image: imageSource,
                text: textSource,
                loadedInPlace: true
            )
        }
        let cacheRoot = cacheDirectory.standardizedFileURL
        guard cacheRoot.path != "/",
              cacheRoot.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw CoreMLVisualEmbeddingError.modelCompilationFailed
        }
        let namespace = cacheRoot.appendingPathComponent(
            modelFingerprint,
            isDirectory: true
        )
        let imageDestination = namespace.appendingPathComponent(
            "image.mlmodelc",
            isDirectory: true
        )
        let textDestination = namespace.appendingPathComponent(
            "text.mlmodelc",
            isDirectory: true
        )

        let started = ContinuousClock.now
        return try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try createOwnerOnlyDirectory(cacheRoot, fileManager: fileManager)
            try createOwnerOnlyDirectory(namespace, fileManager: fileManager)
            let image = try compileIfNeeded(
                source: imageSource,
                destination: imageDestination,
                namespace: namespace,
                fileManager: fileManager
            )
            let text = try compileIfNeeded(
                source: textSource,
                destination: textDestination,
                namespace: namespace,
                fileManager: fileManager
            )
            _ = started // Keeps the detached operation visibly bounded to this request.
            return PreparedCoreMLModels(image: image, text: text, loadedInPlace: false)
        }.value
    }

    private static func validVerifiedCompiledDirectory(
        _ directory: URL,
        beneath packRoot: URL
    ) throws -> Bool {
        let values = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let resolvedRoot = packRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.path.hasPrefix(resolvedRoot.path + "/")
    }

    private static func compileIfNeeded(
        source: URL,
        destination: URL,
        namespace: URL,
        fileManager: FileManager
    ) throws -> URL {
        if try validCompiledDirectory(destination, beneath: namespace, fileManager: fileManager) {
            return destination
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let compiled: URL
        if source.pathExtension == "mlmodelc" {
            compiled = source
        } else {
            compiled = try MLModel.compileModel(at: source)
        }
        let staging = namespace.appendingPathComponent(
            ".compile-\(UUID().uuidString).mlmodelc",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try copyTreeWithoutLinks(
            from: compiled,
            to: staging,
            fileManager: fileManager
        )
        try hardenTree(staging, fileManager: fileManager)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            // Another model instance may have won the same atomic install race.
            guard try validCompiledDirectory(
                destination,
                beneath: namespace,
                fileManager: fileManager
            ) else { throw error }
        }
        return destination
    }

    private static func validCompiledDirectory(
        _ directory: URL,
        beneath namespace: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        let resolvedNamespace = namespace.resolvingSymlinksInPath()
        let resolved = directory.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedNamespace.path + "/") else { return false }
        let values = try resolved.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func createOwnerOnlyDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func copyTreeWithoutLinks(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let sourceValues = try source.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw CoreMLVisualEmbeddingError.modelCompilationFailed
        }
        try createOwnerOnlyDirectory(destination, fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CoreMLVisualEmbeddingError.modelCompilationFailed
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw CoreMLVisualEmbeddingError.modelCompilationFailed
            }
            let relative = item.path.dropFirst(source.path.count + 1)
            guard !relative.isEmpty, !relative.hasPrefix("/") else {
                throw CoreMLVisualEmbeddingError.modelCompilationFailed
            }
            let target = destination.appendingPathComponent(String(relative))
            if values.isDirectory == true {
                try createOwnerOnlyDirectory(target, fileManager: fileManager)
            } else if values.isRegularFile == true {
                try fileManager.copyItem(at: item, to: target)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: target.path
                )
            } else {
                throw CoreMLVisualEmbeddingError.modelCompilationFailed
            }
        }
    }

    private static func hardenTree(_ root: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw CoreMLVisualEmbeddingError.modelCompilationFailed }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let permissions: Int = values.isDirectory == true ? 0o700 : 0o600
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: item.path
            )
        }
    }
}
