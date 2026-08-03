@testable import PassageUI
import Testing

@Suite("Memory Lens presentation")
struct MemoryLensPresentationTests {
    @Test("A selected area takes precedence over search words and empty text")
    func memoryLensTakesQueryPresentationPrecedence() {
        #expect(RecallQueryKind.resolve(
            queryText: "   \n",
            hasMemoryLens: true
        ) == .memoryLens)
        #expect(RecallQueryKind.resolve(
            queryText: "quarterly plan",
            hasMemoryLens: true
        ) == .memoryLens)
        #expect(RecallQueryKind.resolve(
            queryText: "quarterly plan",
            hasMemoryLens: false
        ) == .text)
        #expect(RecallQueryKind.resolve(
            queryText: "",
            hasMemoryLens: false
        ) == .none)
    }

    @Test("Selected-area match copy describes local appearance, never identity")
    func selectedAreaMatchReasonIsTruthful() {
        let reason = RecallMatchReason.reason(
            hasVisualEvidence: true,
            hasRegionEvidence: false,
            isVisualOnly: true,
            hasMemoryLensSelection: true
        )

        #expect(reason == .selectedAreaAppearance)
        #expect(reason.label == "Looks like selected area")
        #expect(reason.systemImage == "viewfinder")
        #expect(reason.explanation.contains("appearance on this Mac"))
        #expect(reason.explanation.contains("did not identify an object or person"))
        #expect(reason.usesImageAppearance)
        #expect(!reason.usesPersonDetail)
    }

    @Test("Copied evidence carries the same non-identification boundary")
    func copiedEvidenceIsTruthful() throws {
        let detail = try #require(
            RecallMatchReason.selectedAreaAppearance.copiedEvidenceDetail
        )
        #expect(detail.contains("appearance was compared on this Mac"))
        #expect(detail.contains("did not identify an object or person"))
        #expect(!detail.localizedCaseInsensitiveContains("recognized the object"))
        #expect(!detail.localizedCaseInsensitiveContains("recognized the person"))
    }

    @Test("Memory Lens result heading and footer never imply a text match")
    func resultChromeIsVisualAndLocal() {
        #expect(MemoryLensPresentation.heading(resultCount: 12)
            == "Looks like selected area · 12 shown")

        let footer = RecallRankingExplanation.text(
            mode: .bestMatches,
            isRefining: true,
            hasVisualEvidence: true,
            hasMemoryLensSelection: true
        )
        #expect(footer == MemoryLensPresentation.rankingFooter)
        #expect(footer.contains("appearance similarity"))
        #expect(footer.contains("on this Mac"))
        #expect(!footer.localizedCaseInsensitiveContains("saved text"))
    }

    @Test("Empty Memory Lens copy responds to filters without suggesting words")
    func emptyResultsCopyIsVisual() {
        let unfiltered = MemoryLensPresentation.emptyMessage(hasFilters: false)
        let filtered = MemoryLensPresentation.emptyMessage(hasFilters: true)

        #expect(MemoryLensPresentation.emptyTitle == "No similar moments found")
        #expect(unfiltered.contains("selected area"))
        #expect(unfiltered.contains("larger or more distinctive area"))
        #expect(!unfiltered.localizedCaseInsensitiveContains("fewer words"))
        #expect(filtered.contains("in this scope"))
        #expect(filtered.contains("time, app, or website filter"))
        #expect(filtered.contains("choose another area"))
    }

    @Test("The removable crop chip names what changes and what remains")
    func scopeChipCopyPreservesMetadataFilters() {
        #expect(MemoryLensPresentation.scopeLabel == "Looks like this")
        #expect(MemoryLensPresentation.scopeRemovalLabel.contains("Remove"))
        #expect(MemoryLensPresentation.scopeRemovalHelp.contains("keeping"))
        #expect(MemoryLensPresentation.scopeRemovalHelp.contains("time"))
        #expect(MemoryLensPresentation.scopeRemovalHelp.contains("app"))
        #expect(MemoryLensPresentation.scopeRemovalHelp.contains("website"))
    }

    @Test("Loading copy discloses local saved-image comparison")
    func loadingCopyIsTruthful() {
        #expect(MemoryLensPresentation.loadingMessage.contains("saved images"))
        #expect(MemoryLensPresentation.loadingMessage.contains("on this Mac"))
        #expect(MemoryLensPresentation.loadingHeading.contains("selected area"))
        #expect(MemoryLensPresentation.loadingAccessibilityLabel.contains("on this Mac"))
    }

    @Test("Stale rows stay hidden until selected-area comparison publishes")
    func staleRowsAreNeverPresentedAsLensMatches() {
        #expect(MemoryLensPresentation.hidesStaleResults(
            queryKind: .memoryLens,
            resultsAreStale: true
        ))
        #expect(!MemoryLensPresentation.hidesStaleResults(
            queryKind: .memoryLens,
            resultsAreStale: false
        ))
        #expect(!MemoryLensPresentation.hidesStaleResults(
            queryKind: .text,
            resultsAreStale: true
        ))
    }
}
