import Foundation

package struct WordIndexStatus: Codable, Sendable, Equatable {
    package let state: String
    package let message: String
    package var updated: Int64?
    package var sources: Int?
    package var changedSources: Int?
    package var changedDirectories: Int?
    package var generation: Int64?
    package var verification: String?
    package var title: String {
        switch state {
        case "updated": "Words up to date"
        case "needsUpdate": "Words need updating"
        case "unavailable": "Prepared folder unavailable"
        case "partial": "Words partly prepared"
        default: "Words not prepared"
        }
    }
    package init(
        state: String, message: String, updated: Int64? = nil, sources: Int? = nil, changedSources: Int? = nil,
        changedDirectories: Int? = nil, generation: Int64? = nil
    ) {
        self.state = state
        self.message = message
        self.updated = updated
        self.sources = sources
        self.changedSources = changedSources
        self.changedDirectories = changedDirectories
        self.generation = generation
    }

}

package struct WordSuggestion: Codable, Sendable, Equatable {
    package let text: String
    package let documents: Int
    package init(text: String, documents: Int) {
        self.text = text
        self.documents = documents
    }

}

package enum WordIndexService {
    /// Explicit alternatives for the whole Contents value. Literal/regex modes
    /// never use this, and accepting an alternative is the only state mutation.
    package static func completions(_ request: SearchRequest, text: String, history: [String]) async -> [String] {
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.refinements.wordSearch == true, prefix.count >= 2 else { return [] }
        var values = history.filter {
            $0 != text && $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
        if !prefix.contains(where: \.isWhitespace) {
            values += (try? await suggestions(request, prefix: prefix))?.map(\.text) ?? []
        }
        var seen = Set<String>()
        return Array(values.filter { $0 != text && seen.insert($0).inserted }.prefix(8))
    }
    package static func command(
        _ action: String, request: SearchRequest, prefix: String? = nil, tools: Toolchain = .resolve()
    ) throws -> CommandSpec {
        var request = request
        request.refinements.wordSearch = true
        let command = try ContentSearchPlan.command(
            tree: .rule(.allLines), request: request, fileUnit: true, tools: tools, action: action)
        return SearchPipeline.command(command + (prefix.map { " " + shellQuote($0) } ?? ""))
    }
    package static func status(_ request: SearchRequest) async throws -> WordIndexStatus {
        let response = try await ProcessRunner.run(
            spec: command("--word-status", request: request), pathOverride: Toolchain.resolve().searchPath)
        guard response.exitCode == 0 else { throw SearchServiceError.commandFailed(response.stderr) }
        return try JSONDecoder().decode(WordIndexStatus.self, from: Data(response.stdout.utf8))
    }
    package static func suggestions(_ request: SearchRequest, prefix: String) async throws -> [WordSuggestion] {
        let response = try await ProcessRunner.run(
            spec: command("--word-suggest", request: request, prefix: prefix),
            pathOverride: Toolchain.resolve().searchPath)
        guard response.exitCode == 0 else { throw SearchServiceError.commandFailed(response.stderr) }
        return try JSONDecoder().decode([WordSuggestion].self, from: Data(response.stdout.utf8))
    }
}
