@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

private struct DeadlineExceeded: Error {}

private func withinDeadline<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private struct SearchFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-tests-\(UUID().uuidString)")
        for directory in ["docs", "docs-backup"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for name in ["report", "report-draft", "docs/needle.txt", "docs-backup/needle.txt", " spaced\nname.txt "] {
            try Data("🙂 café needle NEEDLE\nsecond line\n".utf8).write(to: root.appendingPathComponent(name))
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func request(_ query: String, exact: Bool = false, scope: URL? = nil, limit: Int = 300,
                 syntax: SearchSyntax = .literal, mode: SearchMode = .files) -> SearchRequest {
        SearchRequest(query: query, mode: mode, scope: scope ?? root, includeHidden: true, caseSensitive: false,
                      syntax: syntax, exactNameMatch: exact, maxResults: limit, indexedFilter: .files)
    }
}

private let fallbackTools = Toolchain(fd: nil, fzf: nil, rg: Toolchain.resolve().rg,
                                      find: URL(fileURLWithPath: "/usr/bin/find"), mdfind: nil)

@Test func processDrainsLargeStdoutAndStderrWithoutDeadlock() async throws {
    let execution = try await withinDeadline {
        try await ProcessRunner.run(spec: CommandSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "/bin/dd if=/dev/zero bs=1048576 count=1; /bin/dd if=/dev/zero bs=1048576 count=1 >&2; echo COMPLETED >&2"
        ]), pathOverride: "/usr/bin:/bin")
    }
    #expect(execution.exitCode == 0)
    #expect(execution.stdout.utf8.count == 1_048_576)
    #expect(execution.stderr.utf8.count <= 1_048_576 + 128)
    #expect(execution.stderr.contains("Additional search diagnostics omitted"))
    #expect(execution.stderr.hasSuffix("COMPLETED\n"))
}

@Test func processCancellationTerminatesProducer() async throws {
    try await withinDeadline {
        let task = Task {
            try await ProcessRunner.run(spec: CommandSpec(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                          arguments: ["30"]), pathOverride: "/usr/bin:/bin")
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process unexpectedly succeeded")
        } catch is CancellationError {}
    }
}

@Test func streamStopsProducerAfterEnoughRecords() async throws {
    let execution = try await withinDeadline {
        try await ProcessRunner.stream(spec: CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                                         arguments: ["match"]), pathOverride: "/usr/bin:/bin") { _ in false }
    }
    #expect(execution.stoppedEarly)
}

@Test func streamCleansUpWhenConsumerThrows() async throws {
    try await withinDeadline {
        do {
            _ = try await ProcessRunner.stream(spec: CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                                                 arguments: []), pathOverride: "/usr/bin:/bin") { _ in
                throw DeadlineExceeded()
            }
            Issue.record("Expected consumer error")
        } catch is DeadlineExceeded {}
    }
}

private func checkParity(tools: Toolchain) async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let indexService = IndexService(tools: tools)
    let build = try await indexService.buildIndex(name: "Fixture", scope: fixture.root, includeHidden: true)
    #expect(build.metadata.fileCount == 5)
    #expect(build.entries.contains { $0.relativePath == " spaced\nname.txt " })
    let live = SearchService(tools: tools)
    let requests = [
        fixture.request("path:docs"),
        fixture.request("report", exact: true),
        fixture.request("-draft"),
        fixture.request("ext:txt path:docs"),
        fixture.request("needle", scope: fixture.root.appendingPathComponent("docs")),
        fixture.request("name:\" spaced\nname.txt \"", exact: true),
        fixture.request("r(eport|ubbish)", syntax: .regex),
        fixture.request("report", exact: true, syntax: .regex),
    ]
    let expectedCounts = [2, 1, 4, 2, 1, 1, 2, 1]
    for (request, expected) in zip(requests, expectedCounts) {
        let response = try await live.search(request: request)
        let indexed = try await indexService.search(request: request, index: build.metadata, entries: build.entries)
        #expect(response.results.count == expected, "Unexpected count for \(request.query)")
        #expect(response.results.map(\.path).sorted() == indexed.results.map(\.path).sorted(),
                "Live/index mismatch for \(request.query)")
    }
}

@Test func findFallbackMatchesIndexIncludingRegexAndUnusualNames() async throws {
    try await checkParity(tools: fallbackTools)
}

@Test(.enabled(if: Toolchain.resolve().fd != nil))
func fdMatchesIndexIncludingPathExactAndExclusionOnlyQueries() async throws {
    try await checkParity(tools: .resolve())
}

