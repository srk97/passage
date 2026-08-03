@testable import PassageUI
import PassageCore
import Foundation
import Testing

@Suite("Timeline projection")
struct TimelineProjectionTests {
    @Test("An idle timeline shows only the current saved-memory puck")
    func idleTimelineUsesSavedMoment() {
        let saved = Date(timeIntervalSinceReferenceDate: 100)
        let hit = hit("saved", at: saved, applicationName: "Safari")

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: hit,
            requestedDate: nil,
            preview: nil,
            newestDate: nil,
            isScrubbing: false
        )

        #expect(presentation.status == .idle)
        #expect(presentation.requestedDate == nil)
        #expect(presentation.resolvedDate == saved)
        #expect(presentation.puckDate == saved)
        #expect(presentation.applicationName == "Safari")
    }

    @Test("An active seek separates the chosen-time needle from the last shown memory")
    func activeSeekKeepsBothTruths() {
        let saved = Date(timeIntervalSinceReferenceDate: 100)
        let requested = Date(timeIntervalSinceReferenceDate: 125)
        let hit = hit("saved", at: saved)
        let preview = RecallTimeLensPreview(
            requestedAt: requested,
            hit: hit,
            resolution: .resolving
        )

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: hit,
            requestedDate: requested,
            preview: preview,
            newestDate: nil,
            isScrubbing: true
        )

        #expect(presentation.status == .resolving)
        #expect(presentation.requestedDate == requested)
        #expect(presentation.resolvedDate == nil)
        #expect(presentation.lastShownDate == saved)
        #expect(presentation.puckDate == saved)
    }

    @Test("A resolved sparse seek explains the saved app and temporal gap")
    func resolvedGapIsTruthful() {
        let requested = Date(timeIntervalSinceReferenceDate: 3 * 60 * 60)
        let saved = requested.addingTimeInterval(-13 * 60)
        let hit = hit(
            "saved",
            at: saved,
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari"
        )
        let preview = RecallTimeLensPreview(
            requestedAt: requested,
            hit: hit,
            resolution: .resolved
        )

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: hit,
            requestedDate: requested,
            preview: preview,
            newestDate: nil,
            isScrubbing: true
        )

        #expect(presentation.status == .resolved)
        #expect(presentation.requestedDate == requested)
        #expect(presentation.resolvedDate == saved)
        #expect(abs((presentation.gap ?? 0) - (13 * 60)) < 0.001)
        #expect(presentation.gapDescription == "13 min earlier")
        #expect(presentation.applicationName == "Safari")
        #expect(presentation.bundleIdentifier == "com.apple.Safari")
        #expect(presentation.accessibilityValue?.contains("Safari") == true)
        #expect(presentation.accessibilityValue?.contains("13 min earlier") == true)
    }

    @Test("An exact saved timestamp visually coalesces both meanings")
    func exactResolutionCoalesces() {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let hit = hit("exact", at: date)
        let preview = RecallTimeLensPreview(
            requestedAt: date,
            hit: hit,
            resolution: .resolved
        )

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: hit,
            requestedDate: date,
            preview: preview,
            newestDate: nil,
            isScrubbing: true
        )

        #expect(presentation.status == .resolved)
        #expect(presentation.isExact)
        #expect(presentation.gapDescription == nil)
        #expect(presentation.requestedDate == presentation.resolvedDate)
    }

    @Test("A result for an older pointer target remains visibly stale")
    func staleTargetNeverBecomesCurrentResolution() {
        let oldRequest = Date(timeIntervalSinceReferenceDate: 125)
        let currentRequest = Date(timeIntervalSinceReferenceDate: 175)
        let saved = hit("old", at: Date(timeIntervalSinceReferenceDate: 100))
        let preview = RecallTimeLensPreview(
            requestedAt: oldRequest,
            hit: saved,
            resolution: .resolved
        )

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: saved,
            requestedDate: currentRequest,
            preview: preview,
            newestDate: nil,
            isScrubbing: true
        )

        #expect(presentation.status == .resolving)
        #expect(presentation.requestedDate == currentRequest)
        #expect(presentation.resolvedDate == nil)
        #expect(presentation.lastShownDate == saved.capturedAt)
    }

    @Test("A successful miss never masquerades as the baseline selection")
    func successfulMissHasNoMemoryPuck() {
        let requested = Date(timeIntervalSinceReferenceDate: 75)
        let baseline = hit("baseline", at: Date(timeIntervalSinceReferenceDate: 100))
        let preview = RecallTimeLensPreview(
            requestedAt: requested,
            hit: nil,
            resolution: .resolved
        )

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: baseline,
            requestedDate: requested,
            preview: preview,
            newestDate: nil,
            isScrubbing: true
        )

        #expect(presentation.status == .noResult)
        #expect(presentation.resolvedDate == nil)
        #expect(presentation.lastShownDate == nil)
        #expect(presentation.puckDate == nil)
        #expect(presentation.accessibilityValue?.contains("No saved moment") == true)
    }

    @Test("A failed lookup retains the old image without claiming it as current")
    func failedLookupLabelsRetainedEvidence() {
        let requested = Date(timeIntervalSinceReferenceDate: 175)
        let retained = hit("retained", at: Date(timeIntervalSinceReferenceDate: 100))
        let preview = RecallTimeLensPreview(
            requestedAt: requested,
            hit: retained,
            resolution: .failed
        )

        let presentation = TimelineProjection.scrubPresentation(
            displayedHit: retained,
            requestedDate: requested,
            preview: preview,
            newestDate: nil,
            isScrubbing: true
        )

        #expect(presentation.status == .failed)
        #expect(presentation.resolvedDate == nil)
        #expect(presentation.lastShownDate == retained.capturedAt)
        #expect(presentation.accessibilityValue?.contains("could not check") == true)
    }

    @Test("The chosen-time bubble stays inside both rail edges")
    func bubbleClampsAtEdges() {
        #expect(TimelineProjection.bubbleCenter(
            requestedFraction: 0,
            railWidth: 200,
            bubbleWidth: 100
        ) == 54)
        #expect(TimelineProjection.bubbleCenter(
            requestedFraction: 0.5,
            railWidth: 200,
            bubbleWidth: 100
        ) == 100)
        #expect(TimelineProjection.bubbleCenter(
            requestedFraction: 1,
            railWidth: 200,
            bubbleWidth: 100
        ) == 146)
    }

    @Test("A one-moment whole-day rail still positions chosen time temporally")
    func oneMomentWholeDayCursorUsesBounds() throws {
        let bounds = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 100)
        ))
        let only = hit("only", at: Date(timeIntervalSinceReferenceDate: 80))

        #expect(TimelineProjection.cursorFraction(
            for: Date(timeIntervalSinceReferenceDate: 25),
            in: [only],
            bounds: bounds
        ) == 0.25)
    }

    @Test("Moments are ordered by capture time with a stable ID tie-break")
    func stableChronologicalOrder() {
        let sameTime = Date(timeIntervalSinceReferenceDate: 200)
        let hits = [
            hit("z", at: sameTime),
            hit("old", at: Date(timeIntervalSinceReferenceDate: 100)),
            hit("a", at: sameTime),
        ]

        #expect(TimelineProjection.ordered(hits).map(\.id.rawValue) == ["old", "a", "z"])
    }

    @Test("Fractions clamp and preserve temporal spacing")
    func temporalFractions() {
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 100)),
            hit("middle", at: Date(timeIntervalSinceReferenceDate: 125)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 200)),
        ]

        #expect(TimelineProjection.fraction(forIndex: -10, in: hits) == 0)
        #expect(TimelineProjection.fraction(forIndex: 1, in: hits) == 0.25)
        #expect(TimelineProjection.fraction(forIndex: 99, in: hits) == 1)
    }

    @Test("Equal timestamps fall back to stable positional spacing")
    func equalTimestampSpacing() {
        let timestamp = Date(timeIntervalSinceReferenceDate: 300)
        let hits = [hit("a", at: timestamp), hit("b", at: timestamp), hit("c", at: timestamp)]

        #expect(TimelineProjection.fraction(forIndex: 0, in: hits) == 0)
        #expect(TimelineProjection.fraction(forIndex: 1, in: hits) == 0.5)
        #expect(TimelineProjection.fraction(forIndex: 2, in: hits) == 1)
    }

    @Test("Scrub selection chooses the nearest moment and clamps boundaries")
    func nearestMoment() {
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 0)),
            hit("middle", at: Date(timeIntervalSinceReferenceDate: 40)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 100)),
        ]

        #expect(TimelineProjection.nearestHit(toFraction: -1, in: hits)?.id.rawValue == "first")
        #expect(TimelineProjection.nearestHit(toFraction: 0.36, in: hits)?.id.rawValue == "middle")
        #expect(TimelineProjection.nearestHit(toFraction: 2, in: hits)?.id.rawValue == "last")
        #expect(TimelineProjection.nearestHit(toFraction: 0.5, in: []) == nil)
    }

    @Test("A single moment remains centered and selectable")
    func singleMoment() {
        let only = hit("only", at: Date(timeIntervalSinceReferenceDate: 10))
        #expect(TimelineProjection.fraction(forIndex: 0, in: [only]) == 0.5)
        #expect(TimelineProjection.nearestHit(toFraction: 0, in: [only])?.id == only.id)
        #expect(TimelineProjection.nearestHit(toFraction: 1, in: [only])?.id == only.id)
    }

    @Test("A single moment paints as a point without invented activity")
    func singleMomentRailActivity() {
        let layout = TimelineProjection.railActivityLayout(in: [
            hit("only", at: Date(timeIntervalSinceReferenceDate: 10)),
        ])

        #expect(layout.segmentStartIndices.isEmpty)
        #expect(layout.isolatedHitIndices == [0])
    }

    @Test("The rail paints only real consecutive-hit intervals")
    func railActivityUsesRealIntervals() {
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 0)),
            hit("connected-last", at: Date(timeIntervalSinceReferenceDate: 60)),
        ]

        let layout = TimelineProjection.railActivityLayout(in: hits)

        #expect(layout.segmentStartIndices == [0])
        #expect(layout.isolatedHitIndices.isEmpty)
    }

    @Test("A newest hit after a gap paints as a point, not a trailing segment")
    func isolatedNewestMomentDoesNotGrowATail() {
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 0)),
            hit("connected", at: Date(timeIntervalSinceReferenceDate: 60)),
            hit(
                "isolated-last",
                at: Date(timeIntervalSinceReferenceDate:
                    60 + TimelineProjection.maximumContinuousInterval + 1)
            ),
        ]

        let layout = TimelineProjection.railActivityLayout(in: hits)

        #expect(layout.segmentStartIndices == [0])
        #expect(layout.isolatedHitIndices == [2])
    }

    @Test("A partially loaded day focuses the visible rail on its honest saved span")
    func focusesLoadedSpan() throws {
        let complete = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 4 * 60 * 60)
        ))
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 3 * 60 * 60)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 3 * 60 * 60 + 6 * 60)),
        ]

        let focused = try #require(TimelineProjection.focusedBounds(for: hits, within: complete))
        #expect(focused.oldest > complete.oldest)
        #expect(focused.newest < complete.newest)
        #expect(focused.oldest < hits[0].capturedAt)
        #expect(focused.newest > hits[1].capturedAt)
        #expect(focused.duration < 10 * 60)
    }

    @Test("A substantially loaded range keeps the complete scale stable")
    func completeScaleStaysStable() throws {
        let complete = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 10 * 60)
        ))
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 20)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 9 * 60 + 40)),
        ]

        #expect(TimelineProjection.focusedBounds(for: hits, within: complete) == complete)
    }

    @Test("Unloaded earlier moments keep the rail focused on what is actually drawn")
    func incompleteRangeNeverLooksEmpty() throws {
        let complete = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 10 * 60)
        ))
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 60)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 9 * 60 + 40)),
        ]

        let focused = try #require(TimelineProjection.focusedBounds(
            for: hits,
            within: complete,
            hasUnloadedEarlier: true
        ))
        #expect(focused.oldest > complete.oldest)
        #expect(focused.newest == complete.newest)
    }

    @Test("Whole-day browsing reaches the complete retained range with partial markers")
    func wholeDayNavigationUsesCompleteBounds() throws {
        let focused = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 3 * 60 * 60),
            newest: Date(timeIntervalSinceReferenceDate: 4 * 60 * 60)
        ))
        let complete = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 12 * 60 * 60)
        ))

        #expect(TimelineProjection.navigationBounds(
            focusedBounds: focused,
            completeBounds: complete,
            browsesWholeDay: false
        ) == focused)
        #expect(TimelineProjection.navigationBounds(
            focusedBounds: focused,
            completeBounds: complete,
            browsesWholeDay: true
        ) == complete)
    }

    @Test("App transition icons stay collision-free and preserve the final transition")
    func transitionMarkersAreSpaced() throws {
        let bounds = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 100)
        ))
        let hits = (0..<20).map { index in
            hit(
                "\(index)",
                at: Date(timeIntervalSinceReferenceDate: Double(index * 5)),
                bundleIdentifier: "app.\(index)"
            )
        }
        let indices = TimelineProjection.spacedTransitionIndices(
            in: hits,
            bounds: bounds,
            width: 200,
            minimumSeparation: 28
        )

        #expect(indices.first == 0)
        #expect(indices.last == 19)
        #expect(indices.count < hits.count)
        let positions = indices.map {
            TimelineProjection.markerPosition(
                fraction: bounds.fraction(for: hits[$0].capturedAt),
                width: 200
            )
        }
        #expect(positions.first == 12)
        #expect(try #require(positions.last) <= 188)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { pair in
            pair.1 - pair.0 >= 28
        })
    }

    @Test("Two colliding app icons keep the newer transition")
    func twoCollidingTransitionsPreferNewest() throws {
        let bounds = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 1_000)
        ))
        let hits = [
            hit("first", at: bounds.oldest, bundleIdentifier: "app.first"),
            hit(
                "latest-transition",
                at: bounds.oldest.addingTimeInterval(1),
                bundleIdentifier: "app.latest"
            ),
        ]

        #expect(TimelineProjection.spacedTransitionIndices(
            in: hits,
            bounds: bounds,
            width: 200,
            minimumSeparation: 28
        ) == [1])
    }

    @Test("When every app icon collapses, only the final transition remains")
    func allCollapsedTransitionsPreferFinal() throws {
        let bounds = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 10_000)
        ))
        let hits = (0..<5).map { index in
            hit(
                "\(index)",
                at: bounds.oldest.addingTimeInterval(Double(index)),
                bundleIdentifier: "app.\(index)"
            )
        }

        #expect(TimelineProjection.spacedTransitionIndices(
            in: hits,
            bounds: bounds,
            width: 200,
            minimumSeparation: 28
        ) == [4])
    }

    @Test("The final app icon replaces a crowded predecessor without breaking spacing")
    func finalTransitionDisplacesCrowdedPredecessor() throws {
        let bounds = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 100)
        ))
        let hits = [
            hit("first", at: bounds.oldest, bundleIdentifier: "app.first"),
            hit(
                "middle",
                at: bounds.oldest.addingTimeInterval(40),
                bundleIdentifier: "app.middle"
            ),
            hit(
                "final",
                at: bounds.oldest.addingTimeInterval(55),
                bundleIdentifier: "app.final"
            ),
        ]

        let indices = TimelineProjection.spacedTransitionIndices(
            in: hits,
            bounds: bounds,
            width: 100,
            minimumSeparation: 28
        )

        #expect(indices == [0, 2])
        let positions = indices.map {
            TimelineProjection.markerPosition(
                fraction: bounds.fraction(for: hits[$0].capturedAt),
                width: 100
            )
        }
        #expect(positions[1] - positions[0] >= 28)
    }

    @Test("One old outlier cannot compress a dense recent activity span")
    func focusesContinuousActivity() throws {
        let old = hit("old", at: Date(timeIntervalSinceReferenceDate: 0))
        let recent = (0..<92).map { index in
            hit(
                "recent-\(index)",
                at: Date(timeIntervalSinceReferenceDate: 3 * 60 * 60 + Double(index * 10))
            )
        }
        let hits = [old] + recent
        let range = TimelineProjection.activityRange(in: hits, around: hits.last?.id)

        #expect(range.lowerBound == 1)
        #expect(range.count == 92)
        let visible = Array(hits[range])
        let newest = try #require(hits.last?.capturedAt)
        let bounds = try #require(TimelineProjection.focusedBounds(
            for: visible,
            within: RecallTimeLensBounds(
                oldest: old.capturedAt,
                newest: newest
            ),
            hasUnloadedEarlier: true
        ))
        #expect(bounds.oldest > old.capturedAt)
        #expect(bounds.duration < 20 * 60)
    }

    @Test("Sparse breadcrumb captures cannot hold a dense activity span open")
    func sparseBreadcrumbsDoNotCreateOneContinuousSpan() {
        let breadcrumbs = (0..<60).map { index in
            hit(
                "breadcrumb-\(index)",
                at: Date(timeIntervalSinceReferenceDate: Double(index * 3 * 60))
            )
        }
        let denseStart = 3 * 60 * 60
        let dense = (0..<33).map { index in
            hit(
                "dense-\(index)",
                at: Date(timeIntervalSinceReferenceDate: Double(denseStart + index * 10))
            )
        }
        let hits = breadcrumbs + dense

        let range = TimelineProjection.activityRange(in: hits, around: hits.last?.id)

        #expect(range.lowerBound == breadcrumbs.count)
        #expect(range.count == dense.count)
    }

    @Test("The exact painted continuity boundary remains in one activity span")
    func continuityBoundaryIsShared() {
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 0)),
            hit(
                "boundary",
                at: Date(timeIntervalSinceReferenceDate:
                    TimelineProjection.maximumContinuousInterval)
            ),
            hit(
                "outside",
                at: Date(timeIntervalSinceReferenceDate:
                    TimelineProjection.maximumContinuousInterval * 2 + 1)
            ),
        ]

        let boundaryRange = TimelineProjection.activityRange(
            in: hits,
            around: hits[1].id
        )
        let outsideRange = TimelineProjection.activityRange(
            in: hits,
            around: hits[2].id
        )

        #expect(boundaryRange == 0..<2)
        #expect(outsideRange == 2..<3)
    }

    @Test("Stale complete bounds cannot pin newer visible moments to the right edge")
    func incompatibleCompleteBoundsAreIgnored() throws {
        let hits = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 1_000)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 1_120)),
        ]
        let stale = try #require(RecallTimeLensBounds(
            oldest: Date(timeIntervalSinceReferenceDate: 0),
            newest: Date(timeIntervalSinceReferenceDate: 900)
        ))

        let focused = try #require(TimelineProjection.focusedBounds(
            for: hits,
            within: stale
        ))

        #expect(focused.oldest < hits[0].capturedAt)
        #expect(focused.newest > hits[1].capturedAt)
        #expect(TimelineProjection.railFraction(
            forHitAt: 0,
            in: hits,
            bounds: focused
        ) < 0.5)
        #expect(TimelineProjection.railFraction(
            forHitAt: 1,
            in: hits,
            bounds: focused
        ) > 0.5)
    }

    @Test("Applications without bundle identifiers still create distinct transitions")
    func missingBundleIdentifiersUseApplicationNames() {
        let hits = [
            hit("first", at: .distantPast, bundleIdentifier: nil, applicationName: "Alpha"),
            hit("second", at: Date(), bundleIdentifier: nil, applicationName: "Beta"),
        ]

        #expect(TimelineProjection.spacedTransitionIndices(
            in: hits,
            bounds: nil,
            width: 200
        ) == [0, 1])
        #expect(TimelineProjection.applicationIdentity(for: hits[0].context) == "alpha")
        #expect(TimelineProjection.applicationIdentity(for: hits[1].context) == "beta")
    }

    @Test("Timeline results are restricted to the selected half-open day")
    func filtersWrongDayResults() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
        let selectedDay = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 28,
            hour: 12
        )))
        let start = calendar.startOfDay(for: selectedDay)
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let hits = [
            hit("before", at: start.addingTimeInterval(-1)),
            hit("first", at: start),
            hit("last", at: next.addingTimeInterval(-1)),
            hit("after", at: next),
        ]

        #expect(
            TimelineProjection.hits(hits, onDay: selectedDay, calendar: calendar).map(\.id.rawValue)
                == ["first", "last"]
        )
    }

    @Test("Focused bounds cannot seek into a hidden adjacent moment")
    func hiddenMomentCannotOwnPadding() throws {
        let hidden = hit("hidden", at: Date(timeIntervalSinceReferenceDate: 99))
        let visible = [
            hit("first", at: Date(timeIntervalSinceReferenceDate: 100)),
            hit("last", at: Date(timeIntervalSinceReferenceDate: 110)),
        ]
        let projected = try #require(TimelineProjection.focusedBounds(
            for: visible,
            within: RecallTimeLensBounds(oldest: hidden.capturedAt, newest: visible[1].capturedAt),
            hasUnloadedEarlier: true
        ))
        #expect(projected.oldest < visible[0].capturedAt)

        let clamped = try #require(TimelineProjection.clampBounds(
            projected,
            to: visible,
            hiddenBefore: true,
            hiddenAfter: false
        ))
        #expect(clamped.oldest == visible[0].capturedAt)
        #expect(clamped.date(at: 0) > hidden.capturedAt)
    }

    @Test("A focused isolated moment stays centered through the real bounds pipeline")
    func isolatedFocusedMomentStaysCentered() throws {
        let hidden = hit("hidden", at: Date(timeIntervalSinceReferenceDate: 0))
        let visible = [hit("isolated", at: Date(timeIntervalSinceReferenceDate: 10 * 60))]
        let projected = try #require(TimelineProjection.focusedBounds(
            for: visible,
            within: RecallTimeLensBounds(
                oldest: hidden.capturedAt,
                newest: visible[0].capturedAt
            ),
            hasUnloadedEarlier: true
        ))
        let clamped = try #require(TimelineProjection.clampBounds(
            projected,
            to: visible,
            hiddenBefore: true,
            hiddenAfter: false
        ))

        #expect(clamped.oldest == visible[0].capturedAt)
        #expect(clamped.newest == visible[0].capturedAt)
        #expect(TimelineProjection.railFraction(
            forHitAt: 0,
            in: visible,
            bounds: clamped
        ) == 0.5)
        #expect(TimelineProjection.cursorFraction(
            for: visible[0].capturedAt,
            in: visible,
            bounds: clamped
        ) == 0.5)
        #expect(clamped.date(at: 0) == visible[0].capturedAt)
        #expect(clamped.date(at: 1) == visible[0].capturedAt)
    }

    @Test("The rail remains frozen until commit resolution actually settles")
    func frozenRailLifetime() {
        #expect(TimelineProjection.shouldRetainFrozenRail(
            isScrubbing: true,
            isResolving: false
        ))
        #expect(TimelineProjection.shouldRetainFrozenRail(
            isScrubbing: false,
            isResolving: true
        ))
        #expect(!TimelineProjection.shouldRetainFrozenRail(
            isScrubbing: false,
            isResolving: false
        ))
    }

    @Test("A Timeline day scope is constraint-free and follows calendar-day DST")
    func cleanCalendarDayScope() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
        let daylightSavingDay = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        )))

        let scope = TimelineWorkspaceScope.dayScope(
            for: daylightSavingDay,
            calendar: calendar
        )
        let start = try #require(scope.startDate)
        let end = try #require(scope.endDate)

        #expect(start == calendar.startOfDay(for: daylightSavingDay))
        #expect(end.timeIntervalSince(start) == 23 * 60 * 60)
        #expect(scope.text.isEmpty)
        #expect(scope.applicationBundleIdentifiers.isEmpty)
        #expect(scope.domains.isEmpty)
    }

    @Test("Initial Timeline day prefers context without inheriting its constraints")
    func initialDayPriority() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
        let exactDay = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 3,
            hour: 12
        )))
        let selectedDay = try #require(calendar.date(byAdding: .day, value: 2, to: exactDay))
        let newestDay = try #require(calendar.date(byAdding: .day, value: 4, to: exactDay))
        var constrainedScope = TimelineWorkspaceScope.dayScope(
            for: exactDay,
            calendar: calendar
        )
        constrainedScope.text = "quarterly plan"
        constrainedScope.applicationBundleIdentifiers = ["com.apple.Notes"]
        constrainedScope.domains = ["example.com"]

        let fromVisibleSelection = TimelineWorkspaceScope.initialDay(
            preferredDay: nil,
            visibleSelectionDate: selectedDay,
            recallScope: constrainedScope,
            newestCapture: newestDay,
            now: .distantPast,
            calendar: calendar
        )
        let fromExactScope = TimelineWorkspaceScope.initialDay(
            preferredDay: nil,
            visibleSelectionDate: nil,
            recallScope: constrainedScope,
            newestCapture: newestDay,
            now: .distantPast,
            calendar: calendar
        )

        #expect(fromVisibleSelection == calendar.startOfDay(for: selectedDay))
        #expect(fromExactScope == calendar.startOfDay(for: exactDay))
    }

    private func hit(
        _ id: String,
        at capturedAt: Date,
        bundleIdentifier: String? = "app.example",
        applicationName: String = "Example"
    ) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            capturedAt: capturedAt,
            context: ScreenContext(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: id
            ),
            snippet: id,
            imageRelativePath: "\(id).heic",
            score: 0
        )
    }
}
