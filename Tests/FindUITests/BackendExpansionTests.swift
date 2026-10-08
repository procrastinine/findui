@testable import SearchBackend
import Foundation
import Testing
import Darwin
@testable import FindUI

private func expansionRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("findui-expansion-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func expansionRequest(_ root: URL) -> SearchRequest {
    SearchRequest(query: "", mode: .files, scope: root, includeHidden: true, caseSensitive: false,
                  syntax: .literal, exactNameMatch: false, maxResults: .max)
}
private func writeTags(_ values: [String], to file: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    let status = data.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0) }
    #expect(status == 0)
}

@Test func archiveNamesUseMetadataWithoutEnablingConversionAndCopiedCommandsAgree() async throws {
    let root = try expansionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("report.txt"), archive = root.appendingPathComponent("reports.zip")
    try Data("bodymarker\n".utf8).write(to: source)
    let zip = try await ProcessRunner.run(spec: .init(executable: URL(fileURLWithPath: "/usr/bin/zip"),
        arguments: ["-q", "-j", archive.path, source.path]), pathOverride: Toolchain.resolve().searchPath)
    #expect(zip.exitCode == 0)
    var request = expansionRequest(root)
    request.refinements.useContentIndex = false
    request.state.replaceRules(.init(files: .all([]), contents: .rule(.metadata(.member, "report")), contentUnit: .document))
    #expect(request.refinements.extraction == nil)
    let result = try await SearchService().search(request: request)
    #expect(result.results.count == 1)
    #expect(result.results.first?.extractedOrigin?.metadataOnly == true)
    #expect(result.results.first?.extractedOrigin?.memberPath == "report.txt")
    let copied = try await ProcessRunner.run(spec: SearchPipeline.command(result.commandPreview), pathOverride: Toolchain.resolve().searchPath)
    #expect(copied.exitCode == 0)
    #expect(copied.stdout.contains("\"metadataOnly\":true"))
    #expect(!copied.stdout.contains("bodymarker"))
    request.refinements.extraction = .init(); request.refinements.extraction?.archives = true
    request.refinements.extraction?.cacheText = false
    var rules = request.state.ruleSet!
    rules.contents = .all([.rule(.metadata(.member, "report")), .rule(.literal("bodymarker"))])
    request.state.replaceRules(rules)
    let expanded = try await SearchService().search(request: request)
    #expect(expanded.results.count == 1 && expanded.results.first?.extractedOrigin?.metadataOnly == false)
}

@Test func historicalConversionDefaultsAreClearedButNewExplicitChoicesPersist() throws {
    var request = expansionRequest(URL(fileURLWithPath: "/tmp"))
    request.refinements.extraction = .init(); request.refinements.extraction?.archives = true
    let entry = SearchHistoryEntry(id: UUID(), snapshot: request.state, searchedAt: .now,
        resultCount: 1, engineName: "fixture", isPinned: true, pinOrder: 0)
    let library = PersistedLibrary(history: [entry])
    let data = try JSONEncoder().encode(library)
    let current = try JSONDecoder().decode(PersistedLibrary.self, from: data)
    #expect(current.history[0].snapshot.refinements.extraction?.archives == true)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "explicitConversionChoices")
    let migrated = try JSONDecoder().decode(PersistedLibrary.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated.history[0].snapshot.refinements.extraction == nil)
    #expect(migrated.history[0].isPinned && migrated.history[0].snapshot.scopePath == "/tmp")
}

@Test func finderTagsWorkWithoutSpotlightAndShareLiveGroupedAndSnapshotSemantics() async throws {
    let root = try expansionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let tagged = root.appendingPathComponent("tagged.txt"), other = root.appendingPathComponent("other.txt")
    try Data("needle".utf8).write(to: tagged); try Data("needle".utf8).write(to: other)
    try writeTags(["Research\n4", "café, notes\n0"], to: tagged)
    #expect(FileMetadata.finderTags(tagged) == ["Research", "café, notes"])
    let built = try await IndexService().buildIndex(name: "Tags", scope: root, includeHidden: true)
    for (tags, matching, expected) in [(["research", "cafe\u{301}, notes"], TagMatch.all, [tagged.path]),
                                      (["Research", "Absent"], .any, [tagged.path]), (["Research"], .none, [other.path])] {
        var request = expansionRequest(root); request.refinements.finderTags = tags; request.refinements.tagMatch = matching
        let live = try await SearchService().search(request: request)
        #expect(live.results.map(\.path).sorted() == expected.sorted())
        let copied = try await ProcessRunner.run(spec: SearchPipeline.command(live.commandPreview), pathOverride: Toolchain.resolve().searchPath)
        #expect(copied.exitCode == 0 && copied.stdout.split(separator: "\0").map(String.init).sorted() == expected.sorted())
        try request.state.promoteToRules()
        #expect(try await SearchService().search(request: request).results.map(\.path).sorted() == expected.sorted())
        request.useIndex = true
        let indexed = try await IndexService().search(request: request, index: built.metadata, entries: built.entries)
        #expect(indexed.results.map(\.path).sorted() == expected.sorted())
    }
    try writeTags(["Updated\n2"], to: tagged)
    let refreshed = try await IndexService().refreshIndex(.init(metadata: built.metadata, entries: built.entries), changes: [.init(path: tagged.path, recursive: false)])
    #expect(refreshed.entries.first { $0.relativePath == tagged.lastPathComponent }?.tags == ["Updated"])
    #expect(refreshed.metadata.queryGeneration != built.metadata.queryGeneration)
}

