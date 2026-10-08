@testable import SearchBackend
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FindUI

private struct FeatureFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-features-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    @discardableResult
    func file(_ name: String, text: String = "before\nneedle café 🙂\nafter\nneedle again\nlast",
              modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func request(_ query: String = "", mode: SearchMode = .files, syntax: SearchSyntax = .literal,
                 limit: Int = 300, filters: SearchFilters = .init(), traversal: SearchTraversalOptions = .init()) -> SearchRequest {
        SearchRequest(query: query, mode: mode, scope: root, includeHidden: true, caseSensitive: false,
                      syntax: syntax, exactNameMatch: false, maxResults: limit,
                      indexedFilter: mode == .folders ? .folders : .files, filters: filters, traversal: traversal)
    }
}

private let findTools = Toolchain(fd: nil, fzf: Toolchain.resolve().fzf, rg: Toolchain.resolve().rg,
                                  find: URL(fileURLWithPath: "/usr/bin/find"), mdfind: nil)

@Test func sizeAndDateFiltersValidateUnitsAndInclusiveCalendarDates() throws {
    #expect(try SearchFilters.bytes("1.5 MB") == 1_500_000)
    #expect(try SearchFilters.bytes("2 MiB") == 2_097_152)
    #expect(try SearchFilters.bytes("0") == 0)
    #expect(try SearchFilters.bytes("10 megabytes") == 10_000_000)
    #expect(try SearchFilters.bytes("100k") == 100_000)
    #expect(try SearchFilters.bytes("1.5 mebibytes") == 1_572_864)
    #expect(try SearchFilters.bytes("0.1 B") == 1)
    #expect(try SearchFilters.bytes("9007199254740993 B") == 9_007_199_254_740_993)
    #expect(try SearchFilters.bytes("9223372036854775807 B") == Int64.max)
    #expect(throws: SearchServiceError.self) { try SearchFilters.bytes("9223372036854775808 B") }
    #expect(try SearchFilters.bytes("  ") == nil)
    for value in ["-1 MB", "NaN", "10 elephants", "1e99", "999999999999999999999 TB"] {
        #expect(throws: SearchServiceError.self) { try SearchFilters.bytes(value) }
    }
    #expect(throws: SearchServiceError.self) { try SearchFilters(minimumSize: "2 MB", maximumSize: "1 MB").validated() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = Date(timeIntervalSince1970: 1_700_006_400)
    let start = calendar.startOfDay(for: day)
    let filters = try SearchFilters(datePeriod: .custom, dateFrom: day, dateThrough: day).validated(calendar: calendar)
    #expect(filters.matches(size: nil, modifiedAt: start, createdAt: nil))
    #expect(filters.matches(size: nil, modifiedAt: start.addingTimeInterval(86_399), createdAt: nil))
    #expect(!filters.matches(size: nil, modifiedAt: start.addingTimeInterval(86_400), createdAt: nil))
    #expect(!filters.matches(size: nil, modifiedAt: nil, createdAt: nil))
    #expect(throws: SearchServiceError.self) {
        try SearchFilters(datePeriod: .custom, dateFrom: day.addingTimeInterval(172_800), dateThrough: day).validated()
    }
}

@Test(arguments: [false, true])
func metadataFiltersRunWithoutAQueryAndBeforeTheResultLimit(useFD: Bool) async throws {
    if useFD && Toolchain.resolve().fd == nil { return }
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    try fixture.file("small.txt", text: "tiny")
    try fixture.file("old.txt", text: String(repeating: "x", count: 120), modified: Date(timeIntervalSince1970: 100))
    let wanted = try fixture.file("recent.txt", text: String(repeating: "needle\n", count: 20))
    let tools = useFD ? Toolchain.resolve() : findTools
    let indexService = IndexService(tools: tools)
    let build = try await indexService.buildIndex(name: "Test", scope: fixture.root, includeHidden: true)
    let filters = SearchFilters(minimumSize: "100 B", maximumSize: "200 B", datePeriod: .week)
    let request = fixture.request(limit: 1, filters: filters)
    let live = try await SearchService(tools: tools).search(request: request)
    let indexed = try await indexService.search(request: request, index: build.metadata, entries: build.entries)
    #expect(live.results.map(\.url) == [wanted])
    #expect(indexed.results.map(\.url) == [wanted])
    #expect(!live.isTruncated)
    #expect(!indexed.isTruncated)
    if tools.rg != nil {
        let content = try await SearchService(tools: tools).search(request: fixture.request("needle", mode: .contents, limit: 1, filters: filters))
        #expect(content.results.map(\.url) == [wanted])
        #expect(content.isTruncated)
    }
}

