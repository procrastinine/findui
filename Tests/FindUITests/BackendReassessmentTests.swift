@testable import SearchBackend
import Foundation
import Testing
import Darwin
@testable import FindUI

private func reassessmentRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-reassessment-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func reassessmentRequest(_ root: URL, query: String = "needle", mode: SearchMode = .contents) -> SearchRequest {
    SearchRequest(query: query, mode: mode, scope: root, includeHidden: true,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
}

@Test func backendMatchesSurviveInvalidUTF8AndRetainRegexOffsets() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("legacy.txt")
    var bytes = Data([0x63, 0x61, 0x66, 0xe9, 0x20]); bytes.append(Data("needle\n".utf8))
    try bytes.write(to: file)
    var request = reassessmentRequest(root)
    request.syntax = .regex
    let service = SearchService()
    let response = try await service.search(request: request)
    #expect(response.results.count == 1)
    let row = try #require(response.results.first)
    #expect(row.snippet == "caf� needle")
    #expect(row.snippetMatchRanges == [5..<11])
    let copied = try await ProcessRunner.run(spec: SearchPipeline.command(response.commandPreview), pathOverride: service.tools.searchPath)
    #expect(copied.exitCode == 0 && copied.stdout.contains("\"type\":\"match\""))
    #expect(response.warning == nil)
}

@Test func ignorePolicyFollowsTheNativeToolAcrossSimpleFilteredGroupedAndSnapshots() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in [("visible.txt", "needle"), ("rg-hidden.txt", "needle"), ("fd-hidden.txt", "needle"),
                         (".rgignore", "rg-hidden.txt\n"), (".fdignore", "fd-hidden.txt\n")] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    let expectedContents = ["visible.txt", "fd-hidden.txt"].map { root.appendingPathComponent($0).path }.sorted()
    let expectedFiles = ["visible.txt", "rg-hidden.txt"].map { root.appendingPathComponent($0).path }.sorted()
    var request = reassessmentRequest(root)
    for variant in 0..<3 {
        if variant == 1 { request.refinements.name = ".txt" }
        if variant == 2 { try request.state.promoteToRules() }
        let result = try await SearchService().search(request: request)
        #expect(result.results.map(\.path).sorted() == expectedContents)
    }
    let files = reassessmentRequest(root, query: ".txt", mode: .files)
    #expect(try await SearchService().search(request: files).results.map(\.path).sorted() == expectedFiles)
    let snapshot = try await IndexService().buildIndex(name: "Ignore parity", scope: root, includeHidden: true)
    var indexed = files; indexed.useIndex = true
    #expect(try await IndexService().search(request: indexed, index: snapshot.metadata, entries: snapshot.entries).results.map(\.path).sorted() == expectedFiles)
}

@Test func followingSymlinksUsesTargetFinderTagsInLiveAndFrozenMetadata() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target.txt"), link = root.appendingPathComponent("link.txt")
    try Data("needle".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let tags = try PropertyListSerialization.data(fromPropertyList: ["Research\n4"], format: .binary, options: 0)
    #expect(tags.withUnsafeBytes { setxattr(target.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0) } == 0)
    var request = reassessmentRequest(root, query: "", mode: .files)
    request.traversal.followSymlinks = true; request.refinements.finderTags = ["Research"]
    let expected = [target.path, link.path].sorted()
    #expect(try await SearchService().search(request: request).results.map(\.path).sorted() == expected)
    let snapshot = try await IndexService().buildIndex(name: "Tags", scope: root, includeHidden: true, traversal: request.traversal)
    request.useIndex = true
    #expect(try await IndexService().search(request: request, index: snapshot.metadata, entries: snapshot.entries).results.map(\.path).sorted() == expected)
}

