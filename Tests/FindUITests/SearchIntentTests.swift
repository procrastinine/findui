@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func selectedScopeSymbolsAndLiteralFoldersStayDistinct() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-root-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = SearchSnapshot(query: "", mode: .files, scopePath: root.path, useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    for folder in ["home", "current directory", "root directory"] {
        let target = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bytes = try JSONSerialization.data(withJSONObject: ["mode":"files","roots":[folder]])
        let intent = try SearchIntent.decodeModelOutput(bytes)
        #expect(intent.roots == [folder])
        let state = try intent.proposal(context: context, tools: .resolve()).snapshot
        #expect(state.scopePath == target.path)
    }
    for symbol in [".", "~", "/"] {
        let bytes = try JSONSerialization.data(withJSONObject: ["mode":"files","roots":[symbol]])
        #expect(try SearchIntent.decodeModelOutput(bytes).naturalPlan().scopePath == symbol)
    }
    let ordered = try SearchIntent.decodeModelOutput(Data(#"{"mode":"files","roots":["zeta","alpha","zeta"]}"#.utf8))
    #expect(ordered.roots == ["alpha", "zeta"])
}

@Test func legacyDescriptionsUseActualControlsAndCompiler() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-intent-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = SearchSnapshot(query: "", mode: .files, scopePath: root.path, useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    // Legacy annotation fixtures still exercise current controls and compilation.
    let descriptions = [
        #"{"mode":"files","extensions":["pdf"],"maxDepth":3,"date":"recentDays","relativeDays":20}"#,
        #"{"mode":"contents","content":"hBN","extensions":["ppt","pptx"],"source":"spotlight","contentSource":"indexedDocumentText","dateField":"documentCreated","date":"custom","dateFrom":"2025-01-01","dateThrough":"2025-02-28"}"#
    ]
    let proposals = try descriptions.map { try JSONDecoder().decode(SearchIntent.self, from: Data($0.utf8)).proposal(context: context, tools: .resolve()) }
    #expect(proposals[0].snapshot.filters.relativeDays == 20)
    #expect(proposals[0].snapshot.traversal.maximumDepth == 3)
    #expect(proposals[0].snapshot.refinements.extensions == "pdf")
    let document = proposals[1].snapshot
    #expect(document.refinements.source == .spotlight)
    #expect(document.refinements.contentSource == .indexedDocumentText)
    #expect(document.filters.dateField == .documentCreated)
    #expect(document.filters.datePeriod == .custom)
    #expect(ParsedSearchQuery.parseLiteral(document.query).tokens.map(\.value) == ["hBN"])
    #expect(!document.makeRequest().producesContentLines)
    #expect(proposals[1].command.contains("kMDItemContentCreationDate"))
    for proposal in proposals {
        #expect(try JSONDecoder().decode(SearchSnapshot.self, from: JSONEncoder().encode(proposal.snapshot)) == proposal.snapshot)
    }
}

@Test func richIntentPreservesLiteralTextInsteadOfInterpretingItAsFilters() throws {
    let context = SearchSnapshot(query: "", mode: .files, scopePath: "/tmp", useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    let source = #"{"mode":"contents","content":"-draft name:notes \"hello\"","maxDepth":3,"followSymlinks":true}"#
    let result = try JSONDecoder().decode(SearchIntent.self, from: Data(source.utf8)).proposal(context: context, tools: .resolve())
    let tokens = ParsedSearchQuery.parseLiteral(result.snapshot.query).tokens
    #expect(tokens.count == 1)
    #expect(tokens.first?.value == #"-draft name:notes "hello""#)
    #expect(tokens.first?.isExcluded == false)
    #expect(tokens.first?.field == .any)
    #expect(result.snapshot.traversal.followSymlinks)
}

@Test func intentPreservesSignificantRegexWhitespaceAndSupportsListing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("regex-whitespace-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("def spaced():\ndef\ttabbed():\ndefinition\n".utf8).write(to: root.appendingPathComponent("sample.py"))
    let context = SearchSnapshot(query: "", mode: .files, scopePath: root.path, useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    let text = #"{"mode":"contents","content":"^def ","contentMatching":"regex","extensions":["py"]}"#
    let result = try JSONDecoder().decode(SearchIntent.self, from: Data(text.utf8)).proposal(context: context, tools: .resolve())
    #expect(result.snapshot.query == "^def ")
    #expect(result.snapshot.makeRequest().query == "^def ")
    let execution = try await ProcessRunner.run(spec: SearchPipeline.command(result.command), pathOverride: Toolchain.resolve().searchPath)
    #expect(execution.exitCode == 0)
    let matches = execution.stdout.split(separator: "\n").enumerated().compactMap {
        SearchService().parseRipgrepJSONLine(String($0.element), request: result.snapshot.makeRequest(), sourceOrder: $0.offset, pipelineOutput: true)
    }
    #expect(matches.map(\.snippet) == ["def spaced():"])
    let listing = try JSONDecoder().decode(SearchIntent.self, from: Data(#"{"mode":"files"}"#.utf8)).proposal(context: context, tools: .resolve())
    #expect(listing.snapshot.query.isEmpty)
    #expect(listing.command.contains("fd"))
}

@Test func indexedOperationsInferTheirRequiredBackend() throws {
    let context = SearchSnapshot(query: "", mode: .files, scopePath: "/tmp", useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    for text in [#"{"mode":"contents","content":"hBN","contentSource":"indexedDocumentText"}"#,
                 #"{"mode":"files","date":"today","dateField":"lastOpened"}"#] {
        let result = try JSONDecoder().decode(SearchIntent.self, from: Data(text.utf8)).proposal(context: context, tools: .resolve())
        #expect(result.snapshot.refinements.source == .spotlight)
    }
    let conflict = #"{"mode":"contents","content":"hBN","contentSource":"indexedDocumentText","source":"filesystem"}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SearchIntent.self, from: Data(conflict.utf8)).proposal(context: context, tools: .resolve())
    }
}

@Test func wordsInsideCopiedLiteralsNeverBecomeOptions() throws {
    let context = SearchSnapshot(query: "", mode: .files, scopePath: "/tmp", useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    let value = "pdf modified yesterday in Downloads hidden Docmuents"
    for field in ["name", "content"] {
        let object = ["mode": field == "content" ? "contents" : "files", field: value]
        let intent = try JSONDecoder().decode(SearchIntent.self, from: JSONSerialization.data(withJSONObject: object))
        let snapshot = try intent.proposal(context: context, tools: .resolve()).snapshot
        #expect(snapshot.filters.datePeriod == .any)
        #expect(snapshot.refinements.extensions.isEmpty)
        #expect(!snapshot.includeHidden && !snapshot.traversal.includeIgnored)
        #expect(snapshot.scopePath == "/tmp")
        if field == "name" { #expect(snapshot.refinements.name == value) }
        else { #expect(ParsedSearchQuery.parseLiteral(snapshot.query).tokens.first?.value == value) }
    }
}
