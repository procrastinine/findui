import SearchBackend
import AppKit
import SwiftUI

struct ResultsTableBridge: NSViewRepresentable {
    struct ColumnItem: Hashable, Sendable {
        let id: String
        let title: String
        let isVisible: Bool
        let canHide: Bool
    }

    let results: [SearchResult]
    let isBrowsingDirectory: Bool
    let columnItems: [ColumnItem]
    let onQuickLook: () -> Void
    let onOpenResult: (SearchResult) -> Void
    let onOpenFolder: (SearchResult) -> Void
    let onNavigateDirectory: (SearchResult) -> Void
    let onToggleColumnVisibility: (String) -> Void
    let onShowAllColumns: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
        nsView.scheduleConfiguration()
    }

    static func dismantleNSView(_ nsView: BridgeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ResultsTableBridge
        weak var tableView: NSTableView?
        private var eventMonitor: Any?

        init(parent: ResultsTableBridge) {
            self.parent = parent
        }

        func attach(to tableView: NSTableView) {
            guard self.tableView !== tableView else {
                configureColumns(in: tableView)
                return
            }

            detach()
            self.tableView = tableView
            tableView.target = self
            tableView.action = #selector(handlePrimaryAction(_:))
            tableView.doubleAction = #selector(handleDoubleAction(_:))
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let table = self.tableView,
                          event.window === table.window else { return false }
                    if event.type == .leftMouseDown {
                        let point = table.convert(event.locationInWindow, from: nil)
                        if table.visibleRect.contains(point), table.row(at: point) >= 0 {
                            // SwiftUI can replace a table's action target during
                            // redraw. Transfer focus from the field editor on
                            // the actual row click, independently of that target.
                            table.window?.makeFirstResponder(table)
                        }
                        return false
                    }
                    guard table.window?.firstResponder === table,
                          event.charactersIgnoringModifiers == " ",
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                    self.parent.onQuickLook()
                    return true
                }
                return handled ? nil : event
            }
            configureColumns(in: tableView)
        }

        func detach() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            guard let tableView else {
                return
            }

            if tableView.target === self {
                tableView.action = nil
                tableView.doubleAction = nil
                tableView.target = nil
            }

            self.tableView = nil
        }

        @objc private func handlePrimaryAction(_ sender: Any?) {
            guard let tableView else {
                return
            }

            tableView.window?.makeFirstResponder(tableView)
        }

        @objc private func handleDoubleAction(_ sender: Any?) {
            guard let tableView else {
                return
            }

            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < parent.results.count else {
                return
            }

            let result = parent.results[row]
            if parent.isBrowsingDirectory, result.isBrowsableDirectoryEntry {
                parent.onNavigateDirectory(result)
                return
            }

            let clickedColumn = tableView.clickedColumn
            let clickedTitle = clickedColumn >= 0 && clickedColumn < tableView.tableColumns.count
                ? tableView.tableColumns[clickedColumn].title
                : ""

            if clickedTitle == ResultPresentationLabels.path {
                parent.onOpenFolder(result)
            } else {
                parent.onOpenResult(result)
            }
        }

        private func configureColumns(in tableView: NSTableView) {
            configureHeaderMenu(for: tableView)
        }

        private func configureHeaderMenu(for tableView: NSTableView) {
            tableView.headerView?.menu = makeHeaderMenu()
        }

        private func makeHeaderMenu() -> NSMenu {
            let menu = NSMenu(title: "Columns")
            menu.autoenablesItems = false

            let showAllItem = NSMenuItem(
                title: "Show All Columns",
                action: #selector(handleShowAllColumns(_:)),
                keyEquivalent: ""
            )
            showAllItem.target = self
            menu.addItem(showAllItem)
            menu.addItem(.separator())

            for item in parent.columnItems {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(handleToggleColumn(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = item.id as NSString
                menuItem.state = item.isVisible ? .on : .off
                menuItem.isEnabled = item.canHide
                menu.addItem(menuItem)
            }

            return menu
        }

        @objc private func handleToggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? NSString else {
                return
            }
            parent.onToggleColumnVisibility(id as String)
        }

        @objc private func handleShowAllColumns(_ sender: NSMenuItem) {
            parent.onShowAllColumns()
        }
    }

    @MainActor
    final class BridgeView: NSView {
        weak var coordinator: Coordinator?

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            Task { @MainActor [weak self] in
                self?.configureIfNeeded()
            }
        }

        private func configureIfNeeded() {
            guard let coordinator else {
                return
            }

            guard let tableView = findTableView(startingAt: self) else {
                return
            }

            coordinator.attach(to: tableView)
        }

        private func findTableView(startingAt view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let candidate = current {
                if let tableView = Self.findTableView(in: candidate) {
                    return tableView
                }
                current = candidate.superview
            }
            return nil
        }

        private static func findTableView(in view: NSView) -> NSTableView? {
            if let tableView = view as? NSTableView, tableView.tableColumns.contains(where: { $0.title == "Name" }) {
                return tableView
            }

            for subview in view.subviews {
                if let tableView = findTableView(in: subview) {
                    return tableView
                }
            }

            return nil
        }
    }
}
