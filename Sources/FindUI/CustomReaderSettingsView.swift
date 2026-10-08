import AppKit
import SearchBackend
import SearchCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomReaderSettingsView: View {
    @State private var readers: [ReaderAdapter] = []
    @State private var expanded = false
    @State private var editing: ReaderAdapter?
    @State private var status: String?
    var body: some View {
        ExpandableSection("Custom readers", isExpanded: $expanded, identifier: "customReaders") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Choose installed programs that return plain UTF-8 text. Enable them per search in Scope & Options."
                )
                .font(.caption).foregroundStyle(.secondary)
                ForEach(readers) { reader in
                    HStack(alignment: .top) {
                        Toggle(
                            reader.title,
                            isOn: Binding(
                                get: { reader.enabled },
                                set: { value in
                                    change { items in
                                        if let i = items.firstIndex(where: { $0.id == reader.id }) {
                                            items[i].enabled = value
                                        }
                                    }
                                })
                        ).help(reader.extensions.map { "." + $0 }.joined(separator: ", "))
                        Spacer()
                        Button("Edit") { editing = reader }.accessibilityIdentifier("editCustomReader.\(reader.id)")
                        Button("Remove") { change { $0.removeAll { $0.id == reader.id } } }
                    }
                }
                HStack {
                    Button("Add Reader…") { editing = ReaderAdapter() }
                    Button("Import…") { importReaders() }
                    Button("Export…") { exportReaders() }.disabled(readers.isEmpty)
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { reload() }
        .sheet(item: $editing) { reader in
            ReaderEditor(reader: reader) { value in
                try ReaderConfiguration().update { items in
                    if let i = items.firstIndex(where: { $0.id == value.id }) {
                        items[i] = value
                    } else {
                        items.append(value)
                    }
                }
                reload()
            }
        }
    }
    private func reload() {
        do {
            readers = try ReaderConfiguration().load()
            status = nil
        } catch { status = error.localizedDescription }
    }
    private func change(_ edit: (inout [ReaderAdapter]) throws -> Void) {
        do {
            readers = try ReaderConfiguration().update(edit)
            status = nil
        } catch { status = error.localizedDescription }
    }
    private func importReaders() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ReaderConfiguration(location: url).load()
            change { items in
                for reader in imported {
                    if let i = items.firstIndex(where: { $0.id == reader.id }) {
                        items[i] = reader
                    } else {
                        items.append(reader)
                    }
                }
            }
        } catch { status = error.localizedDescription }
    }
    private func exportReaders() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "findui-readers.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(readers).write(to: url, options: .atomic)
            status = "Reader settings exported."
        } catch { status = error.localizedDescription }
    }
}

private struct ReaderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var reader: ReaderAdapter
    @State private var extensions = ""
    @State private var arguments = ""
    @State private var error: String?
    let save: (ReaderAdapter) throws -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(reader.title.isEmpty ? "Add Reader" : "Edit Reader").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $reader.title)
                TextField("File extensions", text: $extensions, prompt: Text("abc, xyz"))
                HStack {
                    TextField("Program", text: $reader.executable)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { reader.executable = url.path }
                    }
                }
            }
            Text("Arguments · one per line").font(.headline)
            TextEditor(text: $arguments).font(.body.monospaced()).frame(height: 120)
                .border(Color.secondary.opacity(0.3)).accessibilityLabel("Reader arguments")
            Text(
                "Use {path} for the file. Arguments are passed literally; shell quoting and pipes are not interpreted."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelCustomReader")
                Button("Save") {
                    reader.extensions = extensions.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map {
                        String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    }
                    reader.arguments = arguments.components(separatedBy: "\n")
                    do {
                        try reader.validate()
                        guard FileManager.default.isExecutableFile(atPath: reader.executable) else {
                            throw SearchServiceError.commandFailed("Choose an executable program.")
                        }
                        try save(reader)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("saveCustomReader")
            }
        }.padding(22).frame(width: 520)
            .onAppear {
                extensions = reader.extensions.joined(separator: ", ")
                arguments = reader.arguments.joined(separator: "\n")
            }
    }
}
