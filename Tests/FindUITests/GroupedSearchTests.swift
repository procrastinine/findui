@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

private struct GroupedFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-groups-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func file(_ name: String, _ text: String = "needle\n", bytes: Int? = nil) throws -> URL {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (bytes.map { Data(repeating: 65, count: $0) } ?? Data(text.utf8)).write(to: path)
        return path
    }
    var request: SearchRequest {
        SearchRequest(query: "", mode: .files, scope: root, includeHidden: true, caseSensitive: false,
                      syntax: .literal, exactNameMatch: false, maxResults: .max)
    }
    func run(_ rules: SearchRuleSet, tools: Toolchain = .resolve(), request: SearchRequest? = nil) async throws -> (SearchPipeline, [String]) {
        let pipeline = try SearchRulePipelineCompiler(tools: tools).compile(request ?? self.request, rules: rules)
        let command = CommandSpec(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", pipeline.spec.shellString])
        let execution = try await ProcessRunner.run(spec: command, pathOverride: tools.searchPath)
        #expect(execution.exitCode == 0, "Copied grouped command failed: \(execution.stderr)")
        guard execution.exitCode == 0 else { throw SearchServiceError.commandFailed(execution.stderr) }
        if pipeline.outputIsJSON {
            let rows = try execution.stdout.split(separator: "\n").map { row -> String in
                let value = try JSONSerialization.jsonObject(with: Data(row.utf8)) as! [String: Any]
                let data = value["data"] as! [String: Any]
                let path = data["path"] as! [String: String]
                return URL(fileURLWithPath: path["text"]!).lastPathComponent + ":" + String(data["line_number"] as! Int)
            }
            return (pipeline, rows)
        }
        return (pipeline, execution.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).lastPathComponent })
    }
}

@Test func groupedConditionalFormatsDoNotLeakTheirPrefix() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    for name in ["other.psd", "other.psb", "edit_logo.ai", "other.ai", "edit_logo.ps"] { try fixture.file(name) }
    let rules = SearchRuleSet(files: .any([
        .rule(.extensions(["psd", "psb"])),
        .all([.rule(.extensions(["ai"])), .rule(.name("edit_*", .glob))])
    ]))
    let (_, names) = try await fixture.run(rules)
    #expect(Set(names) == ["other.psd", "other.psb", "edit_logo.ai"])
}

@Test func literalExtensionTrailingPeriodsKeepTheirMeaningAcrossInputs() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    for name in ["normal.py", "trailing.py.", "normal.python", "trailing.python."] { try fixture.file(name) }
    #expect(try SearchFileTypes.selectedExtensions("..PY.") == ["py."])
    #expect(try SearchFileTypes.selectedExtensions(".python") == ["python"])
    let group = try #require(SearchFileTypes.groups.first)
    #expect(SearchFileTypes.adding(group, to: ".py.").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("py."))
    for grouped in [false, true] {
        let predicates: [String: Any] = ["extensions": ["..PY."]]
        let fields = grouped ? ["mode": "files", "files": predicates] : ["mode": "files"].merging(predicates) { _, new in new }
        let intent = try SearchIntent.decodeModelOutput(JSONSerialization.data(withJSONObject: fields))
        let state = try intent.proposal(context: fixture.request.state, tools: .resolve()).snapshot
        let result = try await SearchService().search(request: state.makeRequest())
        #expect(result.results.map(\.name) == ["trailing.py."])
    }
    var legacy = fixture.request
    legacy.query = "ext:.py."
    let result = try await SearchService().search(request: legacy)
    #expect(result.results.map(\.name) == ["trailing.py."])
}

@Test func groupedBranchSizesStayWithinTheirOwnOrBranch() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    for (name, bytes) in [("small.svg", 10_000), ("large.svg", 10_001), ("large.png", 100_000), ("huge.png", 100_001), ("other.txt", 1)] {
        try fixture.file(name, bytes: bytes)
    }
    let rules = SearchRuleSet(files: .any([
        .all([.rule(.extensions(["svg"])), .rule(.size(minimum: "", maximum: "<= 10 KB"))]),
        .all([.rule(.extensions(["png"])), .rule(.size(minimum: "", maximum: "<= 100 KB"))])
    ]))
    #expect(Set(try await fixture.run(rules).1) == ["small.svg", "large.png"])
}

