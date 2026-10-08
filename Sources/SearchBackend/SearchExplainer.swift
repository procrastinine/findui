import Foundation

package struct SearchExplanation: Codable, Identifiable, Sendable {
    package struct Step: Codable, Sendable { package let title: String; package let passed: Bool; package let detail: String
        package init(title: String, passed: Bool, detail: String) {
            self.title = title
            self.passed = passed
            self.detail = detail
        }
}
    package var id = UUID()
    package let path: String
    package var steps: [Step] = []
    package var command = ""
    package var summary: String { steps.last?.detail ?? "No explanation available." }
    package init(id: UUID = UUID(), path: String, steps: [Step] = [], command: String = "") {
        self.id = id
        self.path = path
        self.steps = steps
        self.command = command
    }

}

/// A headless diagnostic runs the same traversal and compiled predicates on one
/// selected path. Views only present the resulting report.
package struct SearchExplainer {
    package let tools: Toolchain
    package func explain(_ original: SearchRequest, file: URL, snapshot: URL? = nil) async throws -> SearchExplanation {
        guard original.state.nativeCommand == nil else {
            throw SearchServiceError.commandFailed("This search uses the displayed native command. Switch to search controls to explain individual conditions.")
        }
        var report = SearchExplanation(path: file.path)
        report.command = try HeadlessCLI.explainCommand(original, file: file, snapshot: snapshot)
        let suppliedPath = file.path
        let file = original.scopes.lazy.compactMap { scope -> URL? in
            SearchPath.relativePath(of: file, in: scope).map { scope.appendingPathComponent($0) }
        }.first ?? file
        var request = original
        // Match `search --snapshot`: an explicit artifact chooses the source,
        // even when the saved state originally described a live search.
        if snapshot != nil { request.useIndex = true }
        if request.useIndex {
            guard let snapshot else { throw SearchServiceError.commandFailed("Choose a saved snapshot before explaining this search.") }
            let prepared = try await PreparedSearch.snapshot(request: request, at: snapshot, tools: tools)
            guard let index = prepared.index, let frozen = prepared.snapshot else { throw SearchServiceError.missingIndex }
            let relative = SearchPath.relativePath(of: file, in: index.scopeURL)
            let recordedPath = relative.map { index.scopeURL.appendingPathComponent($0).path }
            let present = try recordedPath.map { try frozen.recordedEntry($0) != nil } ?? false
            report.steps.append(.init(title: "Snapshot", passed: present, detail: present ? "This path is recorded in the snapshot." : "This path is absent from the snapshot. Refresh it to include recent changes."))
            guard present else { return report }
            try request.state.promoteToRules()
            var rules = request.state.ruleSet!
            rules.addFileCondition(.path(file.path, .exact, absolute: true))
            request.state.replaceRules(rules)
            request.maxResults = 1
            let selected = try PreparedSearch(request: request, index: index, snapshot: frozen, tools: tools, location: snapshot)
            let collector = SearchResultCollector()
            _ = try await selected.stream(tools: tools) { await collector.append($0) }
            let matched = await !collector.results.isEmpty
            report.steps.append(.init(title: "Search conditions", passed: matched, detail: matched ? "The snapshot entry matches this search." : "The snapshot entry does not satisfy the search conditions."))
            return report
        }
        if request.refinements.source == .spotlight {
            // Ask the selected metadata source itself. A live one-file scope
            // changes the source and cannot evaluate Spotlight predicates.
            try request.state.promoteToRules()
            var rules = request.state.ruleSet!
            rules.addFileCondition(.path(file.path, .exact, absolute: true))
            request.state.replaceRules(rules)
            request.maxResults = 1
            let response = try await SearchService(tools: tools).search(request: request)
            let selected = response.results.contains { $0.path == file.path }
            report.steps.append(.init(title: "Spotlight and search conditions", passed: selected,
                detail: response.warning ?? (selected ? "Spotlight returned this file and the search conditions allow it."
                    : "Spotlight did not return this file with the current search conditions.")))
            return report
        }
        guard let worker = tools.contentWorker else { throw SearchServiceError.missingTool("findui-content") }
        let compiler = SearchPipelineCompiler(tools: tools)
        let configuration: [String: Any] = ["path": file.path, "walk": try compiler.traversalConfiguration(request)]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let traversal = try await ProcessRunner.run(spec: .init(executable: worker, arguments: ["--explain-path", String(decoding: data, as: UTF8.self)]), pathOverride: tools.searchPath)
        guard traversal.exitCode == 0, let result = try JSONSerialization.jsonObject(with: Data(traversal.stdout.utf8)) as? [String: Any] else {
            throw SearchServiceError.commandFailed(traversal.stderr)
        }
        let admitted = result["admitted"] as? Bool == true
        report.steps.append(.init(title: "Scope and exclusions", passed: admitted, detail: result["reason"] as? String ?? "Could not inspect traversal."))
        guard admitted else { return report }
        if let scope = request.state.resultScope {
            let aliases = Set([suppliedPath, file.path, file.resolvingSymlinksInPath().path])
            let included = try Data(contentsOf: URL(fileURLWithPath: scope.path)).split(separator: 0).contains {
                String(data: $0, encoding: .utf8).map(aliases.contains) == true
            }
            report.steps.append(.init(title: "Saved results", passed: included, detail: included ? "Included in the saved result list." : "This file is absent from the saved result list."))
            guard included else { return report }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("findui-explain-\(UUID())")
        try Data((file.path + "\0").utf8).write(to: temporary, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporary) }
        request.state.resultScope = .init(path: temporary.path, name: "Selected file", count: 1)
        var fileRequest = request
        try fileRequest.state.promoteToRules()
        let rules = SearchRuleSet(files: fileRequest.state.ruleSet!.candidateFiles)
        fileRequest.state.replaceRules(rules); fileRequest.refinements.wordSearch = nil
        var fileQuery = try fileRequest.normalizedQuery()
        fileQuery.action = .search
        let filePipeline = try compiler.compile(fileQuery)
        let collector = SearchResultCollector()
        _ = try await SearchService(tools: tools).streamSearch(request: fileRequest, pipeline: filePipeline) { await collector.append($0) }
        let selected = await collector.results.contains { $0.path == file.path }
        report.steps.append(.init(title: "File conditions", passed: selected, detail: selected ? "Filename, path, type, date, size and tag conditions allow this file." : "The file conditions exclude this path."))
        guard selected else { return report }
        if request.mode == .contents {
            if let format = result["format"] as? String, !format.isEmpty {
                report.steps.append(.init(title: "Detected format", passed: true, detail: format.uppercased()))
            }
            request.maxResults = 1; request.refinements.matchingFilesOnly = true
            do {
                let response = try await SearchService(tools: tools).search(request: request)
                report.steps.append(.init(title: "Contents", passed: !response.results.isEmpty,
                    detail: response.warning ?? (response.results.isEmpty ? "No content matched with the current document, archive, encoding and matching options." : "This file has matching content.")))
            } catch {
                report.steps.append(.init(title: "Contents", passed: false, detail: error.localizedDescription))
            }
        } else { report.steps.append(.init(title: "Result", passed: true, detail: "This file matches the search.")) }
        // The report remains reproducible after the temporary one-file list is removed.
        report.command = try HeadlessCLI.explainCommand(original, file: file, snapshot: snapshot)
        return report
    }
    package init(tools: Toolchain) {
        self.tools = tools
    }

}