@Test func statisticsDoNotSelectADifferentSearchBackend() throws {
    var request = reassessmentRequest(FileManager.default.temporaryDirectory)
    let first = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    request.collectStatistics = true
    let measured = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    #expect(first.spec.executable == measured.spec.executable)
    #expect(first.spec.arguments == measured.spec.arguments.filter { $0 != "--stats" })
    #expect(first.engineName == measured.engineName)
    #expect(first.stages.count == measured.stages.count)
    #expect(!first.plan.query.options.useContentIndex)
    #expect(first.engineName == "rg")
}

@Test func sqliteSnapshotsApplyDeltasAndKeepActiveReadersFrozen() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let scope = root.appendingPathComponent("files"); try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    let file = scope.appendingPathComponent("document.txt"); try Data("before".utf8).write(to: file)
    let service = IndexService(), database = root.appendingPathComponent("snapshot.json")
    let build = try await service.buildIndex(name: "Incremental", scope: scope, includeHidden: true)
    let original = IndexArtifact(metadata: build.metadata, entries: build.entries)
    try original.save(database)
    #expect(IndexDatabase.isDatabase(database))
    let loaded = try IndexArtifact.load(database)
    let cache = SnapshotQueryCache(directory: root.appendingPathComponent("queries"))
    let held = try await cache.prepare(index: loaded.metadata, entries: loaded.entries)
    #expect(held.entry(file.path)?.size == 6)
    let noChange = try await service.refreshIndex(loaded, changes: [])
    #expect(noChange.metadata.queryGeneration == loaded.metadata.queryGeneration)
    #expect(noChange.delta?.upserts.isEmpty == true)
    try Data("after a longer edit".utf8).write(to: file)
    let update = try await service.refreshIndex(loaded, changes: [.init(path: file.path, recursive: false)])
    #expect(update.delta?.upserts.count == 1)
    try IndexArtifact(metadata: update.metadata, entries: update.entries, catalog: update.catalog, delta: update.delta).save(database)
    let next = try IndexArtifact.load(database)
    #expect(next.entries.first?.size == 19)
    #expect(held.entry(file.path)?.size == 6)
    let fresh = try await cache.prepare(index: next.metadata, entries: next.entries)
    #expect(fresh.entry(file.path)?.size == 19)
    let metadataOnly = try IndexArtifact.load(database, includeEntries: false)
    #expect(metadataOnly.entries.isEmpty)
    var request = reassessmentRequest(scope, query: "document", mode: .files); request.useIndex = true
    #expect(try await service.search(request: request, index: next.metadata, entries: next.entries).results.first?.size == 19)
    #expect(try await service.search(request: request, index: metadataOnly.metadata, entries: metadataOnly.entries).results.first?.size == 19)
}

@Test func preparedWordSearchUsesTheSameFiltersAndHeadlessCommand() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let old = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]
    setenv("FINDUI_CACHE_DIRECTORY", root.appendingPathComponent("cache").path, 1)
    defer { if let old { setenv("FINDUI_CACHE_DIRECTORY", old, 1) } else { unsetenv("FINDUI_CACHE_DIRECTORY") } }
    let scope = root.appendingPathComponent("files"); try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    for (name,text) in [("one.txt","connecting needle needle\n"),("two.md","needle other\n"),("no-match.txt","haystack\n"),("ignored.txt","needle\n"),(".rgignore","ignored.txt\n")] { try Data(text.utf8).write(to: scope.appendingPathComponent(name)) }
    var prepare = reassessmentRequest(scope)
    prepare.buildWordIndex = true
    let preparation = try SearchPipelineCompiler(tools: .resolve()).compile(prepare)
    let built = try await ProcessRunner.run(spec: preparation.spec, pathOverride: Toolchain.resolve().searchPath)
    #expect(built.exitCode == 0, "\(built.stderr)")
    var request = reassessmentRequest(scope, query: "connect")
    request.refinements.wordSearch = true; request.refinements.stemWords = true
    let response = try await SearchService().search(request: request)
    #expect(response.results.map(\.name) == ["one.txt"])
    #expect(response.results.first?.snippetMatchRanges == [0..<10])
    request.query = "needle"; request.refinements.extensions = "md"
    let filtered = try await SearchService().search(request: request)
    #expect(filtered.results.map(\.name) == ["two.md"])
    let copied = try await ProcessRunner.run(spec: SearchPipeline.command(filtered.commandPreview), pathOverride: Toolchain.resolve().searchPath)
    #expect(copied.exitCode == 0 && copied.stdout.contains("two.md") && !copied.stdout.contains("one.txt"))
    // Ignore changes after preparation still apply without a directory rescan.
    request.refinements.extensions = ""
    try Data("ignored.txt\none.txt\n".utf8).write(to: scope.appendingPathComponent(".rgignore"))
    #expect(try await SearchService().search(request: request).results.map(\.name) == ["two.md"])
    let within = root.appendingPathComponent("within.nul")
    try Data((["two.md", "no-match.txt"].map { scope.appendingPathComponent($0).path }.joined(separator: "\0") + "\0").utf8).write(to: within)
    request.state.resultScope = .init(path: within.path, name: "Saved results", count: 3)
    request.refinements.matchingFilesOnly = true
    #expect(try await SearchService().search(request: request).results.map(\.name) == ["two.md"])
}

