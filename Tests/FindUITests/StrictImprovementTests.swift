import Foundation
import SearchCore
import Testing
@testable import SearchBackend

@Test func typedMatchDecodingPreservesBytesLocationsAndOptionalFields() throws {
    let root = FileManager.default.temporaryDirectory
    let request = SearchRequest(query: "needle", mode: .contents, scope: root,
        includeHidden: false, caseSensitive: false, syntax: .regex, exactNameMatch: false, maxResults: .max)
    let service = SearchService(tools: .resolve(includeDocumentReaders: false))
    let bytes = Data([10, 0xff] + Array("needle café\n".utf8))
    let record: [String: Any] = ["type": "match", "data": [
        "path": ["text": 42, "bytes": Data(root.appendingPathComponent("absent.txt").path.utf8).base64EncodedString()],
        "lines": ["bytes": bytes.base64EncodedString()], "line_number": 12,
        "submatches": [["start": 2, "end": 8, "match": ["text": "ignored duplicate"]], NSNull(), ["start": "bad", "end": 8]],
        "findui_tags": ["Blue"], "findui_origin": ["extractor": "fixture", "line": 12, "page": 3],
        "unknown_future_field": ["nested": true]
    ]]
    let input = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    let row = try #require(service.parseRipgrepJSONLine(input, request: request, sourceOrder: 9, pipelineOutput: true))
    #expect(row.snippet == "�needle café")
    #expect(row.snippetMatchRanges == [1..<7])
    #expect(row.lineNumber == 12 && row.sourceOrder == 9)
    #expect(row.tags == ["Blue"] && row.extractedOrigin?.page == 3)
    let invalidPath = #"{"type":"match","data":{"path":{"bytes":"/w=="},"lines":{"text":"needle"}}}"#
    #expect(service.parseRipgrepJSONLine(invalidPath, request: request, sourceOrder: 0, pipelineOutput: true) == nil)
}

@Test func executionOnlyCompilationKeepsPlanAndImportableExport() throws {
    let root = FileManager.default.temporaryDirectory
    var state = SearchRequest(query: "needle", mode: .contents, scope: root,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max).state
    state.refinements.finderTags = ["Blue"]
    let compiler = SearchPipelineCompiler(tools: .resolve(includeDocumentReaders: false))
    let request = state.makeRequest()
    let exported = try compiler.compile(request)
    let execution = try compiler.compile(request, includeCommandMetadata: false)
    #expect(exported.plan == execution.plan)
    #expect(exported.spec.executable == execution.spec.executable && exported.spec.arguments == execution.spec.arguments)
    #expect(!exported.importHeader.isEmpty && execution.importHeader.isEmpty)
    let restored = try #require(try SearchCommandExport.restore(exported.script))
    #expect(restored.refinements.finderTags == ["Blue"])
}
