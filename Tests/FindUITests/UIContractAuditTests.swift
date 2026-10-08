@testable import SearchBackend
import Foundation
import Testing
import SearchCore
@testable import FindUI

private struct ContractFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-contract-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String, _ text: String) throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }
    var state: SearchState {
        SearchRequest(query: "", mode: .files, scope: root, includeHidden: false,
            caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max).state
    }
}

@Test func contractLiteralResultsSurviveRulesControlsAndCommandRoundTrips() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    let values = ["name:literal", "-excluded", "two words", "a*b?", "  spaces  ",
                  "say \"yes\"", "it's", #"C:\temp\file"#, "a\tb", "東京 résumé", "$(literal)", "ext:"]
    for (i, value) in values.enumerated() { try fixture.file("file-\(i).txt", value + "\n") }
    let service = SearchService()
    for (i, value) in values.enumerated() {
        var state = fixture.state; state.contentsInput = value
        var expanded = state; try expanded.promoteToRules()
        let compact = try #require(expanded.compactProjection)
        for variant in [state, expanded, compact] {
            let restored = try CLICommandParser.parse(
                SearchPipelineCompiler(tools: service.tools).compile(variant.makeRequest()).script,
                currentDirectory: fixture.root)
            let before = try variant.makeRequest().normalizedQuery()
            let after = try restored.makeRequest().normalizedQuery()
            #expect(before.files == after.files && before.contents == after.contents)
            #expect(before.traversal == after.traversal && before.unit == after.unit)
            #expect(before.options == after.options)
            let result = try await service.search(request: restored.makeRequest())
            #expect(result.results.map(\.name) == ["file-\(i).txt"], "\(value): \(variant.criteria)")
        }
    }
}

@Test func contractIncompleteExpressionsCannotBroadenSearches() throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    for query in ["ext:", "name:", "needle -path:", "\"unfinished", "needle 'unfinished", "ext:.;"] {
        for mode in [SearchMode.files, .contents] {
            var state = fixture.state; state.mode = mode; state.query = query
            state.contentQueryStyle = .expression
            #expect(throws: (any Error).self, "Incomplete query: \(query)") {
                _ = try SearchPipelineCompiler(tools: .resolve()).compile(state.makeRequest())
            }
            #expect(throws: (any Error).self) { try state.promoteToRules() }
        }
    }
}

@Test func contractScopePresetsKeepAUsableSourceForExistingConditions() throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    let liveScope = SearchPreset(name: "Here", kind: .scope, state: fixture.state)
    var current = fixture.state
    current.contentsInput = "needle"; current.contentMatchingChoice = .documentText
    let restored = try liveScope.applying(to: current)
    #expect(restored.sourceChoice == .spotlight)
    #expect(restored.sourceChoices.contains(restored.sourceChoice))
    _ = try SearchPipelineCompiler(tools: .resolve()).compile(restored.makeRequest())

    var spotlightScope = fixture.state; spotlightScope.sourceChoice = .spotlight
    current = fixture.state; current.contentsInput = "needle"; current.contentMatchingChoice = .indexedWords
    let words = try SearchPreset(name: "Here too", kind: .scope, state: spotlightScope).applying(to: current)
    #expect(words.refinements.wordSearch == true && words.sourceChoice == .live)
    #expect(words.sourceChoices.contains(words.sourceChoice))
}

