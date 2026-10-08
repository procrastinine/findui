@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

private func enhancementRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-enhancements-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func enhancementRequest(_ root: URL, mode: SearchMode = .files) -> SearchRequest {
    SearchRequest(query: "", mode: mode, scope: root, includeHidden: true, caseSensitive: false,
                  syntax: .literal, exactNameMatch: false, maxResults: .max)
}

@Test func packagePruningAgreesForFDAndFindAndRetainsTheBundleItself() async throws {
    let root = try enhancementRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("Demo.APP/Contents/Resources")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("needle\n".utf8).write(to: nested.appendingPathComponent("inside.txt"))
    try Data("needle\n".utf8).write(to: root.appendingPathComponent("outside.txt"))
    for fd in [Toolchain.resolve().fd, nil] {
        let defaults = Toolchain.resolve()
        let tools = Toolchain(fd: fd, fzf: defaults.fzf, rg: defaults.rg, find: defaults.find, mdfind: nil)
        var request = enhancementRequest(root, mode: .everything)
        request.traversal.includePackageContents = false
        let files = try await SearchService(tools: tools).search(request: request)
        #expect(Set(files.results.map(\.name)) == ["Demo.APP", "outside.txt"])
        request.mode = .contents; request.query = "needle"
        let content = try await SearchService(tools: tools).search(request: request)
        #expect(content.results.map(\.name) == ["outside.txt"])
        request.traversal.includePackageContents = true
        #expect(try await SearchService(tools: tools).search(request: request).results.count == 2)
    }
}

@Test func extractionOptionsSurviveGroupsAndCopiedCommandsAndNeverInventSourceLines() throws {
    var request = enhancementRequest(FileManager.default.temporaryDirectory, mode: .contents)
    request.query = "needle"; request.refinements.extraction = .init()
    request.refinements.extraction?.cacheText = false
    request.refinements.workers = 3
    try request.state.promoteToRules()
    #expect(request.refinements.extraction?.cacheText == false)
    #expect(request.refinements.workers == 3)
    var tools = Toolchain.resolve()
    tools.rgaPreproc = URL(fileURLWithPath: "/opt/homebrew/bin/rga-preproc")
    let command = try SearchPipelineCompiler(tools: tools).compile(request).script
    let restored = try #require(try SearchCommandExport.restore(command))
    #expect(restored.refinements.extraction == request.refinements.extraction)
    let json = #"{"type":"match","data":{"path":{"text":"/tmp/report.pdf"},"lines":{"text":"Page 2: needle"},"line_number":null,"submatches":[],"findui_origin":{"extractor":"rga","line":7,"page":2}}}"#
    let result = try #require(SearchService().parseRipgrepJSONLine(json, request: request, sourceOrder: 0, pipelineOutput: true))
    #expect(result.lineNumber == nil)
    #expect(result.extractedOrigin?.page == 2)
    #expect(ResultExport.matchingLines([result]).contains("Page 2"))
    #expect(request.state.parameterDescription.contains("Parallel workers: 3"))
    #expect(request.state.parameterDescription.contains("Extracted text cache: bypassed"))
    let sheetJSON = #"{"extractor":"rga","line":4,"sheet":"Ledger"}"#
    let origin = try JSONDecoder().decode(ExtractedMatchOrigin.self, from: Data(sheetJSON.utf8))
    #expect(origin.label == "Sheet Ledger · extracted text")
    var archivesOnly = SearchExtractionOptions()
    archivesOnly.documents = false; archivesOnly.archives = true; archivesOnly.useTika = true
    tools.tikaJar = nil
    #expect(try archivesOnly.plan(tools: tools)["tikaJar"] is NSNull)
}

