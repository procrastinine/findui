import SearchBackend
import AppKit
import SwiftUI

/// A native single-selection table. Its row draws one blue selection surface;
/// AppKit still owns mouse, arrow-key, focus, and accessibility behavior.
struct IndexDriveList: NSViewRepresentable {
    let volumes: [StorageVolume]
    let indexes: [ManagedIndex]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 50
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: .init("drive")))
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.setAccessibilityLabel("Drives to index")
        table.setAccessibilityIdentifier("indexDrives")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = table
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let changed = coordinator.parent.volumes != volumes || coordinator.parent.indexes != indexes
        coordinator.parent = self
        if changed || table.numberOfRows != volumes.count { table.reloadData() }
        if let row = volumes.firstIndex(where: { $0.id == selection }), table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        coordinator.updateColors(table)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: IndexDriveList
        init(_ parent: IndexDriveList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.volumes.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { DriveRow() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: .init("driveCell"), owner: self) as? DriveCell) ?? DriveCell()
            let volume = parent.volumes[row]
            cell.name.stringValue = volume.name
            cell.path.stringValue = volume.url.path
            cell.count.stringValue = parent.indexes.first(where: { $0.scopePath == volume.id }).map { String($0.entryCount) } ?? ""
            cell.toolTip = volume.url.path
            cell.setAccessibilityIdentifier("indexDrive.\(volume.id)")
            cell.setSelected(row == tableView.selectedRow)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView,
                  parent.volumes.indices.contains(table.selectedRow) else { return }
            let path = parent.volumes[table.selectedRow].id
            if parent.selection != path { parent.selection = path }
            updateColors(table)
        }
        func updateColors(_ table: NSTableView) {
            for row in 0..<table.numberOfRows {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? DriveCell)?.setSelected(row == table.selectedRow)
            }
        }
    }
    private final class DriveRow: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            NSColor.systemBlue.setFill()
            bounds.fill()
        }
    }
    private final class DriveCell: NSTableCellView {
        let name = NSTextField(labelWithString: "")
        let path = NSTextField(labelWithString: "")
        let count = NSTextField(labelWithString: "")
        init() {
            super.init(frame: .zero)
            identifier = .init("driveCell")
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            path.lineBreakMode = .byTruncatingMiddle
            count.font = .systemFont(ofSize: 11, weight: .semibold)
            count.setContentHuggingPriority(.required, for: .horizontal)
            count.setContentCompressionResistancePriority(.required, for: .horizontal)
            for field in [name, path, count] { field.translatesAutoresizingMaskIntoConstraints = false; addSubview(field) }
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
                path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
                path.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
                count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                count.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func setSelected(_ selected: Bool) {
            name.textColor = selected ? .white : .labelColor
            path.textColor = selected ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
            count.textColor = selected ? .white : .secondaryLabelColor
        }
    }
}
