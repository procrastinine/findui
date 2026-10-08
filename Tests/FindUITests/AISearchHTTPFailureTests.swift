@testable import SearchBackend
import Foundation
import Testing

private final class AIHTTPFixture: @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let data: Data }
    private let lock = NSLock()
    private var pending: [Reply]
    private var captured: [Data] = []
    init(_ replies: [Reply]) { pending = replies }
    var bodies: [Data] { lock.withLock { captured } }
    func handle(_ request: URLRequest) -> Reply {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = Data() }
        return lock.withLock {
            captured.append(body)
            return pending.isEmpty ? .init(status: 500, data: Data()) : pending.removeFirst()
        }
    }
}

private final class AIHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: AIHTTPFixture] = [:]
    subscript(_ host: String) -> AIHTTPFixture? {
        get { lock.withLock { fixtures[host] } }
        set { lock.withLock { fixtures[host] = newValue } }
    }
}

private final class AIHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = AIHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host, let fixture = Self.registry[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let reply = fixture.handle(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func reply(_ status: Int, _ text: String) -> AIHTTPFixture.Reply { .init(status: status, data: Data(text.utf8)) }
private let success = #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{}"}}]}"#
private let schemaUnsupported = #"{"error":{"message":"response_format json_schema is not supported"}}"#

private func withHTTPFixture(_ replies: [AIHTTPFixture.Reply],
                            body: (AISearchHTTPClient, URLSession, AIHTTPFixture) async throws -> Void) async throws {
    let host = UUID().uuidString.lowercased() + ".invalid"
    let fixture = AIHTTPFixture(replies)
    AIHTTPProtocol.registry[host] = fixture
    var settings = AISearchSettings(); settings.baseURL = "https://" + host + "/v1"
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel(); AIHTTPProtocol.registry[host] = nil }
    try await body(AISearchHTTPClient(settings: settings, apiKey: "fixture-only"), session, fixture)
}

@Test func aiStructuredOutputFallbackRequiresAnExplicitUnsupportedSchemaResponse() async throws {
    let schema = try JSONSerialization.data(withJSONObject: AISearchGrammar.schema, options: [.sortedKeys])
    let messages: [AISearchMessage] = [.init("system", AISearchService.instructions), .init("user", "Find reports")]
    for status in [400, 422] {
        try await withHTTPFixture([reply(status, schemaUnsupported), reply(200, success)]) { client, session, fixture in
            #expect(try await client.generate(messages: messages, schema: schema, session: session) == "{}")
            let bodies = try fixture.bodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            #expect(bodies.count == 2)
            let strict = try #require(bodies.first?["response_format"] as? [String: Any])
            #expect(strict["type"] as? String == "json_schema")
            let configuration = try #require(strict["json_schema"] as? [String: Any])
            #expect(configuration["strict"] as? Bool == true)
            #expect(NSDictionary(dictionary: configuration["schema"] as! [String: Any]).isEqual(to: AISearchGrammar.schema))
            #expect((bodies[1]["response_format"] as? [String: Any])?["type"] as? String == "json_object")
            let fallback = try #require(bodies[1]["messages"] as? [[String: String]])
            #expect(fallback[0]["content"]?.contains(String(decoding: schema, as: UTF8.self)) == true)
            #expect(!String(decoding: fixture.bodies[0], as: UTF8.self).contains("fixture-only"))
        }
    }
    for (status, error) in [(401, schemaUnsupported), (403, schemaUnsupported), (429, schemaUnsupported),
                           (500, schemaUnsupported), (302, schemaUnsupported),
                           (400, #"{"error":{"message":"Invalid model"}}"#),
                           (422, #"{"error":{"message":"Malformed json_schema missing required fields"}}"#)] {
        try await withHTTPFixture([reply(status, error), reply(200, success)]) { client, session, fixture in
            await #expect(throws: (any Error).self) { try await client.generate(messages: messages, schema: schema, session: session) }
            #expect(fixture.bodies.count == 1)
        }
    }
    try await withHTTPFixture([reply(400, schemaUnsupported), reply(422, schemaUnsupported), reply(200, success)]) { client, session, fixture in
        await #expect(throws: (any Error).self) { try await client.generate(messages: messages, schema: schema, session: session) }
        #expect(fixture.bodies.count == 2)
    }
    try await withHTTPFixture([reply(200, String(repeating: "x", count: 512 * 1024 + 1))]) { client, session, fixture in
        await #expect(throws: (any Error).self) { try await client.generate(messages: messages, schema: schema, session: session) }
        #expect(fixture.bodies.count == 1)
    }
}

@Test func aiBadCompletionEnvelopesFailBeforeTheirTextCanBeApplied() throws {
    let message: [String: Any] = ["role": "assistant", "content": "{}"]
    let choice: [String: Any] = ["finish_reason": "stop", "message": message]
    var invalid: [[String: Any]] = [["choices": []], ["choices": [choice, choice]],
                                  ["choices": [choice], "error": ["message": "failed"]]]
    for reason: Any in [NSNull(), "length", "tool_calls", "content_filter", "error", true] {
        var changed = choice; changed["finish_reason"] = reason; invalid.append(["choices": [changed]])
    }
    for (key, value) in [("role", "tool" as Any), ("content", NSNull()), ("content", ""),
                         ("content", [["type": "text", "text": "{}"]]), ("refusal", "No"), ("refusal", true),
                         ("tool_calls", [["function": ["name": "run"]]]), ("tool_calls", "malformed"),
                         ("function_call", ["name": "run"])] {
        var changed = message; changed[key] = value
        invalid.append(["choices": [["finish_reason": "stop", "message": changed]]])
    }
    for envelope in invalid {
        #expect(throws: (any Error).self) { try AISearchHTTPClient.output(JSONSerialization.data(withJSONObject: envelope)) }
    }
    let duplicate = success.replacingOccurrences(of: "\"finish_reason\":\"stop\"", with: "\"finish_reason\":\"length\",\"finish_reason\":\"stop\"")
    #expect(throws: (any Error).self) { try AISearchHTTPClient.output(Data(duplicate.utf8)) }
}

@Test func aiStrictSchemaRequiresEveryFieldAndDisallowsUnknownProperties() throws {
    func visit(_ value: Any) throws {
        if let object = value as? [String: Any] {
            if object["type"] as? String == "object" {
                #expect(object["additionalProperties"] as? Bool == false)
                let properties = try #require(object["properties"] as? [String: Any])
                #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys))
            }
            if let ref = object["$ref"] as? String { #expect(ref == "#/$defs/node") }
            for child in object.values { try visit(child) }
        } else if let array = value as? [Any] { for child in array { try visit(child) } }
    }
    try visit(AISearchGrammar.schema)
    #expect((AISearchGrammar.schema["$defs"] as? [String: Any])?["node"] != nil)
}
