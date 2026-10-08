import SearchBackend
import AppKit
import SwiftUI
import ScreenCaptureKit
#if FINDUI_AUDIT_IMPORT
@testable import FindUI
#endif

@main struct FolderActionsAuditApp: App {
    @NSApplicationDelegateAdaptor(FolderActionsAuditDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class FolderActionsAuditDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            do { try await FolderActionsAudit.run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor enum FolderActionsAudit {
    static func run() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-folder-audit-\(UUID())")
        let folder = root.appendingPathComponent("Folder 'quoted' $(literal) `text` 文")
        let child = folder.appendingPathComponent("Subfolder")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: folder.appendingPathComponent("sample.txt"))
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let domain = "local.findui.folder-audit.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        try AISearchSettings().save(to: preferences)
        defer {
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            previous?.activate(options: [])
        }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let library = SearchLibraryStore(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("library")))
        let model = SearchViewModel(loadSavedState: false, libraryStore: library)
        var state = model.searchState
        state.scopePath = folder.path; state.mode = .everything; state.query = "*"
        model.restoreSearchState(state)
        model.scheduleSearch(immediate: true)
        for _ in 0..<100 where model.results.count < 2 || model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        let file = try require(model.results.first { $0.name == "sample.txt" }, "File fixture")
        let directory = try require(model.results.first { $0.name == "Subfolder" }, "Folder fixture")
        try check(FolderActions.terminalDirectory(for: file).path == folder.path, "File must use its parent")
        try check(FolderActions.terminalDirectory(for: directory).path == child.path, "Folder must use itself")
        let main = NSHostingView(rootView: ContentView(viewModel: model, aiPreferences: preferences).preferredColorScheme(.light))
        let window = show(main, width: 1000, height: 740)
        defer { model.shutdown(); window.close() }
        try await settle()
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        let finder = try find("openScopeFinder", in: main), terminal = try find("openScopeTerminal", in: main)
        try check(!finder.frame.intersects(terminal.frame) && terminal.frame.minX > finder.frame.maxX, "Scope actions overlap")
        try check(window.frame.contains(finder.frame) && window.frame.contains(terminal.frame), "Scope actions are clipped")
        try await capture(window, output.appendingPathComponent("scope-light.png"))
        do { try await terminalAction(at: folder) { try press("openScopeTerminal", in: main) } }
        catch { print("Folder action error: \(model.actionError ?? "none")"); throw error }
        try press("openScopeFinder", in: main); try await settle()
        try check(model.actionError == nil, "Finder action failed")

        let inspector = NSHostingView(rootView: InfoInspectorView(viewModel: model).preferredColorScheme(.light))
        let inspectorWindow = show(inspector, width: 280, height: 840)
        defer { inspectorWindow.close() }
        for name in ["sample.txt", "Subfolder"] {
            let result = try require(model.results.first { $0.name == name }, "Current result: " + name)
            model.selectedResultIDs = [result.id]
            try await settle()
            let button = try find("openInspectorTerminal", in: inspector)
            print("Inspector button: \(String(describing: button.object.accessibilityLabel?())) / \(String(describing: button.object.accessibilityRole?())) / \(button.frame)")
            try check(button.object.accessibilityLabel?() == (result.kind == .folder ? "Open folder in Terminal" : "Open containing folder in Terminal"), "Inspector label does not identify the destination")
            try check(inspectorWindow.frame.contains(button.frame), "Inspector action clipped at minimum width")
            try await terminalAction(at: FolderActions.terminalDirectory(for: result)) { try press("openInspectorTerminal", in: inspector) }
            try await capture(inspectorWindow, output.appendingPathComponent("inspector-\(result.kind.rawValue).png"))
        }

        // A typed path must be committed by the action itself, without Return.
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let field = try require(views(main).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Directory path" }, "Scope field")
        window.makeFirstResponder(field); field.selectText(nil)
        let editor = try require(field.currentEditor() as? NSTextView, "Scope editor")
        editor.insertText(child.path, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle()
        try await terminalAction(at: child) { try press("openScopeTerminal", in: main) }
        try check(model.scopeURL.path == child.path && model.actionError == nil, "Typed scope was not committed")
        main.rootView = ContentView(viewModel: model, aiPreferences: preferences).preferredColorScheme(.dark)
        try await settle(); try await capture(window, output.appendingPathComponent("scope-dark.png"))
        do { try await FolderActions.openTerminal(at: root.appendingPathComponent("missing")); throw failure("Missing folder opened Terminal") }
        catch { try check(error.localizedDescription.hasPrefix("Folder not found:"), "Missing-folder failure is not actionable") }
        await library.shutdown()
        print("PASS: Finder and Terminal scope buttons, committed path edits, inspector file/folder destinations, missing folder, actual shell working directories including quoted paths, 1000-point window and 280-point inspector.")
    }

    struct Element {
        let object: AnyObject
        var frame: NSRect { object.accessibilityFrame?() ?? .zero }
    }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func find(_ id: String, in view: NSView) throws -> Element {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) -> Element? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.accessibilityIdentifier?() == id { return Element(object: object) }
            for child in object.accessibilityChildren?() ?? [] {
                if let found = visit(child as AnyObject) { return found }
            }
            return nil
        }
        for child in views(view) { if let found = visit(child) { return found } }
        throw failure("Missing control: " + id)
    }
    static func press(_ id: String, in view: NSView) throws {
        try check(try find(id, in: view).object.accessibilityPerformPress?() == true, "Could not press " + id)
    }
    static func terminalAction(at folder: URL, _ action: () throws -> Void) async throws {
        let before = try shellIDs()
        try action()
        var observed: [Int32: String] = [:]
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            let added = try shellIDs().subtracting(before)
            for pid in added {
                let cwd = try run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]).split(separator: "\n").first { $0.hasPrefix("n/") }.map { URL(fileURLWithPath: String($0.dropFirst())).resolvingSymlinksInPath() }
                observed[pid] = cwd?.path ?? "unknown"
                if cwd?.path == folder.resolvingSymlinksInPath().path {
                    // This shell was created by the audited button, not an
                    // existing Terminal session. Close only that test shell.
                    kill(pid, SIGHUP)
                    print("PASS: Terminal working directory = \(folder.lastPathComponent)")
                    return
                }
            }
        }
        throw failure("Terminal did not start a shell in \(folder.path); observed \(observed)")
    }
    static func shellIDs() throws -> Set<Int32> {
        Set(try run("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            let name = URL(fileURLWithPath: String(parts[1]).trimmingCharacters(in: .whitespaces)).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard ["zsh", "bash", "fish", "sh"].contains(name) else { return nil }
            return Int32(parts[0])
        })
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    static func show(_ view: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.title = "FindUI Folder Actions Audit"
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        return window
    }
    static func capture(_ window: NSWindow, _ path: URL) async throws {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await settle()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let target = try require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }, "Capture window")
        let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2); config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        try require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "PNG").write(to: path)
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
    static func failure(_ message: String) -> NSError { NSError(domain: "FindUIFolderAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    static func require<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
}
