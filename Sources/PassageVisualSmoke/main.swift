import PassageVisualModel
import Darwin
import Foundation

@main
struct PassageVisualSmoke {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3 else {
                throw SmokeError.usage
            }

            let resourcesURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
                .standardizedFileURL
            let cacheURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
                .standardizedFileURL
            let packStore = VisualModelPackStore(
                rootDirectory: resourcesURL.appendingPathComponent(
                    "VisualModelPacks",
                    isDirectory: true
                )
            )
            let pack = try await BundledVisualModelCatalog.verify(
                resourcesURL: resourcesURL,
                using: packStore
            )
            let model = try await CoreMLVisualEmbeddingModel(
                pack: pack,
                compiledModelCacheDirectory: cacheURL
            )
            try await model.prewarm()
            print("Visual model inference smoke passed (text + image).")
        } catch {
            let message = "error: visual model inference smoke failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}

private enum SmokeError: Error, LocalizedError {
    case usage

    var errorDescription: String? {
        "usage: passage-visual-smoke <app-resources> <private-model-cache>"
    }
}