@Test(arguments: [false, true])
func globAndExtensionGroupsHaveLiveIndexParity(useFD: Bool) async throws {
    if useFD && Toolchain.resolve().fd == nil { return }
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    for name in ["src/report-01.csv", "src/deep/report-AB.CSV", "src/report-long.txt",
                 "src/report-*.csv", "src/other.png", "outside/report-02.csv"] { try fixture.file(name) }
    let tools = useFD ? Toolchain.resolve() : findTools
    let indexService = IndexService(tools: tools)
    let build = try await indexService.buildIndex(name: "Test", scope: fixture.root, includeHidden: true)
    let cases: [(String, Int)] = [
        ("name:report-??.csv", 3),
        ("path:src/**/report-*.csv", 3),
        ("ext:csv;png -name:report-01*", 4),
        (#"name:"report-*.csv""#, 1),
        (#"name:report-\*.csv"#, 1),
        ("name:report-* ext:txt;csv -path:outside/**", 4),
    ]
    for (query, count) in cases {
        let request = fixture.request(query)
        let live = try await SearchService(tools: tools).search(request: request)
        let indexed = try await indexService.search(request: request, index: build.metadata, entries: build.entries)
        #expect(live.results.count == count, "\(query)")
        #expect(live.results.map(\.path).sorted() == indexed.results.map(\.path).sorted(), "\(query)")
    }
    var scoped = fixture.request("path:deep/**")
    scoped.scope = fixture.root.appendingPathComponent("src")
    let live = try await SearchService(tools: tools).search(request: scoped)
    let indexed = try await indexService.search(request: scoped, index: build.metadata, entries: build.entries)
    #expect(live.results.count == 1)
    #expect(live.results.map(\.path) == indexed.results.map(\.path))
}

@Test(.enabled(if: Toolchain.resolve().rg != nil))
func contentTermsStayLiteralWhileFilenameFiltersUseGlobsAndExtensionGroups() async throws {
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    let wanted = try fixture.file("report-one.txt", text: "a*b\nab\nneedle\n")
    try fixture.file("report-two.csv", text: "ab\nneedle\n")
    try fixture.file("other.txt", text: "a*b\n")
    let result = try await SearchService().search(request: fixture.request("a*b name:report-*.txt ext:txt;md", mode: .contents))
    #expect(result.results.map(\.url) == [wanted])
    #expect(result.results.first?.snippet == "a*b")
}

@Test(arguments: [false, true])
func fuzzySearchRanksTheFullScopeBeforeApplyingTheLimit(useFD: Bool) async throws {
    if useFD && Toolchain.resolve().fd == nil { return }
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    try fixture.file("aaaSearchViewModel.swift")
    try fixture.file("SearchViewModel.swift")
    let wanted = try fixture.file("zzz/srchvm.swift")
    try fixture.file("srchvm.txt")
    let tools = useFD ? Toolchain.resolve() : findTools
    let request = fixture.request("srchvm ext:swift", syntax: .fuzzy, limit: 1)
    let indexService = IndexService(tools: tools)
    let build = try await indexService.buildIndex(name: "Test", scope: fixture.root, includeHidden: true)
    let live = try await SearchService(tools: tools).search(request: request)
    let indexed = try await indexService.search(request: request, index: build.metadata, entries: build.entries)
    #expect(live.results.map(\.url) == [wanted])
    #expect(indexed.results.map(\.url) == [wanted])
    #expect(live.isTruncated && indexed.isTruncated)
    #expect(FuzzyFilenameMatcher.rank(term: "vmsearch", name: "searchviewmodel.swift") == nil)
}

@Test(.enabled(if: Toolchain.resolve().fd != nil && Toolchain.resolve().rg != nil))
func ignoreControlsApplyToFilesFoldersContentsAndIndexCoverage() async throws {
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try fixture.file(".gitignore", text: "generated/\n")
    try fixture.file("visible/keep.txt")
    try fixture.file("generated/ignored.txt")
    try fixture.file("node_modules/dependency.txt")
    try fixture.file(".git/internal.txt")
    let tools = Toolchain.resolve()
    let service = SearchService(tools: tools)
    let respecting = try await service.search(request: fixture.request("ext:txt"))
    #expect(Set(respecting.results.map(\.name)) == ["keep.txt", "dependency.txt"])
    let options = SearchTraversalOptions(includeIgnored: true, excludedFolders: [".git", "node_modules"])
    let request = fixture.request("ext:txt", traversal: options)
    let including = try await service.search(request: request)
    #expect(Set(including.results.map(\.name)) == ["keep.txt", "ignored.txt"])
    let contents = try await service.search(request: fixture.request("needle", mode: .contents, traversal: options))
    #expect(Set(contents.results.map(\.name)) == ["keep.txt", "ignored.txt"])
    let folders = try await service.search(request: fixture.request("*", mode: .folders, traversal: options))
    #expect(Set(folders.results.map(\.name)) == ["visible", "generated"])
    let indexService = IndexService(tools: tools)
    let index = try await indexService.buildIndex(name: "Test", scope: fixture.root, includeHidden: true, traversal: options)
    let indexed = try await indexService.search(request: request, index: index.metadata, entries: index.entries)
    #expect(including.results.map(\.path).sorted() == indexed.results.map(\.path).sorted())
    await #expect(throws: SearchServiceError.self) {
        try await indexService.search(request: fixture.request("ext:txt"), index: index.metadata, entries: index.entries)
    }
    let refreshed = try await indexService.buildIndex(name: "Test", scope: fixture.root, includeHidden: true)
    let refreshedResult = try await indexService.search(request: fixture.request("ext:txt"), index: refreshed.metadata, entries: refreshed.entries)
    #expect(Set(refreshedResult.results.map(\.name)) == ["keep.txt", "dependency.txt"])
}

@Test(arguments: [false, true])
func exclusionsAreExactDirectoryNamesAndPreserveSameNamedFiles(useFD: Bool) async throws {
    if useFD && Toolchain.resolve().fd == nil { return }
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    try fixture.file("cache[1]/gone.txt")
    try fixture.file("cache1/keep.txt")
    try fixture.file("file/cache[1]")
    let tools = useFD ? Toolchain.resolve() : findTools
    let options = SearchTraversalOptions(includeIgnored: true, excludedFolders: ["cache[1]"])
    let request = fixture.request("*", traversal: options)
    let results = try await SearchService(tools: tools).search(request: request)
    #expect(Set(results.results.map(\.name)) == ["keep.txt", "cache[1]"])
    let index = try await IndexService(tools: tools).buildIndex(name: "Test", scope: fixture.root, includeHidden: true, traversal: options)
    #expect(Set(index.entries.filter { $0.kind == .file }.map(\.name)) == ["keep.txt", "cache[1]"])
}

@Test func contentPreviewHandlesContextBoundariesBlankLinesAndChangedFiles() throws {
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    let url = try fixture.file("context.txt", text: "first\r\n\r\ncafé 🙂\r\nfour\r\nlast")
    let preview = try ContentPreviewReader.read(url: url, lineNumber: 3, expectedSnippet: "café 🙂")
    #expect(preview.lines.map(\.number) == [1, 2, 3, 4, 5])
    #expect(preview.lines.map(\.text) == ["first", "", "café 🙂", "four", "last"])
    #expect(preview.lines.filter(\.isMatch).map(\.number) == [3])
    #expect(preview.warning == nil)
    #expect(try ContentPreviewReader.read(url: url, lineNumber: 1, radius: 1).lines.map(\.number) == [1, 2])
    #expect(try ContentPreviewReader.read(url: url, lineNumber: 5, expectedSnippet: "old text").warning?.contains("changed") == true)
    #expect(try ContentPreviewReader.read(url: url, lineNumber: 100).warning?.contains("no longer") == true)
    let huge = try fixture.file("huge.txt", text: String(repeating: "x", count: 140_000) + "\ntarget\nend")
    let acrossChunks = try ContentPreviewReader.read(url: huge, lineNumber: 2)
    #expect(acrossChunks.lines.first(where: \.isMatch)?.text == "target")
    let bounded = try ContentPreviewReader.read(url: huge, lineNumber: 2, byteLimit: 1_024)
    #expect(bounded.lines.isEmpty)
    #expect(bounded.warning?.contains("read limit") == true)
}

@Test func exportsPreserveQuotesNewlinesAndUnicodeAndDeduplicateFiles() {
    let url = URL(fileURLWithPath: "/tmp/é,\"file\n.txt")
    let first = SearchResult(url: url, kind: .contentMatch, lineNumber: 2, snippet: "say \"hello\", café",
                             matchRank: 0, sourceOrder: 0)
    let second = SearchResult(url: url, kind: .contentMatch, lineNumber: 4, snippet: "again", matchRank: 0, sourceOrder: 1)
    let parent = SearchResult(url: URL(fileURLWithPath: "/tmp"), kind: .folder, isParentDirectoryEntry: true,
                              matchRank: 0, sourceOrder: 2)
    #expect(ResultExport.uniqueURLs([first, second, parent]) == [url])
    #expect(ResultExport.paths([first, second, parent]) == url.path)
    #expect(ResultExport.matchingLines([first, second]).contains(":4: again"))
    let csv = ResultExport.csv([first, second, parent])
    #expect(csv.contains(#""say ""hello"", café""#))
    #expect(csv.contains("\"/tmp/é,\"\"file\n.txt\""))
    #expect(csv.components(separatedBy: "\r\n").count == 4)
    let groups = ContentResultGroup.groups(from: [second, first])
    #expect(groups.count == 1)
    #expect(groups[0].matches.map(\.lineNumber) == [2, 4])
}

@MainActor
@Test func fileTransferUsesFileURLsAndCopiesEachFileOnlyOnce() async throws {
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    let url = try fixture.file("é space # quote.txt")
    let result = SearchResult(url: url, kind: .contentMatch, lineNumber: 1, matchRank: 0, sourceOrder: 0)
    let provider = ResultTransfer.provider(for: url)
    #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    let data: Data = try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            if let data { continuation.resume(returning: data) }
            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
        }
    }
    #expect(URL(dataRepresentation: data, relativeTo: nil)?.standardizedFileURL == url.standardizedFileURL)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(ResultTransfer.copyFiles([result, result], to: pasteboard))
    let files = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
    #expect(files == [url])
}

