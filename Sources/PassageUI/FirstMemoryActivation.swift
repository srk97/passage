import PassageCapture
import PassageCore
import Foundation

/// A local, deterministic search prompt derived from fields already stored in
/// Passage's encrypted index. The phrase is deliberately transient: durable
/// activation state stores only the opaque frame identifier, then reconstructs
/// this value from the encrypted frame after the vault reopens.
public struct FirstMemoryRecallCandidate: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case windowTitle
        case visibleText
        case website
        case application

        var label: String {
            switch self {
            case .windowTitle: "window title"
            case .visibleText: "visible text"
            case .website: "website"
            case .application: "app name"
            }
        }
    }

    public let frameID: FrameID
    public let query: String
    public let applicationName: String
    public let source: Source

    public init(
        frameID: FrameID,
        query: String,
        applicationName: String,
        source: Source
    ) {
        self.frameID = frameID
        self.query = query
        self.applicationName = applicationName
        self.source = source
    }
}

/// The only first-memory state stored outside the encrypted vault.
///
/// Queries, titles, OCR, domains, and application names are intentionally
/// absent. `FrameID` is an opaque random identifier used to resume against the
/// encrypted repository after unlock or relaunch.
public enum FirstMemoryActivationProgress: Codable, Equatable, Sendable {
    case pending
    case awaitingRecall(FrameID)
    case verified(FrameID)
    case skipped
}

