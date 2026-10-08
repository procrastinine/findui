@testable import SearchBackend
import Foundation
import Testing
import Darwin
@testable import FindUI

private func adversarialRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-adversarial-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test(arguments: [false, true]) func incrementalSnapshotsMatchFreshBuildForWhitelistedHiddenDirectories(includeHidden: Bool) async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try Data("!.kept/\n!.kept/**\n".utf8).write(to: root.appendingPathComponent(".ignore"))
    let service = IndexService()
    let initial = try await service.buildIndex(name: "Before", scope: root, includeHidden: includeHidden)
    let added = root.appendingPathComponent(".kept")
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    try Data("needle".utf8).write(to: added.appendingPathComponent("file.txt"))
    let update = try await service.refreshIndex(.init(metadata: initial.metadata, entries: initial.entries),
        changes: [.init(path: added.path, recursive: true)])
    let fresh = try await service.buildIndex(name: "After", scope: root, includeHidden: includeHidden)
    #expect(fresh.entries.contains { $0.relativePath == ".kept/file.txt" } == includeHidden)
    #expect(Set(update.entries.map(\.relativePath)) == Set(fresh.entries.map(\.relativePath)))
}

@Test func incrementalSnapshotsKeepDepthRelativeToOriginalRoot() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let traversal = SearchTraversalOptions(minimumDepth: 3, maximumDepth: 4)
    let service = IndexService()
    let initial = try await service.buildIndex(name: "Before", scope: root, includeHidden: false, traversal: traversal)
    let added = root.appendingPathComponent("new")
    try FileManager.default.createDirectory(at: added.appendingPathComponent("child/deeper"), withIntermediateDirectories: true)
    for path in ["shallow.txt", "child/deep.txt", "child/deeper/last.txt"] {
        try Data("needle".utf8).write(to: added.appendingPathComponent(path))
    }
    let update = try await service.refreshIndex(.init(metadata: initial.metadata, entries: initial.entries),
        changes: [.init(path: added.path, recursive: true)])
    let fresh = try await service.buildIndex(name: "After", scope: root, includeHidden: false, traversal: traversal)
    #expect(Set(update.entries.map(\.relativePath)) == Set(fresh.entries.map(\.relativePath)))
}

@Test(arguments: [false, true]) func hiddenControlsOverrideWhitelistsAcrossFiltersRulesPreparedWordsAndSnapshots(includeHidden: Bool) async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let kept = root.appendingPathComponent(".kept")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    let file = kept.appendingPathComponent("document.txt")
    try Data("needle".utf8).write(to: file)
    try Data("!.kept/\n!.kept/**\n".utf8).write(to: root.appendingPathComponent(".ignore"))
    let expected = includeHidden ? [file.path] : []
    var request = SearchRequest(query: "needle", mode: .contents, scope: root, includeHidden: includeHidden,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    let service = SearchService()
    #expect(try await service.search(request: request).results.map(\.path) == expected)
    request.refinements.name = ".txt"
    #expect(try await service.search(request: request).results.map(\.path) == expected)
    try request.state.promoteToRules()
    #expect(try await service.search(request: request).results.map(\.path) == expected)
    let report = try await SearchExplainer(tools: service.tools).explain(request, file: file)
    #expect(report.steps.allSatisfy { $0.passed } == includeHidden)
    let index = try await IndexService().buildIndex(name: "Whitelist", scope: root, includeHidden: includeHidden)
    var files = SearchRequest(query: "document", mode: .files, scope: root, includeHidden: includeHidden,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    #expect(try await service.search(request: files).results.map(\.path) == expected)
    files.useIndex = true
    #expect(try await IndexService().search(request: files, index: index.metadata, entries: index.entries).results.map(\.path) == expected)
    let oldCache = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]
    setenv("FINDUI_CACHE_DIRECTORY", root.appendingPathComponent("cache").path, 1)
    defer { if let oldCache { setenv("FINDUI_CACHE_DIRECTORY", oldCache, 1) } else { unsetenv("FINDUI_CACHE_DIRECTORY") } }
    var prepare = request; prepare.buildWordIndex = true
    let command = try SearchPipelineCompiler(tools: service.tools).compile(prepare)
    let built = try await ProcessRunner.run(spec: command.spec, pathOverride: service.tools.searchPath)
    #expect(built.exitCode == 0, "\(built.stderr)")
    request.refinements.wordSearch = true
    var rules = request.state.ruleSet!; rules.contentUnit = .document; request.state.replaceRules(rules)
    #expect(try await service.search(request: request).results.map(\.path) == expected)
}

@Test func savedResultsApplyChangedIgnoreRulesAndExplainTheSameDecision() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("document.txt"), list = root.appendingPathComponent("within.nul")
    try Data("needle".utf8).write(to: file)
    try Data((file.path + "\0").utf8).write(to: list)
    try Data("document.txt\n".utf8).write(to: root.appendingPathComponent(".ignore"))
    var request = SearchRequest(query: "needle", mode: .contents, scope: root, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.state.resultScope = .init(path: list.path, name: "Selected files", count: 1)
    let service = SearchService()
    #expect(try await service.search(request: request).results.isEmpty)
    #expect(try await SearchExplainer(tools: service.tools).explain(request, file: file).steps.last?.passed == false)
    request.traversal.includeIgnored = true
    #expect(try await service.search(request: request).results.map(\.path) == [file.path])
    #expect(try await SearchExplainer(tools: service.tools).explain(request, file: file).steps.allSatisfy { $0.passed })
}

