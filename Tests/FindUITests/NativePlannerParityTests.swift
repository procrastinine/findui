@testable import SearchBackend
import Foundation
import Testing
import SearchCore
@testable import FindUI

/// Compare complete results against both native tools and the fused executor.
/// Order is intentionally ignored except for explicitly ranked searches.
@Test func nativePlansAndSharedExecutorHaveEquivalentFilePredicates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-parity-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, bytes) in [("report.txt", 10), ("REPORT.MD", 11), ("nested/report.swift", 9), ("caf\u{e9}.txt", 12),
                           (".hidden.txt", 10), ("skip/report.txt", 10), ("not.txt", 0), ("ſample.K", 10)] {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: path)
    }
    let tools = Toolchain.resolve()
    var fused = tools.capabilities; fused.fd = nil; fused.rg = nil; fused.find = nil
    var query = SearchQuery(); query.traversal.roots = [root.path]; query.traversal.ignore = .none
    query.traversal.excludedFolders = ["skip"]
    let predicates: [QueryTree<FilePredicate>] = [
        .all([]), .leaf(.text(.init(.name, .literal, "report"))), .leaf(.text(.init(.name, .exact, "report.txt"))),
        .leaf(.text(.init(.name, .glob, "*.txt"))), .leaf(.text(.init(.name, .literal, "café"))),
        .leaf(.text(.init(.name, .literal, "cafe\u{301}"))), .leaf(.size(.init(minimum: 10, maximum: 10))),
        .leaf(.extensions(["txt", "md"])), .leaf(.extensions(["k"])), .leaf(.text(.init(.name, .literal, "sample"))),
        .leaf(.text(.init(.absolute, .exact, root.appendingPathComponent("report.txt").path))),
        .all([.leaf(.text(.init(.name, .literal, "report"))), .leaf(.extensions(["txt"]))])
    ]
    for contents in [false, true] {
    query.contents = contents ? .leaf(.literal("A")) : nil
    for sensitive in [false, true] {
        query.options.fileCaseSensitive = sensitive
        for predicate in predicates {
            query.files = predicate
            let direct = try SearchPlanner(tools: tools.capabilities).plan(query)
            let shared = try SearchPlanner(tools: fused).plan(query)
            let a = try await ProcessRunner.run(spec: CommandSpec(direct.invocation), pathOverride: tools.searchPath)
            let b = try await ProcessRunner.run(spec: CommandSpec(shared.invocation), pathOverride: tools.searchPath)
            #expect((a.exitCode == 0 || direct.invocation.emptyExitCodes.contains(a.exitCode)) && b.exitCode == 0, "\(a.stderr) \(b.stderr)")
            func paths(_ out: String) throws -> [String] {
                if !contents { return out.split(separator: "\0").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }.sorted() }
                return try out.split(separator: "\n").compactMap { line in
                    let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                    guard record["type"] as? String == "match" else { return nil }
                    var data = record["data"] as! [String: Any]
                    let path = (data["path"] as! [String: String])["text"]!
                    data["path"] = ["text": URL(fileURLWithPath: path).standardizedFileURL.path]
                    return String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self)
                }.sorted()
            }
            #expect(try paths(a.stdout) == paths(b.stdout), "\(predicate), sensitive \(sensitive), contents \(contents)")
        }
    }
    }
}

@Test func nativeContentExtensionsPreserveIgnoresAndCommandImport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-types-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in [("yes.txt", "needle\n"), ("ignored.txt", "needle\n"), ("case.TXT", "needle\n"),
                         ("no.md", "needle\n"), (".ignore", "ignored.txt\n")] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    var request = SearchRequest(query: "needle", mode: .contents, scope: root, includeHidden: true,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.extensions = "txt"; request.refinements.fileCaseSensitive = true
    let service = SearchService(), response = try await service.search(request: request)
    #expect(response.engineName == "rg")
    #expect(response.results.map(\.name) == ["yes.txt"])
    let restored = try CLICommandParser.parse(response.commandPreview, currentDirectory: root)
    #expect(try await service.search(request: restored.makeRequest()).results.map(\.name) == ["yes.txt"])
}

