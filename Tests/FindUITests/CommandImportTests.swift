@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func commandImportComposesFileAndContentPredicates() throws {
    let parsed = try CLICommandParser.parse("fd -t f -g '*.swift' --size +10k --changed-within 7d -H -0 . | xargs -0 rg -F -w -i 'timeout retry'", currentDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(parsed.mode == .contents)
    #expect(parsed.refinements.nameMatching == .regex)
    #expect(parsed.refinements.name.contains("[sS]"))
    #expect(parsed.query == #""timeout retry""#)
    #expect(parsed.refinements.wholeWords)
    #expect(parsed.includeHidden && !parsed.caseSensitive)
    #expect(parsed.filters.minimumSize == "10000 B")
    #expect(parsed.filters.datePeriod == .week)
    #expect(parsed.sourceCommand?.contains("xargs") == true)
    #expect(parsed.scopePath == "/tmp")
}

@Test func directCommandImportsShowAllOptionsAndPreserveQuoting() throws {
    let directory = URL(fileURLWithPath: "/tmp")
    let rg = try CLICommandParser.parse(#"rg --fixed-strings --ignore-case --glob '*.swift' --hidden --max-depth 4 'name:literal -dash' 'a folder' /Users/Shared"#, currentDirectory: directory)
    #expect(rg.query == #""name:literal -dash""#)
    #expect(!rg.caseSensitive)
    #expect(rg.traversal.pathRules == ["*.swift"] && rg.refinements.name.isEmpty)
    #expect(rg.parameterDescription.contains("Include paths: *.swift"))
    #expect(rg.refinements.additionalScopes == ["/Users/Shared"])
    #expect(rg.traversal.maximumDepth == 4)
    let quoted = try CLICommandParser.tokenize(#"fd -F 'it'\''s $(literal)' '/tmp/a folder'"#)
    #expect(quoted[0][2] == "it's $(literal)")
    let find = try CLICommandParser.parse("find . -type f -name '*.pdf' -size +100c -maxdepth 3", currentDirectory: directory)
    #expect(find.filters.minimumSize == "101 B")
    #expect(find.includeHidden && find.traversal.includeIgnored)
    let fuzzy = try CLICommandParser.parse("fd -t f -e swift -0 | fzf --read0 --print0 --no-extended --ignore-case --filter srchvm", currentDirectory: directory)
    #expect(fuzzy.refinements.pathMatching == .fuzzy)
    #expect(fuzzy.refinements.path == "srchvm")
}

@Test(arguments: ["rm -rf .", "fd x; touch /tmp/surprise", "fd $(pwd)", "fd \"$HOME\"", "fd x > out", "fd x && rg y", "fd x | rg y", "fd -0 | xargs -0 sh -c 'touch /tmp/no'", "fd --exec rm", "rg --pre cat x", "fd --hidden=true x", "fd 'open", "fd x |", "find . -delete"])
func unsupportedCommandImportNeverExecutesOrDropsOptions(command: String) {
    #expect(throws: (any Error).self) { try CLICommandParser.parse(command, currentDirectory: URL(fileURLWithPath: "/tmp")) }
}

@Test func importedSizeBoundsRemainExactAndNeverOverflow() throws {
    let base = URL(fileURLWithPath: "/tmp")
    let exact = try CLICommandParser.parse("find . -type f -size 9007199254740993c", currentDirectory: base)
    #expect(exact.filters.minimumSize == "9007199254740993 B")
    #expect(exact.filters.maximumSize == "9007199254740993 B")
    #expect(throws: (any Error).self) {
        try CLICommandParser.parse("find . -size +9223372036854775807c", currentDirectory: base)
    }
}

@Test @MainActor func twoInputsAutomaticallySelectSearchAndPreserveFilenameFilters() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-toggle-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    model.refinements.name = "*.swift"
    model.refinements.nameMatching = .glob
    model.refinements.path = "Sources"
    model.syntax = .regex
    model.contentsInput = "^ERROR"
    #expect(model.mode == .contents)
    model.caseSensitive = true
    #expect(model.refinements.fileCaseSensitive == false)
    model.contentsInput = ""
    #expect(model.mode == .files && model.query.isEmpty)
    #expect(model.refinements.name == "*.swift" && model.refinements.path == "Sources")
    model.contentsInput = "^ERROR"
    #expect(model.query == "^ERROR" && model.syntax == .regex)
    #expect(model.refinements.nameMatching == .glob)
    model.stopSearch()
}

@Test @MainActor func clearingRestoredFilenameExpressionKeepsSharedTraversalAndBroadensCandidates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("restored-rg-\(UUID())")
    let files = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: files.appendingPathComponent("Asset"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Asset/one.txt", "other.txt"] {
        try Data("needle\n".utf8).write(to: files.appendingPathComponent(name))
    }
    // History saves asynchronously and includes the search term. Keep its
    // library outside the searched fixture, regardless of which task wins.
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("state")), loadSavedState: false)
    var snapshot = model.searchState
    snapshot.scopePath = files.path; snapshot.mode = .contents; snapshot.query = "needle"
    snapshot.refinements.extraction = nil // This regression exercises the unfiltered content path.
    snapshot.refinements.fileQuery = "Asset"
    let entry = SearchHistoryEntry(id: UUID(), snapshot: snapshot, searchedAt: .now,
                                  resultCount: 1, engineName: "fd → rg", isPinned: false, pinOrder: nil)
    model.runHistoryEntry(entry)
    #expect(model.filenameInput == "Asset" && model.filenameUsesExpression)
    #expect(model.engineName == "FindUI")
    let before = try await SearchService().search(request: model.searchState.makeRequest())
    #expect(before.results.map(\.name) == ["one.txt"])
    model.filenameInput = ""
    model.scheduleSearch(immediate: true)
    #expect(model.refinements.fileQuery.isEmpty && !model.filenameUsesExpression)
    #expect(model.engineName == "rg")
    #expect(!model.refinements.hasFileConditions)
    let after = try await SearchService().search(request: model.searchState.makeRequest())
    #expect(after.engineName == "rg")
    #expect(Set(after.results.map(\.name)) == ["one.txt", "other.txt"])
    model.stopSearch()
}