@Test func snapshotGenerationsReusePreparedBytesAcrossReadersAndProtectActiveGenerations() async throws {
    let root = try expansionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var metadata = ManagedIndex(id: UUID(), name: "Test", scopePath: root.path, includeHidden: true,
        createdAt: .now, updatedAt: .now, fileCount: 2000, folderCount: 0, entryCount: 2000, engineName: "fixture", queryGeneration: UUID())
    let entries = (0..<2000).map { IndexedEntry(relativePath: "odd '\($0)\n.txt", kind: .file, size: Int64($0), tags: ["Tag"]) }
    let cache = SnapshotQueryCache(directory: root.appendingPathComponent("prepared"))
    let first = try await cache.prepare(index: metadata, entries: entries)
    let attributes = try FileManager.default.attributesOfItem(atPath: first.source.path)
    let second = try await cache.prepare(index: metadata, entries: entries)
    #expect(first === second)
    let independent = SnapshotQueryCache(directory: root.appendingPathComponent("prepared"))
    let third = try await independent.prepare(index: metadata, entries: entries)
    #expect(third.source == first.source && third.byPath == first.byPath)
    #expect(try FileManager.default.attributesOfItem(atPath: third.source.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
    metadata.queryGeneration = UUID() // timestamps deliberately identical
    let next = try await cache.prepare(index: metadata, entries: Array(entries.dropLast()))
    #expect(next.source != first.source && next.byPath.count == 1999)
    #expect(FileManager.default.fileExists(atPath: first.source.path), "Active readers retain their previous generation")
    metadata.queryGeneration = UUID()
    let concurrentMetadata = metadata
    async let a = cache.prepare(index: concurrentMetadata, entries: entries)
    async let b = independent.prepare(index: concurrentMetadata, entries: entries)
    let (left, right) = try await (a, b)
    #expect(left.source == right.source && left.byPath == right.byPath)
    metadata.queryGeneration = nil
    var legacyEntries = entries
    let legacy = try await cache.prepare(index: metadata, entries: legacyEntries)
    #expect(try await cache.prepare(index: metadata, entries: legacyEntries) === legacy)
    legacyEntries[0] = .init(relativePath: "changed.txt", kind: .file)
    let changed = try await cache.prepare(index: metadata, entries: legacyEntries)
    #expect(changed.source != legacy.source && changed.byPath[root.appendingPathComponent("changed.txt").path] != nil)
}

@Test func presetsComposeConditionsRestoreScopesAndRoundTripWithoutLosingNewRules() async throws {
    let root = try expansionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var base = expansionRequest(root).state; base.refinements.name = "report"
    var filter = expansionRequest(root).state
    filter.refinements.finderTags = ["Review"]; filter.filters.minimumSize = "2kb"
    let preset = SearchPreset(name: "Review documents", kind: .filter, state: filter)
    let applied = try preset.applying(to: base)
    #expect(applied.refinements.name == "report" && applied.refinements.finderTags == ["Review"] && applied.filters.minimumSize == "2kb")
    var scope = base; scope.scopePath = "/tmp"; scope.refinements.additionalScopes = ["/var/tmp"]; scope.traversal.maximumDepth = 2
    let scoped = try SearchPreset(name: "Folders", kind: .scope, state: scope).applying(to: applied)
    #expect(scoped.criteria == applied.criteria || scoped.refinements.name == applied.refinements.name)
    #expect(scoped.scopePath == "/tmp" && scoped.traversal.maximumDepth == 2 && scoped.refinements.finderTags == ["Review"])
    var search = base
    search.replaceRules(.init(contents: .all([.rule(.proximity(.init(terms: ["alpha", "beta"], distance: 3, ordered: true))), .rule(.metadata(.author, "Ada"))]), contentUnit: .document))
    let complete = SearchPreset(name: "Documents", kind: .search, state: search)
    let store = SearchPresetStore(directory: root)
    try store.change { $0.presets = [preset, complete] }
    #expect(try store.resolve("Documents").applying(to: base) == search)
    #expect(try store.read().presets == [preset, complete])
    #expect(try JSONDecoder().decode(SearchPresetCollection.self, from: JSONEncoder().encode(store.read())).presets == [preset, complete])
}

@Test func resultScopeIncludesEveryPageAndCompiledRefinementCannotEnumerateOtherFiles() async throws {
    let root = try expansionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let found = root.appendingPathComponent("found.txt"), excluded = root.appendingPathComponent("other.txt")
    try Data("needle".utf8).write(to: found); try Data("needle".utf8).write(to: excluded)
    let store = try ResultStore()
    var rows = (0..<1100).map { SearchResult(url: root.appendingPathComponent("missing\($0)"), kind: .file, matchRank: $0, sourceOrder: $0) }
    rows.append(.init(url: found, kind: .file, matchRank: 1100, sourceOrder: 1100))
    rows.append(rows.last!)
    try await store.append(rows)
    let saved = try await store.saveScope(name: "Results", directory: root.appendingPathComponent("scopes"))
    #expect(saved.count == 1101)
    #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)).filter { $0 == 0 }.count == 1101)
    var request = expansionRequest(root); request.state.resultScope = saved; request.refinements.name = "found"
    let result = try await SearchService().search(request: request)
    #expect(result.results.map(\.url) == [found])
    try request.state.promoteToRules()
    #expect(try await SearchService().search(request: request).results.map(\.url) == [found])
    try FileManager.default.removeItem(atPath: saved.path)
    #expect(throws: (any Error).self) { try SearchPipelineCompiler(tools: .resolve()).compile(request) }
}