@Test func scopeUsesDirectoryBoundariesAndAbsolutePaths() throws {
    #expect(SearchPath.contains(URL(fileURLWithPath: "/work/docs/a"), in: URL(fileURLWithPath: "/work/docs")))
    #expect(!SearchPath.contains(URL(fileURLWithPath: "/work/docs-backup/a"), in: URL(fileURLWithPath: "/work/docs")))
    #expect(SearchPath.relativePath(of: URL(fileURLWithPath: "/work/a"), in: URL(fileURLWithPath: "/")) == "work/a")
    #expect(SearchPath.relativePath(of: URL(fileURLWithPath: "/work"), in: URL(fileURLWithPath: "/work")) == "")
}

@Test func findErrorsAreNotTreatedAsEmptyResults() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let tools = Toolchain(fd: nil, fzf: nil, rg: nil, find: URL(fileURLWithPath: "/usr/bin/false"), mdfind: nil, contentWorker: nil)
    await #expect(throws: SearchServiceError.self) {
        try await SearchService(tools: tools).search(request: fixture.request("report"))
    }
    await #expect(throws: SearchServiceError.self) {
        try await IndexService(tools: tools).buildIndex(name: "Failed", scope: fixture.root, includeHidden: true)
    }
}

@Test func invalidFilenameRegexFailsBeforeReturningResults() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    await #expect(throws: (any Error).self) {
        try await SearchService(tools: fallbackTools).search(request: fixture.request("(", syntax: .regex))
    }
}

@Test(arguments: [0, 1, 2, 5, 10])
func liveResultLimitReportsOnlyActualTruncation(limit: Int) async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let result = try await SearchService(tools: fallbackTools).search(request: fixture.request("-nothing-excluded", limit: limit))
    #expect(result.results.count == min(limit, 5))
    #expect(result.isTruncated == (limit < 5))
}

@Test(arguments: [0, 1, 300, 1200, 1300])
func indexedStreamingEnforcesLimitWithoutDroppingFinalBatch(limit: Int) async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let entries = (0..<1200).map { IndexedEntry(relativePath: "report-\($0).txt", kind: .file) }
    let index = ManagedIndex(id: UUID(), name: "Fixture", scopePath: fixture.root.path, includeHidden: true,
                            createdAt: .now, updatedAt: .now, fileCount: 1200, folderCount: 0, entryCount: 1200, engineName: "test")
    let collector = SearchResultCollector()
    let summary = try await IndexService().streamSearch(request: fixture.request("report", limit: limit),
                                                       index: index, entries: entries) { await collector.append($0) }
    let results = await collector.results
    #expect(results.count == min(limit, 1200))
    #expect(Set(results.map(\.path)).count == results.count)
    #expect(summary.isTruncated == (limit < 1200))
}

@Test func indexedDirectoryEntriesRemainNavigable() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let service = IndexService(tools: fallbackTools)
    let index = try await service.buildIndex(name: "Fixture", scope: fixture.root, includeHidden: true)
    let collector = SearchResultCollector()
    _ = try await service.streamDirectoryListing(scope: fixture.root, index: index.metadata, entries: index.entries,
                                                includeHidden: true) { await collector.append($0) }
    let folders = await collector.results.filter { $0.kind == .folder }
    #expect(folders.count == 2)
    #expect(folders.allSatisfy { $0.isBrowsableDirectoryEntry && $0.displayName.hasSuffix("/") })
}

@Test func bestMatchPromotesExactNamesAheadOfPrefixesAndSubstrings() {
    let request = SearchRequest(query: "report", mode: .files, scope: URL(fileURLWithPath: "/tmp"),
                                includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: 10)
    let results = SearchService().parseNameSearchOutput("/tmp/my-report\0/tmp/report-draft\0/tmp/report\0", request: request)
    #expect(results.sorted(by: SearchResult.bestMatchFirst).map(\.name) == ["report", "report-draft", "my-report"])
}

@Test(.enabled(if: Toolchain.resolve().rg != nil))
func contentFiltersDoNotBecomeTextPatternsAndAllTermsAreHighlighted() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let service = SearchService()
    let filtered = try await service.search(request: fixture.request("path:docs ext:txt", mode: .contents))
    #expect(filtered.results.count == 4)
    let matches = try await service.search(request: fixture.request("café needle path:docs", mode: .contents))
    #expect(matches.results.count == 2)
    #expect(matches.results.allSatisfy { $0.snippetMatchRanges == [3..<7, 8..<14, 15..<21] && $0.lineNumber == 1 })
    let regex = try await service.search(request: fixture.request("needle", syntax: .regex, mode: .contents))
    #expect(regex.results.first?.snippetMatchRanges == [8..<14, 15..<21])
    let rustRegex = try await service.search(request: fixture.request("(?P<word>needle)", syntax: .regex, mode: .contents))
    #expect(rustRegex.results.count == regex.results.count)
}

