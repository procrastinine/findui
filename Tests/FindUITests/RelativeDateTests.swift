@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func arbitraryDayIntervalsRoundTripWithHistoryAndCommandImport() throws {
    let snapshot = try CLICommandParser.parse("fd -t f -e pdf --max-depth 3 --changed-within 20d . /tmp",
        currentDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(snapshot.filters.datePeriod == .recentDays)
    #expect(snapshot.filters.relativeDays == 20)
    #expect(snapshot.traversal.maximumDepth == 3)
    #expect(snapshot.activeFilterDescriptions.contains("Modified: Last 20 days"))
    let restored = try JSONDecoder().decode(SearchSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(restored.filters == snapshot.filters)
    #expect(restored.traversal.maximumDepth == 3)
    let find = try CLICommandParser.parse("find /tmp -type f -mtime -20", currentDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(find.filters.relativeDays == 20)
    let old = Data(#"{"minimumSize":"","maximumSize":"","dateField":"modified","datePeriod":"week","dateFrom":0,"dateThrough":0}"#.utf8)
    let oldFilters = try JSONDecoder().decode(SearchFilters.self, from: old)
    #expect(oldFilters.datePeriod == .week && oldFilters.relativeDays == nil)
}

@Test func rollingIntervalsUseElapsedDaysAcrossDaylightSaving() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12)))
    let bounds = try SearchFilters(datePeriod: .recentDays, relativeDays: 20).validated(now: now, calendar: calendar)
    #expect(bounds.from == now.addingTimeInterval(-20 * 86_400))
    #expect(bounds.before == now)
    #expect(bounds.matches(size: nil, modifiedAt: now.addingTimeInterval(-19 * 86_400), createdAt: nil))
    #expect(!bounds.matches(size: nil, modifiedAt: now.addingTimeInterval(-21 * 86_400), createdAt: nil))
    for invalid in [0, -1, 10_001] {
        #expect(throws: (any Error).self) { try SearchFilters(datePeriod: .recentDays, relativeDays: invalid).validated() }
    }
}
