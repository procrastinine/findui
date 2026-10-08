@testable import SearchBackend
import AppKit
import Foundation
import Testing
@testable import FindUI

private struct ContinuationFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-continuation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func file(_ name: String, text: String = "needle\n") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func context() -> SearchSnapshot {
        SearchSnapshot(query: "", mode: .files, scopePath: root.path, useIndex: false, includeHidden: false,
            caseSensitive: false, syntax: .literal, exactNameMatch: false, selectedDrivePath: nil, indexedFilter: .files)
    }
}

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<600 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for search state")
}

@Test(arguments: [SearchSyntax.literal, .fuzzy])
@MainActor
func interactiveSearchStreamsBeyond300AndKeepsSelection(syntax: SearchSyntax) async throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    for number in 0..<420 { try fixture.file("needle-a-\(number).txt") }
    let last = try fixture.file("needle-z-last.txt")
    let helper = try fixture.file("producer", text: """
    #!/bin/sh
    root=\(shellQuote(fixture.root.path))
    for file in "$root"/needle-a-*.txt; do printf '%s\\0' "$file"; done
    /bin/sleep 1
    printf '%s\\0' "$root/needle-z-last.txt"
    """)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let tools = Toolchain(fd: helper, fzf: Toolchain.resolve().fzf, rg: nil, find: nil, mdfind: nil, contentWorker: nil)
    let model = SearchViewModel(service: SearchService(tools: tools),
        persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    model.query = "needle"
    model.syntax = syntax
    model.refinements.fuzzyFullPath = false
    model.scheduleSearch(immediate: true)
    if syntax == .fuzzy {
        // fzf ranks the entire candidate set before producing globally ordered hits.
        try await waitFor { model.isSearching }
        try await waitFor { model.results.count == 421 && !model.isSearching }
    } else {
        try await waitFor { model.results.count >= 420 }
        #expect(model.isSearching)
        #expect(model.results.count == 420)
    }
    let selected = try #require(model.results.last)
    model.selectResult(selected)
    try await waitFor { !model.isSearching }
    #expect(model.results.count == 421)
    #expect(model.results.contains { $0.url == last })
    #expect(model.selectedResultIDs == [selected.id])
    #expect(!model.statusMessage.contains("limit"))
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    model.copyCommandPreview(to: clipboard)
    #expect(clipboard.string(forType: .string) == model.nativeCommand)
    #expect(model.transientFooterMessage == "Copied command.")
}

@Test @MainActor
func stoppingAnUncappedSearchPreservesLoadedResultsAndRejectsLateChunks() async throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    let first = try fixture.file("needle-first.txt")
    let late = try fixture.file("needle-late.txt")
    let helper = try fixture.file("producer", text: """
    #!/bin/sh
    for arg do [ "$arg" = absent ] && exit 0; done
    printf '%s\\0' \(shellQuote(first.path))
    /bin/sleep 1
    printf '%s\\0' \(shellQuote(late.path))
    """)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let model = SearchViewModel(service: SearchService(tools: Toolchain(fd: helper, fzf: nil, rg: nil, find: nil, mdfind: nil, contentWorker: nil)),
        persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    model.query = "needle"
    model.scheduleSearch(immediate: true)
    try await waitFor { model.results.count == 1 }
    model.stopSearch()
    #expect(!model.isSearching)
    #expect(model.results.map(\.url) == [first])
    try await Task.sleep(for: .milliseconds(1200))
    #expect(model.results.map(\.url) == [first])
    model.query = "absent"
    model.scheduleSearch(immediate: true)
    try await waitFor { model.results.isEmpty && !model.isSearching }
    #expect(model.results.isEmpty)
}

@Test(.enabled(if: Toolchain.resolve().rg != nil))
@MainActor
func contentSearchLoadsEveryMatchingLineBeyond300() async throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    try fixture.file("many.txt", text: (1...740).map { "needle \($0)\n" }.joined())
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")),
        loadSavedState: false)
    model.scopeURL = fixture.root
    model.mode = .contents
    model.query = "needle"
    model.scheduleSearch(immediate: true)
    try await waitFor { model.results.count >= 740 && !model.isSearching }
    #expect(model.results.count == 740)
    #expect(model.results.map(\.lineNumber).compactMap { $0 }.max() == 740)
    #expect(!model.statusMessage.contains("limit"))
}

private actor ResultBatches {
    var counts: [Int] = []
    var results: [SearchResult] = []
    func append(_ batch: [SearchResult]) { counts.append(batch.count); results += batch }
}

