import Foundation

/// Conservative website recovery for browser moments whose accessibility tree
/// did not expose an address. It only considers high-confidence text in the
/// browser-chrome band at the top of a focused-window image; ordinary page text
/// is intentionally ignored.
public enum BrowserWebsiteMetadata {
    public static let minimumConfidence: Float = 0.82
    public static let minimumVerticalCenter = 0.86
    public static let maximumVerticalCenter = 0.95

    public static func enriching(
        _ context: ScreenContext,
        from regions: [OCRRegion]
    ) -> ScreenContext {
        guard context.domain == nil,
              ScreenContext.isKnownWebBrowserBundleIdentifier(
                context.bundleIdentifier
              ) else { return context }

        var enriched = context
        if let scheme = context.url?.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           let host = context.url?.host(percentEncoded: false)?.lowercased() {
            enriched.domain = normalizedHost(host)
        } else {
            enriched.domain = inferredDomain(from: regions)
        }
        return enriched
    }

    public static func inferredDomain(from regions: [OCRRegion]) -> String? {
        let candidates = regions.compactMap { region -> String? in
            let verticalCenter = region.y + region.height / 2
            let horizontalCenter = region.x + region.width / 2
            guard region.confidence >= minimumConfidence,
                  verticalCenter >= minimumVerticalCenter,
                  verticalCenter < maximumVerticalCenter,
                  horizontalCenter >= 0.06,
                  horizontalCenter <= 0.94,
                  region.width >= 0.035 else { return nil }
            return domainCandidate(region.text)
        }
        // OCR confidence says that text was recognized clearly; it does not
        // prove which control produced it. If browser chrome presents more
        // than one plausible website, preserving nil is safer than assigning a
        // tab title or page label to the active moment.
        let uniqueDomains = Set(candidates)
        guard uniqueDomains.count == 1 else { return nil }
        return uniqueDomains.first
    }

    static func domainCandidate(_ rawValue: String) -> String? {
        let trimmingCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "'\"“”‘’()[]{}<>,;")
        )
        let value = rawValue.trimmingCharacters(in: trimmingCharacters)
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return nil }

        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("about:"),
              !lowercased.hasPrefix("chrome:"),
              !lowercased.hasPrefix("safari:"),
              !lowercased.hasPrefix("javascript:"),
              !lowercased.hasPrefix("file:") else { return nil }

        let filenameExtensions = [
            ".css", ".csv", ".gif", ".htm", ".html", ".jpeg", ".jpg",
            ".js", ".json", ".md", ".pdf", ".png", ".svg", ".txt", ".xml",
        ]
        let pathlessCandidate = lowercased.split(
            whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }
        ).first.map(String.init) ?? lowercased
        guard !filenameExtensions.contains(where: pathlessCandidate.hasSuffix) else {
            return nil
        }

        let url: URL?
        if lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://") {
            url = URL(string: value)
        } else {
            url = URL(string: "https://\(value)")
        }
        guard let url,
              url.user == nil,
              url.password == nil,
              let host = url.host(percentEncoded: false) else { return nil }
        return normalizedHost(host)
    }

    static func normalizedHost(_ rawHost: String) -> String? {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        if host == "localhost" { return host }
        if host.split(separator: ".").count == 4,
           host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) {
            return host
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                guard (1...63).contains(label.utf8.count),
                      label.first != "-",
                      label.last != "-" else { return false }
                return label.utf8.allSatisfy { byte in
                    (byte >= 48 && byte <= 57)
                        || (byte >= 97 && byte <= 122)
                        || byte == 45
                }
              }),
              let suffix = labels.last,
              suffix.count >= 2,
              suffix.contains(where: { $0.isLetter }) else { return nil }
        return host
    }
}
