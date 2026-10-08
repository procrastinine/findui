import AppKit
import Foundation
import ScreenCaptureKit
import SearchBackend
import SwiftUI

@main struct GUIBenchmarkApp: App {
    @NSApplicationDelegateAdaptor(GUIBenchmarkDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class GUIBenchmarkDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            do { try await GUIBenchmark.run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@MainActor enum GUIBenchmark {
    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SearchServiceError.commandFailed(message) }; return value
    }
    static func wait(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw SearchServiceError.commandFailed(message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func text(_ object: AnyObject, seen: inout Set<ObjectIdentifier>) -> [String] {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        var result = [String]()
        if let label = object.accessibilityLabel?() { result.append(label) }
        if let value = object as? NSObject, value.responds(to: NSSelectorFromString("accessibilityValue")),
           let string = value.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String {
            result.append(string)
        }
        for child in object.accessibilityChildren?() ?? [] { result += text(child as AnyObject, seen: &seen) }
        return result
    }
    static func table(_ root: NSView) -> NSOutlineView? {
        views(root).compactMap { $0 as? NSOutlineView }.first { $0.tableColumns.contains { $0.title == "Name" } }
    }
    static func capture(_ window: NSWindow, to file: URL) async throws {
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }, "Own window capture")
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
        try require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "Screenshot encoding").write(to: file)
    }
    static func hasDrawnRow(_ names: Set<String>, root: NSView, window: NSWindow) -> Bool {
        guard let table = table(root), table.numberOfRows > 0,
              let column = table.tableColumns.firstIndex(where: { $0.title == "Name" }) else { return false }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return false }
        for row in visible.location..<min(table.numberOfRows, NSMaxRange(visible)) {
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) else { continue }
            var seen = Set<ObjectIdentifier>()
            let labels = text(cell, seen: &seen)
            guard labels.contains(where: { label in names.contains(where: label.contains) }) else { continue }
            // Include AppKit drawing, rather than stopping at a model publication.
            // This does not measure the subsequent physical display scan-out.
            window.displayIfNeeded()
            return true
        }
        return false
    }
    static func edit(_ value: String, field: NSSearchField, window: NSWindow) throws {
        window.makeFirstResponder(field)
        let editor = try require(field.currentEditor() as? NSTextView, "Search field editor unavailable")
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }
    static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-gui-benchmark-\(UUID())")
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(); try? FileManager.default.removeItem(at: root) }
        setenv("FINDUI_DATA_DIRECTORY", root.appendingPathComponent("settings").path, 1)
        setenv("FINDUI_CACHE_DIRECTORY", root.appendingPathComponent("cache").path, 1)
        setenv("FINDUI_QUERY_CACHE_DIRECTORY", root.appendingPathComponent("queries").path, 1)
        setenv("FINDUI_TIKA_JAR", "", 1)
        // SwiftUI creates accessibility nodes lazily. Enable them in this
        // disposable process, independent of a screen reader or other apps.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        var urls = [URL]()
        for i in 0..<2_000 {
            let name = String(format: "%@-%04d.txt", i.isMultiple(of: 4) ? "needle" : "other", i)
            let url = files.appendingPathComponent(name)
            try Data(String(repeating: "needle café line\n", count: 10).utf8).write(to: url)
            urls.append(url)
        }
        let persistence = AppPersistence(baseDirectory: root.appendingPathComponent("settings"))
        let library = SearchLibraryStore(persistence: persistence)
        let tools = Toolchain.resolve(includeDocumentReaders: false)
        let model = SearchViewModel(service: SearchService(tools: tools), persistence: persistence,
                                    loadSavedState: false, libraryStore: library)
        model.scopeURL = files; model.mode = .files; model.filenameInput = "absent-in-fixture"
        defer { model.stopSearch() }
        let view = NSHostingView(rootView: ContentView(viewModel: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = view; window.title = "FindUI · Responsiveness benchmark"
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let rounds = Int(ProcessInfo.processInfo.environment["FINDUI_GUI_ROUNDS"] ?? "5") ?? 5
        guard (1...31).contains(rounds) else { throw SearchServiceError.invalidQuery }
        var samples = [[String: Any]]()
        for scenario in ["liveNames", "liveContents", "preparedWords", "snapshotNames", "browse"] {
            model.stopSearch(); model.useIndex = false; model.refinements.wordSearch = nil
            model.contentsInput = ""; model.filenameInput = ""
            if ["liveContents", "preparedWords"].contains(scenario) {
                model.contentsInput = "absent-in-fixture"
            } else { model.filenameInput = "absent-in-fixture" }
            model.traversal.includeIgnored = false
            if scenario == "preparedWords" {
                model.contentMatchingChoice = .indexedWords; model.contentsInput = "absent-in-fixture"
                model.prepareContentIndex()
                try await wait("Word preparation did not finish: \(model.statusMessage)") { !model.preparingContents && !model.isSearching }
            }
            if scenario == "snapshotNames" {
                let volume = model.currentDrive.url
                let entries = urls.compactMap { IndexService(tools: tools).indexedEntry($0, scope: volume) }
                let index = ManagedIndex(id: UUID(), name: "Benchmark fixture", scopePath: volume.path,
                    includeHidden: true, createdAt: .now, updatedAt: .now, fileCount: entries.count,
                    folderCount: 0, entryCount: entries.count, engineName: "FindUI",
                    traversal: model.traversal, queryGeneration: UUID())
                try await persistence.saveIndex(IndexArtifact(metadata: index, entries: entries))
                library.value.managedIndexes = [index]; model.useIndex = true
            }
            let identifier = model.mode == .contents ? "searchInput" : "filenameInput"
            try await wait("Missing search input") { views(view).contains { ($0 as? NSSearchField)?.accessibilityIdentifier() == identifier } }
            for round in 0..<rounds {
                let field = try require(views(view).compactMap { $0 as? NSSearchField }.first { $0.accessibilityIdentifier() == identifier }, "Search input")
                try edit("absent-in-fixture", field: field, window: window)
                model.scheduleSearch(immediate: true)
                try await wait("Baseline search failed: \(model.statusMessage)") {
                    !model.isSearching && model.results.isEmpty && (table(view)?.numberOfRows ?? 0) == 0
                }
                try await Task.sleep(for: .milliseconds(40))
                let start = DispatchTime.now().uptimeNanoseconds
                try edit(scenario == "browse" ? "" : "needle", field: field, window: window)
                var published: Double?
                var drawn: Double?
                let deadline = ContinuousClock.now + .seconds(30)
                while drawn == nil || model.isSearching || model.results.isEmpty {
                    guard ContinuousClock.now < deadline else {
                        try? await capture(window, to: output.appendingPathComponent("\(scenario)-failed.png"))
                        var seen = Set<ObjectIdentifier>()
                        let labels = table(view).map { text($0, seen: &seen).prefix(12) } ?? []
                        throw SearchServiceError.commandFailed("\(scenario) did not render: \(model.statusMessage), rows=\(model.results.count), table=\(table(view)?.numberOfRows ?? -1), visible=\(String(describing: table(view)?.visibleRect)), labels=\(labels)")
                    }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    let actualRows = model.results.filter { !$0.isParentDirectoryEntry }
                    if !actualRows.isEmpty, model.query != "absent-in-fixture" {
                        if published == nil { published = elapsed }
                        if drawn == nil {
                            // Native row order may differ from discovery order,
                            // and more batches can arrive before the first draw.
                            let names = Set(actualRows.map { $0.displayNameOverride ?? $0.name })
                            if hasDrawnRow(names, root: view, window: window) {
                                drawn = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let expected = scenario == "liveContents" ? 20_000 : scenario == "preparedWords" ? 2_000 : scenario == "browse" ? 2_001 : 500
                guard model.totalResultCount == expected else { throw SearchServiceError.commandFailed("\(scenario) lost results: \(model.totalResultCount), expected \(expected)") }
                samples.append(["scenario": scenario, "round": round, "firstModelMilliseconds": published!,
                    "firstDrawnRowMilliseconds": drawn!, "completionMilliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                    "resultCount": model.totalResultCount])
            }
            print("PASS: \(scenario) editor input, native row drawing, and complete result count")
            fflush(nil)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let report: [String: Any] = ["note": "Release-optimized production GUI and backend. Native field-editor input through debounce, search, storage, SwiftUI table update and AppKit drawing. Two-millisecond polling; first sample retained. Does not measure physical keyboard latency or compositor/display scan-out. Warm disposable 2000-file fixture and default result presentation.", "samples": samples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("gui.json"))
        try await capture(window, to: output.appendingPathComponent("gui.png"))
        await library.shutdown()
        print("PASS: GUI responsiveness benchmark")
    }
}
