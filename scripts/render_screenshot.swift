import SearchBackend
import AppKit
import SwiftUI
import ScreenCaptureKit
import QuickLookUI

@MainActor
private final class ResultNavigationTrace {
    var movements: [String] = []
    var previewAssignments = 0
}

@main
struct ScreenshotAuditApp: App {
    @NSApplicationDelegateAdaptor(ScreenshotAuditDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class ScreenshotAuditDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenshotRenderer.run()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Use the same application lifecycle as FindUI so native focus/activation is
/// available, with disposable sample files instead of the user's saved state.
@MainActor
struct ScreenshotRenderer {
    static func run() {
        let application = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let layoutOnly = CommandLine.arguments.contains("--layout-only")
        application.setActivationPolicy(layoutOnly ? .accessory : .regular)
        // SwiftUI creates its accessibility nodes lazily. Enable them only in
        // this disposable audit process, without changing system preferences.
        application.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        application.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: Native UI audit exceeded its 240-second deadline.\n".utf8)); exit(2)
        }
        Task {
            defer { previousApplication?.activate(options: []) }
            do {
                let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".cache/verification/screenshot.png")
                let temporary = URL(fileURLWithPath: "/tmp").appendingPathComponent("FindUI-Demo-\(UUID().uuidString.prefix(8))")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let project = temporary.appendingPathComponent("Example Project")
                let samples = [
                    ("Sources/RequestClient.swift", 42, "let retryPolicy = RetryPolicy(timeout: 30, attempts: 3)"),
                    ("Sources/SyncJob.swift", 18, "// Retry this operation when a network timeout occurs."),
                    ("Tests/RequestClientTests.swift", 27, "func testRetryAfterTimeout() async throws {"),
                    ("Notes/networking.md", 8, "A timeout triggers retry with exponential backoff."),
                ]
                for (path, line, content) in samples {
                    let file = project.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let before = String(repeating: "\n", count: max(0, line - 4))
                        + "// Request configuration\nlet options = RequestOptions()\n// Apply the policy below.\n"
                    let after = "\nreturn try await client.send(options)\n// End of operation.\n"
                        + (path == "Sources/RequestClient.swift" ? "logger.debug(\"Retry after timeout\")\n" : "")
                    try Data((before + content + after).utf8).write(to: file)
                }
                // Match normal app tool discovery. A synthetic rg path used to
                // trigger a tool refresh/search cancellation when macOS finally
                // granted activation, making this fixture timing-dependent.
                let tools = Toolchain.resolve()
                let library = SearchLibraryStore(persistence: AppPersistence(baseDirectory: temporary.appendingPathComponent("Settings")))
                let model = SearchViewModel(service: SearchService(tools: tools),
                                            loadSavedState: false, libraryStore: library)
                model.scopeURL = project
                model.mode = .contents
                model.contentsInput = "retry timeout"
                model.isInspectorPresented = true
                if CommandLine.arguments.contains("--sidebar-preview-only") {
                    library.value.history = (0..<150).map { index in
                        var snapshot = model.searchState
                        snapshot.query = "Saved query \(index)"
                        return SearchHistoryEntry(id: UUID(), snapshot: snapshot, searchedAt: Date().addingTimeInterval(Double(-index)),
                            resultCount: index + 1, engineName: "rg", isPinned: index < 8, pinOrder: index < 8 ? index : nil)
                    }
                }
                let view = NSHostingView(rootView: ContentView(viewModel: model).preferredColorScheme(.light))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1320, height: 820),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "FindUI"
                window.toolbar = NSToolbar(identifier: "FindUIAudit")
                window.toolbarStyle = .unified
                window.contentView = view
                if !layoutOnly { window.center() }
                window.orderFront(nil)
                application.activate(ignoringOtherApps: true)
                window.makeKey()
                window.display()
                model.scheduleSearch(immediate: true)
                try await Task.sleep(for: .milliseconds(700))
                for _ in 0..<100 where model.isSearching || model.results.isEmpty {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard model.results.count == samples.count + 1 else {
                    throw SearchServiceError.commandFailed("Screenshot search failed: \(model.statusMessage)")
                }
                guard var table = resultsOutline(in: view), table.numberOfRows == samples.count + 1 else {
                    throw SearchServiceError.commandFailed("Grouped table did not render the expected result rows.")
                }
                if CommandLine.arguments.contains("--sidebar-preview-only") {
                    try await auditSidebarInteractions(view: view, window: window, model: model, output: output)
                    print("Native grouping, multi-selection, row-click focus: sidebar/preview audit complete.")
                    exit(0)
                }
                guard table.rect(ofRow: 0).minY == 0 else {
                    throw SearchServiceError.commandFailed("Results retain padding before the first row: \(table.rect(ofRow: 0)).")
                }
                print("First result starts at y=0, immediately below the native column header.")
                if !layoutOnly {
                    window.makeFirstResponder(table)
                    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    try await Task.sleep(for: .milliseconds(150))
                    let trace = ResultNavigationTrace()
                    let firstRow = table.rect(ofRow: 0)
                    let visibleRect = table.visibleRect
                    let tableFrame = table.frame
                    let styleObservation = table.observe(\.style) { table, _ in
                        MainActor.assumeIsolated {
                            if table.rect(ofRow: 0) != firstRow {
                                trace.movements.append("Style update moved first row: \(firstRow) -> \(table.rect(ofRow: 0))")
                            }
                        }
                    }
                    defer { styleObservation.invalidate() }
                    var expectedRow = 0
                    for key in [UInt16(125), 125, 125, 126, 126, 126] {
                        let character = key == 125 ? "\u{F701}" : "\u{F700}"
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: key)!
                        application.sendEvent(event)
                        expectedRow += key == 125 ? 1 : -1
                        for _ in 0..<8 {
                            try await Task.sleep(for: .milliseconds(16))
                            guard table.selectedRow == expectedRow,
                                  table.rect(ofRow: 0) == firstRow,
                                  table.visibleRect == visibleRect, table.frame == tableFrame else {
                                throw SearchServiceError.commandFailed("Arrow navigation moved visible rows or changed table geometry: selected=\(table.selectedRow), expected=\(expectedRow), row=\(table.rect(ofRow: 0)), viewport=\(table.visibleRect), frame=\(table.frame).")
                            }
                        }
                    }
                    styleObservation.invalidate()
                    guard trace.movements.isEmpty else {
                        throw SearchServiceError.commandFailed(trace.movements.joined(separator: "\n"))
                    }
                    print("Arrow navigation: six real Up/Down events, 48 stable frames, no transient row inset/width changes.")
                }
                if CommandLine.arguments.contains("--navigation-only") {
                    print("Native grouping, multi-selection, row-click focus: navigation diagnostic complete.")
                    application.terminate(nil)
                    return
                }
                // Exercise native disclosure and selection, not just a static snapshot.
                if let row = (0..<table.numberOfRows).first(where: { table.isExpandable(table.item(atRow: $0)) }),
                   let item = table.item(atRow: row) {
                    table.collapseItem(item)
                    try await Task.sleep(for: .milliseconds(150))
                    guard table.numberOfRows == samples.count else {
                        throw SearchServiceError.commandFailed("Collapsing a file did not hide its other matches.")
                    }
                    table.expandItem(item)
                    try await Task.sleep(for: .milliseconds(150))
                } else {
                    throw SearchServiceError.commandFailed("No collapsible file group was found.")
                }
                table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(150))
                guard model.selectedResultIDs.count == 2 else {
                    throw SearchServiceError.commandFailed("Native multi-selection did not reach the view model.")
                }
                if let first = model.results.first(where: { $0.name == "RequestClient.swift" && $0.lineNumber == 42 }) {
                    model.selectResult(first)
                    model.moveContentMatch(by: 1)
                    guard model.selectedResult?.lineNumber == 45 else {
                        throw SearchServiceError.commandFailed("Next-match navigation selected the wrong line.")
                    }
                    model.moveContentMatch(by: -1)
                }
                try await Task.sleep(for: .milliseconds(400))
                if layoutOnly {
                    print("Layout-only audit: keyboard/focus checks skipped while the user is active.")
                } else if let field = searchField(in: view) {
                    var reportedFocus = false
                    if let reportingField = field as? FocusReportingSearchField {
                        let report = reportingField.onFocusChange
                        reportingField.onFocusChange = { value in reportedFocus = value; report?(value) }
                    }
                    window.makeFirstResponder(table)
                    try await Task.sleep(for: .milliseconds(100))
                    await click(NSPoint(x: 90, y: field.bounds.midY), in: field, window: window)
                    try await Task.sleep(for: .milliseconds(150))
                    guard field.currentEditor() != nil, reportedFocus else {
                        throw SearchServiceError.commandFailed("Clicking search without typing did not activate its focus outline.")
                    }
                    let focusedOutput = output.deletingLastPathComponent().appendingPathComponent("ui-search-focused.png")
                    try await capture(window.contentView?.superview ?? view, to: focusedOutput)
                    // SwiftUI may replace the outline during layout or capture.
                    // Send the click to the attached control, then check the
                    // current responder rather than a retained, detached view.
                    guard let currentTable = resultsOutline(in: view), currentTable.window === window else {
                        throw SearchServiceError.commandFailed("The results table is missing after focusing search.")
                    }
                    if table !== currentTable { print("Audit reacquired the attached results table after layout.") }
                    table = currentTable
                    table.scrollRowToVisible(0)
                    table.layoutSubtreeIfNeeded()
                    let column = table.tableColumns.firstIndex(where: { $0.title == "Name" })!
                    await click(NSPoint(x: table.rect(ofColumn: column).midX, y: table.rect(ofRow: 0).midY), in: table, window: window)
                    try await Task.sleep(for: .milliseconds(150))
                    let focusedView = window.firstResponder as? NSView
                    guard let clickedTable = resultsOutline(in: view), clickedTable.window === window,
                          (focusedView === clickedTable || focusedView?.isDescendant(of: clickedTable) == true),
                          clickedTable.selectedRow == 0,
                          field.currentEditor() == nil, !reportedFocus else {
                        throw SearchServiceError.commandFailed("A result click did not retain native table focus or clear search focus. Responder=\(String(describing: window.firstResponder)); editor=\(String(describing: field.currentEditor())); reported=\(reportedFocus); table attached=\(table.window === window); selected=\(resultsOutline(in: view)?.selectedRow ?? -1); key=\(window.isKeyWindow)")
                    }
                    table = clickedTable
                    print("Result focus: native table; active app: \(application.isActive); key window: \(window.isKeyWindow); emphasized selection: \(table.rowView(atRow: table.selectedRow, makeIfNecessary: true)?.isEmphasized ?? false)")
                    print("Selected row: \(table.selectedRow); selected count: \(table.selectedRowIndexes.count); responder: \(String(describing: window.firstResponder)); row: \(String(describing: table.rowView(atRow: table.selectedRow, makeIfNecessary: true)))")
                    try await capture(window.contentView?.superview ?? view,
                        to: output.deletingLastPathComponent().appendingPathComponent("ui-results-focused.png"))

                    try await auditQuickLook(view: view, window: window, model: model, output: output)
                    let focusShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
                    guard window.performKeyEquivalent(with: focusShortcut) else {
                        throw SearchServiceError.commandFailed("Command-F was not handled.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    guard let editor = field.currentEditor() as? NSTextView,
                          editor.font?.pointSize == field.font?.pointSize else {
                        throw SearchServiceError.commandFailed("Search text and field editor use different fonts.")
                    }
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                    print("Search control: \(field.frame); font: \(field.font!.pointSize); editor font: \(editor.font!.pointSize)")
                    print("Text rect: \(field.searchTextBounds); icon rect: \(field.searchButtonBounds); editor: \(field.convert(editor.bounds, from: editor))")
                    let editorBounds = field.convert(editor.bounds, from: editor)
                    let caretOnScreen = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
                    let caret = field.convert(window.convertFromScreen(caretOnScreen), from: nil)
                    print("Caret: \(caret)")
                    guard abs(caret.midY - field.bounds.midY) < 2,
                          abs(caret.midY - field.searchButtonBounds.midY) < 2,
                          caret.minX - field.searchButtonBounds.maxX >= 8,
                          caret.height < 24, editorBounds.height < 24 else {
                        throw SearchServiceError.commandFailed("Search text, caret, and icon are not vertically aligned.")
                    }
                    let query = model.query
                    editor.insertText(" audit", replacementRange: editor.selectedRange())
                    guard model.query == query + " audit" else {
                        throw SearchServiceError.commandFailed("Typing into the native search field did not update the query.")
                    }
                    editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    try await Task.sleep(for: .milliseconds(100))
                    guard model.query == query, editor.font?.pointSize == 17 else {
                        throw SearchServiceError.commandFailed("Editing changed the search field's font or query unexpectedly.")
                    }
                    let editingOutput = output.deletingLastPathComponent().appendingPathComponent("ui-editing.png")
                    try await capture(window.contentView?.superview ?? view, to: editingOutput)
                    window.makeFirstResponder(table)
                    try await Task.sleep(for: .milliseconds(100))
                    // A historical query must be editable in the visible first
                    // input; clearing it must return to the direct rg listing
                    // and shared multi-term content matcher.
                    model.refinements.fileQuery = "Sources"
                    try await Task.sleep(for: .milliseconds(250))
                    guard let filename = descendants(view).compactMap({ $0 as? NSSearchField })
                        .first(where: { $0.accessibilityIdentifier() == "filenameInput" }),
                          filename.stringValue == "Sources" else {
                        throw SearchServiceError.commandFailed("Restored file query is missing from the filename input.")
                    }
                    window.makeFirstResponder(filename)
                    guard let filenameEditor = filename.currentEditor() as? NSTextView else {
                        throw SearchServiceError.commandFailed("Filename query cannot be edited.")
                    }
                    filenameEditor.insertText("", replacementRange: NSRange(location: 0, length: filenameEditor.string.utf16.count))
                    try await Task.sleep(for: .milliseconds(400))
                    guard model.filenameInput.isEmpty, model.refinements.fileQuery.isEmpty,
                          model.engineName == "FindUI", model.contentsInput == query else {
                        throw SearchServiceError.commandFailed("Clearing the native filename input did not restore the compound content search: engine=\(model.engineName), filename=\(model.filenameInput), contents=\(model.contentsInput).")
                    }
                    print("Restored filename query: visible; native clear restores direct content search and retains contents.")
                    window.makeFirstResponder(table)
                } else {
                    throw SearchServiceError.commandFailed("The native search field did not render.")
                }
                try await capture(window.contentView?.superview ?? view, to: output)
                print(output.path)
                for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = window.standardWindowButton(kind) {
                        print("Native window control \(kind.rawValue): \(button.frame)")
                    }
                }
                window.setContentSize(NSSize(width: 1000, height: 680))
                try await Task.sleep(for: .milliseconds(250))
                let minimumOutput = output.deletingLastPathComponent().appendingPathComponent("ui-minimum.png")
                try await capture(window.contentView?.superview ?? view, to: minimumOutput)
                print(minimumOutput.path)
                let filesModel = SearchViewModel(service: SearchService(tools: tools),
                    persistence: AppPersistence(baseDirectory: temporary.appendingPathComponent("FileSearch")), loadSavedState: false)
                filesModel.scopeURL = project
                filesModel.refinements.name = "*.swift"
                filesModel.refinements.nameMatching = .glob
                let filesView = NSHostingView(rootView: ContentView(viewModel: filesModel).preferredColorScheme(.light))
                let filesWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 680),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                filesWindow.title = "FindUI"
                filesWindow.contentView = filesView
                if !layoutOnly {
                    filesWindow.center()
                    application.activate()
                    filesWindow.makeKeyAndOrderFront(nil)
                }
                filesWindow.display()
                try await Task.sleep(for: .milliseconds(600))
                let filesOutput = output.deletingLastPathComponent().appendingPathComponent("ui-files-minimum.png")
                try await capture(filesWindow.contentView?.superview ?? filesView, to: filesOutput)
                print(filesOutput.path)
                @MainActor func control(_ id: String) throws -> AccessibleElement {
                    guard let element = accessibilityElements(in: filesView).first(where: { $0.accessibilityIdentifier() == id }) else {
                        throw SearchServiceError.commandFailed("Missing visible control: \(id)")
                    }
                    return element
                }
                guard !accessibilityElements(in: filesView).contains(where: {
                    ($0.accessibilityLabel() ?? "").contains("Describe Search")
                }) else { throw SearchServiceError.commandFailed("The removed natural-language action is still visible.") }
                let modeFrame = try control("expandSearchRules").accessibilityFrame()
                let searchFrame = try control("searchButton").accessibilityFrame()
                let optionsFrame = try control("searchScopeOptions").accessibilityFrame()
                guard searchFrame.minX > modeFrame.maxX, abs(searchFrame.midY - modeFrame.midY) < 2,
                      abs(optionsFrame.midY - modeFrame.midY) < 2 else {
                    throw SearchServiceError.commandFailed("Search, mode toggle and Scope & Options do not share one toolbar row.")
                }
                _ = try control("filenamePresets")
                guard !accessibilityElements(in: filesView).contains(where: { $0.accessibilityIdentifier() == "documentSearchOptions" }) else {
                    throw SearchServiceError.commandFailed("Documents still has a separate toolbar panel.")
                }
                if !layoutOnly {
                    filesWindow.makeKeyAndOrderFront(nil)
                    guard let filename = descendants(filesView).compactMap({ $0 as? NSSearchField })
                        .first(where: { $0.accessibilityIdentifier() == "filenameInput" }) else {
                        throw SearchServiceError.commandFailed("Filename field is missing before the Rules switch.")
                    }
                    await click(NSPoint(x: 90, y: filename.bounds.midY), in: filename, window: filesWindow)
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard try control("expandSearchRules").accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("Rules cannot be activated.")
                }
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(12))
                    guard try control("useSimpleSearchControls").accessibilityFrame() == modeFrame,
                          try control("searchButton").accessibilityFrame() == searchFrame,
                          try control("searchScopeOptions").accessibilityFrame() == optionsFrame else {
                        let actualMode = try control("useSimpleSearchControls").accessibilityFrame()
                        let actualSearch = try control("searchButton").accessibilityFrame()
                        let actualOptions = try control("searchScopeOptions").accessibilityFrame()
                        throw SearchServiceError.commandFailed("Switching to Rules moved a toolbar action: mode \(modeFrame) -> \(actualMode); search \(searchFrame) -> \(actualSearch); options \(optionsFrame) -> \(actualOptions).")
                    }
                }
                guard try control("useSimpleSearchControls").accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("Simple controls cannot be restored.")
                }
                try await Task.sleep(for: .milliseconds(100))
                guard try control("expandSearchRules").accessibilityFrame() == modeFrame else {
                    throw SearchServiceError.commandFailed("Returning to simple controls moved the toggle.")
                }
                print("Search and the mode toggle retain their positions; Scope & Options shares the row, and filename presets are visible.")
                if !layoutOnly, let contents = searchField(in: filesView) {
                    await click(NSPoint(x: 90, y: contents.bounds.midY), in: contents, window: filesWindow)
                    try await Task.sleep(for: .milliseconds(150))
                    try assertSearchOutlines(in: filesView, focused: "searchInput", output: output)
                    guard let filename = descendants(filesView).compactMap({ $0 as? NSSearchField })
                        .first(where: { $0.accessibilityIdentifier() == "filenameInput" }) else {
                        throw SearchServiceError.commandFailed("Filename field is missing after restoring Simple controls.")
                    }
                    await click(NSPoint(x: 90, y: filename.bounds.midY), in: filename, window: filesWindow)
                    try await Task.sleep(for: .milliseconds(100))
                    try assertSearchOutlines(in: filesView, focused: "filenameInput", output: output)
                    await click(NSPoint(x: 90, y: contents.bounds.midY), in: contents, window: filesWindow)
                    try await Task.sleep(for: .milliseconds(100))
                    try assertSearchOutlines(in: filesView, focused: "searchInput", output: output)
                    try await capture(filesWindow.contentView?.superview ?? filesView,
                        to: output.deletingLastPathComponent().appendingPathComponent("ui-focus-after-rules.png"))
                    filesWindow.makeFirstResponder(nil)
                    try await Task.sleep(for: .milliseconds(100))
                    try assertSearchOutlines(in: filesView, focused: nil, output: output)
                    print("Rules → Simple → Contents and alternating input clicks keep exactly one blue outline; leaving the inputs clears both.")
                }
                if let entry = filesModel.orderedHistory.last { filesModel.togglePinned(entry) }
                try await Task.sleep(for: .milliseconds(150))
                try await capture(filesWindow.contentView?.superview ?? filesView,
                    to: output.deletingLastPathComponent().appendingPathComponent("ui-pinned-history.png"))
                let segments = descendants(filesView).compactMap { $0 as? NSSegmentedControl }
                guard segments.count == 1 else { throw SearchServiceError.commandFailed("The file-kind control is missing.") }
                let geometry = segments.map { $0.convert($0.bounds, to: filesView) }
                // Sample intermediate frames, not just settled screenshots. A
                // transient intrinsic-size animation was the reported bug.
                for mode in SearchMode.allCases + [.contents, .files] {
                    filesModel.mode = mode
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(8))
                        filesView.layoutSubtreeIfNeeded()
                        for (index, control) in segments.enumerated() {
                            guard control.convert(control.bounds, to: filesView) == geometry[index] else {
                                throw SearchServiceError.commandFailed("Search controls shifted during mode switch to \(mode.title).")
                            }
                        }
                    }
                }
                guard filesWindow.titlebarSeparatorStyle == .none else {
                    throw SearchServiceError.commandFailed("The titlebar separator is still visible.")
                }
                print("Mode-switch geometry stayed fixed across 120 intermediate frames; titlebar separator removed.")
                guard let split = descendants(filesView).compactMap({ $0 as? NSSplitView }).first(where: { $0.isVertical && $0.subviews.count >= 2 }),
                      let paneGuide = descendants(filesView).first(where: { $0.identifier?.rawValue == "resultsPaneGuide" }),
                      let footerGuide = descendants(filesView).first(where: { $0.identifier?.rawValue == "footerStatusGuide" }) else {
                    throw SearchServiceError.commandFailed("Results/footer alignment guides are missing.")
                }
                for position: CGFloat in [210, 280, 230] {
                    split.setPosition(position, ofDividerAt: 0)
                    try await Task.sleep(for: .milliseconds(100))
                    filesView.layoutSubtreeIfNeeded()
                    let paneLeft = paneGuide.convert(paneGuide.bounds, to: filesView).minX
                    let footerLeft = footerGuide.convert(footerGuide.bounds, to: filesView).minX
                    guard abs(footerLeft - paneLeft - 16) <= 1 else {
                        throw SearchServiceError.commandFailed("Footer drifted after sidebar resize: \(paneLeft), \(footerLeft).")
                    }
                }
                let importButton = try control("importSearchCommand")
                guard filesWindow.frame.contains(importButton.accessibilityFrame()),
                      !descendants(filesView).compactMap({ $0 as? NSTextField }).contains(where: {
                          ($0.placeholderString ?? "").contains("Paste fd, rg")
                      }) else { throw SearchServiceError.commandFailed("Command import is not in its compact footer location.") }
                print("Footer stayed aligned across three sidebar widths; command import is visible without an extra input row.")
                guard let reloadGuide = descendants(filesView).first(where: { $0.identifier?.rawValue == "reloadGuide" }),
                      let copyGuide = descendants(filesView).first(where: { $0.identifier?.rawValue == "copyCommandGuide" }) else {
                    throw SearchServiceError.commandFailed("Reload/copy controls did not render.")
                }
                guard abs(reloadGuide.convert(reloadGuide.bounds, to: filesView).minX - 16) <= 1 else {
                    throw SearchServiceError.commandFailed("Reload is not aligned to the window's left padding.")
                }
                let copyFrame = copyGuide.convert(copyGuide.bounds, to: filesView)
                filesModel.copyCommandPreview(to: NSPasteboard.withUniqueName())
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(12))
                    filesView.layoutSubtreeIfNeeded()
                    guard copyGuide.convert(copyGuide.bounds, to: filesView) == copyFrame else {
                        throw SearchServiceError.commandFailed("Copy feedback changed command-button geometry: \(copyFrame) -> \(copyGuide.convert(copyGuide.bounds, to: filesView)).")
                    }
                }
                print("Reload is fixed at the left margin; copy feedback preserves command-button geometry across 20 frames.")
                if !layoutOnly {
                    filesWindow.makeKeyAndOrderFront(nil)
                    guard let scope = descendants(filesView).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.placeholderString == "Directory path" }),
                          let filename = descendants(filesView).compactMap({ $0 as? NSSearchField })
                        .first(where: { $0.accessibilityIdentifier() == "filenameInput" }) else {
                        throw SearchServiceError.commandFailed("Folder or filename input is missing.")
                    }
                    let editedFolder = project.appendingPathComponent("Sources")
                    await click(NSPoint(x: scope.bounds.midX, y: scope.bounds.midY), in: scope, window: filesWindow)
                    try await Task.sleep(for: .milliseconds(100))
                    guard let editor = scope.currentEditor() as? NSTextView else {
                        throw SearchServiceError.commandFailed("Folder path cannot be edited.")
                    }
                    editor.insertText(editedFolder.path, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    try await Task.sleep(for: .milliseconds(100))
                    await click(NSPoint(x: filename.bounds.midX, y: filename.bounds.midY), in: filename, window: filesWindow)
                    try await Task.sleep(for: .milliseconds(300))
                    guard filesModel.scopeURL.path == editedFolder.path else {
                        throw SearchServiceError.commandFailed("Leaving the folder field without Return lost the edited scope: field=\(scope.stringValue), current=\(filesModel.scopeURL.path), expected=\(editedFolder.path), status=\(filesModel.statusMessage).")
                    }
                    filesModel.updateScopePath(project.path)
                    try await Task.sleep(for: .milliseconds(300))
                    let beforeImport = filesModel.searchState
                    guard try control("importSearchCommand").accessibilityPerformPress() else {
                        throw SearchServiceError.commandFailed("Command import cannot be opened.")
                    }
                    try await Task.sleep(for: .milliseconds(300))
                    guard let commandView = application.windows.filter(\.isVisible).compactMap(\.contentView).first(where: {
                        descendants($0).compactMap { $0 as? NSTextField }.contains { ($0.placeholderString ?? "").contains("Paste fd, rg") }
                    }), let input = descendants(commandView).compactMap({ $0 as? NSTextField })
                        .first(where: { ($0.placeholderString ?? "").contains("Paste fd, rg") }) else {
                        throw SearchServiceError.commandFailed("Command input cannot be found.")
                    }
                    guard let commandEditor = input.currentEditor() as? NSTextView else {
                        throw SearchServiceError.commandFailed("Command input did not receive keyboard focus automatically.")
                    }
                    let imported = "rg --fixed-strings --ignore-case --glob '*.swift' timeout ."
                    commandEditor.insertText(imported, replacementRange: NSRange(location: 0, length: commandEditor.string.utf16.count))
                    try await Task.sleep(for: .milliseconds(100))
                    try await capture(commandView.window?.contentView?.superview ?? commandView,
                        to: output.deletingLastPathComponent().appendingPathComponent("ui-command-import.png"))
                    guard let apply = accessibilityElements(in: commandView).first(where: { $0.accessibilityIdentifier() == "applyCommandImport" }),
                          apply.accessibilityPerformPress() else {
                        throw SearchServiceError.commandFailed("The command cannot be applied from its visible button.")
                    }
                    for _ in 0..<80 {
                        if !filesModel.isSearching && filesModel.history.contains(where: { $0.snapshot.sourceCommand == imported }) { break }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    guard filesModel.mode == .contents, filesModel.contentsInput == "timeout",
                          let history = filesModel.history.first(where: { $0.snapshot.sourceCommand == imported }) else {
                        throw SearchServiceError.commandFailed("Pasting a command did not populate controls and history: mode=\(filesModel.mode), contents=\(filesModel.contentsInput), source=\(filesModel.searchState.sourceCommand ?? "nil"), status=\(filesModel.statusMessage).")
                    }
                    filesModel.restoreSearchState(beforeImport)
                    filesModel.runHistoryEntry(history)
                    try await Task.sleep(for: .milliseconds(250))
                    guard filesModel.searchState.sourceCommand == imported, searchField(in: filesView)?.stringValue == "timeout",
                          filesModel.refinements == history.snapshot.refinements else {
                        throw SearchServiceError.commandFailed("History did not restore command, contents, and filters.")
                    }
                    filesModel.restoreSearchState(beforeImport)
                    filesModel.scheduleSearch(immediate: true)
                    print("Native folder edits commit on focus change; command paste populates controls and restores completely from history.")
                }

                window.setContentSize(NSSize(width: 1320, height: 820))
                view.rootView = ContentView(viewModel: model).preferredColorScheme(.dark)
                window.appearance = NSAppearance(named: .darkAqua)
                try await Task.sleep(for: .milliseconds(350))
                let darkOutput = output.deletingLastPathComponent().appendingPathComponent("ui-dark.png")
                try await capture(window.contentView?.superview ?? view, to: darkOutput)
                print(darkOutput.path)
                let filterModel = SearchViewModel(persistence: AppPersistence(baseDirectory: temporary.appendingPathComponent("Filters")),
                                                   loadSavedState: false)
                filterModel.filters = SearchFilters(minimumSize: "10 MB", datePeriod: .week)
                filterModel.traversal.excludedFolders = ["node_modules", ".venv", "build"]
                let filterView = NSHostingView(rootView: SearchOptionsView(viewModel: filterModel).preferredColorScheme(.light))
                let filterWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 340),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
                filterWindow.contentView = filterView
                filterWindow.display()
                try await Task.sleep(for: .milliseconds(150))
                // Type separators one keystroke at a time: rebuilding these
                // editors from arrays used to delete the newline immediately.
                let additionalFolder = project.appendingPathComponent("Tests").path
                filterModel.refinements.additionalScopes = [project.path, additionalFolder]
                try await Task.sleep(for: .milliseconds(100))
                guard let removeScope = accessibilityElements(in: filterView).first(where: { $0.accessibilityIdentifier() == "removeScope.\(project.path)" }),
                      removeScope.accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("Additional folders have no working Remove control.")
                }
                try await Task.sleep(for: .milliseconds(100))
                guard filterModel.refinements.additionalScopes == [additionalFolder] else {
                    throw SearchServiceError.commandFailed("Removing one additional folder changed another folder.")
                }
                for initial in ["node_modules\n.venv\nbuild"] {
                    guard let editor = descendants(filterView).compactMap({ $0 as? NSTextView })
                        .first(where: { !$0.isFieldEditor && $0.string == initial }) else {
                        throw SearchServiceError.commandFailed("Cannot find the multiline editor for \(initial).")
                    }
                    editor.insertText("\n", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                    try await Task.sleep(for: .milliseconds(100))
                    guard editor.string == initial + "\n" else {
                        throw SearchServiceError.commandFailed("A multiline editor erased the new line before the next entry could be typed.")
                    }
                    let addition = "dist"
                    editor.insertText(addition, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                    try await Task.sleep(for: .milliseconds(100))
                    let values = filterModel.traversal.excludedFolders
                    guard values.last == addition else {
                        throw SearchServiceError.commandFailed("The second multiline entry did not reach SearchState.")
                    }
                }
                filterModel.refinements.additionalScopes = []
                filterModel.traversal.excludedFolders = ["node_modules", ".venv", "build"]
                try await Task.sleep(for: .milliseconds(100))
                print("Additional folder rows remove only their own scope; exclusions preserve newlines and commit every typed entry.")
                let filterOutput = output.deletingLastPathComponent().appendingPathComponent("filters.png")
                try await capture(filterView, to: filterOutput)
                print(filterOutput.path)
                guard filterModel.refinements.extraction == nil,
                      let documents = accessibilityElements(in: filterView).first(where: { $0.accessibilityIdentifier() == "searchExtractedText" }) else {
                    throw SearchServiceError.commandFailed("Document conversion is enabled without opting in, or its checkbox is missing.")
                }
                guard documents.accessibilityPerformPress() else { throw SearchServiceError.commandFailed("Cannot toggle Documents on.") }
                try await Task.sleep(for: .milliseconds(100))
                guard filterModel.refinements.extraction?.documents == true, filterModel.refinements.extraction?.archives == false else {
                    throw SearchServiceError.commandFailed("Documents checkbox did not opt into document conversion alone.")
                }
                guard documents.accessibilityPerformPress() else { throw SearchServiceError.commandFailed("Cannot toggle Documents off.") }
                try await Task.sleep(for: .milliseconds(100))
                guard filterModel.refinements.extraction == nil else { throw SearchServiceError.commandFailed("Documents checkbox did not disable extraction.") }
                print("Documents is an explicit opt-in in Scope & Options; its checkbox never enables archive expansion.")
                filterModel.defaultSearchDirectoryPath = project.path
                let settingsView = NSHostingView(rootView: SettingsView(viewModel: filterModel).preferredColorScheme(.light))
                let settingsWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 860, height: 640),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
                settingsWindow.title = "FindUI Settings"
                settingsWindow.contentView = settingsView
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.display()
                try await Task.sleep(for: .milliseconds(250))
                guard !accessibilityElements(in: settingsView).contains(where: {
                    $0.accessibilityIdentifier() == "loadSearchModelAtStartup"
                }) else { throw SearchServiceError.commandFailed("Model loading is still present in Settings.") }
                for identifier in ["openFullDiskAccess", "revealFindUIApplication"] {
                    guard accessibilityElements(in: settingsView).contains(where: {
                        $0.accessibilityIdentifier() == identifier
                    }) else { throw SearchServiceError.commandFailed("Missing Full Disk Access setup action: \(identifier).") }
                }
                print("Settings includes Full Disk Access setup and a Finder action for the running app; no permission is granted by the audit.")

                let settingsOutput = output.deletingLastPathComponent().appendingPathComponent("ui-settings.png")
                try await capture(settingsWindow.contentView?.superview ?? settingsView, to: settingsOutput)
                print(settingsOutput.path)
                if let tabs = descendants(settingsView).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 3 }) {
                    tabs.selectedSegment = 2
                    tabs.sendAction(tabs.action, to: tabs.target)
                } else if let toolsTab = accessibilityElements(in: settingsView).first(where: { $0.accessibilityLabel() == "Tools" || $0.object.accessibilityTitle?() == "Tools" }) {
                    guard toolsTab.accessibilityPerformPress() else { throw SearchServiceError.commandFailed("Cannot open Tools settings.") }
                } else { throw SearchServiceError.commandFailed("Tools settings tab is missing.") }
                try await Task.sleep(for: .milliseconds(400))
                for id in ["tikaDownload", "tikaSelectedVersion", "tikaCheckUpdates"] {
                    guard accessibilityElements(in: settingsView).contains(where: { $0.accessibilityIdentifier() == id }) else {
                        throw SearchServiceError.commandFailed("Missing Tika management control: \(id)")
                    }
                }
                let toolsOutput = output.deletingLastPathComponent().appendingPathComponent("ui-tools.png")
                try await capture(settingsWindow.contentView?.superview ?? settingsView, to: toolsOutput)
                print(toolsOutput.path)
                // The audit uses an isolated manager directory, never the user's selection.
                if let isolated = ProcessInfo.processInfo.environment["FINDUI_TIKA_DIRECTORY"], isolated.contains("/.cache/usability-revision/"),
                   let version = try TikaManager().status().selectedVersion {
                    defer { try? TikaManager().select(version) }
                    try TikaManager().select(nil)
                    try await Task.sleep(for: .milliseconds(100))
                    guard !filterModel.toolLocations.contains(where: { $0.name == "Tika" }) else {
                        throw SearchServiceError.commandFailed("Turning Tika off did not update the running app.")
                    }
                    try TikaManager().select(version)
                    try await Task.sleep(for: .milliseconds(100))
                    guard filterModel.toolLocations.contains(where: { $0.name == "Tika" }) else {
                        throw SearchServiceError.commandFailed("Selecting Tika still requires restarting the app.")
                    }
                    print("Tika selection updates the live toolchain without restarting.")
                }
                // Reproduce unfinished edits, not just removing already-valid
                // values. Both sections must return to exactly the empty state.
                for section in ["files", "contents"] {
                    for join in 0..<3 {
                        let file = SearchRuleTree<SearchFileRule>.rule(.name("", .contains))
                        let content = SearchRuleTree<SearchContentRule>.rule(.literal(""))
                        let fileTree: SearchRuleTree<SearchFileRule> = join == 0 ? .all([file]) : join == 1 ? .any([file]) : .none([file])
                        let contentTree: SearchRuleTree<SearchContentRule> = join == 0 ? .all([content]) : join == 1 ? .any([content]) : .none([content])
                        filesModel.updateRules(section == "files" ? .init(files: fileTree) : .init(contents: contentTree))
                        try await Task.sleep(for: .milliseconds(120))
                        print("Unfinished \(section): \(filesModel.searchRules!) / \(filesModel.statusMessage)")
                        guard try control("removeRule.\(section).0").accessibilityPerformPress() else {
                            throw SearchServiceError.commandFailed("Cannot remove an unfinished \(section) condition.")
                        }
                        try await Task.sleep(for: .milliseconds(300))
                        guard filesModel.searchRules == .init(), filesModel.canUseCompactControls else {
                            throw SearchServiceError.commandFailed("Removing the last unfinished \(section) row left invalid rules: \(String(describing: filesModel.searchRules)).")
                        }
                        try filesModel.searchRules!.validate(now: .now)
                        guard !filesModel.statusMessage.contains("empty condition") else {
                            throw SearchServiceError.commandFailed("The \(section) validation error survived removal: \(filesModel.statusMessage)")
                        }
                    }
                }
                print("Empty Files and Contents conditions both clear completely after removal, for All/Any/None.")
                try "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>hBN</title></svg>\n".write(
                    to: project.appendingPathComponent("hBN.svg"), atomically: true, encoding: .utf8)
                filesModel.updateRules(.init(files: .any([
                    .all([.rule(.extensions(["svg", "pdf", "ai"])), .rule(.size(minimum: "", maximum: "10 MB"))]),
                    .all([.rule(.extensions(["jpg", "jpeg", "png", "gif", "webp"])), .rule(.size(minimum: "", maximum: "100 MB"))])
                ]), contents: .all([.rule(.literal("hBN")), .none([.rule(.literal("draft"))])]), contentUnit: .file))
                filesModel.refreshSearch()
                filesWindow.setContentSize(NSSize(width: 1100, height: 820))
                filesWindow.makeKeyAndOrderFront(nil)
                filesWindow.display()
                try await Task.sleep(for: .milliseconds(400))
                for _ in 0..<100 where filesModel.isSearching || filesModel.results.map(\.name) != ["hBN.svg"] {
                    try await Task.sleep(for: .milliseconds(40))
                }
                guard filesModel.results.map(\.name) == ["hBN.svg"] else {
                    throw SearchServiceError.commandFailed("Grouped UI search did not find the new SVG fixture after refresh.")
                }
                if !layoutOnly {
                    let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: filesWindow.windowNumber,
                        context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
                    guard filesWindow.performKeyEquivalent(with: shortcut) else {
                        throw SearchServiceError.commandFailed("Grouped Command-F was not handled.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    guard let editor = filesWindow.firstResponder as? NSTextView, editor.string == "hBN" else {
                        throw SearchServiceError.commandFailed("Grouped Command-F did not focus the content condition.")
                    }
                    editor.selectAll(nil)
                    editor.insertText("hBN", replacementRange: editor.selectedRange())
                }
                let groupedOutput = output.deletingLastPathComponent().appendingPathComponent("ui-grouped-search.png")
                try await capture(filesWindow.contentView?.superview ?? filesView, to: groupedOutput)
                print(groupedOutput.path)
                guard !descendants(filesView).contains(where: { $0 is NSSegmentedControl }) else {
                    throw SearchServiceError.commandFailed("Rules still shows the compact file-kind bar.")
                }
                let ruleElements = accessibilityElements(in: filesView)
                guard ruleElements.contains(where: { $0.accessibilityIdentifier() == "useSimpleSearchControls" }),
                      ruleElements.contains(where: { $0.accessibilityIdentifier() == "addRule.files" }),
                      ruleElements.contains(where: { $0.accessibilityIdentifier() == "addRule.contents" }) else {
                    let found = ruleElements.compactMap { $0.accessibilityIdentifier() }.filter { !$0.isEmpty }.joined(separator: ", ")
                    throw SearchServiceError.commandFailed("Missing rule actions in accessibility tree: \(found)")
                }
                guard !ruleElements.contains(where: {
                    ["Add content condition", "Remove contents"].contains($0.accessibilityLabel() ?? "")
                }) else { throw SearchServiceError.commandFailed("Contents still has its separate activation/removal controls.") }
                if let simple = ruleElements.first(where: { $0.accessibilityIdentifier() == "useSimpleSearchControls" }),
                   let editor = ruleElements.first(where: { $0.accessibilityIdentifier() == "searchRuleEditor" }) {
                    guard simple.accessibilityFrame().minY > editor.accessibilityFrame().maxY else {
                        throw SearchServiceError.commandFailed("Simple controls is still inside the rule sections.")
                    }
                }
                guard filesModel.searchRules != nil, !filesModel.refinements.hasFileConditions,
                      !filesModel.filters.isActive, !filesModel.canUseCompactControls,
                      !filesModel.producesContentLines else {
                    throw SearchServiceError.commandFailed("Grouped UI state conflicts with compact controls or output unit.")
                }
                let groupedOptions = NSHostingView(rootView: SearchOptionsView(viewModel: filesModel).preferredColorScheme(.light))
                filterWindow.contentView = groupedOptions
                filterWindow.display()
                try await Task.sleep(for: .milliseconds(150))
                let groupedOptionsOutput = output.deletingLastPathComponent().appendingPathComponent("ui-grouped-options.png")
                try await capture(groupedOptions, to: groupedOptionsOutput)
                print(groupedOptionsOutput.path)
                print("Grouped controls retain branches; compact filters are absent; same-file contents return files.")
                guard let previousRules = filesModel.searchRules else {
                    throw SearchServiceError.commandFailed("Grouped audit state lost its rules.")
                }
                let age = SearchFilters(datePeriod: .recentCalendar, calendarAge: "5 months and 4 days")
                filesModel.updateRules(.init(files: .all([.rule(.date(.init(age))), previousRules.files]),
                    contents: previousRules.contents, contentUnit: previousRules.contentUnit))
                try await Task.sleep(for: .milliseconds(180))
                guard descendants(filesView).contains(where: { ($0 as? NSTextField)?.stringValue == "5 months and 4 days" }) else {
                    throw SearchServiceError.commandFailed("The grouped calendar duration is not visible in its date condition.")
                }
                let calendarRulesOutput = output.deletingLastPathComponent().appendingPathComponent("ui-calendar-rules.png")
                try await capture(filesWindow.contentView?.superview ?? filesView, to: calendarRulesOutput)
                filesModel.updateRules(previousRules)
                let calendarModel = SearchViewModel(persistence: AppPersistence(baseDirectory: temporary.appendingPathComponent("CalendarSettings")),
                                                    loadSavedState: false)
                calendarModel.filters = age
                let calendarOptions = NSHostingView(rootView: SearchOptionsView(viewModel: calendarModel).preferredColorScheme(.light))
                filterWindow.contentView = calendarOptions; filterWindow.display()
                try await Task.sleep(for: .milliseconds(180))
                guard descendants(calendarOptions).contains(where: { ($0 as? NSTextField)?.stringValue == "5 months and 4 days" }) else {
                    throw SearchServiceError.commandFailed("The compact calendar duration is not visible in its date filter.")
                }
                let calendarOptionsOutput = output.deletingLastPathComponent().appendingPathComponent("ui-calendar-options.png")
                try await capture(calendarOptions, to: calendarOptionsOutput)
                print("Calendar durations are visible and editable in both compact filters and grouped rules.")
                for join in 0..<3 {
                    let content = SearchRuleTree<SearchContentRule>.rule(.literal("hBN"))
                    let tree: SearchRuleTree<SearchContentRule> = join == 0 ? .all([content]) : join == 1 ? .any([content]) : .none([content])
                    filesModel.updateRules(.init(contents: tree, contentUnit: .file))
                    try await Task.sleep(for: .milliseconds(120))
                    guard let remove = accessibilityElements(in: filesView).first(where: {
                        $0.accessibilityIdentifier() == "removeRule.contents.0"
                    }), remove.accessibilityPerformPress() else {
                        throw SearchServiceError.commandFailed("The last content condition cannot be removed using its visible button.")
                    }
                    try await Task.sleep(for: .milliseconds(120))
                    guard filesModel.searchRules?.contents == nil, filesModel.mode == .files,
                          filesModel.searchRules?.contentUnit == .line, filesModel.canUseCompactControls else {
                        throw SearchServiceError.commandFailed("Deleting the last content condition did not restore the empty section.")
                    }
                }
                filesModel.updateRules(.init(contents: .all([.any([.rule(.literal("hBN"))])]), contentUnit: .file))
                try await Task.sleep(for: .milliseconds(120))
                guard let nestedRemove = accessibilityElements(in: filesView).first(where: {
                    $0.accessibilityIdentifier() == "removeRule.contents.0.0"
                }), nestedRemove.accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("The nested content condition cannot be removed.")
                }
                try await Task.sleep(for: .milliseconds(120))
                guard filesModel.searchRules?.contents == .all([.any([])]) else {
                    throw SearchServiceError.commandFailed("Deleting a nested condition silently cleared its parent group.")
                }
                guard let groupRemove = accessibilityElements(in: filesView).first(where: {
                    $0.accessibilityIdentifier() == "removeRule.contents.0"
                }), groupRemove.accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("The empty content group cannot be removed.")
                }
                try await Task.sleep(for: .milliseconds(120))
                let emptyRulesOutput = output.deletingLastPathComponent().appendingPathComponent("ui-grouped-empty.png")
                try await capture(filesWindow.contentView?.superview ?? filesView, to: emptyRulesOutput)
                guard filesModel.searchRules?.contents == nil else {
                    throw SearchServiceError.commandFailed("Removing the final content group did not clear the section.")
                }
                print("Native last-condition deletion clears All/Any/None contents; nested empty groups remain incomplete until removed.")
                filesModel.traversal.pathRules = ["*.swift", "!Generated/**"]
                try await Task.sleep(for: .milliseconds(180))
                guard accessibilityElements(in: filesView).contains(where: { $0.accessibilityIdentifier() == "pathRulesBanner" }) else {
                    throw SearchServiceError.commandFailed("Imported path rules are hidden from the main search controls.")
                }
                try await capture(filesWindow.contentView!.superview!, to: output.deletingLastPathComponent().appendingPathComponent("ui-path-rules.png"))
                guard let clearPatterns = accessibilityElements(in: filesView).first(where: { $0.accessibilityIdentifier() == "clearPathRules" }),
                      clearPatterns.accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("The path-rules Clear button cannot be pressed.")
                }
                try await Task.sleep(for: .milliseconds(100))
                guard filesModel.traversal.pathRules == nil else { throw SearchServiceError.commandFailed("Clear did not remove path rules.") }
                let wordModel = SearchViewModel(persistence: AppPersistence(baseDirectory: temporary.appendingPathComponent("WordOptions")), loadSavedState: false)
                wordModel.scopeURL = project
                wordModel.contentsInput = "retry"
                wordModel.contentMatchingChoice = .indexedWords
                wordModel.resetAdditionalFilters()
                guard wordModel.refinements.wordSearch == true else {
                    throw SearchServiceError.commandFailed("Reset Options changed Indexed words matching.")
                }
                let simpleWords = wordModel.searchState
                wordModel.updateRules(.init(contents: .any([.rule(.literal("retry")), .rule(.literal("timeout"))]), contentUnit: .document))
                let wordRules = NSHostingView(rootView: SearchRuleEditor(viewModel: wordModel).preferredColorScheme(.light))
                let wordWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                wordWindow.isReleasedWhenClosed = false; wordWindow.title = "Search rules"; wordWindow.contentView = wordRules
                wordWindow.orderFront(nil); wordWindow.display()
                try await Task.sleep(for: .milliseconds(180))
                guard let enginePicker = descendants(wordRules).compactMap({ $0 as? NSPopUpButton })
                    .first(where: { $0.accessibilityLabel() == "Content search engine" }), enginePicker.isEnabled else {
                    throw SearchServiceError.commandFailed("Grouped word searches have no usable content engine picker.")
                }
                for title in ["Live text", "Indexed words"] {
                    enginePicker.selectItem(withTitle: title)
                    guard enginePicker.sendAction(enginePicker.action, to: enginePicker.target) else {
                        throw SearchServiceError.commandFailed("The native content engine picker did not send its action.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    guard wordModel.contentTextEngine.title == title, wordModel.searchRules?.contents?.leaves.count == 2 else {
                        throw SearchServiceError.commandFailed("Switching content engines changed or lost the grouped conditions.")
                    }
                }
                try await capture(wordWindow.contentView!.superview!, to: output.deletingLastPathComponent().appendingPathComponent("ui-word-rules.png"))
                wordWindow.orderOut(nil); wordWindow.close()
                wordModel.restoreSearchState(simpleWords)
                print("Native path rules remain visible and clearable; grouped OR conditions survive both directions of the content engine picker.")
                let wordOptions = NSHostingView(rootView: SearchOptionsView(viewModel: wordModel).preferredColorScheme(.light))
                filterWindow.contentView = wordOptions; filterWindow.display()
                filterWindow.center(); filterWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(180))
                guard accessibilityElements(in: wordOptions).contains(where: { $0.accessibilityIdentifier() == "prepareContentIndex" }) else {
                    throw SearchServiceError.commandFailed("Word preparation is hidden behind Advanced.")
                }
                if let scroll = descendants(wordOptions).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                    document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height - 220)))
                }
                try await capture(filterWindow.contentView!.superview!, to: output.deletingLastPathComponent().appendingPathComponent("ui-word-options.png"))
                wordModel.contentMatchingChoice = .literal
                wordModel.refinements.textEncoding = "windows-1252"
                wordModel.refinements.typoTolerance = 1
                try await Task.sleep(for: .milliseconds(100))
                if let scroll = descendants(wordOptions).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                    document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                }
                try await Task.sleep(for: .milliseconds(150))
                guard let advanced = accessibilityElements(in: wordOptions).first(where: { $0.accessibilityIdentifier() == "advancedSearchOptions" }), advanced.accessibilityPerformPress() else {
                    throw SearchServiceError.commandFailed("Advanced search options cannot be expanded.")
                }
                try await Task.sleep(for: .milliseconds(150))
                guard accessibilityElements(in: wordOptions).contains(where: { $0.accessibilityIdentifier() == "textEncoding" }) else {
                    throw SearchServiceError.commandFailed("Expanded Advanced options do not expose the encoding picker.")
                }
                if let scroll = descendants(wordOptions).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                    document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                }
                try await capture(filterWindow.contentView!.superview!, to: output.deletingLastPathComponent().appendingPathComponent("ui-encoding-typos.png"))
                let explanation = try await SearchExplainer(tools: .resolve()).explain(wordModel.searchState.makeRequest(), file: project.appendingPathComponent("Sources/RequestClient.swift"))
                let explanationView = NSHostingView(rootView: SearchExplanationView(report: explanation).preferredColorScheme(.light))
                filterWindow.contentView = explanationView; filterWindow.display()
                try await Task.sleep(for: .milliseconds(150))
                try await capture(filterWindow.contentView!.superview!, to: output.deletingLastPathComponent().appendingPathComponent("ui-explain-file.png"))
                print("Indexed words exposes preparation without Advanced; option reset retains matching; encoding, typos and actual backend explanations render natively.")
                // Finish this set of standalone fixtures before testing the
                // managed windows. Their pending SwiftUI focus requests must
                // not compete with the active-tab routing check.
                for fixture in [window, filesWindow, filterWindow, settingsWindow] {
                    fixture.orderOut(nil)
                }
                let windowLibrary = SearchLibraryStore(persistence: AppPersistence(baseDirectory: temporary.appendingPathComponent("WindowLibrary")))
                windowLibrary.value.defaultSearchDirectoryPath = project.path
                var lastWindowClosures = 0
                let windowManager = SearchWindowManager(libraryStore: windowLibrary, loadSavedState: false,
                    onLastWindowClosed: { lastWindowClosures += 1 })
                let firstWindow = windowManager.newWindow()
                let firstSearch = windowManager.viewModel(for: firstWindow)!
                firstSearch.filenameInput = "*.swift"
                firstSearch.scheduleSearch(immediate: true)
                let tab = windowManager.newTab(relativeTo: firstWindow)
                let tabSearch = windowManager.viewModel(for: tab)!
                tabSearch.contentsInput = "timeout"
                tabSearch.scheduleSearch(immediate: true)
                let separateWindow = windowManager.newWindow()
                try await Task.sleep(for: .milliseconds(500))
                guard firstWindow.tabGroup?.windows.count == 2,
                      firstWindow.tabGroup === tab.tabGroup,
                      separateWindow.tabGroup !== firstWindow.tabGroup,
                      firstSearch !== tabSearch, firstSearch.filenameInput == "*.swift",
                      tabSearch.filenameInput.isEmpty, tabSearch.contentsInput == "timeout",
                      firstSearch.contentsInput.isEmpty else {
                    throw SearchServiceError.commandFailed("New window/tab grouping or independent query state failed.")
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
                firstWindow.tabGroup?.selectedWindow = firstWindow
                firstWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                let skipsForegroundRouting = layoutOnly || (CommandLine.arguments.contains("--allow-inactive") && !firstWindow.isKeyWindow)
                if !skipsForegroundRouting {
                    guard windowManager.activeViewModel === firstSearch else {
                        throw SearchServiceError.commandFailed("Window actions are not targeting the active search: key=\(firstWindow.isKeyWindow), selected=\(firstWindow.tabGroup?.selectedWindow === firstWindow), delegate=\(String(describing: firstWindow.delegate)), controller=\(String(describing: firstWindow.windowController)).")
                    }
                } else if !layoutOnly {
                    print("LIMIT: macOS denied foreground activation; native in-process input passed, but desktop focus and active-window routing remain unchecked.")
                }
                let tabOutput = output.deletingLastPathComponent().appendingPathComponent("ui-tabs.png")
                try await capture(firstWindow.contentView!.superview ?? firstWindow.contentView!, to: tabOutput)
                // The native tab-bar + action follows the window controller's
                // responder chain, just like the system's New Tab action.
                firstWindow.windowController?.newWindowForTab(nil)
                try await Task.sleep(for: .milliseconds(150))
                guard firstWindow.tabGroup?.windows.count == 3 else {
                    throw SearchServiceError.commandFailed("The native New Tab action did not add a tab.")
                }
                tab.close()
                separateWindow.close()
                try await Task.sleep(for: .milliseconds(100))
                guard windowManager.windows.count == 2, lastWindowClosures == 0 else {
                    throw SearchServiceError.commandFailed("Closing one tab/window closed other searches.")
                }
                for window in windowManager.windows { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                guard windowManager.windows.isEmpty, lastWindowClosures == 1 else {
                    throw SearchServiceError.commandFailed("The final search window did not request app termination exactly once.")
                }
                await windowLibrary.flush()
                print(skipsForegroundRouting ? "Native independent windows/tabs, tab-bar New Tab, and last-window close passed; foreground routing skipped."
                      : "Native independent windows/tabs, active-search routing, tab-bar New Tab, and last-window close passed.")
                print(layoutOnly ? "Native layout, grouping, multi-selection, and match navigation checks passed."
                      : "Native grouping, multi-selection, row-click focus, search-click focus, Space, match navigation, Command-F, typing, and text/icon geometry checks passed.")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }

    private static func auditSidebarInteractions(view: NSView, window: NSWindow, model: SearchViewModel, output: URL) async throws {
        guard let guide = descendants(view).first(where: { $0.identifier?.rawValue == "resultsPaneGuide" }),
              let originalTable = resultsOutline(in: view),
              let history = descendants(view).compactMap({ $0 as? NSTableView }).first(where: { $0 !== originalTable && $0.numberOfRows > 100 }) else {
            throw SearchServiceError.commandFailed("Sidebar performance fixtures did not load.")
        }
        let root = window.contentView?.superview ?? view
        history.scrollRowToVisible(75)
        try await Task.sleep(for: .milliseconds(80))
        let historyOffset = history.visibleRect.origin
        var timings: [Double] = []
        for identifier in ["toggleHistorySidebar", "toggleInspectorSidebar"] {
            for iteration in 0..<6 {
                let buttons = accessibilityElements(in: root).filter { $0.accessibilityIdentifier() == identifier }
                guard let button = buttons.last else {
                    throw SearchServiceError.commandFailed("Missing toolbar button: \(identifier)")
                }
                let initial = guide.convert(guide.bounds, to: view)
                let started = ProcessInfo.processInfo.systemUptime
                // A toolbar item's outer accessibility wrapper can report a
                // successful press without invoking its SwiftUI Button. Use the
                // inner button node, not the NSToolbarItemViewer wrapper.
                if !button.accessibilityPerformPress() {
                    let frame = button.accessibilityFrame()
                    let point = root.convert(window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), from: nil)
                    await click(point, in: root, window: window)
                }
                var previous = initial, stableFrames = 0
                for _ in 0..<120 {
                    try await Task.sleep(for: .milliseconds(8))
                    view.layoutSubtreeIfNeeded()
                    let frame = guide.convert(guide.bounds, to: view)
                    if frame != initial, frame == previous { stableFrames += 1 } else { stableFrames = 0 }
                    previous = frame
                    if stableFrames >= 3 { break }
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                guard stableFrames >= 3 else {
                    throw SearchServiceError.commandFailed("Sidebar \(identifier) did not settle after its visible button was pressed; inspector=\(model.isInspectorPresented), initial=\(initial), current=\(previous).")
                }
                timings.append(elapsed)
                let currentHistory = descendants(view).compactMap({ $0 as? NSTableView }).first(where: { $0 !== resultsOutline(in: view) && $0.numberOfRows > 100 })
                print("Sidebar \(identifier) \(iteration.isMultiple(of: 2) ? "hide" : "show"): \(String(format: "%.1f", elapsed)) ms, table retained=\(originalTable === resultsOutline(in: view)), history retained=\(history === currentHistory), stable=\(stableFrames >= 3)")
                if !CommandLine.arguments.contains("--baseline") {
                    guard originalTable === resultsOutline(in: view), history === currentHistory else {
                        throw SearchServiceError.commandFailed("Collapsing a sidebar recreated the result or history table.")
                    }
                    if iteration % 2 == 1, history.visibleRect.origin != historyOffset {
                        throw SearchServiceError.commandFailed("The history scroll position changed after reopening: \(historyOffset) -> \(history.visibleRect.origin).")
                    }
                }
            }
        }
        let sorted = timings.sorted()
        print("Sidebar timing median=\(String(format: "%.1f", sorted[sorted.count / 2])) ms; max=\(String(format: "%.1f", sorted.last!)) ms. Includes three stable 8 ms frames.")
        try await capture(root, to: output)
        if !CommandLine.arguments.contains("--baseline") {
            try await auditQuickLook(view: view, window: window, model: model, output: output)
        }
    }

    private static func auditQuickLook(view: NSView, window: NSWindow, model: SearchViewModel, output: URL) async throws {
        func key(_ code: UInt16, _ characters: String, to target: NSWindow) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            NSApplication.shared.sendEvent(event)
        }
        func openPreview() async throws -> NSWindow {
            guard let table = resultsOutline(in: view) else { throw SearchServiceError.commandFailed("No results to preview.") }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(table)
            key(49, " ", to: window)
            for _ in 0..<50 {
                if let sheet = window.attachedSheet {
                    try await Task.sleep(for: .milliseconds(200))
                    return sheet
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw SearchServiceError.commandFailed("Space did not present Quick Look.")
        }
        func waitForClose() async throws {
            for _ in 0..<50 {
                if model.quickLookURL == nil, window.attachedSheet == nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw SearchServiceError.commandFailed("Quick Look did not dismiss.")
        }
        guard let table = resultsOutline(in: view) else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(30))
        let sheet = try await openPreview()
        let content = sheet.contentView!
        func control(_ identifier: String) throws -> AccessibleElement {
            guard let control = accessibilityElements(in: content).last(where: { $0.accessibilityIdentifier() == identifier }) else {
                throw SearchServiceError.commandFailed("Missing preview control: \(identifier)")
            }
            return control
        }
        let close = try control("closeQuickLook")
        let previous = try control("previousQuickLookResult")
        let next = try control("nextQuickLookResult")
        let sizes = [close, previous, next].map { $0.accessibilityFrame().size }
        guard sizes.allSatisfy({ $0 == sizes[0] && $0.width > 0 && $0.width <= 40 }),
              close.accessibilityLabel() == "Close preview" else {
            throw SearchServiceError.commandFailed("Preview icon controls have inconsistent geometry: \(sizes).")
        }
        let selected = model.selectedResultID
        guard next.accessibilityPerformPress() else { throw SearchServiceError.commandFailed("Next preview button did not respond.") }
        try await Task.sleep(for: .milliseconds(100))
        guard model.selectedResultID != selected else { throw SearchServiceError.commandFailed("Next preview button did not move selection.") }
        guard try control("previousQuickLookResult").accessibilityPerformPress() else { throw SearchServiceError.commandFailed("Previous preview button did not respond.") }
        try await Task.sleep(for: .milliseconds(100))
        guard model.selectedResultID == selected else { throw SearchServiceError.commandFailed("Previous preview button did not restore selection.") }
        guard let preview = descendants(content).compactMap({ $0 as? QLPreviewView }).first else {
            throw SearchServiceError.commandFailed("Native Quick Look view missing.")
        }
        let trace = ResultNavigationTrace()
        let observation = preview.observe(\.previewItem) { _, _ in
            MainActor.assumeIsolated { trace.previewAssignments += 1 }
        }
        for _ in 0..<4 {
            model.isInspectorPresented.toggle()
            try await Task.sleep(for: .milliseconds(40))
        }
        observation.invalidate()
        guard trace.previewAssignments == 0 else {
            throw SearchServiceError.commandFailed("Unchanged Quick Look item was reloaded \(trace.previewAssignments) times.")
        }
        try await capture(content.superview ?? content, to: output.deletingLastPathComponent().appendingPathComponent("ui-quick-look.png"))
        let bounds = content.bounds
        guard try control("closeQuickLook").accessibilityPerformPress() else { throw SearchServiceError.commandFailed("Close preview did not respond.") }
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(8))
            if window.attachedSheet != nil, content.bounds != bounds {
                throw SearchServiceError.commandFailed("Closing Quick Look changed its content geometry before dismissal.")
            }
        }
        try await waitForClose()
        for (code, text) in [(UInt16(49), " "), (UInt16(53), "\u{1b}")] {
            let reopened = try await openPreview()
            key(code, text, to: reopened)
            try await waitForClose()
        }
        print("Quick Look: equal-size ×/arrow controls, next/previous, Space/Escape/× dismissal, stable closing geometry, and zero unchanged-file reloads passed.")
    }

    private static func click(_ point: NSPoint, in view: NSView, window: NSWindow) async {
        // Directly delivered synthetic events do not go through WindowServer's
        // normal click-to-activate handling. Establish that state explicitly.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(100))
        window.displayIfNeeded()
        let location = view.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: timestamp + 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let table = view as? NSTableView, table.selectedRow != table.row(at: point),
           CommandLine.arguments.contains("--allow-inactive") {
            // A synthetic NSEvent has no WindowServer pointer/tracking state.
            // Still exercise AppKit's real selection handler; never substitute
            // a programmatic selectRow call or claim desktop routing coverage.
            print("LIMIT: synthetic table input required direct AppKit delivery; physical pointer routing is not verified.")
            NSApplication.shared.postEvent(up, atStart: true)
            table.mouseDown(with: down)
        }
    }

    private static func resultsOutline(in view: NSView) -> NSOutlineView? {
        if let table = view as? NSOutlineView, table.tableColumns.contains(where: { $0.title == "Name" }) { return table }
        for child in view.subviews {
            if let table = resultsOutline(in: child) { return table }
        }
        return nil
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private struct AccessibleElement {
        let object: AnyObject
        func accessibilityIdentifier() -> String? { object.accessibilityIdentifier?() }
        func accessibilityLabel() -> String? { object.accessibilityLabel?() }
        func accessibilityPerformPress() -> Bool { object.accessibilityPerformPress?() ?? false }
        func accessibilityFrame() -> NSRect { object.accessibilityFrame?() ?? .zero }
    }

    private static func accessibilityElements(in view: NSView) -> [AccessibleElement] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ item: Any) -> [AccessibleElement] {
            let object = item as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [AccessibleElement(object: object)] + (object.accessibilityChildren?() ?? []).flatMap(visit)
        }
        return descendants(view).flatMap(visit)
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField, field.accessibilityIdentifier() == "searchInput" { return field }
        for child in view.subviews {
            if let field = searchField(in: child) { return field }
        }
        return nil
    }

    /// Check the rendered outlines themselves, not just AppKit's responder.
    /// The reported regression had one real editor but two blue borders.
    private static func assertSearchOutlines(in view: NSView, focused identifier: String?, output: URL) throws {
        view.layoutSubtreeIfNeeded()
        let imageURL = output.deletingLastPathComponent().appendingPathComponent("ui-focus-\(identifier ?? "none").png")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            throw SearchServiceError.commandFailed("Could not inspect search outlines.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: imageURL) }
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let fields = descendants(view).compactMap { $0 as? NSSearchField }.filter {
            ["filenameInput", "searchInput"].contains($0.accessibilityIdentifier())
        }
        guard fields.count == 2 else { throw SearchServiceError.commandFailed("Both simple search fields must be visible.") }
        for field in fields {
            let rect = field.convert(field.bounds, to: view)
            // The border surrounds ten points of horizontal padding. Sample
            // the straight left edge, away from icons, text and rounded corners.
            let sampleY = view.isFlipped ? rect.midY - view.bounds.minY : view.bounds.maxY - rect.midY
            let y = Int(sampleY * scaleY)
            let x = Int((rect.minX - 10 - view.bounds.minX) * scaleX)
            let highlighted = (x..<(x + Int(4 * scaleX))).contains { pixel in
                guard let color = bitmap.colorAt(x: pixel, y: y)?.usingColorSpace(.sRGB) else { return false }
                // The compositor color-converts the screenshot; compare hue
                // and saturation rather than requiring identical RGB bytes.
                if accent.saturationComponent > 0.2 {
                    let distance = abs(color.hueComponent - accent.hueComponent)
                    return min(distance, 1 - distance) < 0.08 && color.saturationComponent > 0.4
                }
                return abs(color.redComponent - accent.redComponent) < 0.12
                    && abs(color.greenComponent - accent.greenComponent) < 0.12
                    && abs(color.blueComponent - accent.blueComponent) < 0.12
            }
            let expected = field.accessibilityIdentifier() == identifier
            guard highlighted == expected else {
                throw SearchServiceError.commandFailed("Incorrect visible focus outline for \(field.accessibilityIdentifier()): blue=\(highlighted), expected=\(expected); sampled at \(x),\(y) in \(bitmap.pixelsWide)x\(bitmap.pixelsHigh).")
            }
        }
    }

    private static func capture(_ view: NSView, to url: URL) async throws {
        if !CommandLine.arguments.contains("--layout-only"), !CommandLine.arguments.contains("--bitmap-only"), #available(macOS 14.4, *),
           let window = view.window, window.contentView?.superview === view {
            try await captureCompositedWindow(window, to: url)
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SearchServiceError.commandFailed("Could not create the screenshot bitmap.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SearchServiceError.commandFailed("Could not encode the screenshot.")
        }
        try png.write(to: url)
    }

    private static func captureCompositedWindow(_ window: NSWindow, to url: URL) async throws {
        guard #available(macOS 14.4, *) else { return }
        // cacheDisplay omits the compositor's Liquid Glass layers. Capture only
        // this process's disposable window; currentProcess requires no TCC grant.
        let priorFrame = window.frame
        defer { window.setFrame(priorFrame, display: true) }
        window.center(); window.makeKeyAndOrderFront(nil); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw SearchServiceError.commandFailed("The audit's own window is unavailable for composited capture.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // WindowServer can briefly reject capture just after app activation.
        // Retry that transient startup error, retaining failures after the bound.
        var captured: CGImage?
        for attempt in 0..<3 {
            do {
                captured = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
                break
            } catch {
                let failure = error as NSError
                guard attempt < 2, failure.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                      failure.code == -3811 else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let pixels = captured else { throw SearchServiceError.commandFailed("No window image was captured.") }
        guard let png = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else {
            throw SearchServiceError.commandFailed("Could not encode the composited window image.")
        }
        try png.write(to: url)
        print("Composited own-window capture: \(url.lastPathComponent)")
    }
}
