@testable import SearchBackend
import SearchCore
import Foundation
import Testing

private func adversarialState() -> SearchState {
    SearchRequest(query: "keep current", mode: .files, scope: FileManager.default.temporaryDirectory,
        includeHidden: false, caseSensitive: true, syntax: .literal, exactNameMatch: false, maxResults: 100).state
}

private func wire(_ rule: [String: Any] = ["kind": "literal", "text": "needle"],
                  unit: String = "line", changes: [String: Any] = [:]) -> [String: Any] {
    let properties = AISearchGrammar.schema["properties"] as! [String: Any]
    let optionProperties = (properties["options"] as! [String: Any])["properties"] as! [String: Any]
    var options = Dictionary(uniqueKeysWithValues: optionProperties.keys.map { ($0, NSNull() as Any) })
    options.merge(changes) { _, new in new }
    return ["version": 1, "summary": "Find the requested files", "clarification": NSNull(),
            "rules": rule, "contentUnit": unit, "options": options]
}

private func encodeWire(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}

private func decodeWire(_ value: [String: Any], state: SearchState = adversarialState()) throws -> SearchState {
    try #require(AISearchGrammar.decode(encodeWire(value), relativeTo: state).state)
}

@Test func aiBadOutputMissingExtraAndMistypedFieldsNeverBecomeSearches() throws {
    let original = adversarialState()
    let valid = wire()
    for key in valid.keys {
        var changed = valid; changed.removeValue(forKey: key)
        #expect(throws: (any Error).self) { try decodeWire(changed, state: original) }
    }
    let options = valid["options"] as! [String: Any]
    for key in options.keys {
        var changed = valid, fields = options; fields.removeValue(forKey: key); changed["options"] = fields
        #expect(throws: (any Error).self) { try decodeWire(changed, state: original) }
    }
    for (key, value) in [("version", "1" as Any), ("version", true), ("version", 1.1), ("version", 2),
                         ("summary", ["text": "Find things"]), ("summary", " \n "),
                         ("clarification", false), ("contentUnit", "paragraph"),
                         ("rules", NSNull()), ("rules", "rg needle"), ("rules", []),
                         ("options", []), ("command", "touch /tmp/should-never-run")] {
        var changed = valid; changed[key] = value
        #expect(throws: (any Error).self) { try decodeWire(changed, state: original) }
    }
    for rule: [String: Any] in [
        ["kind": "literal"], ["kind": "literal", "text": 123], ["kind": "literal", "text": ""],
        ["kind": "literal", "text": "x", "shell": "pwd"], ["kind": "execute", "text": "pwd"],
        ["kind": "allLines", "text": "ignored"], ["kind": "all", "children": NSNull()],
        ["kind": "all", "children": ["needle"]], ["kind": "any", "children": []],
        ["kind": "none", "children": []], ["kind": "all", "children": [["kind": "all", "children": []]]],
        ["kind": "path", "text": "src", "matching": "contains", "absolute": 1],
        ["kind": "name", "text": "x", "matching": "semantic"],
        ["kind": "extensions", "values": "swift"], ["kind": "extensions", "values": ["../swift"]],
        ["kind": "extensions", "values": []], ["kind": "tags", "values": ["Work"], "matching": "maybe"],
        ["kind": "size", "minimum": "2 MiB", "maximum": "1 MiB"],
        ["kind": "size", "minimum": "", "maximum": ""], ["kind": "size", "minimum": "-1 B", "maximum": ""],
        ["kind": "metadata", "field": "imaginary", "text": "value"],
        ["kind": "proximity", "terms": ["one"], "distance": 2, "ordered": false],
        ["kind": "proximity", "terms": ["one", "two"], "distance": -1, "ordered": false],
        ["kind": "proximity", "terms": ["one", "two"], "distance": 1001, "ordered": false],
        ["kind": "proximity", "terms": ["one two", "three"], "distance": 2, "ordered": false],
        ["kind": "proximity", "terms": ["one", "two"], "distance": true, "ordered": false]
    ] {
        #expect(throws: (any Error).self) { try decodeWire(wire(rule), state: original) }
    }
    for (key, value) in [("hidden", 1 as Any), ("archives", "true"), ("maximumDepth", true),
                         ("maximumDepth", 0), ("maximumDepth", -2), ("maximumDepth", 10001),
                         ("maximumDepth", 1.5), ("maximumDepth", 1e30),
                         ("typoTolerance", -1), ("typoTolerance", 3), ("excludedFolders", "build"),
                         ("excludedFolders", [1]), ("encoding", 123), ("source", "web"),
                         ("source", "snapshot"), ("wordLanguage", "unknown"), ("kind", "folders"),
                         ("kind", "contents"), ("indexedWords", true), ("unknown", false)] {
        #expect(throws: (any Error).self) { try decodeWire(wire(changes: [key: value]), state: original) }
    }
    #expect(original == adversarialState())
}

