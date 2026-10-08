import SearchBackend
import AppKit
import SwiftUI
import ScreenCaptureKit

@main struct FOSSAuditApp: App {
    @NSApplicationDelegateAdaptor(FOSSAuditDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class FOSSAuditDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            do { try await FOSSAudit.run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@MainActor enum FOSSAudit {
    static func check(_ value: Bool,_ message: String) throws { if !value { throw SearchServiceError.commandFailed(message) } }
    static func wait(_ message:String,until predicate:() -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for:.milliseconds(25)) }
        throw SearchServiceError.commandFailed(message)
    }
    static func views(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func elements(_ view:NSView) -> [AnyObject] {
        var seen=Set<ObjectIdentifier>()
        func visit(_ item:AnyObject) -> [AnyObject] {
            guard seen.insert(ObjectIdentifier(item)).inserted else { return [] }
            return [item] + (item.accessibilityChildren?() ?? []).flatMap { visit($0 as AnyObject) }
        }
        return views(view).flatMap { visit($0) }
    }
    static func run() async throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("findui-foss-ui-\(UUID())")
        let previous=NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options:[]); try? FileManager.default.removeItem(at:root) }
        let files=root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        setenv("FINDUI_CACHE_DIRECTORY",root.appendingPathComponent("cache").path,1)
        try Data((1...1200).map { "needle line \($0)\n" }.joined().utf8).write(to:files.appendingPathComponent("long.txt"))
        try Data("needle nearby\n".utf8).write(to:files.appendingPathComponent("short.md"))
        NSApp.accessibilitySetValue(true,forAttribute:.init(rawValue:"AXManualAccessibility"))
        NSApp.accessibilitySetValue(true,forAttribute:.init(rawValue:"AXEnhancedUserInterface"))
        let model=SearchViewModel(persistence:AppPersistence(baseDirectory:root.appendingPathComponent("settings")),loadSavedState:false)
        model.scopeURL=files; model.mode = .contents; model.contentsInput="needle"; model.contentMatchingChoice = .indexedWords
        model.isInspectorPresented=true
        defer { model.stopSearch() }
        let view=NSHostingView(rootView:ContentView(viewModel:model).preferredColorScheme(.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.contentView=view; window.title="FindUI · Search audit"; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { window.orderOut(nil) }
        try await Task.sleep(for:.milliseconds(300))
        print("Word mode: \(model.refinements.wordSearch as Any); controls: \(elements(view).compactMap { element -> String? in guard let id=element.accessibilityIdentifier?(), id.contains("Word") || id.contains("word") else { return nil }; return "\(id) \(element.accessibilityRole?() as Any) \(element.accessibilityLabel?() as Any)" })")
        let update = elements(view).first { $0.accessibilityIdentifier?() == "updateActiveWordIndex" }
        try check(update?.accessibilityPerformPress?() == true,"Active word-index Update button cannot be pressed")
        try await wait("Word preparation/search did not finish: \(model.statusMessage)") { !model.preparingContents && !model.isSearching && model.results.count == 2 && model.wordIndexStatus?.state == "updated" }
        try await capture(window,to:output.appendingPathComponent("word-status.png"))
        print("PASS: active-scope Update prepares words, searches, and reports current coverage")
        let field=try require(views(view).compactMap { $0 as? NSSearchField }.first { $0.accessibilityIdentifier() == "searchInput" },"Contents input")
        window.makeFirstResponder(field)
        let editor=try require(field.currentEditor() as? NSTextView,"Contents editor")
        editor.insertText("ne",replacementRange:NSRange(location:0,length:editor.string.utf16.count))
        try await wait("Native word suggestion did not appear") { field.searchMenuTemplate?.items.contains { $0.title == "needle" } == true }
        let menu=try require(field.searchMenuTemplate,"Suggestions menu")
        let index=try require(menu.items.firstIndex { $0.title == "needle" },"needle suggestion")
        menu.performActionForItem(at:index)
        try await wait("Accepting a word did not update the shared query") { model.contentsInput == "needle" && !model.isSearching && model.results.count == 2 }
        print("PASS: native suggestion menu accepts an indexed word and updates the shared search")
        let facets=await model.resultFacets()
        try check(facets.contains { $0.kind == .fileType && $0.value == "txt" && $0.count == 1 },"Facets counted matching lines as files")
        let options=NSHostingView(rootView:SearchOptionsView(viewModel:model))
        let optionsWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:570,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        optionsWindow.contentView=options; optionsWindow.title="Scope & Options"; optionsWindow.center(); optionsWindow.makeKeyAndOrderFront(nil)
        try await wait("Result facets menu is missing from Options") { elements(options).contains { $0.accessibilityIdentifier?() == "resultFacets" } }
        try await capture(optionsWindow,to:output.appendingPathComponent("result-facets.png")); optionsWindow.orderOut(nil)
        model.applyFacet(try require(facets.first { $0.kind == .fileType && $0.value == "txt" },"TXT facet"))
        try await wait("Applying a facet lost the content query or did not narrow files") { !model.isSearching && model.results.count == 1 && model.results.first?.name == "long.txt" }
        try check(model.contentsInput == "needle" && model.refinements.wordSearch == true,"Facet replaced word matching")
        print("PASS: Options offers result facets; applying one retains the query and uses existing file conditions")
        model.contentMatchingChoice = .literal
        model.scheduleSearch(immediate:true)
        try await wait("Live search did not retain all 1200 matches: \(model.statusMessage)") { !model.isSearching && model.totalResultCount == 1200 }
        model.sortResults([KeyPathComparator(\SearchResult.name)])
        try await wait("First page did not render") { model.results.count == 1000 }
        let last=try require(model.results.first { $0.lineNumber == 1000 },"Last match on page one")
        model.selectResult(last)
        try await wait("Document-wide match position is missing") { model.contentMatchPosition == 999 }
        try check(model.contentMatchCount == 1200,"Inspector count is page-local")
        window.makeKeyAndOrderFront(nil)
        try await capture(window,to:output.appendingPathComponent("matches-page-one.png"))
        let next=try require(elements(view).first { $0.accessibilityLabel?() == "Next match in this file" },"Next match control")
        try check(next.accessibilityPerformPress?() == true,"Next match control cannot be pressed")
        try await wait("Next match did not cross the page boundary") { model.resultPage == 1 && model.selectedResult?.lineNumber == 1001 && model.contentMatchPosition == 1000 }
        try check(model.contentMatchCount == 1200 && model.results.count == 200,"Second page lost total count or lazy paging")
        try await capture(window,to:output.appendingPathComponent("matches-page-two.png"))
        print("PASS: 1200 total matches, lazy pages, full document counts, and native cross-page Next match")

        try Data(("needle " + String(repeating: "long text 🙂 ", count: 4_000) + " needle\n").utf8).write(to: files.appendingPathComponent("long.txt"))
        model.scheduleSearch(immediate: true)
        try await wait("Long-line search did not finish") { !model.isSearching && model.totalResultCount == 1 }
        model.selectResult(try require(model.results.first, "Long-line match"))
        try await wait("Long-line highlight navigation is missing") { elements(view).contains { $0.accessibilityLabel?() == "Next highlight" } }
        let nextHighlight = try require(elements(view).first { $0.accessibilityLabel?() == "Next highlight" }, "Next highlight")
        try check(nextHighlight.accessibilityPerformPress?() == true, "Next highlight cannot be pressed")
        try await wait("Highlight navigation did not update") { elements(view).contains { element in
            if element.accessibilityLabel?() == "Highlight 2 of 2" { return true }
            let selector = NSSelectorFromString("accessibilityValue")
            guard let object = element as? NSObject, object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == "Highlight 2 of 2"
        } }
        try await capture(window, to: output.appendingPathComponent("bounded-long-line.png"))

        try Data("before\nalpha café\nbeta 🙂\nafter\n".utf8).write(to: files.appendingPathComponent("long.txt"))
        model.contentMatchingChoice = .regex
        model.refinements.multiline = true
        model.contentsInput = #"alpha[^\n]*\nbeta"#
        model.scheduleSearch(immediate: true)
        try await wait("Multiline search did not finish") { !model.isSearching && model.totalResultCount == 1 && model.results.first?.snippet?.contains("\n") == true }
        model.selectResult(try require(model.results.first, "Multiline match"))
        try await capture(window, to: output.appendingPathComponent("multiline-preview.png"))
        print("PASS: bounded long-line previews navigate between highlights; multiline regex results render with context")
    }
    static func require<T>(_ value:T?,_ name:String) throws -> T {
        guard let value else { throw SearchServiceError.commandFailed("Missing \(name)") }; return value
    }
    static func capture(_ window:NSWindow,to url:URL) async throws {
        window.displayIfNeeded(); try await Task.sleep(for:.milliseconds(120))
        let content=try await SCShareableContent.currentProcess
        let shared=try require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) },"own window capture")
        let config=SCStreamConfiguration(); config.width=Int(window.frame.width*2); config.height=Int(window.frame.height*2); config.showsCursor=false
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:shared),configuration:config)
        let data=try require(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"PNG")
        try data.write(to:url)
    }
}
