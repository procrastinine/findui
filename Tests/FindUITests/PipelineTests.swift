@testable import SearchBackend
import Foundation
import Testing
import Darwin
@testable import FindUI

@Test func copiedPipelineHandlesMacOSTemporaryRootAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("needle.txt")
    try Data("🙂 café needle NEEDLE\n".utf8).write(to: file)
    var request = SearchRequest(query: "needle", mode: .files, scope: root, includeHidden: true,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    let raw = try await ProcessRunner.run(spec: SearchPipeline.command(pipeline.enumeration), pathOverride: Toolchain.resolve().searchPath)
    let output = try await ProcessRunner.run(spec: pipeline.spec, pathOverride: Toolchain.resolve().searchPath)
    #expect(!raw.stdout.isEmpty)
    #expect(output.exitCode == 0)
    #expect(output.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).standardizedFileURL } == [file.standardizedFileURL])
    request.mode = .contents; request.query = "café needle"
    let content = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    #expect(content.plan.output == .matches)
    let c = try await ProcessRunner.run(spec: content.spec, pathOverride: Toolchain.resolve().searchPath)
    #expect(!c.stdout.isEmpty)
}

private struct PipelineFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func file(_ path: String, _ text: String = "ERROR42 timeout\nERROR42 timeouts\n") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func request(_ query: String = "", mode: SearchMode = .files) -> SearchRequest {
        SearchRequest(query: query, mode: mode, scope: root, includeHidden: true, caseSensitive: false,
            syntax: .literal, exactNameMatch: false, maxResults: .max)
    }
}

/// Execute the actual clipboard string with a shell, rather than checking that
/// its text happens to mention flags. Compare every returned path and line.
private func checkCopiedCommand(_ request: SearchRequest, tools: Toolchain = .resolve()) async throws -> SearchResponse {
    let service = SearchService(tools: tools)
    let response = try await service.search(request: request)
    let execution = try await ProcessRunner.run(spec: CommandSpec(executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: ["-f", "-c", response.commandPreview]), pathOverride: tools.searchPath)
    #expect(execution.exitCode == 0, "\(execution.stderr)")
    if request.producesContentLines {
        let copied = execution.stdout.split(separator: "\n").enumerated().compactMap {
            service.parseRipgrepJSONLine(String($0.element), request: request, sourceOrder: $0.offset, pipelineOutput: true)
        }
        #expect(copied.map { "\($0.path):\($0.lineNumber ?? 0)" }.sorted() == response.results.map { "\($0.path):\($0.lineNumber ?? 0)" }.sorted())
    } else {
        let copied = execution.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        #expect(copied.sorted() == response.results.map(\.path).sorted())
        if request.syntax == .fuzzy { #expect(copied == response.results.map(\.path)) }
    }
    return response
}

@Test func contentsOnlyUsesDirectRipgrepAndNeverCachesMatchingLines() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    try fixture.file("one.txt", "needle\nneedle banned\n")
    try fixture.file(".hidden.txt", "needle\n")
    try fixture.file(".git/private.txt", "needle\n")
    try fixture.file("build[1]/skip.txt", "needle\n")
    var request = fixture.request("needle -banned", mode: .contents)
    request.includeHidden = false
    request.traversal.excludedFolders = [".git", "build[1]"]
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    #expect(pipeline.engineName == "FindUI")
    #expect(pipeline.plan.query.source.freshness == .live)
    #expect(try await checkCopiedCommand(request).results.map(\.name) == ["one.txt"])
    let service = SearchService()
    _ = try await service.streamSearch(request: request) { _ in }
    try fixture.file("one.txt", "no match now\n")
    let collector = SearchResultCollector()
    _ = try await service.streamSearch(request: request) { await collector.append($0) }
    #expect(await collector.results.isEmpty)
    request.refinements.name = "*.txt"; request.refinements.nameMatching = .glob
    let combined = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    #expect(combined.engineName == "FindUI")
    #expect(combined.plan.query.source.freshness == .live)
}

@Test func contentsOnlyNeedsNoFilenameEnumerator() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("one.txt", "needle\n")
    let tools = Toolchain(fd: nil, fzf: nil, rg: Toolchain.resolve().rg, find: nil, mdfind: nil)
    let request = fixture.request("needle", mode: .contents)
    #expect(try await checkCopiedCommand(request, tools: tools).results.map(\.url) == [wanted])
}

