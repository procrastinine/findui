import Foundation
import Testing
@testable import SearchCore

private func tools() -> ToolCapabilities {
    var tools = ToolCapabilities(); tools.fd = "/usr/local/bin/fd"; tools.rg = "/usr/local/bin/rg"
    tools.fzf = "/usr/local/bin/fzf"; tools.worker = "/app/findui-content"; return tools
}
@Test func ordinaryQueriesRemainNativeCommands() throws {
    var query = SearchQuery(); query.traversal.roots = ["/scope"]
    query.files = .leaf(.text(.init(.name, .literal, "report")))
    let names = try SearchPlanner(tools: tools()).plan(query)
    #expect(names.direct?.executable == tools().fd)
    #expect(!names.command.contains("--execute"))
    query.files = .all([]); query.contents = .leaf(.literal("needle")); query.traversal.ignore = .ripgrep
    let text = try SearchPlanner(tools: tools()).plan(query)
    #expect(text.direct?.executable == tools().rg)
    #expect(text.direct?.arguments.suffix(3) == ["--", "needle", "/scope"])
}
@Test func reducingBooleanTreesPreservesEveryTruthAssignmentAndBranchOrder() throws {
    let leaves = (0..<4).map { FilePredicate.text(.init(.name, .literal, "x\($0)")) }
    let expressions: [QueryTree<FilePredicate>] = [
        .all([.all([.leaf(leaves[0]), .leaf(leaves[1])]), .leaf(leaves[0])]),
        .any([.any([.leaf(leaves[2]), .leaf(leaves[1])]), .leaf(leaves[2])]),
        .none([.all([.leaf(leaves[0]), .leaf(leaves[1])]), .none([.leaf(leaves[3])])])
    ]
    for expression in expressions {
        for bits in 0..<16 {
            let predicate: (FilePredicate) -> Bool = { bits & (1 << leaves.firstIndex(of: $0)!) != 0 }
            #expect(expression.evaluate(predicate) == expression.simplified.evaluate(predicate))
        }
    }
    #expect(expressions[1].simplified.leaves == [leaves[2], leaves[1]])
}
@Test func incompatibleStreamsAndVersionsFailBeforeExecution() throws {
    var query = SearchQuery(); query.traversal.roots = ["/scope"]
    query.version = 999
    #expect(throws: PlanningError.self) { try SearchPlanner(tools: tools()).plan(query) }
    query.version = 2
    #expect(throws: PlanningError.self) {
        try ExecutionPlan(query: query, stages: [
            .init(.enumerate, Invocation("fd"), output: .paths, label: "fd"),
            .init(.filter, Invocation("filter"), input: .metadata, output: .paths, label: "filter")])
    }
}

@Test func everyParallelRankingStageSharesTheWorkerBudget() throws {
    var query = SearchQuery(); query.traversal.roots = ["/scope"]
    query.files = .all(["alpha", "beta", "gamma"].map { .leaf(.text(.init(.absolute, .fuzzy, $0))) })
    query.options.workers = 8
    let plan = try SearchPlanner(tools: tools()).plan(query)
    #expect(plan.stages.count == 4)
    let enumeration = try #require(plan.stages[0].invocation.arguments.firstIndex(of: "--threads"))
    let walkers = try #require(Int(plan.stages[0].invocation.arguments[enumeration + 1]))
    let ranking = plan.stages.dropFirst().compactMap { Int($0.invocation.environment["GOMAXPROCS"] ?? "") }
    #expect(ranking.count == 3)
    #expect(ranking.reduce(walkers, +) == 8)
    query.options.workers = 3
    #expect(try SearchPlanner(tools: tools()).plan(query).direct?.executable == tools().worker)
    query.options.workers = 0
    query.files = .all((0..<13).map { .leaf(.text(.init(.absolute, .fuzzy, "term\($0)"))) })
    #expect(try SearchPlanner(tools: tools()).plan(query).direct?.executable == tools().worker)
}
