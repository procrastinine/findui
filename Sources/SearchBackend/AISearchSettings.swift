import Foundation
import Security

package enum AISearchProvider: String, Codable, CaseIterable, Sendable {
    case compatible, anthropic, codex
    package var title: String {
        switch self {
        case .compatible: "OpenAI compatible API"
        case .anthropic: "Anthropic API"
        case .codex: "ChatGPT via Codex"
        }
    }
}

/// Presets select an endpoint and wire format; keys remain scoped to URLs.
package enum AISearchConnection: String, Codable, CaseIterable, Sendable {
    case codex, openRouter, openAI, anthropic, google, custom
    package var title: String {
        switch self {
        case .codex: "ChatGPT via Codex"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic (Claude)"
        case .google: "Google (Gemini)"
        case .custom: "Custom URL"
        }
    }
    package var provider: AISearchProvider {
        self == .codex ? .codex : self == .anthropic ? .anthropic : .compatible
    }
    package var baseURL: String {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .codex, .custom: ""
        }
    }
    package var defaultModel: String {
        switch self {
        case .codex, .openAI: "gpt-6.1-sol"
        case .openRouter: "google/gemini-3.8-flash"
        case .anthropic: "claude-sonnet-5-5"
        case .google: "gemini-3.8-flash"
        case .custom: ""
        }
    }
}

/// Configuration is shared by the GUI and headless clients. Credentials never
/// enter saved searches, preferences, command exports, or prompts.
package struct AISearchSettings: Codable, Equatable, Sendable {
    package var enabled = false
    package var provider: AISearchProvider = .compatible
    package var baseURL = "https://openrouter.ai/api/v1"
    package var model = "google/gemini-3.8-flash"
    package var codexModel = "gpt-6.1-sol"
    package var codexPath = ""
    // Optional for compatibility with existing settings. An explicit Custom
    // choice stays editable even while its URL equals a built-in preset.
    package var connectionOverride: AISearchConnection?
    package init() {}
    package var connection: AISearchConnection {
        if provider == .codex { return .codex }
        if connectionOverride == .custom { return .custom }
        guard let endpoint = try? endpoint() else { return .custom }
        return AISearchConnection.allCases.first { choice in
            guard choice != .custom, choice.provider == provider else { return false }
            var preset = Self(); preset.provider = choice.provider; preset.baseURL = choice.baseURL
            return (try? preset.endpoint()) == endpoint
        } ?? .custom
    }
    package mutating func selectConnection(_ choice: AISearchConnection) {
        if choice == .custom {
            if provider == .codex { provider = .compatible }
            connectionOverride = .custom
        } else {
            provider = choice.provider; connectionOverride = nil
            if choice != .codex { baseURL = choice.baseURL; model = choice.defaultModel }
        }
    }
    package static let preferencesKey = "AISearchConfiguration"
    package static var preferences: UserDefaults {
        Bundle.main.bundleIdentifier == "com.codex.findui" ? .standard : UserDefaults(suiteName: "com.codex.findui") ?? .standard
    }
    package static func load(from defaults: UserDefaults = preferences) -> Self {
        guard let data = defaults.data(forKey: preferencesKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    /// A saved configuration is an explicit choice, including disabled AI.
    /// Discovering a login supplies an in-memory default only; it never saves
    /// preferences, reads OAuth tokens, or sends an inference request.
    package static func resolve(configurationData: Data?,
        detectCodex: @Sendable (String) async -> CodexSearchStatus = { await CodexSearchClient.status(preferred: $0) }
    ) async -> AISearchSettingsResolution {
        if let configurationData {
            return .init(settings: (try? JSONDecoder().decode(Self.self, from: configurationData)) ?? .init(),
                         codexStatus: nil, automaticallyDetected: false)
        }
        var settings = Self()
        let status = await detectCodex(settings.codexPath)
        guard !Task.isCancelled else { return .init(settings: settings, codexStatus: nil, automaticallyDetected: false) }
        if status.available { settings.provider = .codex; settings.enabled = true }
        return .init(settings: settings, codexStatus: status, automaticallyDetected: status.available)
    }
    package func save(to defaults: UserDefaults = preferences) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferencesKey)
    }
    package func endpoint() throws -> URL {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw AISearchError.message("Use an HTTPS API URL, or HTTP for a server on localhost. Put the key in API key, not in the URL.")
        }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = provider == .anthropic ? "messages" : "chat/completions"
        if parts.path != suffix && !parts.path.hasSuffix("/" + suffix) { parts.path += (parts.path.isEmpty ? "" : "/") + suffix }
        parts.path = "/" + parts.path
        guard let url = parts.url else { throw AISearchError.message("The API URL is invalid.") }
        return url
    }
    package var credentialAccount: String { get throws { try endpoint().absoluteString } }
    package func validate() throws {
        guard enabled else { throw AISearchError.message("Enable AI Search in Settings first.") }
        if provider != .codex {
            _ = try endpoint()
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 200, !model.contains(where: \.isNewline) else {
                throw AISearchError.message("Enter the model ID supplied by your API provider.")
            }
        } else if codexModel.count > 200 || codexModel.contains(where: \.isNewline) {
            throw AISearchError.message("The Codex model ID is invalid.")
        }
    }
}

package struct AISearchSettingsResolution: Sendable {
    package let settings: AISearchSettings
    package let codexStatus: CodexSearchStatus?
    package let automaticallyDetected: Bool
}

package enum AISearchError: LocalizedError, Sendable {
    case message(String)
    package var errorDescription: String? { switch self { case .message(let message): message } }
}

package enum AISearchCredentials {
    private static let service = "FindUI.AISearch"
    /// Query item existence only, without requesting its secret or allowing a
    /// Keychain access prompt merely because Settings was opened.
    package static func contains(account: String) throws -> Bool? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed { return nil }
        throw AISearchError.message("Couldn’t check Keychain (\(status)).")
    }
    package static func read(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AISearchError.message("Couldn’t read the API key from Keychain (\(status)).")
        }
        return key
    }
    package static func write(_ key: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AISearchError.message("Couldn’t remove the API key (\(status)).") }
            return
        }
        guard !trimmed.contains(where: \.isNewline) else { throw AISearchError.message("The API key must fit on one line.") }
        let values: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var add = query.merging(values) { _, rhs in rhs }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AISearchError.message("Couldn’t save the API key in Keychain (\(status)).") }
    }
}
