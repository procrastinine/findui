@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func selectedCalendarPhrasesPreserveWholeMonthsAndLeapYears() throws {
    for phrase in ["Jan to April 2024", "Jan-April 2024", "Jan–April 2024", "January through Apr 2024"] {
        #expect(try SearchValueUnits.calendarRange(phrase) == .init(from: "2024-01-01", through: "2024-04-30"))
    }
    #expect(try SearchValueUnits.calendarRange("February 2024").through == "2024-02-29")
    #expect(try SearchValueUnits.calendarRange("February 2023").through == "2023-02-28")
    #expect(try SearchValueUnits.calendarRange("2024").through == "2024-12-31")
    #expect(try SearchValueUnits.calendarRange("Q1 2024").through == "2024-03-31")
    for phrase in ["01..04/24", "January or April 2024", "April-January 2024", "report Jan-April 2024"] {
        #expect(throws: (any Error).self) { try SearchValueUnits.calendarRange(phrase) }
    }
}

@Test func sizeComparisonsUseExactInclusiveIntegerBounds() throws {
    #expect(try SearchFilters.sizeBound("<= 8KiB", side: .maximum) == 8192)
    #expect(try SearchFilters.sizeBound("< 8KiB", side: .maximum) == 8191)
    #expect(try SearchFilters.sizeBound("> 8KiB", side: .minimum) == 8193)
    #expect(try SearchFilters.sizeBound("at least 8 kibibytes", side: .minimum) == 8192)
    #expect(try SearchFilters.sizeBound("bigger than 25mb", side: .minimum) == 25_000_001)
    #expect(try SearchFilters.sizeBound("below 50kb", side: .maximum) == 49_999)
    #expect(try SearchFilters.sizeBound("0.1 B", side: .maximum) == 0)
    #expect(try SearchFilters.sizeBound("0.1 B", side: .minimum) == 1)
    #expect(try SearchFilters.sizeBound("< 0.1 B", side: .maximum) == 0)
    #expect(try SearchFilters.sizeBound("> 0.1 B", side: .minimum) == 1)
    #expect(try SearchFilters.sizeBound("9223372036854775807 B", side: .maximum) == Int64.max)
    for (value, side) in [("< 0 B", SearchFilters.SizeSide.maximum), ("> 9223372036854775807 B", .minimum), ("<= 8KiB", .minimum)] {
        #expect(throws: (any Error).self) { try SearchFilters.sizeBound(value, side: side) }
    }
}

private func typedContext() -> SearchState {
    SearchState(query: "", mode: .files, scopePath: "/tmp", useIndex: false, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, selectedDrivePath: nil, indexedFilter: .files)
}

@Test func modelSizeBoundsRejectInvalidOrOppositeComparisonsBeforeCompilation() throws {
    let context = typedContext()
    for raw in [
        #"{"mode":"files","minimum":"more than 10mb"}"#,
        #"{"mode":"files","files":{"minimum":"more than 10mb"}}"#
    ] {
        let intent = try SearchIntent.decodeModelOutput(Data(raw.utf8))
        let snapshot = try intent.proposal(context: context, tools: .resolve()).snapshot
        let canonical = try (snapshot.compactProjection ?? snapshot).modelIntent()
        #expect(try SearchFilters.sizeBound(canonical.minimum?.text ?? "", side: .minimum) == 10_000_001)
    }
    for fields in [#""maximum":"more than 10mb""#, #""minimum":"less than 10mb""#,
                   #""minimum":"10 elephants""#, #""maximum":"roughly big""#,
                   #""minimum":"20 MB","maximum":"10 MB""#] {
        for raw in ["{\"mode\":\"files\",\(fields)}", "{\"mode\":\"files\",\"files\":{\(fields)}}"] {
            #expect(throws: (any Error).self) {
                let intent = try SearchIntent.decodeModelOutput(Data(raw.utf8))
                _ = try intent.proposal(context: context, tools: .resolve())
            }
        }
    }
}

@Test func selectedPluralTypesExpandWithoutChangingLiteralExtensions() throws {
    for spelling in ["pdfs", "PDFs", "pdf"] {
        #expect(try SearchFileTypes.selectedExtensions(spelling) == ["pdf"])
    }
    #expect(try SearchFileTypes.selectedExtensions(".pdfs") == ["pdfs"])
    #expect(try SearchFileTypes.selectedExtensions("css") == ["css"])
    let raw = #"{"mode":"files","extensions":["pdfs"]}"#
    #expect(try SearchIntent.decodeModelOutput(Data(raw.utf8)).extensions == ["pdf"])
    #expect(try JSONDecoder().decode(SearchIntent.self, from: Data(raw.utf8)).extensions == ["pdfs"])
}