@Test func explicitPathPrefixesCompileWithoutAnotherModelDecision() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("src/report.swift")
    try fixture.file("elsewhere/src/report.swift")
    var request = fixture.request()
    request.refinements.path = "./src/*.swift"; request.refinements.pathMatching = .glob
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
    request.refinements.path = wanted.path; request.refinements.pathMatching = .exact
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
    request.refinements.path = "src/report.swift"
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
}

@Test func independentFuzzyNameAndPathThenContentsHaveCopiedParity() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("Sources/SearchViewModel.swift", "needle\n")
    try fixture.file("Sources/SearchViewModel.txt", "other\n")
    try fixture.file("Elsewhere/SearchViewModel.swift", "needle\n")
    var request = fixture.request("needle", mode: .contents)
    request.refinements.name = "srchvm"; request.refinements.nameMatching = .fuzzy
    request.refinements.path = "Sources"; request.refinements.pathMatching = .fuzzy
    request.refinements.extensions = "swift"
    let response = try await checkCopiedCommand(request)
    #expect(response.results.map(\.url) == [wanted])
    #expect(response.engineName == "FindUI + fzf")
    #expect(response.commandPreview.components(separatedBy: "--filter").count == 3)
}

@Test func fuzzyRankSurvivesParallelContentSearches() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    try fixture.file("report.txt", String(repeating: "unrelated data\n", count: 300_000) + "needle\n")
    try fixture.file("report-final.txt", "needle\n")
    try fixture.file("annual-report-summary.txt", "needle\n")
    var request = fixture.request()
    request.refinements.name = "report"; request.refinements.nameMatching = .fuzzy
    request.refinements.workers = 4
    let ranking = try await SearchService().search(request: request).results.map(\.url)
    request.mode = .contents; request.query = "needle"
    for filesOnly in [false, true] {
        request.refinements.matchingFilesOnly = filesOnly
        let result = try await checkCopiedCommand(request)
        #expect(result.results.map(\.url) == ranking)
    }
}

@Test func literalFolderExclusionsKeepTheirSpaces() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    try fixture.file(" build /one.txt")
    let wanted = try fixture.file("build/two.txt")
    var request = fixture.request()
    request.traversal.excludedFolders = [" build "]
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
}

@Test func lastOpenedUsesSpotlightDatesAndRejectsUnindexedDateFiltering() throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    var request = fixture.request()
    request.refinements.source = .spotlight
    request.filters.dateField = .lastOpened
    request.filters.datePeriod = .week
    let now = Date(timeIntervalSinceReferenceDate: 812_345_678)
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(request, now: now)
    #expect(pipeline.enumeration.contains("kMDItemLastUsedDate >= \(now.addingTimeInterval(-7 * 86400).timeIntervalSinceReferenceDate)"))
    #expect(pipeline.enumeration.contains("kMDItemLastUsedDate < \(now.timeIntervalSinceReferenceDate)"))
    request.refinements.source = .filesystem
    #expect(throws: (any Error).self) { try SearchPipelineCompiler(tools: .resolve()).compile(request) }
    let bounds = try request.filters.validated(now: now)
    #expect(!bounds.matches(size: 10, modifiedAt: now, createdAt: now))
    #expect(bounds.matches(size: 10, modifiedAt: nil, createdAt: nil, lastOpenedAt: now.addingTimeInterval(-10)))
}

@Test func independentFileFiltersComposeWithContentRegexAndWholeWords() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("src/report-1.swift")
    try fixture.file("src/report-2.txt")
    try fixture.file("src/report-skip.swift")
    try fixture.file("vendor/report-1.swift")
    var request = fixture.request("ERROR[0-9]+", mode: .contents)
    request.syntax = .regex
    request.refinements.name = "report-*"; request.refinements.nameMatching = .glob
    request.refinements.path = "src/**"; request.refinements.pathMatching = .glob
    request.refinements.extensions = "swift,md"; request.refinements.excludedFiles = "*-skip.*"
    request.filters.minimumSize = "10 B"
    let regex = try await checkCopiedCommand(request)
    #expect(regex.results.map(\.url) == [wanted, wanted])
    request.syntax = .literal; request.query = "timeout"; request.refinements.wholeWords = true
    #expect(try await checkCopiedCommand(request).results.map(\.lineNumber) == [1])
    request.refinements.matchingFilesOnly = true
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
}