@Test func contractImportsMatchInstalledRipgrepForExclusions() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    for (name, body) in [("UPPER.txt", "needle\n"), ("other/upper.txt", "NEEDLE\n"),
                         ("skip/inside.txt", "needle\n"), ("alpha.txt", "alpha\n"), ("beta.txt", "beta\n"),
                         (".hidden.txt", "needle\n"), (".private/inside.txt", "needle\n"), ("ignored.txt", "needle\n"),
                         ("sub/report.md", "needle\n"), ("sub/other.md", "needle\n")] {
        try fixture.file(name, body)
    }
    try fixture.file(".rgignore", "ignored.txt\n")
    let tools = Toolchain.resolve(), rg = try #require(Toolchain.resolve().rg)
    for args in [["-l", "-0", "-i", "-g", "!UPPER.txt", "needle"],
                 ["-l", "-0", "-g", "!skip", "needle"],
                 ["-l", "-0", "-g", "*.txt", "needle"],
                 ["-l", "-0", "-g", "!*.txt", "needle"],
                 ["-l", "-0", "-g", "*.md", "-g", "!other.md", "needle"],
                 ["-l", "-0", "-g", "!*.txt", "-g", "ignored.txt", "needle"]] {
        let command = SearchPipelineCompiler.command(rg.path, args + [fixture.root.path])
        let direct = try await ProcessRunner.run(spec: SearchPipeline.command(command), pathOverride: tools.searchPath)
        #expect(direct.exitCode == 0, "\(direct.stderr)")
        let expected = Set(direct.stdout.split(separator: "\0").map { String($0) })
        let positive = args.enumerated().contains { index, value in value == "-g" && args.indices.contains(index + 1) && !args[index + 1].hasPrefix("!") }
        let imported: SearchState
        if positive {
            // rg admits whitelisted dotfiles without descending all hidden
            // directories. Keep those exact native semantics in command mode.
            #expect(throws: (any Error).self) { try CLICommandParser.parse(command, currentDirectory: fixture.root) }
            imported = try NativeSearchCommand(command: command, directory: fixture.root.path).snapshot()
        } else { imported = try CLICommandParser.parse(command, currentDirectory: fixture.root) }
        let result = try await SearchService(tools: tools).search(request: imported.makeRequest())
        #expect(Set(result.results.map(\.path)) == expected, "\(args)")
        if !positive {
            var grouped = imported; try grouped.promoteToRules()
            #expect(Set(try await SearchService(tools: tools).search(request: grouped.makeRequest()).results.map(\.path)) == expected)
        }
    }
}

@Test func contractGroupedWordSearchHasAReturnPathToLiveText() throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    var state = fixture.state
    state.replaceRules(.init(contents: .any([.rule(.literal("alpha")), .rule(.literal("beta"))])))
    #expect(state.compactProjection == nil)
    let tree = state.ruleSet?.contents
    state.contentTextEngine = .indexedWords
    #expect(state.contentTextEngine == .indexedWords && state.ruleSet?.contentUnit == .document)
    state.contentTextEngine = .live
    #expect(state.refinements.wordSearch != true && state.ruleSet?.contents == tree)
    #expect(state.ruleSet?.contentUnit == .document)
    let rules = SearchRuleSet(contents: .rule(.regex("alpha.*beta")))
    state.replaceRules(rules)
    #expect(state.contentTextEngineChoices == [.live])
    state.contentTextEngine = .indexedWords
    #expect(state.ruleSet == rules && state.refinements.wordSearch != true)
}

@Test func contractIndexedWordsCannotCreateContradictorySpotlightControls() throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    var state = fixture.state
    state.contentsInput = "needle"
    state.filters.dateField = .lastOpened; state.filters.datePeriod = .week
    state.selectRequiredSource()
    state.contentMatchingChoice = .indexedWords
    #expect(state.sourceChoices.contains(state.sourceChoice))
    #expect(state.refinements.wordSearch != true)
}

@Test func contractPipedRipgrepGlobsDoNotFilterExplicitFileArguments() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    try fixture.file("one.txt", "needle\n"); try fixture.file("two.md", "needle\n")
    let tools = Toolchain.resolve()
    let fd = try #require(tools.fd), rg = try #require(tools.rg)
    for glob in ["*.txt", "!two.md"] {
        let command = SearchPipelineCompiler.command(fd.path, ["-t", "f", "-0", ".", fixture.root.path])
            + " | " + SearchPipelineCompiler.command("/usr/bin/xargs", ["-0", rg.path, "-l", "-0", "-g", glob, "needle"])
        let direct = try await ProcessRunner.run(spec: SearchPipeline.command(command), pathOverride: tools.searchPath)
        #expect(direct.exitCode == 0)
        let expected = Set(direct.stdout.split(separator: "\0").map(String.init))
        let state = try CLICommandParser.parse(command, currentDirectory: fixture.root)
        #expect(Set(try await SearchService(tools: tools).search(request: state.makeRequest()).results.map(\.path)) == expected)
        #expect(expected.count == 2)
    }
}

