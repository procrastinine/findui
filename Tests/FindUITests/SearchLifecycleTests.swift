import Darwin
import Foundation
import SearchCore
import Testing

@testable import SearchBackend

@Test func batchedHighlightOffsetsEqualIndependentReplacementDecoding() {
    let fixtures = [
        Data("\r\nASCII\ttext\0\n".utf8),
        Data("\r\n🙂 café e\u{301} 東京\n".utf8),
        Data([0x61, 0xf0, 0x90, 0x80, 0x62, 0xed, 0xa0, 0x80, 0xc2, 0xff, 0x0a]),
    ]
    for bytes in fixtures {
        let ranges = (0..<bytes.count).flatMap { a in ((a + 1)...bytes.count).map { a..<$0 } }
        for trim in [false, true] {
            let full = String(decoding: bytes, as: UTF8.self)
            let leading =
                trim
                ? full.prefix(while: { $0.unicodeScalars.allSatisfy(CharacterSet.newlines.contains) }).utf16.count : 0
            let count = (trim ? full.trimmingCharacters(in: .newlines) : full).utf16.count
            let expected: [Range<Int>] = ranges.compactMap { range in
                let a = min(
                    count, max(0, String(decoding: bytes.prefix(range.lowerBound), as: UTF8.self).utf16.count - leading)
                )
                let b = min(
                    count, max(0, String(decoding: bytes.prefix(range.upperBound), as: UTF8.self).utf16.count - leading)
                )
                return b > a ? a..<b : nil
            }
            #expect(ContentMatchRanges.utf16Ranges(bytes: bytes, offsets: ranges, trimmingNewlines: trim) == expected)
        }
    }
}

@Test func snippetWindowsStayBoundedAndKeepUnicodeMatches() {
    let text = String(repeating: "🙂 café ", count: 20_000) + "needle"
    let match = (text.utf16.count - 6)..<text.utf16.count
    let window = SnippetWindow(text: text, ranges: [match])
    #expect(window.shortened && window.text.utf16.count <= 1_204)
    #expect(window.text.hasSuffix("needle") && !window.text.contains("�"))
    #expect(window.ranges.last!.lowerBound <= 82)
    #expect(window.ranges.last?.upperBound == window.text.utf16.count)
}

@Test func pageCacheTracksMembershipAcrossRankAndUserSort() async throws {
    let url = URL(fileURLWithPath: "/fixture/needle")
    func row(_ rank: Int, _ name: String = "needle") -> SearchResult {
        SearchResult(
            url: url.deletingLastPathComponent().appendingPathComponent(name), kind: .file, matchRank: rank,
            sourceOrder: rank)
    }
    let store = try ResultStore()
    try await store.append((0..<1_000).map { row($0) })
    let original = try await store.page(0)
    let revision = await store.pageRevision
    try await store.append((1_000..<3_000).map { row($0) })
    #expect(try await store.page(0) == original)
    #expect(await store.pageRevision == revision)
    #expect(await store.decodedRowCount == 1_000)
    let first = row(-1)
    try await store.append([first])
    #expect(try await store.page(0).first == first)
    #expect(await store.pageRevision != revision)
    let order = [ResultSort(column: "name", descending: false)]
    _ = try await store.page(0, sort: order)
    let before = await store.pageRevision
    try await store.append([row(4_000, "zzz")])
    _ = try await store.page(0, sort: order)
    #expect(await store.pageRevision == before)
    let earlier = row(5_000, "aaa")
    try await store.append([earlier])
    #expect(try await store.page(0, sort: order).first == earlier)
}

@Test func directoryListingExportAndPresentationHaveIdenticalMembership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-listing-contract-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("ignored.txt\n".utf8).write(to: root.appendingPathComponent(".ignore"))
    for name in ["visible.txt", "ignored.txt", "new\nline.txt"] {
        try Data().write(to: root.appendingPathComponent(name))
    }
    let service = SearchService()
    for hidden in [false, true] {
        let rows = SearchResultCollector()
        let summary = try await service.streamDirectoryListing(scope: root, includeHidden: hidden) {
            await rows.append($0)
        }
        let copied = try await ProcessRunner.run(
            spec: SearchPipeline.command(summary.commandPreview), pathOverride: service.tools.searchPath)
        #expect(copied.exitCode == 0)
        let exported = Set(copied.stdout.split(separator: "\0").map(String.init))
        let presented = Set(await rows.results.map(\.path))
        #expect(exported == presented)
        #expect(await rows.results.contains { $0.name == "ignored.txt" })
        #expect(await !rows.results.contains { $0.name == ".git" })
    }
}

@Test func indexIdentityDoesNotChangeWhenMissingCacheIsCreated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-identity-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("cache/child").path
    let before = canonicalIdentityPath(path)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    #expect(canonicalIdentityPath(path) == before)
}

