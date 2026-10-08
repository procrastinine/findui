@testable import SearchBackend
import SearchCore
import Foundation
import Testing
@testable import FindUI

private struct MixedFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-mixed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String, _ text: String = "needle\n") throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }
    var request: SearchRequest {
        SearchRequest(query: "", mode: .files, scope: root, includeHidden: false,
                      caseSensitive: true, syntax: .literal, exactNameMatch: false, maxResults: .max)
    }
    func request(_ expression: SearchRuleTree<SearchCondition>, unit: SearchContentUnit = .line) -> SearchRequest {
        var value = request; value.state.replaceRules(.init(expression: expression, contentUnit: unit)); return value
    }
    func names(_ request: SearchRequest) async throws -> Set<String> {
        Set(try await SearchService().search(request: request).results.map(\.name))
    }
}

@Test func hiddenControlsRemainInvariantAcrossFilenameAndContentPlans() async throws {
    let f = try MixedFixture(); defer { f.remove() }
    for name in ["Visible.swift", ".Hidden.swift", "nested/.Hidden.swift", ".hidden/Inside.swift",
                 ".allowed/Explicit.swift", "ignored.swift", "Other.md"] { try f.file(name) }
    try f.file(".ignore", "ignored.swift\n!.allowed/\n!.Hidden.swift\n")
    let tools = Toolchain.resolve()
    var worker = tools.capabilities; worker.fd = nil; worker.rg = nil; worker.find = nil
    for hidden in [false, true] { for ignored in [false, true] { for filtered in [false, true] {
        var request = f.request
        request.mode = .contents; request.query = "needle"
        request.includeHidden = hidden; request.traversal.includeIgnored = ignored
        if filtered { request.refinements.name = "*.swift"; request.refinements.nameMatching = .glob }
        let query = try request.normalizedQuery()
        let native = try SearchPlanner(tools: tools.capabilities).plan(query)
        #expect(native.direct?.executable == tools.rg?.path)
        let reference = try SearchPlanner(tools: worker).plan(query)
        func paths(_ plan: ExecutionPlan) async throws -> Set<String> {
            let result = try await ProcessRunner.run(spec: CommandSpec(plan.invocation), pathOverride: tools.searchPath)
            #expect(result.exitCode == 0, "\(result.stderr)")
            return try Set(result.stdout.split(separator: "\n").compactMap { row in
                let record = try JSONSerialization.jsonObject(with: Data(row.utf8)) as! [String: Any]
                guard record["type"] as? String == "match", let data = record["data"] as? [String: Any],
                    let path = (data["path"] as? [String: String])?["text"] else { return nil as String? }
                return String(path.dropFirst(f.root.path.count + 1))
            })
        }
        var expected: Set<String> = ["Visible.swift"]
        if !filtered { expected.insert("Other.md") }
        if hidden { expected.formUnion([".Hidden.swift", "nested/.Hidden.swift", ".hidden/Inside.swift", ".allowed/Explicit.swift"]) }
        if ignored { expected.insert("ignored.swift") }
        #expect(try await paths(native) == expected)
        #expect(try await paths(reference) == expected)
        let response = try await SearchService().search(request: request)
        let restored = try CLICommandParser.parse(response.commandPreview, currentDirectory: f.root)
        #expect(restored.includeHidden == hidden)
        let restoredNames = try await f.names(restored.makeRequest())
        #expect(try await f.names(request) == restoredNames)
    } } }
    var names = f.request; names.refinements.name = "*.swift"; names.refinements.nameMatching = .glob
    #expect(try await f.names(names) == ["Visible.swift"])
}