@Test(arguments: [SearchSyntax.literal, .fuzzy])
func indexAndHistoryRequestsContinueWithoutAnImplicitCap(syntax: SearchSyntax) async throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    for number in 0..<620 { try fixture.file("needle-\(number).txt") }
    let service = IndexService()
    let build = try await service.buildIndex(name: "Fixture", scope: fixture.root, includeHidden: false)
    var snapshot = fixture.context()
    snapshot.query = "needle"
    snapshot.syntax = syntax
    let request = snapshot.makeRequest()
    #expect(request.maxResults == .max)
    let batches = ResultBatches()
    let summary = try await service.streamSearch(request: request, index: build.metadata, entries: build.entries) {
        await batches.append($0)
    }
    #expect(await batches.results.count == 620)
    #expect(await batches.counts.first == 1)
    #expect(await batches.counts.count > 1)
    #expect(!summary.isTruncated)
}

@Test @MainActor
func cliTranslationAppliesOptionsAndBuildsTheCommandDeterministically() async throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    let wanted = try fixture.file("project/code.swift", text: "before\nconnection refused\nafter\n")
    try fixture.file("project/code.txt", text: "connection refused\n")
    try fixture.file("build/code.swift", text: "connection refused\n")
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")),
        loadSavedState: false)
    model.scopeURL = fixture.root
    if Toolchain.resolve().rg == nil { return }
    let command = #"rg --fixed-strings --ignore-case --hidden --glob '*.swift' --glob '!**/build/**' 'connection refused' ."#
    try model.importCommand(command)
    #expect(model.mode == .contents)
    #expect(model.contentsInput == "connection refused")
    #expect(!model.caseSensitive)
    #expect(model.searchState.sourceCommand == command)
    try await waitFor { !model.results.isEmpty && !model.isSearching }
    #expect(model.results.map(\.url) == [wanted])
}

@Test func cliSizeDateAndExtensionTranslationPreservesConditions() throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    let draft = CLISearchDraft(tool: .fd, pattern: "backup", scopePath: ".", options: [
        .init(flag: "--type", value: "f"), .init(flag: "--fixed-strings"), .init(flag: "--ignore-case"),
        .init(flag: "--extension", value: "pdf"), .init(flag: "--extension", value: "txt"),
        .init(flag: "--size", value: "+500m"), .init(flag: "--size", value: "-1gi"),
        .init(flag: "--changed-within", value: "7d"), .init(flag: "--exclude", value: "build/")
    ])
    let proposal = try draft.plan().validated(context: fixture.context(), tools: .resolve())
    let filters = try proposal.snapshot.filters.validated()
    #expect(filters.minimumSize == 500_000_000)
    #expect(filters.maximumSize == 1_073_741_824)
    #expect(proposal.snapshot.filters.datePeriod == .week)
    #expect(proposal.snapshot.query == #"name:"backup" ext:pdf;txt"#)
    #expect(proposal.snapshot.traversal.excludedFolders == [".git", "build"])
}

@Test func quotedContentCannotBecomeQuerySyntaxOrShellSyntax() throws {
    let text = #"name:secret $(touch /tmp/never-create-this) "quoted" \path"#
    let plan = try CLISearchDraft(tool: .rg, pattern: text, scopePath: ".", options: [.init(flag: "--fixed-strings")]).plan()
    let parsed = ParsedSearchQuery.parseLiteral(plan.query)
    #expect(parsed.tokens.count == 1)
    #expect(parsed.tokens.first?.field == .any)
    #expect(parsed.tokens.first?.value == text)
    let matcher = SearchQueryMatcher(query: plan.query, caseSensitive: false, exactNameMatch: false)
    #expect(matcher.matchesContentCandidate(name: "file.txt", path: "/file.txt", snippet: text))
    #expect(!matcher.matchesContentCandidate(name: "secret", path: "/secret", snippet: "unrelated"))
}

@Test(arguments: [false, true])
func translatedFullPathMatchesParentsWithLiveAndIndexedSearch(useFD: Bool) async throws {
    let resolved = Toolchain.resolve()
    if useFD && resolved.fd == nil { return }
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    let wanted = try fixture.file("foo/bar/memo.txt")
    try fixture.file("other/bar/memo.txt")
    try fixture.file("foo/bar/image.png")
    let tools = Toolchain(fd: useFD ? resolved.fd : nil, fzf: nil, rg: resolved.rg,
                          find: URL(fileURLWithPath: "/usr/bin/find"), mdfind: nil)
    let plan = try CLISearchDraft(tool: .fd, pattern: "foo/bar", scopePath: ".", options: [
        .init(flag: "--type", value: "f"), .init(flag: "--fixed-strings"),
        .init(flag: "--full-path"), .init(flag: "--ignore-case"),
        .init(flag: "--extension", value: "txt")
    ]).plan()
    #expect(plan.query == #"path:"foo/bar" ext:txt"#)
    #expect(plan.scopePath == ".")
    let proposal = try plan.validated(context: fixture.context(), tools: tools)
    let request = proposal.snapshot.makeRequest()
    let live = try await SearchService(tools: tools).search(request: request)
    #expect(live.results.map(\.url) == [wanted])
    let service = IndexService(tools: tools)
    let index = try await service.buildIndex(name: "Path fixture", scope: fixture.root, includeHidden: false)
    let indexed = try await service.search(request: request, index: index.metadata, entries: index.entries)
    #expect(indexed.results.map(\.url) == [wanted])
}