@Test func markdownFormatAndLiteralSuffixStayDistinctThroughHistory() throws {
    for (selected, expected) in [("Markdown", ["markdown", "md"]), (".markdown", ["markdown"])] {
        let raw = try JSONSerialization.data(withJSONObject: ["mode": "files", "extensions": [selected]])
        let state = try SearchIntent.decodeModelOutput(raw).proposal(context: typedContext(), tools: .resolve()).snapshot
        let restored = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(state))
        #expect(try restored.modelIntent().extensions?.sorted() == expected)
        // Canonical state and pasted commands contain literal extensions,
        // so restoring old history must not expand an existing suffix.
        #expect(try JSONDecoder().decode(SearchIntent.self, from: raw).extensions == [selected])
    }
}

@Test func typedWireValuesBecomeOrdinaryVisibleControls() throws {
    let raw = #"{"mode":"files","minimum":{"value":1.5,"unit":"KiB"},"maximum":"<= 8KiB","calendarPeriod":"Jan-April 2024"}"#
    let intent = try JSONDecoder().decode(SearchIntent.self, from: Data(raw.utf8))
    let state = try intent.proposal(context: typedContext(), tools: .resolve()).snapshot
    let bounds = try state.filters.validated()
    #expect(bounds.minimumSize == 1536 && bounds.maximumSize == 8192)
    #expect(state.filters.datePeriod == .custom)
    let restored = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(state))
    #expect(restored == state)
    let canonical = try restored.modelIntent()
    #expect(canonical.calendarPeriod == nil)
    #expect(canonical.dateFrom == "2024-01-01" && canonical.dateThrough == "2024-04-30")
    #expect(try SearchValueUnits.relativeDays("5 weeks") == 35)
    #expect(throws: (any Error).self) { try SearchValueUnits.relativeDays("5 months") }
}

@Test func presetLiteralAndRawRegexRolesStayDistinct() throws {
    let expected = try #require(SearchPatternPresets.named("email"))
    for (matching, value) in [("preset", expected.pattern), ("regex", "email"), ("literal", "email")] {
        let data = try JSONSerialization.data(withJSONObject: ["mode":"contents", "contentMatching":matching, "content":"email"])
        let state = try JSONDecoder().decode(SearchIntent.self, from: data).proposal(context: typedContext(), tools: .resolve()).snapshot
        #expect(state.contentsInput == value)
        #expect(state.contentMatchingChoice == (matching == "literal" ? .literal : .regex))
        #expect(try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(state)) == state)
    }
    var state = typedContext(); state.query = "*.swift"
    state.applyContentPreset(expected)
    #expect(state.refinements.fileQuery == "*.swift")
    #expect(state.contentsInput == expected.pattern && state.contentMatchingChoice == .regex)
    #expect(state.mode == .contents && !state.refinements.wholeWords)
}

