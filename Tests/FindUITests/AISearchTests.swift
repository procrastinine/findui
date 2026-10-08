@testable import SearchBackend
import SearchCore
import Foundation
import Testing

private func aiBaseState() -> SearchState {
    SearchRequest(query: "", mode: .files, scope: FileManager.default.temporaryDirectory,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: 100).state
}

private func aiResponse(_ node: [String: Any]?, options changed: [String: Any] = [:], clarification: String? = nil, contentUnit: String = "line") throws -> String {
    let schema = AISearchGrammar.schema["properties"] as! [String: Any]
    let optionsSchema = schema["options"] as! [String: Any]
    let properties = optionsSchema["properties"] as! [String: Any]
    var options = Dictionary(uniqueKeysWithValues: properties.keys.map { ($0, NSNull() as Any) })
    options.merge(changed) { _, new in new }
    let object: [String: Any] = ["version": 1, "summary": "Fixture search", "clarification": clarification as Any? ?? NSNull(),
        "rules": node as Any? ?? NSNull(), "contentUnit": contentUnit, "options": options]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private actor AIResponses: AISearchGenerating {
    let responses: [String]
    var requests: [[AISearchMessage]] = []
    init(_ responses: [String]) { self.responses = responses }
    func generate(messages: [AISearchMessage], schema: Data) async throws -> String {
        requests.append(messages)
        return responses[min(requests.count - 1, responses.count - 1)]
    }
}

@Test func aiGrammarPreservesMixedNestingAndKeepsTheOriginalScopeAndReaderPolicy() throws {
    let tree: [String: Any] = ["kind": "all", "children": [
        ["kind": "any", "children": [
            ["kind": "all", "children": [["kind": "extensions", "values": ["swift"]], ["kind": "literal", "text": "TODO"]]],
            ["kind": "all", "children": [["kind": "extensions", "values": ["md"]], ["kind": "literal", "text": "FIXME"]]]]],
        ["kind": "none", "children": [["kind": "name", "matching": "contains", "text": "generated"]]]]]
    var original = aiBaseState(); original.traversal.excludedFolders = [".git", "node_modules"]
    let proposal = try AISearchGrammar.decode(Data(aiResponse(tree).utf8), relativeTo: original)
    let state = try #require(proposal.state), expression = try #require(state.ruleSet?.expression)
    #expect(state.scopePath == original.scopePath)
    #expect(state.traversal == original.traversal)
    #expect(state.includeHidden == false)
    #expect(state.refinements.extraction == nil)
    #expect(state.mode == .contents)
    #expect(expression.leaves.count == 5)
    let normalized = try SearchRequest(state: state).normalizedQuery()
    #expect(normalized.expression != nil, "Cross-domain OR must remain an expression, not two independent trees")
    #expect(normalized.traversal.hidden == false)
    #expect(expression.queryTree.evaluate {
        switch $0 {
        case .file(.extensions(let values)): return values == ["swift"]
        case .content(.literal(let text)): return text == "TODO"
        default: return false
        }
    })
    #expect(!expression.queryTree.evaluate {
        switch $0 {
        case .file(.extensions(let values)): return values == ["swift"]
        case .content(.literal(let text)): return text == "FIXME"
        default: return false
        }
    }, "A Swift file with only FIXME must not match the Markdown branch")
}

@Test func aiSimpleExpressionsStillNormalizeIntoNativeFastPaths() throws {
    let tree: [String: Any] = ["kind": "all", "children": [["kind": "extensions", "values": ["swift"]], ["kind": "literal", "text": "TODO"]]]
    let state = try #require(AISearchGrammar.decode(Data(aiResponse(tree).utf8), relativeTo: aiBaseState()).state)
    let query = try SearchRequest(state: state).normalizedQuery()
    #expect(query.expression == nil)
    #expect(query.contents?.single == .literal("TODO"))
    #expect(query.files.single == .extensions(["swift"]))
    #expect(query.extraction == nil)
}

@Test func aiSourceChoicesNeverSilentlyReplaceASnapshotOrSpotlight() throws {
    var original = aiBaseState(); original.useIndex = true
    let content: [String: Any] = ["kind": "literal", "text": "TODO"]
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(aiResponse(content).utf8), relativeTo: original) }
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(aiResponse(content, options: ["source": "snapshot"]).utf8), relativeTo: original) }
    let live = try #require(AISearchGrammar.decode(Data(aiResponse(content, options: ["source": "live"]).utf8), relativeTo: original).state)
    #expect(!live.useIndex && live.refinements.source == .filesystem)
    let filename: [String: Any] = ["kind": "name", "text": "report", "matching": "contains"]
    #expect(try AISearchGrammar.decode(Data(aiResponse(filename).utf8), relativeTo: original).state?.useIndex == true)
    original.useIndex = false
    let spotlight: [String: Any] = ["kind": "spotlightText", "text": "report"]
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(aiResponse(spotlight, contentUnit: "file").utf8), relativeTo: original) }
    #expect(try AISearchGrammar.decode(Data(aiResponse(spotlight, options: ["source": "spotlight"], contentUnit: "file").utf8), relativeTo: original).state?.refinements.source == .spotlight)
}