@Test func groupedSameLineAndSameFileHaveDifferentActualResults() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("together.swift", "alpha beta\nalpha\n")
    try fixture.file("apart.swift", "alpha\nbeta\n")
    try fixture.file("missing.swift", "alpha\n")
    try fixture.file("outside.txt", "alpha beta\n")
    var rules = SearchRuleSet(files: .rule(.extensions(["swift"])),
        contents: .all([.rule(.literal("alpha")), .rule(.literal("beta"))]))
    let lines = try await fixture.run(rules)
    #expect(lines.0.outputIsJSON)
    #expect(lines.1 == ["together.swift:1"])
    rules.contentUnit = .file
    let files = try await fixture.run(rules)
    #expect(!files.0.outputIsJSON)
    #expect(Set(files.1) == ["together.swift", "apart.swift"])
}

@Test func groupedContentsOnlyRequiresJustRipgrepAndKeepsLiteralText() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("one.txt", "alpha beta\nemail\nalpha banned\n$(touch OWNED)\n")
    let tools = Toolchain(fd: nil, fzf: nil, rg: Toolchain.resolve().rg, find: nil, mdfind: nil)
    let rules = SearchRuleSet(contents: .all([
        .any([.rule(.literal("alpha")), .rule(.regex("^email$")), .rule(.literal("$(touch OWNED)"))]),
        .none([.rule(.literal("banned"))])
    ]))
    let result = try await fixture.run(rules, tools: tools)
    #expect(result.0.engineName == "FindUI")
    #expect(Set(result.1) == ["one.txt:1", "one.txt:2", "one.txt:4"])
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("OWNED").path))
}

@Test func groupedNegationIncludesUnmatchedLinesAndNestedDoubleNegation() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("one.txt", "alpha\nbanned\nother\n")
    var rules = SearchRuleSet(contents: .none([.rule(.literal("banned"))]))
    #expect(Set(try await fixture.run(rules).1) == ["one.txt:1", "one.txt:3"])
    rules.contents = .none([.none([.rule(.literal("alpha"))])])
    #expect(try await fixture.run(rules).1 == ["one.txt:1"])
}

@Test func groupedWholeFileNegationIncludesEmptyFilesButLineNegationDoesNotInventLines() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("empty.txt", "")
    try fixture.file("clean.txt", "alpha\nother\n")
    try fixture.file("mixed.txt", "alpha\nbanned\n")
    try fixture.file("outside.swift", "")
    var rules = SearchRuleSet(files: .rule(.extensions(["txt"])),
        contents: .none([.rule(.literal("banned"))]), contentUnit: .file)
    #expect(Set(try await fixture.run(rules).1) == ["empty.txt", "clean.txt"])
    rules.contentUnit = .line
    #expect(Set(try await fixture.run(rules).1) == ["clean.txt:1", "clean.txt:2", "mixed.txt:1"])
}

@Test func groupedHistoryRejectsConflictingModeOrHiddenCompactPredicates() throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    var state = fixture.request.state
    state.replaceRules(.init(contents: .rule(.literal("needle"))))
    let encoded = try JSONEncoder().encode(state)
    var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    json["mode"] = SearchMode.files.rawValue
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SearchState.self, from: JSONSerialization.data(withJSONObject: json))
    }
    json["mode"] = SearchMode.contents.rawValue
    json["query"] = "hidden predicate"
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SearchState.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@Test func copiedGroupedCommandRestoresEveryRuleAndRejectsEditedShell() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("edit_logo.ai", "hBN\n")
    try fixture.file("other.psd", "hBN draft\n")
    var state = fixture.request.state
    state.replaceRules(.init(files: .any([
        .rule(.extensions(["psd", "psb"])),
        .all([.rule(.extensions(["ai"])), .rule(.name("edit_*", .glob))])
    ]), contents: .all([.rule(.literal("hBN")), .none([.rule(.literal("draft"))])]), contentUnit: .file))
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(state.makeRequest())
    let restored = try CLICommandParser.parse(pipeline.script, currentDirectory: fixture.root)
    state.sourceCommand = pipeline.script
    #expect(restored == state)
    #expect(try SearchPipelineCompiler(tools: .resolve()).compile(restored.makeRequest()).script == pipeline.script)
    #expect(restored.ruleSet?.contentUnit == .file)
    let results = try await SearchService().search(request: restored.makeRequest())
    #expect(results.results.map(\.name) == ["edit_logo.ai"])
    let changed = SearchPipeline.command(pipeline.script + "\nprintf changed").shellString
    #expect(throws: (any Error).self) { try CLICommandParser.parse(changed, currentDirectory: fixture.root) }
    let changedOption = SearchPipeline.command(pipeline.script.replacingOccurrences(of: "edit_", with: "other_")).shellString
    #expect(changedOption != pipeline.spec.shellString)
    #expect(throws: (any Error).self) { try CLICommandParser.parse(changedOption, currentDirectory: fixture.root) }
}