@Test func formatExclusionsExpandOnlySelectedTypes() throws {
    let data = Data(#"{"mode":"files","extensions":["svg","pdf","ai"],"excludedExtensions":["postscript"],"excludedFiles":["draft-*.*"]}"#.utf8)
    let state = try JSONDecoder().decode(SearchIntent.self, from: data).proposal(context: typedContext(), tools: .resolve()).snapshot
    #expect(state.refinements.extensions == "svg,pdf,ai")
    #expect(state.refinements.excludedFiles == "*.ps\ndraft-*.*")
    let literal = try JSONDecoder().decode(SearchIntent.self, from: Data(#"{"mode":"files","extensions":["image"]}"#.utf8))
    #expect(literal.extensions == ["image"])
}

@Test func copiedExclusionOrderDoesNotChangeTheReproducibleCommand() throws {
    let compiler = SearchPipelineCompiler(tools: .resolve())
    for grouped in [false, true] {
        func request(_ exclusions: [String]) throws -> SearchRequest {
            let fields: [String: Any] = grouped
                ? ["mode": "files", "files": ["excludedFiles": exclusions]]
                : ["mode": "files", "excludedFiles": exclusions]
            let data = try JSONSerialization.data(withJSONObject: fields)
            let intent = try SearchIntent.decodeModelOutput(data)
            return try intent.proposal(context: typedContext(), tools: .resolve()).snapshot.makeRequest()
        }
        let canonical = try request(["*.tmp", "build/*"])
        let reordered = try request(["build/*", "*.tmp", "build/*"])
        #expect(try compiler.compile(canonical).executionScript == compiler.compile(reordered).executionScript)
    }
}

@Test func calendarDurationsUseRealMonthsAndRetainEveryComponent() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let iso = ISO8601DateFormatter()
    for (now, duration, expected) in [
        ("2024-03-31T12:00:00Z", "1 month", "2024-02-29T12:00:00Z"),
        ("2023-03-31T12:00:00Z", "1 month", "2023-02-28T12:00:00Z"),
        ("2024-03-31T12:00:00Z", "1 month and 4 days", "2024-02-25T12:00:00Z"),
        ("2024-02-29T12:00:00Z", "1 year", "2023-02-28T12:00:00Z"),
        ("2026-10-01T12:00:00Z", "5 months and 4 days", "2026-04-27T12:00:00Z")
    ] {
        let value = try SearchValueUnits.calendarAge(duration)
        let start = try value.before(#require(iso.date(from: now)), calendar: calendar)
        #expect(iso.string(from: start) == expected)
    }
    #expect(try SearchValueUnits.calendarAge("1 YEAR, 2 months, and 3 weeks").text == "14 months and 21 days")
    for invalid in ["0 months", "-1 month", "1.5 months", "1 month ago", "1 month minus 4 days",
                    "5 months and 4 days but not 2023", "1201 months", "1 month and 10001 days", "4 days"] {
        #expect(throws: (any Error).self) { try SearchValueUnits.calendarAge(invalid) }
    }
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let age = try SearchValueUnits.calendarAge("1 month and 1 day")
    // The final calendar day crosses the DST boundary: retain noon locally.
    let start = try age.before(#require(iso.date(from: "2024-04-10T16:00:00Z")), calendar: calendar)
    #expect(iso.string(from: start) == "2024-03-09T17:00:00Z")
}

@Test func selectedNamedDaysAreExactAndNeverGuessNumericDateOrder() throws {
    for phrase in ["Jan 1, 2024", "January 1st 2024", "1 Jan 2024", "1st Jan. 2024"] {
        #expect(try SearchValueUnits.calendarDay(phrase) == "2024-01-01")
    }
    #expect(try SearchValueUnits.calendarDay("Feb 29, 2024") == "2024-02-29")
    for phrase in ["Feb 29, 2023", "Apr 31, 2024", "Jan 11st 2024", "03/04/2024", "January 2024"] {
        #expect(throws: (any Error).self) { try SearchValueUnits.calendarDay(phrase) }
    }
    let raw = #"{"mode":"files","date":"custom","dateFrom":"Jan 1, 2024","dateThrough":"Apr 30, 2024"}"#
    let intent = try SearchIntent.decodeModelOutput(Data(raw.utf8))
    #expect(intent.dateFrom == "2024-01-01" && intent.dateThrough == "2024-04-30")
}

@Test func calendarDurationAndYearBoundaryRoundTripThroughVisibleRules() throws {
    let raw = #"{"mode":"files","files":{"all":[{"calendarAge":"5 months and 4 days","dateField":"created"},{"date":"after","calendarBoundary":"2023","dateField":"created"}]}}"#
    let intent = try SearchIntent.decodeModelOutput(Data(raw.utf8))
    let state = try intent.proposal(context: typedContext(), tools: .resolve()).snapshot
    let dates = try #require(state.ruleSet).files.leaves.compactMap { rule -> SearchDateCondition? in
        if case .date(let date) = rule { return date }; return nil
    }
    #expect(dates.count == 2)
    #expect(dates[0].period == .recentCalendar && dates[0].calendarAge == "5 months and 4 days")
    #expect(dates[1].period == .after)
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    #expect(formatter.string(from: dates[1].from) == "2023-12-31")
    let restored = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(state))
    #expect(restored == state)
    let projection = try restored.modelIntent().proposal(context: typedContext(), tools: .resolve()).snapshot
    var a = state.makeRequest(), b = projection.makeRequest()
    a.referenceDate = Date(timeIntervalSince1970: 1_790_000_000); b.referenceDate = a.referenceDate
    let compiler = SearchPipelineCompiler(tools: .resolve())
    #expect(try compiler.compile(a).executionScript == compiler.compile(b).executionScript)

    var compact = typedContext()
    compact.filters.relativeDays = 21
    compact.filters.datePeriod = .recentCalendar; compact.filters.calendarAge = "1 year, 2 months"
    let active = try compact.modelIntent()
    #expect(active.relativeDays == nil && active.calendarAge == "14 months")
    // Canonical cross-language records may retain explicit empty/default fields.
    let canonical = #"{"mode":"files","date":"recentCalendar","calendarAge":"14 months","dateFrom":"","dateThrough":"","relativeDays":null}"#
    let complete = try SearchIntent.decodeModelOutput(Data(canonical.utf8))
    #expect(complete.calendarAge == active.calendarAge)
}