@Test func fullPathDoesNotSilentlyChangeMatchingOrContentSearch() throws {
    for matching in ["--exact", "--glob"] {
        #expect(throws: SearchServiceError.self) {
            try CLISearchDraft(tool: .fd, pattern: "foo/bar", scopePath: ".", options: [
                .init(flag: "--type", value: "f"), .init(flag: matching), .init(flag: "--full-path")
            ]).plan()
        }
    }
    #expect(throws: SearchServiceError.self) {
        try CLISearchDraft(tool: .rg, pattern: "foo/bar", scopePath: ".", options: [
            .init(flag: "--fixed-strings"), .init(flag: "--full-path")
        ]).plan()
    }
}

@Test func unsupportedCommandsAndInvalidValuesNeverBecomeSearches() throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    for flag in ["--exec", "--exec-batch", "-delete", "-exec", "|", ";"] {
        let draft = CLISearchDraft(tool: .fd, pattern: "report", scopePath: ".", options: [.init(flag: flag)])
        #expect(throws: SearchServiceError.self) { try draft.plan() }
    }
    let context = fixture.context()
    for plan in [
        NaturalSearchPlan(mode: .contents, syntax: .fuzzy, query: "abc"),
        NaturalSearchPlan(query: "\"unfinished"),
        NaturalSearchPlan(query: "abc", scopePath: "nonexistent-folder"),
        NaturalSearchPlan(query: "abc", minimumSize: "2 GB", maximumSize: "1 MB"),
        NaturalSearchPlan(query: "abc", datePeriod: .custom, dateFrom: "2026-02-31", dateThrough: "2026-03-01")
    ] {
        #expect(throws: (any Error).self) { try plan.validated(context: context, tools: .resolve()) }
    }
}

@Test func naturalSearchKeepsOnlyCompatibleEnabledFilenameIndexes() throws {
    let fixture = try ContinuationFixture()
    defer { fixture.remove() }
    let tools = Toolchain(fd: URL(fileURLWithPath: "/fixture/fd"), fzf: nil,
        rg: URL(fileURLWithPath: "/fixture/rg"), find: nil, mdfind: nil)
    let service = IndexService(tools: tools)
    let plan = NaturalSearchPlan(query: "ext:pdf", includeHidden: false, includeIgnored: false)
    let proposal = try plan.validated(context: fixture.context(), tools: tools)
    var index = ManagedIndex(id: UUID(), name: "Fixture", scopePath: fixture.root.path,
        includeHidden: false, createdAt: .now, updatedAt: .now, fileCount: 0, folderCount: 0,
        entryCount: 0, engineName: "fd", traversal: .init())
    let indexed = proposal.preservingIndexPreference(true, index: index, service: service)
    #expect(indexed.snapshot.useIndex)
    #expect(indexed.executionNote.contains("snapshot updated"))
    #expect(indexed.command.contains("scoped to"))
    #expect(!proposal.preservingIndexPreference(false, index: index, service: service).snapshot.useIndex)
    #expect(!proposal.preservingIndexPreference(true, index: nil, service: service).snapshot.useIndex)

    index.traversal = SearchTraversalOptions(includeIgnored: true)
    let incompatible = proposal.preservingIndexPreference(true, index: index, service: service)
    #expect(!incompatible.snapshot.useIndex)
    #expect(incompatible.executionNote.contains("does not cover"))
    index.traversal = .init()
    index.scopePath = fixture.root.appendingPathComponent("elsewhere").path
    #expect(!proposal.preservingIndexPreference(true, index: index, service: service).snapshot.useIndex)

    index.scopePath = fixture.root.path
    let hidden = try NaturalSearchPlan(query: "ext:pdf", includeHidden: true, includeIgnored: false)
        .validated(context: fixture.context(), tools: tools)
    #expect(!hidden.preservingIndexPreference(true, index: index, service: service).snapshot.useIndex)
    let contents = try NaturalSearchPlan(mode: .contents, query: "needle", includeHidden: false, includeIgnored: false)
        .validated(context: fixture.context(), tools: tools)
    #expect(!contents.preservingIndexPreference(true, index: index, service: service).snapshot.useIndex)
}