@Test func copiedCompactCommandRestoresLiteralTextAndFixedDateBounds() throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    var state = fixture.request.state
    state.contentsInput = "$(touch /tmp/NEVER-RUN) 'quoted'"
    state.refinements.extensions = "swift"
    state.filters.datePeriod = .week
    let date = Date(timeIntervalSince1970: 1_790_800_000)
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(state.makeRequest(), now: date)
    state.sourceCommand = pipeline.script
    let restored = try CLICommandParser.parse(pipeline.script, currentDirectory: fixture.root)
    #expect(restored == state)
    #expect(try SearchPipelineCompiler(tools: .resolve()).compile(restored.makeRequest()).script == pipeline.script)
    #expect(!FileManager.default.fileExists(atPath: "/tmp/NEVER-RUN"))
}

@Test func calendarDurationFiltersRealFilesAndCopiedCommandsRetainTheClock() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    let iso = ISO8601DateFormatter()
    let now = try #require(iso.date(from: "2024-04-15T12:00:00Z"))
    // Away from DST and month-end for the pipeline fixture. Separate typed
    // arithmetic tests exercise month-end clamping and daylight saving.
    var request = fixture.request
    request.referenceDate = now
    request.filters.datePeriod = .recentCalendar
    request.filters.calendarAge = "1 month and 4 days"
    let from = try #require(request.filters.validated(now: now).from)
    for (name, time) in [("old.txt",from.addingTimeInterval(-1)), ("boundary.txt",from),
                         ("recent.txt",now.addingTimeInterval(-1)), ("future.txt",now.addingTimeInterval(1))] {
        let file = try fixture.file(name)
        try FileManager.default.setAttributes([.modificationDate:time], ofItemAtPath: file.path)
    }
    let rules = SearchRuleSet(files: .rule(.date(.init(request.filters))))
    #expect(Set(try await fixture.run(rules, request: request).1) == ["boundary.txt", "recent.txt"])
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    let restored = try CLICommandParser.parse(pipeline.script, currentDirectory: fixture.root)
    var expected = request.state; expected.sourceCommand = pipeline.script
    #expect(restored == expected)
    #expect(try SearchPipelineCompiler(tools: .resolve()).compile(restored.makeRequest()).script == pipeline.script)
    var grouped = request.state
    try grouped.promoteToRules()
    var groupedRequest = grouped.makeRequest(); groupedRequest.referenceDate = now
    let copied = try SearchPipelineCompiler(tools: .resolve()).compile(groupedRequest)
    grouped.sourceCommand = copied.script
    let groupedRestore = try CLICommandParser.parse(copied.script, currentDirectory: fixture.root)
    #expect(groupedRestore == grouped)
    #expect(try SearchPipelineCompiler(tools: .resolve()).compile(groupedRestore.makeRequest()).script == copied.script)
}

