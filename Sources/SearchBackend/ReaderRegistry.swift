import Foundation

package struct ReaderCapability: Codable, Identifiable, Sendable {
    package let id: String
    package let title: String
    package let formats: [String]
    package let option: String
    package let dependency: String
    package let ready: Bool
    package let command: String?
    package init(id: String, title: String, formats: [String], option: String, dependency: String, ready: Bool, command: String? = nil) {
        self.id = id
        self.title = title
        self.formats = formats
        self.option = option
        self.dependency = dependency
        self.ready = ready
        self.command = command
    }

}
package enum ReaderRegistry {
    package static func load(tools: Toolchain = .resolve()) async throws -> [ReaderCapability] {
        guard let worker = tools.contentWorker else { return [] }
        var requested = SearchExtractionOptions(); requested.customReaders = true
        let options = try requested.plan(tools:tools)
        let argument = String(decoding:try JSONSerialization.data(withJSONObject:options,options:[.sortedKeys]),as:UTF8.self)
        let response = try await ProcessRunner.run(spec:.init(executable:worker,arguments:["--readers",argument]),pathOverride:tools.searchPath)
        guard response.exitCode == 0 else { throw SearchServiceError.commandFailed(response.stderr) }
        return try JSONDecoder().decode([ReaderCapability].self,from:Data(response.stdout.utf8))
    }
}
