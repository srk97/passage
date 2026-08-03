@testable import PassageUI
import PassageCore
import PassageStore
import PassageVisualModel
import PassageVisualSearch
import CoreGraphics
import Foundation
import Testing

@Suite("Recall async publication", .serialized)
@MainActor
struct RecallAsyncModelTests {
    @Test("First-memory proof verifies only when Recall publishes the exact frame")
    func firstMemoryProofRequiresExactPublishedFrame() async {
        let frame = Self.frame(1, text: "Launch checklist tomorrow")
        let repository = RecallModelFakeRepository(frames: [frame])
        let suiteName = "RecallAsyncModelTests.first-proof.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activationStore = FirstMemoryActivationStore(defaults: defaults)
        let model = makeModel(
            repository: repository,
            activationStore: activationStore
        )

        model.consume(.persisted(frame, continuous: true))
        guard case .recallReady(let candidate) = model.firstMemoryActivationState else {
            Issue.record("Expected a saved frame to await Recall proof")
            return
        }
        #expect(candidate.frameID == frame.id)

        model.searchFirstMemorySuggestion()
        let verified = await waitUntil {
            model.firstMemoryActivationState == .verified(frame.id)
        }

        #expect(verified)
        #expect(model.results.contains { $0.id == frame.id })
        #expect(model.selectedHit?.id == frame.id)
        #expect(activationStore.load() == .verified(frame.id))

        #expect(model.finishFirstMemoryActivationJourney())
        #expect(model.firstMemoryActivationState == .complete)
        #expect(model.selectedHit?.id == frame.id)
        #expect(activationStore.load() == .verified(frame.id))
        #expect(!model.finishFirstMemoryActivationJourney())
    }

    @Test("Typing an arbitrary query never dismisses the first-memory proof")
    func arbitraryTypingDoesNotCompleteFirstMemoryProof() async {
        let frame = Self.frame(1, text: "Launch checklist tomorrow")
        let repository = RecallModelFakeRepository(frames: [frame])
        let model = makeModel(repository: repository)
        model.consume(.persisted(frame, continuous: true))
        let awaitingState = model.firstMemoryActivationState

        model.queryText = "something unrelated"
        model.scheduleSearch()
        _ = await waitUntil { !model.recallIsLoading }

        #expect(model.firstMemoryActivationState == awaitingState)
        #expect(model.firstMemoryActivationState != .verified(frame.id))
    }

    @Test("A missing exact frame fails honestly and Retry can later verify it")
    func firstMemoryProofRetryAfterExactMiss() async {
        let frame = Self.frame(1, text: "Launch checklist tomorrow")
        let repository = RecallModelFakeRepository(frames: [])
        let model = makeModel(repository: repository)
        model.consume(.persisted(frame, continuous: true))

        model.searchFirstMemorySuggestion()
        let failed = await waitUntil {
            if case .recallFailed = model.firstMemoryActivationState { return true }
            return false
        }
        #expect(failed)
        #expect(model.results.isEmpty)

        await repository.add(frame)
        model.retryFirstMemoryActivation()
        let verified = await waitUntil {
            model.firstMemoryActivationState == .verified(frame.id)
        }
        #expect(verified)
    }

    @Test("Replacing an in-flight proof search reports interruption and remains resumable")
    func firstMemoryProofCancellationIsVisible() async {
        let frame = Self.frame(1, text: "Launch checklist tomorrow")
        let repository = RecallModelFakeRepository(frames: [frame])
        await repository.suspendRecall(text: "Launch checklist tomorrow")
        let model = makeModel(repository: repository)
        model.consume(.persisted(frame, continuous: true))

        model.searchFirstMemorySuggestion()
        let proofStarted = await waitUntil {
            await repository.hasRecallWaiter(text: "Launch checklist tomorrow")
        }
        #expect(proofStarted)

        model.queryText = "different words"
        model.scheduleSearch()
        guard case .recallFailed(let candidate, let message) = model.firstMemoryActivationState else {
            Issue.record("Expected interruption to remain visible and resumable")
            await repository.releaseRecall(text: "Launch checklist tomorrow")
            return
        }
        #expect(candidate.frameID == frame.id)
        #expect(message.contains("interrupted"))

        await repository.releaseRecall(text: "Launch checklist tomorrow")
        _ = await waitUntil { !model.recallIsLoading }
        if case .recallFailed(let retained, _) = model.firstMemoryActivationState {
            #expect(retained.frameID == frame.id)
        } else {
            Issue.record("A canceled read must not publish a false verification")
        }
    }

    @Test("Skip is explicit, durable, and leaves saved history intact")
    func firstMemoryProofSkipIsNonDestructive() async {
        let frame = Self.frame(1, text: "Launch checklist tomorrow")
        let repository = RecallModelFakeRepository(frames: [frame])
        let suiteName = "RecallAsyncModelTests.first-skip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activationStore = FirstMemoryActivationStore(defaults: defaults)
        let model = makeModel(
            repository: repository,
            activationStore: activationStore
        )
        model.consume(.persisted(frame, continuous: true))

        model.skipFirstMemoryActivation()

        #expect(model.firstMemoryActivationState == .skipped)
        #expect(activationStore.load() == .skipped)
        #expect(await repository.frame(id: frame.id)?.id == frame.id)
    }

