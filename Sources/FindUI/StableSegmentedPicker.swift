import SearchBackend
import AppKit
import SwiftUI

/// AppKit owns selection; segment widths never depend on the selected label.
struct StableSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let labels: [String]
    let widths: [CGFloat]
    var disabled: Set<Value> = []

    var width: CGFloat { widths.reduce(0, +) + 8 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 12)
        control.setAccessibilityLabel(title)
        control.setAccessibilityIdentifier(title == "Search mode" ? "searchMode" : "searchMatching")
        for index in widths.indices { control.setWidth(widths[index], forSegment: index) }
        updateNSView(control, context: context)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = values.firstIndex(of: selection) ?? 0
        for index in values.indices { control.setEnabled(!disabled.contains(values[index]), forSegment: index) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: width, height: 28)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: StableSegmentedPicker
        init(_ parent: StableSegmentedPicker) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.values.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.values[sender.selectedSegment]
        }
    }
}

/// Keep the native title bar and content as one surface, including on macOS 14.
struct UnifiedSearchTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitlebarView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.window?.titlebarSeparatorStyle = .none
        if #unavailable(macOS 15) { view.window?.toolbar?.showsBaselineSeparator = false }
        view.window?.titlebarAppearsTransparent = true
    }
    private final class TitlebarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarSeparatorStyle = .none
            if #unavailable(macOS 15) { window?.toolbar?.showsBaselineSeparator = false }
            window?.titlebarAppearsTransparent = true
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// HSplitView hosts its panes in separate native view trees, so SwiftUI named
/// coordinate spaces cannot measure their shared window position reliably.
struct ResultsPanePosition: NSViewRepresentable {
    var identifier = "resultsPaneGuide"
    let changed: (CGFloat) -> Void
    func makeNSView(context: Context) -> PositionView {
        let view = PositionView(changed: changed)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }
    func updateNSView(_ view: PositionView, context: Context) { view.changed = changed; view.report() }
    final class PositionView: NSView {
        var changed: (CGFloat) -> Void
        private var last: CGFloat = -1
        init(changed: @escaping (CGFloat) -> Void) {
            self.changed = changed; super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(splitResized),
                name: NSSplitView.didResizeSubviewsNotification, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }
        override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); report() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); report() }
        @objc private func splitResized(_ notification: Notification) {
            guard (notification.object as? NSSplitView)?.window == window else { return }
            report()
        }
        func report() {
            Task { @MainActor [weak self] in
                guard let self, let window, let content = window.contentView else { return }
                let left = convert(bounds, to: content).minX
                guard left != last else { return }; last = left; changed(max(0, left))
            }
        }
    }
}