@Test func newFilterAndIgnoreSettingsRoundTripAndOldHistoryStillLoads() throws {
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    let filters = SearchFilters(minimumSize: "10 MB", datePeriod: .week)
    let traversal = SearchTraversalOptions(includeIgnored: true, excludedFolders: [".git", "node_modules"])
    let snapshot = SearchSnapshot(query: "srchvm ext:swift", mode: .files, scopePath: fixture.root.path,
        useIndex: true, includeHidden: true, caseSensitive: false, syntax: .fuzzy, exactNameMatch: false,
        selectedDrivePath: "/", indexedFilter: .files, filters: filters, traversal: traversal)
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SearchSnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.makeRequest().filters == filters)
    #expect(decoded.makeRequest().traversal == traversal)
    let old = Data(#"{"query":"report","mode":"files","scopePath":"/tmp"}"#.utf8)
    let legacy = try JSONDecoder().decode(SearchSnapshot.self, from: old)
    #expect(!legacy.filters.isActive)
    #expect(legacy.traversal == .init())
    let library = PersistedLibrary(traversal: traversal)
    #expect(try JSONDecoder().decode(PersistedLibrary.self, from: JSONEncoder().encode(library)).traversal == traversal)
}

@MainActor
@Test(.enabled(if: Toolchain.resolve().rg != nil))
func multiSelectionAndMatchNavigationOperateOnRealSearchResults() async throws {
    let fixture = try FeatureFixture()
    defer { fixture.remove() }
    try fixture.file("one.txt")
    try fixture.file("two.txt")
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")),
                                loadSavedState: false)
    model.scopeURL = fixture.root
    model.query = "needle"
    model.mode = .contents
    model.scheduleSearch(immediate: true)
    for _ in 0..<1000 {
        if !model.results.isEmpty && !model.isSearching { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.results.count == 4, "\(model.statusMessage)")
    let results = model.results.sorted(by: SearchResult.bestMatchFirst)
    let first = try #require(results.first)
    model.selectedResultIDs = Set(results.map(\.id))
    #expect(model.selectedResults.count == 4)
    #expect(ResultExport.uniqueURLs(model.selectedResults).count == 2)
    model.selectResult(first)
    #expect(model.contentMatchPosition == 0)
    model.moveContentMatch(by: 1)
    #expect(model.selectedResults.count == 1)
    #expect(model.selectedResult?.path == first.path)
    #expect(model.selectedResult?.lineNumber == 4)
    model.moveContentMatch(by: 1)
    #expect(model.selectedResult?.lineNumber == 4)
    model.moveContentMatch(by: -1)
    #expect(model.selectedResult?.lineNumber == 2)
}
