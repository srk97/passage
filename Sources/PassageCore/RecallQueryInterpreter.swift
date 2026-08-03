import Foundation

/// Conversational wording that Passage can remove without guessing at the
/// user's intent. These are deliberately narrow, edge-anchored templates rather
/// than a general stop-word list.
public enum RecallQueryScaffold: String, Hashable, Sendable {
    case whereILeft
    case whatWasIWorkingOn
    case showMe
    case takeMeBackTo
    case resume
    case liked
    case saw
}

public enum RecallWeekday: Int, CaseIterable, Hashable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    public var displayName: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }
}

public enum RecallTemporalScope: Hashable, Sendable {
    case today
    case yesterday
    case lastWeek
    case weekday(RecallWeekday)

    public var displayName: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastWeek: "Last week"
        case .weekday(let weekday): weekday.displayName
        }
    }
}

/// A conservative second-chance lexical query derived from conversational
/// wording. `nil` means the original query should remain authoritative.
public struct RecallQueryInterpretation: Hashable, Sendable {
    public let searchText: String
    public let startDate: Date?
    public let endDate: Date?
    public let recognizedScaffolds: [RecallQueryScaffold]
    public let temporalScope: RecallTemporalScope?

    public init(
        searchText: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        recognizedScaffolds: [RecallQueryScaffold] = [],
        temporalScope: RecallTemporalScope? = nil
    ) {
        self.searchText = searchText
        self.startDate = startDate
        self.endDate = endDate
        self.recognizedScaffolds = recognizedScaffolds
        self.temporalScope = temporalScope
    }

    /// A concise disclosure suitable for showing beside rescued results.
    public var displayLabel: String {
        let queryLabel = "\u{201c}\(searchText)\u{201d}"
        guard let temporalScope else { return queryLabel }
        return "\(queryLabel) \u{00b7} \(temporalScope.displayName)"
    }

    /// Replaces the lexical text while retaining exact metadata filters and
    /// intersecting any existing date bounds with the recognized time scope.
    public func applying(to query: SearchQuery) -> SearchQuery {
        var result = query
        result.text = searchText
        if let startDate {
            result.startDate = result.startDate.map { max($0, startDate) } ?? startDate
        }
        if let endDate {
            result.endDate = result.endDate.map { min($0, endDate) } ?? endDate
        }
        return result
    }
}

/// Recognizes a deliberately small set of high-confidence conversational
/// wrappers and calendar suffixes. It never expands terms, introduces `OR`, or
/// rewrites text inside the captured lexical expression.
public struct RecallQueryInterpreter: Sendable {
    private struct LeadingPattern: Sendable {
        let words: [String]
        let scaffold: RecallQueryScaffold
    }

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func interpret(
        _ rawQuery: String,
        now: Date = Date()
    ) -> RecallQueryInterpretation? {
        var candidate = Self.trim(rawQuery)
        guard !candidate.isEmpty else { return nil }

        candidate = Self.removingTerminalSentencePunctuation(from: candidate)

        let temporalMatch = Self.removeTemporalSuffix(from: candidate)
        candidate = temporalMatch.remainder

        var scaffolds: [RecallQueryScaffold] = []
        while let leading = Self.removeLeadingScaffold(from: candidate) {
            candidate = leading.remainder
            scaffolds.append(leading.scaffold)
        }
        if let trailing = Self.removeTrailingScaffold(from: candidate) {
            candidate = trailing.remainder
            scaffolds.append(trailing.scaffold)
        }

        guard temporalMatch.scope != nil || !scaffolds.isEmpty else {
            return nil
        }

        // Articles and deictic pronouns are removed only at the exposed edge of
        // a recognized template. They are never filtered from arbitrary input.
        candidate = Self.removeLeadingReferenceWrapper(from: candidate)
        candidate = Self.trim(candidate)
        guard Self.hasDistinctiveContent(candidate) else { return nil }

        let dates = temporalMatch.scope.flatMap { dateRange(for: $0, now: now) }
        guard temporalMatch.scope == nil || dates != nil else { return nil }

        return RecallQueryInterpretation(
            searchText: candidate,
            startDate: dates?.start,
            endDate: dates?.end,
            recognizedScaffolds: scaffolds,
            temporalScope: temporalMatch.scope
        )
    }

