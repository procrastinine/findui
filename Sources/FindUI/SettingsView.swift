import SearchBackend
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var showsToolDetails = false
    @State private var readerCapabilities: [ReaderCapability] = []
    @State private var selectedTab = 0
    @FocusState private var defaultDirectoryFocused: Bool
    @State private var defaultDirectoryDraft: String
    @State private var defaultDirectoryOriginal: String?
    // Keep download progress and cancellation alive while switching sections.
    @StateObject private var tikaModel: TikaSettingsModel
    @StateObject private var aiModel: AISearchSettingsModel

    init(viewModel: SearchViewModel, tikaManager: TikaManager = TikaManager(), aiSettingsModel: AISearchSettingsModel? = nil) {
        self.viewModel = viewModel
        _defaultDirectoryDraft = State(initialValue: viewModel.defaultSearchDirectoryPath)
        _tikaModel = StateObject(wrappedValue: TikaSettingsModel(manager: tikaManager))
        _aiModel = StateObject(wrappedValue: aiSettingsModel ?? AISearchSettingsModel())
    }

    var body: some View {
        VStack(spacing: 16) {
            StableSegmentedPicker(title: "Settings sections", selection: $selectedTab,
                values: [0, 1, 2, 3], labels: ["General", "Indexes", "Tools", "AI Search"], widths: [96, 96, 96, 96])
                .frame(width: 394, height: 28)
            Group {
                switch selectedTab {
                case 1: driveIndexesTab
                case 2: toolsTab
                case 3: AISearchSettingsView(model: aiModel)
                default: generalTab
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 600)
        .nativeUtilityButtonStyle()
        .menuStyle(NativeUtilityMenuStyle())
        .onAppear {
            viewModel.refreshVolumes()
            viewModel.chooseManagerDrive(path: viewModel.selectedManagerDrivePath)
        }
        .onChange(of: viewModel.defaultSearchDirectoryPath) { _, path in defaultDirectoryDraft = path }
    }

    private var generalTab: some View {
        Form {
            Section("Default Search Directory") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Directory path", text: $defaultDirectoryDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($defaultDirectoryFocused)
                        .accessibilityIdentifier("defaultSearchDirectory")
                        .onSubmit(commitDefaultDirectory)
                        .onChange(of: defaultDirectoryFocused) { _, focused in
                            if focused { defaultDirectoryOriginal = viewModel.defaultSearchDirectoryPath }
                            else { commitDefaultDirectory() }
                        }

                    if let error = viewModel.defaultDirectoryError {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("defaultDirectoryError")
                    }

                    HStack(spacing: 10) {
                        Button("Choose…") {
                            viewModel.chooseDefaultSearchDirectory()
                        }
                        .nativeUtilityButtonStyle()

                        Button("Use Current Search Directory") {
                            viewModel.useCurrentScopeAsDefaultDirectory()
                        }
                        .nativeUtilityButtonStyle()

                        Button("Use Home") {
                            viewModel.useHomeAsDefaultDirectory()
                        }
                        .nativeUtilityButtonStyle()
                    }

                    Text("New windows and tabs start in this folder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Full Disk Access") {
                FullDiskAccessControls()
            }

            Section("Blank Searches") {
                HStack {
                    Text("When the search is blank")
                    Spacer()
                    UtilityPicker(title: "When the search is blank", selection: $viewModel.emptySearchBehavior,
                                  values: EmptySearchBehavior.allCases, label: \.title)
                        .frame(width: 205)
                        .accessibilityIdentifier("emptySearchBehavior")
                }
                .onChange(of: viewModel.emptySearchBehavior) { _, _ in viewModel.persistEmptySearchPreference() }
                Text("Browse shows immediate files and folders together. Double-click a folder to enter it; use .. to go up. Search terms or file filters start a search.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Editor for Content Matches") {
                HStack {
                    Text("Editor")
                    Spacer()
                    UtilityPicker(title: "Editor", selection: $viewModel.preferredEditor,
                                  values: SourceEditor.allCases, label: { $0.title })
                        .frame(width: 180)
                }
                .onChange(of: viewModel.preferredEditor) { _, _ in viewModel.persistEditorPreference() }
                Text("Automatic uses an installed VS Code, VS Code Insiders, Cursor, or VSCodium. Right-click a content match or use the Inspector to open its line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            if defaultDirectoryFocused { commitDefaultDirectory() }
        }
    }

    private func commitDefaultDirectory() {
        // A folder chosen by a button or another window wins over a delayed blur.
        guard defaultDirectoryOriginal == viewModel.defaultSearchDirectoryPath else { return }
        viewModel.updateDefaultSearchDirectoryPath(defaultDirectoryDraft)
        defaultDirectoryOriginal = viewModel.defaultSearchDirectoryPath
    }

    private var driveIndexesTab: some View {
        HSplitView {
            IndexDriveList(volumes: viewModel.availableVolumes, indexes: viewModel.managedIndexes, selection: Binding(
                get: { viewModel.selectedManagerDrivePath },
                set: { viewModel.chooseManagerDrive(path: $0) }
            ))
            .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)

            VStack(alignment: .leading, spacing: 12) {
                if let index = viewModel.selectedManagerIndex {
                    Text(index.name)
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 10) {
                        Button("Rebuild Index") {
                            viewModel.buildIndexForSelectedManagerDrive()
                        }
                        .nativeUtilityButtonStyle()
                        .disabled(viewModel.isBuildingIndex)
                        if viewModel.isBuildingIndex {
                            Button("Cancel") { viewModel.cancelIndexBuild() }
                        }

                        Button("Delete Index") {
                            viewModel.deleteIndexForSelectedManagerDrive()
                        }
                        .nativeUtilityButtonStyle()
                        .disabled(viewModel.isBuildingIndex)

                        Menu {
                            Button("Show Index File in Finder") { viewModel.revealSelectedManagerIndexFile() }
                            Button("Open Drive in Finder") { viewModel.revealSelectedManagerDrive() }
                        } label: {
                            Text("More")
                        }
                        .nativeUtilityButtonStyle()
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        settingsMetadataRow(label: "Root", value: index.scopePath, monospace: true)
                        settingsMetadataRow(label: "Built with", value: index.engineName)
                        settingsMetadataRow(label: "Updated", value: index.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        settingsMetadataRow(label: "Entries", value: "\(index.entryCount) total · \(index.fileCount) \(index.fileCount == 1 ? "file" : "files") · \(index.folderCount) \(index.folderCount == 1 ? "folder" : "folders")")
                        if let warning = index.warning {
                            settingsMetadataRow(label: "Skipped locations", value: warning)
                        }
                    }
                    Toggle("Keep this index updated while FindUI is open", isOn: Binding(
                        get: { index.automaticRefresh == true },
                        set: { viewModel.setAutomaticIndexRefresh($0, index: index) }
                    ))
                    Button("Copy Terminal Update Command") { viewModel.copyIndexMaintenanceCommand(index) }
                        .help("Run the same index maintenance in a terminal. Only one process can maintain an index at a time.")

                    Divider()

                    HStack {
                        Text("Inspect Index")
                            .font(.headline)
                        Spacer()
                        TextField("Filter indexed paths", text: $viewModel.inspectedIndexFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }

                    Table(viewModel.filteredInspectedEntries) {
                        TableColumn("Name") { entry in
                            Text(entry.name)
                        }
                        .width(min: 120, ideal: 150)

                        TableColumn("Kind") { entry in
                            Text(entry.kind.title)
                        }
                        .width(min: 60, ideal: 70)

                        TableColumn("Path") { entry in
                            Text(entry.relativePath)
                                .lineLimit(1)
                        }
                        .width(min: 180, ideal: 240)
                    }
                    .frame(minHeight: 120)
                    HStack {
                        Text("Page \(viewModel.inspectedPage + 1)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Previous") { viewModel.moveInspectedPage(-1) }.disabled(viewModel.inspectedPage == 0)
                        Button("Next") { viewModel.moveInspectedPage(1) }.disabled(!viewModel.inspectedHasMore)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.selectedManagerDrive?.name ?? "Drive")
                            .font(.title3.weight(.semibold))
                        Text("No index exists for this drive.")
                            .foregroundStyle(.secondary)
                        Button("Build Index") {
                            viewModel.buildIndexForSelectedManagerDrive()
                        }
                        .nativeUtilityButtonStyle()
                        .disabled(viewModel.isBuildingIndex)
                    }
                    Spacer()
                }

                HStack {
                    if viewModel.isBuildingIndex {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.indexManagerStatusMessage)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.leading, 20)
        }
    }

    private var toolsTab: some View {
        Form {
            Section {
                LabeledContent("Archives and packages", value: "Included · libarchive")
                if readerCapabilities.isEmpty {
                    readerStatus("PDF text", tools: ["Poppler"])
                    readerStatus("DOCX, ODT and e-books", tools: ["Pandoc"])
                } else {
                    ForEach(readerCapabilities.filter { ["pdf","pandoc","media"].contains($0.id) }) { reader in
                        HStack {
                            Text(reader.title)
                            Spacer()
                            Label(reader.ready ? "Ready" : "Not installed",systemImage:reader.ready ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(reader.ready ? Color.secondary : Color.orange)
                        }.help(reader.formats.joined(separator:", "))
                    }
                }
                if !viewModel.toolLocations.contains(where: { $0.name == "FFmpeg" }) {
                    SettingsCommandRow(title: "Install media readers", command: "brew install ffmpeg", identifier: "copyMediaReadersCommand")
                }
                if !["Poppler", "Pandoc"].allSatisfy({ name in viewModel.toolLocations.contains { $0.name == name } }) {
                    SettingsCommandRow(title: "Install document readers", command: "brew install poppler pandoc",
                                       identifier: "copyDocumentReadersCommand")
                    Text("Run with Homebrew in Terminal, then refresh.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Document readers").accessibilityIdentifier("documentReadersTitle")
                    UtilityIconButton(title: "Refresh tools", systemImage: "arrow.clockwise") {
                        viewModel.refreshTools()
                        tikaModel.reload()
                        Task { await tikaModel.checkJava() }
                    }
                        .accessibilityIdentifier("refreshDocumentReaders")
                    Spacer(minLength: 0)
                }
            }
            Section("Tika · Office documents") {
                TikaSettingsView(model: tikaModel)
            }
            Section { CustomReaderSettingsView() }
            Section("Search cache") {
                DocumentCacheSettingsView()
            }
            Section {
                ExpandableSection("Installed tool details", isExpanded: $showsToolDetails, identifier: "installedToolDetails") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.toolLocations) { tool in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tool.name).fontWeight(.medium)
                                Text(tool.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("toolPath-" + tool.name)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(readerCapabilities.filter { ["mail","sqlite"].contains($0.id) }) { reader in
                            VStack(alignment:.leading,spacing:4) {
                                Text(reader.title).fontWeight(.medium)
                                Text("Included · " + reader.formats.map { $0.uppercased() }.joined(separator:", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                        if !viewModel.toolLocations.contains(where: { $0.name == "fzf" }) {
                            SettingsCommandRow(title: "Install fuzzy filename search", command: "brew install fzf",
                                               identifier: "copyRecommendedSearchToolsCommand")
                        }
                        Text("FindUI.app includes fd, ripgrep, fzf and its shared search worker. Copy a search command to inspect or run it in Terminal.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .task(id:viewModel.toolLocations.map(\.path)) {
            readerCapabilities = (try? await ReaderRegistry.load()) ?? []
        }
    }

    private func readerStatus(_ label: String, tools: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            let installed = tools.allSatisfy { name in viewModel.toolLocations.contains { $0.name == name } }
            Label(installed ? "Ready" : "Not installed", systemImage: installed ? "checkmark.circle" : "minus.circle")
                .foregroundStyle(installed ? Color.secondary : Color.orange)
        }
    }

    private func settingsMetadataRow(label: String, value: String, monospace: Bool = false) -> some View {
        GridRow(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? .system(size: 12, design: .monospaced) : .body)
                .textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
        }
    }
}
