import Foundation

package enum AISearchCLI {
    package static func run(_ args: [String]) async throws -> Int32 {
        let settings = AISearchSettings.load()
        switch args.first {
        case "schema" where args.count == 1:
            print(String(decoding: try JSONSerialization.data(withJSONObject: AISearchGrammar.schema, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        case "models" where args.count == 1 || args.count == 2:
            let selected: AISearchSettings
            if args.count == 2 {
                if let connection = AISearchConnection.allCases.first(where: { $0.rawValue.lowercased() == args[1].lowercased() && $0 != .custom }) {
                    var value = AISearchSettings(); value.selectConnection(connection); selected = value
                }
                else { selected = try JSONDecoder().decode(AISearchSettings.self, from: HeadlessCLI.input(args[1])) }
            } else {
                selected = await AISearchSettings.resolve(configurationData: AISearchSettings.preferences.data(forKey: AISearchSettings.preferencesKey)).settings
            }
            let key = selected.provider != .codex && !AISearchModelCatalog.isOpenRouter(selected)
                ? try AISearchCredentials.read(account: selected.credentialAccount) ?? "" : ""
            let models = try await AISearchModelCatalog.fetch(settings: selected, apiKey: key)
            print(try HeadlessCLI.encoded(models))
        case "configure" where args.count == 2:
            let value = try JSONDecoder().decode(AISearchSettings.self, from: HeadlessCLI.input(args[1]))
            if value.enabled { try value.validate() }
            try value.save()
            print("AI Search settings saved.")
        case "status" where args.count == 1:
            let resolution = await AISearchSettings.resolve(configurationData: AISearchSettings.preferences.data(forKey: AISearchSettings.preferencesKey))
            let settings = resolution.settings
            var object: [String: Any] = ["enabled": settings.enabled, "provider": settings.provider.rawValue,
                                        "connection": settings.connection.rawValue,
                                        "automaticallyDetected": resolution.automaticallyDetected]
            if settings.provider == .codex {
                let status: CodexSearchStatus
                if let detected = resolution.codexStatus { status = detected }
                else { status = await CodexSearchClient.status(preferred: settings.codexPath) }
                object["codex"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status))
            } else {
                object["url"] = try settings.endpoint().absoluteString; object["model"] = settings.model
                object["hasAPIKey"] = try AISearchCredentials.contains(account: settings.credentialAccount) as Any? ?? NSNull()
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        case "key" where args.count == 2 && ["set", "remove"].contains(args[1]):
            guard settings.provider != .codex else { throw AISearchError.message("Select an API provider before saving a key.") }
            let key: String
            if args[1] == "set" {
                let data = try FileHandle.standardInput.read(upToCount: 16 * 1024 + 1) ?? Data()
                guard !data.isEmpty, data.count <= 16 * 1024, let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AISearchError.message("Pass one API key on stdin (at most 16 KB).") }
                key = text
            } else { key = "" }
            try AISearchCredentials.write(key, account: settings.credentialAccount)
            print(key.isEmpty ? "API key removed." : "API key saved in Keychain.")
        case "apply" where args.count == 3:
            let state = try JSONDecoder().decode(SearchState.self, from: HeadlessCLI.input(args[2]))
            let result = try AISearchGrammar.decode(HeadlessCLI.input(args[1]), relativeTo: state)
            guard let proposed = result.state else { throw AISearchError.message(result.clarification ?? "No proposed search.") }
            print(try HeadlessCLI.encoded(proposed))
        case "propose" where args.count == 3:
            let state = try JSONDecoder().decode(SearchState.self, from: HeadlessCLI.input(args[2])), now = Date()
            let settings = await AISearchSettings.resolve(configurationData: AISearchSettings.preferences.data(forKey: AISearchSettings.preferencesKey)).settings
            let proposal = try await AISearchService(settings: settings).propose(args[1], state: state, now: now)
            var output: [String: Any] = ["summary": proposal.summary, "clarification": proposal.clarification as Any? ?? NSNull()]
            if let state = proposal.state {
                output["state"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                output["referenceDate"] = now.timeIntervalSinceReferenceDate
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        default: throw AISearchError.message("Use ai schema|status, ai models [openrouter|openai|anthropic|google|codex|@settings.json], ai configure JSON|@settings.json, ai key set|remove, ai propose DESCRIPTION JSON|@state.json, or ai apply JSON|@proposal.json JSON|@state.json.")
        }
        return 0
    }
}