@Test func aiGrammarRejectsUnknownFieldsCoercionsAndDeepTrees() throws {
    let good = try aiResponse(["kind": "literal", "text": "needle"])
    var root = try JSONSerialization.jsonObject(with: Data(good.utf8)) as! [String: Any]
    root["command"] = "rm -rf /"
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(JSONSerialization.data(withJSONObject: root), relativeTo: aiBaseState()) }
    root.removeValue(forKey: "command"); root["version"] = true
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(JSONSerialization.data(withJSONObject: root), relativeTo: aiBaseState()) }
    let numericBool = try aiResponse(["kind": "name", "matching": "contains", "text": "x"], options: ["hidden": 1])
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(numericBool.utf8), relativeTo: aiBaseState()) }
    var node: [String: Any] = ["kind": "literal", "text": "x"]
    for _ in 0..<10 { node = ["kind": "all", "children": [node]] }
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(aiResponse(node).utf8), relativeTo: aiBaseState()) }
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(aiResponse(["kind": "any", "children": []]).utf8), relativeTo: aiBaseState()) }
}

@Test func aiClarificationCannotSmuggleExecutableRulesOrOptions() throws {
    let response = try aiResponse(nil, clarification: "Which folder should be selected?")
    let result = try AISearchGrammar.decode(Data(response.utf8), relativeTo: aiBaseState())
    #expect(result.state == nil)
    #expect(result.clarification != nil)
    #expect(throws: (any Error).self) {
        try AISearchGrammar.decode(Data(aiResponse(nil, options: ["archives": true], clarification: "Clarify").utf8), relativeTo: aiBaseState())
    }
    #expect(throws: (any Error).self) {
        try AISearchGrammar.decode(Data(aiResponse(["kind": "allLines"], clarification: "Clarify").utf8), relativeTo: aiBaseState())
    }
}

@Test func aiReaderOptionsAreIndependentAndCredentialsNeverEnterThePrompt() async throws {
    let response = try aiResponse(["kind": "literal", "text": "needle"], options: ["archives": true])
    let fake = AIResponses([response])
    var original = aiBaseState(); original.sourceCommand = "secret-source-command"
    let proposal = try await AISearchService(client: fake).propose("Search inside archives for needle", state: original)
    let state = try #require(proposal.state)
    #expect(state.refinements.extraction?.archives == true)
    #expect(state.refinements.extraction?.documents == false, "Enabling archives must not implicitly enable documents")
    #expect(state.sourceCommand == nil)
    let messages = await fake.requests[0]
    #expect(!messages.map(\.content).joined().contains("secret-source-command"))
    #expect(messages[0].content.contains("Do not move file conditions outside their OR branches"))
}

@Test func aiInvalidOutputGetsOneRepairWithValidationFeedback() async throws {
    let good = try aiResponse(["kind": "name", "matching": "contains", "text": "report"])
    let client = AIResponses(["{\"bad\":true}", good])
    let proposal = try await AISearchService(client: client).propose("Find reports", state: aiBaseState())
    #expect(proposal.state != nil)
    #expect(await client.requests.count == 2)
    #expect(await client.requests[1].last?.content.contains("validator rejected") == true)
    let invalid = AIResponses(["{\"bad\":true}"])
    await #expect(throws: (any Error).self) { try await AISearchService(client: invalid).propose("Find reports", state: aiBaseState()) }
    #expect(await invalid.requests.count == 2)
}

@Test func aiAPITransportHasScopedURLAndNoToolOrCredentialPayload() throws {
    var settings = AISearchSettings(); settings.enabled = true; settings.baseURL = "https://api.example.test/v1/"
    let client = AISearchHTTPClient(settings: settings, apiKey: "fixture-secret")
    let schema = try JSONSerialization.data(withJSONObject: AISearchGrammar.schema)
    let request = try client.request(messages: [.init("system", "Return JSON"), .init("user", "reports")], schema: schema)
    #expect(request.url?.absoluteString == "https://api.example.test/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
    let body = try #require(request.httpBody)
    #expect(!String(decoding: body, as: UTF8.self).contains("fixture-secret"))
    let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(object["tools"] == nil)
    for url in ["http://remote.example/v1", "https://user:secret@host.test/v1", "https://host.test/v1?key=secret", "file:///tmp"] {
        settings.baseURL = url
        #expect(throws: (any Error).self) { try settings.endpoint() }
    }
    settings.baseURL = "http://127.0.0.1:8000/v1"
    #expect(try settings.endpoint().host == "127.0.0.1")
    #expect(throws: (any Error).self) { try AISearchHTTPClient.output(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#.utf8)) }
    #expect(throws: (any Error).self) { try AISearchHTTPClient.output(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{}","tool_calls":[{}]}}]}"#.utf8)) }
    #expect(try AISearchHTTPClient.output(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{}","tool_calls":null,"function_call":null}}]}"#.utf8)) == "{}")
}

@Test func aiSubprocessTimeoutAndCancellationStopTheProcessGroup() async throws {
    let start = Date()
    await #expect(throws: (any Error).self) {
        try await AICommandProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 20 & wait"], timeout: 0.15)
    }
    #expect(Date().timeIntervalSince(start) < 3)
    let task = Task { try await AICommandProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 20 & wait"], timeout: 30) }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let result = try await AICommandProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 1)
    #expect(result.stdout == "hello\n")
}
