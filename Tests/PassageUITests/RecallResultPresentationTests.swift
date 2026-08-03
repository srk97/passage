@testable import PassageUI
import PassageCore
import Foundation
import Testing

@Suite("Recall result presentation")
struct RecallResultPresentationTests {
    @Test("Projection preserves every exact moment in deterministic newest-first order")
    func projectionPreservesRawResults() throws {
        let calendar = utcCalendar
        let newest = makeHit("c", at: date(2026, 7, 29, 10, 0, 4))
        let middle = makeHit("b", at: date(2026, 7, 29, 10, 0, 2))
        let oldest = makeHit("a", at: date(2026, 7, 29, 10, 0, 0))

        let groups = RecallResultPresentation.dayGroups(
            hits: [oldest, newest, middle],
            calendar: calendar
        )
        let group = try #require(groups.first)

        #expect(groups.count == 1)
        #expect(group.rawMomentCount == 3)
        #expect(group.activityCount == 1)
        #expect(group.stacks.flatMap(\.hits).map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test("Exactly sixty seconds starts a new activity stack")
    func strictGapBoundary() {
        let newestDate = Date(timeIntervalSince1970: 10_000)
        let within = makeHit("within", at: newestDate.addingTimeInterval(-59.999))
        let boundary = makeHit("boundary", at: newestDate.addingTimeInterval(-60))
        let newest = makeHit("newest", at: newestDate)

        #expect(RecallResultPresentation.stacks(hits: [newest, within]).count == 1)
        #expect(RecallResultPresentation.stacks(hits: [newest, boundary]).count == 2)
    }

    @Test("Missing or different session and source context stay separate")
    func ambiguousSourcesStaySeparate() {
        let now = Date(timeIntervalSince1970: 20_000)
        let baseline = makeHit("base", at: now)
        let variants = [
            makeHit("nil-session", at: now.addingTimeInterval(-2), session: nil),
            makeHit("other-session", at: now.addingTimeInterval(-2), session: "other"),
            makeHit("other-app", at: now.addingTimeInterval(-2), app: "Notes", bundle: "com.apple.Notes"),
            makeHit("other-domain", at: now.addingTimeInterval(-2), domain: "other.example"),
            makeHit("other-title", at: now.addingTimeInterval(-2), title: "Another page"),
            makeHit("other-url", at: now.addingTimeInterval(-2), url: "https://example.com/elsewhere"),
            makeHit("other-window", at: now.addingTimeInterval(-2), windowID: 99),
        ]

        for variant in variants {
            #expect(
                RecallResultPresentation.stacks(hits: [baseline, variant]).count == 2,
                "Expected \(variant.id.rawValue) to remain separate"
            )
        }
    }

    @Test("Equivalent context normalization still joins nearby changes")
    func contextNormalization() {
        let now = Date(timeIntervalSince1970: 30_000)
        let first = makeHit(
            "first",
            at: now,
            app: "Browser",
            bundle: " COM.EXAMPLE.BROWSER ",
            domain: "Example.COM.",
            title: "  Project   Notes ",
            url: "HTTPS://EXAMPLE.COM/project"
        )
        let second = makeHit(
            "second",
            at: now.addingTimeInterval(-2),
            app: "Different display name",
            bundle: "com.example.browser",
            domain: "example.com",
            title: "project notes",
            url: "https://example.com/project"
        )

        #expect(RecallResultPresentation.stacks(hits: [first, second]).count == 1)
    }

    @Test("Stacking is contiguous and never reaches across another activity")
    func stackingIsContiguous() {
        let now = Date(timeIntervalSince1970: 40_000)
        let firstA = makeHit("a-new", at: now)
        let b = makeHit(
            "b",
            at: now.addingTimeInterval(-2),
            title: "Different activity"
        )
        let secondA = makeHit("a-old", at: now.addingTimeInterval(-4))

        let stacks = RecallResultPresentation.stacks(hits: [secondA, b, firstA])
        #expect(stacks.map { $0.hits.map(\.id.rawValue) } == [["a-new"], ["b"], ["a-old"]])
    }

