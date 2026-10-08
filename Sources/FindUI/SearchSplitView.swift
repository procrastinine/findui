import SearchBackend
import AppKit
import SwiftUI

/// Keep the results and history hosts alive when a pane collapses. Removing
/// children from a SwiftUI HSplitView recreated lists and discarded scroll state.
struct SearchSplitView<History: View, Results: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var isHistoryPresented: Bool
    @Binding var isInspectorPresented: Bool
    let history: History
    let results: Results
    let inspector: Inspector

    func makeNSViewController(context: Context) -> SearchSplitController {
        SearchSplitController(history: AnyView(history), results: AnyView(results), inspector: AnyView(inspector),
            historyPresented: $isHistoryPresented, inspectorPresented: $isInspectorPresented)
    }

    func updateNSViewController(_ controller: SearchSplitController, context: Context) {
        controller.update(history: AnyView(history), results: AnyView(results), inspector: AnyView(inspector),
            historyPresented: $isHistoryPresented, inspectorPresented: $isInspectorPresented)
    }
}

@MainActor
final class SearchSplitController: NSSplitViewController {
    private let historyHost: NSHostingController<AnyView>
    private let resultsHost: NSHostingController<AnyView>
    private let inspectorHost: NSHostingController<AnyView>
    private let historyItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private var observations: [NSKeyValueObservation] = []
    private var historyPresented: Binding<Bool>
    private var inspectorPresented: Binding<Bool>

    init(history: AnyView, results: AnyView, inspector: AnyView,
         historyPresented: Binding<Bool>, inspectorPresented: Binding<Bool>) {
        self.historyPresented = historyPresented
        self.inspectorPresented = inspectorPresented
        historyHost = NSHostingController(rootView: history)
        resultsHost = NSHostingController(rootView: results)
        inspectorHost = NSHostingController(rootView: inspector)
        historyItem = NSSplitViewItem(sidebarWithViewController: historyHost)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.identifier = NSUserInterfaceItemIdentifier("searchSplitView")

        historyHost.sizingOptions = []
        resultsHost.sizingOptions = []
        inspectorHost.sizingOptions = []
        configure(historyItem, minimum: 200, maximum: 300)
        configure(inspectorItem, minimum: 280, maximum: 440)
        historyItem.preferredThicknessFraction = 0.18
        inspectorItem.preferredThicknessFraction = 0.25
        historyItem.isCollapsed = !historyPresented.wrappedValue
        inspectorItem.isCollapsed = !inspectorPresented.wrappedValue

        let resultsItem = NSSplitViewItem(viewController: resultsHost)
        resultsItem.minimumThickness = 440
        addSplitViewItem(historyItem)
        addSplitViewItem(resultsItem)
        addSplitViewItem(inspectorItem)

        observations = [historyItem, inspectorItem].map { item in
            item.observe(\.isCollapsed) { [weak self] _, _ in
                // Divider gestures also change visibility. Report after
                // AppKit's layout callback, using the current state.
                Task { @MainActor [weak self] in self?.reportVisibility() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(_:)") }

    private func configure(_ item: NSSplitViewItem, minimum: CGFloat, maximum: CGFloat) {
        item.minimumThickness = minimum
        item.maximumThickness = maximum
        item.canCollapse = true
        item.canCollapseFromWindowResize = false
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.allowsFullHeightLayout = false
        item.holdingPriority = NSLayoutConstraint.Priority(251)
    }

    func update(history: AnyView, results: AnyView, inspector: AnyView,
                historyPresented: Binding<Bool>, inspectorPresented: Binding<Bool>) {
        self.historyPresented = historyPresented
        self.inspectorPresented = inspectorPresented
        historyHost.rootView = history
        resultsHost.rootView = results
        inspectorHost.rootView = inspector
        // Direct assignment is non-animated; AppKit preserves pane widths.
        if historyItem.isCollapsed == historyPresented.wrappedValue {
            historyItem.isCollapsed = !historyPresented.wrappedValue
        }
        if inspectorItem.isCollapsed == inspectorPresented.wrappedValue {
            inspectorItem.isCollapsed = !inspectorPresented.wrappedValue
        }
    }

    private func reportVisibility() {
        if historyPresented.wrappedValue == historyItem.isCollapsed {
            historyPresented.wrappedValue = !historyItem.isCollapsed
        }
        if inspectorPresented.wrappedValue == inspectorItem.isCollapsed {
            inspectorPresented.wrappedValue = !inspectorItem.isCollapsed
        }
    }
}
