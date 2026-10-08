import SearchBackend
import SwiftUI
import UniformTypeIdentifiers

struct SearchPresetsView: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SearchPresetKind = .search
    @State private var name = ""
    @State private var saving = false
    @State private var renaming: SearchPreset?
    @State private var rename = ""
    @State private var hoveredPreset: UUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Presets").font(.headline)
                Spacer()
                Menu {
                    Button("Import…", action: importPresets)
                    Button("Export…", action: exportPresets).disabled(viewModel.presets.isEmpty)
                } label: { Text("Manage") }
                .fixedSize()
                .accessibilityLabel("Import or export presets")
            }
            StableSegmentedPicker(title: "Preset kind", selection: $kind, values: SearchPresetKind.allCases,
                                  labels: SearchPresetKind.allCases.map(\.plural), widths: [124, 124, 124])
                .frame(height: 28).accessibilityIdentifier("presetKind")
            Text(kind.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let presets = viewModel.presets.filter { $0.kind == kind }
                    if presets.isEmpty {
                        Text("No saved \(kind.plural.lowercased()) yet.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 95, alignment: .center)
                    }
                    ForEach(presets) { preset in
                        HStack(spacing: 6) {
                            Button {
                                if viewModel.applyPreset(preset) { dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name).fontWeight(.medium)
                                    Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(preset.state.parameterDescription)
                                .background(hoveredPreset == preset.id ? Color.accentColor.opacity(0.1) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .onHover { hoveredPreset = $0 ? preset.id : nil }
                                .accessibilityIdentifier("applyPreset.\(preset.id)")
                            Menu {
                                Button("Rename…") { rename = preset.name; renaming = preset }
                                Button("Replace with Current \(kind.title)") { viewModel.savePreset(name: preset.name, kind: kind, replacing: preset.id) }
                                Divider()
                                Button("Delete", role: .destructive) { viewModel.deletePreset(preset) }
                            } label: { Image(systemName: "ellipsis").frame(width: 14, height: 18) }.menuIndicator(.hidden).fixedSize().padding(.trailing, 4)
                                .accessibilityLabel("Manage \(preset.name)")
                        }
                    }
                }
            }.frame(height: max(96, min(230, CGFloat(viewModel.presets.filter { $0.kind == kind }.count) * 56)))
            Divider()
            if saving {
                HStack {
                    TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .task {
                            // The conditional field must join the popover's
                            // focus tree before requesting its field editor.
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            nameFocused = true
                        }
                        .accessibilityIdentifier("presetName").onSubmit(save)
                    Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .nativePrimaryButtonStyle().keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("savePreset")
                    Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                }
            } else {
                Button("Save Current \(kind.title)…") {
                    name = kind == .scope ? viewModel.searchState.resultScope?.name ?? viewModel.scopeURL.lastPathComponent
                        : viewModel.searchState.title
                    saving = true
                }
                    .accessibilityIdentifier("newPreset")
            }
            if let error = viewModel.presetError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(16).frame(width: 420).font(.system(size: 12)).nativeUtilityButtonStyle()
        .menuStyle(NativeUtilityMenuStyle())
        .onAppear { viewModel.reloadPresets() }
        .onChange(of: kind) { _, _ in saving = false; viewModel.presetError = nil }
        .onChange(of: saving) { _, value in if !value { nameFocused = false } }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $rename)
            Button("Save") { if let preset = renaming { viewModel.renamePreset(preset, name: rename) }; renaming = nil }
                .disabled(rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
    private func save() {
        viewModel.savePreset(name: name, kind: kind)
        if viewModel.presetError == nil { saving = false }
    }
    private func exportPresets() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "FindUI Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(viewModel.presetStore.read()).write(to: url, options: .atomic) }
        catch { viewModel.presetError = error.localizedDescription }
    }
    private func importPresets() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try JSONDecoder().decode(SearchPresetCollection.self, from: Data(contentsOf: url)); try incoming.validate()
            _ = try viewModel.presetStore.importPresets(incoming)
            viewModel.reloadPresets()
        } catch { viewModel.presetError = error.localizedDescription }
    }
}