@Test @MainActor func restoredRegexUsesPrimaryInputAndKeepsMeaningUntilCleared() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("restored-expression-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    model.refinements.savedFileQuery = .init(text: "^Sources/", syntax: .regex, exactName: false)
    #expect(model.filenameInput == "^Sources/" && model.filenameInputMatching == .expression)
    model.resetAdditionalFilters()
    #expect(model.filenameInput == "^Sources/")
    model.filenameInput = ""
    #expect(model.refinements.savedFileQuery == nil)
    model.refinements.fileQuery = "report"
    model.filenameInputMatching = .pattern(.contains)
    #expect(model.refinements.fileQuery.isEmpty && model.refinements.name == "report")
    #expect(!model.filenameUsesExpression)
    model.stopSearch()
}

@Test @MainActor func contentTogglePreservesLegacyPathRegexMembership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-toggle-\(UUID())")
    let nested = root.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("match\n".utf8).write(to: nested.appendingPathComponent("one.swift"))
    try Data("match\n".utf8).write(to: root.appendingPathComponent("two.swift"))
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = root
    model.query = "^Nested/"
    model.syntax = .regex
    model.refinements.name = "*.swift"
    model.refinements.nameMatching = .glob
    model.contentsInput = "match"
    #expect(model.refinements.savedFileQuery?.text == "^Nested/")
    let snapshot = SearchSnapshot(query: model.query, mode: model.mode, scopePath: root.path,
        useIndex: false, includeHidden: false, caseSensitive: false, syntax: model.syntax,
        exactNameMatch: false, selectedDrivePath: root.path, indexedFilter: .files, refinements: model.refinements)
    let restored = try JSONDecoder().decode(SearchSnapshot.self, from: JSONEncoder().encode(snapshot))
    let response = try await SearchService().search(request: restored.makeRequest())
    #expect(response.results.map(\.name) == ["one.swift"])
    model.stopSearch()
}

@Test @MainActor func restoredHistoryShowsEveryActiveConditionAndKeepsSeparateInputs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-state-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    var snapshot = try CLICommandParser.parse("fd -t f -g '*.swift' --size +10k --changed-within 7d --exclude node_modules/ -0 . | xargs -0 rg -F -w 'timeout'", currentDirectory: root)
    snapshot.refinements.additionalScopes = ["/Users/Shared"]
    snapshot.refinements.excludedFiles = "*.generated.swift"
    let entry = SearchHistoryEntry(id: UUID(), snapshot: snapshot, searchedAt: .now,
                                  resultCount: 4, engineName: "fd → rg", isPinned: false, pinOrder: nil)
    model.runHistoryEntry(entry)
    #expect(model.refinements.name == snapshot.refinements.name && model.contentsInput == "timeout")
    #expect(model.filters.minimumSize == "10000 B" && model.filters.datePeriod == .week)
    let description = model.searchState.parameterDescription
    for value in [snapshot.refinements.name, "timeout", "10000 B", "Last 7 days", "node_modules", "*.generated.swift", "/Users/Shared", "whole words"] {
        #expect(description.contains(value))
    }
    model.resetAdditionalFilters()
    #expect(model.refinements.name == snapshot.refinements.name && model.contentsInput == "timeout")
    #expect(!model.filters.isActive && model.traversal.excludedFolders.isEmpty)
    #expect(model.refinements.additionalScopes.isEmpty && model.refinements.excludedFiles.isEmpty)
    model.stopSearch()
}

@Test @MainActor func importedPipelineExecutesEquivalentSearchAndPersistsHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-import-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in [("one.swift", "timeout retry\nother\n"), ("two.swift", "not a match\n"), ("one.txt", "timeout retry\n")] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    let command = "fd -t f -g '*.swift' -0 | xargs -0 rg -F 'timeout retry'"
    let snapshot = try CLICommandParser.parse(command, currentDirectory: root)
    let response = try await SearchService().search(request: snapshot.makeRequest())
    #expect(response.results.map(\.name) == ["one.swift"])
    #expect(response.results.first?.lineNumber == 1)
    let stored = try JSONDecoder().decode(SearchSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(stored == snapshot)
    #expect(stored.title == command)
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = root
    try model.importCommand(command)
    for _ in 0..<500 where model.history.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.history.first?.snapshot.sourceCommand == command)
    #expect(model.history.first?.snapshot.refinements.name == snapshot.refinements.name)
    model.query = "different"
    model.scheduleSearch(immediate: true)
    for _ in 0..<500 where model.history.first?.snapshot.query != "different" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.history.first?.snapshot.sourceCommand == nil)
    model.stopSearch()
}

@Test func importedFullPathGlobKeepsAbsolutePathSemantics() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("absolute-import-\(UUID())")
    let folder = root.appendingPathComponent("alpha/book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("text".utf8).write(to: folder.appendingPathComponent("one.swift"))
    var snapshot = try CLICommandParser.parse("fd --type f --full-path --glob '*/book/**'", currentDirectory: root)
    #expect(snapshot.refinements.absolutePathMatching == true)
    let absolute = try await SearchService().search(request: snapshot.makeRequest())
    #expect(absolute.results.isEmpty)
    snapshot.refinements.absolutePathMatching = false
    let relative = try await SearchService().search(request: snapshot.makeRequest())
    #expect(relative.results.map(\.name) == ["one.swift"])
}