@Test func groupedModelInputUsesExistingFieldsWithoutLosingBranchScope() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("other.psd", "hBN\n")
    try fixture.file("other.psb", "hBN draft\n")
    try fixture.file("edit_logo.ai", "hBN\n")
    try fixture.file("other.ai", "hBN\n")
    let json = #"""
    {"mode":"contents","files":{"any":[
      {"extensions":["psd","psb"]},
      {"extensions":["ai"],"nameMatching":"glob","name":"edit_*","maximum":"<= 8 KiB"}
    ]},"contents":{"all":[{"content":"hBN"},{"none":[{"content":"draft"}]}]},"contentUnit":"file"}
    """#
    let intent = try JSONDecoder().decode(SearchIntent.self, from: Data(json.utf8))
    let proposal = try intent.proposal(context: fixture.request.state, tools: .resolve())
    #expect(proposal.snapshot.ruleSet?.contentUnit == .file)
    #expect(!proposal.snapshot.refinements.hasFileConditions && !proposal.snapshot.filters.isActive)
    let result = try await SearchService().search(request: proposal.snapshot.makeRequest())
    #expect(Set(result.results.map(\.name)) == ["other.psd", "edit_logo.ai"])
    let redecoded = try JSONDecoder().decode(SearchIntent.self, from: JSONEncoder().encode(intent))
    let replay = try redecoded.proposal(context: fixture.request.state, tools: .resolve())
    #expect(replay.snapshot == proposal.snapshot)
    let projected = try proposal.snapshot.modelIntent().proposal(context: fixture.request.state, tools: .resolve())
    let compiler = SearchPipelineCompiler(tools: .resolve())
    #expect(try compiler.compile(projected.snapshot.makeRequest()).executionScript
            == compiler.compile(proposal.snapshot.makeRequest()).executionScript)
}

@Test func groupedModelContentsNeedOnlyRgAndPresetSelectionStaysExplicit() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("one.txt", "literal email\nalice@example.org\nno match\n")
    let json = #"{"mode":"contents","contents":{"any":[{"content":"email"},{"content":"email","contentMatching":"preset"}]}}"#
    let intent = try JSONDecoder().decode(SearchIntent.self, from: Data(json.utf8))
    let tools = Toolchain(fd: nil, fzf: nil, rg: Toolchain.resolve().rg, find: nil, mdfind: nil)
    let proposal = try intent.proposal(context: fixture.request.state, tools: tools)
    let result = try await SearchService(tools: tools).search(request: proposal.snapshot.makeRequest())
    #expect(Set(result.results.compactMap(\.lineNumber)) == [1, 2])
    #expect(result.engineName == "FindUI")
}

@Test func groupedModelInputsRejectHiddenOrAmbiguousState() throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    for json in [
        #"{"mode":"files","name":"hidden","files":{"name":"visible"}}"#,
        #"{"mode":"contents","content":"hidden","contents":{"content":"visible"}}"#,
        #"{"mode":"files","files":{"all":[]}}"#,
        #"{"mode":"files","files":{"any":[{"name":"x","hidden":true}]}}"#,
        #"{"mode":"files","contents":{"content":"x"}}"#,
        #"{"mode":"contents","files":{"content":"wrong section"},"content":"x"}"#,
        #"{"mode":"contents","contents":{"content":"x","contentSource":"indexedDocumentText"},"wholeWords":true}"#
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SearchIntent.self, from: Data(json.utf8))
                .proposal(context: fixture.request.state, tools: .resolve())
        }
    }
}

@Test func groupedFuzzyUsesRealFzfAndAnEmptyGroupDoesNotBroaden() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("SearchViewModel.swift")
    try fixture.file("srchvm.swift")
    try fixture.file("other.txt")
    let rules = SearchRuleSet(files: .any([.rule(.name("srchvm", .fuzzy)), .rule(.extensions(["txt"]))]))
    let result = try await fixture.run(rules)
    #expect(result.0.engineName == "FindUI + fzf")
    #expect(result.1.first == "srchvm.swift")
    #expect(Set(result.1) == ["srchvm.swift", "SearchViewModel.swift", "other.txt"])
    for files: SearchRuleTree<SearchFileRule> in [.any([]), .none([]), .all([.all([])]), .rule(.name("", .contains))] {
        #expect(throws: (any Error).self) {
            try SearchRulePipelineCompiler(tools: .resolve()).compile(fixture.request, rules: .init(files: files))
        }
    }
}

@Test func groupedPromotionAndHistoryPreserveEveryCompactPredicate() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("src/report.swift", "alpha beta\nalpha banned\n")
    try fixture.file("src/report.txt", "alpha beta\n")
    try fixture.file("src/report-skip.swift", "alpha beta\n")
    try fixture.file("other/report.swift", "alpha beta\n")
    var state = fixture.request.state
    state.refinements.name = "report*"; state.refinements.nameMatching = .glob
    state.refinements.path = "src/**"; state.refinements.pathMatching = .glob
    state.refinements.extensions = "swift"
    state.refinements.excludedFiles = "*-skip.*"
    state.filters.minimumSize = "10 B"; state.filters.maximumSize = "1 KB"
    state.contentsInput = "alpha"
    state.contentMatchingChoice = .expression; state.query = "alpha -banned"
    let service = SearchService()
    let before = try await service.search(request: state.makeRequest())
    try state.promoteToRules()
    #expect(state.ruleSet != nil && !state.filters.isActive && !state.refinements.hasFileConditions)
    #expect(state.parameterDescription.contains("*-skip.*"))
    let encoded = try JSONEncoder().encode(state)
    let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    #expect(json["criteria"] != nil && json["filters"] == nil && json["refinements"] == nil)
    let restored = try JSONDecoder().decode(SearchState.self, from: encoded)
    #expect(restored == state)
    let after = try await service.search(request: restored.makeRequest())
    #expect(after.results.map { "\($0.name):\($0.lineNumber ?? 0)" } == before.results.map { "\($0.name):\($0.lineNumber ?? 0)" })
    #expect(after.results.map(\.name) == ["report.swift"])
    let compact = try #require(restored.compactProjection)
    #expect(compact.ruleSet == nil)
    let projected = try await service.search(request: compact.makeRequest())
    #expect(projected.results.map { "\($0.name):\($0.lineNumber ?? 0)" } == before.results.map { "\($0.name):\($0.lineNumber ?? 0)" })
}

@Test func groupedWholeFileAndBranchesCannotSilentlyCollapseIntoCompactControls() throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    var state = fixture.request.state
    state.replaceRules(.init(files: .any([.rule(.extensions(["svg"])), .rule(.name("edit_*.ai", .glob))])))
    #expect(state.compactProjection == nil)
    state.replaceRules(.init(contents: .all([.rule(.literal("alpha")), .rule(.literal("beta"))]), contentUnit: .file))
    #expect(state.compactProjection == nil)
    #expect(!state.makeRequest().producesContentLines)
    let encoded = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(SearchState.self, from: encoded).ruleSet?.contentUnit == .file)
}

@Test @MainActor func groupedIncompleteEditsKeepPreviousResults() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("one.swift")
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    model.refinements.name = "one.swift"; model.refinements.nameMatching = .exact
    model.scheduleSearch(immediate: true)
    for _ in 0..<500 {
        if !model.results.isEmpty && !model.isSearching { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let previous = model.results.map(\.id)
    try #require(!previous.isEmpty, "Initial search must finish before testing an incomplete edit.")
    model.enableRules()
    var rules = try #require(model.searchRules)
    rules.files = .all([rules.files, .rule(.name("", .contains))])
    model.updateRules(rules)
    model.scheduleSearch(immediate: true)
    try await Task.sleep(for: .milliseconds(60))
    #expect(model.results.map(\.id) == previous)
    #expect(!model.isSearching && model.commandPreview.isEmpty)
    #expect(model.statusMessage.contains("Enter a value"))
}

@Test @MainActor func quickDefaultsDoNotChangeImportedLiteralSearches() throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    defer { model.shutdown() }
    #expect(model.filenameInputMatching == .quick)
    #expect(model.contentMatchingChoice == .expression)
    model.contentsInput = "alpha beta -draft"
    model.enableRules()
    #expect(model.searchRules?.contents == .all([.rule(.literal("alpha")), .rule(.literal("beta")), .none([.rule(.literal("draft"))])]))

    let imported = try CLICommandParser.parse("rg -F 'alpha beta -draft' .", currentDirectory: fixture.root)
    model.restoreSearchState(imported)
    #expect(model.contentMatchingChoice == .literal)
    #expect(model.contentsInput == "alpha beta -draft")
    model.enableRules()
    #expect(model.searchRules?.contents == .rule(.literal("alpha beta -draft")))
}

@Test @MainActor func fileTypePresetKeepsFilenameAndContentsAndRoundTrips() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    try fixture.file("holiday.png", "blue sky\n")
    try fixture.file("holiday.jpeg", "blue sky\n")
    try fixture.file("holiday.pdf", "blue sky\n")
    try fixture.file("other.png", "blue sky\n")
    try fixture.file("holiday.gif", "red sky\n")
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    model.filenameInput = "holiday.*"
    model.contentsInput = "blue"
    let images = try #require(SearchFileTypes.groups.first { $0.aliases.contains("images") })
    model.selectFileTypePreset(images)
    #expect(model.filenameInput == "holiday.*" && model.contentsInput == "blue")
    #expect(model.fileTypePresetTitle == images.title)
    let compact = model.searchState
    let direct = try await SearchService().search(request: compact.makeRequest())
    #expect(Set(direct.results.map(\.name)) == ["holiday.png", "holiday.jpeg"])
    model.enableRules()
    let encoded = try JSONEncoder().encode(model.searchState)
    let restored = try JSONDecoder().decode(SearchState.self, from: encoded)
    model.restoreSearchState(restored)
    model.useCompactControls()
    #expect(model.fileTypePresetTitle == images.title)
    #expect(model.filenameInput == "holiday.*" && model.contentsInput == "blue")
    let after = try await SearchService().search(request: model.searchState.makeRequest())
    #expect(Set(after.results.map(\.name)) == Set(direct.results.map(\.name)))
}

@Test @MainActor func quickMatchingUsesOnlyExistingPredicatesAndKeepsExplicitModes() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    for name in ["report", "annual-report.pdf", "report.txt", "photo.jpeg"] { try fixture.file(name) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    for (input, matching, names) in [
        ("report", PatternMatching.contains, Set(["report", "annual-report.pdf", "report.txt"])),
        ("*.pdf", .glob, Set(["annual-report.pdf"]))
    ] {
        model.filenameInput = input
        #expect(model.filenameInputMatching == .quick)
        #expect(model.refinements.nameMatching == matching)
        #expect(try model.searchState.modelIntent().nameMatching == matching)
        let rows = try await SearchService().search(request: model.searchState.makeRequest())
        #expect(Set(rows.results.map(\.name)) == names)
        let saved = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(model.searchState))
        model.restoreSearchState(saved)
        #expect(model.filenameInputMatching == .quick)
    }
    model.filenameInputMatching = .pattern(.glob)
    model.filenameInput = "report"
    let exactGlob = try await SearchService().search(request: model.searchState.makeRequest())
    #expect(exactGlob.results.map(\.name) == ["report"])
    model.filenameInputMatching = .pattern(.contains)
    model.filenameInput = "*.pdf"
    #expect(model.refinements.nameMatching == .contains)
    #expect(try await SearchService().search(request: model.searchState.makeRequest()).results.isEmpty)
}

@Test @MainActor func emptyRuleValidationClearsImmediatelyForBothSections() throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    model.scopeURL = fixture.root
    for rules in [SearchRuleSet(files: .all([.rule(.name("", .contains))])), .init(contents: .all([.rule(.literal(""))]))] {
        model.updateRules(rules)
        model.scheduleSearch(immediate: true)
        #expect(model.ruleValidationMessage != nil && model.statusMessage.contains("empty condition"))
        model.updateRules(.init())
        #expect(model.ruleValidationMessage == nil)
        #expect(!model.statusMessage.contains("empty condition"))
        #expect(model.canUseCompactControls)
    }
}

@Test @MainActor func compactProjectionPreservesResultsAndHistoryRestoresEveryCondition() async throws {
    let fixture = try GroupedFixture(); defer { fixture.remove() }
    for (name, text) in [("one.swift", "alpha beta\n"), ("two.swift", "alpha\nbeta\n"), ("other.txt", "alpha beta\n")] {
        try fixture.file(name, text)
    }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    for (json, requiresRules) in [
        (#"{"mode":"contents","files":{"extensions":["swift"]},"contents":{"all":[{"content":"alpha"},{"content":"beta"}]},"contentUnit":"line"}"#, false),
        (#"{"mode":"contents","files":{"extensions":["swift"]},"contents":{"all":[{"content":"alpha"},{"content":"beta"}]},"contentUnit":"file"}"#, true),
        (#"{"mode":"files","files":{"any":[{"name":"one.swift","nameMatching":"exact"},{"name":"other.txt","nameMatching":"exact"}]}}"#, true)
    ] {
        let intent = try SearchIntent.decodeModelOutput(Data(json.utf8))
        let proposal = try intent.proposal(context: fixture.request.state, tools: .resolve())
        let expected = try await SearchService().search(request: proposal.snapshot.makeRequest())
        model.runHistoryEntry(.init(id: UUID(), snapshot: proposal.snapshot.compactProjection ?? proposal.snapshot,
            searchedAt: .now, resultCount: expected.results.count, engineName: "test", isPinned: false, pinOrder: nil))
        #expect((model.searchRules != nil) == requiresRules)
        let actual = try await SearchService().search(request: model.searchState.makeRequest())
        #expect(Set(actual.results.map { "\($0.path):\($0.lineNumber ?? 0)" }) == Set(expected.results.map { "\($0.path):\($0.lineNumber ?? 0)" }))
        model.stopSearch()
    }
}
