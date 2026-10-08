@testable import SearchBackend
import SearchCore
import Foundation
import Testing
@testable import FindUI

@Test func ordinaryExportsRegenerateExactlyFromParsedControlsWithoutSourceText() throws {
    let root = FileManager.default.temporaryDirectory
    let compiler = SearchPipelineCompiler(tools: .resolve(includeDocumentReaders: false))
    for mode in [SearchMode.files, .folders, .everything, .contents] {
        for sensitive in [false, true] {
            for text in ["needle", "*.swift", "résumé", SearchState.literalQuery("it's $(literal)"), "name:foo -path:bar"] {
                var request = SearchRequest(query: text, mode: mode, scope: root, includeHidden: false,
                    caseSensitive: sensitive, syntax: .literal, exactNameMatch: false, maxResults: .max)
                if mode == .contents { request.refinements.extensions = "swift,md" }
                let command = try compiler.compile(request).script
                var restored = try CLICommandParser.parse(command, currentDirectory: URL(fileURLWithPath: "/"))
                // This must be interpretation, not a remembered command.
                restored.sourceCommand = nil
                for _ in 0..<3 {
                    let copied = try compiler.compile(restored.makeRequest()).script
                    #expect(copied == command, "\(mode), \(text), case=\(sensitive)")
                    restored = try CLICommandParser.parse(copied, currentDirectory: root)
                    restored.sourceCommand = nil
                }
            }
        }
    }
}

@Test func longGeneratedCommandsUseTheSameParserBudgetForLiveAndSnapshotSearches() throws {
    let root = FileManager.default.temporaryDirectory
    let compiler = SearchPipelineCompiler(tools: .resolve(includeDocumentReaders: false))
    var request = SearchRequest(query: "", mode: .files, scope: root, includeHidden: false,
        caseSensitive: true, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.name = String(repeating: "a", count: 40_000)
    let command = try compiler.compile(request).script
    var restored = try CLICommandParser.parse(command, currentDirectory: root)
    restored.sourceCommand = nil
    #expect(try compiler.compile(restored.makeRequest()).script == command)
    request.useIndex = true
    let snapshot = try HeadlessCLI.searchCommand(request, snapshot: root.appendingPathComponent("names.sqlite"))
    let indexed = try CLICommandParser.parse(snapshot, currentDirectory: root)
    #expect(try compiler.compile(indexed.makeRequest()).script == snapshot)
    #expect(throws: (any Error).self) {
        try CLICommandParser.tokenize(String(repeating: "a", count: CLICommandParser.maximumCommandBytes + 1))
    }
}

@Test func relativeClockAndRequestOptionsSurviveCopyPasteWithoutStaleOverrides() throws {
    let root = FileManager.default.temporaryDirectory
    let compiler = SearchPipelineCompiler(tools: .resolve(includeDocumentReaders: false))
    var request = SearchRequest(query: "needle", mode: .files, scope: root, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max,
        referenceDate: Date(timeIntervalSince1970: 1_700_000_000))
    request.filters.datePeriod = .week
    request.collectStatistics = true
    let initial = try compiler.compile(request)
    let restored = try CLICommandParser.parse(initial.script, currentDirectory: root)
    let later = SearchRequest(state: restored, referenceDate: request.referenceDate.addingTimeInterval(86_400))
    let copied = try compiler.compile(later)
    #expect(copied.script == initial.script)
    #expect(copied.plan == initial.plan)
    var inventory = Toolchain.resolve(includeDocumentReaders: false)
    inventory.pandoc = URL(fileURLWithPath: "/optional/bin/pandoc")
    #expect(try SearchPipelineCompiler(tools: inventory).compile(later).script == initial.script)
    #expect(try compiler.compile(later, includeCommandMetadata: false).plan == initial.plan)
    var edited = later
    edited.query = "different"
    #expect(try compiler.compile(edited).script != initial.script)
    #expect(try compiler.compile(edited).plan.query == edited.normalizedQuery())
    edited.state.sourceCommand = "rg needle; touch /tmp/never-execute-this"
    let safe = try compiler.compile(edited)
    edited.state.sourceCommand = nil
    #expect(try compiler.compile(edited).script == safe.script)
}

@Test func findFallbackAndBrowseExportsHaveExactInverses() throws {
    let root = FileManager.default.temporaryDirectory
    let tools = Toolchain(find: URL(fileURLWithPath: "/usr/bin/find"))
    let compiler = SearchPipelineCompiler(tools: tools)
    var request = SearchRequest(query: "needle", mode: .files, scope: root, includeHidden: false,
        caseSensitive: true, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.traversal.includeIgnored = true
    for browse in [false, true] {
        request.isDirectoryListing = browse
        let original = try compiler.compile(request)
        let restored = try CLICommandParser.parse(original.script, currentDirectory: root)
        let again = try compiler.compile(restored.makeRequest())
        #expect(again.script == original.script)
        #expect(again.plan == original.plan)
        if browse {
            #expect(restored.query.isEmpty && restored.mode == .everything && restored.traversal.maximumDepth == 1)
            var edited = restored; edited.query = "other"
            #expect(try !compiler.compile(edited.makeRequest()).plan.query.files.isTrue)
        }
    }
}

@Test @MainActor func importedExportsStayIdenticalThroughGUIRestorationAndEditing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inverse-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: directory), loadSavedState: false)
    defer { model.stopSearch() }
    let compiler = SearchPipelineCompiler(tools: .resolve(includeDocumentReaders: false))
    for command in ["fd -t f -g '*.swift' -0 | xargs -0 rg -F TODO", "rg -F -e TODO -e FIXME ."] {
        let state = try CLICommandParser.parse(command, currentDirectory: FileManager.default.temporaryDirectory)
        let exported = try compiler.compile(state.makeRequest()).script
        model.restoreSearchState(try CLICommandParser.parse(exported, currentDirectory: FileManager.default.temporaryDirectory))
        #expect(try compiler.compile(model.searchState.makeRequest()).script == exported)
        #expect(!model.searchState.title.contains("# FindUI search v1:"))
        model.includeHidden.toggle()
        #expect(try compiler.compile(model.searchState.makeRequest()).script != exported)
    }
}

@Test func relativeFuzzySearchDoesNotMatchItsScopePrefixAndKeepsDuplicateNames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-needle-\(UUID())")
    let first = root.appendingPathComponent("one"), second = root.appendingPathComponent("two/deeper")
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in [first, second] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("plain.txt"))
        try Data().write(to: folder.appendingPathComponent("needle.txt"))
    }
    var request = SearchRequest(query: "", mode: .files, scope: first, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.path = "needle"; request.refinements.pathMatching = .fuzzy
    request.refinements.additionalScopes = [second.path]
    let found = try await SearchService().search(request: request)
    #expect(Set(found.results.map(\.path)) == Set([first, second].map { $0.appendingPathComponent("needle.txt").path }))
}
