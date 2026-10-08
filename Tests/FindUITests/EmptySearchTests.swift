@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test @MainActor func blankSearchPreferenceBrowsesBothKindsAndNavigatesWithoutRecursing() async throws {
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("findui-browse-\(UUID())")
    let root = temporary.appendingPathComponent("root"), child = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:temporary) }
    let top = root.appendingPathComponent("top.txt"), nested = child.appendingPathComponent("nested.txt")
    try Data().write(to:top); try Data().write(to:nested)
    let persistence = AppPersistence(baseDirectory:temporary.appendingPathComponent("settings"))
    let model = SearchViewModel(persistence:persistence,loadSavedState:false)
    defer { model.stopSearch() }
    model.scopeURL = root
    func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if !model.isSearching && predicate() { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        Issue.record("Directory/search result did not settle: \(model.statusMessage); expected root \(root.path); got \(model.results.map { $0.url.path })")
    }
    for mode in [SearchMode.files, .folders, .everything] {
        model.mode = mode; model.scheduleSearch(immediate:true)
        try await waitFor { model.results.contains { $0.url.resolvingSymlinksInPath().path == top.path } }
        #expect(model.isBrowsingDirectory)
        #expect(model.results.contains { $0.url.resolvingSymlinksInPath().path == child.path && $0.isBrowsableDirectoryEntry })
        #expect(!model.results.contains { $0.url.resolvingSymlinksInPath().path == nested.path })
        #expect(model.results.contains { $0.isParentDirectoryEntry })
    }
    model.browse(to:child)
    try await waitFor { model.results.contains { $0.url.resolvingSymlinksInPath().path == nested.path } }
    let parent = try #require(model.results.first { $0.isParentDirectoryEntry })
    model.browse(to:parent.url)
    try await waitFor { model.results.contains { $0.url.resolvingSymlinksInPath().path == top.path } }
    #expect(model.scopeURL.path == root.path)
    model.emptySearchBehavior = .search; model.persistEmptySearchPreference()
    try await waitFor { model.results.contains { $0.url.resolvingSymlinksInPath().path == nested.path } }
    #expect(!model.isBrowsingDirectory)
    #expect(try await persistence.loadLibrary().emptySearchBehavior == .search)
    model.emptySearchBehavior = .browse; model.persistEmptySearchPreference()
    try await waitFor { !model.results.contains { $0.url.resolvingSymlinksInPath().path == nested.path } }
    #expect(model.isBrowsingDirectory)
    model.refinements.extensions = "txt"
    #expect(!model.isBrowsingDirectory)
    model.refinements.extensions = ""
    model.updateRules(.init())
    #expect(model.isBrowsingDirectory)
}

@Test func oldSettingsIgnoreRemovedModelPreferenceAndKeepDirectoryBrowsing() throws {
    let old = Data(#"{"history":[],"savedSearches":[],"managedIndexes":[],"loadSearchModelAtStartup":true}"#.utf8)
    var library = try JSONDecoder().decode(PersistedLibrary.self, from: old)
    #expect(library.emptySearchBehavior == .browse)
    library.emptySearchBehavior = .search
    let encoded = try JSONEncoder().encode(library)
    let restored = try JSONDecoder().decode(PersistedLibrary.self, from: encoded)
    #expect(restored.emptySearchBehavior == .search)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("loadSearchModelAtStartup"))
}

@Test @MainActor func invalidFolderEditsKeepTheExistingScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-folder-edit-\(UUID())")
    let child = root.appendingPathComponent("Child Folder")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("settings")), loadSavedState: false)
    defer { model.stopSearch() }
    model.scopeURL = root
    #expect(!model.updateScopePath("   "))
    #expect(model.scopeURL.path == root.path)
    #expect(!model.updateScopePath(root.appendingPathComponent("absent").path))
    #expect(model.scopeURL.path == root.path)
    #expect(model.statusMessage.contains("Directory not found"))
    #expect(model.updateScopePath(child.path))
    #expect(model.scopeURL.path == child.standardizedFileURL.path)
}