@Test func contractPathRulesRemainAnchoredDuringIncrementalSnapshotsAndAdmission() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    let scope = fixture.root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    let traversal = SearchTraversalOptions(pathRules: ["nested/**", "!*.skip"])
    let service = IndexService()
    let initial = try await service.buildIndex(name: "Rules", scope: scope, includeHidden: false, traversal: traversal)
    try fixture.file("files/nested/sub/allowed.txt", "needle\n")
    try fixture.file("files/nested/sub/excluded.skip", "needle\n")
    try fixture.file("files/other.txt", "needle\n")
    let updated = try await service.refreshIndex(.init(metadata: initial.metadata, entries: initial.entries),
        changes: [.init(path: scope.appendingPathComponent("nested").path, recursive: true)])
    let fresh = try await service.buildIndex(name: "Rules", scope: scope, includeHidden: false, traversal: traversal)
    #expect(Set(updated.entries.map(\.relativePath)) == Set(fresh.entries.map(\.relativePath)))
    #expect(fresh.entries.contains { $0.relativePath == "nested/sub/allowed.txt" })
    #expect(!fresh.entries.contains { $0.relativePath == "nested/sub/excluded.skip" })
    var request = fixture.state.makeRequest(); request.scope = scope; request.query = "needle"; request.mode = .contents
    request.traversal = traversal
    let matches = try await SearchService().search(request: request)
    #expect(matches.results.map(\.name) == ["allowed.txt"])
    let list = fixture.root.appendingPathComponent("within.nul")
    try Data(["nested/sub/allowed.txt", "nested/sub/excluded.skip", "other.txt"].map { scope.appendingPathComponent($0).path + "\0" }.joined().utf8).write(to: list)
    request.state.resultScope = .init(path: list.path, name: "Prior files", count: 3)
    #expect(try await SearchService().search(request: request).results.map(\.name) == ["allowed.txt"])
    let explain = try await SearchExplainer(tools: .resolve()).explain(request, file: scope.appendingPathComponent("nested/sub/excluded.skip"))
    #expect(explain.steps.last?.passed == false)
}

@Test func contractPathRulesUseOneFreshWalkPerSearch() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    for name in ["alpha.txt", "beta.txt", "gamma.md"] { try fixture.file("files/" + name, "needle\n") }
    var tools = Toolchain.resolve(); let worker = try #require(tools.contentWorker)
    let log = fixture.root.appendingPathComponent("calls"), wrapper = fixture.root.appendingPathComponent("worker")
    let script = "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$1\" >> " + SearchPipelineCompiler.command(log.path, [])
        + "\nexec " + SearchPipelineCompiler.command(worker.path, []) + " \"$@\"\n"
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    tools.contentWorker = wrapper
    let service = SearchService(tools: tools)
    var request = fixture.state.makeRequest(); request.scope = fixture.root.appendingPathComponent("files")
    request.mode = .contents; request.query = "needle"; request.traversal.pathRules = ["*.txt"]
    for (name, patterns, expected) in [("", ["*.txt"], ["alpha.txt", "beta.txt"]),
                                       ("alpha", ["*.txt"], ["alpha.txt"]), ("", ["*.md"], ["gamma.md"])] {
        request.refinements.name = name; request.traversal.pathRules = patterns
        let collector = SearchResultCollector()
        _ = try await service.streamSearch(request: request) { await collector.append($0) }
        #expect(Set(await collector.results.map(\.name)) == Set(expected))
    }
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(calls == ["--execute", "--execute", "--execute"])
}

@Test @MainActor func contractIncompleteUIExpressionsKeepPriorResultsAndExposeTheError() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    try fixture.file("alpha.txt", "needle\n")
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: fixture.root.appendingPathComponent("state")), loadSavedState: false)
    defer { model.stopSearch() }
    model.scopeURL = fixture.root; model.contentsInput = "needle"; model.scheduleSearch(immediate: true)
    for _ in 0..<300 where model.results.isEmpty || model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.results.map(\.name) == ["alpha.txt"])
    model.contentMatchingChoice = .expression; model.contentsInput = "needle -path:"; model.scheduleSearch(immediate: true)
    #expect(!model.isSearching && model.commandPreview.isEmpty)
    #expect(model.statusMessage.contains("Enter a value"))
    #expect(model.results.map(\.name) == ["alpha.txt"])
}

