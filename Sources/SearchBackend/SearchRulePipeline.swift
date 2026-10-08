import Foundation

/// Grouped controls use the same normalization and planner as compact controls.
package struct SearchRulePipelineCompiler {
    package let tools: Toolchain
    package func compile(_ original: SearchRequest, rules: SearchRuleSet) throws -> SearchPipeline {
        var request = original
        request.state.replaceRules(rules)
        return try SearchPipelineCompiler(tools: tools).compile(request)
    }
    package init(tools: Toolchain) {
        self.tools = tools
    }

}