@Test func highlightRangesHandleUnicodeAndOverlappingTerms() {
    #expect(ContentMatchRanges.utf16Range(in: "🙂 café needle", byteStart: 11, byteEnd: 17) == 8..<14)
    #expect(ContentMatchRanges.utf16Range(in: "🙂", byteStart: 1, byteEnd: 3) == nil)
    #expect(ContentMatchRanges.literal(in: "report", query: "report port", caseSensitive: false) == [0..<6])
}

@Test func editorLinksEscapeSpecialCharactersAndKeepTheLineNumber() throws {
    let file = URL(fileURLWithPath: "/tmp/a #?%: café.txt")
    for editor in SourceEditor.allCases where editor != .automatic {
        let link = try #require(editor.fileURL(file, line: 42))
        #expect(link.path == file.path + ":42")
        #expect(link.query == nil && link.fragment == nil)
        #expect(link.absoluteString.contains("%23"))
        #expect(link.absoluteString.contains("%3F"))
        #expect(link.absoluteString.contains("%25"))
        #expect(link.absoluteString.contains("%3A"))
    }
}

@Test func oldSavedSettingsStillDecodeWithAutomaticEditor() throws {
    let data = Data(#"{"managedIndexes":[],"history":[]}"#.utf8)
    let library = try JSONDecoder().decode(PersistedLibrary.self, from: data)
    #expect(library.preferredEditor == .automatic)
}

@Test func partialIndexKeepsItsWarning() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let helper = fixture.root.appendingPathComponent("partial-scan")
    try Data("#!/bin/sh\nprintf 'Permission denied: protected directory\\n' >&2\nexit 0\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let tools = Toolchain(fd: helper, fzf: nil, rg: nil, find: nil, mdfind: nil, contentWorker: nil)
    let build = try await IndexService(tools: tools).buildIndex(name: "Partial", scope: fixture.root, includeHidden: true)
    #expect(build.metadata.warning?.contains("Permission denied") == true)
    let response = try await IndexService().search(request: fixture.request("report"), index: build.metadata, entries: build.entries)
    #expect(response.warning == build.metadata.warning)
}

@MainActor
@Test(arguments: [false, true])
func failedOrCancelledRefreshPreservesSavedIndex(cancel: Bool) async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let helper = fixture.root.appendingPathComponent("scan")
    let script = cancel ? "#!/bin/sh\nexec /bin/sleep 30\n" : "#!/bin/sh\nexit 1\n"
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let tools = Toolchain(fd: helper, fzf: nil, rg: nil, find: nil, mdfind: nil, contentWorker: nil)
    let storage = AppPersistence(baseDirectory: fixture.root.appendingPathComponent("Saved"))
    let entries = [IndexedEntry(relativePath: "report", kind: .file)]
    let oldIndex = ManagedIndex(id: UUID(), name: "Fixture", scopePath: fixture.root.path, includeHidden: true,
                               createdAt: .now, updatedAt: .now, fileCount: 1, folderCount: 0, entryCount: 1, engineName: "test")
    try await storage.saveEntries(entries, for: oldIndex.id)
    try await storage.saveLibrary(PersistedLibrary(selectedDrivePath: fixture.root.path,
                    defaultSearchDirectoryPath: fixture.root.path, managedIndexes: [oldIndex]))
    let model = SearchViewModel(service: SearchService(tools: tools), persistence: storage)
    model.availableVolumes = [StorageVolume(url: fixture.root, name: "Fixture")]
    for _ in 0..<200 where model.managedIndexes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try #require(model.selectedManagerIndex?.id == oldIndex.id)
    model.buildIndexForSelectedManagerDrive()
    if cancel {
        try await Task.sleep(for: .milliseconds(50))
        model.cancelIndexBuild()
    }
    for _ in 0..<200 where model.isBuildingIndex { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isBuildingIndex)
    #expect(model.selectedManagerIndex?.id == oldIndex.id)
    #expect(try await storage.loadEntries(for: oldIndex.id) == entries)
    #expect(try await storage.loadLibrary().managedIndexes.first?.id == oldIndex.id)
    if cancel { #expect(model.indexManagerStatusMessage.contains("cancelled")) }
}

@Test func exactRegexDoesNotAcceptATrailingNewline() throws {
    let matcher = try NameQueryMatcher(query: "report", syntax: .regex, caseSensitive: false, exactNameMatch: true)
    #expect(matcher.rank(name: "report\n", path: "/tmp/report\n", relativePath: nil, fileExtension: "") == nil)
}