@Test func aiBadOutputRejectsTruncationDuplicateKeysAndEscapedKeyAliases() throws {
    let good = String(decoding: try encodeWire(wire()), as: UTF8.self)
    let corrupt = ["", "null", "[]", "true", "1", "```json\n" + good + "\n```", good + good,
        String(good.dropLast()), good + " trailing prose",
        good.replacingOccurrences(of: "\"version\":1", with: "\"version\":0,\"version\":1"),
        good.replacingOccurrences(of: "\"hidden\":null", with: "\"hidden\":true,\"hidden\":null"),
        good.replacingOccurrences(of: "\"hidden\":null", with: "\"hidden\":true,\"\\u0068idden\":null"),
        good.replacingOccurrences(of: "\"text\":\"needle\"", with: "\"text\":\"evil\",\"text\":\"needle\""),
        String(repeating: "[", count: 10000) + String(repeating: "]", count: 10000)]
    for text in corrupt {
        #expect(throws: (any Error).self) { try AISearchGrammar.decode(Data(text.utf8), relativeTo: adversarialState()) }
    }
    // Identical keys in distinct objects, and JSON-looking literal data, are valid.
    let text = #"\"kind\":\"all\", {\"text\": \"value\"} \\ path ☃"#
    let state = try decodeWire(wire(["kind": "all", "children": [
        ["kind": "literal", "text": text], ["kind": "literal", "text": "other"]]]))
    #expect(try SearchRequest(state: state).normalizedQuery().contentPredicates.contains(.literal(text)))
}

@Test func aiBadOutputLimitsDateBoundsAndClarificationsAreStrict() throws {
    let leaf: [String: Any] = ["kind": "literal", "text": "x"]
    var deep = leaf
    for _ in 0..<8 { deep = ["kind": "all", "children": [deep]] }
    _ = try decodeWire(wire(deep))
    deep = ["kind": "all", "children": [deep]]
    #expect(throws: (any Error).self) { try decodeWire(wire(deep)) }
    _ = try decodeWire(wire(["kind": "all", "children": Array(repeating: leaf, count: 63)]))
    #expect(throws: (any Error).self) { try decodeWire(wire(["kind": "all", "children": Array(repeating: leaf, count: 64)])) }
    for value in [String(repeating: "x", count: 16001), "a\0b", "a\nb"] {
        #expect(throws: (any Error).self) { try decodeWire(wire(["kind": "literal", "text": value])) }
    }
    #expect(throws: (any Error).self) {
        try AISearchGrammar.decode(Data(repeating: 32, count: 256 * 1024 + 1), relativeTo: adversarialState())
    }
    var date: [String: Any] = ["kind": "date", "field": "modified", "period": "custom",
                              "days": NSNull(), "calendarAge": NSNull(), "from": "2026-10-01", "through": "2026-10-05"]
    _ = try decodeWire(wire(date))
    for (key, value) in [("from", "2026-02-30" as Any), ("from", "2026-10-06"), ("from", "2026-1-01"),
                         ("from", NSNull()), ("through", NSNull()), ("days", 1),
                         ("calendarAge", "2 months"), ("period", "any"), ("field", "lastOpened")] {
        var changed = date; changed[key] = value
        #expect(throws: (any Error).self) { try decodeWire(wire(changed)) }
    }
    date["period"] = "recentDays"; date["from"] = NSNull(); date["through"] = NSNull()
    for days: Any in [NSNull(), 0, -1, 10001, true, "7"] {
        date["days"] = days
        #expect(throws: (any Error).self) { try decodeWire(wire(date)) }
    }
    var clarification = wire(); clarification["rules"] = NSNull(); clarification["clarification"] = " \n "
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(encodeWire(clarification), relativeTo: adversarialState()) }
    clarification["clarification"] = String(repeating: "x", count: 2001)
    #expect(throws: (any Error).self) { try AISearchGrammar.decode(encodeWire(clarification), relativeTo: adversarialState()) }
}