@Test func contractSnapshotRequestsCannotSilentlyBecomeLiveSearches() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    try fixture.file("live.txt", "needle\n")
    var state = fixture.state; state.useIndex = true
    #expect(await HeadlessCLI.run(["search", try HeadlessCLI.encoded(state)]) == 2)
    #expect(throws: (any Error).self) {
        _ = try SearchPipelineCompiler(tools: .resolve()).compile(state.makeRequest())
    }
}

@Test func contractSnapshotPrintCommandRunsTheFrozenSearch() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    try fixture.file("files/frozen.txt", "needle\n")
    let scope = fixture.root.appendingPathComponent("files")
    let built = try await IndexService().buildIndex(name: "Frozen", scope: scope, includeHidden: false)
    let snapshot = fixture.root.appendingPathComponent("frozen.sqlite")
    try IndexArtifact(metadata: built.metadata, entries: built.entries).save(snapshot)
    try FileManager.default.removeItem(at: scope.appendingPathComponent("frozen.txt"))
    var state = fixture.state; state.scopePath = scope.path; state.useIndex = true; state.query = "frozen"
    for options in [["--snapshot", snapshot.path, "--print-command"], ["--print-command", "--snapshot", snapshot.path]] {
        let command = CommandSpec(executable: try currentTestCLIExecutable(),
            arguments: ["--cli", "search", try HeadlessCLI.encoded(state)] + options)
        let printed = try await ProcessRunner.run(spec: command, pathOverride: Toolchain.resolve().searchPath)
        #expect(printed.exitCode == 0, "\(printed.stderr)")
        #expect(printed.stdout.contains("--snapshot"))
        let copied = try await ProcessRunner.run(spec: SearchPipeline.command(printed.stdout), pathOverride: Toolchain.resolve().searchPath)
        #expect(copied.exitCode == 0, "\(copied.stderr)")
        #expect(copied.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).lastPathComponent } == ["frozen.txt"])
    }
}

@Test func contractFindPathWildcardsCrossDirectoriesLikeFind() async throws {
    let fixture = try ContractFixture(); defer { fixture.remove() }
    for name in ["top.txt", "sub/one.txt", "sub/deeper/two.txt", "sub/other.md"] { try fixture.file(name, "needle\n") }
    let tools = Toolchain.resolve(), find = try #require(Toolchain.resolve().find)
    for (root, pattern) in [(fixture.root.path, "*.txt"), (fixture.root.path, fixture.root.path + "/sub/*.txt"), (".", "./sub/*.txt")] {
        let command = SearchPipelineCompiler.command(find.path, [root, "-type", "f", "-path", pattern, "-print0"])
        let script = SearchPipelineCompiler.command("cd", [fixture.root.path]) + " && " + command
        let direct = try await ProcessRunner.run(spec: SearchPipeline.command(script), pathOverride: tools.searchPath)
        #expect(direct.exitCode == 0)
        let expected = Set(direct.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).lastPathComponent })
        let state = try CLICommandParser.parse(command, currentDirectory: fixture.root)
        #expect(Set(try await SearchService(tools: tools).search(request: state.makeRequest()).results.map(\.name)) == expected)
        #expect(expected.contains("two.txt"))
    }
    for flag in ["-name", "-path"] {
        let command = SearchPipelineCompiler.command(find.path, [fixture.root.path, "-type", "f", flag, "", "-print0"])
        let state = try CLICommandParser.parse(command, currentDirectory: fixture.root)
        #expect(try await SearchService(tools: tools).search(request: state.makeRequest()).results.isEmpty)
    }
    #expect(throws: (any Error).self) {
        _ = try CLICommandParser.parse("find . -type f -path '*.txt'", currentDirectory: fixture.root)
    }
}
