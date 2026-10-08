import Foundation
import SearchCore

/// The app consumes a typed, headless execution plan. Rendering a command never
/// determines execution, membership, stream format, or optimizer eligibility.
package struct SearchPipeline: Sendable {
    package let plan: ExecutionPlan
    package var importHeader = ""
    package var engineName: String { plan.engineName }
    package var outputIsJSON: Bool { plan.output != .paths && plan.output != .text }
    package var exportBody: String { importHeader + plan.command }
    package var script: String { importHeader.isEmpty ? plan.command : Self.command(exportBody).shellString }
    package var executionScript: String { plan.command }
    package var displayCommand: String { plan.direct?.arguments.first == "--execute" ? plan.engineName : plan.command }
    package var spec: CommandSpec { CommandSpec(plan.invocation) }
    package var emptyExitCodes: [Int32] { plan.invocation.emptyExitCodes }
    package var requiresCompletion: Bool { plan.stages.contains { $0.invocation.arguments.first == "--execute" } }
    // Diagnostic views of stages; composition itself uses PlanStage, not strings.
    package var enumeration: String { plan.stages[0].invocation.shell }
    package var stages: [String] { plan.stages.dropFirst().map(\.invocation.shell) }
    package static let preamble = "set -o pipefail\n"
    package static func command(_ script: String) -> CommandSpec {
        CommandSpec(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["--noprofile", "--norc", "-c", script])
    }
    package init(plan: ExecutionPlan, importHeader: String = "") {
        self.plan = plan
        self.importHeader = importHeader
    }

}
extension CommandSpec {
    package init(_ invocation: Invocation) {
        if invocation.environment.isEmpty && invocation.unsetEnvironment.isEmpty {
            self.init(executable: URL(fileURLWithPath: invocation.executable, isDirectory: false), arguments: invocation.arguments,
                workingDirectory: invocation.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        } else {
            self.init(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments:
                invocation.unsetEnvironment.flatMap { ["-u", $0] }
                + invocation.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                + [invocation.executable] + invocation.arguments,
                workingDirectory: invocation.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
    }
}
package struct SearchPipelineCompiler {
    package let tools: Toolchain
    package func compile(_ request: SearchRequest, now: Date? = nil, source: QuerySource? = nil,
                         includeCommandMetadata: Bool = true) throws -> SearchPipeline {
        var timed = SearchCommandExport.restoringContext(request).resolvingBrowseAction()
        if let now { timed.referenceDate = now }
        if let native = timed.state.nativeCommand {
            guard source == nil, !timed.useIndex, !timed.isDirectoryListing,
                !timed.buildContentIndex, !timed.buildWordIndex, timed.state.resultScope == nil else {
                throw SearchServiceError.commandFailed("A command search cannot be combined with snapshot, index-building, or saved-file-scope options.")
            }
            var pipeline = try native.pipeline(tools: tools, state: timed.state)
            // Copied snapshot searches already contain their entire typed
            // request, clock and artifact. Render the parsed argv directly.
            if includeCommandMetadata && pipeline.plan.direct?.executable != HeadlessCLI.executable.path {
                pipeline.importHeader = try SearchCommandExport(timed, tools: tools).header()
            }
            return pipeline
        }
        var query = try timed.normalizedQuery(source: source)
        tools.resolveReaders(in: &query)
        var pipeline = try compile(query)
        if includeCommandMetadata && (SearchCommandExport.needsExecutionMetadata(timed) || query.contents.map({ $0.single == nil }) == true || pipeline.plan.stages.count != 1 || ![tools.fd?.path, tools.rg?.path].contains(pipeline.plan.direct?.executable)) {
            pipeline.importHeader = try SearchCommandExport(timed, tools: tools).header()
        }
        return pipeline
    }
    package func compile(_ query: SearchQuery) throws -> SearchPipeline {
        if query.source.kind == .live || query.source.kind == .manifest {
            for root in query.traversal.roots {
                var directory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: root, isDirectory: &directory), directory.boolValue else {
                    throw SearchServiceError.commandFailed("Search folder is unavailable: \(root)")
                }
            }
        }
        do { return SearchPipeline(plan: try SearchPlanner(tools: tools.capabilities).plan(query)) }
        catch let error as PlanningError {
            switch error { case .missingTool(let tool): throw SearchServiceError.missingTool(tool)
            case .invalid(let reason): throw SearchServiceError.commandFailed(reason) }
        }
    }
    package func enumerate(_ request: SearchRequest, bounds: ValidatedSearchFilters? = nil) throws -> String {
        var query = try request.normalizedQuery()
        query.files = .all([]); query.contents = nil; query.expression = nil; query.unit = .line; query.action = .search
        if let bounds, bounds.minimumSize != nil || bounds.maximumSize != nil {
            query.files = .leaf(.size(.init(minimum: bounds.minimumSize.map(UInt64.init), maximum: bounds.maximumSize.map(UInt64.init))))
        }
        return try compile(query).script
    }
    package func traversalConfiguration(_ request: SearchRequest, bounds: ValidatedSearchFilters? = nil) throws -> [String: Any] {
        var value = WalkConfiguration(try request.normalizedQuery())
        value.minimum = bounds?.minimumSize.map(UInt64.init); value.maximum = bounds?.maximumSize.map(UInt64.init)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    package static func command(_ executable: String, _ args: [String]) -> String { Invocation(executable, args).shell }
    package static func escapeRegex(_ text: String) -> String { SearchCore.escapeRegex(text) }
    package static func glob(_ value: String) -> String { SearchCore.globRegex(value) }
    package init(tools: Toolchain) {
        self.tools = tools
    }

}