public struct FirstMemoryActivationStore {
    public static let defaultKey = "chronicle.first-memory-activation.v2"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = FirstMemoryActivationStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> FirstMemoryActivationProgress? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(
            FirstMemoryActivationProgress.self,
            from: data
        )
    }

    public func save(_ progress: FirstMemoryActivationProgress) {
        guard let data = try? PropertyListEncoder().encode(progress) else { return }
        defaults.set(data, forKey: key)
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// The one-time activation loop between setup and a proven useful memory.
///
/// Saving is only the first half of the loop. Passage reaches `verified`
/// only after normal local Recall publishes the exact persisted `FrameID`.
public enum FirstMemoryActivationState: Equatable, Sendable {
    case preparing
    case complete
    case permissionRequired
    case paused
    case waitingForAnotherApplication
    case processing(String)
    case protectedApplication(String)
    case recallReady(FirstMemoryRecallCandidate)
    case recallSearching(FirstMemoryRecallCandidate)
    case recallFailed(FirstMemoryRecallCandidate, String)
    case resumeFailed(FrameID?, String)
    case verified(FrameID)
    case skipped
    case blocked(String)

    var showsCoach: Bool {
        switch self {
        case .complete, .skipped:
            false
        case .preparing, .permissionRequired, .paused, .waitingForAnotherApplication,
             .processing, .protectedApplication, .recallReady, .recallSearching,
             .recallFailed, .resumeFailed, .verified, .blocked:
            true
        }
    }

    /// Keeps the entire first success loop on one stable surface. The journey
    /// ends only after the person explicitly enters the normal workspace or
    /// skips; merely finding the exact frame is the payoff, not an implicit
    /// dismissal.
    var presentsJourney: Bool { showsCoach }

    var recallCandidate: FirstMemoryRecallCandidate? {
        switch self {
        case .recallReady(let candidate),
             .recallSearching(let candidate),
             .recallFailed(let candidate, _):
            candidate
        default:
            nil
        }
    }

    var readyFrameID: FrameID? {
        switch self {
        case .recallReady(let candidate),
             .recallSearching(let candidate),
             .recallFailed(let candidate, _):
            candidate.frameID
        case .verified(let frameID):
            frameID
        default:
            nil
        }
    }

    var isTerminal: Bool {
        switch self {
        case .complete, .verified, .skipped:
            true
        default:
            false
        }
    }
}

/// Builds a short phrase that is guaranteed to come from an FTS-indexed field.
/// It does not infer, caption, correct, or send any content to a provider.
enum FirstMemoryRecallSuggestion {
    static let maximumQueryCharacters = 64
    static let maximumQueryTokens = 5

    private static let genericTokens: Set<String> = [
        "and", "app", "browser", "for", "from", "home", "item", "items",
        "new", "of", "page", "tab", "the", "to", "untitled", "window", "with",
        "www", "com", "net", "org",
    ]

    static func make(for frame: FrameDocument) -> FirstMemoryRecallCandidate? {
        make(
            frameID: frame.id,
            context: frame.context,
            ocrText: frame.ocrText
        )
    }

    static func make(for hit: SearchHit) -> FirstMemoryRecallCandidate? {
        make(
            frameID: hit.id,
            context: hit.context,
            ocrText: hit.snippet
                .replacingOccurrences(of: "‹", with: "")
                .replacingOccurrences(of: "›", with: "")
        )
    }

    private static func make(
        frameID: FrameID,
        context: ScreenContext,
        ocrText: String
    ) -> FirstMemoryRecallCandidate? {
        let applicationName = normalizedDisplayText(context.applicationName)
            ?? context.applicationName

        let choices: [(String?, FirstMemoryRecallCandidate.Source)] = [
            (metadataPhrase(context.windowTitle), .windowTitle),
            (cleanOCRPhrase(ocrText), .visibleText),
            (websitePhrase(context), .website),
            (metadataPhrase(context.applicationName), .application),
        ]
        guard let choice = choices.first(where: { $0.0 != nil }),
              let query = choice.0 else { return nil }
        return FirstMemoryRecallCandidate(
            frameID: frameID,
            query: query,
            applicationName: applicationName,
            source: choice.1
        )
    }

    private static func metadataPhrase(_ source: String?) -> String? {
        guard let source else { return nil }
        let tokens = searchableTokens(in: source, allowsDigits: true)
        return boundedPhrase(preferredTokens(in: tokens))
            ?? boundedPhrase(tokens)
    }

    private static func websitePhrase(_ context: ScreenContext) -> String? {
        // `frame_search` indexes the saved URL rather than the convenience
        // domain column. Only offer a domain phrase when the trusted URL proves
        // the same host is present in that index.
        guard let url = context.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        if let normalizedDomain = context.domain?.lowercased(),
           host != normalizedDomain,
           !host.hasSuffix(".\(normalizedDomain)") {
            return nil
        }
        let tokens = searchableTokens(in: host, allowsDigits: true)
        return boundedPhrase(preferredTokens(in: tokens))
    }

    private static func cleanOCRPhrase(_ source: String) -> String? {
        // Prefer one coherent line. A line must have at least two ordinary
        // alphabetic words; mixed letter/digit OCR (for example "Toma5") and
        // punctuation-only toolbar observations are deliberately rejected.
        var bestLine: [String]?
        for line in source.split(whereSeparator: \.isNewline) {
            let tokens = searchableTokens(in: String(line), allowsDigits: false)
            let preferred = preferredTokens(in: tokens)
            let usable = preferred.count >= 2 ? preferred : tokens
            guard usable.count >= 2 else { continue }
            if let current = bestLine {
                if usable.count > current.count {
                    bestLine = usable
                }
            } else {
                bestLine = usable
            }
        }
        if let bestLine, let phrase = boundedPhrase(bestLine) {
            return phrase
        }
        let tokens = searchableTokens(in: source, allowsDigits: false)
        let preferred = preferredTokens(in: tokens)
        guard preferred.count >= 2 || tokens.count >= 2 else { return nil }
        return boundedPhrase(preferred.count >= 2 ? preferred : tokens)
    }

    private static func searchableTokens(
        in source: String,
        allowsDigits: Bool
    ) -> [String] {
        source
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in
                let characters = Array(token)
                guard (2...24).contains(characters.count) else { return false }
                let letterCount = characters.lazy.filter(\.isLetter).count
                let numberCount = characters.lazy.filter(\.isNumber).count
                guard letterCount > 0 else { return allowsDigits && numberCount >= 2 }
                if !allowsDigits, numberCount > 0 { return false }
                guard allowsDigits || letterCount >= 3 else { return false }
                if !allowsDigits {
                    let lowercased = token.lowercased()
                    let uppercased = token.uppercased()
                    let titlecased = lowercased.prefix(1).uppercased() + lowercased.dropFirst()
                    guard token == lowercased
                            || token == uppercased
                            || token == titlecased else { return false }
                }
                return true
            }
    }

    private static func preferredTokens(in tokens: [String]) -> [String] {
        tokens.filter { !genericTokens.contains($0.lowercased()) }
    }

    private static func boundedPhrase(_ tokens: [String]) -> String? {
        var result = ""
        for token in tokens.prefix(maximumQueryTokens) {
            let candidate = result.isEmpty ? token : "\(result) \(token)"
            guard candidate.count <= maximumQueryCharacters else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }

    private static func normalizedDisplayText(_ source: String) -> String? {
        let value = source
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}

/// Pure policy for deterministic lifecycle tests and UI choreography.
enum FirstMemoryActivationReducer {
    static func initial(
        frameCount: Int,
        intent: CaptureIntent,
        permissionGranted: Bool,
        progress: FirstMemoryActivationProgress? = nil
    ) -> FirstMemoryActivationState {
        switch progress {
        case .verified:
            // Verification is durable evidence that the journey succeeded.
            // A later launch should enter Passage normally rather than replay
            // a celebration that was already seen (or abandoned by quitting).
            return .complete
        case .skipped:
            return .skipped
        case .awaitingRecall, .pending:
            if frameCount > 0 { return .preparing }
        case nil:
            // Existing libraries predate the proof loop. Do not force a new
            // onboarding experience over established history.
            if frameCount > 0 { return .complete }
        }
        guard permissionGranted else { return .permissionRequired }
        return intent == .remembering ? .waitingForAnotherApplication : .paused
    }

    static func reduce(
        _ current: FirstMemoryActivationState,
        event: CaptureEvent
    ) -> FirstMemoryActivationState {
        // Once Recall is ready or terminal, background capture must not replace
        // the exact frame whose proof the person is completing.
        switch current {
        case .recallReady, .recallSearching, .recallFailed,
             .verified, .skipped, .complete:
            return current
        default:
            break
        }

        switch event {
        case .started:
            return .waitingForAnotherApplication
        case .paused:
            return .paused
        case .waitingForExternalApplication:
            return .waitingForAnotherApplication
        case .processingContext(let context, _):
            return .processing(context.applicationName)
        case .skippedPrivateContext(let context, _):
            return .protectedApplication(context.applicationName)
        case .skippedUnchanged:
            return .waitingForAnotherApplication
        case .persisted(let frame, _):
            guard let candidate = FirstMemoryRecallSuggestion.make(for: frame) else {
                return .blocked("That moment did not contain a safe searchable phrase. Passage will try the next useful moment.")
            }
            return .recallReady(candidate)
        case .retentionCommitted:
            return current
        case .failed(let message, let disposition):
            return disposition == .actionRequired ? .blocked(message) : current
        }
    }
}

/// Pure choreography for the one-shot handoff from setup into a real external
/// app. The UI applies these effects without ever activating Passage over the
/// person's work; completion is announced only through the Dock.
enum FirstMemoryHandoffPolicy {
    static func shouldHideApplication(
        armed: Bool,
        alreadyHidden: Bool,
        state: FirstMemoryActivationState
    ) -> Bool {
        armed && !alreadyHidden && state == .waitingForAnotherApplication
    }

    static func shouldRequestAttention(
        armed: Bool,
        from previous: FirstMemoryActivationState,
        to current: FirstMemoryActivationState
    ) -> Bool {
        guard armed, previous != current else { return false }
        switch current {
        case .recallReady, .protectedApplication, .blocked:
            return true
        default:
            return false
        }
    }

    static func shouldDisarm(state: FirstMemoryActivationState) -> Bool {
        state == .complete || state == .skipped
    }
}
