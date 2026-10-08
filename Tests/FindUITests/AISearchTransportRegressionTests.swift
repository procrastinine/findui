@testable import SearchBackend
import Foundation
import Testing

@Test func codexInstructionPathsAreValidTOMLAndWarningsAreNotToolCalls() throws {
    let configuration = try CodexSearchClient.instructionsConfiguration("/tmp/with \"quotes\" and \\slashes/instructions.txt")
    #expect(!configuration.contains("\\/"))
    #expect(configuration.contains("\\\"quotes\\\""))
    #expect(configuration.contains("\\\\slashes"))
    let warnings = #"{"type":"item.completed","item":{"type":"error","message":"An optional feature is disabled."}}"#
    let success = #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#
    try CodexSearchClient.validateEvents(warnings + "\n" + success)
    #expect(throws: (any Error).self) { try CodexSearchClient.validateEvents(warnings) }
    #expect(throws: (any Error).self) {
        try CodexSearchClient.validateEvents(#"{"type":"item.completed","item":{"type":"command_execution"}}"# + "\n" + success)
    }
    #expect(throws: (any Error).self) {
        try CodexSearchClient.validateEvents(#"{"type":"turn.failed","error":{"message":"failed"}}"# + "\n" + success)
    }
}

@Test func aiCatalogUsesThePublicOpenRouterEndpointWithoutLeakingKeys() throws {
    var settings = AISearchSettings(); settings.baseURL = "https://openrouter.ai/api/v1"
    let request = try AISearchModelCatalog.request(settings: settings, apiKey: "must-not-send")
    #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    settings.baseURL = "https://example.test/proxy/v1/chat/completions"
    let authenticated = try AISearchModelCatalog.request(settings: settings, apiKey: "fixture-key")
    #expect(authenticated.url?.absoluteString == "https://example.test/proxy/v1/models")
    #expect(authenticated.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    let models = try AISearchModelCatalog.decode(Data(#"{"data":[{"id":"b","name":"Beta"},{"id":"a","name":"Alpha"},{"id":"b"},{"id":"image","architecture":{"output_modalities":["image"]}}]}"#.utf8))
    #expect(models.map(\.id) == ["a", "b"])
    #expect(throws: (any Error).self) { try AISearchModelCatalog.decode(Data("{}".utf8)) }
}

@Test func geminiUsesPortableJSONAndKeepsTheExactGrammarAndBoundedBudget() throws {
    var settings = AISearchSettings(); settings.baseURL = "https://openrouter.ai/api/v1"; settings.model = "google/gemini-3.8-flash"
    let schema = try JSONSerialization.data(withJSONObject: AISearchGrammar.schema)
    let client = AISearchHTTPClient(settings: settings, apiKey: "fixture-key")
    let request = try client.request(messages: [.init("system", AISearchService.instructions), .init("user", "Find reports")], schema: schema, strict: false)
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    #expect(body["max_tokens"] as? Int == 8192)
    #expect(body["max_completion_tokens"] == nil)
    #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    #expect((body["provider"] as? [String: Any])?["require_parameters"] as? Bool == true)
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages[0]["content"]?.contains(String(decoding: schema, as: UTF8.self)) == true)
    #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains("fixture-key"))
}
