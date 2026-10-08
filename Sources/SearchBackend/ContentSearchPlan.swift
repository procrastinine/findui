import Foundation
import SearchCore

/// Low-level maintenance commands share the production content configuration.
/// Search execution itself is planned through SearchPipelineCompiler.
package enum ContentSearchPlan {
    package static func command(tree: SearchRuleTree<SearchContentRule>, request: SearchRequest,
                        fileUnit: Bool, tools: Toolchain, ordered: Bool = false, action: String? = nil) throws -> String {
        guard let worker = tools.contentWorker else { throw SearchServiceError.missingTool("findui-content") }
        var request = request
        try request.state.promoteToRules(now: request.referenceDate)
        var rules = SearchRuleSet(files: request.state.ruleSet!.candidateFiles, contents: tree)
        rules.contentUnit = fileUnit ? (request.state.ruleSet?.contentUnit == .file ? .file : .document) : .line
        request.state.replaceRules(rules)
        var query = try request.normalizedQuery()
        tools.resolveReaders(in: &query)
        guard var content = try SearchPlanner(tools: tools.capabilities).workerRequest(query).content else { throw SearchServiceError.invalidQuery }
        content.ordered = ordered
        return Invocation(worker.path, [action ?? "--plan", try encodeSearchJSON(content)]).shell
    }
}