@Test func mixedBooleanTruthTableSurvivesExecutionPersistenceAndCopiedCommand() async throws {
    let f = try MixedFixture(); defer { f.remove() }
    var expected = Set<String>()
    for mask in 0..<32 {
        let a = mask & 1 != 0, b = mask & 2 != 0, c = mask & 4 != 0, d = mask & 8 != 0, e = mask & 16 != 0
        let name = "\(a ? "A" : "X")\(c ? "C" : "Y")\(e ? "E" : "Z")-\(mask).txt"
        try f.file(name, "\(b ? "bravo" : "quiet") \(d ? "delta" : "quiet")\n")
        if ((a && b) || (c && d)) && e { expected.insert(name) }
    }
    let tree: SearchRuleTree<SearchCondition> = .all([
        .any([.all([.rule(.file(.name("A", .contains))), .rule(.content(.literal("bravo")))]),
              .all([.rule(.file(.name("C", .contains))), .rule(.content(.literal("delta")))])]),
        .rule(.file(.name("E", .contains)))])
    let request = f.request(tree)
    let normalized = try request.normalizedQuery()
    #expect(normalized.expression != nil)
    let response = try await SearchService().search(request: request)
    #expect(Set(response.results.map(\.name)) == expected)
    let saved = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(request.state))
    #expect(saved.ruleSet?.expression == tree)
    let imported = try CLICommandParser.parse(response.commandPreview, currentDirectory: f.root)
    #expect(imported.ruleSet?.expression == tree)
    #expect(try await f.names(imported.makeRequest()) == expected)
    let copied = try await ProcessRunner.run(spec: SearchPipeline.command(response.commandPreview), pathOverride: Toolchain.resolve().searchPath)
    #expect(copied.exitCode == 0, "\(copied.stderr)")
    #expect(Set(copied.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).lastPathComponent }) == expected)
}

@Test func mixedUnitsNegationAndFileOnlyBranchesKeepTheirMeaning() async throws {
    let f = try MixedFixture(); defer { f.remove() }
    try f.file("together.swift", "alpha beta\n"); try f.file("apart.swift", "alpha\nbeta\n")
    try f.file("matching.md", "gamma\n"); try f.file("wrong.md", "alpha beta\n")
    try f.file("empty.keep", ""); try f.file("binary.keep", "\0binary")
    let tree: SearchRuleTree<SearchCondition> = .any([
        .all([.rule(.file(.extensions(["swift"]))), .rule(.content(.literal("alpha"))), .rule(.content(.literal("beta")))]),
        .all([.rule(.file(.extensions(["md"]))), .rule(.content(.literal("gamma")))]),
        .rule(.file(.extensions(["keep"])))] )
    #expect(try await f.names(f.request(tree)) == ["together.swift", "matching.md", "empty.keep", "binary.keep"])
    #expect(try await f.names(f.request(tree, unit: .file)) == ["together.swift", "apart.swift", "matching.md", "empty.keep", "binary.keep"])
    let negative: SearchRuleTree<SearchCondition> = .none([.all([
        .rule(.file(.extensions(["swift"]))), .none([.rule(.content(.literal("beta")))])])])
    #expect(try await f.names(f.request(negative, unit: .file)) == ["together.swift", "apart.swift", "matching.md", "wrong.md", "empty.keep", "binary.keep"])
}

@Test func unifiedRulesRetainNativeFastPathsWhenDomainsAreSeparable() throws {
    let f = try MixedFixture(); defer { f.remove() }
    let files: SearchRuleTree<SearchCondition> = .rule(.file(.extensions(["swift"])))
    let text: SearchRuleTree<SearchCondition> = .rule(.content(.literal("needle")))
    let tools = Toolchain.resolve()
    let trees: [SearchRuleTree<SearchCondition>] = [.all([files, text]), .all([.all([text]), .all([files])])]
    for tree in trees {
        let query = try f.request(tree).normalizedQuery()
        #expect(query.expression == nil)
        #expect(try SearchPlanner(tools: tools.capabilities).plan(query).direct?.executable == tools.rg?.path)
    }
    let query = try f.request(.all([files])).normalizedQuery()
    #expect(query.expression == nil && query.contents == nil)
    #expect(try SearchPlanner(tools: tools.capabilities).plan(query).direct?.executable == tools.fd?.path)
}

