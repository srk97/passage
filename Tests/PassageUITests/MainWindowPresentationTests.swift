@testable import PassageUI
import PassageCore
import PassageVisualSearch
import CoreGraphics
import Foundation
import Testing

@Suite("Main window presentation")
struct MainWindowPresentationTests {
    @Test("Sealed history outranks every workspace and the first-memory coach")
    func sealedHistoryHasPresentationPrecedence() {
        for section in MainWindowSection.allCases {
            #expect(
                MainWindowDetailRoute.resolve(
                    section: section,
                    historyIsSealed: true,
                    presentsFirstMemoryJourney: true
                ) == .historySealed
            )
        }
    }

    @Test("Fresh unlocked history keeps the first-memory experience")
    func freshUnlockedHistoryKeepsFirstMemoryCoach() {
        #expect(
            MainWindowDetailRoute.resolve(
                section: .everything,
                historyIsSealed: false,
                presentsFirstMemoryJourney: true
            ) == .firstMemoryJourney
        )
    }

    @Test("First-memory proof copy distinguishes saved, searching, and failed")
    func firstMemoryProofPresentationIsTruthful() throws {
        let candidate = FirstMemoryRecallCandidate(
            frameID: FrameID(rawValue: "first-proof"),
            query: "Launch checklist",
            applicationName: "Notes",
            source: .visibleText
        )
        let ready = try #require(
            FirstMemoryRecallBannerPresentation(state: .recallReady(candidate))
        )
        let searching = try #require(
            FirstMemoryRecallBannerPresentation(state: .recallSearching(candidate))
        )
        let failed = try #require(
            FirstMemoryRecallBannerPresentation(
                state: .recallFailed(candidate, "The proof search was interrupted.")
            )
        )

        #expect(ready.phase == .ready)
        #expect(ready.title.contains("Prove"))
        #expect(ready.message.contains("exact saved moment"))
        #expect(ready.query == candidate.query)
        #expect(ready.applicationName == candidate.applicationName)
        #expect(ready.sourceLabel == "visible text")
        #expect(ready.localityMessage.contains("on this Mac"))
        #expect(searching.phase == .searching)
        #expect(searching.message.contains("on this Mac"))
        #expect(failed.phase == .failed)
        #expect(failed.message.contains("interrupted"))
    }

    @Test("First-memory Recall proof hides preselected content before verification")
    func firstMemoryProofHidesMomentUntilVerified() throws {
        let candidate = FirstMemoryRecallCandidate(
            frameID: FrameID(rawValue: "hidden-before-proof"),
            query: "Launch checklist",
            applicationName: "Notes",
            source: .visibleText
        )
        let states: [FirstMemoryActivationState] = [
            .recallReady(candidate),
            .recallSearching(candidate),
            .recallFailed(candidate, "Search was interrupted."),
        ]

        for state in states {
            let route = FirstMemoryProofDetailRoute.resolve(
                state: state,
                selectedHitID: candidate.frameID,
                selectedFrameID: candidate.frameID
            )

            #expect(!route.revealsMoment)
            let presentation: FirstMemoryRecallBannerPresentation
            switch route {
            case .recallProof(let value):
                presentation = value
            default:
                Issue.record("Expected a sealed Recall-proof placeholder")
                continue
            }
            #expect(presentation.query == candidate.query)
            #expect(presentation.applicationName == candidate.applicationName)
            #expect(presentation.sourceLabel == "visible text")
            #expect(presentation.localityMessage.contains("on this Mac"))
        }
    }

    @Test("Verified first-memory proof reveals only its exact loaded selection")
    func verifiedFirstMemoryProofRequiresExactSelection() {
        let verifiedID = FrameID(rawValue: "verified-proof")
        let exact = FirstMemoryProofDetailRoute.resolve(
            state: .verified(verifiedID),
            selectedHitID: verifiedID,
            selectedFrameID: verifiedID
        )

        #expect(exact == .verifiedMoment(verifiedID))
        #expect(exact.revealsMoment)
    }

    @Test("Verified proof keeps missing and mismatched selections sealed")
    func verifiedFirstMemoryProofRejectsMissingOrWrongSelection() {
        let verifiedID = FrameID(rawValue: "verified-proof")
        let wrongID = FrameID(rawValue: "another-moment")
        let selections: [(FrameID?, FrameID?)] = [
            (nil, nil),
            (verifiedID, nil),
            (wrongID, verifiedID),
            (verifiedID, wrongID),
            (wrongID, wrongID),
        ]

        for (selectedHitID, selectedFrameID) in selections {
            let route = FirstMemoryProofDetailRoute.resolve(
                state: .verified(verifiedID),
                selectedHitID: selectedHitID,
                selectedFrameID: selectedFrameID
            )

            #expect(route == .awaitingVerifiedMoment(verifiedID))
            #expect(!route.revealsMoment)
        }
    }

    @Test("Established unlocked history returns to the normal workspace")
    func establishedUnlockedHistoryKeepsNormalWorkspace() {
        #expect(
            MainWindowDetailRoute.resolve(
                section: .everything,
                historyIsSealed: false,
                presentsFirstMemoryJourney: false
            ) == .everything
        )
        #expect(
            MainWindowDetailRoute.resolve(
                section: .timeline,
                historyIsSealed: false,
                presentsFirstMemoryJourney: true
            ) == .timeline
        )
    }

    @Test("First-memory journey keeps capture, recall, and success actions explicit")
    func firstMemoryJourneyActions() {
        let candidate = FirstMemoryRecallCandidate(
            frameID: FrameID(rawValue: "journey-proof"),
            query: "launch checklist",
            applicationName: "Notes",
            source: .visibleText
        )

        let paused = FirstMemoryCoachPresentation(state: .paused)
        let ready = FirstMemoryCoachPresentation(state: .recallReady(candidate))
        let searching = FirstMemoryCoachPresentation(state: .recallSearching(candidate))
        let verified = FirstMemoryCoachPresentation(state: .verified(candidate.frameID))

        #expect(paused.actionTitle == "Create my first memory")
        #expect(paused.message.contains("tuck itself away"))
        #expect(ready.actionTitle == "Find this memory")
        #expect(ready.canSkip)
        #expect(searching.showsProgress)
        #expect(searching.canSkip)
        #expect(verified.actionTitle == "Enter Passage")
        #expect(verified.message.contains("source attached"))
        #expect(!verified.canSkip)
    }

    @Test("Sealed copy explains automatic recovery without implying data loss")
    func sealedCopyIsTruthful() {
        let presentation = HistorySealedPresentation.current

        #expect(presentation.title == "History is sealed")
        #expect(presentation.message.contains("keeping them sealed"))
        #expect(presentation.message.contains("try again after login"))
        #expect(presentation.message.contains("restart your Mac"))
        #expect(presentation.status.contains("protected data"))
        #expect(presentation.assurance.contains("unchanged"))
    }

    @Test("Empty website presentation is concise and offers one truthful recovery")
    func emptyWebsitePresentationIsTruthful() {
        let noBrowserMoments = WebsiteFacetEmptyPresentation.make(
            availability: .available(count: 0),
            appContextGranted: false,
            bestMatchesUseSavedTextScope: false,
            hasFilters: false,
            hasFacetError: false
        )
        #expect(noBrowserMoments.title == "No websites in this scope")
        #expect(noBrowserMoments.message == "No browser moments match the current scope.")
        #expect(noBrowserMoments.recoveryAction == nil)

        let filteredEmpty = WebsiteFacetEmptyPresentation.make(
            availability: .available(count: 0),
            appContextGranted: true,
            bestMatchesUseSavedTextScope: true,
            hasFilters: true,
            hasFacetError: false
        )
        #expect(filteredEmpty.message.contains("appearance-only matches"))
        #expect(filteredEmpty.recoveryAction == .clearFilters)

        let appContextPrompt = WebsiteFacetEmptyPresentation.make(
            availability: .available(count: 3),
            appContextGranted: false,
            bestMatchesUseSavedTextScope: false,
            hasFilters: false,
            hasFacetError: false
        )
        #expect(appContextPrompt.title == "Website names aren’t available")
        #expect(appContextPrompt.message.contains("future saved moments"))
        #expect(appContextPrompt.recoveryAction == .enableAppContext)

        let failed = WebsiteFacetEmptyPresentation.make(
            availability: .error,
            appContextGranted: true,
            bestMatchesUseSavedTextScope: false,
            hasFilters: false,
            hasFacetError: true
        )
        #expect(failed.title == "Websites unavailable")
        #expect(failed.recoveryAction == .retry)
    }

    @Test("Website chip exposes count, scope, permission, failure, and selection")
    func websiteFilterChipPresentationIsTruthful() {
        let counted = WebsiteFilterChipPresentation.make(
            selectedDomains: [],
            availableDomainCount: 12,
            availability: .available(count: 20),
            appContextGranted: true,
            facetsAreLoading: false,
            hasFacetError: false
        )
        #expect(counted.title == "Websites · 12")
        #expect(counted.accessibilityLabel.contains("12 websites available"))

        let none = WebsiteFilterChipPresentation.make(
            selectedDomains: [],
            availableDomainCount: 0,
            availability: .available(count: 0),
            appContextGranted: true,
            facetsAreLoading: false,
            hasFacetError: false
        )
        #expect(none.title == "No websites in scope")

        let permission = WebsiteFilterChipPresentation.make(
            selectedDomains: [],
            availableDomainCount: 0,
            availability: .available(count: 4),
            appContextGranted: false,
            facetsAreLoading: false,
            hasFacetError: false
        )
        #expect(permission.title == "App Context off")

        let failed = WebsiteFilterChipPresentation.make(
            selectedDomains: [],
            availableDomainCount: 0,
            availability: .error,
            appContextGranted: true,
            facetsAreLoading: false,
            hasFacetError: true
        )
        #expect(failed.title == "Websites unavailable")

        let selected = WebsiteFilterChipPresentation.make(
            selectedDomains: ["example.com"],
            availableDomainCount: 0,
            availability: .error,
            appContextGranted: false,
            facetsAreLoading: false,
            hasFacetError: true
        )
        #expect(selected.title == "example.com")
        #expect(selected.accessibilityLabel.contains("selected"))
    }

    @Test("Inspector summaries stay compact without hiding exact evidence")
    func inspectorEvidencePresentationIsCalmAndTruthful() throws {
        let sourceURL = try #require(URL(
            string: "https://example.com/a/very/long/research/path?private=query"
        ))
        let source = try #require(InspectorSourcePresentation.make(url: sourceURL))

        #expect(source.displayText == "example.com/a/very/long/research/path")
        #expect(source.fullText == sourceURL.absoluteString)
        #expect(InspectorEvidencePresentation.appProvidedTextSummary(
            count: 1,
            isTruncated: false
        ) == "1 visible label")
        #expect(InspectorEvidencePresentation.appProvidedTextSummary(
            count: 20,
            isTruncated: true
        ) == "20+ visible labels")

        let noisyOCR = "é--> 0 Q kNkin8for t?Toma5"
        let summary = InspectorEvidencePresentation.ocrSummary(
            text: noisyOCR,
            isImproving: false
        )
        #expect(summary == "Searchable text available")
        #expect(!summary.contains(noisyOCR))
        #expect(InspectorEvidencePresentation.ocrSummary(
            text: "   ",
            isImproving: false
        ) == "No readable text")
        #expect(InspectorEvidencePresentation.ocrSummary(
            text: noisyOCR,
            isImproving: true
        ) == "Rereading saved image…")
    }

    @Test("Person-detail evidence is local, ephemeral, and never identity copy")
    func personDetailPresentationIsTruthful() {
        let visualOnly = RecallMatchReason.reason(
            hasVisualEvidence: true,
            hasRegionEvidence: true,
            isVisualOnly: true
        )
        let combined = RecallMatchReason.reason(
            hasVisualEvidence: true,
            hasRegionEvidence: true,
            isVisualOnly: false
        )

        #expect(visualOnly.label == "Person detail")
        #expect(combined.label == "Saved text + person detail")
        #expect(visualOnly.explanation.contains("did not identify"))
        #expect(visualOnly.usesPersonDetail)
    }

    @Test("Progressive ranking copy acknowledges already-published image matches")
    func progressiveRankingCopyIsTruthful() {
        let initial = RecallRankingExplanation.text(
            mode: .bestMatches,
            isRefining: true,
            hasVisualEvidence: false
        )
        let progressive = RecallRankingExplanation.text(
            mode: .bestMatches,
            isRefining: true,
            hasVisualEvidence: true
        )

        #expect(initial.contains("Saved-text matches shown first"))
        #expect(progressive.contains("image matches shown"))
        #expect(progressive.contains("finer image detail"))
        #expect(!progressive.contains("shown first"))
    }

    @Test("Recall empty copy keeps both split-view panes in the same state")
    func recallEmptyPresentationIsContextual() {
        let fresh = RecallEmptyPresentation.make(
            queryKind: .none,
            hasFilters: false,
            searchMode: .bestMatches,
            visualState: .ready,
            coverage: nil,
            totalMomentCount: 0,
            searchError: nil
        )
        let filtered = RecallEmptyPresentation.make(
            queryKind: .none,
            hasFilters: true,
            searchMode: .bestMatches,
            visualState: .ready,
            coverage: nil,
            totalMomentCount: 42,
            searchError: nil
        )
        let searched = RecallEmptyPresentation.make(
            queryKind: .text,
            hasFilters: false,
            searchMode: .bestMatches,
            visualState: .ready,
            coverage: nil,
            totalMomentCount: 42,
            searchError: nil
        )
        let failed = RecallEmptyPresentation.make(
            queryKind: .text,
            hasFilters: false,
            searchMode: .bestMatches,
            visualState: .ready,
            coverage: nil,
            totalMomentCount: 42,
            searchError: "The encrypted index is unavailable."
        )

        #expect(fresh.title == "No memories yet")
        #expect(fresh.message.contains("Start Remembering"))
        #expect(filtered.title == "No memories in this scope")
        #expect(filtered.message.contains("Change or clear"))
        #expect(searched.title == "No matches")
        #expect(searched.message.contains("visual description"))
        #expect(failed.title == "Recall couldn’t finish")
        #expect(failed.message == "The encrypted index is unavailable.")
    }

    @Test("Person-detail overlay flips only the vertical image origin")
    func personDetailOverlayGeometry() throws {
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.20,
            y: 0.25,
            width: 0.30,
            height: 0.40
        ))
        let frame = VisualRegionOverlayGeometry.frame(
            bounds: bounds,
            container: CGSize(width: 1_000, height: 500)
        )

        #expect(abs(frame.minX - 200) < 0.000_001)
        #expect(abs(frame.minY - 175) < 0.000_001)
        #expect(abs(frame.width - 300) < 0.000_001)
        #expect(abs(frame.height - 200) < 0.000_001)

        let topRight = try #require(NormalizedVisualRegionBounds(
            x: 0.875,
            y: 0.875,
            width: 0.125,
            height: 0.125
        ))
        let edgeFrame = VisualRegionOverlayGeometry.frame(
            bounds: topRight,
            container: CGSize(width: 96, height: 64)
        )
        #expect(edgeFrame == CGRect(x: 84, y: 0, width: 12, height: 8))
    }
}
