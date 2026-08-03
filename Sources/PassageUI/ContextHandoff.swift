import AppKit
import PassageCore
import Foundation
import SwiftUI

enum ContextHandoffExportFormat: String, CaseIterable, Hashable, Identifiable, Sendable {
    case markdown
    case json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        }
    }
}

enum ContextHandoffOrigin: Hashable, Sendable {
    case moment(frameID: FrameID, activitySessionID: ActivitySessionID?)
    case session(ActivitySessionID)
}

enum ContextHandoffRetrieval: Hashable, Sendable {
    case moment(FrameID)
    case session(ActivitySessionID)
}

struct ContextHandoffDraft: Hashable, Sendable {
    var origin: ContextHandoffOrigin
    var retrieval: ContextHandoffRetrieval
    var title: String
    var scopeDescription: String
    var containsPrivateHistory: Bool
}

struct ContextHandoffAccessibility: Codable, Hashable, Sendable {
    var role: String
    var label: String?
    var value: String?
    var depth: Int
}

struct ContextHandoffVisualEvidence: Codable, Hashable, Sendable {
    var similarity: Double
    var maximumSimilarityError: Double
    var minimumPossibleSimilarity: Double
    var modelIdentifier: String
    var modelRevision: String
}

struct ContextHandoffSource: Codable, Hashable, Sendable, Identifiable {
    var frameID: FrameID
    var activitySessionID: ActivitySessionID?
    var capturedAt: Date
    var fusedRank: Int
    var savedTextRank: Int?
    var visualAppearanceRank: Int?
    var applicationName: String
    var bundleIdentifier: String?
    var domain: String?
    var siteOrigin: String?
    var evidenceModalities: [PassageMemoryEvidenceModality]
    var selectionReasons: [PassageMemorySelectionReason]
    var ocrText: String
    var ocrTextTruncated: Bool
    var accessibility: [ContextHandoffAccessibility]
    var accessibilityTruncated: Bool
    var visual: ContextHandoffVisualEvidence?

    var id: FrameID { frameID }

    init(_ source: PassageMemoryCapsuleSource) {
        frameID = source.frameID
        activitySessionID = source.activitySessionID
        capturedAt = source.capturedAt
        fusedRank = source.fusedRank
        savedTextRank = source.savedTextRank
        visualAppearanceRank = source.visualAppearanceRank
        applicationName = source.applicationName
        bundleIdentifier = source.bundleIdentifier
        domain = source.domain
        siteOrigin = source.url
        evidenceModalities = source.evidenceModalities
        selectionReasons = source.selectionReasons
        ocrText = source.ocrText
        ocrTextTruncated = source.ocrTextTruncated
        accessibility = source.accessibility.map {
            ContextHandoffAccessibility(
                role: $0.role,
                label: $0.label,
                value: $0.value,
                depth: $0.depth
            )
        }
        accessibilityTruncated = source.accessibilityTruncated
        visual = source.visual.map {
            ContextHandoffVisualEvidence(
                similarity: $0.similarity,
                maximumSimilarityError: $0.maximumSimilarityError,
                minimumPossibleSimilarity: $0.minimumPossibleSimilarity,
                modelIdentifier: $0.modelIdentifier,
                modelRevision: $0.modelRevision
            )
        }
    }

    /// Revalidates every exported byte against the authoritative, current
    /// private-safe frame immediately before a receipt and clipboard write.
    func matches(_ evidence: AgentSafeFrameEvidence) -> Bool {
        let frame = evidence.frame
        guard frame.id == frameID,
              evidence.activitySessionID == activitySessionID,
              frame.capturedAt == capturedAt,
              frame.context.applicationName == applicationName,
              frame.context.bundleIdentifier == bundleIdentifier,
              ContextHandoffSanitizer.domain(frame.context.domain) == domain,
              ContextHandoffSanitizer.siteOrigin(frame.context.url) == siteOrigin else {
            return false
        }
        if ocrTextTruncated {
            guard frame.ocrText.hasPrefix(ocrText) else { return false }
        } else if frame.ocrText != ocrText {
            return false
        }

        let currentAccessibility = Set(
            (frame.accessibilitySnapshot?.nodes ?? []).compactMap {
                ContextHandoffSanitizer.accessibility($0)
            }
        )
        return accessibility.allSatisfy(currentAccessibility.contains)
    }
}

struct ContextHandoffCoverage: Codable, Hashable, Sendable {
    var eligibleCandidateCount: Int
    var countIsLowerBound: Bool
    var savedTextCandidateCount: Int
    var visualAppearanceCandidateCount: Int
    var multimodalCandidateCount: Int
    var disclosedSavedTextCount: Int
    var disclosedAccessibilityCount: Int
    var disclosedVisualAppearanceCount: Int
}

