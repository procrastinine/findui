@testable import SearchBackend
import Foundation
import CoreServices
import Testing
@testable import FindUI

@Test func documentContentAndCalendarDatesCompileToMetadataNotRipgrep() throws {
    var request = SearchRequest(query: "hBN", mode: .contents, scope: URL(fileURLWithPath: "/tmp"),
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.source = .spotlight
    request.refinements.contentSource = .indexedDocumentText
    request.refinements.extensions = "ppt,pptx"
    request.filters.dateField = .documentCreated
    request.filters.datePeriod = .custom
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    request.filters.dateFrom = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    request.filters.dateThrough = try #require(calendar.date(from: DateComponents(year: 2025, month: 2, day: 28)))
    let bounds = try request.filters.validated()
    #expect(bounds.before == calendar.date(from: DateComponents(year: 2025, month: 3, day: 1)))
    let predicate = try SpotlightQuery.predicate(for: request, bounds: bounds)
    #expect(predicate.contains("kMDItemTextContent == \"*hBN*\"c"))
    #expect(predicate.contains("kMDItemContentCreationDate >= \(request.filters.dateFrom.timeIntervalSinceReferenceDate)"))
    #expect(MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) != nil, "\(predicate)")
    let tools = Toolchain(fd: nil, fzf: nil, rg: nil, find: nil, mdfind: URL(fileURLWithPath: "/usr/bin/mdfind"))
    let pipeline = try SearchPipelineCompiler(tools: tools).compile(request)
    #expect(pipeline.engineName == "Spotlight")
    #expect(!pipeline.outputIsJSON && !request.producesContentLines && pipeline.plan.query.source.kind == .spotlight)
    #expect(!pipeline.script.contains("/usr/bin/stat"))
    #expect(!bounds.matches(size: nil, modifiedAt: request.filters.dateFrom, createdAt: request.filters.dateFrom))
    #expect(bounds.matches(size: nil, modifiedAt: nil, createdAt: nil, documentCreatedAt: request.filters.dateFrom))
    request.syntax = .regex
    #expect(throws: (any Error).self) { try SearchPipelineCompiler(tools: tools).compile(request) }
    request.syntax = .literal; request.refinements.wholeWords = true
    #expect(throws: (any Error).self) { try SearchPipelineCompiler(tools: tools).compile(request) }
    request.refinements.wholeWords = false; request.refinements.source = .filesystem
    #expect(throws: (any Error).self) { try SearchPipelineCompiler(tools: tools).compile(request) }
}

@Test func indexedDocumentResultsPreserveClipboardAndHistoryState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-document-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let slide = root.appendingPathComponent("slide 'one'.pptx")
    let other = root.appendingPathComponent("other.txt")
    // Mock only mdfind's index output; neither file has raw matching bytes. A
    // subsequent rg stage would incorrectly discard the document match.
    try Data("binary document fixture".utf8).write(to: slide)
    try Data("other".utf8).write(to: other)
    let listing = root.appendingPathComponent("index-output")
    try Data((slide.path + "\0" + other.path + "\0").utf8).write(to: listing)
    let fake = root.appendingPathComponent("mdfind")
    try Data(("#!/bin/sh\nexec /bin/cat " + shellQuote(listing.path) + "\n").utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let tools = Toolchain(fd: nil, fzf: nil, rg: nil, find: nil, mdfind: fake)
    var snapshot = SearchSnapshot(query: "hBN", mode: .contents, scopePath: root.path, useIndex: false,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        selectedDrivePath: nil, indexedFilter: .files)
    snapshot.refinements.source = .spotlight
    snapshot.refinements.contentSource = .indexedDocumentText
    snapshot.refinements.extensions = "ppt,pptx"
    snapshot.filters.dateField = .documentCreated
    let restored = try JSONDecoder().decode(SearchSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(restored == snapshot)
    #expect(restored.activeFilterDescriptions.contains("Indexed document text"))
    let result = try await SearchService(tools: tools).search(request: restored.makeRequest())
    #expect(result.results.map(\.path) == [slide.path])
    #expect(result.results.allSatisfy { $0.lineNumber == nil })
    let copied = try await ProcessRunner.run(spec: CommandSpec(executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: ["-f", "-c", result.commandPreview]), pathOverride: tools.searchPath)
    #expect(copied.exitCode == 0)
    #expect(copied.stdout.split(separator: "\0").map(String.init) == [slide.path])
}

@Test func spotlightLiteralQuotingRejectsWildcardsAndKeepsTermsInData() throws {
    var request = SearchRequest(query: #""hBN quote\"" -draft"#, mode: .contents, scope: URL(fileURLWithPath: "/tmp"),
        includeHidden: false, caseSensitive: true, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.source = .spotlight; request.refinements.contentSource = .indexedDocumentText
    let predicate = try SpotlightQuery.predicate(for: request, bounds: request.filters.validated())
    #expect(predicate.contains(#""*hBN quote\"*""#))
    #expect(predicate.contains(#"!(kMDItemTextContent == "*draft*")"#))
    #expect(MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) != nil)
    request.query = "literal*"
    #expect(throws: (any Error).self) { try SpotlightQuery.predicate(for: request, bounds: request.filters.validated()) }
}
