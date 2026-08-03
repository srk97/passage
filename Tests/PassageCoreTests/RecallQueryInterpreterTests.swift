import PassageCore
import Foundation
import Testing

@Suite("Recall query interpreter")
struct RecallQueryInterpreterTests {
    @Test("Known conversational scaffolds expose exact lexical content")
    func knownScaffolds() throws {
        let interpreter = RecallQueryInterpreter(calendar: Self.calendar)
        let cases: [(String, String, [RecallQueryScaffold])] = [
            ("where I left the checkout flow", "checkout flow", [.whereILeft]),
            ("WHERE I LEFT OFF WITH Project Atlas?", "Project Atlas", [.whereILeft]),
            ("what was I working on with Aurora", "Aurora", [.whatWasIWorkingOn]),
            ("show me the walnut desk", "walnut desk", [.showMe]),
            ("take me back to this checkout flow", "checkout flow", [.takeMeBackTo]),
            ("Resume: checkout redesign", "checkout redesign", [.resume]),
            ("that unusual lamp I liked", "unusual lamp", [.liked]),
            ("the walnut desk I saw", "walnut desk", [.saw]),
            (
                "show me where I left the checkout flow",
                "checkout flow",
                [.showMe, .whereILeft]
            ),
        ]

        for (rawQuery, expectedText, expectedScaffolds) in cases {
            let result = try #require(interpreter.interpret(rawQuery, now: Self.now))
            #expect(result.searchText == expectedText)
            #expect(result.recognizedScaffolds == expectedScaffolds)
            #expect(result.temporalScope == nil)
            #expect(result.startDate == nil)
            #expect(result.endDate == nil)
        }
    }

    @Test("Calendar suffixes produce inclusive, deterministic ranges")
    func temporalSuffixes() throws {
        let interpreter = RecallQueryInterpreter(calendar: Self.calendar)
        let cases: [(String, String, RecallTemporalScope, Date, Date)] = [
            (
                "checkout flow today",
                "checkout flow",
                .today,
                Self.date(2026, 7, 22),
                Self.instantBefore(2026, 7, 23)
            ),
            (
                "checkout flow yesterday",
                "checkout flow",
                .yesterday,
                Self.date(2026, 7, 21),
                Self.instantBefore(2026, 7, 22)
            ),
            (
                "the walnut desk from last week",
                "walnut desk",
                .lastWeek,
                Self.date(2026, 7, 13),
                Self.instantBefore(2026, 7, 20)
            ),
            (
                "unusual lamp on Friday",
                "unusual lamp",
                .weekday(.friday),
                Self.date(2026, 7, 17),
                Self.instantBefore(2026, 7, 18)
            ),
            (
                "checkout review on Wednesday",
                "checkout review",
                .weekday(.wednesday),
                Self.date(2026, 7, 22),
                Self.instantBefore(2026, 7, 23)
            ),
        ]

        for (rawQuery, expectedText, expectedScope, expectedStart, expectedEnd) in cases {
            let result = try #require(interpreter.interpret(rawQuery, now: Self.now))
            #expect(result.searchText == expectedText)
            #expect(result.temporalScope == expectedScope)
            #expect(result.startDate == expectedStart)
            #expect(result.endDate == expectedEnd)
        }

        let lastWeek = try #require(
            interpreter.interpret("the walnut desk from last week", now: Self.now)
        )
        #expect(lastWeek.displayLabel == "\u{201c}walnut desk\u{201d} \u{00b7} Last week")
    }

    @Test("Quoted and advanced FTS expressions remain intact")
    func preservesAdvancedFTS() throws {
        let interpreter = RecallQueryInterpreter(calendar: Self.calendar)
        let advanced = try #require(interpreter.interpret(
            "Show me   \"Project Aurora\" OR checkout*?",
            now: Self.now
        ))
        #expect(advanced.searchText == "\"Project Aurora\" OR checkout*")

        let dated = try #require(interpreter.interpret(
            "(\"Project Aurora\" OR checkout*) from last week",
            now: Self.now
        ))
        #expect(dated.searchText == "(\"Project Aurora\" OR checkout*)")
        #expect(dated.temporalScope == .lastWeek)

        #expect(interpreter.interpret("\"Project Aurora\" OR checkout*", now: Self.now) == nil)
    }

    @Test("Ambiguous or unrecognized wording is not rescued")
    func refusesLowConfidenceQueries() {
        let interpreter = RecallQueryInterpreter(calendar: Self.calendar)
        let queries = [
            "",
            "show me",
            "resume",
            "what was I working on yesterday?",
            "that I saw",
            "something I liked",
            "can you show me the walnut desk",
            "I liked the walnut desk",
            "today's checkout plan",
            "walnut desk I admired",
        ]

        for query in queries {
            #expect(interpreter.interpret(query, now: Self.now) == nil)
        }
    }

    @Test("Applying an interpretation retains filters and intersects dates")
    func appliesToSearchQuery() throws {
        let interpreter = RecallQueryInterpreter(calendar: Self.calendar)
        let interpretation = try #require(
            interpreter.interpret("show me the checkout flow today", now: Self.now)
        )
        let original = SearchQuery(
            text: "show me the checkout flow today",
            startDate: Self.date(2026, 7, 22, 9),
            endDate: Self.date(2026, 7, 23, 12),
            applicationBundleIdentifiers: ["com.figma.Desktop"],
            domains: ["figma.com"],
            activitySessionIDs: [ActivitySessionID(rawValue: "session")],
            limit: 17
        )

        let applied = interpretation.applying(to: original)
        #expect(applied.text == "checkout flow")
        #expect(applied.startDate == Self.date(2026, 7, 22, 9))
        #expect(applied.endDate == Self.instantBefore(2026, 7, 23))
        #expect(applied.applicationBundleIdentifiers == ["com.figma.Desktop"])
        #expect(applied.domains == ["figma.com"])
        #expect(applied.activitySessionIDs == [ActivitySessionID(rawValue: "session")])
        #expect(applied.limit == 17)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private static let now = date(2026, 7, 22, 15, 30)

    private static func instantBefore(_ year: Int, _ month: Int, _ day: Int) -> Date {
        let boundary = date(year, month, day)
        return Date(timeIntervalSince1970: boundary.timeIntervalSince1970.nextDown)
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }
}