struct ContextHandoffOmission: Codable, Hashable, Sendable, Identifiable {
    var reason: PassageMemoryCapsuleOmissionReason
    var count: Int
    var countIsLowerBound: Bool

    var id: PassageMemoryCapsuleOmissionReason { reason }
}

struct ContextHandoffApplication: Codable, Hashable, Sendable, Identifiable {
    var applicationName: String
    var bundleIdentifier: String?
    var sourceCount: Int

    var id: String { bundleIdentifier ?? "name:\(applicationName)" }
}

struct ContextHandoffWebsite: Codable, Hashable, Sendable, Identifiable {
    var domain: String
    var sourceCount: Int

    var id: String { domain }
}

struct ContextHandoffPayload: Codable, Hashable, Sendable {
    static let currentFormatVersion: UInt16 = 1

    var formatVersion: UInt16
    var capsuleSchemaVersion: UInt16
    var title: String
    var scopeDescription: String
    var requestedCount: Int
    var disclosedCount: Int
    var hasMoreCandidates: Bool
    var truncated: Bool
    var retrievalModalities: [PassageMemoryRetrievalModality]
    var coverage: ContextHandoffCoverage
    var omissions: [ContextHandoffOmission]
    var applications: [ContextHandoffApplication]
    var websites: [ContextHandoffWebsite]
    var screenshotsIncluded: Bool
    var mediaPathsIncluded: Bool
    var pixelGeometryIncluded: Bool
    var embeddingVectorsIncluded: Bool
    var canonicalUTF8Bytes: Int
    var sources: [ContextHandoffSource]

    static func make(
        manifest: PassageMemoryCapsuleManifest,
        title: String,
        scopeDescription: String
    ) throws -> Self {
        let sources = manifest.sources.map(ContextHandoffSource.init)
        let groupedApplications = Dictionary(grouping: sources) {
            ($0.bundleIdentifier ?? "name:\($0.applicationName)").lowercased()
        }
        let applications: [ContextHandoffApplication] = groupedApplications.values.map { group in
            let first = group[0]
            return ContextHandoffApplication(
                applicationName: first.applicationName,
                bundleIdentifier: first.bundleIdentifier,
                sourceCount: group.count
            )
        }.sorted {
            if $0.sourceCount != $1.sourceCount { return $0.sourceCount > $1.sourceCount }
            return $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
                == .orderedAscending
        }
        let websites = Dictionary(grouping: sources.compactMap(\.domain)) { $0 }
            .map { ContextHandoffWebsite(domain: $0.key, sourceCount: $0.value.count) }
            .sorted {
                if $0.sourceCount != $1.sourceCount { return $0.sourceCount > $1.sourceCount }
                return $0.domain < $1.domain
            }

        var payload = Self(
            formatVersion: currentFormatVersion,
            capsuleSchemaVersion: manifest.schemaVersion,
            title: title,
            scopeDescription: scopeDescription,
            requestedCount: manifest.requestedCount,
            disclosedCount: sources.count,
            hasMoreCandidates: manifest.hasMoreCandidates,
            truncated: manifest.truncated,
            retrievalModalities: manifest.retrievalModalities,
            coverage: ContextHandoffCoverage(
                eligibleCandidateCount: manifest.coverage.candidateCount,
                countIsLowerBound: manifest.coverage.isLowerBound,
                savedTextCandidateCount: manifest.coverage.savedTextCandidateCount,
                visualAppearanceCandidateCount: manifest.coverage.visualAppearanceCandidateCount,
                multimodalCandidateCount: manifest.coverage.multimodalCandidateCount,
                disclosedSavedTextCount: manifest.coverage.disclosedSavedTextCount,
                disclosedAccessibilityCount: manifest.coverage.disclosedAccessibilityCount,
                disclosedVisualAppearanceCount: manifest.coverage.disclosedVisualAppearanceCount
            ),
            omissions: manifest.omissions.map {
                ContextHandoffOmission(
                    reason: $0.reason,
                    count: $0.count,
                    countIsLowerBound: $0.countIsLowerBound
                )
            },
            applications: applications,
            websites: websites,
            screenshotsIncluded: false,
            mediaPathsIncluded: false,
            pixelGeometryIncluded: false,
            embeddingVectorsIncluded: false,
            canonicalUTF8Bytes: 0,
            sources: sources
        )
        for _ in 0..<32 {
            let encoded = try payload.canonicalJSONData()
            let byteCount = encoded.count
            if payload.canonicalUTF8Bytes == byteCount { return payload }
            payload.canonicalUTF8Bytes = byteCount
        }
        throw PassageMemoryCapsuleBuildError.couldNotStabilizeEncodedSize
    }