    private func dateRange(
        for scope: RecallTemporalScope,
        now: Date
    ) -> (start: Date, end: Date)? {
        let today = calendar.startOfDay(for: now)

        switch scope {
        case .today:
            return inclusiveDay(startingAt: today)
        case .yesterday:
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else {
                return nil
            }
            return inclusiveDay(startingAt: start)
        case .lastWeek:
            guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start) else {
                return nil
            }
            return (start, Self.instantBefore(currentWeek.start))
        case .weekday(let weekday):
            let currentWeekday = calendar.component(.weekday, from: today)
            let daysSinceRequestedWeekday = (currentWeekday - weekday.rawValue + 7) % 7
            guard let start = calendar.date(
                byAdding: .day,
                value: -daysSinceRequestedWeekday,
                to: today
            ) else {
                return nil
            }
            return inclusiveDay(startingAt: start)
        }
    }

    private func inclusiveDay(startingAt start: Date) -> (start: Date, end: Date)? {
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return (start, Self.instantBefore(nextDay))
    }

    private static func instantBefore(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.nextDown)
    }

    private static let leadingPatterns: [LeadingPattern] = [
        LeadingPattern(words: ["where", "i", "left", "off", "with"], scaffold: .whereILeft),
        LeadingPattern(words: ["where", "i", "left", "off", "on"], scaffold: .whereILeft),
        LeadingPattern(words: ["where", "i", "left", "off", "at"], scaffold: .whereILeft),
        LeadingPattern(words: ["where", "i", "left", "off", "in"], scaffold: .whereILeft),
        LeadingPattern(words: ["where", "i", "left", "off"], scaffold: .whereILeft),
        LeadingPattern(words: ["where", "i", "left"], scaffold: .whereILeft),
        LeadingPattern(
            words: ["what", "was", "i", "working", "on", "with"],
            scaffold: .whatWasIWorkingOn
        ),
        LeadingPattern(
            words: ["what", "was", "i", "working", "on", "for"],
            scaffold: .whatWasIWorkingOn
        ),
        LeadingPattern(
            words: ["what", "was", "i", "working", "on"],
            scaffold: .whatWasIWorkingOn
        ),
        LeadingPattern(words: ["take", "me", "back", "to"], scaffold: .takeMeBackTo),
        LeadingPattern(words: ["show", "me"], scaffold: .showMe),
        LeadingPattern(words: ["resume"], scaffold: .resume),
    ]

    private static func removeLeadingScaffold(
        from value: String
    ) -> (remainder: String, scaffold: RecallQueryScaffold)? {
        for pattern in leadingPatterns {
            guard let end = endIndex(ofLeadingWords: pattern.words, in: value) else {
                continue
            }
            var remainder = String(value[end...])
            if remainder.first == ":" {
                remainder.removeFirst()
            }
            return (trim(remainder), pattern.scaffold)
        }
        return nil
    }

    private static func removeTrailingScaffold(
        from value: String
    ) -> (remainder: String, scaffold: RecallQueryScaffold)? {
        if let remainder = removingTrailingWords(["i", "liked"], from: value) {
            return (remainder, .liked)
        }
        if let remainder = removingTrailingWords(["i", "saw"], from: value) {
            return (remainder, .saw)
        }
        return nil
    }

    private static func removeTemporalSuffix(
        from value: String
    ) -> (remainder: String, scope: RecallTemporalScope?) {
        let fixedScopes: [([String], RecallTemporalScope)] = [
            (["from", "last", "week"], .lastWeek),
            (["last", "week"], .lastWeek),
            (["from", "yesterday"], .yesterday),
            (["yesterday"], .yesterday),
            (["from", "today"], .today),
            (["today"], .today),
        ]
        for (words, scope) in fixedScopes {
            if let remainder = removingTrailingWords(words, from: value) {
                return (remainder, scope)
            }
        }
        for weekday in RecallWeekday.allCases {
            if let remainder = removingTrailingWords(
                ["on", weekday.displayName],
                from: value
            ) {
                return (remainder, .weekday(weekday))
            }
        }
        return (value, nil)
    }

    private static func removeLeadingReferenceWrapper(from value: String) -> String {
        for word in ["the", "that", "this"] {
            if let end = endIndex(ofLeadingWords: [word], in: value) {
                return trim(String(value[end...]))
            }
        }
        return value
    }

    private static func endIndex(
        ofLeadingWords words: [String],
        in value: String
    ) -> String.Index? {
        var cursor = value.startIndex

        for (offset, word) in words.enumerated() {
            if offset > 0 {
                guard cursor < value.endIndex, value[cursor].isWhitespace else { return nil }
                while cursor < value.endIndex, value[cursor].isWhitespace {
                    cursor = value.index(after: cursor)
                }
            }
            guard let wordEnd = value.index(
                cursor,
                offsetBy: word.count,
                limitedBy: value.endIndex
            ) else {
                return nil
            }
            let actual = String(value[cursor..<wordEnd])
            guard actual.compare(word, options: .caseInsensitive) == .orderedSame else {
                return nil
            }
            cursor = wordEnd
        }

        guard cursor == value.endIndex || value[cursor].isWhitespace || value[cursor] == ":" else {
            return nil
        }
        return cursor
    }

    private static func removingTrailingWords(
        _ words: [String],
        from value: String
    ) -> String? {
        var cursor = value.endIndex

        for (offset, word) in words.reversed().enumerated() {
            if offset > 0 {
                guard cursor > value.startIndex else { return nil }
                let before = value.index(before: cursor)
                guard value[before].isWhitespace else { return nil }
                while cursor > value.startIndex {
                    let previous = value.index(before: cursor)
                    guard value[previous].isWhitespace else { break }
                    cursor = previous
                }
            }
            guard let wordStart = value.index(
                cursor,
                offsetBy: -word.count,
                limitedBy: value.startIndex
            ) else {
                return nil
            }
            let actual = String(value[wordStart..<cursor])
            guard actual.compare(word, options: .caseInsensitive) == .orderedSame else {
                return nil
            }
            cursor = wordStart
        }

        guard cursor == value.startIndex || value[value.index(before: cursor)].isWhitespace else {
            return nil
        }
        return trim(String(value[..<cursor]))
    }

    private static func removingTerminalSentencePunctuation(from value: String) -> String {
        var result = value
        while let last = result.last, last == "?" || last == "!" || last == "." {
            result.removeLast()
            result = trim(result)
        }
        return result
    }

    private static func hasDistinctiveContent(_ value: String) -> Bool {
        guard value.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return false
        }

        // Exact residues from the supported templates are not enough evidence
        // to issue a second FTS query. This is refusal logic, not token removal.
        let residue = value.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return ![
            "it", "the", "that", "this", "what", "where", "thing", "something", "anything",
        ].contains(residue)
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