    @Test("A debounced scope visibly marks retained rows stale")
    func debouncedScopeIsExplicitlyStale() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "alpha notes"),
            Self.frame(2, text: "beta notes"),
        ])
        let model = makeModel(repository: repository)
        await model.refresh()

        model.queryText = "beta"
        model.scheduleSearch()

        #expect(model.recallIsLoading)
        #expect(model.recallResultsAreStale)
        #expect(model.searchError == nil)
        #expect(model.results.count == 2)

        let completed = await waitUntil {
            !model.recallIsLoading && !model.recallResultsAreStale
        }
        #expect(completed)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f002")])
    }

    @Test("A fresh successful Recall selects its first visible memory")
    func freshRecallSelectsFirstResult() async {
        let older = Self.frame(1, text: "older note")
        let newer = Self.frame(2, text: "newer note")
        let model = makeModel(
            repository: RecallModelFakeRepository(frames: [older, newer])
        )

        await model.refresh()

        #expect(model.results.map(\.id) == [newer.id, older.id])
        #expect(model.selectedHit?.id == newer.id)
        #expect(await waitUntil { model.selectedFrame?.id == newer.id })
    }

    @Test("A successful Recall refresh preserves the selected memory by ID")
    func recallRefreshPreservesSelectedResult() async {
        let older = Self.frame(1, text: "older draft")
        let newer = Self.frame(2, text: "newer draft")
        let repository = RecallModelFakeRepository(frames: [older, newer])
        let model = makeModel(repository: repository)
        await model.refresh()

        #expect(model.results.contains { $0.id == older.id })
        model.select(Self.hit(older))
        #expect(await waitUntil { model.selectedFrame?.id == older.id })

        var corrected = older
        corrected.ocrText = "older corrected draft"
        await repository.add(corrected)
        await model.refresh()

        #expect(model.selectedHit?.id == older.id)
        #expect(model.selectedHit?.snippet == "older corrected draft")
    }

    @Test("Recall replaces a selection that leaves the published scope")
    func recallReplacesSelectionOutsideNewScope() async {
        let alpha = Self.frame(1, text: "alpha notes")
        let beta = Self.frame(2, text: "beta notes")
        let model = makeModel(
            repository: RecallModelFakeRepository(frames: [alpha, beta])
        )
        await model.refresh()

        #expect(model.results.contains { $0.id == alpha.id })
        model.select(Self.hit(alpha))
        model.queryText = "beta"
        await model.refresh()

        #expect(model.results.map(\.id) == [beta.id])
        #expect(model.selectedHit?.id == beta.id)
    }

    @Test("A successful empty Recall clears selection and a later result restores it")
    func emptyThenNonemptyRecallRestoresSelection() async {
        let alpha = Self.frame(1, text: "alpha notes")
        let model = makeModel(
            repository: RecallModelFakeRepository(frames: [alpha])
        )
        await model.refresh()
        #expect(model.selectedHit?.id == alpha.id)

        model.queryText = "nothing matches this"
        await model.refresh()
        #expect(model.results.isEmpty)
        #expect(model.selectedHit == nil)

        model.queryText = "alpha"
        await model.refresh()
        #expect(model.results.map(\.id) == [alpha.id])
        #expect(model.selectedHit?.id == alpha.id)
    }

    @Test("Visual refinement can reorder Recall without moving its selection")
    func visualRefinementPreservesSelectedResult() async {
        let visuallyPreferred = Self.frame(1, text: "person with glasses")
        let initiallyFirst = Self.frame(2, text: "person with glasses")
        let repository = RecallModelFakeRepository(
            frames: [visuallyPreferred, initiallyFirst]
        )
        let visualRuntime = RecallVisualRuntimeStub(matches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(visuallyPreferred)),
        ])
        await visualRuntime.suspendSearches()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person with glasses"

        await model.refresh()
        #expect(model.results.map(\.id) == [initiallyFirst.id, visuallyPreferred.id])
        #expect(model.selectedHit?.id == initiallyFirst.id)

        await visualRuntime.releaseSearches()
        #expect(await waitUntil {
            !model.visualSearchIsRefining
                && model.visualRecallEvidenceByFrameID[visuallyPreferred.id] != nil
        })
        #expect(model.results.map(\.id) == [visuallyPreferred.id, initiallyFirst.id])
        #expect(model.selectedHit?.id == initiallyFirst.id)
    }

    @Test("A newer refresh owns publication even when an old read finishes last")
    func newerRefreshWins() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "alpha notes"),
            Self.frame(2, text: "beta notes"),
        ])
        await repository.suspendRecall(text: "alpha")
        let model = makeModel(repository: repository)

        model.queryText = "alpha"
        let slowRefresh = Task { await model.refresh() }
        let slowReadStarted = await waitUntil {
            await repository.hasRecallWaiter(text: "alpha")
        }
        #expect(slowReadStarted)

        model.queryText = "beta"
        await model.refresh()
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f002")])

        await repository.releaseRecall(text: "alpha")
        await slowRefresh.value
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f002")])
        #expect(!model.recallIsLoading)
        #expect(!model.recallResultsAreStale)
    }

    @Test("The first page publishes while full-scope facets are still loading")
    func firstPagePublishesBeforeFacets() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "alpha notes"),
        ])
        await repository.suspendFacets(text: "alpha")
        let model = makeModel(repository: repository)
        model.queryText = "alpha"

        let refresh = Task { await model.refresh() }
        let facetsStarted = await waitUntil {
            await repository.hasFacetWaiter(text: "alpha")
        }

        #expect(facetsStarted)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f001")])
        #expect(!model.recallIsLoading)
        #expect(!model.recallResultsAreStale)
        #expect(model.recallFacetsAreLoading)
        #expect(model.recallFacets.applications.isEmpty)
        #expect(model.recallBrowserMomentAvailability == .loading)

        await repository.releaseFacets(text: "alpha")
        await refresh.value
        let facetsPublished = await waitUntil {
            !model.recallFacetsAreLoading
                && model.recallFacets.applications.map(\.bundleIdentifier) == ["com.apple.Notes"]
        }
        #expect(facetsPublished)
        #expect(model.recallBrowserMomentAvailability == .available(count: 0))
    }

    @Test("Website repair refreshes current facets without rerunning Recall")
    func websiteRepairRefreshesOnlyFacets() async {
        var browser = Self.frame(
            1,
            text: "browser page",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let repository = RecallModelFakeRepository(frames: [browser])
        let model = makeModel(repository: repository)
        await model.refresh()
        let initialFacetsPublished = await waitUntil {
            !model.recallFacetsAreLoading
        }
        #expect(initialFacetsPublished)
        #expect(model.recallFacets.domains.isEmpty)
        #expect(model.recallBrowserMomentAvailability == .available(count: 1))
        let recallCount = await repository.recallCount(text: "")

        browser.context.domain = "example.com"
        await repository.add(browser)
        model.refreshRecallFacetsAfterWebsiteRepair(
            repairedCount: 1,
            repository: repository
        )

        let repairedFacetsPublished = await waitUntil {
            !model.recallFacetsAreLoading
                && model.recallFacets.domains.map(\.domain) == ["example.com"]
        }
        #expect(repairedFacetsPublished)
        #expect(await repository.recallCount(text: "") == recallCount)
    }

    @Test("Website repair cannot publish across a locked or stale generation")
    func websiteRepairPublicationBoundary() {
        let current = UUID()
        #expect(WebsiteFacetRepairPublication.canPublish(
            repairedCount: 1,
            expectedGeneration: current,
            currentGeneration: current,
            sessionIsLocked: false,
            repositoryAvailable: true
        ))
        #expect(!WebsiteFacetRepairPublication.canPublish(
            repairedCount: 0,
            expectedGeneration: current,
            currentGeneration: current,
            sessionIsLocked: false,
            repositoryAvailable: true
        ))
        #expect(!WebsiteFacetRepairPublication.canPublish(
            repairedCount: 1,
            expectedGeneration: UUID(),
            currentGeneration: current,
            sessionIsLocked: false,
            repositoryAvailable: true
        ))
        #expect(!WebsiteFacetRepairPublication.canPublish(
            repairedCount: 1,
            expectedGeneration: current,
            currentGeneration: current,
            sessionIsLocked: true,
            repositoryAvailable: true
        ))
        #expect(!WebsiteFacetRepairPublication.canPublish(
            repairedCount: 1,
            expectedGeneration: current,
            currentGeneration: current,
            sessionIsLocked: false,
            repositoryAvailable: false
        ))
    }

    @Test("A cancelled facet read cannot overwrite a newer scope")
    func staleFacetsCannotPublish() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(
                1,
                text: "alpha notes",
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes"
            ),
            Self.frame(
                2,
                text: "beta page",
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            ),
        ])
        await repository.suspendFacets(text: "alpha")
        let model = makeModel(repository: repository)

        model.queryText = "alpha"
        await model.refresh()
        let oldFacetsStarted = await waitUntil {
            await repository.hasFacetWaiter(text: "alpha")
        }
        #expect(oldFacetsStarted)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f001")])

        model.queryText = "beta"
        await model.refresh()
        let newFacetsPublished = await waitUntil {
            !model.recallFacetsAreLoading
                && model.recallFacets.applications.map(\.bundleIdentifier) == ["com.apple.Safari"]
        }
        #expect(newFacetsPublished)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f002")])

        await repository.releaseFacets(text: "alpha")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.recallFacets.applications.map(\.bundleIdentifier) == ["com.apple.Safari"])
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f002")])
        #expect(!model.recallFacetsAreLoading)
    }

    @Test("Facet failures stay distinct from an empty scope and can be retried")
    func facetFailureIsRetryable() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "alpha notes"),
        ])
        await repository.setFacetFailure(true)
        let model = makeModel(repository: repository)
        model.queryText = "alpha"

        await model.refresh()
        let failurePublished = await waitUntil {
            !model.recallFacetsAreLoading && model.recallFacetsError != nil
        }

        #expect(failurePublished)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f001")])
        #expect(model.recallFacets.applications.isEmpty)
        #expect(model.recallBrowserMomentAvailability == .error)

        await repository.setFacetFailure(false)
        model.retryRecallFacets()
        #expect(model.recallFacetsAreLoading)
        #expect(model.recallFacetsError == nil)

        let retryPublished = await waitUntil {
            !model.recallFacetsAreLoading
                && model.recallFacetsError == nil
                && model.recallFacets.applications.map(\.bundleIdentifier)
                    == ["com.apple.Notes"]
        }
        #expect(retryPublished)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "f001")])
        #expect(model.recallBrowserMomentAvailability == .available(count: 0))
    }

    @Test("A late inspector read cannot publish beneath a newer selection")
    func selectionReadIsGuarded() async {
        let first = Self.frame(1, text: "first")
        let second = Self.frame(2, text: "second")
        let repository = RecallModelFakeRepository(frames: [first, second])
        await repository.suspendFrame(id: first.id)
        let model = makeModel(repository: repository)

        model.select(Self.hit(first))
        let firstReadStarted = await waitUntil {
            await repository.hasFrameWaiter(id: first.id)
        }
        #expect(firstReadStarted)

        model.select(Self.hit(second))
        let secondPublished = await waitUntil { model.selectedFrame?.id == second.id }
        #expect(secondPublished)

        await repository.releaseFrame(id: first.id)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.selectedHit?.id == second.id)
        #expect(model.selectedFrame?.id == second.id)
    }

    @Test("Only legacy fast OCR quality triggers an on-demand reread")
    func legacyOCRRefinementGateIsDeterministic() {
        var legacy = Self.frame(1, text: "Me55age5 & Add carhwd5")
        legacy.ocrRegions = (0..<10).map { index in
            OCRRegion(
                text: "line \(index)",
                confidence: index < 4 ? 0.35 : 0.92,
                x: 0.05,
                y: 0.9 - Double(index) * 0.05,
                width: 0.4,
                height: 0.03
            )
        }
        #expect(PassageModel.shouldImproveLegacyOCR(in: legacy))

        var currentAccurate = legacy
        currentAccurate.ocrRegions = currentAccurate.ocrRegions.map { region in
            var region = region
            region.confidence = 0.76
            return region
        }
        #expect(!PassageModel.shouldImproveLegacyOCR(in: currentAccurate))

        var isolatedWeakObservation = currentAccurate
        isolatedWeakObservation.ocrRegions[0].confidence = 0.40
        #expect(!PassageModel.shouldImproveLegacyOCR(in: isolatedWeakObservation))

        var empty = legacy
        empty.ocrText = ""
        #expect(!PassageModel.shouldImproveLegacyOCR(in: empty))
    }

    @Test("A refreshed page replaces stale evidence in the selected row")
    func refreshedPageUpdatesSelectedHit() async throws {
        let original = Self.frame(1, text: "Me55age5 & Add carhwd5")
        let repository = RecallModelFakeRepository(frames: [original])
        let model = makeModel(repository: repository)
        await model.refresh()

        #expect(model.results.count == 1)
        guard let initialHit = model.results.first else { return }
        model.select(initialHit)
        let selected = await waitUntil { model.selectedFrame?.id == original.id }
        #expect(selected)

        var corrected = original
        corrected.ocrText = "Messages and Add canvas"
        await repository.add(corrected)
        await model.refresh()

        #expect(model.selectedHit?.id == original.id)
        #expect(model.selectedHit?.snippet == "Messages and Add canvas")
    }

    @Test("Timeline is a reversible clean day-scope transaction")
    func timelineWorkspaceRestoresEverythingScope() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "alpha notes"),
            Self.frame(2, text: "beta notes"),
        ])
        let model = makeModel(repository: repository)
        let calendar = Calendar.autoupdatingCurrent
        let originalStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let originalEnd = calendar.date(byAdding: .day, value: 2, to: originalStart)!

        model.queryText = "alpha"
        model.setRecallCalendarRange(startingAt: originalStart, through: originalEnd)
        model.toggleRecallApplication("com.apple.Notes")
        model.toggleRecallDomain("example.com")
        let originalScope = model.recallScope
        let originalSettled = await waitUntil { !model.recallIsLoading }
        #expect(originalSettled)

        let firstTimelineDay = calendar.date(byAdding: .day, value: 7, to: originalStart)!
        let enteredDay = model.enterTimelineWorkspace(preferredDay: firstTimelineDay)
        let expectedFirstScope = TimelineWorkspaceScope.dayScope(for: firstTimelineDay)
        #expect(enteredDay == expectedFirstScope.startDate)
        #expect(model.queryText.isEmpty)
        #expect(model.recallScope == expectedFirstScope)
        #expect(model.recallScope.applicationBundleIdentifiers.isEmpty)
        #expect(model.recallScope.domains.isEmpty)

        let ignoredSecondEntry = model.enterTimelineWorkspace(
            preferredDay: calendar.date(byAdding: .day, value: 30, to: originalStart)!
        )
        #expect(ignoredSecondEntry == enteredDay)

        let secondTimelineDay = calendar.date(byAdding: .day, value: 1, to: firstTimelineDay)!
        model.setTimelineWorkspaceDay(secondTimelineDay)
        #expect(model.queryText.isEmpty)
        #expect(model.recallScope == TimelineWorkspaceScope.dayScope(for: secondTimelineDay))

        model.exitTimelineWorkspace()
        #expect(model.queryText == "alpha")
        #expect(model.recallScope == originalScope)

        // Repeated disappearance callbacks must be harmless.
        model.exitTimelineWorkspace()
        #expect(model.queryText == "alpha")
        #expect(model.recallScope == originalScope)
    }

    @Test("A selected search memory is the exact reversible Timeline anchor")
    func selectedSearchMemoryAnchorsTimeline() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let selectedTime = try #require(calendar.date(
            byAdding: .minute,
            value: 9 * 60 + 17,
            to: day
        ))
        let laterTime = try #require(calendar.date(
            byAdding: .minute,
            value: 11 * 60 + 42,
            to: day
        ))

        var selectedFrame = Self.frame(
            id: "selected",
            capturedAt: selectedTime,
            text: "alpha search target",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        selectedFrame.context.domain = "example.com"
        var laterMatch = Self.frame(
            id: "later-match",
            capturedAt: laterTime,
            text: "alpha later match",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        laterMatch.context.domain = "example.com"
        let nearbyContext = Self.frame(
            id: "nearby-context",
            capturedAt: selectedTime.addingTimeInterval(90),
            text: "unfiltered nearby context",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        let repository = RecallModelFakeRepository(frames: [
            selectedFrame,
            laterMatch,
            nearbyContext,
        ])
        let model = makeModel(repository: repository)
        model.queryText = "alpha"
        model.setRecallDay(day)
        model.toggleRecallApplication("com.apple.Safari")
        model.toggleRecallDomain("example.com")
        await model.refresh()

        let originalScope = model.recallScope
        #expect(model.results.map(\.id) == [laterMatch.id, selectedFrame.id])
        let selectedHit = try #require(model.results.first { $0.id == selectedFrame.id })
        model.select(selectedHit)

        let enteredDay = model.enterTimelineWorkspace(preferredDay: selectedHit.capturedAt)
        let dayScope = TimelineWorkspaceScope.dayScope(for: selectedHit.capturedAt)
        #expect(enteredDay == dayScope.startDate)
        #expect(model.selectedHit?.id == selectedFrame.id)
        #expect(model.queryText.isEmpty)
        #expect(model.recallScope == dayScope)
        #expect(model.recallScope.applicationBundleIdentifiers.isEmpty)
        #expect(model.recallScope.domains.isEmpty)

        let timelineLoaded = await waitUntil {
            !model.recallIsLoading && !model.recallResultsAreStale
        }
        #expect(timelineLoaded)
        #expect(model.results.map(\.id) == [laterMatch.id, nearbyContext.id, selectedFrame.id])
        #expect(model.selectedHit?.id == selectedFrame.id)

        model.exitTimelineWorkspace()
        #expect(model.queryText == "alpha")
        #expect(model.recallScope == originalScope)

        let everythingRestored = await waitUntil {
            !model.recallIsLoading && !model.recallResultsAreStale
        }
        #expect(everythingRestored)
        #expect(model.results.map(\.id) == [laterMatch.id, selectedFrame.id])
        #expect(model.selectedHit?.id == selectedFrame.id)
    }

    @Test("Timeline loads through an exact anchor older than its newest page")
    func oldSearchMemoryStillAnchorsTimeline() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let anchorTime = try #require(calendar.date(
            byAdding: .hour,
            value: 2,
            to: day
        ))
        let anchor = Self.frame(
            id: "old-anchor",
            capturedAt: anchorTime,
            text: "anchorphrase",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let nearbyContext = [
            Self.frame(
                id: "context-before-1",
                capturedAt: anchorTime.addingTimeInterval(-30),
                text: "nearby context one"
            ),
            Self.frame(
                id: "context-before-2",
                capturedAt: anchorTime.addingTimeInterval(-90),
                text: "nearby context two"
            ),
        ]
        let laterFrames = (0..<80).map { index in
            Self.frame(
                id: String(format: "later-%03d", index),
                capturedAt: anchorTime.addingTimeInterval(10 * 60 + Double(index * 30)),
                text: "later activity"
            )
        }
        let repository = RecallModelFakeRepository(
            frames: nearbyContext + [anchor] + laterFrames
        )
        let model = makeModel(repository: repository)
        model.queryText = "anchorphrase"
        model.setRecallDay(day)
        await model.refresh()

        let selected = try #require(model.results.first)
        #expect(selected.id == anchor.id)
        model.select(selected)
        _ = model.enterTimelineWorkspace(preferredDay: anchorTime)

        let timelineLoaded = await waitUntil {
            !model.recallIsLoading && !model.recallResultsAreStale
        }
        #expect(timelineLoaded)
        #expect(model.selectedHit?.id == anchor.id)
        #expect(model.results.contains { $0.id == anchor.id })
        #expect(model.results.contains { $0.id == nearbyContext[0].id })
        #expect(model.results.count > 60)
        #expect(model.recallHasMore)
    }

    @Test("Opening a Timeline moment commits its clean day scope to Everything")
    func timelineMomentCommitKeepsDayScope() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "alpha notes"),
        ])
        let model = makeModel(repository: repository)
        model.queryText = "alpha"
        await model.refresh()

        let calendar = Calendar.autoupdatingCurrent
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let committedDay = calendar.date(byAdding: .day, value: 3, to: firstDay)!
        _ = model.enterTimelineWorkspace(preferredDay: firstDay)
        model.setTimelineWorkspaceDay(committedDay)
        let committedScope = TimelineWorkspaceScope.dayScope(for: committedDay)

        model.commitTimelineWorkspaceForOpeningMoment()
        model.exitTimelineWorkspace()

        #expect(model.queryText.isEmpty)
        #expect(model.recallScope == committedScope)
        #expect(model.recallScope.text.isEmpty)
        #expect(model.recallScope.applicationBundleIdentifiers.isEmpty)
        #expect(model.recallScope.domains.isEmpty)
    }

    @Test("A late Timeline day read cannot overwrite a restored Everything query")
    func staleTimelineReadCannotPublishAfterExit() async {
        let alpha = Self.frame(1, text: "alpha notes")
        let beta = Self.frame(2, text: "beta notes")
        let repository = RecallModelFakeRepository(frames: [alpha, beta])
        let model = makeModel(repository: repository)
        model.queryText = "alpha"
        await model.refresh()
        #expect(model.results.map(\.id) == [alpha.id])

        await repository.suspendRecall(text: "")
        _ = model.enterTimelineWorkspace(preferredDay: alpha.capturedAt)
        let timelineReadStarted = await waitUntil {
            await repository.hasRecallWaiter(text: "")
        }
        #expect(timelineReadStarted)

        model.exitTimelineWorkspace()
        let everythingRestored = await waitUntil {
            !model.recallIsLoading && model.results.map(\.id) == [alpha.id]
        }
        #expect(everythingRestored)
        #expect(model.queryText == "alpha")
        #expect(model.recallScope.text == "alpha")

        await repository.releaseRecall(text: "")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.results.map(\.id) == [alpha.id])
        #expect(model.queryText == "alpha")
        #expect(model.recallScope.text == "alpha")
    }

    @Test("Capture refresh merges at the head without resetting the walked cursor")
    func captureRefreshPreservesPaginationAndSelection() async throws {
        let baseFrames = (0..<130).map { Self.frame($0, text: "shared history") }
        let repository = RecallModelFakeRepository(frames: baseFrames)
        let model = makeModel(repository: repository)
        await model.refresh()
        #expect(model.results.count == 60)
        #expect(model.recallHasMore)

        model.loadEarlierRecall()
        let secondPageLoaded = await waitUntil {
            model.results.count == 120 && !model.recallIsLoadingMore
        }
        #expect(secondPageLoaded)

        let firstCapture = Self.frame(1_000, text: "first new capture")
        await repository.add(firstCapture)
        model.consume(.persisted(firstCapture, continuous: true))
        model.skipFirstMemoryActivation()
        let firstMerged = await waitUntil { model.results.count == 121 }
        #expect(firstMerged)

        let olderID = FrameID(rawValue: "f010")
        let olderHit = try #require(model.results.first { $0.id == olderID })
        model.select(olderHit)
        let olderSelected = await waitUntil { model.selectedFrame?.id == olderID }
        #expect(olderSelected)

        let secondCapture = Self.frame(1_001, text: "second new capture")
        await repository.add(secondCapture)
        model.consume(.persisted(secondCapture, continuous: true))
        let secondMerged = await waitUntil {
            model.results.count == 122 && model.results.first?.id == secondCapture.id
        }
        #expect(secondMerged)
        #expect(model.selectedHit?.id == olderID)
        #expect(model.selectedFrame?.id == olderID)
        #expect(model.recallHasMore)

        model.loadEarlierRecall()
        let oldestLoaded = await waitUntil {
            model.results.count == 132 && !model.recallIsLoadingMore
        }
        #expect(oldestLoaded)
        #expect(Set(model.results.map(\.id)).count == 132)
        #expect(!model.recallHasMore)
    }

    @Test("Timeline can progressively fill its complete selected day")
    func timelineLoadsCompleteSelectedDay() async {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let frames = (0..<470).map { index in
            Self.frame(
                id: String(format: "timeline-%04d", index),
                capturedAt: day.addingTimeInterval(Double(index * 5)),
                text: "saved timeline activity"
            )
        }
        let repository = RecallModelFakeRepository(frames: frames)
        let model = makeModel(repository: repository)

        _ = model.enterTimelineWorkspace(preferredDay: day)
        let firstPageLoaded = await waitUntil {
            !model.recallIsLoading
                && !model.recallResultsAreStale
                && model.results.count == 60
                && model.recallHasMore
        }
        #expect(firstPageLoaded)

        model.loadCompleteTimelineDay()
        let completeDayLoaded = await waitUntil {
            !model.recallIsLoadingMore
                && model.results.count == frames.count
                && !model.recallHasMore
        }

        #expect(completeDayLoaded)
        #expect(Set(model.results.map(\.id)).count == frames.count)
        #expect(model.results.first?.id == frames.last?.id)
        #expect(model.results.last?.id == frames.first?.id)
    }

    @Test("A failed deletion clears busy state immediately and reconstructs recall")
    func deletionFailureRecoversRecall() async throws {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "one"),
            Self.frame(2, text: "two"),
        ])
        await repository.setDeleteFailure(true)
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let model = makeModel(repository: repository, mediaStore: fixture.store)
        await model.refresh()

        model.scheduleSearch()
        #expect(model.recallIsLoading)
        #expect(model.recallResultsAreStale)
        model.deleteAllHistory()

        #expect(model.historyDeletionInProgress)
        #expect(!model.recallIsLoading)
        #expect(!model.recallIsLoadingMore)
        #expect(!model.recallResultsAreStale)

        let recovered = await waitUntil { !model.historyDeletionInProgress }
        #expect(recovered)
        #expect(model.historyDeletionError != nil)
        #expect(model.results.count == 2)
        #expect(!model.recallIsLoading)
        #expect(!model.recallResultsAreStale)
    }

    @Test("Newest-page merge is stable and duplicate free")
    func mergePolicyIsStable() {
        let timestamp = Date(timeIntervalSince1970: 20)
        let a = Self.hit(Self.frame(id: "a", capturedAt: timestamp))
        let b = Self.hit(Self.frame(id: "b", capturedAt: timestamp))
        let old = Self.hit(Self.frame(id: "old", capturedAt: .init(timeIntervalSince1970: 10)))

        let merged = PassageModel.mergingNewestRecallPage([a, b], into: [old, a])

        #expect(merged.map(\.id.rawValue) == ["b", "a", "old"])
    }

    @Test("Memory Lens publishes image similarity with blank text and excludes its source")
    func memoryLensPublishesImageSimilarityAndExcludesSource() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let similar = Self.frame(
            id: "lens-similar",
            capturedAt: Date(timeIntervalSince1970: 90),
            text: "visually related"
        )
        let repository = RecallModelFakeRepository(frames: [source, similar])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(source), similarity: 0.80),
            RecallVisualRuntimeStub.match(hit: Self.hit(similar), similarity: 0.72),
        ])
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        let bounds = try Self.memoryLensBounds()

        model.findSimilarMoments(to: Self.hit(source), within: bounds)

        let published = await waitUntil {
            await visualRuntime.imageSearchCount == 1
                && !model.visualSearchIsRefining
                && model.results.map(\.id) == [similar.id]
        }
        #expect(published)
        #expect(model.queryText.isEmpty)
        #expect(model.memoryLensSelection == MemoryLensSelectionDescriptor(
            sourceFrameID: source.id,
            sourceVisualFingerprint: source.visualFingerprint,
            bounds: bounds
        ))
        #expect(model.memoryLensQueryImage != nil)
        #expect(model.visualOnlyRecallFrameIDs == [similar.id])
        #expect(model.visualRecallEvidenceByFrameID[similar.id] != nil)
        #expect(model.visualRecallEvidenceByFrameID[source.id] == nil)
        #expect(await visualRuntime.searchCount == 0)
        let request = try #require(await visualRuntime.imageSearchRequests.last)
        #expect(request.scope == RecallScope())
        #expect(request.excludedSourceFrameID == source.id)
        #expect(request.pixelWidth >= 8)
        #expect(request.pixelHeight >= 8)
    }

    @Test("A new Memory Lens source clears the previous crop preview immediately")
    func memoryLensNewSourceClearsOldPreview() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let first = try await Self.frameWithEncryptedMedia(
            id: "lens-preview-first",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "first source",
            fixture: fixture
        )
        let second = try await Self.frameWithEncryptedMedia(
            id: "lens-preview-second",
            capturedAt: Date(timeIntervalSince1970: 90),
            text: "second source",
            fixture: fixture
        )
        let repository = RecallModelFakeRepository(frames: [first, second])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(second), similarity: 0.74),
        ])
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(first))
        #expect(await waitUntil {
            model.selectedFrame?.id == first.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(first),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil {
            model.selectedFrame?.id == second.id
                && model.memoryLensQueryImage != nil
                && model.memoryLensCanStart
        })

        await repository.suspendFrame(id: second.id)
        model.findSimilarMoments(
            to: Self.hit(second),
            within: try Self.memoryLensBounds()
        )

        #expect(model.memoryLensSelection?.sourceFrameID == second.id)
        #expect(model.memoryLensQueryImage == nil)
        await repository.releaseFrame(id: second.id)
        _ = await waitUntil { !model.visualSearchIsRefining }
    }

    @Test("Memory Lens reruns image retrieval through exact time, app, and site scopes")
    func memoryLensFiltersRerunExactScope() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        var source = try await Self.frameWithEncryptedMedia(
            id: "lens-filter-source",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "selected source",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            fixture: fixture
        )
        source.context.domain = "example.com"
        var similar = Self.frame(
            id: "lens-filter-similar",
            capturedAt: source.capturedAt.addingTimeInterval(-30),
            text: "related page",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        similar.context.domain = "example.com"
        let repository = RecallModelFakeRepository(frames: [source, similar])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(similar), similarity: 0.70),
        ])
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil { await visualRuntime.imageSearchCount == 1 })

        model.setRecallDay(source.capturedAt)
        #expect(await waitUntil { await visualRuntime.imageSearchCount == 2 })
        model.toggleRecallApplication("com.apple.Safari")
        #expect(await waitUntil { await visualRuntime.imageSearchCount == 3 })
        model.toggleRecallDomain("example.com")
        #expect(await waitUntil {
            await visualRuntime.imageSearchCount == 4
                && !model.visualSearchIsRefining
        })

        let requests = await visualRuntime.imageSearchRequests
        #expect(requests.count == 4)
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: source.capturedAt)
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let dayScope = RecallScope(startDate: start, endDate: end)
        #expect(requests[0].scope == RecallScope())
        #expect(requests[1].scope == dayScope)
        #expect(requests[2].scope == RecallScope(
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: ["com.apple.Safari"]
        ))
        #expect(requests[3].scope == RecallScope(
            startDate: start,
            endDate: end,
            applicationBundleIdentifiers: ["com.apple.Safari"],
            domains: ["example.com"]
        ))
        #expect(requests.allSatisfy {
            $0.scope.text.isEmpty && $0.excludedSourceFrameID == source.id
        })
        #expect(model.memoryLensSelection?.sourceFrameID == source.id)

        model.clearMemoryLens()
        #expect(await waitUntil {
            model.memoryLensSelection == nil
                && !model.recallIsLoading
                && model.recallScope == requests[3].scope
        })
        #expect(model.queryText.isEmpty)
    }

    @Test("A changed Memory Lens source fingerprint rejects a late image response")
    func memoryLensFingerprintChangeRejectsLateResponse() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-fingerprint-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let similar = Self.frame(id: "lens-fingerprint-result", capturedAt: .now)
        let repository = RecallModelFakeRepository(frames: [source, similar])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(similar), similarity: 0.75),
        ])
        await visualRuntime.suspendImageSearches()
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil { await visualRuntime.hasImageSearchWaiter })

        var changed = source
        changed.visualFingerprint &+= 1
        await repository.add(changed)
        await visualRuntime.releaseImageSearches()

        #expect(await waitUntil {
            !model.visualSearchIsRefining && model.searchError != nil
        })
        #expect(model.results.isEmpty)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
        #expect(model.memoryLensSelection?.sourceFrameID == source.id)
        #expect(model.memoryLensQueryImage == nil)
    }

    @Test("Deleting a Memory Lens source rejects its late image response")
    func memoryLensDeletionRejectsLateResponse() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-deleted-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let similar = Self.frame(id: "lens-deleted-result", capturedAt: .now)
        let repository = RecallModelFakeRepository(frames: [source, similar])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(similar), similarity: 0.75),
        ])
        await visualRuntime.suspendImageSearches()
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil { await visualRuntime.hasImageSearchWaiter })

        _ = try await repository.deleteFrames(
            from: source.capturedAt,
            through: source.capturedAt
        )
        await visualRuntime.releaseImageSearches()

        #expect(await waitUntil {
            !model.visualSearchIsRefining && model.searchError != nil
        })
        #expect(model.results.isEmpty)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
        #expect(model.memoryLensSelection?.sourceFrameID == source.id)
        #expect(model.memoryLensQueryImage == nil)
    }

    @Test("A deleted Memory Lens result cannot publish from a late image response")
    func memoryLensDeletedResultDoesNotPublish() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-current-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let erased = Self.frame(
            id: "lens-erased-result",
            capturedAt: Date(timeIntervalSince1970: 90),
            text: "stale visual result"
        )
        let repository = RecallModelFakeRepository(frames: [source, erased])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(erased), similarity: 0.75),
        ])
        await visualRuntime.suspendImageSearches()
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil { await visualRuntime.hasImageSearchWaiter })

        _ = try await repository.deleteFrames(
            from: erased.capturedAt,
            through: erased.capturedAt
        )
        await visualRuntime.releaseImageSearches()

        #expect(await waitUntil { !model.visualSearchIsRefining })
        #expect(model.results.isEmpty)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
        #expect(model.memoryLensSelection?.sourceFrameID == source.id)
        #expect(model.searchError == nil)
    }

    @Test("An ordinary text query supersedes a cancellation-insensitive Memory Lens response")
    func ordinaryRecallRejectsLateMemoryLensResponse() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-superseded-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let lateVisual = Self.frame(
            id: "lens-late-visual",
            capturedAt: Date(timeIntervalSince1970: 90),
            text: "unrelated pixels"
        )
        let ordinary = Self.frame(
            id: "ordinary-result",
            capturedAt: Date(timeIntervalSince1970: 80),
            text: "ordinary target"
        )
        let repository = RecallModelFakeRepository(frames: [source, lateVisual, ordinary])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(lateVisual), similarity: 0.76),
        ])
        await visualRuntime.suspendImageSearches()
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil { await visualRuntime.hasImageSearchWaiter })

        model.queryText = "ordinary target"
        model.scheduleSearch()
        #expect(await waitUntil {
            model.memoryLensSelection == nil
                && !model.recallIsLoading
                && model.results.map(\.id) == [ordinary.id]
        })
        await visualRuntime.releaseImageSearches()
        try? await Task.sleep(for: .milliseconds(40))

        #expect(model.queryText == "ordinary target")
        #expect(model.recallScope.text == "ordinary target")
        #expect(model.results.map(\.id) == [ordinary.id])
        #expect(model.memoryLensSelection == nil)
        #expect(model.memoryLensQueryImage == nil)
        #expect(model.visualRecallEvidenceByFrameID[lateVisual.id] == nil)
    }

    @Test("Pre-retention invalidation blocks a late Memory Lens response and abort rebuilds Recall")
    func retentionBoundaryRejectsLateMemoryLensResponse() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-retention-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let lateVisual = Self.frame(
            id: "lens-retention-late",
            capturedAt: Date(timeIntervalSince1970: 90),
            text: "late appearance"
        )
        let repository = RecallModelFakeRepository(frames: [source, lateVisual])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(lateVisual), similarity: 0.76),
        ])
        await visualRuntime.suspendImageSearches()
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil {
            await visualRuntime.hasImageSearchWaiter && model.memoryLensQueryImage != nil
        })

        model.consumeRetentionMutationBoundary(.willMutate)
        #expect(model.results.isEmpty)
        #expect(model.selectedHit == nil)
        #expect(model.memoryLensSelection == nil)
        #expect(model.memoryLensQueryImage == nil)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)

        await visualRuntime.releaseImageSearches()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.results.isEmpty)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)

        model.consumeRetentionMutationBoundary(
            .finished(commitEventFollows: false)
        )
        #expect(await waitUntil {
            !model.recallIsLoading && model.results.map(\.id) == [source.id, lateVisual.id]
        })
        #expect(model.memoryLensSelection == nil)
        #expect(model.memoryLensQueryImage == nil)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
    }

    @Test("Clearing Memory Lens restores the exact prior query, filters, and selection")
    func clearMemoryLensRestoresRecallWorkspace() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        var source = try await Self.frameWithEncryptedMedia(
            id: "lens-return-source",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "alpha selected source",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            fixture: fixture
        )
        source.context.domain = "example.com"
        var similar = Self.frame(
            id: "lens-return-similar",
            capturedAt: source.capturedAt.addingTimeInterval(-60),
            text: "alpha related page",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        similar.context.domain = "example.com"
        let repository = RecallModelFakeRepository(frames: [source, similar])
        let visualRuntime = RecallVisualRuntimeStub(imageMatches: [
            RecallVisualRuntimeStub.match(hit: Self.hit(similar), similarity: 0.74),
        ])
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        model.queryText = "alpha"
        model.setRecallDay(source.capturedAt)
        model.toggleRecallApplication("com.apple.Safari")
        model.toggleRecallDomain("example.com")
        await model.refresh()
        let originalScope = model.recallScope
        let originalHit = try #require(model.results.first { $0.id == source.id })
        model.select(originalHit)
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })

        model.findSimilarMoments(
            to: originalHit,
            within: try Self.memoryLensBounds()
        )
        #expect(await waitUntil {
            !model.visualSearchIsRefining
                && model.results.map(\.id) == [similar.id]
        })
        model.clearMemoryLens()

        #expect(await waitUntil {
            model.memoryLensSelection == nil
                && model.queryText == "alpha"
                && model.recallScope == originalScope
                && !model.recallIsLoading
                && model.selectedFrame?.id == source.id
        })
        #expect(model.results.map(\.id) == [source.id, similar.id])
        #expect(model.selectedHit?.id == source.id)
        #expect(model.memoryLensQueryImage == nil)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
    }

    @Test("A failed Memory Lens clears unrelated rows but keeps the Lens active")
    func memoryLensFailureStaysActiveWithoutUnrelatedResults() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-failure-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let unrelated = Self.frame(
            id: "lens-failure-unrelated",
            capturedAt: Date(timeIntervalSince1970: 90),
            text: "unrelated chronology"
        )
        let repository = RecallModelFakeRepository(frames: [source, unrelated])
        let visualRuntime = RecallVisualRuntimeStub()
        await visualRuntime.setImageSearchFailure(true)
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        #expect(model.results.count == 2)
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )

        #expect(await waitUntil {
            !model.visualSearchIsRefining && model.searchError != nil
        })
        #expect(model.results.isEmpty)
        #expect(model.selectedHit == nil)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
        #expect(model.visualOnlyRecallFrameIDs.isEmpty)
        #expect(model.memoryLensSelection?.sourceFrameID == source.id)
        #expect(model.queryText.isEmpty)
        #expect(await visualRuntime.imageSearchCount == 1)
    }

    @Test("Memory Lens refuses a response mislabeled as text-to-image evidence")
    func memoryLensRejectsUnexpectedEvidenceKind() async throws {
        let fixture = try MediaFixture()
        defer { fixture.cleanUp() }
        let source = try await Self.frameWithEncryptedMedia(
            id: "lens-evidence-source",
            capturedAt: Date(timeIntervalSince1970: 100),
            text: "selected source",
            fixture: fixture
        )
        let similar = Self.frame(id: "lens-evidence-result", capturedAt: .now)
        let repository = RecallModelFakeRepository(frames: [source, similar])
        let visualRuntime = RecallVisualRuntimeStub(
            imageMatches: [RecallVisualRuntimeStub.match(hit: Self.hit(similar))],
            imageEvidenceKind: .textToImageSimilarity
        )
        let model = makeModel(
            repository: repository,
            mediaStore: fixture.store,
            visualRuntime: visualRuntime
        )
        await model.refresh()
        model.select(Self.hit(source))
        #expect(await waitUntil {
            model.selectedFrame?.id == source.id && model.memoryLensCanStart
        })
        model.findSimilarMoments(
            to: Self.hit(source),
            within: try Self.memoryLensBounds()
        )

        #expect(await waitUntil {
            !model.visualSearchIsRefining && model.searchError != nil
        })
        #expect(model.results.isEmpty)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
        #expect(model.memoryLensSelection?.sourceFrameID == source.id)
    }

    @Test("Lexical matches publish immediately, then local visual evidence refines ranking")
    func visualRecallRefinesWithoutBlockingText() async {
        let lexicalFrame = Self.frame(1, text: "person with glasses notes")
        let visualFrame = Self.frame(2, text: "unrelated movie subtitle")
        let repository = RecallModelFakeRepository(frames: [lexicalFrame, visualFrame])
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [RecallVisualRuntimeStub.match(hit: Self.hit(visualFrame))]
        )
        await visualRuntime.suspendSearches()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person with glasses"

        await model.refresh()

        #expect(model.recallPresentationMode == .bestMatches)
        #expect(model.results.map(\.id) == [lexicalFrame.id])
        #expect(model.visualSearchIsRefining)
        #expect(await visualRuntime.searchCount == 1)

        await visualRuntime.releaseSearches()
        let refined = await waitUntil {
            !model.visualSearchIsRefining
                && model.visualRecallEvidenceByFrameID[visualFrame.id] != nil
        }
        #expect(refined)
        #expect(model.results.map(\.id) == [lexicalFrame.id, visualFrame.id])
        #expect(model.visualOnlyRecallFrameIDs == Set([visualFrame.id]))
        #expect(!model.recallHasMore)
    }

    @Test("Hybrid refinement keeps repository drill-sideways app alternatives")
    func hybridRecallKeepsDrillSidewaysApplicationFacets() async {
        let notes = Self.frame(
            1,
            text: "walnut desk notes",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let safari = Self.frame(
            2,
            text: "walnut desk page",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let repository = RecallModelFakeRepository(frames: [notes, safari])
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [RecallVisualRuntimeStub.match(hit: Self.hit(notes))]
        )
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "walnut desk"
        await model.refresh()
        #expect(await waitUntil {
            !model.visualSearchIsRefining && !model.recallFacetsAreLoading
        })

        model.toggleRecallApplication("com.apple.Notes")
        #expect(await waitUntil {
            let searchCount = await visualRuntime.searchCount
            return searchCount >= 2
                && !model.visualSearchIsRefining
                && !model.recallFacetsAreLoading
        })

        #expect(model.recallScope.applicationBundleIdentifiers == ["com.apple.Notes"])
        #expect(Set(model.recallFacets.applications.map(\.bundleIdentifier)) == [
            "com.apple.Notes",
            "com.apple.Safari",
        ])
    }

    @Test("A visual-only website remains available beside saved-text facets")
    func hybridRecallKeepsVisualOnlyWebsiteFacet() async {
        let lexical = Self.frame(
            1,
            text: "walnut desk notes",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        var visualBrowser = Self.frame(
            2,
            text: "unrelated browser page",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        visualBrowser.context.domain = "visual.example"
        let repository = RecallModelFakeRepository(frames: [lexical, visualBrowser])
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [RecallVisualRuntimeStub.match(hit: Self.hit(visualBrowser))]
        )
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "walnut desk"

        await model.refresh()
        #expect(await waitUntil {
            !model.visualSearchIsRefining
                && !model.recallFacetsAreLoading
                && model.visualRecallEvidenceByFrameID[visualBrowser.id] != nil
        })

        #expect(model.recallFacets.domains.map(\.domain) == ["visual.example"])
        #expect(model.recallBrowserMomentAvailability == .available(count: 0))
    }

    @Test("Saved Text Only never invokes visual retrieval")
    func savedTextOnlyBypassesVisualRecall() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "person with glasses"),
        ])
        let visualRuntime = RecallVisualRuntimeStub()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person with glasses"

        model.setRecallSearchMode(.savedTextOnly)
        let settled = await waitUntil { !model.recallIsLoading }

        #expect(settled)
        #expect(model.recallSearchMode == .savedTextOnly)
        #expect(model.recallPresentationMode == .savedTextOnly)
        #expect(await visualRuntime.searchCount == 0)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
    }

    @Test("Global image matches publish before person-detail refinement")
    func personDetailRefinesAVisibleGlobalShortlist() async throws {
        let first = Self.frame(1, text: "ordinary movie scene one")
        let second = Self.frame(2, text: "ordinary movie scene two")
        let repository = RecallModelFakeRepository(frames: [first, second])
        let firstMatch = RecallVisualRuntimeStub.match(hit: Self.hit(first), similarity: 0.34)
        let secondMatch = RecallVisualRuntimeStub.match(hit: Self.hit(second), similarity: 0.32)
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.2,
            y: 0.2,
            width: 0.4,
            height: 0.5
        ))
        let regionEvidence = VisualRegionRecallEvidence(
            kind: .face,
            bounds: bounds,
            similarity: 0.52,
            sourceVisualFingerprint: 42
        )
        let refinedSecond = RecallVisualRuntimeStub.match(
            hit: Self.hit(second),
            similarity: 0.52,
            error: 0
        )
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [firstMatch, secondMatch],
            regionResponse: VisualRegionRerankResponse(
                matches: [refinedSecond, firstMatch],
                evidenceByFrameID: [second.id: regionEvidence],
                candidateFrameCount: 2,
                embeddedRegionCount: 2
            )
        )
        await visualRuntime.suspendRegionReranks()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "a man with glasses"

        await model.refresh()
        let globalPublished = await waitUntil {
            let regionCount = await visualRuntime.regionRerankCount
            return regionCount == 1
                && model.results.map(\.id) == [first.id, second.id]
                && model.visualRecallEvidenceByFrameID[second.id]?.region == nil
                && model.visualSearchIsRefining
        }
        #expect(globalPublished)

        await visualRuntime.releaseRegionReranks()
        let refined = await waitUntil {
            !model.visualSearchIsRefining
                && model.results.map(\.id) == [second.id, first.id]
                && model.visualRecallEvidenceByFrameID[second.id]?.region == regionEvidence
        }
        #expect(refined)
    }

    @Test("Saved-text mode persists across query and filter refreshes")
    func savedTextModePersistsUntilChanged() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "person with glasses"),
        ])
        let visualRuntime = RecallVisualRuntimeStub()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person"

        model.setRecallSearchMode(.savedTextOnly)
        #expect(await waitUntil { !model.recallIsLoading })
        #expect(model.recallPresentationMode == .savedTextOnly)

        model.toggleRecallApplication("com.apple.Notes")
        #expect(await waitUntil { !model.recallIsLoading })
        #expect(model.recallPresentationMode == .savedTextOnly)

        model.queryText = "glasses"
        model.scheduleSearch()
        #expect(await waitUntil { !model.recallIsLoading })
        #expect(model.recallPresentationMode == .savedTextOnly)
        #expect(await visualRuntime.searchCount == 0)

        model.setRecallSearchMode(.bestMatches)
        let visualFinished = await waitUntil {
            let searchCount = await visualRuntime.searchCount
            return !model.recallIsLoading
                && !model.visualSearchIsRefining
                && searchCount == 1
        }
        #expect(visualFinished)
        #expect(model.recallSearchMode == .bestMatches)
        #expect(model.recallPresentationMode == .bestMatches)
    }

    @Test("Original wording is independent of the Best Matches source choice")
    func originalWordingKeepsBestMatchesSelected() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(1, text: "walnut desk"),
        ])
        let model = makeModel(repository: repository)
        model.queryText = "show me the walnut desk"

        await model.refresh()
        #expect(model.results.count == 1)
        #expect(model.recallQueryInterpretation?.searchText == "walnut desk")
        #expect(model.recallSearchMode == .bestMatches)

        model.searchOriginalWording()
        #expect(await waitUntil { !model.recallIsLoading })
        #expect(model.results.isEmpty)
        #expect(model.recallQueryInterpretation == nil)
        #expect(model.recallUsesOriginalWording)
        #expect(model.recallSearchMode == .bestMatches)
        #expect(model.recallPresentationMode == .bestMatches)
    }

    @Test("A temporal suffix is exposed as the editable Time scope")
    func temporalSuffixPublishesEditableTimeScope() async throws {
        let now = Date()
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(
                id: "today-desk",
                capturedAt: now,
                text: "walnut desk"
            ),
        ])
        let model = makeModel(repository: repository)

        model.setRecallQueryText("walnut desk today")
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallQueryInterpretation?.temporalScope == .today
        })

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        #expect(model.queryText == "walnut desk today")
        #expect(model.recallScope.startDate == nil)
        #expect(model.recallScope.endDate == nil)
        #expect(model.effectiveRecallFilterScope.startDate == today)
        #expect(model.effectiveRecallFilterScope.endDate == tomorrow)
        #expect(model.recallTimeLabel == "Today")
        #expect(model.hasRecallFilters)
        #expect(model.activeRecallFilterCount == 1)
        #expect(await repository.recallCount(text: "walnut desk") == 1)
    }

    @Test("An explicit Last 7 days choice replaces an interpreted Today scope once")
    func explicitTimeChoiceOverridesTemporalSuffixWithoutDuplicateRecall() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(id: "today-desk", capturedAt: now, text: "walnut desk"),
            Self.frame(id: "older-desk", capturedAt: threeDaysAgo, text: "walnut desk"),
        ])
        let model = makeModel(repository: repository)

        model.setRecallQueryText("walnut desk today")
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallQueryInterpretation?.temporalScope == .today
        })
        #expect(await repository.recallCount(text: "walnut desk") == 1)
        #expect(model.results.map(\.id) == [FrameID(rawValue: "today-desk")])

        model.setRecallLastDays(7)
        let expectedStart = try #require(calendar.date(byAdding: .day, value: -6, to: today))
        let expectedEnd = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallScope.startDate == expectedStart
                && model.recallScope.endDate == expectedEnd
        })

        #expect(model.queryText == "walnut desk")
        #expect(model.recallQueryInterpretation == nil)
        #expect(model.recallScope.text == "walnut desk")
        #expect(model.results.map(\.id) == [
            FrameID(rawValue: "today-desk"),
            FrameID(rawValue: "older-desk"),
        ])
        #expect(await repository.recallCount(text: "walnut desk") == 2)
        let requests = await repository.recallRequests(text: "walnut desk")
        #expect(requests.count == 2)
        #expect(requests[1].startDate == expectedStart)
        #expect(requests[1].endDate == expectedEnd)
    }

    @Test("Clearing interpreted time retains explicit app and website scopes")
    func clearingInterpretedTimeRetainsSourceFilters() async {
        var frame = Self.frame(
            id: "browser-desk",
            capturedAt: Date(),
            text: "walnut desk",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        frame.context.domain = "example.com"
        let repository = RecallModelFakeRepository(frames: [frame])
        let model = makeModel(repository: repository)

        model.setRecallQueryText("walnut desk today")
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallQueryInterpretation?.temporalScope == .today
        })

        model.toggleRecallApplication("com.apple.Safari")
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallScope.applicationBundleIdentifiers == ["com.apple.Safari"]
        })
        #expect(model.queryText == "walnut desk")
        #expect(model.recallScope.startDate != nil)
        #expect(model.recallScope.endDate != nil)

        model.toggleRecallDomain("example.com")
        #expect(await waitUntil {
            !model.recallIsLoading && model.recallScope.domains == ["example.com"]
        })

        model.clearRecallTimeScope()
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallScope.startDate == nil
                && model.recallScope.endDate == nil
        })
        #expect(model.queryText == "walnut desk")
        #expect(model.recallScope.applicationBundleIdentifiers == ["com.apple.Safari"])
        #expect(model.recallScope.domains == ["example.com"])
        #expect(model.activeRecallFilterCount == 2)
    }

    @Test("Clear materializes interpreted wording before removing every filter")
    func clearFiltersMaterializesTemporalInterpretation() async {
        let repository = RecallModelFakeRepository(frames: [
            Self.frame(id: "today-desk", capturedAt: Date(), text: "walnut desk"),
        ])
        let model = makeModel(repository: repository)

        model.setRecallQueryText("walnut desk today")
        #expect(await waitUntil {
            !model.recallIsLoading
                && model.recallQueryInterpretation?.temporalScope == .today
        })

        model.clearRecallFilters()
        #expect(await waitUntil { !model.recallIsLoading })
        #expect(model.queryText == "walnut desk")
        #expect(model.recallScope == RecallScope(text: "walnut desk"))
        #expect(model.recallQueryInterpretation == nil)
        #expect(!model.hasRecallFilters)
    }

    @Test("Session lock clears evidence before a cancellation-insensitive visual search exits")
    func lockRevokesVisibleRecallBeforeVisualShutdown() async throws {
        let frame = Self.frame(1, text: "person with glasses")
        let repository = RecallModelFakeRepository(frames: [frame])
        let visualRuntime = RecallVisualRuntimeStub()
        await visualRuntime.suspendSearches()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person with glasses"
        await model.refresh()
        let hit = try #require(model.results.first)
        model.select(hit)
        #expect(await waitUntil { model.selectedFrame?.id == frame.id })

        let lock = Task { await model.suspendForSessionLock() }
        let revokedBeforeRelease = await waitUntil {
            model.results.isEmpty
                && model.selectedHit == nil
                && model.selectedFrame == nil
                && model.visualRecallEvidenceByFrameID.isEmpty
                && !model.visualSearchIsRefining
        }

        #expect(revokedBeforeRelease)
        #expect(await visualRuntime.wasRevoked)
        await visualRuntime.releaseSearches()
        await lock.value
    }

    @Test("A new capture refreshes an active ranked search")
    func rankedSearchIncludesNewCapture() async {
        let original = Self.frame(1, text: "shared project")
        let repository = RecallModelFakeRepository(frames: [original])
        let model = makeModel(repository: repository)
        model.queryText = "shared"
        await model.refresh()
        #expect(model.results.map(\.id) == [original.id])

        let captured = Self.frame(2, text: "shared follow-up")
        await repository.add(captured)
        model.consume(.persisted(captured, continuous: true))

        #expect(await waitUntil { model.results.map(\.id) == [captured.id, original.id] })
    }

    @Test("Session lock rejects cancellation-insensitive person-detail publication")
    func lockRejectsLatePersonDetailEvidence() async throws {
        let frame = Self.frame(1, text: "movie scene")
        let repository = RecallModelFakeRepository(frames: [frame])
        let match = RecallVisualRuntimeStub.match(hit: Self.hit(frame), similarity: 0.33)
        let bounds = try #require(NormalizedVisualRegionBounds(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4
        ))
        let region = VisualRegionRecallEvidence(
            kind: .person,
            bounds: bounds,
            similarity: 0.50,
            sourceVisualFingerprint: 42
        )
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [match],
            regionResponse: VisualRegionRerankResponse(
                matches: [RecallVisualRuntimeStub.match(
                    hit: Self.hit(frame),
                    similarity: 0.50,
                    error: 0
                )],
                evidenceByFrameID: [frame.id: region]
            )
        )
        await visualRuntime.suspendRegionReranks()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person"
        await model.refresh()
        #expect(await waitUntil { await visualRuntime.regionRerankCount == 1 })
        #expect(model.visualRecallEvidenceByFrameID[frame.id]?.region == nil)

        let lock = Task { await model.suspendForSessionLock() }
        let cleared = await waitUntil {
            model.captureState == .locked
                && model.results.isEmpty
                && model.visualRecallEvidenceByFrameID.isEmpty
                && !model.visualSearchIsRefining
        }
        #expect(cleared)
        #expect(await visualRuntime.wasRevoked)

        await visualRuntime.releaseRegionReranks()
        await lock.value
        #expect(model.results.isEmpty)
        #expect(model.visualRecallEvidenceByFrameID.isEmpty)
    }

    @Test("Retention commit removes stale rows, selection, and decoded-media revision")
    func retentionCommitForcesFullRecallReload() async throws {
        let old = Self.frame(1, text: "retained project")
        let current = Self.frame(2, text: "retained project")
        let repository = RecallModelFakeRepository(frames: [old, current])
        let model = makeModel(repository: repository)
        model.queryText = "retained"
        await model.refresh()
        let oldHit = try #require(model.results.first { $0.id == old.id })
        model.select(oldHit)
        #expect(await waitUntil { model.selectedFrame?.id == old.id })
        let revisionBefore = model.mediaRevision

        _ = try await repository.deleteFrames(
            from: old.capturedAt,
            through: old.capturedAt
        )
        model.consume(.retentionCommitted)

        #expect(model.selectedHit == nil)
        #expect(model.selectedFrame == nil)
        #expect(model.mediaRevision == revisionBefore + 1)
        #expect(await waitUntil { model.results.map(\.id) == [current.id] })
    }

    @Test("Retention supersedes a cancellation-insensitive lexical read with a fresh reload")
    func retentionCannotRepublishErasedRowsFromInFlightRecall() async throws {
        let erased = Self.frame(1, text: "retained project")
        let current = Self.frame(2, text: "retained project")
        let repository = RecallModelFakeRepository(frames: [erased, current])
        let model = makeModel(repository: repository)
        model.queryText = "retained"
        await model.refresh()
        #expect(model.results.map(\.id) == [current.id, erased.id])

        // This read snapshots both rows before suspending and deliberately
        // ignores cancellation. It models a storage call that is already past
        // its cancellation boundary when retention commits.
        await repository.suspendNextRecall(text: "retained")
        let staleRefresh = Task { await model.refresh() }
        #expect(await waitUntil {
            await repository.hasRecallWaiter(text: "retained")
        })

        _ = try await repository.deleteFrames(
            from: erased.capturedAt,
            through: erased.capturedAt
        )
        model.consume(.retentionCommitted)

        // Retention must not wait for the stale call to unwind. A distinct
        // recall pass should rebuild the visible page from durable state.
        let freshReloadPublished = await waitUntil {
            let recallCount = await repository.recallCount(text: "retained")
            return recallCount >= 3 && model.results.map(\.id) == [current.id]
        }
        #expect(freshReloadPublished)

        await repository.releaseRecall(text: "retained")
        await staleRefresh.value
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.results.map(\.id) == [current.id])
    }

    @Test(
        "Capture or retention during final visual prewarm schedules another indexing pass",
        arguments: VisualIndexSignal.allCases
    )
    func visualIndexSignalDuringFinalPrewarmIsReplayed(
        signal: VisualIndexSignal
    ) async {
        let seed = Self.frame(1, text: "seed frame")
        let repository = RecallModelFakeRepository(frames: [seed])
        let visualRuntime = RecallVisualRuntimeStub()
        await visualRuntime.suspendPrewarms()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)

        model.consume(.persisted(seed, continuous: true))
        #expect(await waitUntil { await visualRuntime.hasPrewarmWaiter })
        #expect(await visualRuntime.indexCount == 1)

        switch signal {
        case .persisted:
            let captured = Self.frame(2, text: "arrived during prewarm")
            await repository.add(captured)
            model.consume(.persisted(captured, continuous: true))
        case .retention:
            model.consume(.retentionCommitted)
        }

        await visualRuntime.releasePrewarms()
        #expect(await waitUntil { await visualRuntime.indexCount >= 2 })
    }

    @Test("A finishing visual index is prewarmed before its first refinement is exposed")
    func visualIndexPrewarmsBeforeFirstRefinement() async {
        let lexical = Self.frame(1, text: "person with glasses")
        let visual = Self.frame(2, text: "movie scene")
        let repository = RecallModelFakeRepository(frames: [lexical, visual])
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [RecallVisualRuntimeStub.match(hit: Self.hit(visual))]
        )
        await visualRuntime.suspendPrewarms()
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)

        // One final indexing pass has completed, but its encrypted search
        // snapshot is intentionally held in prewarm.
        model.consume(.persisted(lexical, continuous: true))
        #expect(await waitUntil { await visualRuntime.hasPrewarmWaiter })

        model.queryText = "person with glasses"
        await model.refresh()
        #expect(model.results.map(\.id) == [lexical.id])

        let refinementStartedBeforePrewarm = await waitUntil(timeout: .milliseconds(200)) {
            await visualRuntime.searchCount > 0
                || !model.visualRecallEvidenceByFrameID.isEmpty
        }
        #expect(!refinementStartedBeforePrewarm)

        await visualRuntime.releasePrewarms()
        let refined = await waitUntil {
            model.visualRecallEvidenceByFrameID[visual.id] != nil
        }
        #expect(refined)

        let events = await visualRuntime.lifecycleEvents
        let prewarmFinished = events.firstIndex(of: "prewarm-finished")
        let firstSearch = events.firstIndex(of: "search")
        #expect(prewarmFinished != nil)
        #expect(firstSearch != nil)
        if let prewarmFinished, let firstSearch {
            #expect(prewarmFinished < firstSearch)
        }
    }

    @Test("Visual failure keeps query-scoped facets")
    func failedVisualRecallDoesNotPublishUnrelatedFacets() async {
        let notes = Self.frame(
            1,
            text: "walnut desk",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let safari = Self.frame(
            2,
            text: "unrelated page",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let repository = RecallModelFakeRepository(frames: [notes, safari])
        let visualRuntime = RecallVisualRuntimeStub()
        await visualRuntime.setSearchFailure(true)
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "walnut desk"

        await model.refresh()
        #expect(await waitUntil { model.visualSearchError != nil && !model.recallFacetsAreLoading })
        #expect(model.recallFacets.applications.map(\.bundleIdentifier) == ["com.apple.Notes"])
    }

    @Test("Visual reranking after indexing uses the original lexical baseline")
    func indexingProgressReranksCurrentVisualQuery() async {
        let lexical = Self.frame(1, text: "person with glasses")
        let firstVisual = Self.frame(2, text: "movie scene one")
        let secondVisual = Self.frame(3, text: "movie scene two")
        let repository = RecallModelFakeRepository(frames: [lexical, firstVisual, secondVisual])
        let visualRuntime = RecallVisualRuntimeStub(
            matches: [RecallVisualRuntimeStub.match(hit: Self.hit(firstVisual))]
        )
        let model = makeModel(repository: repository, visualRuntime: visualRuntime)
        model.queryText = "person with glasses"
        await model.refresh()
        #expect(await waitUntil { model.visualRecallEvidenceByFrameID[firstVisual.id] != nil })

        await visualRuntime.setMatches([
            RecallVisualRuntimeStub.match(hit: Self.hit(secondVisual)),
        ])
        model.consume(.persisted(secondVisual, continuous: true))

        #expect(await waitUntil {
            await visualRuntime.searchCount >= 2
                && model.visualRecallEvidenceByFrameID[secondVisual.id] != nil
        })
        #expect(model.results.contains { $0.id == lexical.id })
        #expect(model.visualOnlyRecallFrameIDs.contains(secondVisual.id))
    }

    private func makeModel(
        repository: any PassageModelRepository,
        mediaStore: MediaStore? = nil,
        visualRuntime: (any PassageVisualRecallServing)? = nil,
        activationStore: FirstMemoryActivationStore? = nil
    ) -> PassageModel {
        let fixtureName = "RecallAsyncModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: fixtureName)!
        defaults.removePersistentDomain(forName: fixtureName)
        return PassageModel(
            captureIntentStore: CaptureIntentStore(defaults: defaults),
            screenPermissionStatus: { true },
            screenPermissionRequest: { true },
            accessibilityPermissionStatus: { false },
            accessibilityPermissionRequest: {},
            firstMemoryActivationStore: activationStore
                ?? FirstMemoryActivationStore(defaults: defaults),
            repository: repository,
            mediaStore: mediaStore,
            visualRecallRuntime: visualRuntime
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private static func memoryLensBounds() throws -> NormalizedVisualRegionBounds {
        try #require(NormalizedVisualRegionBounds(
            x: 0.125,
            y: 0.125,
            width: 0.75,
            height: 0.75
        ))
    }

    private static func frameWithEncryptedMedia(
        id: String,
        capturedAt: Date,
        text: String,
        applicationName: String = "Notes",
        bundleIdentifier: String = "com.apple.Notes",
        fixture: MediaFixture
    ) async throws -> FrameDocument {
        var frame = frame(
            id: id,
            capturedAt: capturedAt,
            text: text,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        let receipt = try await fixture.store.write(
            image: testImage(),
            id: frame.id,
            capturedAt: capturedAt
        )
        frame.imageRelativePath = receipt.imagePath
        frame.thumbnailRelativePath = receipt.thumbnailPath
        frame.pixelWidth = 32
        frame.pixelHeight = 32
        return frame
    }

    private static func testImage() throws -> CGImage {
        let pixel = [UInt8(72), 146, 221, 255]
        let bytes = Data(Array(repeating: pixel, count: 32 * 32).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 32 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private static func frame(
        _ index: Int,
        text: String,
        applicationName: String = "Notes",
        bundleIdentifier: String = "com.apple.Notes"
    ) -> FrameDocument {
        frame(
            id: String(format: "f%03d", index),
            capturedAt: Date(timeIntervalSince1970: Double(index)),
            text: text,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func frame(
        id: String,
        capturedAt: Date,
        text: String = "remembered text",
        applicationName: String = "Notes",
        bundleIdentifier: String = "com.apple.Notes"
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: capturedAt,
            context: ScreenContext(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier
            ),
            ocrText: text,
            imageRelativePath: "Media/\(id).bin",
            pixelWidth: 100,
            pixelHeight: 100,
            visualFingerprint: 1,
            changeScore: 1
        )
    }

    private static func hit(_ frame: FrameDocument) -> SearchHit {
        SearchHit(
            id: frame.id,
            capturedAt: frame.capturedAt,
            context: frame.context,
            snippet: frame.ocrText,
            imageRelativePath: frame.imageRelativePath,
            thumbnailRelativePath: frame.thumbnailRelativePath,
            score: 0
        )
    }
}

private actor RecallModelFakeRepository: PassageModelRepository {
    private enum FakeError: LocalizedError {
        case invalidCursor
        case deleteFailed
        case facetsFailed

        var errorDescription: String? {
            switch self {
            case .invalidCursor: "The test cursor is invalid."
            case .deleteFailed: "The test deletion failed."
            case .facetsFailed: "The test facet read failed."
            }
        }
    }

    private var frames: [FrameDocument]
    private var suspendedRecallTexts = Set<String>()
    private var suspendedNextRecallTexts = Set<String>()
    private var recallWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var recallCounts: [String: Int] = [:]
    private var recordedRecallScopes: [RecallScope] = []
    private var suspendedFacetTexts = Set<String>()
    private var facetWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var suspendedFrameIDs = Set<FrameID>()
    private var frameWaiters: [FrameID: [CheckedContinuation<Void, Never>]] = [:]
    private var deleteShouldFail = false
    private var facetsShouldFail = false

    init(frames: [FrameDocument]) {
        self.frames = frames
    }

    func add(_ frame: FrameDocument) {
        frames.removeAll { $0.id == frame.id }
        frames.append(frame)
    }

    func suspendRecall(text: String) {
        suspendedRecallTexts.insert(text)
    }

    func suspendNextRecall(text: String) {
        suspendedNextRecallTexts.insert(text)
    }

    func recallCount(text: String) -> Int {
        recallCounts[text, default: 0]
    }

    func recallRequests(text: String) -> [RecallScope] {
        recordedRecallScopes.filter { $0.text == text }
    }

    func hasRecallWaiter(text: String) -> Bool {
        !(recallWaiters[text] ?? []).isEmpty
    }

    func releaseRecall(text: String) {
        suspendedRecallTexts.remove(text)
        let waiters = recallWaiters.removeValue(forKey: text) ?? []
        waiters.forEach { $0.resume() }
    }

    func suspendFacets(text: String) {
        suspendedFacetTexts.insert(text)
    }

    func hasFacetWaiter(text: String) -> Bool {
        !(facetWaiters[text] ?? []).isEmpty
    }

    func releaseFacets(text: String) {
        suspendedFacetTexts.remove(text)
        let waiters = facetWaiters.removeValue(forKey: text) ?? []
        waiters.forEach { $0.resume() }
    }

    func setFacetFailure(_ enabled: Bool) {
        facetsShouldFail = enabled
    }

    func suspendFrame(id: FrameID) {
        suspendedFrameIDs.insert(id)
    }

    func hasFrameWaiter(id: FrameID) -> Bool {
        !(frameWaiters[id] ?? []).isEmpty
    }

    func releaseFrame(id: FrameID) {
        suspendedFrameIDs.remove(id)
        let waiters = frameWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume() }
    }

    func setDeleteFailure(_ enabled: Bool) {
        deleteShouldFail = enabled
    }

    func insert(_ frame: FrameDocument) {
        add(frame)
    }

    func search(_ query: SearchQuery) -> [SearchHit] {
        Array(filtered(
            RecallScope(
                text: query.text,
                startDate: query.startDate,
                endDate: query.endDate,
                applicationBundleIdentifiers: query.applicationBundleIdentifiers,
                domains: query.domains
            )
        ).prefix(query.limit).map(Self.hit))
    }

    func recent(limit: Int) -> [SearchHit] {
        Array(sortedFrames.prefix(max(limit, 0)).map(Self.hit))
    }

    func frame(id: FrameID) async -> FrameDocument? {
        if suspendedFrameIDs.contains(id) {
            await withCheckedContinuation { continuation in
                frameWaiters[id, default: []].append(continuation)
            }
        }
        return frames.first { $0.id == id }
    }

    func deleteFrames(olderThan date: Date) throws -> [String] {
        if deleteShouldFail { throw FakeError.deleteFailed }
        return removeFrames { $0.capturedAt < date }
    }

    func deleteFrames(from startDate: Date?, through endDate: Date?) throws -> [String] {
        if deleteShouldFail { throw FakeError.deleteFailed }
        return removeFrames { frame in
            (startDate.map { frame.capturedAt >= $0 } ?? true)
                && (endDate.map { frame.capturedAt <= $0 } ?? true)
        }
    }

    func deleteOldestFrames(limit: Int) throws -> [String] {
        if deleteShouldFail { throw FakeError.deleteFailed }
        let ids = Set(sortedFrames.suffix(max(limit, 0)).map(\.id))
        return removeFrames { ids.contains($0.id) }
    }

    func expireOldestMedia(limit: Int) -> [String] { [] }

    func statistics() -> StoreStatistics {
        StoreStatistics(
            frameCount: frames.count,
            oldestCapture: frames.map(\.capturedAt).min(),
            newestCapture: frames.map(\.capturedAt).max(),
            databaseBytes: 0,
            mediaBytes: 0
        )
    }

    func recall(
        _ scope: RecallScope,
        after cursor: RecallCursor?,
        limit: Int
    ) async throws -> RecallPage {
        recallCounts[scope.text, default: 0] += 1
        recordedRecallScopes.append(scope)
        let suspendsWithSnapshot = suspendedNextRecallTexts.remove(scope.text) != nil
        let snapshot = suspendsWithSnapshot ? filtered(scope) : nil
        if suspendsWithSnapshot || suspendedRecallTexts.contains(scope.text) {
            await withCheckedContinuation { continuation in
                recallWaiters[scope.text, default: []].append(continuation)
            }
        }
        let matches = snapshot ?? filtered(scope)
        let start: Int
        if let cursor {
            guard let index = matches.firstIndex(where: { $0.id.rawValue == cursor.token }) else {
                throw FakeError.invalidCursor
            }
            start = matches.index(after: index)
        } else {
            start = matches.startIndex
        }
        let boundedLimit = min(max(limit, RecallPage.minimumLimit), RecallPage.maximumLimit)
        let end = min(start + boundedLimit, matches.endIndex)
        let pageFrames = start < end ? Array(matches[start..<end]) : []
        let hasMore = end < matches.endIndex
        return RecallPage(
            hits: pageFrames.map(Self.hit),
            nextCursor: hasMore ? pageFrames.last.map { RecallCursor(token: $0.id.rawValue) } : nil,
            hasMore: hasMore
        )
    }

    func recallFacets(
        _ scope: RecallScope,
        limitPerKind: Int
    ) async throws -> RecallFacets {
        if suspendedFacetTexts.contains(scope.text) {
            await withCheckedContinuation { continuation in
                facetWaiters[scope.text, default: []].append(continuation)
            }
        }
        if facetsShouldFail { throw FakeError.facetsFailed }
        let appScope = RecallScope(
            text: scope.text,
            startDate: scope.startDate,
            endDate: scope.endDate,
            domains: scope.domains
        )
        let domainScope = RecallScope(
            text: scope.text,
            startDate: scope.startDate,
            endDate: scope.endDate,
            applicationBundleIdentifiers: scope.applicationBundleIdentifiers
        )
        let appGroups = Dictionary(grouping: filtered(appScope)) {
            $0.context.bundleIdentifier ?? ""
        }
        let domainGroups = Dictionary(grouping: filtered(domainScope)) {
            $0.context.domain ?? ""
        }
        return RecallFacets(
            applications: appGroups
                .filter { !$0.key.isEmpty }
                .map {
                    RecallApplicationFacet(
                        bundleIdentifier: $0.key,
                        applicationName: $0.value.first?.context.applicationName ?? $0.key,
                        frameCount: $0.value.count
                    )
                },
            domains: domainGroups
                .filter { !$0.key.isEmpty }
                .map { RecallDomainFacet(domain: $0.key, frameCount: $0.value.count) },
            browserMomentCount: filtered(domainScope).count {
                ScreenContext.isKnownWebBrowserBundleIdentifier(
                    $0.context.bundleIdentifier
                )
            }
        )
    }

    func activitySessions(_ query: ActivitySessionQuery) -> [ActivitySessionSummary] { [] }

    func activitySession(id: ActivitySessionID, momentLimit: Int) -> ActivitySessionDetail? { nil }

    private var sortedFrames: [FrameDocument] {
        frames.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.id.rawValue > $1.id.rawValue
            }
            return $0.capturedAt > $1.capturedAt
        }
    }

    private func filtered(_ scope: RecallScope) -> [FrameDocument] {
        sortedFrames.filter { frame in
            (scope.text.isEmpty
                || frame.ocrText.localizedCaseInsensitiveContains(scope.text))
                && (scope.startDate.map { frame.capturedAt >= $0 } ?? true)
                && (scope.endDate.map { frame.capturedAt < $0 } ?? true)
                && (scope.applicationBundleIdentifiers.isEmpty
                    || frame.context.bundleIdentifier.map {
                        scope.applicationBundleIdentifiers.contains($0)
                    } == true)
                && (scope.domains.isEmpty
                    || frame.context.domain.map { scope.domains.contains($0.lowercased()) } == true)
        }
    }

    private func removeFrames(_ shouldRemove: (FrameDocument) -> Bool) -> [String] {
        let removed = frames.filter(shouldRemove)
        frames.removeAll(where: shouldRemove)
        return removed.map(\.imageRelativePath)
    }

    private static func hit(_ frame: FrameDocument) -> SearchHit {
        SearchHit(
            id: frame.id,
            capturedAt: frame.capturedAt,
            context: frame.context,
            snippet: frame.ocrText,
            imageRelativePath: frame.imageRelativePath,
            thumbnailRelativePath: frame.thumbnailRelativePath,
            score: 0
        )
    }
}

