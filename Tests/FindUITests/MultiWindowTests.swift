@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test @MainActor func searchesShareHistoryAndPinsWithoutSharingLiveState() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("findui-windows-\(UUID())")
    let firstFolder = root.appendingPathComponent("first"), secondFolder = root.appendingPathComponent("second")
    for directory in [firstFolder, secondFolder] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let swift = firstFolder.appendingPathComponent("one.swift"), pdf = secondFolder.appendingPathComponent("two.pdf")
    try Data("first".utf8).write(to: swift)
    try Data("second".utf8).write(to: pdf)
    let persistence = AppPersistence(baseDirectory: root.appendingPathComponent("settings"))
    let library = SearchLibraryStore(persistence: persistence)
    _ = try await library.load()
    let first = SearchViewModel(loadSavedState: false, libraryStore: library)
    let second = SearchViewModel(loadSavedState: false, libraryStore: library)
    defer { first.shutdown(); second.shutdown() }
    first.scopeURL = firstFolder; first.filenameInput = "*.swift"
    first.caseSensitive = true; first.isInspectorPresented = true
    second.scopeURL = secondFolder; second.filenameInput = "*.pdf"
    first.scheduleSearch(immediate: true); second.scheduleSearch(immediate: true)
    for _ in 0..<200 {
        if !first.isSearching && !second.isSearching && library.value.history.count == 2 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(first.history.count == 2 && second.history == first.history)
    #expect(first.results.map(\.url.path) == [swift.path])
    #expect(second.results.map(\.url.path) == [pdf.path])
    #expect(first.caseSensitive && !second.caseSensitive)
    #expect(first.isInspectorPresented && !second.isInspectorPresented)
    let firstState = first.searchState, firstResults = first.results.map(\.id)
    let secondEntry = try #require(second.history.first { $0.snapshot.scopePath == secondFolder.path })
    first.togglePinned(secondEntry)
    #expect(second.pinnedHistory.map(\.id) == [secondEntry.id])
    #expect(second.searchState.scopePath == secondFolder.path)
    second.filenameInput = "absent"
    #expect(first.searchState == firstState && first.results.map(\.id) == firstResults)
    second.runHistoryEntry(secondEntry)
    #expect(second.filenameInput == "*.pdf")
    #expect(first.searchState == firstState && first.results.map(\.id) == firstResults)
    second.stopSearch()
    let firstEntry = try #require(first.history.first { $0.snapshot.scopePath == firstFolder.path })
    second.deleteHistoryEntry(firstEntry)
    #expect(first.history.count == 1 && first.history == second.history)
    #expect(first.searchState == firstState && first.results.map(\.id) == firstResults)
    first.persistTraversalPreferences()
    second.persistDisplayPreferences()
    await library.flush()
    let saved = try await persistence.loadLibrary()
    #expect(saved.history.map(\.id) == first.history.map(\.id))
    for (stored, live) in zip(saved.history, first.history) {
        #expect(stored.snapshot == live.snapshot && stored.isPinned == live.isPinned && stored.pinOrder == live.pinOrder)
        #expect(stored.resultCount == live.resultCount)
        // The existing ISO-8601 persistence format stores whole seconds.
        #expect(abs(stored.searchedAt.timeIntervalSince(live.searchedAt)) < 1)
    }
    #expect(saved.history.first?.isPinned == true)
    first.clearHistory()
    await library.flush()
    #expect(second.history.isEmpty)
    #expect(try await persistence.loadLibrary().history.isEmpty)
}
