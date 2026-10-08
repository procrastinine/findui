import SearchBackend
import AppKit
import Combine
import SwiftUI

/// AppKit owns native windows and tabs. Each controller owns exactly one search.
@MainActor
final class SearchWindowManager: ObservableObject {
    let libraryStore: SearchLibraryStore
    @Published private(set) var activeViewModel: SearchViewModel?
    @Published private(set) var isShuttingDown = false
    private var controllers: [SearchWindowController] = []
    private var closingSearches: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let loadSavedState: Bool
    private let onLastWindowClosed: () -> Void
    private var settingsModel: SearchViewModel?
    var settingsFallback: SearchViewModel {
        if let settingsModel { return settingsModel }
        let model = SearchViewModel(loadSavedState: false, libraryStore: libraryStore)
        settingsModel = model
        return model
    }

    init(libraryStore: SearchLibraryStore = SearchLibraryStore(), loadSavedState: Bool = true,
         onLastWindowClosed: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.libraryStore = libraryStore
        self.loadSavedState = loadSavedState
        self.onLastWindowClosed = onLastWindowClosed
    }

    var windows: [NSWindow] { controllers.compactMap(\.window) }

    func viewModel(for window: NSWindow) -> SearchViewModel? {
        controllers.first(where: { $0.window === window })?.viewModel
    }

    @discardableResult
    func newWindow() -> NSWindow { createWindow(tabParent: nil) }

    @discardableResult
    func newTab(relativeTo parent: NSWindow? = nil) -> NSWindow {
        let selected = parent ?? windows.first(where: { $0.isKeyWindow })
            ?? controllers.first(where: { $0.viewModel === activeViewModel })?.window
        return createWindow(tabParent: selected)
    }

    private func createWindow(tabParent: NSWindow?) -> NSWindow {
        // Explicit Cmd-N always means a separate window, regardless of the
        // system preference for automatically grouping new windows into tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        let model = SearchViewModel(loadSavedState: loadSavedState, libraryStore: libraryStore)
        let controller = SearchWindowController(viewModel: model, manager: self)
        let window = controller.window!
        controllers.append(controller)
        if let parent = tabParent, windows.contains(where: { $0 === parent }) {
            parent.addTabbedWindow(window, ordered: .above)
        } else if let previous = windows.dropLast().last {
            window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        } else { window.center() }
        controller.showWindow(nil)
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        activeViewModel = model
        return window
    }

    fileprivate func activated(_ controller: SearchWindowController) {
        activeViewModel = controller.viewModel
    }

    fileprivate func changed(_ controller: SearchWindowController) {
        if activeViewModel === controller.viewModel { objectWillChange.send() }
    }

    fileprivate func closed(_ controller: SearchWindowController) {
        stop(controller.viewModel)
        controllers.removeAll { $0 === controller }
        if activeViewModel === controller.viewModel { activeViewModel = controllers.last?.viewModel }
        if controllers.isEmpty {
            Task { @MainActor [weak self] in
                guard let self, self.controllers.isEmpty else { return }
                self.onLastWindowClosed()
            }
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if let settingsModel { stop(settingsModel) }
        for controller in controllers { stop(controller.viewModel) }
    }

    func waitForShutdown() async {
        for task in Array(closingSearches.values) { await task.value }
    }

    private func stop(_ model: SearchViewModel) {
        let id = ObjectIdentifier(model)
        guard closingSearches[id] == nil else { return }
        let completion = model.shutdown()
        closingSearches[id] = Task { [weak self, model] in
            await completion.value
            self?.closingSearches[ObjectIdentifier(model)] = nil
        }
    }
}

@MainActor
private final class SearchWindowController: NSWindowController, NSWindowDelegate {
    let viewModel: SearchViewModel
    private weak var manager: SearchWindowManager?
    private var observation: AnyCancellable?

    init(viewModel: SearchViewModel, manager: SearchWindowManager) {
        self.viewModel = viewModel
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 680)
        window.tabbingIdentifier = "FindUI.Search"
        window.tabbingMode = .automatic
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(viewModel: viewModel))
        updateTitle()
        observation = viewModel.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateTitle()
                self.manager?.changed(self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(viewModel:manager:)") }

    private func updateTitle() {
        let terms = [viewModel.filenameInput, viewModel.contentsInput].filter { !$0.isEmpty }.joined(separator: " · ")
        let folder = viewModel.scopeURL.lastPathComponent.isEmpty ? "/" : viewModel.scopeURL.lastPathComponent
        let description = viewModel.searchRules != nil ? "Rules" : terms.isEmpty ? folder : String(terms.prefix(70))
        window?.title = "FindUI — " + folder
        window?.tab.title = description
    }

    @objc override func newWindowForTab(_ sender: Any?) { manager?.newTab(relativeTo: window) }
    func windowDidBecomeKey(_ notification: Notification) { manager?.activated(self) }
    func windowWillClose(_ notification: Notification) { manager?.closed(self) }
}
