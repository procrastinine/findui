import SearchBackend
import SearchCore
#if FINDUI_AUDIT_IMPORT
@testable import FindUI
#endif
import AppKit
import SwiftUI
import ScreenCaptureKit

// Real Settings views and native input, with disposable versions and indexes.
// This audit makes no downloads and never uses the user's Tika/index store.
@main struct SettingsAuditApp: App {
    @NSApplicationDelegateAdaptor(SettingsAuditDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class SettingsAuditDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL: Settings audit exceeded its 180-second deadline.\n".utf8)); exit(2)
        }
        Task {
            do { try await SettingsAudit.run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor enum SettingsAudit {
    static func run() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-settings-audit-\(UUID())")
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { previous?.activate(options: []); try? FileManager.default.removeItem(at: root) }
        let manager = TikaManager(directory: root.appendingPathComponent("tika"))
        try seedTika(manager)
        setenv("FINDUI_READER_CONFIG", root.appendingPathComponent("readers.json").path, 1)
        try ReaderConfiguration().update { $0 = [ReaderAdapter(id: "fixture", title: "Fixture reader", extensions: ["custom"], executable: "/bin/cat", arguments: ["{path}"])] }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))

        let persistence = AppPersistence(baseDirectory: root.appendingPathComponent("library"))
        let library = SearchLibraryStore(persistence: persistence)
        let model = SearchViewModel(loadSavedState: false, libraryStore: library)
        defer { model.stopSearch() }
        let view = NSHostingView(rootView: SettingsView(viewModel: model, tikaManager: manager).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "FindUI Settings Audit"
        window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        for _ in 0..<10 where !window.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            try await settle()
            window.makeKeyAndOrderFront(nil)
        }
        if CommandLine.arguments.contains("--layout-only") {
            try await searchUI(model: model, root: root, output: output)
            await library.shutdown()
            print("PASS: Search UI layouts and accessibility actions audited without desktop activation")
            return
        }
        if CommandLine.arguments.contains("--allow-inactive") && (!window.isKeyWindow || !NSApp.isActive) {
            print("LIMIT: macOS denied foreground activation; checking native in-process input and accessibility actions, not desktop focus.")
        } else {
            try check(window.isKeyWindow && NSApp.isActive, "Audit must have a real active window: key=\(window.isKeyWindow), active=\(NSApp.isActive)")
        }
        try await settle()
        let directory = try element("defaultSearchDirectory", in: view)
        try await capture(window, output.appendingPathComponent("general-before-input.png"))
        let originalDefault = model.defaultSearchDirectoryPath
        for path in [root.appendingPathComponent("missing-folder").path, root.path] {
            try await click(directory, x: 60, window: window)
            let editor = try required(window.firstResponder as? NSTextView, "Default folder editor")
            editor.insertText(path, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await settle(); window.makeFirstResponder(nil); try await settle()
            if path != root.path {
                try check(model.defaultSearchDirectoryPath == originalDefault && model.defaultDirectoryError != nil,
                          "Invalid folder changed the saved default or did not explain the error")
                _ = try element("defaultDirectoryError", in: view)
                try await capture(window, output.appendingPathComponent("general-validation.png"))
            } else {
                try check(library.value.defaultSearchDirectoryPath == path && model.defaultDirectoryError == nil,
                          "Default folder did not save on blur or clear its validation error")
            }
        }
        print("PASS: default folder saves without Return; invalid edits stay visible without replacing the saved folder")
        try await capture(window, output.appendingPathComponent("general.png"))
        scroll(view, bottom: true); try await settle()
        try await capture(window, output.appendingPathComponent("general-bottom.png"))

        let tabs = try required(views(view).compactMap { $0 as? NSSegmentedControl }.first, "Settings tabs")
        tabs.selectedSegment = 1; tabs.sendAction(tabs.action, to: tabs.target); try await settle()
        let volumes = [StorageVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD"),
                       StorageVolume(url: root.appendingPathComponent("Backup Drive"), name: "Backup Drive"),
                       StorageVolume(url: root.appendingPathComponent("External Archive"), name: "External Archive")]
        model.availableVolumes = volumes
        let index = ManagedIndex(id: UUID(), name: "Backup Drive", scopePath: volumes[1].url.path, includeHidden: true,
            createdAt: .now, updatedAt: .now, fileCount: 1, folderCount: 1, entryCount: 2, engineName: "fd")
        try await persistence.saveEntries([.init(relativePath: "Projects", kind: .folder),
                                           .init(relativePath: "Projects/Report.txt", kind: .file, size: 123)], for: index.id)
        library.value.managedIndexes = [index]
        let drives = try required(views(view).compactMap { $0 as? NSTableView }.first, "Drive list")
        for row in [0, 1, 2, 1] {
            let point = drives.convert(NSPoint(x: 55, y: drives.rect(ofRow: row).midY), to: nil)
            try await click(point, window: window)
            try check(model.selectedManagerDrivePath == volumes[row].url.path, "Clicking drive \(row) did not select it")
        }
        try await capture(window, output.appendingPathComponent("indexes-selected.png"))
        let entries = try required(views(view).compactMap { $0 as? NSTableView }.first { $0 !== drives }, "Index entries table")
        try check((entries.enclosingScrollView?.contentView.bounds.height ?? 0) >= 120, "Index details squeezed the entries table")
        // Selection stays blue when a control in the detail pane takes focus.
        window.makeFirstResponder(nil)
        try await capture(window, output.appendingPathComponent("indexes-unfocused.png"))
        try assertBlueSelection(drives, row: 1)
        window.makeFirstResponder(drives)
        let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
        window.sendEvent(arrow); try await settle()
        try check(model.selectedManagerDrivePath == volumes[2].url.path, "Drive keyboard selection stopped working")
        print("PASS: drive clicks and arrow keys select the drive; its row stays blue without keyboard focus")

        tabs.selectedSegment = 2; tabs.sendAction(tabs.action, to: tabs.target); try await settle()
        scroll(view, bottom: false); try await settle()
        try await capture(window, output.appendingPathComponent("tools-before.png"))
        let title = try element("documentReadersTitle", in: view)
        let reload = try element("refreshDocumentReaders", in: view)
        try check(abs(title.frame.midY - reload.frame.midY) < 12 && reload.frame.minX - title.frame.maxX < 20,
                  "Reload is not next to the Document readers title")
        try press(reload); try await settle()
        try check(!elements(view).contains { $0.label == "Refresh Tools" }, "The old refresh row is still present")
        try check(find("tikaRemove.3.3.2", in: view) == nil, "Versions should initially be collapsed")
        try await click(try element("tikaManageVersions", in: view), x: 65, window: window)
        _ = try element("tikaRemove.3.3.2", in: view)
        try await click(try element("tikaManageVersions", in: view), x: 65, window: window)
        try check(find("tikaRemove.3.3.2", in: view) == nil, "Clicking Manage versions text did not collapse it")
        try await click(try element("tikaManageVersions", in: view), x: 6, window: window)
        _ = try element("tikaRemove.3.3.2", in: view)
        let header = try element("tikaManageVersions", in: view)
        try await click(header, x: header.frame.width - 10, window: window)
        try check(find("tikaRemove.3.3.2", in: view) == nil, "The disclosure's empty header space is not clickable")
        try press(try element("tikaManageVersions", in: view)); try await settle()
        let remove = try element("tikaRemove.3.3.1", in: view)
        try check(remove.frame.maxX < header.frame.maxX - 4, "Remove extends into the disclosure's right edge")
        try await capture(window, output.appendingPathComponent("tools-expanded.png"))
        try press(remove); try await settle()
        try check(try manager.status().installed.map(\.version) == ["3.3.2"], "Remove did not remove only the fixture version")
        print("PASS: Manage versions text, caret, full header and accessibility action toggle; Remove is inset and works")

        scroll(view, bottom: true); try await settle()
        try await click(try element("installedToolDetails", in: view), x: 90, window: window)
        scroll(view, bottom: true); try await settle()
        let toolPath = try element("toolPath-fzf", in: view)
        try check(toolPath.frame.width > 0, "Bundled fuzzy tool path is not visible")
        try check(find("copyRecommendedSearchToolsCommand", in: view) == nil,
                  "Settings asks users to install an already included search tool")
        try await capture(window, output.appendingPathComponent("tools-details.png"))
        scroll(view, bottom: false); try await settle()
        // Collapse Tika to bring the installed-tools header into view again.
        try press(try element("tikaManageVersions", in: view)); try await settle()
        scroll(view, bottom: true); try await settle()
        try press(try element("installedToolDetails", in: view)); try await settle()
        try check(find("toolPath-fzf", in: view) == nil, "Installed tool details did not collapse")
        print("PASS: Installed tool details text toggles, included tools need no install command, reload sits beside its title")

        try press(try element("customReaders", in: view)); try await settle()
        scroll(view, bottom: true); try await settle()
        try press(try element("editCustomReader.fixture", in: view)); try await settle()
        let editorWindow = try required(window.sheets.first, "Custom reader editor sheet")
        let editorView = try required(editorWindow.contentView, "Custom reader editor")
        try await capture(editorWindow, output.appendingPathComponent("custom-reader-editor.png"))
        try press(try element("saveCustomReader", in: editorView)); try await settle()
        try check(window.sheets.isEmpty && (try ReaderConfiguration().load().first?.arguments) == ["{path}"], "Custom reader editor did not save shared configuration")
        try await capture(window, output.appendingPathComponent("custom-readers.png"))
        try press(try element("customReaders", in: view)); try await settle()
        print("PASS: Custom reader disclosure and editor save the shared headless configuration")

        window.setContentSize(NSSize(width: 1040, height: 760))
        view.rootView = SettingsView(viewModel: model, tikaManager: manager).preferredColorScheme(.dark)
        scroll(view, bottom: false); try await settle()
        try press(try element("tikaManageVersions", in: view)); try await settle()
        try await capture(window, output.appendingPathComponent("tools-dark-wide.png"))
        let options = NSHostingView(rootView: SearchOptionsView(viewModel: model).preferredColorScheme(.light))
        let optionsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 650),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        optionsWindow.contentView = options; optionsWindow.center(); optionsWindow.makeKeyAndOrderFront(nil)
        defer { optionsWindow.orderOut(nil) }
        try await settle(); scroll(options, bottom: true); try await settle()
        try await click(try element("advancedSearchOptions", in: options), x: 50, window: optionsWindow)
        scroll(options, bottom: true); try await settle()
        try check(elements(options).contains { $0.label == "Parallel search workers" }, "Advanced label did not expand options")
        try await capture(optionsWindow, output.appendingPathComponent("advanced-options.png"))
        _ = try element("prepareContentIndex", in: options)
        try await searchUI(model: model, root: root, output: output)
        await library.shutdown()
        print("PASS: Settings interactions, minimum-size layout, wide/dark layout and Advanced disclosure audited")
    }

