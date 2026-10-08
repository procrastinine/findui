import SearchBackend
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var sortOrder: [KeyPathComparator<SearchResult>] = []
    @State private var columnCustomization = TableColumnCustomization<SearchResult>()
    @State private var didInitializeColumns = false
    @State private var isHistoryPresented = true
    @State private var directoryPath = ""
    @FocusState private var isScopeFocused: Bool
    @State private var scopeEditRevision: Int?
    @State private var scopeEditOriginalPath: String?
    @State private var isFiltersPresented = false
    @State private var isPresetsPresented = false
    @State private var isSyntaxHelpPresented = false
    @State private var isAISearchPresented = false
    private let aiPreferences: UserDefaults
    private let aiSettingsModel: AISearchSettingsModel?
    private let aiClient: (any AISearchGenerating)?
    @State private var isCommandPresented = false
    @State private var isCommandImportPresented = false
    @FocusState private var isCommandImportFocused: Bool
    @State private var commandInput = ""
    @State private var commandInputError: String?
    @State private var runNativeCommand = false
    @State private var focusedSearchInput: String?
    @State private var searchFocusRequest = 0
    @State private var collapsedContentFiles = Set<String>()
    @State private var sortedResults: [SearchResult] = []
    @State private var contentGroups: [ContentResultGroup] = []
    @State private var groupMatchCounts: [UUID: Int] = [:]
    @State private var resultsLeading: CGFloat = 0
    @State private var lastQuickLookURL: URL?

    init(viewModel: SearchViewModel, aiPreferences: UserDefaults = AISearchSettings.preferences, aiSettingsModel: AISearchSettingsModel? = nil,
         aiClient: (any AISearchGenerating)? = nil) {
        self.viewModel = viewModel; self.aiPreferences = aiPreferences
        self.aiSettingsModel = aiSettingsModel
        self.aiClient = aiClient
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            SearchSplitView(
                isHistoryPresented: $isHistoryPresented,
                isInspectorPresented: $viewModel.isInspectorPresented,
                history: HistorySidebarView(viewModel: viewModel)
                    .equatable()
                    .background(Color(nsColor: .controlBackgroundColor)),
                results: resultsPane
                    .background(ResultsPanePosition { resultsLeading = $0 }.allowsHitTesting(false))
                    .menuStyle(NativeUtilityMenuStyle()),
                inspector: Group {
                    if viewModel.isInspectorPresented { InfoInspectorView(viewModel: viewModel) }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            footer
        }
        .frame(minWidth: 1000, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(UnifiedSearchTitlebar().allowsHitTesting(false))
        .menuStyle(NativeUtilityMenuStyle())
        .sheet(item: $viewModel.fileExplanation) { SearchExplanationView(report: $0) }
        .sheet(isPresented: $isAISearchPresented) {
            AISearchEntrySheet(state: viewModel.searchState, preferences: aiPreferences, settingsModel: aiSettingsModel, client: aiClient) {
                viewModel.applyGeneratedSearch($0)
            }
        }
        .background {
            Button("Focus Search") { searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.quickLookURL != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.quickLookURL = nil
                    }
                }
            )
        ) {
            // Keep the content and its geometry through the closing animation.
            // Clearing it immediately made the Close control jump on dismissal.
            if let url = viewModel.quickLookURL ?? lastQuickLookURL {
                QuickLookSheet(
                    url: url,
                    title: quickLookTitle(for: url),
                    subtitle: quickLookPositionText,
                    canMoveUp: viewModel.canMoveQuickLookSelection(in: displayedResults, by: -1),
                    canMoveDown: viewModel.canMoveQuickLookSelection(in: displayedResults, by: 1),
                    onMoveUp: {
                        viewModel.moveQuickLookSelection(in: displayedResults, by: -1)
                    },
                    onMoveDown: {
                        viewModel.moveQuickLookSelection(in: displayedResults, by: 1)
                    }
                ) {
                    viewModel.closeQuickLook()
                }
                .frame(minWidth: 680, minHeight: 480)
            }
        }
        .toolbar {
            ToolbarItem {
                if !viewModel.isBrowsingDirectory, !sortOrder.isEmpty {
                    Button("Search Order") { sortOrder = [] }
                        .help("Restore the command's result order. Fuzzy searches use fzf relevance ranking.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { isAISearchPresented = true } label: { Image(systemName: "sparkles") }
                    .help("Describe a search with AI").accessibilityLabel("AI Search")
                    .accessibilityIdentifier("openAISearch")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isHistoryPresented.toggle()
                } label: {
                    Label("Toggle History", systemImage: "sidebar.left")
                }
                .accessibilityIdentifier("toggleHistorySidebar")
                Button {
                    viewModel.isInspectorPresented.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
                .accessibilityIdentifier("toggleInspectorSidebar")
            }
        }
        .onReceive(viewModel.$results) { refreshPresentation($0) }
        .onChange(of: viewModel.quickLookURL) { _, url in
            if let url { lastQuickLookURL = url }
        }
        .onChange(of: sortOrder) { _, _ in
            viewModel.sortResults(sortOrder)
            refreshPresentation(viewModel.results)
        }
        .onChange(of: viewModel.groupContentMatches) { _, _ in refreshPresentation(viewModel.results) }
        .onChange(of: viewModel.searchStateRevision) { _, _ in
            commandInput = viewModel.commandSearch?.command ?? viewModel.searchState.sourceCommand ?? ""
            commandInputError = nil
        }
        .onChange(of: viewModel.searchRules != nil) { _, _ in
            // The native fields are replaced when changing editor modes.
            focusedSearchInput = nil
        }
        .onChange(of: focusedSearchInput) { _, input in
            // AppKit fields can take the editor before SwiftUI delivers the
            // folder field's FocusState change. Commit its draft on that handoff.
            if input != nil { commitScope() }
        }
        .onChange(of: viewModel.searchState) { previous, current in
            if previous.useIndex != current.useIndex { viewModel.handleIndexedToggleChanged() }
            if previous.includeHidden != current.includeHidden { viewModel.persistDisplayPreferences() }
            if previous.traversal != current.traversal { viewModel.persistTraversalPreferences() }
            viewModel.scheduleSearchAfterControlChange()
            viewModel.refreshWordStatus()
        }
        .onChange(of: viewModel.selectedResultIDs) { _, selection in
            let selectedGroups = contentGroups.filter {
                collapsedContentFiles.contains($0.id) && $0.matches.dropFirst().contains(where: { selection.contains($0.id) })
            }.map(\.id)
            if !selectedGroups.isEmpty {
                Task { @MainActor in
                    collapsedContentFiles.subtract(selectedGroups)
                }
            }
        }
        .onChange(of: viewModel.scopeURL) { _, newValue in
            directoryPath = newValue.path
            scopeEditRevision = nil; scopeEditOriginalPath = nil
        }
        .onAppear {
            guard !didInitializeColumns else {
                directoryPath = viewModel.scopeURL.path
                return
            }
            directoryPath = viewModel.scopeURL.path
            columnCustomization[visibility: "icon"] = .visible
            columnCustomization[visibility: "created"] = .hidden
            columnCustomization[visibility: "opened"] = .hidden
            columnCustomization[visibility: "added"] = .hidden
            didInitializeColumns = true
            viewModel.scheduleSearch(immediate: true)
        }
        .confirmationDialog(
            "Index Current Drive?",
            isPresented: $viewModel.isIndexPromptPresented,
            titleVisibility: .visible
        ) {
            Button("Index \(viewModel.currentDrive.name)") {
                viewModel.confirmIndexCurrentDrive()
            }
            Button("Not Now", role: .cancel) {
                viewModel.cancelIndexPrompt()
            }
        } message: {
            Text("Indexed search works per drive. Build an index for \(viewModel.currentDrive.name) now?")
        }
        .sheet(isPresented: $viewModel.isPermissionHelpPresented) {
            FullDiskAccessSheet()
        }
        .alert("Couldn’t Open Editor", isPresented: Binding(
            get: { viewModel.editorError != nil },
            set: { if !$0 { viewModel.editorError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.editorError = nil }
        } message: {
            Text(viewModel.editorError ?? "")
        }
        .alert("Couldn’t Export Results", isPresented: Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    private func refreshPresentation(_ results: [SearchResult]) {
        let parentEntry = results.first(where: \.isParentDirectoryEntry)
        let sortableResults = results.filter { !$0.isParentDirectoryEntry }
        let ordered = viewModel.usesStoredResultOrder ? sortableResults : sortOrder.isEmpty
            ? (viewModel.isBrowsingDirectory ? sortableResults : sortableResults.sorted(by: SearchResult.bestMatchFirst))
            : sortableResults.sorted(using: sortOrder)
        sortedResults = parentEntry.map { [$0] + ordered } ?? ordered
        contentGroups = viewModel.producesContentLines && !viewModel.isBrowsingDirectory
            ? ContentResultGroup.groups(from: sortedResults) : []
        groupMatchCounts = Dictionary(uniqueKeysWithValues: contentGroups.map { ($0.first.id, viewModel.resultTotals.documentCounts[$0.id] ?? $0.matches.count) })
    }

    private var isGroupingContents: Bool {
        viewModel.producesContentLines && viewModel.groupContentMatches && !viewModel.isBrowsingDirectory
    }

    private var displayedResults: [SearchResult] {
        guard isGroupingContents else { return sortedResults }
        return contentGroups.flatMap { collapsedContentFiles.contains($0.id) ? [$0.first] : $0.matches }
    }

    private var currentQuickLookResult: SearchResult? {
        if let selectedResultID = viewModel.selectedResultID,
           let result = displayedResults.first(where: { $0.id == selectedResultID }) {
            return result
        }

        if let quickLookURL = viewModel.quickLookURL,
           let result = displayedResults.first(where: { $0.url == quickLookURL }) {
            return result
        }

        return nil
    }

    private var quickLookPositionText: String? {
        guard
            let result = currentQuickLookResult,
            let index = displayedResults.firstIndex(where: { $0.id == result.id })
        else {
            return nil
        }
        return "\(index + 1) of \(displayedResults.count)  Use ↑ and ↓ to navigate"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = viewModel.commandSearch {
                HStack(spacing: 12) {
                    Text("Command search").fontWeight(.medium)
                    Spacer()
                    Button("Edit Command…") {
                        commandInput = command.command; runNativeCommand = true
                        commandInputError = nil; isCommandImportPresented = true
                    }.accessibilityIdentifier("editNativeCommand")
                    Button("Use Search Controls") { viewModel.useSearchControls() }
                        .accessibilityIdentifier("leaveNativeCommand")
                    searchButton
                }.frame(height: 40)
                Text(command.command).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(4).help(command.command).accessibilityIdentifier("nativeCommandText")
                Text("Working folder: " + command.directory).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            } else {
            HStack(spacing: 12) {
                if viewModel.searchRules == nil {
                Text("Find").fontWeight(.medium).frame(width: 72, alignment: .leading)
                StableSegmentedPicker(title: "Search mode", selection: Binding(
                    get: { viewModel.mode == .contents ? .files : viewModel.mode },
                    set: { if viewModel.mode != .contents { viewModel.mode = $0 } }
                ), values: [.files, .folders, .everything], labels: ["Files", "Directories", "Files & Directories"],
                widths: [60, 100, 154], disabled: viewModel.mode == .contents ? [.folders, .everything] : [])
                    .frame(width: 322, height: 28)
                } else { Text("Search rules").fontWeight(.medium) }
                Spacer(minLength: 8)
                syntaxHelp
                matchingControls
                Button {
                    if viewModel.searchRules == nil { viewModel.enableRules() }
                    else { viewModel.useCompactControls() }
                } label: {
                    Text(viewModel.searchRules == nil ? "Rules…" : "Simple controls").frame(width: viewModel.searchRules == nil ? 56 : 102)
                }
                .disabled(viewModel.searchRules != nil && !viewModel.canUseCompactControls)
                .help(viewModel.searchRules == nil
                      ? "Combine filename, type, size, date and content conditions with All, Any, or None."
                      : "Available when every condition fits in the simple controls without changing its meaning.")
                .accessibilityIdentifier(viewModel.searchRules == nil ? "expandSearchRules" : "useSimpleSearchControls")
                searchButton
            }.frame(height: 40)
            if viewModel.searchRules != nil {
                SearchRuleEditor(viewModel: viewModel, focusRequest: searchFocusRequest)
            } else {
            HStack(spacing: 12) {
                Text(viewModel.filenameUsesExpression ? "Name / path" : "Filename")
                    .foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                searchField(text: Binding(get: { viewModel.filenameInput }, set: { viewModel.filenameInput = $0 }),
                            placeholder: viewModel.filenameInputMatching == .quick ? "Any filename · e.g. report or *.pdf"
                                : viewModel.refinements.nameMatching == .glob ? "Any filename · e.g. *.swift or *report*" : "Any filename",
                            identifier: "filenameInput", focusRequest: viewModel.mode == .contents ? 0 : searchFocusRequest)
                UtilityPicker(title: "Filename matching", selection: Binding(
                    get: { viewModel.filenameInputMatching }, set: { viewModel.filenameInputMatching = $0 }),
                              values: viewModel.filenameMatchingChoices, label: \.title).frame(width: 112)
                    .help(viewModel.filenameUsesExpression
                          ? "This expression searches names and paths. Clear it for any filename, or choose a matching option to search filenames only."
                          : "Quick finds literal text anywhere in the filename, or uses wildcard matching when you type * or ?. Contains always treats punctuation literally. Exact and Wildcard match the whole filename. Regex uses a regular expression. Fuzzy matches characters in order.")
                Toggle("Match case", isOn: Binding(
                    get: { viewModel.refinements.fileCaseSensitive ?? viewModel.caseSensitive },
                    set: { viewModel.refinements.fileCaseSensitive = $0 }
                )).toggleStyle(.checkbox).frame(width: 100, alignment: .leading)
                filenamePresets
            }.frame(height: 46)
            HStack(spacing: 12) {
                Text("Contents").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                searchField(text: Binding(get: { viewModel.contentsInput }, set: { viewModel.contentsInput = $0 }),
                    placeholder: viewModel.refinements.contentSource == .indexedDocumentText ? "Text in indexed documents, PDFs, presentations…" : "Text inside files · leave blank to search names only",
                    identifier: "searchInput", focusRequest: viewModel.mode == .contents ? searchFocusRequest : 0)
                    .disabled(viewModel.mode == .folders)
                UtilityPicker(title: "Content matching", selection: Binding(
                    get: { viewModel.contentMatchingChoice }, set: { viewModel.contentMatchingChoice = $0 }),
                              values: viewModel.contentMatchingChoices, label: \.title).frame(width: 112)
                    .help("Expression requires every space-separated term, supports quoted phrases and -excluded terms. Literal searches the entire text as one phrase. Regex uses a regular expression. Spotlight text searches the macOS index. Indexed words searches a prepared local index with relevance ranking; prepare it in Scope & Options → Content matches. Enable document reading or archive expansion in Scope & Options. Use Rules for OR groups.")
                    .disabled(viewModel.mode == .folders)
                Toggle("Match case", isOn: Binding(
                    get: { viewModel.caseSensitive },
                    set: {
                        viewModel.refinements.fileCaseSensitive = viewModel.refinements.fileCaseSensitive ?? viewModel.caseSensitive
                        viewModel.caseSensitive = $0
                    }
                )).toggleStyle(.checkbox)
                    .frame(width: 100, alignment: .leading).disabled(viewModel.mode == .folders || viewModel.refinements.wordSearch == true)
                Menu {
                    ForEach(SearchPatternPresets.all) { preset in
                        Button("\(preset.title) · \(preset.example)") {
                            var state = viewModel.searchState
                            state.applyContentPreset(preset)
                            viewModel.restoreSearchState(state)
                        }.help(preset.detail)
                    }
                } label: {
                    Label("Patterns", systemImage: "text.magnifyingglass")
                }
                .frame(width: 112).disabled(viewModel.mode == .folders)
                .help("Insert a common regex pattern into Contents")
                .accessibilityIdentifier("contentPatternPresets")
            }.frame(height: 46)
            }
            if let scope = viewModel.searchState.resultScope {
                HStack(spacing: 10) {
                    Text("In results").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
                    Text(scope.name).lineLimit(1).truncationMode(.middle).help(scope.name)
                    Text("\(scope.count) \(scope.count == 1 ? "item" : "items")").foregroundStyle(.secondary).fixedSize()
                    Spacer()
                    Button("Use Folder") { viewModel.clearResultScope() }
                        .help("Return to searching \(viewModel.scopeURL.path)")
                        .accessibilityIdentifier("clearResultScope")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("resultScopeBanner")
            } else {
                HStack(spacing: 10) {
                    Text("In folder").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                    scopeField
                    Button {
                        guard commitScope() else { return }
                        viewModel.openScopeInFinder()
                    } label: { Image(systemName: "folder").frame(width: 18, height: 18) }
                        .help("Open folder in Finder")
                        .accessibilityLabel("Open folder in Finder")
                        .accessibilityIdentifier("openScopeFinder")
                    Button {
                        guard commitScope() else { return }
                        viewModel.openScopeInTerminal()
                    } label: { Image(systemName: "terminal").frame(width: 18, height: 18) }
                        .help("Open folder in Terminal")
                        .accessibilityLabel("Open folder in Terminal")
                        .accessibilityIdentifier("openScopeTerminal")
                    Button("Choose…") { viewModel.chooseFolder() }.fixedSize()
                    Button(primaryDriveName) { viewModel.usePrimaryDriveScope() }.fixedSize()
                }
            }
            if let patterns = viewModel.traversal.pathRules, !patterns.isEmpty {
                HStack(spacing: 10) {
                    Text("Path rules").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                    Text(patterns.joined(separator: " · ")).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(patterns.joined(separator: "\n"))
                    Button("Edit…") { isFiltersPresented = true }
                    Button("Clear") { viewModel.traversal.pathRules = nil }
                        .accessibilityIdentifier("clearPathRules")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("pathRulesBanner")
            }
            if viewModel.useIndex { indexControls }
            if viewModel.refinements.wordSearch == true {
                HStack(spacing: 8) {
                    Text("Word index").foregroundStyle(.secondary).frame(width:72,alignment:.leading)
                    Label(viewModel.wordIndexStatus?.title ?? "Prepared words", systemImage: viewModel.wordIndexStatus?.state == "updated" ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(.secondary)
                        .help(viewModel.wordIndexStatus?.message ?? "Prepare words in the selected folders to search their contents.")
                    if viewModel.preparingContents { ProgressView().controlSize(.small) }
                    Button(viewModel.preparingContents ? "Cancel" : "Update") { viewModel.prepareContentIndex() }
                        .accessibilityIdentifier("updateActiveWordIndex")
                    Spacer(minLength:0)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("wordIndexStatus")
            }
            }
        }
        .font(.system(size: 12))
        .nativeUtilityButtonStyle()
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func searchField(text: Binding<String>, placeholder: String,
                             identifier: String, focusRequest: Int) -> some View {
        SearchInputView(text: text, focusedInput: $focusedSearchInput, focusRequest: focusRequest,
                        placeholder: placeholder, identifier: identifier, accessibilityLabel: identifier == "filenameInput" ? "Filename" : "Contents",
                        completionProvider: wordCompletionProvider(for:identifier)) { submitSearch() }
            .padding(.horizontal, 10).frame(height: 46)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focusedSearchInput == identifier ? Color.accentColor : .secondary.opacity(0.35),
                                  lineWidth: focusedSearchInput == identifier ? 2 : 1).allowsHitTesting(false)
            }
            .layoutPriority(1)
    }

    private func wordCompletionProvider(for identifier: String) -> (@MainActor @Sendable (String) async -> [String])? {
        guard identifier == "searchInput", viewModel.refinements.wordSearch == true else { return nil }
        return { [viewModel] text in await viewModel.wordCompletions(text) }
    }

    private var searchButton: some View {
        Button {
            if viewModel.isSearching { viewModel.stopSearch() }
            else { submitSearch() }
        } label: {
            Label(viewModel.isSearching ? "Stop search" : "Search", systemImage: viewModel.isSearching ? "stop.fill" : "magnifyingglass")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .nativePrimaryButtonStyle().buttonBorderShape(.circle).controlSize(.large)
        .frame(width: 40, height: 40)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(viewModel.isSearching ? "Stop search (⌘↩)" : "Search now (⌘↩)")
        .accessibilityIdentifier("searchButton")
    }

    private func submitSearch() {
        guard commitScope() else { return }
        viewModel.scheduleSearch(immediate: true)
    }

    @discardableResult
    private func commitScope() -> Bool {
        guard let revision = scopeEditRevision else { return true }
        // Restoring history or choosing a folder wins over a delayed blur from
        // the previous field. Never apply an old draft to a different search.
        guard revision == viewModel.searchStateRevision, scopeEditOriginalPath == viewModel.scopeURL.path else {
            directoryPath = viewModel.scopeURL.path
            scopeEditRevision = nil; scopeEditOriginalPath = nil
            return true
        }
        guard viewModel.updateScopePath(directoryPath) else { return false }
        directoryPath = viewModel.scopeURL.path
        scopeEditRevision = nil; scopeEditOriginalPath = nil
        return true
    }

    private func importCommand() {
        guard commitScope() else { return }
        do {
            try viewModel.importCommand(commandInput, runNative: runNativeCommand)
            commandInputError = nil
            isCommandImportPresented = false
            searchFocusRequest += 1
        } catch {
            commandInputError = error.localizedDescription
        }
    }

    private var matchingControls: some View {
        HStack(spacing: 10) {
            Button { isFiltersPresented.toggle() } label: {
                Label("Scope & Options", systemImage: viewModel.hasAdditionalOptions
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .nativeUtilityButtonStyle()
            .fixedSize()
            .accessibilityIdentifier("searchScopeOptions")
            .popover(isPresented: $isFiltersPresented) { SearchOptionsView(viewModel: viewModel) }
            Button { isPresetsPresented.toggle() } label: { Label("Presets", systemImage: "bookmark") }
                .fixedSize().accessibilityIdentifier("searchPresets")
                .popover(isPresented: $isPresetsPresented) { SearchPresetsView(viewModel: viewModel) }
        }
    }

    private var filenamePresets: some View {
        Menu {
            Button("Any file type") { viewModel.refinements.extensions = "" }
            Divider()
            ForEach(SearchFileTypes.groups.filter { $0.category != "language" }) { group in
                Button(group.title) { viewModel.selectFileTypePreset(group) }
                    .help(group.extensions.map { "*." + $0 }.joined(separator: ", "))
            }
            Menu("Languages") {
                ForEach(SearchFileTypes.groups.filter { $0.category == "language" }) { group in
                    Button(group.title) { viewModel.selectFileTypePreset(group) }
                        .help(group.extensions.map { "*." + $0 }.joined(separator: ", "))
                }
            }
            Divider()
            Button("Custom extensions…") { isFiltersPresented = true }
        } label: {
            Text(viewModel.fileTypePresetTitle).lineLimit(1).truncationMode(.tail)
        }
        .frame(width: 112).disabled(viewModel.mode == .folders)
        .help(viewModel.refinements.extensions.isEmpty
              ? "Filter by file type; keeps the filename query. Choose Images, Documents, a language, or custom extensions."
              : "File types: \(viewModel.refinements.extensions). Matches any listed extension, together with the filename query.")
        .accessibilityLabel("File types: \(viewModel.fileTypePresetTitle)")
        .accessibilityIdentifier("filenamePresets")
    }

    private var syntaxHelp: some View {
        Button { isSyntaxHelpPresented.toggle() } label: {
            Image(systemName: "questionmark")
        }
        .nativeUtilityButtonStyle()
        .buttonBorderShape(.circle)
        .foregroundStyle(.secondary)
        .help("Search syntax and examples")
        .accessibilityLabel("Search syntax and examples")
        .popover(isPresented: $isSyntaxHelpPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Search Examples").font(.headline)
                if viewModel.searchRules != nil {
                    Text("Each row is a condition. Choose Filename, Contents, File type, Date, or another type; combine any of them in the same group.")
                    Text("Match All requires every condition; Any accepts any condition; None excludes matching conditions. Add a group to combine those rules.")
                        .foregroundStyle(.secondary)
                    Text("((Swift AND TODO) OR (Markdown AND FIXME)) AND modified this week").font(.system(.body, design: .monospaced))
                    Text("Content conditions can match on the same line or anywhere in the same file. Scope & Options applies folders and traversal settings to the whole search.")
                        .foregroundStyle(.secondary)
                } else {
                Text("Find chooses files, directories, or both. Filename narrows those results; an empty filename includes every name.")
                Text("Filename: report or *.swift  ·  Quick").font(.system(.body, design: .monospaced))
                Text("Quick searches for bare text anywhere in a filename. Typing * or ? makes the whole input a wildcard pattern. Use Contains to search for a literal * or ?; use Exact to match the entire name.").foregroundStyle(.secondary)
                Text("Enter timeout in Contents to search inside the matching Swift files. Leave Filename blank to search contents of every file; leave Contents blank to search names only.").foregroundStyle(.secondary)
                Text("Contents: retry timeout").font(.system(.body, design: .monospaced))
                Text("Expression matches both words on the same line. Use quotes for a phrase and -debug to exclude a term. Literal matches the entire input as one phrase, including punctuation. Use Rules for AND/OR groups; parentheses and OR are not Expression operators.").foregroundStyle(.secondary)
                Text("Filename: srchvm  ·  Fuzzy").font(.system(.body, design: .monospaced))
                Text("Matches filename characters in order, such as SearchViewModel.swift. Scope & Options adds path, size, date, and exclusion conditions. File types beside Filename selects extensions without replacing your filename query.").foregroundStyle(.secondary)
                }
                Text("Import Command accepts fd, rg, find, and supported search pipelines. It fills the controls when their meaning can be preserved, or offers command mode for supported native searches.")
            }
            .font(.system(size: 12))
            .padding(20)
            .frame(width: 410)
        }
    }

    private var indexControls: some View {
        HStack(spacing: 10) {
            if let index = viewModel.currentDriveIndex {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Label("Indexed \(index.updatedAt.formatted(.relative(presentation: .named)))", systemImage: "internaldrive")
                        .help("Last refreshed: \(index.updatedAt.formatted())")
                }
                if let warning = index.warning {
                    Label("Partial index", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(warning)
                }
                if viewModel.currentIndexNeedsRefresh {
                    Text("Scan options changed — refresh needed").foregroundStyle(.orange)
                }
                Spacer()
                if viewModel.isBuildingIndex {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { viewModel.cancelIndexBuild() }
                } else {
                    Button("Refresh Index") { viewModel.refreshCurrentIndex() }
                }
            } else {
                Text(indexStatusText)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }

    private var scopeField: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.isScopeDropTargeted ? "folder.badge.plus" : "folder")
                .foregroundStyle(viewModel.isScopeDropTargeted ? Color.accentColor : .secondary)

            TextField("Directory path", text: Binding(get: { directoryPath }, set: {
                if scopeEditRevision == nil {
                    scopeEditRevision = viewModel.searchStateRevision
                    scopeEditOriginalPath = viewModel.scopeURL.path
                }
                directoryPath = $0
            }))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .focused($isScopeFocused)
                .accessibilityIdentifier("scopePath")
                .accessibilityLabel("Search folder")
                .onSubmit { commitScope() }
                .onChange(of: isScopeFocused) { _, focused in
                    if !focused { commitScope() }
                }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    viewModel.isScopeDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewModel.isScopeDropTargeted) { providers in
            viewModel.acceptDroppedProviders(providers)
        }
    }

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let output = viewModel.commandOutput {
                CommandOutputView(output: output, failure: viewModel.commandError, isRunning: viewModel.isSearching)
            } else if displayedResults.isEmpty, let error = viewModel.commandError {
                CommandOutputView(output: CommandTextOutput(), failure: error, isRunning: false)
            } else {
            resultActionsBar
            if let error = viewModel.commandError { CommandFailureView(message: error) }
            if displayedResults.isEmpty {
                emptyResultsView
            } else {
                Table(
                    of: SearchResult.self,
                    selection: $viewModel.selectedResultIDs,
                    sortOrder: $sortOrder,
                    columnCustomization: $columnCustomization
                ) {
                    TableColumn("") { result in
                        ResultIconView(result: result)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .width(min: isGroupingContents ? 60 : 28, ideal: isGroupingContents ? 60 : 28, max: isGroupingContents ? 68 : 32)
                    .customizationID("icon")

                    TableColumn("Name", value: \.name) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(result.displayName).lineLimit(1)
                                if isGroupingContents, let count = groupMatchCounts[result.id] {
                                    Text(count == 1 ? "1 match" : "\(count) matches" + (viewModel.resultPageCount > 1 ? " total" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let snippet = result.snippet, !snippet.isEmpty {
                                HStack(spacing: 6) {
                                    if let line = result.lineNumber {
                                        Text("\(line):").monospacedDigit()
                                    }
                                    if let origin = result.extractedOrigin {
                                        Text(origin.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    HighlightedSnippet(result: result)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(min: 220, ideal: 300)
                    .customizationID("name")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn(ResultPresentationLabels.kind, value: \.sortableKind) { result in
                        Text(result.typeDescription ?? result.kind.title)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(min: 90, ideal: 110)
                    .customizationID("type")

                    TableColumn(ResultPresentationLabels.path, value: \.path) { result in
                        Text(result.path)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(min: 320, ideal: 460)
                    .customizationID("folder")

                    TableColumn(ResultMetadataLabels.modified, value: \.sortableModifiedAt) { result in
                        if let modifiedAt = result.modifiedAt {
                            Text(modifiedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .width(min: 170, ideal: 200)
                    .customizationID("modified")

                    TableColumn("Size", value: \.sortableSize) { result in
                        if let size = result.size {
                            Text(ByteCountFormatStyle().format(size))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .width(min: 90, ideal: 110)
                    .customizationID("size")

                    TableColumn(ResultMetadataLabels.created, value: \.sortableCreatedAt) { result in
                        if let createdAt = result.createdAt {
                            Text(createdAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .width(min: 170, ideal: 200)
                    .customizationID("created")

                    TableColumn(ResultMetadataLabels.added, value: \.sortableAddedAt) { result in
                        if let addedAt = result.addedAt {
                            Text(addedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .width(min: 170, ideal: 200)
                    .customizationID("added")

                    TableColumn(ResultMetadataLabels.lastOpened, value: \.sortableLastOpenedAt) { result in
                        if let lastOpenedAt = result.lastOpenedAt {
                            Text(lastOpenedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .width(min: 170, ideal: 210)
                    .customizationID("opened")
                } rows: {
                    if isGroupingContents {
                        ForEach(contentGroups) { group in
                            if group.matches.count > 1 {
                                DisclosureTableRow(group.first, isExpanded: Binding(
                                    get: { !collapsedContentFiles.contains(group.id) },
                                    set: { expanded in
                                        // AppKit calls this binding from its outline delegate.
                                        // Update SwiftUI after that callback finishes.
                                        Task { @MainActor in
                                            if expanded { collapsedContentFiles.remove(group.id) }
                                            else { collapsedContentFiles.insert(group.id) }
                                        }
                                    }
                                )) {
                                    ForEach(Array(group.matches.dropFirst())) { result in
                                        TableRow(result).itemProvider { ResultTransfer.provider(for: result.url) }
                                    }
                                }
                                .itemProvider { ResultTransfer.provider(for: group.first.url) }
                            } else {
                                TableRow(group.first).itemProvider { ResultTransfer.provider(for: group.first.url) }
                            }
                        }
                    } else {
                        ForEach(sortedResults) { result in
                            TableRow(result).itemProvider {
                                result.isParentDirectoryEntry ? nil : ResultTransfer.provider(for: result.url)
                            }
                        }
                    }
                }
                // Let SwiftUI own the full-width table style. Overriding its
                // NSTableView style during updates made every selection briefly
                // switch back to inset rows before the bridge restored it.
                .tableStyle(.bordered(alternatesRowBackgrounds: true))
                .background(
                    ResultsTableBridge(
                        results: displayedResults,
                        isBrowsingDirectory: viewModel.isBrowsingDirectory,
                        columnItems: columnItems,
                        onQuickLook: { viewModel.toggleQuickLook(using: displayedResults) },
                        onOpenResult: { result in
                            activateResult(result)
                        },
                        onOpenFolder: { result in
                            activateParentFolder(for: result)
                        },
                        onNavigateDirectory: { result in
                            navigateToDirectory(result)
                        },
                        onToggleColumnVisibility: { id in
                            toggleColumnVisibility(id)
                        },
                        onShowAllColumns: {
                            showAllColumns()
                        }
                    )
                    .frame(width: 0, height: 0)
                )
                .contextMenu(forSelectionType: SearchResult.ID.self) { selection in
                    ResultActions(viewModel: viewModel, results: sortedResults.filter {
                        selection.contains($0.id) && !$0.isParentDirectoryEntry
                    })
                }
                .onCopyCommand {
                    ResultExport.uniqueURLs(viewModel.selectedResults).map { ResultTransfer.provider(for: $0) }
                }
            }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var resultActionsBar: some View {
        ViewThatFits(in: .horizontal) {
            resultActionsRow(compact: false)
            resultActionsRow(compact: true)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func resultActionsRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if viewModel.producesContentLines && !viewModel.isBrowsingDirectory {
                Toggle("Group by File", isOn: $viewModel.groupContentMatches)
                    .toggleStyle(.checkbox).fixedSize()
                if !compact {
                    Text(viewModel.totalResultCount > 0
                         ? "\(viewModel.resultTotals.files.formatted()) \(viewModel.resultTotals.files == 1 ? "file" : "files") · \(viewModel.totalResultCount.formatted()) \(viewModel.totalResultCount == 1 ? "match" : "matches")"
                         : "\(contentGroups.count) files · \(viewModel.results.count) matches")
                        .foregroundStyle(.secondary).fixedSize()
                }
            } else {
                Text(viewModel.isBrowsingDirectory ? "Folder Contents" : "Results")
                    .font(.system(size: 14, weight: .semibold)).fixedSize()
            }
            Spacer(minLength: 0)
            if viewModel.resultPageCount > 1 {
                HStack(spacing: 8) {
                    UtilityIconButton(title: "Previous results page", systemImage: "chevron.left") {
                        viewModel.showResultPage(viewModel.resultPage - 1)
                    }.disabled(viewModel.resultPage == 0)
                    Text("\(viewModel.resultPage + 1) / \(viewModel.resultPageCount)").monospacedDigit()
                    UtilityIconButton(title: "Next results page", systemImage: "chevron.right") {
                        viewModel.showResultPage(viewModel.resultPage + 1)
                    }.disabled(viewModel.resultPage + 1 >= viewModel.resultPageCount)
                }.nativeUtilityButtonStyle().fixedSize()
            }
            if !viewModel.selectedResults.isEmpty {
                Text("\(viewModel.selectedResults.count) selected").foregroundStyle(.secondary).fixedSize()
            }
            Menu {
                ResultActions(viewModel: viewModel, results: viewModel.selectedResults)
                Divider()
                Button(viewModel.savingResultScope ? "Saving Result Scope…" : "Search Within These Results") { viewModel.searchTheseFiles() }
                    .disabled(viewModel.isSearching || viewModel.savingResultScope || viewModel.totalResultCount == 0)
                    .help("Use every item in these results as the next search’s scope, including other result pages.")
                    .accessibilityIdentifier("searchTheseFiles")
                Button("Export All Results…") { viewModel.exportAllResults() }
                    .disabled(sortedResults.isEmpty)
                if isGroupingContents {
                    Divider()
                    Button("Expand All File Groups") { collapsedContentFiles.removeAll() }
                    Button("Collapse All File Groups") { collapsedContentFiles = Set(contentGroups.map(\.id)) }
                }
            } label: {
                Text("Actions")
            }
            .nativeUtilityButtonStyle()
            .accessibilityIdentifier("resultActions")
            .fixedSize()
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(viewModel.isSearching ? "Searching…" : "No Results")
                .font(.headline)
            Text(viewModel.statusMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            UtilityIconButton(title: "Reload search", systemImage: "arrow.clockwise") {
                guard commitScope() else { return }
                if viewModel.useIndex { viewModel.refreshCurrentIndex() }
                else { viewModel.refreshSearch() }
            }
            .frame(width: 34)
            .background(ResultsPanePosition(identifier: "reloadGuide") { _ in }.allowsHitTesting(false))
            .accessibilityIdentifier("reloadSearch")
            .accessibilityLabel("Reload search")
            .help(viewModel.useIndex ? "Refresh the saved snapshot" : "Rescan folders and search again")
            Color.clear.frame(width: max(12, resultsLeading - 34))
            HStack(spacing: 8) {
                Text(viewModel.preparingContents && !viewModel.isSearching ? "Preparing content index…" : viewModel.statusMessage)
                    .foregroundStyle(.secondary).lineLimit(1).help(viewModel.statusMessage)
                    .accessibilityIdentifier("searchStatus")
                if viewModel.isSearching || viewModel.preparingContents { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                if viewModel.preparingContents {
                    UtilityIconButton(title: "Cancel content preparation", systemImage: "xmark.circle") { viewModel.prepareContentIndex() }
                        .accessibilityIdentifier("cancelContentPreparation")
                }
                if viewModel.hasPermissionFailure {
                    Button("File Access…") { viewModel.isPermissionHelpPresented = true }
                        .nativeUtilityButtonStyle()
                        .fixedSize()
                        .accessibilityIdentifier("searchFileAccessHelp")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            .background(ResultsPanePosition(identifier: "footerStatusGuide") { _ in }.allowsHitTesting(false))
            .padding(.trailing, 12)

            if !viewModel.commandPreview.isEmpty {
                Button { viewModel.copyCommandPreview() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                        Text(viewModel.engineName).foregroundStyle(.secondary).fixedSize()
                        Divider().frame(height: 14)
                        Text(viewModel.nativeCommand == nil ? "Search Details" : viewModel.commandSummary.isEmpty ? "Copy Command" : viewModel.commandSummary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: viewModel.transientFooterMessage?.hasPrefix("Copied") == true ? "checkmark" : "doc.on.doc")
                            .frame(width: 14, height: 18)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 450, alignment: .leading)
                }
                .nativeUtilityButtonStyle()
                .modifier(CommandHoverHighlight(isActive: isCommandPresented))
                .accessibilityIdentifier("copyCommand")
                .background(ResultsPanePosition(identifier: "copyCommandGuide") { _ in }.allowsHitTesting(false))
                .accessibilityLabel(viewModel.nativeCommand == nil ? "Copy Search Details" : "Copy Search Command")
                .help("Click to copy the complete command. Right-click to inspect every pipeline stage.")
                .contextMenu {
                    Button("Show Full Command…") { isCommandPresented = true }
                    Button("Explain a File…") { viewModel.explainFile() }.disabled(viewModel.explainingFile)
                }
                .popover(isPresented: $isCommandPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(viewModel.nativeCommand == nil ? "Search Details" : "Search Command").font(.headline)
                            Spacer()
                            Button("Copy") { viewModel.copyCommandPreview() }
                                .nativeUtilityButtonStyle()
                        }
                        HStack {
                            Button("Explain a File…") { viewModel.explainFile() }.disabled(viewModel.explainingFile)
                            if viewModel.explainingFile { ProgressView().controlSize(.small) }
                        }
                        ScrollView {
                            Text(viewModel.nativeCommand ?? viewModel.commandPreview)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: 220)
                        Text(viewModel.nativeCommand == nil
                             ? "This view uses a saved index or a native directory listing."
                             : "This pipeline supplies the displayed matches. Filename output uses NUL separators; content output uses ripgrep JSON.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20).frame(width: 560)
                }
            }
            Button("Import Command…") {
                commandInputError = nil; runNativeCommand = viewModel.commandSearch != nil
                isCommandImportPresented = true
            }
                .nativeUtilityButtonStyle().fixedSize().padding(.leading, 10)
                .accessibilityIdentifier("importSearchCommand")
                .help("Paste an existing fd, rg, find, or FindUI command to populate the search controls.")
                .popover(isPresented: $isCommandImportPresented) { commandImport }
        }
        .font(.system(size: 12))
        .frame(minHeight: 28)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
        .overlay(alignment: .bottomTrailing) {
            if let message = viewModel.transientFooterMessage {
                Text(message).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary.opacity(0.3)))
                    .padding(.trailing, 16).offset(y: -44).allowsHitTesting(false)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }

    }

    private var commandImport: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Search Command").font(.headline)
            Text(runNativeCommand
                 ? "Run an fd, rg, or find command with its tool options. Search results appear as files and matches; other output appears as text. Tool actions have the same effects as in Terminal."
                 : "Paste an fd, rg, find, or FindUI command to fill in the search controls.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $commandInput)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 112).padding(5)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.35)))
                .focused($isCommandImportFocused)
                .accessibilityIdentifier("commandInput")
            Toggle("Run as a command instead of editing controls", isOn: $runNativeCommand)
                .toggleStyle(.checkbox).accessibilityIdentifier("runNativeCommand")
                .onChange(of: runNativeCommand) { _, _ in commandInputError = nil }
            if let commandInputError {
                Text(commandInputError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { isCommandImportPresented = false }.keyboardShortcut(.cancelAction)
                Button(runNativeCommand ? "Run & Show Results" : "Apply & Search", action: importCommand)
                    .nativePrimaryButtonStyle().keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("applyCommandImport")
                    .disabled(commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 560).nativeUtilityButtonStyle()
        .onAppear { isCommandImportFocused = true }
    }

    private var indexStatusText: String {
        if let index = viewModel.currentDriveIndex {
            return "Using \(index.name) index"
        }
        return "No index for \(viewModel.currentDrive.name)"
    }

    private func activateResult(_ result: SearchResult) {
        if viewModel.isBrowsingDirectory, result.isBrowsableDirectoryEntry {
            navigateToDirectory(result)
            return
        }
        viewModel.selectResult(result)
        viewModel.openResult(result)
    }

    private func activateParentFolder(for result: SearchResult) {
        viewModel.selectResult(result)
        viewModel.openParentFolder(for: result)
    }

    private func navigateToDirectory(_ result: SearchResult) {
        guard let target = result.browseTargetURL else {
            return
        }
        viewModel.browse(to: target)
    }

    private var isIconColumnVisible: Bool {
        columnCustomization[visibility: "icon"] != .hidden
    }

    private var columnItems: [ResultsTableBridge.ColumnItem] {
        [
            ResultsTableBridge.ColumnItem(id: "icon", title: "Icon", isVisible: isColumnVisible("icon"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "name", title: "Name", isVisible: true, canHide: false),
            ResultsTableBridge.ColumnItem(id: "type", title: ResultPresentationLabels.kind, isVisible: isColumnVisible("type"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "folder", title: ResultPresentationLabels.path, isVisible: isColumnVisible("folder"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "modified", title: ResultMetadataLabels.modified, isVisible: isColumnVisible("modified"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "size", title: "Size", isVisible: isColumnVisible("size"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "created", title: ResultMetadataLabels.created, isVisible: isColumnVisible("created"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "added", title: ResultMetadataLabels.added, isVisible: isColumnVisible("added"), canHide: true),
            ResultsTableBridge.ColumnItem(id: "opened", title: ResultMetadataLabels.lastOpened, isVisible: isColumnVisible("opened"), canHide: true),
        ]
    }

    private var primaryDriveName: String {
        DriveDiscovery.primaryVolume().name
    }

    private func isColumnVisible(_ id: String) -> Bool {
        columnCustomization[visibility: id] != .hidden
    }

    private func toggleColumnVisibility(_ id: String) {
        guard let item = columnItems.first(where: { $0.id == id }), item.canHide else {
            return
        }
        columnCustomization[visibility: id] = item.isVisible ? .hidden : .visible
    }

    private func showAllColumns() {
        for id in ["icon", "type", "folder", "modified", "size", "created", "added", "opened"] {
            columnCustomization[visibility: id] = .visible
        }
    }

    private func quickLookTitle(for url: URL) -> String {
        currentQuickLookResult?.displayName ?? url.lastPathComponent
    }

}
