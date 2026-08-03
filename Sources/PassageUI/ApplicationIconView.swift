import AppKit
import SwiftUI

/// Resolves installed application icons through Launch Services and keeps only a process-local
/// memory cache. Passage never writes an icon cache or makes a network request for this view.
@MainActor
final class ApplicationIconProvider {
    static let shared = ApplicationIconProvider()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 128
    }

    func image(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }

        let workspaceImage = NSWorkspace.shared.icon(forFile: applicationURL.path)
        let image = (workspaceImage.copy() as? NSImage) ?? workspaceImage
        image.size = NSSize(width: 64, height: 64)
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
struct PassageApplicationIcon: View {
    let bundleIdentifier: String?
    var size: CGFloat = 18

    private var image: NSImage? {
        ApplicationIconProvider.shared.image(bundleIdentifier: bundleIdentifier)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