@Test @MainActor func indexedWordModeSurvivesSimpleRulesAndOptionReset() throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var state = reassessmentRequest(root).state
    state.refinements.wordSearch = true
    state.refinements.textEncoding = "windows-1252"; state.refinements.stemWords = true
    try state.promoteToRules()
    #expect(state.ruleSet?.contentUnit == .document)
    let compact = try #require(state.compactProjection)
    #expect(compact.refinements.wordSearch == true && compact.query == "needle")
    #expect(compact.refinements.textEncoding == "windows-1252" && compact.refinements.stemWords == true)
    let saved = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(state))
    #expect(saved.refinements == state.refinements)
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    model.restoreSearchState(compact)
    model.resetAdditionalFilters()
    #expect(model.refinements.wordSearch == true)
    model.restoreSearchState(state)
    model.resetAdditionalFilters()
    #expect(model.refinements.wordSearch == true)
}

@Test func explainFileReportsBackendExclusionsAndMatches() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("document.txt"); try Data("needle\n".utf8).write(to: file)
    let explainer = SearchExplainer(tools: .resolve())
    let request = reassessmentRequest(root)
    let match = try await explainer.explain(request, file: file)
    #expect(match.steps.allSatisfy { $0.passed })
    #expect(match.command.contains("--cli explain"))
    try Data("document.txt\n".utf8).write(to: root.appendingPathComponent(".rgignore"))
    let excluded = try await explainer.explain(request, file: file)
    #expect(excluded.steps.count == 1 && excluded.steps.first?.passed == false)
    #expect(excluded.summary.contains("ignore"))
}

@Test func typoAndEncodingOptionsSurviveCommandsAndUseBackendHighlights() async throws {
    let root = try reassessmentRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try Data([0x63,0x61,0x66,0xe9,0x20] + Array("needl\n".utf8)).write(to: root.appendingPathComponent("old.txt"))
    var request = reassessmentRequest(root); request.refinements.textEncoding = "windows-1252"; request.refinements.typoTolerance = 1
    let response = try await SearchService().search(request: request)
    #expect(response.results.first?.snippet == "café needl")
    #expect(response.results.first?.snippetMatchRanges == [5..<10])
    let preview = try await ContentPreviewReader.readShared(url: root.appendingPathComponent("old.txt"), lineNumber: 1,
        expectedSnippet: "café needl", radius: 3, encoding: "windows-1252")
    #expect(preview.lines.first?.text == "café needl" && preview.warning == nil)
    let restored = try SearchCommandExport.restore(response.commandPreview)
    #expect(restored?.refinements.textEncoding == "windows-1252")
    #expect(restored?.refinements.typoTolerance == 1)
    try request.state.promoteToRules()
    let grouped = try await SearchService().search(request: request)
    #expect(grouped.results.first?.snippet == "café needl")
}
