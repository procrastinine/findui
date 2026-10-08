@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func parallelWorkerReadsEachCandidateOnceAndDeduplicatesConditions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-parallel-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("paths")
    var paths = Data()
    for i in 0..<32 {
        let file = root.appendingPathComponent("odd '\(i)\n.txt")
        try Data("alpha café\nemail\nalpha banned\n@word!\n".utf8).write(to: file)
        paths.append(contentsOf: (file.path + "\0" + file.path + "\0").utf8)
    }
    try paths.write(to: input)
    let worker = try #require(Toolchain.locateContentWorker())
    var previous: Set<String>?
    for threads in [1, 4] {
        let plan: [String: Any] = ["leaves": [
            ["pattern": "alpha", "regex": false], ["pattern": "alpha", "regex": false],
            ["pattern": "^email$", "regex": true], ["pattern": "banned", "regex": false]],
            "tree": ["all": [["any": [["leaf": 0], ["leaf": 1], ["leaf": 2]]], ["none": [["leaf": 3]]]]],
            "positive": [0, 1, 2], "threads": threads, "stats": true]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        let script = SearchPipelineCompiler.command("/bin/cat", [input.path]) + " | "
            + SearchPipelineCompiler.command(worker.path, ["--plan", json])
        let result = try await ProcessRunner.run(spec: SearchPipeline.command(script), pathOverride: Toolchain.resolve().searchPath)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let rows = Set(result.stdout.split(separator: "\n").map(String.init))
        #expect(rows.count == 64)
        if let previous { #expect(rows == previous) }
        previous = rows
        let raw = try #require(result.stderr.split(separator: "\n").first { $0.hasPrefix("findui-stats: ") })
        let stats = try JSONSerialization.jsonObject(with: Data(raw.dropFirst(14).utf8)) as! [String: Int]
        #expect(stats["filesOpened"] == 32)
        #expect(stats["uniqueMatchers"] == 3)
        #expect(stats["workers"] == threads)
    }
}

@Test func filesOnlyUsesEarlyExitAndMetadataCacheIsExecutionScoped() throws {
    var request = SearchRequest(query: "needle", mode: .contents, scope: FileManager.default.temporaryDirectory,
        includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.matchingFilesOnly = true
    request.refinements.extraction = nil // Plain-text-only searches retain rg's early exit.
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    #expect(pipeline.spec.arguments.contains("--files-with-matches"))
    #expect(!pipeline.script.contains("--json"))
    #expect(!pipeline.script.contains("--threads 1"))
    let cache = SearchMetadataCache()
    var count = 0
    let load: () -> SearchMetadata = { count += 1; return (nil, nil, nil, nil, nil, 42, nil) }
    for _ in 0..<500 { #expect(cache.value(for: "same file", load: load).size == 42) }
    #expect(count == 1)
    _ = SearchMetadataCache().value(for: "same file", load: load)
    #expect(count == 2)
}

@Test func sizeBoundsArePushedIntoTheSingleNativeTraversal() throws {
    var request = SearchRequest(query: "", mode: .files, scope: FileManager.default.temporaryDirectory,
        includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.filters.minimumSize = "100b"
    let first = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    request.filters.minimumSize = "1000b"
    let second = try SearchPipelineCompiler(tools: .resolve()).compile(request)
    #expect(first.enumeration != second.enumeration)
    #expect(first.plan.stages.count == 1 && second.plan.stages.count == 1)
    #expect(first.plan.direct?.arguments.contains("+100b") == true && second.plan.direct?.arguments.contains("+1000b") == true)
}

@Test func orderedParallelOutputSpillsLargeMatchesAndAdvancesPastFailedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-order-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var paths: [String] = []
    for i in 0..<12 {
        let file = root.appendingPathComponent("rank-\(i).txt")
        paths.append(file.path)
        if i != 3 { try Data(String(repeating: "needle\n", count: i == 0 ? 8_000 : 1).utf8).write(to: file) }
    }
    let input = root.appendingPathComponent("paths")
    try Data((paths.joined(separator: "\0") + "\0").utf8).write(to: input)
    let worker = try #require(Toolchain.locateContentWorker())
    for filesOnly in [false, true] {
        let plan: [String: Any] = ["tree": ["leaf": 0], "leaves": [["pattern": "needle"]], "positive": [0],
            "threads": 4, "ordered": true, "filesOnly": filesOnly]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        let script = SearchPipelineCompiler.command("/bin/cat", [input.path]) + " | "
            + SearchPipelineCompiler.command(worker.path, ["--plan", json])
        let result = try await ProcessRunner.run(spec: SearchPipeline.command(script), pathOverride: Toolchain.resolve().searchPath)
        #expect(result.exitCode == 2)
        let outputPaths: [String]
        if filesOnly { outputPaths = result.stdout.split(separator: "\0").map(String.init) }
        else {
            #expect(result.stdout.utf8.count > 1024 * 1024)
            let rows = try result.stdout.split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            outputPaths = rows.map { (($0["data"] as! [String: Any])["path"] as! [String: Any])["text"] as! String }
        }
        let expected = paths.enumerated().flatMap { i, path -> [String] in
            if i == 3 { return [] }
            return Array(repeating: path, count: !filesOnly && i == 0 ? 8_000 : 1)
        }
        #expect(outputPaths == expected)
    }
}
