import Foundation

package struct AISearchModelOption: Codable, Hashable, Identifiable, Sendable {
    package let id: String
    package let name: String
    package init(id: String, name: String) { self.id = id; self.name = name }
}

/// Model discovery shares URL/key boundaries with generation. OpenRouter's
/// catalog is public and never needs an API key or Keychain access.
package enum AISearchModelCatalog {
    package static func isOpenRouter(_ settings: AISearchSettings) -> Bool {
        guard let endpoint = try? settings.endpoint() else { return false }
        return endpoint.scheme == "https" && endpoint.host?.lowercased() == "openrouter.ai" && endpoint.path == "/api/v1/chat/completions"
    }
    package static func isGoogle(_ settings: AISearchSettings) -> Bool {
        guard let endpoint = try? settings.endpoint() else { return false }
        return endpoint.scheme == "https" && endpoint.host?.lowercased() == "generativelanguage.googleapis.com"
            && endpoint.path == "/v1beta/openai/chat/completions"
    }
    package static func request(settings: AISearchSettings, apiKey: String = "", afterID: String? = nil) throws -> URLRequest {
        let endpoint = try settings.endpoint()
        let base = settings.provider == .anthropic ? endpoint.deletingLastPathComponent()
            : endpoint.deletingLastPathComponent().deletingLastPathComponent()
        var parts = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        if settings.provider == .anthropic { parts.queryItems = [.init(name: "limit", value: "1000")] }
        if let afterID { parts.queryItems = (parts.queryItems ?? []) + [.init(name: "after_id", value: afterID)] }
        guard let url = parts.url else { throw AISearchError.message("The model catalog URL is invalid.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !isOpenRouter(settings) { AISearchHTTPClient.authorize(&request, settings: settings, apiKey: apiKey) }
        return request
    }
    package static func decode(_ data: Data) throws -> [AISearchModelOption] {
        try page(data).models
    }
    package static func page(_ data: Data) throws -> (models: [AISearchModelOption], nextCursor: String?) {
        guard data.count <= 16 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]], models.count <= 10000 else {
            throw AISearchError.message("The provider returned an invalid model catalog. You can still enter a model ID.")
        }
        var seen = Set<String>()
        let values = models.compactMap { model -> AISearchModelOption? in
            guard let id = model["id"] as? String, !id.isEmpty, id.count <= 200,
                  !id.contains(where: \.isNewline), seen.insert(id).inserted else { return nil }
            if let architecture = model["architecture"] as? [String: Any],
               let outputs = architecture["output_modalities"] as? [String], !outputs.contains("text") { return nil }
            let name = ((model["name"] ?? model["display_name"]) as? String).flatMap { $0.isEmpty || $0.count > 300 ? nil : $0 } ?? id
            return .init(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var cursor: String?
        if object["has_more"] as? Bool == true {
            guard let value = object["last_id"] as? String, !value.isEmpty, value.count <= 200,
                  !value.contains(where: \.isNewline) else {
                throw AISearchError.message("The provider returned an invalid model catalog cursor. You can still enter a model ID.")
            }
            cursor = value
        }
        return (values, cursor)
    }
    package static func fetch(settings: AISearchSettings, apiKey: String = "") async throws -> [AISearchModelOption] {
        if settings.provider == .codex { return codexModels() }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: AINoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var cursor: String?, seenCursors = Set<String>(), seenModels = Set<String>()
        var models: [AISearchModelOption] = [], totalBytes = 0
        for _ in 0..<20 {
            let (bytes, response) = try await session.bytes(for: request(settings: settings, apiKey: apiKey, afterID: cursor))
            guard let response = response as? HTTPURLResponse else { throw AISearchError.message("The model catalog did not return an HTTP response.") }
            guard (200..<300).contains(response.statusCode) else {
                throw AISearchError.message("Couldn’t load models (HTTP \(response.statusCode)). Check the API URL/key, or enter a model ID.")
            }
            var data = Data()
            for try await byte in bytes {
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                guard totalBytes < 16 * 1024 * 1024 else { throw AISearchError.message("The model catalog is too large. Enter a model ID.") }
                data.append(byte); totalBytes += 1
            }
            let decoded = try page(data)
            models += decoded.models.filter { seenModels.insert($0.id).inserted }
            guard models.count <= 10000 else { throw AISearchError.message("The model catalog is too large. Enter a model ID.") }
            guard let next = decoded.nextCursor else {
                return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            guard seenCursors.insert(next).inserted else { throw AISearchError.message("The provider repeated a model catalog page. Enter a model ID.") }
            cursor = next
        }
        throw AISearchError.message("The model catalog has too many pages. Enter a model ID.")
    }
    private static func codexModels() -> [AISearchModelOption] {
        // This optional local catalog contains public model metadata, not auth.
        // Codex owns its refresh; newer explicit IDs remain selectable even if
        // the cache predates them. Never inspect login/token files.
        var values = [AISearchModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
            .init(id: "gpt-6-astra", name: "GPT-6 Astra"), .init(id: "gpt-6-luna", name: "GPT-6 Luna")]
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let url = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("models_cache.json")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
           let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = object["models"] as? [[String: Any]] {
            values += models.compactMap { model in
                guard model["visibility"] as? String == "list", let id = model["slug"] as? String,
                      !id.isEmpty, id.count <= 200, !id.contains(where: \.isNewline) else { return nil }
                return .init(id: id, name: model["display_name"] as? String ?? id)
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}
