import SearchBackend
import SearchCore
import AppKit
import SwiftUI
import ScreenCaptureKit
#if FINDUI_AUDIT_IMPORT
@testable import FindUI
#endif

private actor FixtureAIClient: AISearchGenerating {
    enum Output: Sendable { case simple, mixed, allFiles, clarification, malformed }
    var delayed = false
    var output = Output.mixed
    func setDelayed(_ value: Bool) { delayed = value }
    func setOutput(_ value: Output) { output = value }
    func generate(messages: [AISearchMessage], schema: Data) async throws -> String {
        if delayed { try await Task.sleep(for: .seconds(20)) }
        if output == .malformed { return "{}" }
        let root = try JSONSerialization.jsonObject(with: schema) as! [String: Any]
        let properties = root["properties"] as! [String: Any]
        let options = properties["options"] as! [String: Any]
        let optionProperties = options["properties"] as! [String: Any]
        let optionValues = Dictionary(uniqueKeysWithValues: optionProperties.keys.map { ($0, NSNull()) })
        var object: [String: Any] = ["version": 1, "summary": "Swift TODOs or Markdown FIXMEs, excluding generated files.",
            "clarification": NSNull(), "contentUnit": "line", "options": optionValues,
            "rules": ["kind": "all", "children": [
                ["kind": "any", "children": [
                    ["kind": "all", "children": [["kind": "extensions", "values": ["swift"]], ["kind": "literal", "text": "TODO"]]],
                    ["kind": "all", "children": [["kind": "extensions", "values": ["md"]], ["kind": "literal", "text": "FIXME"]]]]],
                ["kind": "none", "children": [["kind": "name", "matching": "contains", "text": "generated"]]]]]]
        if output == .simple {
            object["summary"] = "Swift files"
            object["rules"] = ["kind": "name", "matching": "glob", "text": "*.swift"]
        } else if output == .allFiles {
            object["summary"] = "All files"
            object["rules"] = ["kind": "all", "children": []]
        } else if output == .clarification {
            object["summary"] = ""; object["rules"] = NSNull(); object["clarification"] = "Which filename should match?"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private actor FixtureModelCatalog {
    var count = 0
    func load(_ settings: AISearchSettings) -> [AISearchModelOption] {
        count += 1
        if settings.provider == .codex { return [.init(id: "gpt-6.1-sol", name: "GPT 6.1 Sol")] }
        return [.init(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash"),
                .init(id: "openai/gpt-6.1-sol", name: "GPT 6.1 Sol")]
    }
}

@main struct AISearchAuditApp: App {
    @NSApplicationDelegateAdaptor(AISearchAuditDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class AISearchAuditDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            do { try await AISearchAudit.run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor enum AISearchAudit {
    static func run() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-ai-audit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, body) in [("sample.swift", "TODO\n"), ("generated.swift", "TODO\n"), ("notes.md", "FIXME\n"), ("other.txt", "TODO\n")] {
            try Data(body.utf8).write(to: root.appendingPathComponent(name))
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let domain = "local.findui.ai-audit.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        try AISearchSettings().save(to: preferences) // An explicit disabled choice must remain disabled.
        defer { preferences.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root); previous?.activate(options: []) }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        var savedKeys: [String: String] = [:]
        let catalog = FixtureModelCatalog()
        let settings = AISearchSettingsModel(preferences: preferences, writeKey: { key, account in savedKeys[account] = key.isEmpty ? nil : key }, keyExists: { savedKeys[$0] != nil },
            checkLogin: { _ in .init(executable: "/fixture/codex", available: true, message: "ChatGPT login detected. Fixture transport.") },
            loadModels: { await catalog.load($0) })
        let library = SearchLibraryStore(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("library")))
        let search = SearchViewModel(loadSavedState: false, libraryStore: library)
        defer { search.stopSearch() }
        let settingsView = NSHostingView(rootView: SettingsView(viewModel: search, tikaManager: TikaManager(directory: root.appendingPathComponent("tika")), aiSettingsModel: settings).preferredColorScheme(.light))
        let window = show(settingsView, width: 860, height: 600, title: "FindUI AI Settings Audit")
        defer { window.orderOut(nil) }
        for _ in 0..<10 where !window.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true); try await settle(); window.makeKeyAndOrderFront(nil)
        }
        if !NSApp.isActive { print("LIMIT: macOS denied foreground activation; verifying in-process native actions, not desktop focus.") }
        try await settle()
        let tabs = try require(views(settingsView).compactMap { $0 as? NSSegmentedControl }.first, "Settings tabs")
        try check(tabs.segmentCount == 4, "Missing AI settings tab")
        tabs.selectedSegment = 3; tabs.sendAction(tabs.action, to: tabs.target); try await settle()
        try check(!settings.configuration.enabled, "An explicit disabled choice must remain disabled")
        try await capture(window, output.appendingPathComponent("ai-settings-disabled-light.png"))
        try press("enableAISearch", in: settingsView); try await settle()
        try check(AISearchSettings.load(from: preferences).enabled, "AI toggle did not persist")
        let providerMenu = try require(views(settingsView).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "AI provider" }, "Provider menu")
        try check(providerMenu.itemTitles == AISearchConnection.allCases.map(\.title), "The provider menu does not expose all six choices")
        let routerAccount = try settings.configuration.credentialAccount
        settings.apiKey = "fixture-key"; try await settle()
        try press("saveAISearchKey", in: settingsView); try await settle()
        try check(savedKeys[routerAccount] == "fixture-key" && settings.apiKey.isEmpty, "Key save did not use the isolated credential store")
        _ = try find("aiSearchKeySaved", in: settingsView)
        try check(settings.keyInputPrompt == "Replace saved key", "Saved key does not have a replacement placeholder")
        settings.apiKey = " \t\n "; try await settle()
        let emptyKeySave = try find("saveAISearchKey", in: settingsView)
        try check(emptyKeySave.object.isAccessibilityEnabled?() == false && savedKeys[routerAccount] == "fixture-key", "Whitespace-only input can overwrite a saved key")
        settings.apiKey = ""
        settings.apiKey = "discard-provider-draft"
        try await choose(.openAI, in: settingsView)
        try check(settings.configuration.model == "gpt-6.1-sol" && settings.apiKey.isEmpty && settings.hasSavedKey == false, "OpenAI preset or key isolation failed")
        let openAIAccount = try settings.configuration.credentialAccount
        settings.apiKey = "openai-fixture-key"; try await settle()
        try press("saveAISearchKey", in: settingsView); try await settle()
        try await choose(.anthropic, in: settingsView)
        try check(settings.configuration.provider == .anthropic && settings.configuration.model == "claude-sonnet-5-5" && settings.hasSavedKey == false, "Anthropic preset failed")
        let anthropicAccount = try settings.configuration.credentialAccount
        settings.apiKey = "anthropic-fixture-key"; try await settle()
        try press("saveAISearchKey", in: settingsView); try await settle()
        try await capture(window, output.appendingPathComponent("ai-settings-anthropic-light.png"))
        try await choose(.google, in: settingsView)
        try check(settings.configuration.model == "gemini-3.8-flash" && settings.hasSavedKey == false, "Google preset failed")
        try await choose(.openRouter, in: settingsView)
        try check(settings.hasSavedKey == true && savedKeys[routerAccount] == "fixture-key", "Returning to OpenRouter lost its saved key")
        _ = try find("aiSearchKeySaved", in: settingsView)
        try press("removeAISearchKey", in: settingsView); try await settle()
        try check(savedKeys[routerAccount] == nil && savedKeys[openAIAccount] == "openai-fixture-key" && savedKeys[anthropicAccount] == "anthropic-fixture-key", "Remove Key affected another provider")
        _ = try find("aiSearchKeyStatus", in: settingsView)
        try check(settings.keyStatusTitle == "No key saved", "Removing a key leaves a stale saved-key message")
        try press("aiSearchModel", in: settingsView); try await settle()
        let modelsWindow = try popover(containing: "aiModelSearch")
        let modelsView = try require(modelsWindow.contentView, "Model picker")
        try await enterText("flash", in: modelsView)
        _ = try find("aiModelChoice:google/gemini-3.8-flash", in: modelsView)
        try check(!elements(modelsView).contains { $0.id == "aiModelChoice:openai/gpt-6.1-sol" }, "Model search did not filter the catalog")
        try check(await catalog.count == 1, "Typing refetched the model catalog")
        try await capture(modelsWindow, output.appendingPathComponent("ai-model-picker-light.png"), includingParent: window)
        try await modelKey(#selector(NSResponder.insertNewline(_:)), in: modelsView)
        try check(settings.configuration.model == "google/gemini-3.8-flash", "Catalog selection did not save the model ID")
        try press("aiSearchModel", in: settingsView); try await settle()
        let keyboardModels = try require(popover(containing: "aiModelSearch").contentView, "Keyboard model picker")
        try await modelKey(#selector(NSResponder.moveDown(_:)), in: keyboardModels)
        try await modelKey(#selector(NSResponder.moveUp(_:)), in: keyboardModels)
        try await modelKey(#selector(NSResponder.moveDown(_:)), in: keyboardModels)
        try await modelKey(#selector(NSResponder.insertNewline(_:)), in: keyboardModels)
        try check(settings.configuration.model == "openai/gpt-6.1-sol", "Arrow keys and Return did not select a model")
        try press("aiSearchModel", in: settingsView); try await settle()
        let escapeModels = try require(popover(containing: "aiModelSearch").contentView, "Escape model picker")
        try await modelKey(#selector(NSResponder.cancelOperation(_:)), in: escapeModels)
        try check(settings.configuration.model == "openai/gpt-6.1-sol", "Escape changed the selected model")
        try check(await catalog.count == 1, "Reopening refetched a loaded catalog")
        try press("aiSearchModel", in: settingsView); try await settle()
        let manualModels = try require(popover(containing: "aiModelSearch").contentView, "Custom model picker")
        try await enterText("provider/private-model", in: manualModels)
        try press("refreshAIModels", in: manualModels); try await settle()
        try check(await catalog.count == 2, "Explicit Refresh did not reload the model catalog")
        try await modelKey(#selector(NSResponder.insertNewline(_:)), in: manualModels)
        try check(settings.configuration.model == "provider/private-model", "Custom model IDs are not preserved")
        settings.configuration.model = "google/gemini-3.8-flash"
        settings.apiKey = "fresh-router-key"; try await settle()
        try press("saveAISearchKey", in: settingsView); try await settle()
        try check(await catalog.count == 3, "Saving a key did not refresh the loaded model catalog")
        try press("removeAISearchKey", in: settingsView); try await settle()
        try check(await catalog.count == 4, "Removing a key did not refresh the loaded model catalog")
        for id in ["aiSearchProvider", "aiSearchModel", "aiSearchKey", "saveAISearchKey", "removeAISearchKey"] {
            let element = try find(id, in: settingsView)
            try check(element.frame.width > 20 && element.frame.minX >= window.frame.minX && element.frame.maxX <= window.frame.maxX - 10, "AI control is clipped: \(id)")
        }
        try check(!elements(settingsView).contains { $0.id == "aiSearchURL" }, "A known provider unnecessarily exposes an editable URL")
        try await capture(window, output.appendingPathComponent("ai-settings-api-light.png"))
        try await choose(.custom, in: settingsView)
        _ = try find("aiSearchURL", in: settingsView)
        _ = try find("aiSearchFormat", in: settingsView)
        let format = try require(views(settingsView).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "API format" }, "Custom API format")
        try check(format.itemTitles == [AISearchProvider.compatible.title, AISearchProvider.anthropic.title], "Missing custom API protocol choices")
        format.selectItem(withTitle: AISearchProvider.anthropic.title); format.sendAction(format.action, to: format.target); try await settle()
        try check(settings.configuration.connection == .custom && settings.configuration.provider == .anthropic, "Changing the custom protocol selected a built-in provider")
        settings.configuration.baseURL = "https://gateway.example/v1"; try await settle()
        settings.apiKey = "custom-fixture-key"; try await settle()
        try press("saveAISearchKey", in: settingsView); try await settle()
        let customAccount = try settings.configuration.credentialAccount
        try check(savedKeys[customAccount] == "custom-fixture-key" && savedKeys[anthropicAccount] == "anthropic-fixture-key", "Custom URL did not get a separate key")
        try await capture(window, output.appendingPathComponent("ai-settings-custom-light.png"))
        try await choose(.codex, in: settingsView)
        try press("checkAICodex", in: settingsView); try await settle()
        try check(settings.codexStatus?.available == true, "Codex detection did not update")
        try await capture(window, output.appendingPathComponent("ai-settings-codex-light.png"))
        settingsView.rootView = SettingsView(viewModel: search, tikaManager: TikaManager(directory: root.appendingPathComponent("tika")), aiSettingsModel: settings).preferredColorScheme(.dark)
        try await settle()
        try await capture(window, output.appendingPathComponent("ai-settings-codex-dark.png"))

        settings.selectConnection(.openRouter)
        var state = search.searchState; state.scopePath = root.path; state.useIndex = false
        search.restoreSearchState(state)
        let client = FixtureAIClient()
        await client.setOutput(.simple)
        let main = NSHostingView(rootView: ContentView(viewModel: search, aiPreferences: preferences, aiSettingsModel: settings, aiClient: client).preferredColorScheme(.light))
        let mainWindow = show(main, width: 1000, height: 680, title: "FindUI AI Enabled Audit")
        defer { mainWindow.orderOut(nil) }
        try await settle()
        try await capture(mainWindow, output.appendingPathComponent("ai-main-simple-light.png"))
        let titlebar = try require(main.superview, "Main window frame")
        for id in ["openAISearch", "expandSearchRules"] {
            let button = try find(id, in: titlebar)
            try check(button.frame.width >= 20
                && button.frame.minX >= mainWindow.frame.minX && button.frame.maxX <= mainWindow.frame.maxX - 8, "Main AI controls are clipped: \(id)")
        }
        let aiButton = try find("openAISearch", in: titlebar), historyButton = try find("toggleHistorySidebar", in: titlebar), inspectorButton = try find("toggleInspectorSidebar", in: titlebar)
        let examplesButton = try require(elements(main).first { $0.object.accessibilityLabel?() == "Search syntax and examples" }, "Search examples button")
        let scopeButton = try find("searchScopeOptions", in: main)
        try check(examplesButton.frame.maxX < scopeButton.frame.minX, "Examples is not before Scope & Options")
        try check(abs(aiButton.frame.midY - historyButton.frame.midY) < 3 && abs(aiButton.frame.midY - inspectorButton.frame.midY) < 3,
                  "AI is not beside the sidebar controls")
        try check(aiButton.frame.maxX < historyButton.frame.minX && historyButton.frame.midX < inspectorButton.frame.midX,
                  "The sparkle button is not separate from the paired sidebar controls")
        main.rootView = ContentView(viewModel: search, aiPreferences: preferences, aiSettingsModel: settings, aiClient: client).preferredColorScheme(.dark)
        try await settle(); try await capture(mainWindow, output.appendingPathComponent("ai-main-simple-dark.png"))
        try press("openAISearch", in: titlebar); try await settle()
        let actualSheet = try require(mainWindow.sheets.first?.contentView, "AI sheet opened from the main controls")
        try await waitFor("aiSearchDescription", in: actualSheet)
        try check(text(try find("aiSearchProviderModel", in: actualSheet)) == "OpenRouter: google/gemini-3.8-flash", "AI header omits the provider or selected model")
        try await enterDescription("Swift files", in: actualSheet)
        try await capture(try require(actualSheet.window, "AI entry window"), output.appendingPathComponent("ai-search-entry-dark.png"))
        try press("generateAISearch", in: actualSheet)
        try await waitForDismissal(mainWindow)
        try check(search.searchRules == nil && search.filenameInput == "*.swift", "A simple generated search did not use simple controls")
        try await waitFor("expandSearchRules", in: main)
        try await waitForResults(["sample.swift", "generated.swift"], search: search)
        try await capture(mainWindow, output.appendingPathComponent("ai-applied-simple-dark.png"))
        settings.configuration.enabled = false
        try press("openAISearch", in: titlebar); try await settle()
        let setupWindow = try require(mainWindow.sheets.first, "Disabled AI setup sheet")
        let setup = try require(setupWindow.contentView, "AI setup")
        try await waitFor("enableAISearch", in: setup)
        try check(!settings.configuration.enabled, "Opening AI changed an explicit disabled choice")
        try await capture(setupWindow, output.appendingPathComponent("ai-direct-setup-dark.png"))
        try press("enableAISearch", in: setup); try await settle()
        try press("continueAISearch", in: setup); try await settle()
        try await waitFor("aiSearchDescription", in: setup)
        try press("cancelAISearch", in: setup); try await settle()
        preferences.removeObject(forKey: AISearchSettings.preferencesKey)
        try press("openAISearch", in: titlebar); try await settle()
        let detected = try require(mainWindow.sheets.first?.contentView, "Automatically configured AI search")
        try await waitFor("aiSearchDescription", in: detected)
        try check(settings.configuration.provider == .codex && settings.configuration.enabled, "Existing login did not configure a new install")
        try check(preferences.data(forKey: AISearchSettings.preferencesKey) == nil, "Login detection persisted a setting without an edit")
        try check(text(try find("aiSearchProviderModel", in: detected)) == "ChatGPT via Codex: gpt-6.1-sol", "Codex model is not displayed")
        try await capture(try require(detected.window, "Detected AI entry window"), output.appendingPathComponent("ai-autodetected-entry-dark.png"))
        try press("cancelAISearch", in: detected); try await settle()
        settings.configuration.codexModel = ""
        try press("openAISearch", in: titlebar); try await settle()
        let codexDefault = try require(mainWindow.sheets.first?.contentView, "Codex default model entry")
        try await waitFor("aiSearchDescription", in: codexDefault)
        try check(text(try find("aiSearchProviderModel", in: codexDefault)) == "ChatGPT via Codex: Codex default", "Codex default is not identified")
        try press("cancelAISearch", in: codexDefault); try await settle()
        settings.configuration.codexModel = "gpt-6.1-sol"
        await client.setOutput(.mixed)
        try press("openAISearch", in: titlebar); try await settle()
        let mixed = try require(mainWindow.sheets.first?.contentView, "Mixed AI search entry")
        try await waitFor("aiSearchDescription", in: mixed)
        try await enterDescription("Swift TODOs or Markdown FIXMEs, excluding generated files", in: mixed)
        try press("generateAISearch", in: mixed)
        try await waitForDismissal(mainWindow)
        try check(search.searchRules?.expression.leaves.count == 5, "Mixed search lost its nested rules")
        try await waitFor("useSimpleSearchControls", in: main)
        try await waitForResults(["sample.swift", "notes.md"], search: search)
        try await capture(mainWindow, output.appendingPathComponent("ai-applied-mixed-dark.png"))
        main.rootView = ContentView(viewModel: search, aiPreferences: preferences, aiSettingsModel: settings, aiClient: client).preferredColorScheme(.light)
        try await settle(); try await capture(mainWindow, output.appendingPathComponent("ai-applied-mixed-light.png"))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested fixture\n".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        try Data("newline fixture\n".utf8).write(to: nested.appendingPathComponent("line\nbreak.txt"))
        await client.setOutput(.allFiles)
        try press("openAISearch", in: titlebar); try await settle()
        let allFiles = try require(mainWindow.sheets.first?.contentView, "All-files entry")
        try await waitFor("aiSearchDescription", in: allFiles)
        try await enterDescription("Find all files recursively", in: allFiles)
        try press("generateAISearch", in: allFiles)
        try await waitForDismissal(mainWindow)
        try check(search.searchRules == nil && search.filenameInput == "*" && search.contentsInput.isEmpty, "Match-all generation became empty browsing or retained content filters")
        try await waitForResults(["sample.swift", "generated.swift", "notes.md", "other.txt", "deep.txt", "line\nbreak.txt"], search: search, allowingAdditional: true)
        try await capture(mainWindow, output.appendingPathComponent("ai-applied-all-files-light.png"))
        let beforeClarification = search.searchState
        await client.setOutput(.clarification)
        try press("openAISearch", in: titlebar); try await settle()
        let clarification = try require(mainWindow.sheets.first?.contentView, "Clarification entry")
        try await waitFor("aiSearchDescription", in: clarification)
        try await enterDescription("Some files", in: clarification)
        try press("generateAISearch", in: clarification)
        try await waitFor("aiSearchClarification", in: clarification)
        try check(!mainWindow.sheets.isEmpty && search.searchState == beforeClarification, "Clarification changed the search or closed the sheet")
        try await capture(try require(clarification.window, "Clarification window"), output.appendingPathComponent("ai-clarification-light.png"))
        await client.setOutput(.malformed)
        try await enterDescription("Retry", in: clarification)
        try press("generateAISearch", in: clarification)
        try await waitFor("aiSearchError", in: clarification)
        try check(!mainWindow.sheets.isEmpty && search.searchState == beforeClarification, "Failed repair changed the search or closed the sheet")
        try await capture(try require(clarification.window, "Error window"), output.appendingPathComponent("ai-error-light.png"))
        await client.setDelayed(true)
        await client.setOutput(.simple)
        try await enterDescription("Another request", in: clarification)
        try press("generateAISearch", in: clarification)
        try await waitFor("stopAISearch", in: clarification)
        try press("stopAISearch", in: clarification)
        try await waitFor("generateAISearch", in: clarification)
        try check(search.searchState == beforeClarification, "Stop changed the current search")
        try press("generateAISearch", in: clarification)
        try await waitFor("stopAISearch", in: clarification)
        settings.configuration.codexModel = "fixture-other-model"
        try await waitFor("generateAISearch", in: clarification)
        try check(search.searchState == beforeClarification, "A settings change allowed a pending search to apply")
        try press("generateAISearch", in: clarification)
        try await waitFor("stopAISearch", in: clarification)
        try press("cancelAISearch", in: clarification)
        try await waitForDismissal(mainWindow)
        try check(search.searchState == beforeClarification, "Cancel changed the current search")
        await library.shutdown()
        print("PASS: AI settings at 860 points, clear saved-key state, whitespace-save rejection, separate sparkle, six providers and per-URL keys, model picker, provider/model header, direct setup and automatic login, immediate application and auto-close, simple controls versus mixed Rules and recursive match-all, actual results, clarification/error preservation, settings invalidation, Stop and Cancel.")
    }
    static func show(_ view: NSView, width: CGFloat, height: CGFloat, title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title; window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        return window
    }
    static func popover(containing id: String) throws -> NSWindow {
        try require(NSApp.windows.first { window in window.isVisible && (window.contentView.map { elements($0).contains { $0.id == id } } ?? false) }, "Popover: " + id)
    }
    static func choose(_ connection: AISearchConnection, in view: NSView) async throws {
        let menu = try require(views(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "AI provider" }, "Provider menu")
        menu.selectItem(withTitle: connection.title); menu.sendAction(menu.action, to: menu.target)
        try await settle()
        try check(menu.titleOfSelectedItem == connection.title, "Provider menu did not select \(connection.title)")
    }
    static func text(_ element: Element) -> String {
        let selector = NSSelectorFromString("accessibilityValue")
        if let object = element.object as? NSObject, object.responds(to: selector),
           let value = object.perform(selector)?.takeUnretainedValue() as? String { return value }
        return element.object.accessibilityLabel?() ?? ""
    }
    static func enterDescription(_ value: String, in view: NSView) async throws {
        let editor = try require(views(view).compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor }, "Search description editor")
        view.window?.makeKeyAndOrderFront(nil); view.window?.makeFirstResponder(editor)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle()
    }
    static func waitForDismissal(_ window: NSWindow) async throws {
        for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        try check(window.sheets.isEmpty, "Successful generation did not close the sheet automatically")
        try await settle()
    }
    static func waitForResults(_ names: Set<String>, search: SearchViewModel, allowingAdditional: Bool = false) async throws {
        for _ in 0..<200 {
            let actual = Set(search.results.map(\.name))
            if !search.isSearching, allowingAdditional ? actual.isSuperset(of: names) : actual == names { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(false, "Generated search did not run or returned the wrong files: \(search.results.map(\.name))")
    }
    static func enterText(_ value: String, in view: NSView) async throws {
        let field = try require(views(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search models or enter an ID" }, "Model search field")
        let editor = try await editor(for: field)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)); try await settle()
    }
    static func modelKey(_ selector: Selector, in view: NSView) async throws {
        let field = try require(views(view).compactMap { $0 as? NSSearchField }.first, "Model search control")
        let editor = try await editor(for: field)
        editor.doCommand(by: selector); try await settle()
    }
    static func editor(for field: NSTextField) async throws -> NSTextView {
        for _ in 0..<20 {
            if let editor = field.currentEditor() as? NSTextView { return editor }
            NSApp.activate(ignoringOtherApps: true)
            field.window?.makeKeyAndOrderFront(nil); field.window?.makeFirstResponder(field); field.selectText(nil)
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "FindUIAIAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model editor did not focus; active=\(NSApp.isActive), windowKey=\(field.window?.isKeyWindow ?? false), visible=\(field.window?.isVisible ?? false)"])
    }
    struct Element {
        let object: AnyObject
        var id: String? { object.accessibilityIdentifier?() }
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
    static func find(_ id: String, in view: NSView) throws -> Element { try require(elements(view).first { $0.id == id }, id) }
    static func waitFor(_ id: String, in view: NSView) async throws {
        for _ in 0..<30 {
            if elements(view).contains(where: { $0.id == id }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Missing \(id); visible IDs: \(elements(view).compactMap(\.id))")
        if let window = view.window {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try await capture(window, output.appendingPathComponent("ai-unexpected-sheet.png"))
        }
        throw NSError(domain: "FindUIAIAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: id])
    }
    static func press(_ id: String, in view: NSView) throws {
        let matches = elements(view).filter { $0.id == id }
        guard !matches.isEmpty else { throw NSError(domain: "FindUIAIAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(id)"]) }
        for match in matches { print("AX \(id): \(type(of: match.object)) \(match.object.accessibilityRole?()?.rawValue ?? "none") \(match.frame)") }
        fflush(nil)
        if id == "enableAISearch", let control = matches.compactMap({ $0.object as? NSSwitch }).first {
            print("NSSwitch action: \(control.action.map(String.init(describing:)) ?? "none") enabled=\(control.isEnabled) state=\(control.state.rawValue)")
            control.state = control.state == .on ? .off : .on
            control.sendAction(control.action, to: control.target); return
        }
        for match in matches { if match.object.accessibilityPerformPress?() == true { return } }
        // Form switches can expose their identifier on a containing AX group.
        // Dispatch native control events at the right-hand switch in that case.
        let match = matches.first!, window = try require(view.window, "Control window")
        try check(!match.frame.isEmpty, "Empty control frame: \(id)")
        let screenPoint = NSPoint(x: id == "enableAISearch" ? match.frame.maxX - 12 : match.frame.midX, y: match.frame.midY)
        let point = window.convertPoint(fromScreen: screenPoint)
        window.makeKeyAndOrderFront(nil)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: true); NSApp.sendEvent(down)
    }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "FindUIAIAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
    static func require<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw NSError(domain: "FindUIAIAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; return value }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(160)) }
    static func capture(_ window: NSWindow, _ path: URL, includingParent parent: NSWindow? = nil) async throws {
        for _ in 0..<4 where !window.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
        }
        // ScreenCaptureKit composites a sheet with its parent; size that capture
        // from the parent rather than shrinking it into the sheet's rectangle.
        let captureWindow = parent ?? window.sheetParent ?? window
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let target = try require(content.windows.first { $0.windowID == CGWindowID(captureWindow.windowNumber) }, "Audit capture window")
        let config = SCStreamConfiguration(); config.width = Int(captureWindow.frame.width * 2); config.height = Int(captureWindow.frame.height * 2); config.showsCursor = false
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        try require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "PNG").write(to: path)
    }
}