    static func searchUI(model: SearchViewModel, root: URL, output: URL) async throws {
        let presetRoot = root.appendingPathComponent("presets")
        model.presetStore = SearchPresetStore(directory: presetRoot)
        var state = model.searchState
        state.scopePath = root.path; state.useIndex = false; state.mode = .files
        state.refinements.name = "report"; state.refinements.finderTags = ["Review"]
        model.restoreSearchState(state)
        model.savePreset(name: "Reports awaiting review", kind: .filter)
        model.savePreset(name: "Project folders", kind: .scope)
        model.savePreset(name: "Weekly document review", kind: .search)
        let presetHost = NSHostingView(rootView: ContentView(viewModel: model).preferredColorScheme(.light))
        let presetHostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        presetHostWindow.contentView = presetHost; presetHostWindow.center(); presetHostWindow.makeKeyAndOrderFront(nil)
        defer { presetHostWindow.orderOut(nil) }
        try await settle()
        try press(try element("searchPresets", in: presetHost)); try await settle()
        let presetWindow = try required(NSApp.windows.first { window in
            window.isVisible && window.contentView.map { find("newPreset", in: $0) != nil } == true
        }, "Presets popover")
        let presets = try required(presetWindow.contentView, "Presets content")
        // Accessibility presses do not perform WindowServer click activation.
        // Give the popover the same key-window state as a user clicking it.
        presetWindow.makeKeyAndOrderFront(nil)
        try await settle()
        try check(model.presets.count == 3, "Presets did not persist")
        try await capture(presetWindow, output.appendingPathComponent("presets.png"))
        try press(try element("newPreset", in: presets)); try await settle()
        let nameElement = try element("presetName", in: presets)
        if !CommandLine.arguments.contains("--layout-only") {
            let field = try required(views(presets).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Preset name" }, "Preset name field")
            if field.currentEditor() == nil && CommandLine.arguments.contains("--allow-inactive") && !NSApp.isActive {
                print("LIMIT: preset autofocus requires an active window; verifying its field by a native click.")
                try await click(nameElement, x: 30, window: field.window ?? presetWindow)
            }
            let editor = try required(field.currentEditor() as? NSTextView,
                "Focused preset name editor (key=\(presetWindow.isKeyWindow), active=\(NSApp.isActive), attached=\(field.window === presetWindow))")
            editor.insertText("  Native preset  ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await settle()
            try check(model.filenameInput == "report", "Preset editing changed the underlying search input")
        }
        try await capture(presetWindow, output.appendingPathComponent("preset-save.png"))
        try press(try element("savePreset", in: presets)); try await settle()
        try check(model.presets.count == 4 && model.presetError == nil, "Save Current Search did not save a preset")
        if !CommandLine.arguments.contains("--layout-only") {
            try check(model.presets.contains { $0.name == "Native preset" }, "Preset names did not trim surrounding whitespace")
        }
        let kinds = try required(views(presets).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Searches" }, "Preset kind picker")
        kinds.selectedSegment = 1; kinds.sendAction(kinds.action, to: kinds.target); try await settle()
        try await capture(presetWindow, output.appendingPathComponent("preset-filters.png"))
        let savedFilter = try required(model.presets.first { $0.kind == .filter }, "Saved filter")
        _ = try element("applyPreset.\(savedFilter.id)", in: presets)
        var rules = SearchRuleSet(files: .rule(.tags(["Review", "Research"], .any)),
            contents: .all([.rule(.proximity(.init(terms: ["alpha", "beta"], distance: 3, ordered: true))),
                            .rule(.metadata(.author, "Ada"))]), contentUnit: .document)
        state.replaceRules(rules); model.restoreSearchState(state)
        let ruleView = NSHostingView(rootView: SearchRuleEditor(viewModel: model).preferredColorScheme(.light))
        let ruleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 355),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ruleWindow.contentView = ruleView; ruleWindow.center(); ruleWindow.makeKeyAndOrderFront(nil)
        defer { ruleWindow.orderOut(nil) }
        try await settle(); try await capture(ruleWindow, output.appendingPathComponent("document-rules.png"))
        try check(model.ruleValidationMessage == nil, "New rule controls produced invalid criteria")
        let mixed: SearchRuleTree<SearchCondition> = .all([
            .any([.all([.rule(.file(.extensions(["swift"]))), .rule(.content(.literal("TODO")))]),
                  .all([.rule(.file(.extensions(["md"]))), .rule(.content(.literal("FIXME")))])]),
            .rule(.file(.size(minimum: "1", maximum: "")))])
        state.replaceRules(.init(expression: mixed)); model.restoreSearchState(state)
        ruleWindow.setContentSize(NSSize(width: 920, height: 470)); try await settle()
        _ = try element("addRule.rules", in: ruleView)
        try check(find("addRule.files", in: ruleView) == nil && find("addRule.contents", in: ruleView) == nil,
                  "Detailed rules still split files and contents")
        let joins = views(ruleView).compactMap { $0 as? NSPopUpButton }.filter { $0.itemTitles == ["All (AND)", "Any (OR)", "None (NOT)"] }
        try check(joins.count == 4, "Nested groups are missing independent operator controls")
        let rootJoin = try required(joins.first, "Root group operator")
        rootJoin.selectItem(withTitle: "Any (OR)"); rootJoin.sendAction(rootJoin.action, to: rootJoin.target); try await settle()
        if case .any = model.searchRules?.expression {} else { throw NSError(domain: "Rules root operator did not update the shared tree", code: 1) }
        rootJoin.selectItem(withTitle: "All (AND)"); rootJoin.sendAction(rootJoin.action, to: rootJoin.target); try await settle()
        try check(model.searchRules?.expression == mixed, "Changing the root operator altered nested branches")
        let type = try required(views(ruleView).compactMap { $0 as? NSPopUpButton }.first { $0.titleOfSelectedItem == "File type" }, "Unified condition type")
        type.selectItem(withTitle: "Contents"); type.sendAction(type.action, to: type.target); try await settle()
        try check(model.searchRules?.expression.leaves.first == .content(.literal("swift")), "Changing from file type to content lost the text or edited another row")
        type.selectItem(withTitle: "File type"); type.sendAction(type.action, to: type.target); try await settle()
        try check(model.searchRules?.expression == mixed, "Changing a condition type did not restore the exact branch")
        try await capture(ruleWindow, output.appendingPathComponent("mixed-rules.png"))
        ruleView.rootView = SearchRuleEditor(viewModel: model).preferredColorScheme(.dark)
        try await settle(); try await capture(ruleWindow, output.appendingPathComponent("mixed-rules-dark.png"))
        ruleView.rootView = SearchRuleEditor(viewModel: model).preferredColorScheme(.light)
        try await settle()
        try press(try element("removeRule.rules.0.0.1", in: ruleView)); try await settle()
        try check(model.searchRules?.contentLeaves == [.literal("FIXME")], "Removing one nested content row changed another branch")
        try check(model.ruleValidationMessage == nil, "Removing a nested leaf left an invalid hidden condition")
        var deep: SearchRuleTree<SearchCondition> = .rule(.content(.literal("needle")))
        for level in 0..<7 { deep = level.isMultiple(of: 2) ? .all([deep]) : .any([deep]) }
        state.replaceRules(.init(expression: deep)); model.restoreSearchState(state); try await settle()
        try check(model.ruleValidationMessage == nil, "A supported deep group was rejected")
        scroll(ruleView, bottom: true); try await settle()
        try await capture(ruleWindow, output.appendingPathComponent("deep-rules.png"))
        state.replaceRules(rules); model.restoreSearchState(state)
        print("PASS: unified mixed rules render nested groups; native operators, row type changes and leaf removal update the shared expression")
        let options = NSHostingView(rootView: SearchExtractionView(options: Binding(
            get: { model.refinements.extraction }, set: { model.refinements.extraction = $0 })).padding(20).preferredColorScheme(.light))
        let optionsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 455, height: 170),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        optionsWindow.contentView = options; optionsWindow.center(); optionsWindow.makeKeyAndOrderFront(nil)
        defer { optionsWindow.orderOut(nil) }
        model.refinements.extraction = nil
        try await settle()
        try press(try element("searchExtractedText", in: options)); try await settle()
        try check(model.refinements.extraction?.documents == true && model.refinements.extraction?.archives == false, "Documents enabled archive expansion")
        try press(try element("searchArchives", in: options)); try await settle()
        try press(try element("searchExtractedText", in: options)); try await settle()
        try check(model.refinements.extraction?.documents == false && model.refinements.extraction?.archives == true, "Independent archive choice was lost")
        try press(try element("searchArchives", in: options)); try await settle()
        try check(model.refinements.extraction == nil, "Turning off both readers left conversion enabled")
        try press(try element("searchMedia", in: options)); try await settle()
        try check(model.refinements.extraction?.media == true && model.refinements.extraction?.documents == false && model.refinements.extraction?.archives == false, "Media enabled another reader")
        try press(try element("searchMedia", in: options)); try await settle()
        try press(try element("searchCustomReaders", in: options)); try await settle()
        try check(model.refinements.extraction?.customReaders == true && model.refinements.extraction?.media == false, "Custom reader choice was lost")
        try press(try element("searchCustomReaders", in: options)); try await settle()
        try check(model.refinements.extraction == nil, "Disabling all readers did not restore ordinary search")
        try await capture(optionsWindow, output.appendingPathComponent("explicit-conversion-options.png"))
        // Check the main search bar at its normal minimum width as well.
        rules.contents = nil; state.replaceRules(rules); model.restoreSearchState(state)
        let main = NSHostingView(rootView: ContentView(viewModel: model).preferredColorScheme(.light))
        let mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        mainWindow.contentView = main; mainWindow.center(); mainWindow.makeKeyAndOrderFront(nil)
        defer { mainWindow.orderOut(nil) }
        try await settle()
        _ = try element("searchPresets", in: main)
        try await capture(mainWindow, output.appendingPathComponent("main-with-presets.png"))
        let manifest = root.appendingPathComponent("results.nul")
        try Data((root.path + "\0").utf8).write(to: manifest)
        state.resultScope = .init(path: manifest.path, name: "Results of quarterly report", count: 1)
        model.restoreSearchState(state); try await settle()
        _ = try element("resultScopeBanner", in: main)
        try check(!views(main).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Directory path" },
                  "Result scope still has a competing folder input")
        try await capture(mainWindow, output.appendingPathComponent("result-scope.png"))
        try press(try element("clearResultScope", in: main)); try await settle()
        try check(model.searchState.resultScope == nil, "Use Folder did not clear the result scope")
        model.useCompactControls()
        let scopeOptions = NSHostingView(rootView: SearchOptionsView(viewModel: model).preferredColorScheme(.light))
        let scopeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        scopeWindow.contentView = scopeOptions; scopeWindow.center(); scopeWindow.makeKeyAndOrderFront(nil)
        defer { scopeWindow.orderOut(nil) }
        try await settle()
        if !CommandLine.arguments.contains("--layout-only") {
            try await click(try element("Finder tag names", in: scopeOptions), x: 35, window: scopeWindow)
            let editor = try required(scopeWindow.firstResponder as? NSTextView, "Finder tags editor")
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewlineIgnoringFieldEditor(nil)
            try await settle()
            editor.insertText("New tag", replacementRange: editor.selectedRange())
            try await settle()
            try check(model.refinements.finderTags?.last == "New tag", "The tags input lost its newline or new tag")
        }
        try await capture(scopeWindow, output.appendingPathComponent("scope-options.png"))
        print("PASS: preset save, kind tabs, new predicate controls, independent conversion opt-ins and main-window placement audited")
    }

    static func seedTika(_ manager: TikaManager) throws {
        for version in ["3.3.1", "3.3.2"] {
            let jar = manager.jarURL(version)
            try FileManager.default.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("UI fixture; never executed".utf8).write(to: jar)
            let installed = InstalledTika(version: version, sha512: String(repeating: "0", count: 128),
                source: TikaRelease(version: version, archived: false).downloadURL, installedAt: .now, bytes: 66_978_444)
            try JSONEncoder().encode(installed).write(to: jar.deletingLastPathComponent().appendingPathComponent("installed.json"))
        }
        struct Catalog: Encodable { let releases: [TikaRelease]; let checkedAt: Date }
        try JSONEncoder().encode(Catalog(releases: [.init(version: "3.3.2", archived: false), .init(version: "3.3.1", archived: true)], checkedAt: .now))
            .write(to: manager.directory.appendingPathComponent("releases.json"))
        try manager.select("3.3.2")
    }

    struct Element {
        let object: AnyObject
        var id: String? { object.accessibilityIdentifier?() }
        var label: String? { object.accessibilityLabel?() }
        var frame: NSRect { object.accessibilityFrame?() ?? .zero }
    }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func elements(_ view: NSView) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) -> [Element] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [Element(object: object)] + (object.accessibilityChildren?() ?? []).flatMap { visit($0 as AnyObject) }
        }
        return views(view).flatMap { visit($0) }
    }
    static func find(_ id: String, in view: NSView) -> Element? { elements(view).first { $0.id == id } }
    static func element(_ id: String, in view: NSView) throws -> Element { try required(find(id, in: view), id) }
    static func press(_ element: Element) throws {
        try check(element.object.accessibilityPerformPress?() == true, "Cannot press \(element.id ?? element.label ?? "control")")
    }
    static func click(_ element: Element, x: CGFloat, window: NSWindow) async throws {
        try check(!element.frame.isEmpty, "Control has an empty click target")
        try await click(window.convertPoint(fromScreen: NSPoint(x: element.frame.minX + x, y: element.frame.midY)), window: window)
    }
    static func click(_ point: NSPoint, window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: stamp + 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: stamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: true); NSApp.sendEvent(down)
        try await settle()
    }
    static func scroll(_ view: NSView, bottom: Bool) {
        for scroll in views(view).compactMap({ $0 as? NSScrollView }) {
            guard let document = scroll.documentView else { continue }
            let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom == document.isFlipped ? end : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    static func assertBlueSelection(_ table: NSTableView, row: Int) throws {
        let rect = table.rect(ofRow: row)
        let bitmap = try required(table.bitmapImageRepForCachingDisplay(in: rect), "Drive bitmap")
        table.cacheDisplay(in: rect, to: bitmap)
        func isBlue(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.blueComponent > 0.7 && color.redComponent < 0.3 && color.greenComponent < 0.7
        }
        let edges = [(2, 2), (bitmap.pixelsWide - 3, 2), (2, bitmap.pixelsHigh - 3), (bitmap.pixelsWide - 3, bitmap.pixelsHigh - 3)]
        try check(edges.allSatisfy { isBlue($0.0, $0.1) }, "The drive selection has gray edges around its blue highlight")
    }
    static func checkClipboard(_ copy: Element) throws {
        let board = NSPasteboard.general
        let old = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var change = -1
        defer {
            if board.changeCount == change {
                board.clearContents()
                board.writeObjects(old.map { values in
                    let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
                })
            }
        }
        try press(copy); change = board.changeCount
        try check(board.string(forType: .string) == "brew install fzf", "Copy includes the label or wrong command")
    }
    static func capture(_ window: NSWindow, _ path: URL) async throws {
        window.displayIfNeeded(); try await settle()
        window.orderFrontRegardless(); window.display(); try await settle()
        let content = try await SCShareableContent.currentProcess
        let target = try required(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }, "Audit window capture")
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor); config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        try required(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "Screenshot PNG").write(to: path)
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw SearchServiceError.commandFailed(message) } }
    static func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw SearchServiceError.commandFailed("Missing \(name)") }; return value
    }
}
