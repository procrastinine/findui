@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

private func state() -> SearchState {
    SearchState(query: "", mode: .files, scopePath: "/tmp", useIndex: false,
                includeHidden: false, caseSensitive: false, syntax: .literal,
                exactNameMatch: false, selectedDrivePath: nil, indexedFilter: .files)
}

@Test func contentControlsPreserveLiteralBytesAndExplicitExpressions() throws {
    for text in ["two words", "-pdf hidden in Documents", "name:hello", " ", "  hello  ", #"say "yes" \\ "#, "a*b?", "東京 résumé"] {
        var s = state()
        s.contentsInput = text
        #expect(s.mode == .contents && s.contentMatchingChoice == .literal)
        #expect(s.contentsInput == text)
        #expect(ParsedSearchQuery.parseLiteral(s.query).tokens.map(\.value) == [text])
        let restored = try JSONDecoder().decode(SearchState.self, from: JSONEncoder().encode(s))
        #expect(restored == s && restored.contentsInput == text)
    }
    var old = state(); old.mode = .contents; old.query = "error -expected"
    #expect(old.contentMatchingChoice == .expression && old.contentsInput == "error -expected")
    old.contentsInput = "timeout -expected"
    #expect(old.query == "timeout -expected")
    old.contentMatchingChoice = .literal
    #expect(old.contentsInput == "timeout -expected")
    #expect(ParsedSearchQuery.parseLiteral(old.query).tokens.map(\.value) == ["timeout -expected"])
    old.contentMatchingChoice = .regex
    old.contentsInput = "^def "
    #expect(old.query == "^def ")
}

@Test @MainActor func metadataControlsCannotSelectConflictingSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    model.filters.dateField = .lastOpened
    #expect(model.sourceChoices.contains(.live))
    model.filters.datePeriod = .week
    #expect(model.sourceChoice == .spotlight && model.sourceChoices == [.spotlight])
    model.sourceChoice = .live
    #expect(model.sourceChoice == .spotlight)
    model.filters.datePeriod = .any
    model.sourceChoice = .live
    model.contentsInput = "hBN"
    model.contentMatchingChoice = .documentText
    #expect(model.sourceChoice == .spotlight && model.sourceChoices == [.spotlight])
    model.resetAdditionalFilters()
    #expect(model.contentsInput == "hBN" && model.contentMatchingChoice == .documentText)
    #expect(model.sourceChoice == .spotlight)
    model.contentMatchingChoice = .literal
    model.sourceChoice = .live
    #expect(model.sourceChoice == .live)
    model.stopSearch()
}

@Test func wireContractDoesNotSilentlyDiscardUnknownFields() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SearchIntent.self, from: Data(#"{"mode":"files","inventedFilter":true}"#.utf8))
    }
    var s = state(); s.mode = .contents; s.query = "two -conditions"
    #expect(throws: (any Error).self) { try s.modelIntent() }
}

@Test @MainActor func optionsIndicatorTreatsDisabledConversionAsTheDefault() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-options-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    defer { model.stopSearch() }
    #expect(!model.hasAdditionalOptions)
    model.refinements.extraction = .init()
    #expect(model.hasAdditionalOptions)
    model.refinements.extraction = nil
    #expect(!model.hasAdditionalOptions)
    model.refinements.finderTags = ["Review"]
    #expect(model.hasAdditionalOptions)
    model.refinements.finderTags = nil
    #expect(!model.hasAdditionalOptions)
}

@Test func fileOnlyRulesCanReturnToSimpleControlsRegardlessOfUnusedContentUnit() throws {
    var original = state()
    original.replaceRules(.init(files: .rule(.tags(["Review", "Research"], .any)), contents: nil, contentUnit: .document))
    let compact = try #require(original.compactProjection)
    #expect(compact.ruleSet == nil)
    #expect(compact.refinements.finderTags == ["Review", "Research"])
    #expect(compact.refinements.tagMatch == .any && compact.contentsInput.isEmpty)
    var expanded = compact
    try expanded.promoteToRules()
    #expect(expanded.ruleSet?.files.leaves == original.ruleSet?.files.leaves)
    #expect(expanded.ruleSet?.contents == nil)
}