@Test func incrementalIndexMatchesFullBuildAfterEditsRenamesDeletesAndIgnoredCreates() async throws {
    let root = try enhancementRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let initial = root.appendingPathComponent("before.txt")
    try Data("before".utf8).write(to: initial)
    try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".ignore"))
    let service = IndexService()
    let build = try await service.buildIndex(name: "Fixture", scope: root, includeHidden: true)
    let artifact = IndexArtifact(metadata: build.metadata, entries: build.entries)
    let renamed = root.appendingPathComponent("after.txt")
    try FileManager.default.moveItem(at: initial, to: renamed)
    try Data("after with more bytes".utf8).write(to: renamed)
    let added = root.appendingPathComponent("added")
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: added.appendingPathComponent("child.txt"))
    let ignored = root.appendingPathComponent("skip.ignored")
    try Data("ignored".utf8).write(to: ignored)
    let updated = try await service.refreshIndex(artifact, changes: [
        .init(path: initial.path, recursive: false), .init(path: renamed.path, recursive: false),
        .init(path: added.path, recursive: true), .init(path: ignored.path, recursive: false)])
    let full = try await service.buildIndex(name: "Fixture", scope: root, includeHidden: true)
    #expect(Set(updated.entries.map(\.relativePath)) == Set(full.entries.map(\.relativePath)))
    #expect(Dictionary(uniqueKeysWithValues: updated.entries.map { ($0.relativePath, $0.size) }) == Dictionary(uniqueKeysWithValues: full.entries.map { ($0.relativePath, $0.size) }))
    #expect(!updated.entries.contains { $0.relativePath == "skip.ignored" })
}

@Test func indexMaintenancePublishesAtomicGenerationsAndRejectsCompetingWriters() async throws {
    let root = try enhancementRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let files = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    let file = files.appendingPathComponent("before.txt"); try Data("before".utf8).write(to: file)
    let output = root.appendingPathComponent("index.json")
    let config = try JSONDecoder().decode(IndexConfiguration.self, from: Data("{\"scopePath\":\"\(files.path)\"}".utf8))
    let worker = IndexMaintenance(configuration: config, output: output)
    _ = try await worker.rebuild()
    let competing = IndexMaintenance(configuration: config, output: output)
    await #expect(throws: (any Error).self) { _ = try await competing.rebuild() }
    try Data("new file".utf8).write(to: files.appendingPathComponent("new.txt"))
    await worker.enqueue([.init(path: files.appendingPathComponent("new.txt").path, recursive: false)], full: false, event: 42)
    let deadline = Date().addingTimeInterval(6)
    var snapshot = try IndexArtifact.load(output)
    while snapshot.entries.count != 2 && Date() < deadline {
        try await Task.sleep(for: .milliseconds(100)); snapshot = try IndexArtifact.load(output)
    }
    #expect(snapshot.entries.map(\.relativePath) == ["before.txt", "new.txt"])
    await worker.stop()
    _ = try await competing.rebuild()
    await competing.stop()
}

@Test func incrementalIndexHandlesCoalescedFileDirectoryAndSymlinkReplacements() async throws {
    let root = try enhancementRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let item = root.appendingPathComponent("item")
    try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: item.appendingPathComponent("child.txt"))
    let service = IndexService()
    var build = try await service.buildIndex(name: "Fixture", scope: root, includeHidden: true)
    for replacement in ["file", "directory", "symlink"] {
        try FileManager.default.removeItem(at: item)
        if replacement == "file" {
            try Data("replacement".utf8).write(to: item)
        } else if replacement == "directory" {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: item.appendingPathComponent("new.txt"))
        } else {
            try FileManager.default.createSymbolicLink(at: item, withDestinationURL: root)
        }
        build = try await service.refreshIndex(IndexArtifact(metadata: build.metadata, entries: build.entries),
            changes: [.init(path: item.path, recursive: false)])
        let full = try await service.buildIndex(name: "Fixture", scope: root, includeHidden: true)
        #expect(Set(build.entries.map(\.relativePath)) == Set(full.entries.map(\.relativePath)))
        #expect(Dictionary(uniqueKeysWithValues: build.entries.map { ($0.relativePath, $0.size) }) == Dictionary(uniqueKeysWithValues: full.entries.map { ($0.relativePath, $0.size) }))
    }
}
