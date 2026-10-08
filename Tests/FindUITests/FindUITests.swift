@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func fdFallbackIsPreferredWhenAvailable() throws {
    let builder = SearchCommandBuilder(
        tools: Toolchain(
            fd: URL(fileURLWithPath: "/opt/homebrew/bin/fd"),
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind"), contentWorker: nil
        )
    )

    let spec = try builder.preparedCommand(
        for: SearchRequest(
            query: "report",
            mode: .files,
            scope: URL(fileURLWithPath: "/tmp"),
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: true,
            maxResults: 200
        )
    )

    #expect(spec.engineName == "fd")
    #expect(spec.preview.contains("/opt/homebrew/bin/fd --print0"))
    #expect(spec.preview.contains("--print0"))
    #expect(spec.preview.contains("report") && spec.preview.contains("--exact"))
}

@Test func findFallbackBuildsNameQuery() throws {
    let builder = SearchCommandBuilder(
        tools: Toolchain(
            fd: nil,
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind"), contentWorker: nil
        )
    )

    let spec = try builder.preparedCommand(
        for: SearchRequest(
            query: "notes",
            mode: .folders,
            scope: URL(fileURLWithPath: "/tmp"),
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: false,
            maxResults: 200, traversal: .init(includeIgnored: true)
        )
    )

    #expect(spec.engineName == "find")
    #expect(spec.preview.contains("/usr/bin/find -P"))
    #expect(spec.preview.contains("-type d"))
    #expect(spec.preview.contains("-print0"))
    #expect(spec.preview.contains("notes"))
}

@Test func smartLiteralQueryExportsEveryFilter() throws {
    let builder = SearchCommandBuilder(
        tools: Toolchain(
            fd: URL(fileURLWithPath: "/opt/homebrew/bin/fd"),
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind"), contentWorker: Toolchain.resolve().contentWorker
        )
    )

    let spec = try builder.preparedCommand(
        for: SearchRequest(
            query: "report -draft ext:md",
            mode: .files,
            scope: URL(fileURLWithPath: "/tmp"),
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: false,
            maxResults: 200
        )
    )

    #expect(spec.engineName == "FindUI")
    #expect(spec.preview.contains("report") && spec.preview.contains("draft"))
    #expect(!spec.preview.contains("refined in app") && spec.preview.contains("--execute"))
}

@Test func ripgrepJsonParsesMatchRows() {
    let service = SearchService(
        tools: Toolchain(
            fd: URL(fileURLWithPath: "/opt/homebrew/bin/fd"),
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind")
        )
    )

    let output = """
    {"type":"begin","data":{"path":{"text":"/tmp/example.txt"}}}
    {"type":"match","data":{"path":{"text":"/tmp/example.txt"},"lines":{"text":"api key = abc\\n"},"line_number":18,"absolute_offset":0,"submatches":[{"match":{"text":"api key"},"start":0,"end":7}]}}
    {"type":"end","data":{"path":{"text":"/tmp/example.txt"},"binary_offset":null,"stats":{"elapsed":{"secs":0,"nanos":1,"human":"0.0s"},"searches":1,"searches_with_match":1,"bytes_searched":10,"bytes_printed":10,"matched_lines":1,"matches":1}}}
    """

    let results = service.parseRipgrepJSON(
        output,
        request: SearchRequest(
            query: "api key",
            mode: .contents,
            scope: URL(fileURLWithPath: "/tmp"),
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: false,
            maxResults: 200
        )
    )

    #expect(results.count == 1)
    #expect(results.first?.url.path == "/tmp/example.txt")
    #expect(results.first?.lineNumber == 18)
    #expect(results.first?.snippet == "api key = abc")
}

@Test func smartLiteralNameSearchFiltersExcludedTerms() throws {
    let service = SearchService(
        tools: Toolchain(
            fd: URL(fileURLWithPath: "/opt/homebrew/bin/fd"),
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind")
        )
    )

    let output = """
    /tmp/report.md
    /tmp/report-draft.md
    /tmp/final-report.txt
    """

    let results = service.parseNameSearchOutput(
        output,
        request: SearchRequest(
            query: "report -draft ext:md",
            mode: .files,
            scope: URL(fileURLWithPath: "/tmp"),
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: false,
            maxResults: 200
        ),
        matcher: try NameQueryMatcher(
            query: "report -draft ext:md",
            caseSensitive: false,
            exactNameMatch: false
        )
    )

    #expect(results.count == 1)
    #expect(results.first?.url.path == "/tmp/report.md")
}