@Test(arguments: [false, true]) func multipleRootsDepthKindsAndSymlinksHaveCopiedParity(useFD: Bool) async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let one = try fixture.file("one/top.txt")
    let deep = try fixture.file("one/sub/deep.txt")
    let two = try fixture.file("two/top.txt")
    let alias = fixture.root.appendingPathComponent("one/link.txt")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: two)
    let installed = Toolchain.resolve()
    let tools = useFD ? installed : Toolchain(fd: nil, fzf: installed.fzf, rg: installed.rg, find: URL(fileURLWithPath: "/usr/bin/find"), mdfind: nil)
    var request = fixture.request("*", mode: .everything)
    request.scope = fixture.root.appendingPathComponent("one")
    request.refinements.additionalScopes = [fixture.root.appendingPathComponent("two").path, fixture.root.appendingPathComponent("one/sub").path]
    request.traversal.maximumDepth = 1
    let results = try await checkCopiedCommand(request, tools: tools)
    #expect(Set(results.results.map(\.url)) == Set([one, deep, two, fixture.root.appendingPathComponent("one/sub", isDirectory: true)]))
    request.traversal.followSymlinks = true
    #expect(try await checkCopiedCommand(request, tools: tools).results.contains { $0.url == alias })
}

@Test func unicodeAndShellMetacharactersStayData() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let file = try fixture.file("café 'quoted'\n$(touch OWNED).txt", "café $(touch OWNED) 'quotes'\n")
    var request = fixture.request("name:\"café 'quoted'\"")
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [file])
    request.mode = .contents; request.query = #""café" "$(touch OWNED)""#
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [file])
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("OWNED").path))
}

@Test func realFzfRanksAndMissingFzfFailsExplicitly() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    try fixture.file("SearchViewModel.swift")
    let exact = try fixture.file("srchvm.swift")
    try fixture.file("SearchViewModel.txt")
    var request = fixture.request("srchvm ext:swift")
    request.syntax = .fuzzy; request.refinements.fuzzyFullPath = false
    #expect(try await checkCopiedCommand(request).results.first?.url == exact)
    let tools = Toolchain(fd: nil, fzf: nil, rg: nil, find: URL(fileURLWithPath: "/usr/bin/find"), mdfind: nil)
    await #expect(throws: SearchServiceError.self) { try await SearchService(tools: tools).search(request: request) }
    request.syntax = .literal
    #expect(try await SearchService(tools: tools).search(request: request).results.map(\.url) == [exact])
}

@Test func createdAndModifiedDateBoundsAndSnapshotMetadata() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("report.txt")
    var request = fixture.request("report")
    request.filters.dateField = .created; request.filters.datePeriod = .today
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
    request.filters.datePeriod = .before; request.filters.dateFrom = .now
    #expect(try await checkCopiedCommand(request).results.isEmpty)
    request.filters.datePeriod = .custom
    request.filters.dateFrom = .now; request.filters.dateThrough = .now
    let index = try await IndexService().buildIndex(name: "Fixture", scope: fixture.root, includeHidden: true)
    try FileManager.default.removeItem(at: wanted)
    request.refinements.extensions = "txt"
    let snapshot = try await IndexService().search(request: request, index: index.metadata, entries: index.entries)
    #expect(snapshot.results.map(\.url) == [wanted])
    #expect(snapshot.results.first?.createdAt == index.entries.first?.createdAt)
}

@Test func resultStorePagesSortsAndExportsBeyondTheDisplayedPage() async throws {
    let store = try ResultStore()
    let rows = (0..<2_305).map { n in SearchResult(url: URL(fileURLWithPath: "/tmp/result-\(n).txt"), kind: .file,
        size: Int64(n), matchRank: n, sourceOrder: n) }
    try await store.append(rows)
    #expect(await store.count == 2_305)
    #expect(try await store.page(0).count == 1_000)
    #expect(try await store.page(2).count == 305)
    #expect(try await store.page(0, sort: [.init(column: "size", descending: true)]).first?.size == 2_304)
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("findui-export-test-\(UUID()).csv")
    defer { try? FileManager.default.removeItem(at: output) }
    #expect(try await store.exportCSV(to: output, sort: []) == 2_305)
    #expect(try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\r\n").count == 2_307)
}

@Test func everyLiveSearchSeesNewFilesWithoutExplicitRefresh() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    try fixture.file("first.txt")
    let tools = Toolchain.resolve()
    let request = fixture.request("ext:txt")
    func run() async throws -> [SearchResult] {
        let collector = SearchResultCollector()
        _ = try await SearchService(tools: tools).streamSearch(request: request) { await collector.append($0) }
        return await collector.results
    }
    #expect(try await run().count == 1)
    try fixture.file("second.txt")
    #expect(try await run().count == 2)
    #expect(try await run().count == 2)
}

