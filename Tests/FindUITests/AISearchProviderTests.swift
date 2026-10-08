@testable import SearchBackend
import Foundation
import Testing

@Test func aiProviderPresetsKeepDistinctEndpointsAndExistingSettings() throws {
    let expected: [(AISearchConnection, String, String)] = [
        (.openRouter, "https://openrouter.ai/api/v1/chat/completions", "google/gemini-3.8-flash"),
        (.openAI, "https://api.openai.com/v1/chat/completions", "gpt-6.1-sol"),
        (.anthropic, "https://api.anthropic.com/v1/messages", "claude-sonnet-5-5"),
        (.google, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-3.8-flash")]
    var accounts = Set<String>()
    for (choice, endpoint, model) in expected {
        var settings = AISearchSettings(); settings.enabled = true; settings.selectConnection(choice)
        try settings.validate()
        #expect(settings.connection == choice && settings.model == model)
        #expect(try settings.endpoint().absoluteString == endpoint)
        #expect(try accounts.insert(settings.credentialAccount).inserted)
        settings.baseURL += "/"
        #expect(try settings.credentialAccount == endpoint)
        settings.baseURL = endpoint
        #expect(try settings.credentialAccount == endpoint)
        settings.selectConnection(.custom)
        #expect(settings.connection == .custom && settings.model == model)
        #expect(settings.provider == choice.provider)
        #expect(try settings.credentialAccount == endpoint)
        #expect(try JSONDecoder().decode(AISearchSettings.self, from: JSONEncoder().encode(settings)).connection == .custom)
    }
    let old = Data(#"{"enabled":false,"provider":"compatible","baseURL":"https://api.openai.com/v1","model":"my-saved-model","codexModel":"","codexPath":""}"#.utf8)
    let restored = try JSONDecoder().decode(AISearchSettings.self, from: old)
    #expect(restored.connection == .openAI && restored.model == "my-saved-model" && !restored.enabled)
    var custom = restored; custom.selectConnection(.custom); custom.baseURL = "http://localhost:8000/v1"
    let first = try custom.credentialAccount
    custom.baseURL = "http://localhost:8000/another/v1"
    #expect(try custom.credentialAccount != first)
}

@Test func aiAnthropicRequestsKeepNativeAuthenticationAndSharedGrammar() throws {
    var settings = AISearchSettings(); settings.selectConnection(.anthropic)
    let schema = try JSONSerialization.data(withJSONObject: AISearchGrammar.schema, options: [.sortedKeys])
    let messages: [AISearchMessage] = [.init("system", AISearchService.instructions), .init("user", "Find reports"),
        .init("assistant", "invalid prior output"), .init("user", "Repair the output")]
    let request = try AISearchHTTPClient(settings: settings, apiKey: "anthropic-fixture").request(messages: messages, schema: schema)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-fixture")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["model"] as? String == "claude-sonnet-5-5")
    #expect(body["max_tokens"] as? Int == 8192)
    #expect(body["tools"] == nil && body["output_config"] == nil && body["response_format"] == nil)
    #expect((body["messages"] as? [[String: String]])?.map { $0["role"] } == ["user", "assistant", "user"])
    #expect((body["system"] as? String)?.contains(String(decoding: schema, as: UTF8.self)) == true)
    #expect(!String(decoding: data, as: UTF8.self).contains("anthropic-fixture"))
}

@Test func aiDirectProviderRequestsUseTheirOwnModelIDsAndBudgets() throws {
    let schema = try JSONSerialization.data(withJSONObject: AISearchGrammar.schema)
    for choice in [AISearchConnection.openAI, .google, .openRouter] {
        var settings = AISearchSettings(); settings.selectConnection(choice)
        let request = try AISearchHTTPClient(settings: settings, apiKey: choice.rawValue + "-fixture").request(
            messages: [.init("system", AISearchService.instructions), .init("user", "Find reports")],
            schema: schema, strict: choice == .openAI)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + choice.rawValue + "-fixture")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == choice.defaultModel)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == (choice == .openAI ? "json_schema" : "json_object"))
        if choice == .google {
            #expect(body["reasoning_effort"] as? String == "low")
            #expect(body["max_tokens"] as? Int == 8192 && body["max_completion_tokens"] == nil)
        }
        if choice != .openRouter { #expect(body["provider"] == nil && body["reasoning"] == nil) }
    }
}

@Test func aiAnthropicResponsesRejectIncompleteRefusedAndToolOutput() throws {
    var response: [String: Any] = ["type": "message", "role": "assistant", "stop_reason": "end_turn",
        "content": [["type": "thinking", "thinking": "private reasoning"], ["type": "text", "text": "{}"]]]
    #expect(try AISearchHTTPClient.anthropicOutput(JSONSerialization.data(withJSONObject: response)) == "{}")
    for reason in ["max_tokens", "tool_use", "pause_turn", "refusal"] {
        var invalid = response; invalid["stop_reason"] = reason
        #expect(throws: (any Error).self) { try AISearchHTTPClient.anthropicOutput(JSONSerialization.data(withJSONObject: invalid)) }
    }
    response["content"] = [["type": "tool_use", "name": "run_search"]]
    #expect(throws: (any Error).self) { try AISearchHTTPClient.anthropicOutput(JSONSerialization.data(withJSONObject: response)) }
    response["content"] = [["type": "text", "text": "{}"]]
    response["stop_details"] = ["type": "refusal"]
    #expect(throws: (any Error).self) { try AISearchHTTPClient.anthropicOutput(JSONSerialization.data(withJSONObject: response)) }
}

@Test func aiCatalogUsesProviderSpecificHeadersNamesAndBoundedPageCursors() throws {
    var settings = AISearchSettings(); settings.selectConnection(.anthropic)
    let request = try AISearchModelCatalog.request(settings: settings, apiKey: "anthropic-fixture", afterID: "last/model&id")
    #expect(request.url?.path == "/v1/models")
    let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.contains(.init(name: "limit", value: "1000")))
    #expect(query.contains(.init(name: "after_id", value: "last/model&id")))
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-fixture")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let page = try AISearchModelCatalog.page(Data(#"{"data":[{"id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5"}],"has_more":true,"last_id":"claude-sonnet-5-5"}"#.utf8))
    #expect(page.models.first?.name == "Claude Sonnet 5.5" && page.nextCursor == "claude-sonnet-5-5")
    #expect(throws: (any Error).self) { try AISearchModelCatalog.page(Data(#"{"data":[],"has_more":true}"#.utf8)) }
    settings.selectConnection(.google)
    let google = try AISearchModelCatalog.request(settings: settings, apiKey: "google-fixture")
    #expect(google.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/models")
    #expect(google.value(forHTTPHeaderField: "Authorization") == "Bearer google-fixture")
}
