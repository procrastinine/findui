@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func cliSearchInputAcceptsRawStateAndPreservesWrappedReferenceDate() throws {
    let raw = Data(#"{"query":"needle","mode":"files","scopePath":"/tmp"}"#.utf8)
    let before = Date.now
    let decoded = try JSONDecoder().decode(HeadlessCLI.SearchDescription.self, from: raw)
    #expect(decoded.state == (try JSONDecoder().decode(SearchState.self, from: raw)))
    #expect(decoded.referenceDate >= before && decoded.referenceDate <= .now)
    #expect(decoded.index == nil)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let wrapped = HeadlessCLI.SearchDescription(state: decoded.state, referenceDate: date)
    let roundTrip = try JSONDecoder().decode(HeadlessCLI.SearchDescription.self, from: JSONEncoder().encode(wrapped))
    #expect(roundTrip.state == decoded.state)
    #expect(roundTrip.referenceDate == date)
}

@Test func cliSearchInputRejectsMalformedEnvelopesAndInvalidStates() {
    for input in [#"{"state":null}"#, #"{"state":{"query":"x","mode":"files","scopePath":"/tmp"}}"#,
                  #"{"query":4,"mode":"files","scopePath":"/tmp"}"#, "[]", "broken"] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HeadlessCLI.SearchDescription.self, from: Data(input.utf8))
        }
    }
}

@Test func ordinaryToolDiscoveryOmitsOptionalReadersButPreservesCoreTools() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-tools-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["pandoc", "pdftotext", "pdfdetach"] {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let complete = Toolchain.resolve(environmentPath: root.path)
    let ordinary = Toolchain.resolve(environmentPath: root.path, includeDocumentReaders: false)
    #expect(complete.pandoc == root.appendingPathComponent("pandoc"))
    #expect(complete.pdftotext == root.appendingPathComponent("pdftotext"))
    #expect(complete.pdfdetach == root.appendingPathComponent("pdfdetach"))
    #expect(ordinary.pandoc == nil && ordinary.pdftotext == nil && ordinary.pdfdetach == nil && ordinary.tikaJar == nil)
    #expect([ordinary.fd, ordinary.rg, ordinary.fzf, ordinary.find, ordinary.mdfind, ordinary.contentWorker]
        == [complete.fd, complete.rg, complete.fzf, complete.find, complete.mdfind, complete.contentWorker])
    #expect(ordinary.searchPath == Toolchain.defaultSearchPath)

    let raw = Data("{\"query\":\"needle\",\"mode\":\"contents\",\"scopePath\":\"\(root.path)\"}".utf8)
    var request = try JSONDecoder().decode(SearchState.self, from: raw).makeRequest()
    let fullCommand = try SearchPipelineCompiler(tools: complete).compile(request).script
    #expect(try SearchPipelineCompiler(tools: ordinary).compile(request).script == fullCommand)
    #expect(Toolchain.resolve(for: request).pdftotext == nil)
    request.refinements.extraction = .init()
    let extracted = Toolchain.resolve(for: request), all = Toolchain.resolve()
    #expect(extracted.pdftotext == all.pdftotext && extracted.pandoc == all.pandoc && extracted.tikaJar == all.tikaJar)
}