@Test func cancellationTerminatesGrandchildrenThatIgnoreTerm() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let marker = fixture.root.appendingPathComponent("pid")
    let child = try fixture.file("child", "#!/bin/sh\ntrap '' TERM\necho $$ > \(shellQuote(marker.path))\n/bin/sleep 30\n")
    let task = Task {
        try await ProcessRunner.run(spec: CommandSpec(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sh " + shellQuote(child.path) + " & wait"]), pathOverride: "/usr/bin:/bin")
    }
    defer { task.cancel() }
    for _ in 0..<1000 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
    let pid = try #require(Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    let start = ContinuousClock.now
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancellation succeeded unexpectedly") } catch is CancellationError {}
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(kill(pid, 0) != 0)
}

@Test @MainActor func interactiveResultsRetainEveryPageWithBoundedDisplayedRows() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    try fixture.file("many.txt", (1...2_305).map { "needle \($0)\n" }.joined())
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("settings")), loadSavedState: false)
    model.scopeURL = fixture.root; model.query = "needle"; model.mode = .contents
    model.scheduleSearch(immediate: true)
    for _ in 0..<600 {
        #expect(model.results.count <= ResultStore.pageSize)
        if model.totalResultCount == 2_305 && !model.isSearching { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.totalResultCount == 2_305)
    #expect(model.resultPageCount == 3)
    #expect(model.results.count == 1_000)
    model.showResultPage(2)
    for _ in 0..<300 {
        if model.results.count == 305 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.results.count == 305)
    #expect(model.results.last?.lineNumber == 2_305)
    #expect(model.statusMessage.contains("2305") || model.statusMessage.contains("2,305"))
    model.stopSearch()
}

@Test func spotlightSourceUsesTheSamePredicatesAndMarksCoverage() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("report.txt")
    let other = try fixture.file("report.pdf")
    let mdfind = try fixture.file("mdfind", "#!/bin/sh\nprintf '%s\\0' \(shellQuote(wanted.path)) \(shellQuote(other.path))\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mdfind.path)
    let tools = Toolchain(fd: nil, fzf: nil, rg: nil, find: nil, mdfind: mdfind)
    var request = fixture.request("report"); request.refinements.source = .spotlight
    request.refinements.extensions = "txt"
    let response = try await checkCopiedCommand(request, tools: tools)
    #expect(response.results.map(\.url) == [wanted])
    #expect(response.warning?.contains("Spotlight") == true)
}

@Test func clearingDefaultGitExclusionAppliesToLiveAndSnapshots() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let gitFile = try fixture.file(".git/needle.txt")
    var request = fixture.request("needle")
    request.traversal.includeIgnored = true
    #expect(try await checkCopiedCommand(request).results.isEmpty)
    request.traversal.excludedFolders = []
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [gitFile])
    let index = try await IndexService().buildIndex(name: "Fixture", scope: fixture.root, includeHidden: true, traversal: request.traversal)
    #expect(try await IndexService().search(request: request, index: index.metadata, entries: index.entries).results.map(\.url) == [gitFile])
}

@Test func exactFilenameDoesNotTurnIndependentPathContainsIntoExactPath() async throws {
    let fixture = try PipelineFixture(); defer { fixture.remove() }
    let wanted = try fixture.file("src/nested/report.swift")
    try fixture.file("other/report.swift")
    var request = fixture.request("report.swift")
    request.exactNameMatch = true
    request.refinements.fileQuery = "path:src"
    #expect(try await checkCopiedCommand(request).results.map(\.url) == [wanted])
    request.mode = .contents; request.exactNameMatch = false; request.query = ""
    request.refinements.wholeWords = true
    #expect(try await checkCopiedCommand(request).results.count == 2)
}

@Test func legacyTraversalPreservesItsImplicitGitExclusion() throws {
    let old = try JSONDecoder().decode(SearchTraversalOptions.self, from: Data(#"{"includeIgnored":true,"excludedFolders":["build"]}"#.utf8))
    #expect(old.normalized.excludedFolders == [".git", "build"])
    let cleared = SearchTraversalOptions(includeIgnored: true, excludedFolders: [])
    #expect(try JSONDecoder().decode(SearchTraversalOptions.self, from: JSONEncoder().encode(cleared)).excludedFolders.isEmpty)
}