private struct MediaFixture {
    let root: URL
    let store: MediaStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassageRecallAsyncTests-\(UUID().uuidString)", isDirectory: true)
        let paths = PassagePaths(root: root)
        try paths.createDirectories()
        let key = try VaultKey.testing(bytes: Data(repeating: 17, count: VaultKey.byteCount))
        store = MediaStore(paths: paths, vaultKey: key)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecallVisualRuntimeStub: PassageVisualRecallServing {
    static let identity = VisualModelIdentity(
        identifier: "stub-visual",
        revision: "1",
        fingerprint: String(repeating: "b", count: 64),
        preprocessingRevision: "stub-v1",
        embeddingDimension: 512
    )

    private var matches: [VisualEmbeddingMatch]
    private var imageMatches: [VisualEmbeddingMatch]
    private var imageEvidenceKind: VisualSearchEvidenceKind
    private var regionResponse: VisualRegionRerankResponse?
    private var searchesAreSuspended = false
    private var searchShouldFail = false
    private var searchWaiters: [CheckedContinuation<Void, Never>] = []
    private var imageSearchesAreSuspended = false
    private var imageSearchShouldFail = false
    private var imageSearchWaiters: [CheckedContinuation<Void, Never>] = []
    private var regionReranksAreSuspended = false
    private var regionRerankWaiters: [CheckedContinuation<Void, Never>] = []
    private var prewarmsAreSuspended = false
    private var prewarmWaiters: [CheckedContinuation<Void, Never>] = []
    private var events: [String] = []
    private(set) var searchCount = 0
    private(set) var imageSearchRequests: [RecallVisualImageSearchRequest] = []
    private(set) var regionRerankCount = 0
    private(set) var indexCount = 0
    private nonisolated let revocation = RecallRevocationProbe()

    init(
        matches: [VisualEmbeddingMatch] = [],
        imageMatches: [VisualEmbeddingMatch] = [],
        imageEvidenceKind: VisualSearchEvidenceKind = .imageToImageSimilarity,
        regionResponse: VisualRegionRerankResponse? = nil
    ) {
        self.matches = matches
        self.imageMatches = imageMatches
        self.imageEvidenceKind = imageEvidenceKind
        self.regionResponse = regionResponse
    }

    static func match(
        hit: SearchHit,
        similarity: Double = 0.31,
        error: Double = 0.005
    ) -> VisualEmbeddingMatch {
        VisualEmbeddingMatch(
            hit: hit,
            similarity: similarity,
            maximumSimilarityError: error,
            model: identity,
            associatedFrameCount: 1
        )
    }

    func suspendSearches() {
        searchesAreSuspended = true
    }

    func suspendImageSearches() {
        imageSearchesAreSuspended = true
    }

    func suspendPrewarms() {
        prewarmsAreSuspended = true
    }

    func suspendRegionReranks() {
        regionReranksAreSuspended = true
    }

    var hasPrewarmWaiter: Bool {
        !prewarmWaiters.isEmpty
    }

    var hasImageSearchWaiter: Bool {
        !imageSearchWaiters.isEmpty
    }

    var imageSearchCount: Int {
        imageSearchRequests.count
    }

    var lifecycleEvents: [String] {
        events
    }

    func releasePrewarms() {
        prewarmsAreSuspended = false
        let waiters = prewarmWaiters
        prewarmWaiters = []
        waiters.forEach { $0.resume() }
    }

    func setMatches(_ matches: [VisualEmbeddingMatch]) {
        self.matches = matches
    }

    func setImageMatches(_ matches: [VisualEmbeddingMatch]) {
        imageMatches = matches
    }

    func setImageEvidenceKind(_ evidenceKind: VisualSearchEvidenceKind) {
        imageEvidenceKind = evidenceKind
    }

    func setSearchFailure(_ shouldFail: Bool) {
        searchShouldFail = shouldFail
    }

    func setImageSearchFailure(_ shouldFail: Bool) {
        imageSearchShouldFail = shouldFail
    }

    nonisolated func revoke() {
        revocation.revoke()
    }

    var wasRevoked: Bool {
        revocation.isRevoked
    }

    func releaseSearches() {
        searchesAreSuspended = false
        let waiters = searchWaiters
        searchWaiters = []
        waiters.forEach { $0.resume() }
    }

    func releaseImageSearches() {
        imageSearchesAreSuspended = false
        let waiters = imageSearchWaiters
        imageSearchWaiters = []
        waiters.forEach { $0.resume() }
    }

    func releaseRegionReranks() {
        regionReranksAreSuspended = false
        let waiters = regionRerankWaiters
        regionRerankWaiters = []
        waiters.forEach { $0.resume() }
    }

    func indexPersistedFrame(_ frame: FrameDocument) -> VisualEmbeddingWriteSummary {
        VisualEmbeddingWriteSummary()
    }

    func indexNextBatch(limit: Int) -> VisualIndexingPass {
        indexCount += 1
        events.append("index")
        return VisualIndexingPass(
            attemptedFrameCount: 0,
            indexedFrameCount: 0,
            skippedMediaCount: 0,
            pausedForSystemConditions: false,
            writeSummary: VisualEmbeddingWriteSummary(),
            coverage: Self.coverageValue,
            elapsedMilliseconds: 0
        )
    }

    func search(
        text: String,
        scope: RecallScope,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        searchCount += 1
        events.append("search")
        if searchesAreSuspended {
            await withCheckedContinuation { continuation in
                searchWaiters.append(continuation)
            }
        }
        if searchShouldFail {
            throw RecallVisualRuntimeError.searchFailed
        }
        return VisualSearchResponse(
            matches: matches,
            coverage: Self.coverageValue,
            queryEmbeddingMilliseconds: 1,
            retrievalMilliseconds: 2
        )
    }

    func search(
        image: CGImage,
        scope: RecallScope,
        excluding sourceFrameID: FrameID?,
        minimumSimilarity: Double,
        limit: Int,
        candidateLimit: Int
    ) async throws -> VisualSearchResponse {
        imageSearchRequests.append(RecallVisualImageSearchRequest(
            scope: scope,
            excludedSourceFrameID: sourceFrameID,
            minimumSimilarity: minimumSimilarity,
            limit: limit,
            candidateLimit: candidateLimit,
            pixelWidth: image.width,
            pixelHeight: image.height
        ))
        events.append("image-search")
        let responseMatches = imageMatches.map { match in
            var current = match
            // Production image-query matches carry the exact indexed frame
            // fingerprint. Test fixtures use fingerprint 1 unless a test
            // deliberately mutates the authoritative frame afterward.
            if current.sourceVisualFingerprint == nil {
                current.sourceVisualFingerprint = 1
            }
            return current
        }
        let responseEvidenceKind = imageEvidenceKind
        if imageSearchesAreSuspended {
            await withCheckedContinuation { continuation in
                imageSearchWaiters.append(continuation)
            }
        }
        if imageSearchShouldFail {
            throw RecallVisualRuntimeError.searchFailed
        }
        return VisualSearchResponse(
            matches: responseMatches,
            coverage: Self.coverageValue,
            evidenceKind: responseEvidenceKind,
            queryEmbeddingMilliseconds: 1,
            retrievalMilliseconds: 2
        )
    }

    func rerankRegions(
        text: String,
        matches: [VisualEmbeddingMatch],
        policy: VisualRegionRerankingPolicy
    ) async -> VisualRegionRerankResponse {
        regionRerankCount += 1
        events.append("region-rerank")
        if regionReranksAreSuspended {
            await withCheckedContinuation { continuation in
                regionRerankWaiters.append(continuation)
            }
        }
        return regionResponse ?? VisualRegionRerankResponse(matches: matches)
    }

    func coverage() -> VisualEmbeddingCoverage {
        Self.coverageValue
    }

    func prewarmIndex() async {
        events.append("prewarm-started")
        if prewarmsAreSuspended {
            await withCheckedContinuation { continuation in
                prewarmWaiters.append(continuation)
            }
        }
        events.append("prewarm-finished")
    }

    private static let coverageValue = VisualEmbeddingCoverage(
        model: identity,
        eligibleFrameCount: 2,
        indexedEligibleFrameCount: 2,
        indexedFrameCount: 2,
        pendingEligibleFrameCount: 0,
        staleEmbeddingCount: 0,
        uniqueVectorCount: 2,
        deduplicatedFrameCount: 0,
        storedVectorPayloadBytes: 1_152,
        coverageFraction: 1
    )
}

private struct RecallVisualImageSearchRequest: Equatable, Sendable {
    var scope: RecallScope
    var excludedSourceFrameID: FrameID?
    var minimumSimilarity: Double
    var limit: Int
    var candidateLimit: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

private enum RecallVisualRuntimeError: Error {
    case searchFailed
}

enum VisualIndexSignal: CaseIterable, Sendable {
    case persisted
    case retention
}

private final class RecallRevocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }
}
