import Foundation

package enum DocumentAccess {
    package struct Request: Codable, Sendable {
        package var path: String
        package var origin: ExtractedMatchOrigin
        package var extraction: SearchExtractionOptions = .init()
        package var context = 3
        package var expectedSnippet: String? = nil
        package var encoding: String? = nil
        package init(path: String, origin: ExtractedMatchOrigin, extraction: SearchExtractionOptions = .init(), context: Int = 3, expectedSnippet: String? = nil, encoding: String? = nil) {
            self.path = path
            self.origin = origin
            self.extraction = extraction
            self.context = context
            self.expectedSnippet = expectedSnippet
            self.encoding = encoding
        }

    }
    package static func command(_ action: String, request: Request, tools: Toolchain = .resolve()) throws -> CommandSpec {
        guard request.origin.sourceIdentity != nil else {
            throw SearchServiceError.commandFailed("Run this search again to obtain a document location.")
        }
        guard let worker = tools.contentWorker ?? Toolchain.locateContentWorker() else { throw SearchServiceError.missingTool("findui-content") }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        var extraction = try request.extraction.plan(tools: tools)
        extraction["encoding"] = request.encoding as Any? ?? NSNull()
        json["extraction"] = extraction
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return CommandSpec(executable: worker, arguments: [action, String(decoding: data, as: UTF8.self)])
    }
    package static func preview(_ request: Request) async throws -> ContentPreview {
        let result = try await ProcessRunner.run(spec: command("--document-preview", request: request), pathOverride: Toolchain.resolve().searchPath)
        guard result.exitCode == 0 else { throw SearchServiceError.commandFailed(result.stderr) }
        return try JSONDecoder().decode(ContentPreview.self, from: Data(result.stdout.utf8))
    }
    package static func materialize(_ request: Request) async throws -> URL {
        let result = try await ProcessRunner.run(spec: command("--materialize-member", request: request), pathOverride: Toolchain.resolve().searchPath)
        guard result.exitCode == 0 else { throw SearchServiceError.commandFailed(result.stderr) }
        struct Materialized: Decodable { let path: String }
        return URL(fileURLWithPath: try JSONDecoder().decode(Materialized.self, from: Data(result.stdout.utf8)).path)
    }
}

package actor DocumentMaterializer {
    package static let shared = DocumentMaterializer()
    private var files: [String: URL] = [:]
    private var pending: [String: Task<URL, Error>] = [:]
    private var generation = 0
    package func file(_ request: DocumentAccess.Request) async throws -> URL {
        let key = request.path + "\0" + (request.origin.sourceIdentity ?? "") + "\0" + (request.origin.recordKey ?? "")
            + "\0" + (request.origin.members ?? []).map { ($0.kind ?? "archive") + ":" + String($0.index) }.joined(separator: "/")
        if let file = files[key], FileManager.default.fileExists(atPath: file.path) {
            let verified = try await ProcessRunner.run(spec: DocumentAccess.command("--verify-document", request: request), pathOverride: Toolchain.resolve().searchPath)
            guard verified.exitCode == 0 else { throw SearchServiceError.commandFailed(verified.stderr) }
            return file
        }
        let epoch = generation
        let task = pending[key] ?? Task { try await DocumentAccess.materialize(request) }
        pending[key] = task
        let file: URL
        do { file = try await task.value }
        catch { pending[key] = nil; throw error }
        pending[key] = nil
        guard generation == epoch else { try? FileManager.default.removeItem(at: file); throw CancellationError() }
        if let existing = files[key] { return existing }
        files[key] = file
        return file
    }
    package func clear() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
        for file in files.values { try? FileManager.default.removeItem(at: file) }
        files.removeAll()
    }
}

extension DocumentAccess.Request {
    package enum CodingKeys: String, CodingKey { case path, origin, extraction, context, expectedSnippet, encoding }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        origin = try values.decode(ExtractedMatchOrigin.self, forKey: .origin)
        extraction = try values.decodeIfPresent(SearchExtractionOptions.self, forKey: .extraction) ?? .init()
        context = try values.decodeIfPresent(Int.self, forKey: .context) ?? 3
        expectedSnippet = try values.decodeIfPresent(String.self, forKey: .expectedSnippet)
        encoding = try values.decodeIfPresent(String.self, forKey: .encoding)
    }
}
