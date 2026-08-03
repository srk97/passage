import PassageCore
import Foundation
import Testing

@Suite("Recall navigation core contracts")
struct RecallNavigationCoreTests {
    @Test("A recall scope canonicalizes user-entered filters")
    func scopeNormalization() {
        let scope = RecallScope(
            text: "  Project\n\tAurora   checkout  ",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            applicationBundleIdentifiers: [
                "  com.apple.Safari  ",
                "com.figma.Desktop",
                "",
                "   ",
            ],
            domains: [
                "  EXAMPLE.COM  ",
                "Docs.Example.COM",
                "",
                "   ",
            ]
        )

        #expect(scope.text == "Project Aurora checkout")
        #expect(scope.startDate == Date(timeIntervalSince1970: 100))
        #expect(scope.endDate == Date(timeIntervalSince1970: 200))
        #expect(scope.applicationBundleIdentifiers == [
            "com.apple.Safari",
            "com.figma.Desktop",
        ])
        #expect(scope.domains == ["example.com", "docs.example.com"])

        var mutated = RecallScope()
        mutated.text = "  changed\n scope "
        mutated.applicationBundleIdentifiers = [" com.apple.Notes ", ""]
        mutated.domains = [" NEWS.EXAMPLE ", ""]
        let renormalized = mutated.normalized
        #expect(renormalized.text == "changed scope")
        #expect(renormalized.applicationBundleIdentifiers == ["com.apple.Notes"])
        #expect(renormalized.domains == ["news.example"])
    }

    @Test("Recall day ranges honor spring-forward and fall-back boundaries")
    func localDayDSTBoundaries() throws {
        let calendar = Self.torontoCalendar
        let interpreter = RecallQueryInterpreter(calendar: calendar)

        let springNow = try #require(Self.date(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12,
            calendar: calendar
        ))
        let spring = try #require(interpreter.interpret("checkout today", now: springNow))
        let springStart = try #require(spring.startDate)
        let springEnd = try #require(spring.endDate)
        let springNextDay = try #require(calendar.date(byAdding: .day, value: 1, to: springStart))
        #expect(springStart == Self.date(year: 2026, month: 3, day: 8, calendar: calendar))
        #expect(springEnd == Self.instantBefore(springNextDay))
        #expect(springNextDay.timeIntervalSince(springStart) == 23 * 60 * 60)

        let fallNow = try #require(Self.date(
            year: 2026,
            month: 11,
            day: 1,
            hour: 12,
            calendar: calendar
        ))
        let fall = try #require(interpreter.interpret("checkout today", now: fallNow))
        let fallStart = try #require(fall.startDate)
        let fallEnd = try #require(fall.endDate)
        let fallNextDay = try #require(calendar.date(byAdding: .day, value: 1, to: fallStart))
        #expect(fallStart == Self.date(year: 2026, month: 11, day: 1, calendar: calendar))
        #expect(fallEnd == Self.instantBefore(fallNextDay))
        #expect(fallNextDay.timeIntervalSince(fallStart) == 25 * 60 * 60)
    }

    private static var torontoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_CA")
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        calendar: Calendar
    ) -> Date? {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))
    }

    private static func instantBefore(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.nextDown)
    }
}