    func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct PreparedContextHandoff: Hashable, Sendable {
    var draft: ContextHandoffDraft
    var payload: ContextHandoffPayload
    var markdown: String
    var canonicalJSON: String

    static func make(
        draft: ContextHandoffDraft,
        manifest: PassageMemoryCapsuleManifest
    ) throws -> Self {
        let payload = try ContextHandoffPayload.make(
            manifest: manifest,
            title: draft.title,
            scopeDescription: draft.scopeDescription
        )
        return Self(
            draft: draft,
            payload: payload,
            markdown: ContextHandoffMarkdown.render(payload),
            canonicalJSON: String(decoding: try payload.canonicalJSONData(), as: UTF8.self)
        )
    }

    var sourceIDs: [FrameID] { payload.sources.map(\.frameID) }
    var canCopy: Bool { !payload.sources.isEmpty }

    func artifact(for format: ContextHandoffExportFormat) -> String {
        switch format {
        case .markdown: markdown
        case .json: canonicalJSON
        }
    }

    func utf8ByteCount(for format: ContextHandoffExportFormat) -> Int {
        artifact(for: format).utf8.count
    }
}

enum ContextHandoffInvalidation: Equatable, Sendable {
    case historyChanged

    var message: String {
        switch self {
        case .historyChanged:
            "History changed while this handoff was open. Prepare it again before copying."
        }
    }
}

enum ContextHandoffState: Equatable, Sendable {
    case idle
    case preparing(ContextHandoffDraft)
    case ready(PreparedContextHandoff)
    case copying(PreparedContextHandoff, ContextHandoffExportFormat)
    case copied(PreparedContextHandoff, ContextHandoffExportFormat)
    case failed(ContextHandoffDraft, String)
    case invalidated(ContextHandoffDraft, ContextHandoffInvalidation)

    var isPresented: Bool { self != .idle }

    var draft: ContextHandoffDraft? {
        switch self {
        case .idle: nil
        case .preparing(let draft), .failed(let draft, _), .invalidated(let draft, _): draft
        case .ready(let prepared), .copying(let prepared, _), .copied(let prepared, _):
            prepared.draft
        }
    }

    var prepared: PreparedContextHandoff? {
        switch self {
        case .ready(let prepared), .copying(let prepared, _), .copied(let prepared, _): prepared
        default: nil
        }
    }
}

@MainActor
protocol ContextHandoffClipboardWriting: AnyObject {
    func write(_ text: String) throws
}

enum ContextHandoffClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "Passage couldn't put this handoff on the macOS clipboard."
    }
}

@MainActor
final class SystemContextHandoffClipboard: ContextHandoffClipboardWriting {
    func write(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ContextHandoffClipboardError.writeFailed
        }
    }
}

@MainActor
enum ContextHandoffReleaseCoordinator {
    /// Returns `false` when the caller's lifecycle changed while the receipt
    /// was committing. In that case the durable receipt conservatively remains,
    /// but the clipboard is never touched.
    static func release(
        artifact: String,
        event: AccessEvent,
        receiptStore: any AccessEventRepository,
        clipboard: any ContextHandoffClipboardWriting,
        canRelease: () -> Bool
    ) async throws -> Bool {
        try await receiptStore.recordAccessEvent(event)
        guard canRelease() else { return false }
        try clipboard.write(artifact)
        return true
    }
}

private enum ContextHandoffSanitizer {
    static func domain(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    static func siteOrigin(_ url: URL?) -> String? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""
        return components.url?.absoluteString
    }

    static func accessibility(
        _ node: AccessibilityNodeEvidence
    ) -> ContextHandoffAccessibility? {
        let role = boundedText(node.role, maximumCharacters: 64) ?? ""
        let label = boundedText(node.label, maximumCharacters: 240)
        let value = boundedText(node.value, maximumCharacters: 480)
        guard !role.isEmpty, label != nil || value != nil else { return nil }
        return ContextHandoffAccessibility(
            role: role,
            label: label,
            value: value,
            depth: min(max(node.depth, 0), 32)
        )
    }

    private static func boundedText(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
                return " "
            }
            return Character(scalar)
        }
        let trimmed = String(cleaned)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumCharacters))
    }
}