@Test func multilineUsesNativeRipgrepAndSurvivesControlsAndCommandImport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-multiline-\(UUID())")
        .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("before\nalpha café\nbeta 🙂\nafter\n".utf8).write(to: root.appendingPathComponent("text.txt"))
    var request = SearchRequest(
        query: #"alpha[^\n]*\nbeta"#, mode: .contents, scope: root, includeHidden: false,
        caseSensitive: false, syntax: .regex, exactNameMatch: false, maxResults: .max)
    request.refinements.multiline = true
    let tools = Toolchain.resolve()
    let pipeline = try SearchPipelineCompiler(tools: tools).compile(request)
    #expect(pipeline.plan.direct?.executable == tools.rg?.path)
    #expect(pipeline.plan.direct?.arguments.contains("--multiline") == true)
    let imported = try CLICommandParser.parse(pipeline.script, currentDirectory: root)
    #expect(imported.refinements.multiline == true)
    let response = try await SearchService(tools: tools).search(request: request)
    let row = try #require(response.results.first)
    #expect(row.lineNumber == 2 && row.snippet?.contains("\n") == true)
    let preview = try await ContentPreviewReader.readShared(
        url: row.url, lineNumber: 2, expectedSnippet: row.snippet, radius: 1, encoding: nil)
    #expect(preview.warning == nil)
    #expect(preview.lines.map(\.number) == [1, 2, 4])
    var state = request.state
    try state.promoteToRules()
    #expect(state.refinements.multiline == true)
    let roundTrip = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(state))
    #expect(roundTrip.refinements.multiline == true)
}

@Test func customReaderConfigurationSharesLiteralArgumentsAndRejectsConflicts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-reader-config-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReaderConfiguration(location: root.appendingPathComponent("readers.json"))
    let reader = ReaderAdapter(
        id: "fixture", title: "Example", extensions: ["custom"], executable: "/usr/bin/printf",
        arguments: ["%s", "{path}", "$(touch should-not-run)"])
    try store.update { $0.append(reader) }
    #expect(try store.load() == [reader])
    var conflicting = reader
    conflicting.id = "other"
    #expect(throws: (any Error).self) { try store.update { $0.append(conflicting) } }
    #expect(try store.load() == [reader])
    try store.update {
        $0[0].enabled = false
        $0.append(conflicting)
    }
    #expect(try store.load().filter(\.enabled) == [conflicting])
}

@Test func ingestionFailureStopsProducerWithoutWaitingForCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-ingestion-error-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let producer = root.appendingPathComponent("producer")
    try Data("#!/bin/sh\nprintf '%s\\0' /fixture/file\n/bin/sleep 8\n".utf8).write(to: producer)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: producer.path)
    let tools = Toolchain(fd: producer, contentWorker: nil)
    let request = SearchRequest(
        query: "file", mode: .files, scope: root, includeHidden: false, caseSensitive: false, syntax: .literal,
        exactNameMatch: false, maxResults: .max)
    let start = ContinuousClock.now
    do {
        _ = try await SearchService(tools: tools).streamSearch(request: request) { _ in
            throw SearchServiceError.commandFailed("fixture storage failure")
        }
        Issue.record("Expected the consumer error")
    } catch { #expect(error.localizedDescription.contains("fixture storage failure")) }
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func preparedTagMatchesRetainMetadataForFacets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-tag-projection-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("needle.txt")
    try Data("needle\n".utf8).write(to: file)
    let tag = "FindUI Projection Fixture"
    let bytes = try PropertyListSerialization.data(fromPropertyList: [tag + "\n0"], format: .binary, options: 0)
    #expect(
        bytes.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0)
        } == 0)
    var request = SearchRequest(
        query: "needle", mode: .files, scope: root, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.finderTags = [tag]
    let tools = Toolchain.resolve()
    let collector = SearchResultCollector()
    _ = try await PreparedSearch(request: request, tools: tools).stream(tools: tools) { await collector.append($0) }
    let rows = await collector.results
    #expect(rows.count == 1 && rows.first?.tags == [tag])
    #expect(removexattr(file.path, "com.apple.metadata:_kMDItemUserTags", 0) == 0)
    let store = try ResultStore()
    try await store.append(rows)
    #expect(try await store.facets().filter { $0.kind == .tag }.map(\.value) == [tag])
}

@Test func snapshotInspectionPagesAndFiltersWithoutLosingEntries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-inspection-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = (0..<450).map {
        IndexedEntry(relativePath: String(format: "folder/document-%03d.txt", $0), kind: .file, size: Int64($0))
    }
    let metadata = ManagedIndex(
        id: UUID(), name: "Fixture", scopePath: root.path, includeHidden: true,
        createdAt: .now, updatedAt: .now, fileCount: entries.count, folderCount: 0, entryCount: entries.count,
        engineName: "FindUI", traversal: .init(), queryGeneration: UUID())
    let file = root.appendingPathComponent("snapshot.sqlite")
    try IndexArtifact(metadata: metadata, entries: entries).save(file)
    let database = try IndexDatabase(file)
    let pages = try (0..<3).map { try database.page($0) }
    #expect(pages.map { $0.entries.count } == [200, 200, 50])
    #expect(pages.map(\.hasMore) == [true, true, false])
    #expect(pages.flatMap(\.entries).map(\.relativePath) == entries.map(\.relativePath))
    let filtered = try database.page(0, filter: "DOCUMENT-44")
    #expect(filtered.entries.count == 10 && !filtered.hasMore)
}