    @Test("Local day boundaries never merge")
    func localDayBoundary() throws {
        let calendar = utcCalendar
        let beforeMidnight = makeHit("before", at: date(2026, 7, 28, 23, 59, 59))
        let afterMidnight = makeHit("after", at: date(2026, 7, 29, 0, 0, 1))

        let groups = RecallResultPresentation.dayGroups(
            hits: [beforeMidnight, afterMidnight],
            calendar: calendar
        )

        #expect(groups.count == 2)
        #expect(try #require(groups.first).stacks.first?.count == 1)
        #expect(try #require(groups.last).stacks.first?.count == 1)
    }

    @Test("Count and duration caps prevent unbounded chained stacks")
    func stackCaps() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let countLimited = (0...180).map { index in
            makeHit("count-\(index)", at: now.addingTimeInterval(-Double(index)))
        }
        let countStacks = RecallResultPresentation.stacks(hits: countLimited)
        #expect(countStacks.map(\.count) == [180, 1])

        let spanLimited = (0...6).map { index in
            makeHit("span-\(index)", at: now.addingTimeInterval(-Double(index * 59)))
        }
        let spanStacks = RecallResultPresentation.stacks(hits: spanLimited)
        #expect(spanStacks.map(\.count) == [6, 1])
        #expect(try #require(spanStacks.first).hits.count == 6)
    }

    @Test("Loading an older page can grow the boundary stack without changing its ID")
    func paginationBoundaryReprojectsStably() throws {
        let now = Date(timeIntervalSince1970: 60_000)
        let newest = makeHit("newest", at: now)
        let middle = makeHit("middle", at: now.addingTimeInterval(-20))
        let olderPage = makeHit("older-page", at: now.addingTimeInterval(-40))

        let first = try #require(
            RecallResultPresentation.stacks(hits: [newest, middle]).first
        )
        let loaded = try #require(
            RecallResultPresentation.stacks(hits: [newest, middle, olderPage]).first
        )

        #expect(first.id == newest.id)
        #expect(loaded.id == first.id)
        #expect(loaded.hits.map(\.id) == [newest.id, middle.id, olderPage.id])
    }

    @Test("Collapsed stack represents an exact selected member")
    func selectedRepresentative() throws {
        let now = Date(timeIntervalSince1970: 70_000)
        let newest = makeHit("newest", at: now)
        let selected = makeHit("selected", at: now.addingTimeInterval(-2))
        let stack = try #require(
            RecallResultPresentation.stacks(hits: [selected, newest]).first
        )

        #expect(stack.representative(selectedID: nil).id == newest.id)
        #expect(stack.representative(selectedID: selected.id).id == selected.id)
        #expect(stack.contains(selected.id))
        #expect(!stack.contains(FrameID(rawValue: "missing")))
    }

    @Test("Equal timestamps retain the existing descending FrameID tie break")
    func equalTimestampTieBreak() {
        let moment = Date(timeIntervalSince1970: 80_000)
        let a = makeHit("a", at: moment)
        let b = makeHit("b", at: moment)
        let c = makeHit("c", at: moment)

        let ids = RecallResultPresentation.stacks(hits: [a, c, b])
            .flatMap(\.hits)
            .map(\.id.rawValue)
        #expect(ids == ["c", "b", "a"])
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) -> Date {
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = utcCalendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }

    private func makeHit(
        _ id: String,
        at capturedAt: Date,
        session: String? = "session",
        app: String = "Browser",
        bundle: String? = "com.example.browser",
        domain: String? = "example.com",
        title: String? = "Project notes",
        url: String? = "https://example.com/project",
        windowID: UInt32? = 7
    ) -> SearchHit {
        SearchHit(
            id: FrameID(rawValue: id),
            activitySessionID: session.map(ActivitySessionID.init(rawValue:)),
            capturedAt: capturedAt,
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: title,
                url: url.flatMap(URL.init(string:)),
                domain: domain,
                displayID: 1,
                windowID: windowID
            ),
            snippet: "Visible text \(id)",
            imageRelativePath: "\(id).heic",
            thumbnailRelativePath: "\(id)-thumb.jpg",
            score: 0
        )
    }
}