@Test func indexedSearchFindsFileAndFiltersFolders() async throws {
    let service = IndexService(
        tools: Toolchain(
            fd: URL(fileURLWithPath: "/opt/homebrew/bin/fd"),
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind")
        )
    )

    let index = ManagedIndex(
        id: UUID(),
        name: "Macintosh HD",
        scopePath: "/",
        includeHidden: true,
        createdAt: .now,
        updatedAt: .now,
        fileCount: 2,
        folderCount: 1,
        entryCount: 3,
        engineName: "fd"
    )

    let entries = [
        IndexedEntry(relativePath: "example/notes/report.md", kind: .file, modifiedAt: nil, size: 1200),
        IndexedEntry(relativePath: "example/notes", kind: .folder, modifiedAt: nil, size: nil),
        IndexedEntry(relativePath: "example/reporting", kind: .folder, modifiedAt: nil, size: nil),
    ]

    let response = try await service.search(
        request: SearchRequest(
            query: "report",
            mode: .files,
            scope: URL(fileURLWithPath: "/"),
            useIndex: true,
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: false,
            maxResults: 50,
            selectedDrivePath: "/",
            indexedFilter: .files
        ),
        index: index,
        entries: entries
    )

    #expect(response.results.count == 1)
    #expect(response.results.first?.url.path == "/example/notes/report.md")
    #expect(response.engineName == "Snapshot")
}

@Test func indexedSmartLiteralQuerySupportsNegationAndPathFilters() async throws {
    let service = IndexService(
        tools: Toolchain(
            fd: URL(fileURLWithPath: "/opt/homebrew/bin/fd"),
            fzf: nil,
            rg: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            find: URL(fileURLWithPath: "/usr/bin/find"),
            mdfind: URL(fileURLWithPath: "/usr/bin/mdfind")
        )
    )

    let index = ManagedIndex(
        id: UUID(),
        name: "Macintosh HD",
        scopePath: "/",
        includeHidden: true,
        createdAt: .now,
        updatedAt: .now,
        fileCount: 3,
        folderCount: 0,
        entryCount: 3,
        engineName: "fd"
    )

    let entries = [
        IndexedEntry(relativePath: "example/work/report.md", kind: .file, modifiedAt: nil, size: 1200),
        IndexedEntry(relativePath: "example/work/report-draft.md", kind: .file, modifiedAt: nil, size: 800),
        IndexedEntry(relativePath: "example/archive/report.md", kind: .file, modifiedAt: nil, size: 600),
    ]

    let response = try await service.search(
        request: SearchRequest(
            query: "report -draft path:work ext:md",
            mode: .files,
            scope: URL(fileURLWithPath: "/"),
            useIndex: true,
            includeHidden: false,
            caseSensitive: false,
            syntax: .literal,
            exactNameMatch: false,
            maxResults: 50,
            selectedDrivePath: "/",
            indexedFilter: .files
        ),
        index: index,
        entries: entries
    )

    #expect(response.results.count == 1)
    #expect(response.results.first?.url.path == "/example/work/report.md")
}

@MainActor
@Test func quickLookToggleUsesDisplayedOrderWhenNothingIsSelected() {
    let model = makeSearchViewModel()
    let later = makeSearchResult(path: "/tmp/later.txt", sourceOrder: 1)
    let firstDisplayed = makeSearchResult(path: "/tmp/first.txt", sourceOrder: 0)
    let orderedResults = [firstDisplayed, later]

    model.toggleQuickLook(using: orderedResults)

    #expect(model.selectedResultID == firstDisplayed.id)
    #expect(model.quickLookURL == firstDisplayed.url)
}

@MainActor
@Test func quickLookNavigationTracksSelectedMatchWhenURLsRepeat() {
    let model = makeSearchViewModel()
    let firstMatch = makeSearchResult(path: "/tmp/report.md", lineNumber: 12, sourceOrder: 0)
    let secondMatch = makeSearchResult(path: "/tmp/report.md", lineNumber: 24, sourceOrder: 1)
    let nextFile = makeSearchResult(path: "/tmp/summary.md", sourceOrder: 2)
    let orderedResults = [firstMatch, secondMatch, nextFile]

    model.showQuickLook(for: secondMatch)
    model.moveQuickLookSelection(in: orderedResults, by: 1)

    #expect(model.selectedResultID == nextFile.id)
    #expect(model.quickLookURL == nextFile.url)
}

@MainActor
private func makeSearchViewModel() -> SearchViewModel {
    let tools = Toolchain(fd: nil, fzf: nil, rg: nil, find: nil, mdfind: nil)
    return SearchViewModel(
        service: SearchService(tools: tools),
        indexService: IndexService(tools: tools),
        persistence: AppPersistence(),
        loadSavedState: false
    )
}

private func makeSearchResult(path: String, lineNumber: Int? = nil, sourceOrder: Int) -> SearchResult {
    SearchResult(
        url: URL(fileURLWithPath: path),
        kind: lineNumber == nil ? .file : .contentMatch,
        lineNumber: lineNumber,
        matchRank: 0,
        sourceOrder: sourceOrder
    )
}