@Test func incrementalSnapshotsPruneIgnoredSubtreesBeforeStartingWalks() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let scope = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    try Data("ignored/\n".utf8).write(to: scope.appendingPathComponent(".ignore"))
    let log = root.appendingPathComponent("calls"), wrapper = root.appendingPathComponent("worker")
    var tools = Toolchain.resolve(); let worker = try #require(tools.contentWorker)
    let script = "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$1\" >> \(SearchPipelineCompiler.command(log.path, []))\nexec \(SearchPipelineCompiler.command(worker.path, [])) \"$@\"\n"
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    tools.contentWorker = wrapper
    let service = IndexService(tools: tools)
    let initial = try await service.buildIndex(name: "Before", scope: scope, includeHidden: false)
    try Data().write(to: log)
    let added = scope.appendingPathComponent("ignored")
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    for number in 0..<600 { try Data("x".utf8).write(to: added.appendingPathComponent("file-\(number).txt")) }
    let children = (0..<600).map { IndexChange(path: added.appendingPathComponent("file-\($0).txt").path, recursive: false) }
    let update = try await service.refreshIndex(.init(metadata: initial.metadata, entries: initial.entries),
        changes: [.init(path: added.path, recursive: true)] + children)
    #expect(update.entries.isEmpty)
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(!calls.contains("--walk"), "Ignored subtrees must be pruned, not walked and filtered afterwards: \(calls)")
}

@Test func explicitSnapshotExplanationUsesFrozenEntriesAfterDeletion() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let scope = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    let file = scope.appendingPathComponent("record.txt")
    try Data("needle".utf8).write(to: file)
    let service = IndexService()
    let build = try await service.buildIndex(name: "Frozen", scope: scope, includeHidden: false)
    let snapshot = root.appendingPathComponent("snapshot.sqlite")
    try IndexArtifact(metadata: build.metadata, entries: build.entries).save(snapshot)
    try FileManager.default.removeItem(at: file)
    let request = SearchRequest(query: "record", mode: .files, scope: scope, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    let report = try await SearchExplainer(tools: .resolve()).explain(request, file: file, snapshot: snapshot)
    #expect(report.steps.first?.title == "Snapshot")
    #expect(report.steps.allSatisfy { $0.passed })
}

@Test func spotlightExplanationUsesSpotlightInsteadOfALiveResultScope() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("record.txt"), source = root.appendingPathComponent("mdfind")
    try Data("needle".utf8).write(to: file)
    try Data("record.txt\n".utf8).write(to: root.appendingPathComponent(".ignore"))
    let script = "#!/bin/sh\n" + SearchPipelineCompiler.command("/usr/bin/printf", ["%s\\0", file.path]) + "\n"
    try Data(script.utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
    let resolved = Toolchain.resolve()
    let tools = Toolchain(fd: resolved.fd, fzf: resolved.fzf, rg: resolved.rg, find: resolved.find, mdfind: source,
        contentWorker: resolved.contentWorker)
    var request = SearchRequest(query: "record", mode: .files, scope: root, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.source = .spotlight
    #expect(try await SearchService(tools: tools).search(request: request).results.map(\.path) == [file.path])
    let report = try await SearchExplainer(tools: tools).explain(request, file: file)
    #expect(report.steps.allSatisfy { $0.passed })
    #expect(report.steps.first?.title == "Spotlight and search conditions")
}

@Test func canonicalRootAliasesWorkInSavedResultsAndFrozenExplanations() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let file = real.appendingPathComponent("record.txt"), list = root.appendingPathComponent("within.nul")
    try Data("needle".utf8).write(to: file)
    try Data((file.path + "\0").utf8).write(to: list)
    var request = SearchRequest(query: "record", mode: .files, scope: alias, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.state.resultScope = .init(path: list.path, name: "Canonical files", count: 1)
    let response = try await SearchService().search(request: request)
    #expect(response.results.map(\.name) == ["record.txt"], "\(response.commandPreview); \(response.warning ?? "")")
    #expect(try await SearchExplainer(tools: .resolve()).explain(request, file: file).steps.allSatisfy { $0.passed })
    request.state.resultScope = nil
    let build = try await IndexService().buildIndex(name: "Aliased root", scope: alias, includeHidden: false)
    let snapshot = root.appendingPathComponent("snapshot.sqlite")
    try IndexArtifact(metadata: build.metadata, entries: build.entries).save(snapshot)
    try FileManager.default.removeItem(at: file)
    #expect(try await SearchExplainer(tools: .resolve()).explain(request, file: file, snapshot: snapshot).steps.allSatisfy { $0.passed })
}

@Test func metadataReaderDoesNotInventEntriesForFilesThatDisappeared() async throws {
    let root = try adversarialRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let paths = (0..<300).map { root.appendingPathComponent("file-\($0).txt") }
    for (i, path) in paths.enumerated() where i.isMultiple(of: 2) { try Data("needle".utf8).write(to: path) }
    let entries = try await IndexService().indexedEntries(paths.map(\.path), scope: root, followSymlinks: false)
    #expect(Set(entries.map(\.relativePath)) == Set(stride(from: 0, to: 300, by: 2).map { "file-\($0).txt" }))
}