@Test func mixedIndexedWordsAndFuzzyUseTheSameBranchLogic() async throws {
    let f = try MixedFixture(); defer { f.remove() }
    let old = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]
    setenv("FINDUI_CACHE_DIRECTORY", f.root.appendingPathComponent("cache").path, 1)
    defer { if let old { setenv("FINDUI_CACHE_DIRECTORY", old, 1) } else { unsetenv("FINDUI_CACHE_DIRECTORY") } }
    let scope = f.root.appendingPathComponent("files")
    for (name, text) in [("apple.swift", "bravo"), ("apple.md", "delta"), ("wrong.swift", "delta"), ("wrong.md", "bravo"), ("empty.keep", "")] {
        try f.file("files/" + name, text)
    }
    var prepare = f.request; prepare.scope = scope; prepare.mode = .contents; prepare.buildWordIndex = true
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(prepare)
    let built = try await ProcessRunner.run(spec: pipeline.spec, pathOverride: Toolchain.resolve().searchPath)
    #expect(built.exitCode == 0, "\(built.stderr)")
    let tree: SearchRuleTree<SearchCondition> = .any([
        .all([.rule(.file(.extensions(["swift"]))), .rule(.content(.literal("bravo")))]),
        .all([.rule(.file(.extensions(["md"]))), .rule(.content(.literal("delta")))]),
        .rule(.file(.extensions(["keep"])))] )
    var request = f.request(tree, unit: .file); request.scope = scope; request.caseSensitive = false
    request.refinements.wordSearch = true
    #expect(try await f.names(request) == ["apple.swift", "apple.md", "empty.keep"])
    request.refinements.wordSearch = nil
    request.state.replaceRules(.init(expression: .any([
        .all([.rule(.file(.name("appl", .fuzzy))), .rule(.content(.literal("bravo")))]),
        .all([.rule(.file(.extensions(["md"]))), .rule(.content(.literal("delta")))])]), contentUnit: .file))
    #expect(try await f.names(request) == ["apple.swift", "apple.md"])
}

@Test func changingTheLastContentConditionRestoresFilenameSearchAndBrowsingClearsMixedRules() throws {
    let f = try MixedFixture(); defer { f.remove() }
    var request = f.request(.all([.rule(.content(.literal("needle")))]), unit: .document)
    request.refinements.wordSearch = true
    request.refinements.multiline = true
    var extraction = SearchExtractionOptions(); extraction.customReaders = true
    request.refinements.extraction = extraction
    request.state.replaceRules(.init(expression: .all([.rule(.file(.name("report", .contains)))])))
    #expect(request.mode == .files && request.refinements.wordSearch == nil && request.refinements.multiline == nil)
    #expect(request.state.sourceChoices.contains(.snapshot))
    let tools = Toolchain.resolve()
    let query = try request.normalizedQuery()
    #expect(query.action == .search && query.extraction == nil)
    #expect(try SearchPlanner(tools: tools.capabilities).plan(query).direct?.executable == tools.fd?.path)

    request = f.request(.any([.rule(.file(.name("report", .contains))), .rule(.content(.literal("needle")))]))
    request.isDirectoryListing = true
    let listing = try request.normalizedQuery()
    #expect(listing.expression == nil && listing.contents == nil && listing.files.isTrue)
    #expect(listing.action == .search && listing.traversal.maximumDepth == 1)

    var compact = f.request.state
    compact.contentsInput = "needle"
    compact.refinements.wordSearch = true
    compact.refinements.multiline = true
    compact.contentsInput = ""
    #expect(compact.mode == .files && compact.refinements.wordSearch == nil && compact.refinements.multiline == nil)
    #expect(try compact.makeRequest().normalizedQuery().action == .search)
}