private enum ContextHandoffMarkdown {
    static func render(_ payload: ContextHandoffPayload) -> String {
        var lines = [
            "# Passage Context Handoff",
            "",
            "\(payload.disclosedCount) exact source\(payload.disclosedCount == 1 ? "" : "s") · \(payload.canonicalUTF8Bytes) canonical JSON bytes",
            "",
            "**Scope:** \(escape(payload.scopeDescription))",
            "",
            "Screenshots, media paths, pixel geometry, and embedding vectors are not included.",
            "",
            "## Coverage",
            "",
            "- Eligible candidates: \(payload.coverage.eligibleCandidateCount)\(payload.coverage.countIsLowerBound ? "+" : "")",
            "- Disclosed sources: \(payload.disclosedCount)",
            "- Saved-text candidates: \(payload.coverage.savedTextCandidateCount)",
            "- Visual candidates: \(payload.coverage.visualAppearanceCandidateCount)",
            "- Found by both: \(payload.coverage.multimodalCandidateCount)",
            "- Sources with app-provided text: \(payload.coverage.disclosedAccessibilityCount)",
            "- Sources with visual-match provenance: \(payload.coverage.disclosedVisualAppearanceCount)",
        ]

        if !payload.omissions.isEmpty {
            lines += ["", "## Omissions", ""]
            lines += payload.omissions.map {
                "- \(omissionLabel($0.reason)): \($0.countIsLowerBound ? "at least " : "")\($0.count)"
            }
        }

        if !payload.applications.isEmpty || !payload.websites.isEmpty {
            lines += ["", "## Apps and websites", ""]
            lines += payload.applications.map {
                "- \(escape($0.applicationName)) — \($0.sourceCount) source\($0.sourceCount == 1 ? "" : "s")"
            }
            lines += payload.websites.map {
                "- \(escape($0.domain)) — \($0.sourceCount) source\($0.sourceCount == 1 ? "" : "s")"
            }
        }

        lines += ["", "## Sources"]
        for source in payload.sources {
            lines += [
                "",
                "### \(escape(source.applicationName)) · \(timestamp(source.capturedAt))",
                "",
                "- Frame: `\(source.frameID.rawValue)`",
            ]
            if let sessionID = source.activitySessionID {
                lines.append("- Session: `\(sessionID.rawValue)`")
            }
            if let domain = source.domain {
                lines.append("- Website: \(escape(domain))")
            }
            lines.append("- Evidence: \(source.evidenceModalities.map(evidenceLabel).joined(separator: ", "))")
            lines.append("- Selected by: \(source.selectionReasons.map(selectionLabel).joined(separator: ", "))")

            if !source.accessibility.isEmpty {
                lines += ["", "#### Text provided by the app", ""]
                for item in source.accessibility {
                    var value = "Role: \(item.role)"
                    if let label = item.label { value += "\nLabel: \(label)" }
                    if let itemValue = item.value { value += "\nValue: \(itemValue)" }
                    lines.append(fenced(value))
                    lines.append("")
                }
            }
            if !source.ocrText.isEmpty {
                lines += [
                    "",
                    "#### Text read from the image\(source.ocrTextTruncated ? " (truncated)" : "")",
                    "",
                    fenced(source.ocrText),
                ]
            }
            if let visual = source.visual {
                lines += [
                    "",
                    "#### Visual-match provenance",
                    "",
                    "- Similarity: \(String(format: "%.3f", visual.similarity)) ± \(String(format: "%.3f", visual.maximumSimilarityError))",
                    "- Model: `\(visual.modelIdentifier)` / `\(visual.modelRevision)`",
                ]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fenced(_ text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)text\n\(text)\n\(fence)"
    }

    private static func escape(_ value: String) -> String {
        var result = value
        for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "+", "-", ".", "!", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return result.replacingOccurrences(of: "\n", with: " ")
    }

    private static func evidenceLabel(_ value: PassageMemoryEvidenceModality) -> String {
        switch value {
        case .ocr: "OCR"
        case .accessibility: "app text"
        case .visualSimilarity: "visual similarity"
        }
    }

    private static func selectionLabel(_ value: PassageMemorySelectionReason) -> String {
        switch value {
        case .fusedRank: "combined relevance"
        case .savedTextCoverage: "saved text"
        case .visualAppearanceCoverage: "visual appearance"
        case .activitySessionDiversity: "session diversity"
        case .applicationDiversity: "app diversity"
        case .domainDiversity: "website diversity"
        }
    }

    private static func omissionLabel(_ value: PassageMemoryCapsuleOmissionReason) -> String {
        switch value {
        case .sensitiveContext: "Private context"
        case .resultLimit: "Result limit"
        case .byteBudget: "Size limit"
        case .candidateWindow: "Candidate window"
        case .ocrTruncation: "OCR text truncation"
        case .accessibilityTruncation: "App text truncation"
        case .visualIndexUnavailable: "Visual index unavailable"
        case .visualIndexPartial: "Visual index still preparing"
        }
    }
}

struct ContextHandoffSheet: View {
    @Bindable var model: PassageModel
    @State private var format: ContextHandoffExportFormat = .markdown
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.55)
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { close() }
        .onDisappear { model.dismissContextHandoff() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(PassagePalette.accent.opacity(0.11))
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PassagePalette.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Hand off context")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(model.contextHandoffState.draft?.title ?? "Passage context")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .background(.quaternary, in: Circle())
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch model.contextHandoffState {
        case .idle:
            EmptyView()
        case .preparing:
            VStack(spacing: 13) {
                ProgressView()
                    .controlSize(.regular)
                Text("Preparing a private-safe preview…")
                    .font(.system(size: 13, weight: .semibold))
                Text("Passage is resolving exact sources on this Mac. Nothing has been copied or sent anywhere.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        case .ready(let prepared), .copying(let prepared, _), .copied(let prepared, _):
            preview(prepared)
        case .failed(_, let message):
            statusView(
                title: "Handoff couldn't be prepared",
                message: message,
                symbol: "exclamationmark.triangle",
                actionTitle: "Try Again",
                action: model.retryContextHandoff
            )
        case .invalidated(_, let reason):
            statusView(
                title: "Preview is out of date",
                message: reason.message,
                symbol: "arrow.clockwise",
                actionTitle: "Prepare Again",
                action: model.retryContextHandoff
            )
        }
    }

    private func preview(_ prepared: PreparedContextHandoff) -> some View {
        VStack(spacing: 12) {
            truthStrip(prepared)
                .padding(.horizontal, 20)

            if prepared.draft.containsPrivateHistory {
                Label(
                    "Private-session evidence stays inside Passage and is omitted from handoffs.",
                    systemImage: "lock.fill"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PassagePalette.violet)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if prepared.canCopy {
                Picker("Format", selection: $format) {
                    ForEach(ContextHandoffExportFormat.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                ScrollView {
                    Text(prepared.artifact(for: format))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5))
                }
                .padding(.horizontal, 20)

                DisclosureGroup("Exact sources (\(prepared.payload.sources.count))") {
                    VStack(spacing: 7) {
                        ForEach(prepared.payload.sources) { source in
                            HStack(spacing: 9) {
                                PassageApplicationIcon(
                                    bundleIdentifier: source.bundleIdentifier,
                                    size: 18
                                )
                                Text(source.applicationName)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(source.capturedAt, format: .dateTime.hour().minute())
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 20)
            } else {
                ContentUnavailableView {
                    Label("Nothing safe to hand off", systemImage: "lock.shield")
                } description: {
                    Text("This selection has no ordinary, retained sources. Screenshots and private-session history remain on this Mac.")
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func truthStrip(_ prepared: PreparedContextHandoff) -> some View {
        HStack(spacing: 10) {
            Label(
                "\(prepared.payload.sources.count) source\(prepared.payload.sources.count == 1 ? "" : "s")",
                systemImage: "checkmark.seal"
            )
            Divider().frame(height: 14)
            Text(byteCount(prepared.utf8ByteCount(for: format)))
            Divider().frame(height: 14)
            Label("Images stay on this Mac", systemImage: "macbook.and.iphone")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(prepared.payload.sources.count) exact sources, \(byteCount(prepared.utf8ByteCount(for: format))), screenshots stay on this Mac"
        )
    }

    private func statusView(
        title: String,
        message: String,
        symbol: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(PassagePalette.violet)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(PassagePalette.accent)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Copying puts this exact text on the macOS clipboard. Other apps may read it until it is replaced.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)

            switch model.contextHandoffState {
            case .copying:
                ProgressView()
                    .controlSize(.small)
                Button("Copying…") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            case .copied(let prepared, let copiedFormat):
                Label("Copied \(copiedFormat.label)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PassagePalette.mint)
                Button("Done") { close() }
                    .buttonStyle(.borderedProminent)
                    .tint(PassagePalette.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Closes the handoff for \(prepared.draft.title)")
            case .ready(let prepared):
                Button("Cancel") { close() }
                    .buttonStyle(.bordered)
                Button("Copy \(format.label)") {
                    model.copyContextHandoff(format: format)
                }
                .buttonStyle(.borderedProminent)
                .tint(PassagePalette.accent)
                .disabled(!prepared.canCopy)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Writes the previewed text to the macOS clipboard after recording an Access History receipt")
            default:
                Button("Cancel") { close() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func close() {
        model.dismissContextHandoff()
        dismiss()
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