@Test func aiCompactProjectionKeepsAllMatchingUnitsAndLiteralPunctuationHonest() throws {
    let allFiles = try decodeWire(wire(["kind": "all", "children": []]))
    #expect(allFiles.ruleSet == nil && allFiles.refinements.name == "*" && allFiles.refinements.nameMatching == .glob)
    let literals = ["needle", "two words", "-exclude", "name:report", "a*b?", #"say "hello"\path"#]
    for literal in literals {
        let state = try decodeWire(wire(["kind": "literal", "text": literal]))
        #expect(state.ruleSet == nil && state.contentsInput == literal)
        #expect(try SearchRequest(state: state).normalizedQuery().contents?.single == .literal(literal))
    }
    let leaf: [String: Any] = ["kind": "literal", "text": "needle"]
    let file = try decodeWire(wire(leaf, unit: "file"))
    #expect(file.ruleSet == nil && file.refinements.matchingFilesOnly)
    let negation: [String: Any] = ["kind": "none", "children": [leaf]]
    #expect(try decodeWire(wire(negation, unit: "file")).ruleSet?.contentUnit == .file)
    #expect(try decodeWire(wire(leaf, unit: "document")).ruleSet?.contentUnit == .document)
    #expect(try decodeWire(wire(leaf, unit: "file", changes: ["indexedWords": true])).ruleSet?.contentUnit == .file)
    let orTypes: [String: Any] = ["kind": "any", "children": [
        ["kind": "extensions", "values": ["swift"]], ["kind": "extensions", "values": ["md", "swift"]]]]
    let types = try decodeWire(wire(orTypes))
    #expect(types.ruleSet == nil && types.refinements.extensions == "swift,md")
    for value in ["a/b*", "a\nb*"] {
        let excluded: [String: Any] = ["kind": "none", "children": [["kind": "name", "text": value, "matching": "glob"]]]
        #expect(try decodeWire(wire(excluded)).ruleSet != nil, "Never reinterpret a basename glob as a path or two exclusions")
    }
}

@Test func aiCompactAndMixedSearchesMatchIndependentFilesystemFixtures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-ai-adversarial-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in ["yes.swift": "alpha beta\n", "wrong.swift": "beta\n", ".Hidden.swift": "alpha beta\n",
                         "yes.md": "beta\n", "wrong.md": "alpha\n", "split.txt": "alpha\nbeta\n",
                         "keep.bin": "", "negative.txt": "alpha beta\nbanned\n"] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("sub/nested.bin"))
    try Data().write(to: root.appendingPathComponent("\n"))
    var initial = adversarialState(); initial.scopePath = root.path
    func literal(_ value: String) -> [String: Any] { ["kind": "literal", "text": value] }
    func ext(_ value: String) -> [String: Any] { ["kind": "extensions", "values": [value]] }
    let cases: [([String: Any], String, Set<String>, Bool)] = [
        (["kind": "all", "children": []], "line", ["yes.swift", "wrong.swift", "yes.md", "wrong.md", "split.txt", "keep.bin", "negative.txt", "nested.bin", "\n"], true),
        (["kind": "all", "children": [ext("swift"), literal("alpha")]], "line", ["yes.swift"], true),
        (["kind": "any", "children": [ext("swift"), ext("md")]], "line", ["yes.swift", "wrong.swift", "yes.md", "wrong.md"], true),
        (["kind": "any", "children": [
            ["kind": "all", "children": [ext("swift"), literal("alpha")]],
            ["kind": "all", "children": [ext("md"), literal("beta")]]]], "file", ["yes.swift", "yes.md"], false),
        (["kind": "all", "children": [literal("alpha"), literal("beta"), ["kind": "none", "children": [literal("banned")]]]],
         "file", ["yes.swift", "split.txt"], false),
        (["kind": "any", "children": [["kind": "name", "matching": "contains", "text": "keep"], literal("banned")]],
         "file", ["keep.bin", "negative.txt"], false)
    ]
    for (rules, unit, expected, compact) in cases {
        let state = try decodeWire(wire(rules, unit: unit, changes: ["filesOnly": true]), state: initial)
        #expect((state.ruleSet == nil) == compact)
        let actual = try await SearchService().search(request: state.makeRequest())
        #expect(Set(actual.results.map(\.name)) == expected)
    }
}

private actor BrokenAI: AISearchGenerating {
    let response: String
    var calls = 0
    init(_ response: String) { self.response = response }
    func generate(messages: [AISearchMessage], schema: Data) async throws -> String {
        calls += 1; return response
    }
}

@Test func aiBadOutputRetriesAreBoundedAndOversizedResponsesAreNotReplayed() async throws {
    for (response, count) in [("not JSON", 2), (String(repeating: "x", count: 256 * 1024 + 1), 1)] {
        let client = BrokenAI(response)
        await #expect(throws: (any Error).self) { try await AISearchService(client: client).propose("Find reports", state: adversarialState()) }
        #expect(await client.calls == count)
    }
}
