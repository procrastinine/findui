import SearchBackend
import AppKit
import SwiftUI
import ScreenCaptureKit
#if FINDUI_AUDIT_IMPORT
@testable import FindUI
#endif

@main struct SearchComparisonApp: App {
    @NSApplicationDelegateAdaptor(SearchComparisonDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class SearchComparisonDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            do { try await SearchComparison.render(); exit(0) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor enum SearchComparison {
    static func render() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let root = URL(fileURLWithPath: "/tmp/FindUI Demo-\(UUID().uuidString.prefix(6))")
        let project = root.appendingPathComponent("Atlas")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures: [(String, String)] = [
            ("Sources/NetworkClient.swift", """
            import Foundation

            struct NetworkClient {
                let timeout: TimeInterval = 30
                let retryLimit = 3

                func load(_ request: URLRequest) async throws -> Data {
                    // Retry transient failures with a short backoff.
                    for attempt in 0..<retryLimit {
                        do {
                            let (data, _) = try await URLSession.shared.data(for: request)
                            return data
                        } catch where attempt + 1 < retryLimit {
                            try await Task.sleep(for: .seconds(attempt + 1))
                        }
                    }
                    throw URLError(.timedOut)
                }
            }
            """),
            ("Sources/SyncService.swift", "import Foundation\n\nstruct SyncService {\n    // Retry a sync when the connection recovers.\n    let retryDelay = 2.0\n    let timeout = 60.0\n}\n"),
            ("Tests/NetworkClientTests.swift", "import Testing\n\n@Test func retryAfterTimeout() async throws {\n    // A temporary timeout should retry the request.\n    #expect(true)\n}\n"),
            ("Docs/Release plan.md", "# Atlas release plan\n\nA calmer way to keep projects in sync.\n\n## Reliability\n\nRetry temporary network failures with exponential backoff.\nKeep offline edits safe until the connection recovers.\n\n## Ready to ship\n\n- Clear progress for long-running transfers\n- Faster startup and fewer repeated requests\n- Searchable logs for troubleshooting\n"),
            ("Docs/Architecture.md", "# Architecture\n\nThe network client owns request timeouts and retry policy.\nThe release keeps data access separate from the interface.\n"),
            ("Archive/Draft.md", "# Draft\n\nAn earlier release proposal.\n"),
            ("Sources/GeneratedClient.swift", "// Generated file\nlet retryLimit = 2\n")]
        for (name, text) in fixtures {
            let file = project.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let domain = "local.findui.screenshot.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        try AISearchSettings().save(to: preferences)
        defer { preferences.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root); previous?.activate(options: []) }
        let library = SearchLibraryStore(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("Settings")))
        let model = SearchViewModel(loadSavedState: false, libraryStore: library)
        defer { model.shutdown() }
        model.scopeURL = project; model.filenameInput = "*.swift"; model.contentsInput = "retry"
        model.contentMatchingChoice = .literal; model.isInspectorPresented = true
        let simple = model.searchState
        for (i, query) in ["*.swift", "*.md", "*Network*", "*Sync*", "*Tests*"].enumerated() {
            var state = simple; state.contentsInput = ""; state.refinements.name = query
            let results = try await SearchService().search(request: state.makeRequest())
            library.value.history.append(SearchHistoryEntry(id: UUID(), snapshot: state, searchedAt: Date().addingTimeInterval(Double(-i * 600)),
                resultCount: results.results.count, engineName: results.engineName, isPinned: i < 2, pinOrder: i < 2 ? i : nil))
        }
        let view = NSHostingView(rootView: ContentView(viewModel: model, aiPreferences: preferences).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 1060), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "FindUI — Atlas"; window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        model.scheduleSearch(immediate: true)
        try await settle(model)
        model.selectedResultIDs = Set(model.results.first { $0.name == "NetworkClient.swift" }.map { [$0.id] } ?? [])
        try await Task.sleep(for: .milliseconds(600))
        window.makeFirstResponder(nil)
        let left = try await capture(window)
        try save(left, output.appendingPathComponent("search-simple.png"))

        let f: (SearchFileRule) -> SearchRuleTree<SearchCondition> = { .rule(.file($0)) }
        let c: (String) -> SearchRuleTree<SearchCondition> = { .rule(.content(.literal($0))) }
        var complex = simple
        complex.replaceRules(.init(expression: .all([
            .any([
                .all([f(.extensions(["swift"])), .any([c("retry"), c("timeout")])]),
                .all([f(.extensions(["md"])), c("release")])]),
            .none([f(.name("Generated*", .glob)), .all([f(.path("Archive", .contains, absolute: false)), c("draft")])])
        ]), contentUnit: .file))
        window.appearance = NSAppearance(named: .darkAqua)
        view.rootView = ContentView(viewModel: model, aiPreferences: preferences).preferredColorScheme(.dark)
        model.restoreSearchState(complex); model.scheduleSearch(immediate: true)
        try await settle(model)
        model.selectedResultIDs = Set(model.results.first { $0.name == "Release plan.md" }.map { [$0.id] } ?? [])
        try await Task.sleep(for: .seconds(1))
        window.makeFirstResponder(nil)
        let right = try await capture(window)
        try save(right, output.appendingPathComponent("search-rules.png"))
        // Compose the two actual native captures at equal scale; no recreated
        // controls or sample result overlays are drawn into either half.
        let width = left.width + right.width, height = max(left.height, right.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(left, in: CGRect(x: 0, y: height-left.height, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width, y: height-right.height, width: right.width, height: right.height))
        try save(context.makeImage()!, output.appendingPathComponent("search-comparison.png"))
        await library.shutdown()
        print("PASS: actual simple and nested search results; both sidebars, inspector previews, and equal-width native screenshots")
    }
    static func settle(_ model: SearchViewModel) async throws {
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<200 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        guard !model.results.isEmpty, !model.isSearching else { throw NSError(domain: "Screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: model.statusMessage]) }
    }
    static func capture(_ window: NSWindow) async throws -> CGImage {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<30 where !NSApp.isActive || !window.isKeyWindow {
            try await Task.sleep(for: .milliseconds(100))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        guard NSApp.isActive, window.isKeyWindow else {
            throw NSError(domain: "Screenshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Demo window did not become active."])
        }
        try await Task.sleep(for: .milliseconds(350))
        let windows = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = windows.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "Screenshot", code: 2) }
        let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2); config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
    }
    static func save(_ image: CGImage, _ url: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
    }
}