@Test func negatedFrozenFileConditionsNeverAdmitDirectoriesOrExcludedSubtrees() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-not-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("skip"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["yes.txt", "draft.txt", "skip/yes.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
    let index = try await IndexService().buildIndex(name: "Frozen", scope: root, includeHidden: true,
        traversal: .init(excludedFolders: ["skip"]))
    var request = SearchRequest(query: "-draft", mode: .files, scope: root, includeHidden: true,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.traversal.excludedFolders = ["skip"]
    #expect(try await SearchService().search(request: request).results.map(\.name) == ["yes.txt"])
    #expect(try await IndexService().search(request: request, index: index.metadata, entries: index.entries).results.map(\.name) == ["yes.txt"])
}

@Test func nativeBooleanFilesMatchSharedSemanticsIncludingByteTextAndUnicodeFolds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-boolean-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bodies: [Data] = [Data(), Data("\n".utf8), Data("alpha beta\n".utf8), Data("alpha\nbeta\n".utf8),
        Data("alpha beta banned\n".utf8), Data("ALPHA BETA\n".utf8), Data("ſ K\n".utf8), Data([255] + Array("alpha beta\n".utf8)),
        Data("before\0alpha beta\n".utf8), Data("alpha beta\nbefore\0\n".utf8)]
    for (i, body) in bodies.enumerated() { try body.write(to: root.appendingPathComponent("\(i).txt")) }
    let tools = Toolchain.resolve()
    var worker = tools.capabilities; worker.rg = nil; worker.fd = nil; worker.find = nil
    var query = SearchQuery(); query.traversal.roots = [root.path]; query.traversal.ignore = .none; query.options.filesOnly = true
    for words in [["alpha", "beta", "banned"], ["s", "k", "missing"]] {
        let leaves = words.map { QueryTree<ContentPredicate>.leaf(.literal($0)) }
        let trees: [QueryTree<ContentPredicate>] = [.all([leaves[0], leaves[1]]), .any([leaves[0], leaves[1]]),
            .all([leaves[0], leaves[1], .none([leaves[2]])]), .none([leaves[0], leaves[1]]),
            .any([.all([leaves[0], .none([leaves[1]])]), .none([.none([leaves[2]])])])]
        for tree in trees { for sensitive in [false, true] {
            query.contents = tree; query.options.contentCaseSensitive = sensitive
            let native = try SearchPlanner(tools: tools.capabilities).plan(query)
            #expect(native.direct?.executable == tools.rg?.path)
            let reference = try SearchPlanner(tools: worker).plan(query)
            let a = try await ProcessRunner.run(spec: CommandSpec(native.invocation), pathOverride: tools.searchPath)
            let b = try await ProcessRunner.run(spec: CommandSpec(reference.invocation), pathOverride: tools.searchPath)
            #expect(a.exitCode == 0 || a.exitCode == 1, "\(a.stderr)"); #expect(b.exitCode == 0, "\(b.stderr)")
            #expect(a.stdout.split(separator: "\0").sorted() == b.stdout.split(separator: "\0").sorted(), "\(tree), sensitive \(sensitive)")
        } }
    }
}

@Test func nativeEligibilityCannotDropLineOrStatisticsOrCacheScopeSemantics() throws {
    var query = SearchQuery(); query.traversal.roots = ["/cache/inside"]
    query.traversal.ignore = .ripgrep; query.contents = .leaf(.literal("needle"))
    let planner = SearchPlanner(tools: Toolchain.resolve().capabilities)
    query.traversal.excludedPaths = ["/cache"]
    #expect(try planner.plan(query).direct?.executable == Toolchain.resolve().contentWorker?.path)
    query.traversal.excludedPaths = []; query.options.filesOnly = true; query.options.collectStatistics = true
    #expect(try planner.plan(query).direct?.executable == Toolchain.resolve().contentWorker?.path)
    query.contents = .leaf(.literal("needle\nother"))
    #expect(throws: PlanningError.self) { try planner.plan(query) }
}
