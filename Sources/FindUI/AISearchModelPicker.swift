import SearchBackend
import AppKit
import SwiftUI

struct AISearchModelPicker: View {
    @ObservedObject var model: AISearchSettingsModel
    @State private var isPresented = false
    @State private var search = ""
    @State private var highlightedID: String?
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [AISearchModelOption] {
        guard !query.isEmpty else { return model.models }
        return model.models.filter { $0.id.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var customID: String? { !query.isEmpty && !model.models.contains(where: { $0.id == query }) ? query : nil }
    private var selectableIDs: [String] { matches.map(\.id) + (customID.map { [$0] } ?? []) + (model.configuration.provider == .codex ? [""] : []) }
    var body: some View {
        Button {
            search = ""; highlightedID = model.selectedModel; isPresented = true
        } label: {
            HStack {
                Text(model.selectedModel.isEmpty ? "Provider default" : model.selectedModel)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .help("Search available models or enter a model ID")
        .accessibilityLabel("Model: " + (model.selectedModel.isEmpty ? "Provider default" : model.selectedModel))
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    AIModelSearchField(text: $search, move: moveSelection,
                        submit: {
                            let values = selectableIDs
                            if let id = highlightedID, values.contains(id) { select(id) }
                            else if let id = values.first { select(id) }
                        }, cancel: { isPresented = false })
                        .frame(height: 26)
                    Button { model.fetchModels() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh available models").accessibilityLabel("Refresh models")
                        .disabled(model.isLoadingModels).accessibilityIdentifier("refreshAIModels")
                }
                if model.isLoadingModels {
                    HStack { ProgressView().controlSize(.small); Text("Loading models…").foregroundStyle(.secondary) }
                }
                if let error = model.modelsError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { item in
                            Button { select(item.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.body)
                                        Text(item.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if model.selectedModel == item.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }.padding(9).contentShape(Rectangle())
                                    .background(highlightedID == item.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).accessibilityIdentifier("aiModelChoice:" + item.id).id(item.id)
                        }
                        if matches.isEmpty && !model.isLoadingModels {
                            Text(query.isEmpty ? "Enter a model ID to use your provider’s model." : "No matching models.")
                                .foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                    }
                }.frame(height: 270)
                .onChange(of: highlightedID) { _, value in if let value { scroll.scrollTo(value) } }
                }
                if let customID {
                    Divider()
                    Button { select(customID) } label: {
                        Text("Use model ID: \(customID)").lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }.tint(highlightedID == customID ? Color.accentColor : nil).accessibilityIdentifier("useCustomAIModel")
                }
                if model.configuration.provider == .codex {
                    Divider()
                    Button("Use Codex’s default model") { select("") }
                        .tint(highlightedID == "" ? Color.accentColor : nil).accessibilityIdentifier("useDefaultAICodexModel")
                }
            }
            .padding(16).frame(width: 460)
            .nativeUtilityButtonStyle()
            .onAppear { model.fetchModelsIfNeeded(); resetHighlight() }
            .onChange(of: search) { _, _ in highlightedID = selectableIDs.first }
            .onChange(of: model.models) { _, _ in resetHighlight() }
            .onExitCommand { isPresented = false }
        }
    }
    private func select(_ id: String) { model.selectedModel = id; isPresented = false }
    private func resetHighlight() {
        if let highlightedID, selectableIDs.contains(highlightedID) { return }
        highlightedID = selectableIDs.first
    }
    private func moveSelection(_ direction: Int) {
        let values = selectableIDs
        guard !values.isEmpty else { return }
        let index = highlightedID.flatMap { values.firstIndex(of: $0) } ?? (direction > 0 ? -1 : values.count)
        highlightedID = values[min(max(index + direction, 0), values.count - 1)]
    }
}

/// Keep the text editor focused while arrows choose a result, as in a native
/// searchable menu. No global event monitor or app-wide key interception.
private struct AIModelSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = ModelSearchField()
        field.placeholderString = "Search models or enter an ID"
        field.setAccessibilityLabel("Search models or enter an ID"); field.setAccessibilityIdentifier("aiModelSearch")
        field.maximumRecents = 0; field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { field.delegate = nil }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: AIModelSearchField
        init(_ parent: AIModelSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

private final class ModelSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
    }
}
