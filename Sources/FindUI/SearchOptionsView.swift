import SearchCore
import SearchBackend
import AppKit
import SwiftUI

struct SearchOptionsView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var showsAdvanced = false
    @State private var facets: [ResultFacet] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Scope & Options").font(.headline)
                    Spacer()
                    if !facets.isEmpty {
                        Menu("From Results") {
                            ForEach([ResultFacet.Kind.fileType,.folder,.modified,.tag],id:\.self) { kind in
                                let values = facets.filter { $0.kind == kind }
                                if !values.isEmpty {
                                    Section(kind == .fileType ? "File types" : kind == .folder ? "Folders" : kind == .tag ? "Finder tags" : "Modified") {
                                        ForEach(values) { facet in
                                            Button("\(facet.title) (\(facet.count))") { viewModel.applyFacet(facet) }.help(facet.value)
                                        }
                                    }
                                }
                            }
                        }.help("Add a filter using metadata from the current results. Counts are files, not matching lines.")
                            .accessibilityIdentifier("resultFacets")
                    }
                    Button("Reset Options") { viewModel.resetAdditionalFilters() }
                        .help(viewModel.searchRules == nil ? "Clear additional filters; keep the filename and contents inputs."
                              : "Reset shared scope options; keep all file and content conditions.")
                }
                section("Folders and scope") {
                    if viewModel.searchRules != nil {
                        HStack {
                            Text("Include").frame(width: 76, alignment: .leading)
                            UtilityPicker(title: "Item types", selection: Binding(
                                get: { viewModel.mode == .contents ? .files : viewModel.mode },
                                set: { if viewModel.mode != .contents { viewModel.mode = $0 } }
                            ), values: [SearchMode.files, .folders, .everything], label: \.title)
                            .disabled(viewModel.searchRules?.hasContents == true)
                            .help("Content conditions search files. Remove them to include directories.")
                        }
                    }
                    if viewModel.searchState.resultScope == nil {
                    HStack {
                        Text("Source").frame(width: 76, alignment: .leading)
                        UtilityPicker(title: "Search source", selection: $viewModel.sourceChoice,
                                      values: viewModel.sourceChoices,
                                      label: { $0.rawValue })
                    }
                    if viewModel.refinements.source == .spotlight {
                        Text("Searches the existing Spotlight index. Unindexed or recently changed files may be absent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Additional folders").fontWeight(.medium)
                        Spacer()
                        Button("Add Folder…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
                            panel.prompt = "Add"
                            if panel.runModal() == .OK {
                                for url in panel.urls where url.path != viewModel.scopeURL.path && !viewModel.refinements.additionalScopes.contains(url.path) {
                                    viewModel.refinements.additionalScopes.append(url.path)
                                }
                            }
                        }
                    }
                    ForEach(viewModel.refinements.additionalScopes, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(path).lineLimit(1).truncationMode(.middle).help(path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            UtilityIconButton(title: "Remove \(path)", systemImage: "minus.circle") {
                                viewModel.refinements.additionalScopes.removeAll { $0 == path }
                            }
                            .accessibilityIdentifier("removeScope.\(path)")
                        }
                    }
                    }
                    Toggle("Include subfolders", isOn: Binding(
                        get: { viewModel.traversal.maximumDepth.map { $0 > 1 } ?? true },
                        set: { viewModel.traversal.minimumDepth = 1; viewModel.traversal.maximumDepth = $0 ? nil : 1 }
                    )).help("Turn off to search only the selected folders. Set a specific depth under Advanced.")
                    HStack {
                        Toggle("Include hidden files", isOn: $viewModel.includeHidden)
                        Toggle("Include ignored files", isOn: $viewModel.traversal.includeIgnored)
                            .disabled(viewModel.refinements.source == .spotlight && !viewModel.useIndex)
                    }
                    Toggle("Search inside app bundles and packages", isOn: $viewModel.traversal.includePackageContents)
                        .help("Includes contents of .app, .bundle, .framework, .pkg and other common macOS package directories.")
                    SearchExtractionView(options: $viewModel.refinements.extraction)
                        .disabled(viewModel.useIndex || viewModel.mode == .folders || viewModel.refinements.contentSource == .indexedDocumentText)
                }
                if viewModel.searchRules == nil {
                section("File filters") {
                    SearchListEditor(values: Binding(get: { viewModel.refinements.finderTags ?? [] }, set: {
                        viewModel.refinements.finderTags = $0.isEmpty ? nil : $0
                    })) { text in
                        HStack(alignment: .top) {
                            Text("Finder tags").frame(width: 76, alignment: .leading).padding(.top, 5)
                            TextField("Any · one tag per line", text: text, axis: .vertical)
                                .lineLimit(1...4).accessibilityIdentifier("Finder tag names")
                                .help("Exact Finder tag names, one per line. Press Option-Return to add another tag.")
                            UtilityPicker(title: "Tag matching", selection: Binding(
                                get: { viewModel.refinements.tagMatch ?? .all }, set: { viewModel.refinements.tagMatch = $0 }),
                                values: TagMatch.allCases, label: \.title).frame(width: 110)
                        }
                    }
                    patternRow("Path", value: $viewModel.refinements.path, matching: $viewModel.refinements.pathMatching)
                    if !viewModel.refinements.path.isEmpty {
                        UtilityPicker(title: "Path scope", selection: Binding(
                            get: { viewModel.refinements.absolutePathMatching == true },
                            set: { viewModel.refinements.absolutePathMatching = $0 }
                        ), values: [false, true], label: { $0 ? "Full absolute path only" : "Relative to search folder" })
                    }
                    HStack {
                        Text("Extensions").frame(width: 76, alignment: .leading)
                        TextField("pdf, txt, swift", text: $viewModel.refinements.extensions)
                        Menu("Add type") {
                            ForEach(SearchFileTypes.groups.filter { $0.category != "language" }) { group in
                                Button(group.title) {
                                    viewModel.refinements.extensions = SearchFileTypes.adding(group, to: viewModel.refinements.extensions)
                                }
                                .help(group.extensions.joined(separator: ", "))
                            }
                            Menu("Languages") {
                                ForEach(SearchFileTypes.groups.filter { $0.category == "language" }) { group in
                                    Button(group.title) {
                                        viewModel.refinements.extensions = SearchFileTypes.adding(group, to: viewModel.refinements.extensions)
                                    }
                                    .help(group.extensions.joined(separator: ", "))
                                }
                            }
                        }
                        .fixedSize()
                        .help("Add a file-type group. Its extensions remain visible and editable here.")
                    }
                    HStack {
                        Text("Size").frame(width: 76, alignment: .leading)
                        TextField("Minimum (10 MB)", text: $viewModel.filters.minimumSize)
                        Text("to").foregroundStyle(.secondary)
                        TextField("Maximum", text: $viewModel.filters.maximumSize)
                    }
                    HStack {
                        Text("Date").frame(width: 76, alignment: .leading)
                        UtilityPicker(title: "Date field", selection: $viewModel.filters.dateField,
                                      values: SearchDateField.allCases.filter { viewModel.availableDateFields.contains($0) || $0 == viewModel.filters.dateField }, label: \.title)
                        UtilityPicker(title: "Date range", selection: $viewModel.filters.datePeriod,
                                      values: SearchDatePeriod.allCases, label: \.title)
                    }
                    if viewModel.filters.dateField == .lastOpened {
                        Text("Uses Spotlight’s Last Opened date, recorded when Finder or Launch Services opens a file. Files without this date cannot match a date range.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if viewModel.filters.dateField == .documentCreated {
                        Text("Uses Spotlight’s document creation date. Depending on the importer, this may be the file’s creation date rather than its original authoring date. Documents without this metadata cannot match a date range.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if viewModel.filters.datePeriod == .recentDays {
                        HStack {
                            Text("Last").frame(width: 76, alignment: .leading)
                            TextField("Days", value: Binding(
                                get: { viewModel.filters.relativeDays ?? 7 },
                                set: { viewModel.filters.relativeDays = $0 }), format: .number.grouping(.never))
                                .frame(width: 72)
                                .accessibilityLabel("Number of days")
                            Text("days")
                        }
                    }
                    if viewModel.filters.datePeriod == .recentCalendar {
                        HStack {
                            Text("Last").frame(width: 76, alignment: .leading)
                            TextField("5 months and 4 days", text: Binding(
                                get: { viewModel.filters.calendarAge ?? "1 month" },
                                set: { viewModel.filters.calendarAge = $0 }))
                                .accessibilityLabel("Calendar duration")
                                .accessibilityIdentifier("calendarDuration.compact")
                                .help("Counts calendar months, then calendar days, back from the search time.")
                        }
                    }
                    if [.custom, .before, .after].contains(viewModel.filters.datePeriod) {
                        HStack {
                            DatePicker(viewModel.filters.datePeriod == .custom ? "From" : "Date",
                                       selection: $viewModel.filters.dateFrom, displayedComponents: .date)
                            if viewModel.filters.datePeriod == .custom {
                                DatePicker("Through", selection: $viewModel.filters.dateThrough, displayedComponents: .date)
                            }
                        }
                    }
                    // Legacy expressions remain visible and editable, without creating
                    // a competing primary file-query field for new searches.
                    if !viewModel.refinements.fileQuery.isEmpty && !viewModel.filenameUsesExpression {
                        Text("Saved file conditions").fontWeight(.medium)
                        TextField("name:report-* -path:vendor", text: $viewModel.refinements.fileQuery)
                    }
                    if let saved = viewModel.refinements.savedFileQuery,
                       !viewModel.filenameUsesExpression || !viewModel.refinements.fileQuery.isEmpty {
                        HStack {
                            Text("Saved \(saved.syntax.title.lowercased())\(saved.exactName ? " (exact name)" : "")")
                            TextField("File condition", text: Binding(
                                get: { viewModel.refinements.savedFileQuery?.text ?? "" },
                                set: { viewModel.refinements.savedFileQuery?.text = $0 }
                            ))
                            Button("Remove") { viewModel.refinements.savedFileQuery = nil }
                        }
                    }
                }
                }
                if viewModel.searchState.hasFuzzyConditions {
                    section("Fuzzy matching") {
                        Toggle("Match accented variants", isOn: Binding(
                            get: { viewModel.refinements.fuzzyNormalize == true },
                            set: { viewModel.refinements.fuzzyNormalize = $0 ? true : nil }))
                            .help("Uses fzf's normalization, for example matching résumé when searching resume.")
                            .accessibilityIdentifier("fuzzyNormalize")
                    }
                }
                section("Content matches") {
                    if viewModel.refinements.contentSource == .indexedDocumentText
                        || (viewModel.searchRules?.hasContents == true && viewModel.searchRules?.contentLeaves.allSatisfy(\.isDocumentText) == true) {
                        Text("Searches text indexed by Spotlight, including supported PDF and Office documents. Results are files; matching lines and context are unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    if viewModel.refinements.wordSearch == true {
                        HStack {
                            Button(viewModel.preparingContents ? "Cancel Preparation" : "Update Word Index") { viewModel.prepareContentIndex() }
                                .accessibilityIdentifier("prepareContentIndex")
                            if viewModel.preparingContents { ProgressView().controlSize(.small) }
                        }.help("Prepare words in the selected folders. Update after adding or changing files; unchanged text is reused.")
                        Toggle("Related word forms", isOn: Binding(get: { viewModel.refinements.stemWords == true }, set: { viewModel.refinements.stemWords = $0 }))
                            .help("Matches related forms using the selected language. Word boundaries also support scripts without spaces.")
                        if viewModel.refinements.stemWords == true {
                            Picker("Language", selection: Binding(get: { viewModel.refinements.wordLanguage ?? .en }, set: { viewModel.refinements.wordLanguage = $0 })) {
                                ForEach(WordLanguage.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        if let status = viewModel.contentPreparationStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if viewModel.refinements.wordSearch != true {
                        Toggle("Whole words", isOn: $viewModel.refinements.wholeWords)
                        Toggle("Match across line breaks", isOn: Binding(get: { viewModel.refinements.multiline == true }, set: { viewModel.refinements.multiline = $0 }))
                            .help("Allows regex matches to span lines. Use (?s) if a dot should also match line breaks. Large files may need more memory.")
                    }
                    if viewModel.searchRules?.contentUnit != .file && (viewModel.searchRules == nil || viewModel.searchRules?.separated != nil) {
                        Toggle("Show matching files instead of lines", isOn: $viewModel.refinements.matchingFilesOnly)
                    }
                    Stepper("Preview context: \(viewModel.refinements.contextLines) lines",
                            value: $viewModel.refinements.contextLines, in: 0...20)
                    }
                }.disabled(viewModel.refinements.wordSearch != true && (viewModel.searchRules == nil ? viewModel.contentsInput.isEmpty : viewModel.searchRules?.hasContents != true))
                section("Exclusions") {
                    Text("Folders · exact names at any depth").fontWeight(.medium)
                    SearchListEditor(values: $viewModel.traversal.excludedFolders) { text in
                        lineEditor(text: text, label: "Excluded folder names", hint: "One name per line, e.g. .git or node_modules")
                    }
                    if viewModel.searchRules == nil {
                    Text("Files · filename or path wildcards").fontWeight(.medium)
                    lineEditor(text: $viewModel.refinements.excludedFiles, label: "Excluded file patterns",
                               hint: "One pattern per line, e.g. *.lock or **/generated/**")
                    }
                    HStack {
                        Button("Add dependencies and builds") {
                            viewModel.traversal.excludedFolders = Array(Set(viewModel.traversal.excludedFolders
                                + [".git", "node_modules", ".venv", "venv", ".build", "build", "dist"])).sorted()
                        }.help("Add .git, node_modules, .venv, venv, .build, build, and dist to excluded folders.")
                        Spacer()
                        Button("Clear exclusions") {
                            viewModel.traversal.excludedFolders = []; viewModel.refinements.excludedFiles = ""
                        }.disabled(viewModel.traversal.excludedFolders.isEmpty && viewModel.refinements.excludedFiles.isEmpty)
                    }
                }
                ExpandableSection("Advanced", isExpanded: $showsAdvanced, identifier: "advancedSearchOptions") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Follow symbolic links", isOn: $viewModel.traversal.followSymlinks)
                        SearchListEditor(values: Binding(get: { viewModel.traversal.pathRules ?? [] }, set: {
                            viewModel.traversal.pathRules = $0.isEmpty ? nil : $0
                        })) { text in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Path patterns").fontWeight(.medium)
                                TextField("Any path", text: text, axis: .vertical).lineLimit(1...4)
                                    .accessibilityIdentifier("traversalPathRules")
                                    .help("One pattern per line, e.g. *.swift to include or !build to exclude. Later patterns win. Inclusions also admit matching hidden or ignored files. Patterns with / are relative to the first search folder. Excluded folders are pruned before reading contents. Press Option-Return for another pattern.")
                            }
                        }
                        HStack {
                            Text("Folder depth")
                            TextField("Minimum", value: $viewModel.traversal.minimumDepth, format: .number).frame(width: 65)
                                .accessibilityLabel("Minimum folder depth")
                            Text("to").foregroundStyle(.secondary)
                            TextField("Unlimited", text: Binding(
                                get: { viewModel.traversal.maximumDepth.map(String.init) ?? "" },
                                set: { viewModel.traversal.maximumDepth = $0.isEmpty ? nil : Int($0) ?? 0 }
                            )).frame(width: 90).accessibilityLabel("Maximum folder depth")
                            Button("Reset Depth") { viewModel.traversal.minimumDepth = 1; viewModel.traversal.maximumDepth = nil }
                        }
                        HStack {
                            Text("Search workers")
                            TextField("Automatic", text: Binding(
                                get: { (viewModel.refinements.workers ?? 0) == 0 ? "" : String(viewModel.refinements.workers!) },
                                set: { viewModel.refinements.workers = $0.isEmpty ? nil : Int($0) ?? -1 }
                            )).frame(width: 90).accessibilityLabel("Parallel search workers")
                        }.help("Leave blank for automatic scheduling, or choose 1–64. Fewer workers reduce simultaneous disk reads and document conversions.")
                            .disabled(viewModel.useIndex)
                        if viewModel.refinements.wordSearch != true {
                        Toggle("Use cached content index", isOn: Binding(
                            get: { viewModel.refinements.useContentIndex == true }, set: { viewModel.refinements.useContentIndex = $0 }))
                            .help("Skip unchanged files only when the index can rule out a match. Other files are searched normally.")
                        HStack {
                            Button(viewModel.preparingContents ? "Cancel Preparation" : "Prepare Content Index") { viewModel.prepareContentIndex() }
                                .disabled(!viewModel.preparingContents && (viewModel.useIndex || viewModel.refinements.source == .spotlight))
                                .accessibilityIdentifier("prepareContentIndex")
                            if viewModel.preparingContents { ProgressView().controlSize(.small) }
                        }
                        .help("Read files in the current scope once to accelerate repeated searches. Existing conversions and signatures are reused.")
                        if let status = viewModel.contentPreparationStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        }
                        if viewModel.mode == .contents && !viewModel.useIndex && !viewModel.searchState.makeRequest().searchesDocumentText {
                            HStack {
                                Text("Text encoding")
                                Picker("Text encoding", selection: Binding(get: { viewModel.refinements.textEncoding ?? "auto" },
                                    set: { viewModel.refinements.textEncoding = $0 == "auto" ? nil : $0 })) {
                                    Text("Automatic").tag("auto")
                                    Text("UTF-8").tag("utf-8")
                                    Text("Western (Windows-1252)").tag("windows-1252")
                                    Text("UTF-16 LE").tag("utf-16le")
                                    Text("UTF-16 BE").tag("utf-16be")
                                    Text("Japanese (Shift JIS)").tag("shift_jis")
                                    Text("Chinese (GB18030)").tag("gb18030")
                                    if let encoding = viewModel.refinements.textEncoding,
                                       !["utf-8", "windows-1252", "utf-16le", "utf-16be", "shift_jis", "gb18030"].contains(encoding) {
                                        Text(encoding).tag(encoding)
                                    }
                                }.labelsHidden().frame(width: 215).accessibilityIdentifier("textEncoding")
                            }.help("Automatic recognizes Unicode byte-order marks. Choose an encoding for older plain-text files and archive members.")
                            if viewModel.refinements.wordSearch != true {
                            HStack {
                                Text("Allow typos")
                                Picker("Allow typos", selection: Binding(get: { viewModel.refinements.typoTolerance ?? 0 }, set: { viewModel.refinements.typoTolerance = $0 == 0 ? nil : $0 })) {
                                    Text("Off").tag(0); Text("1 edit").tag(1); Text("2 edits").tag(2)
                                }.labelsHidden().frame(width: 120).accessibilityIdentifier("typoTolerance")
                            }.help("Matches literal words and phrases with this many insertions, deletions or substitutions. Regex, proximity and metadata conditions keep their exact meaning.")
                            }
                        }
                        SearchExtractionLimitsView(options: $viewModel.refinements.extraction)
                    }
                }
                if let error = filterError { Text(error).font(.caption).foregroundStyle(.red) }
                if viewModel.useIndex && viewModel.currentIndexNeedsRefresh {
                    Label("Refresh the snapshot to apply scope and exclusion changes.", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(20)
        }
        .frame(width: 570, height: 650)
        .task(id:viewModel.isSearching) {
            facets = viewModel.isSearching ? [] : await viewModel.resultFacets()
        }
        .font(.system(size: 12))
        .textFieldStyle(.roundedBorder)
        .background(Color(nsColor: .windowBackgroundColor))
        .nativeUtilityButtonStyle()
        .menuStyle(NativeUtilityMenuStyle())
        .toggleStyle(.checkbox)
        .onAppear {
            let extraction = viewModel.refinements.extraction
            showsAdvanced = (viewModel.refinements.workers ?? 0) != 0 || viewModel.traversal.followSymlinks
                || viewModel.traversal.minimumDepth != 1 || (viewModel.traversal.maximumDepth.map { $0 != 1 } ?? false)
                || viewModel.refinements.useContentIndex == true || viewModel.refinements.textEncoding != nil || (viewModel.refinements.typoTolerance ?? 0) > 0
                || viewModel.traversal.pathRules?.isEmpty == false
                || (extraction.map {
                    let defaults = SearchExtractionOptions()
                    return !$0.cacheText || !$0.useTika || $0.timeoutSeconds != defaults.timeoutSeconds
                        || $0.maximumMegabytes != defaults.maximumMegabytes || $0.maximumArchiveDepth != defaults.maximumArchiveDepth
                } ?? false)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Text(title).font(.system(size: 12, weight: .semibold)) }
    }

    private func lineEditor(text: Binding<String>, label: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(4).frame(height: 58)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.35)))
                .accessibilityLabel(label).accessibilityIdentifier(label)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func patternRow(_ title: String, value: Binding<String>, matching: Binding<PatternMatching>) -> some View {
        HStack {
            Text(title).frame(width: 76, alignment: .leading)
            TextField("Any", text: value)
            UtilityPicker(title: title + " matching", selection: matching,
                          values: PatternMatching.allCases, label: \.title).frame(width: 110)
        }
    }

    private var filterError: String? {
        do {
            _ = try viewModel.filters.validated(); try viewModel.traversal.validate(allowRoot: viewModel.searchState.resultScope != nil)
            try viewModel.refinements.extraction?.validate()
            guard (0...64).contains(viewModel.refinements.workers ?? 0) else {
                return "Parallel workers must be between 1 and 64, or blank for Automatic."
            }
            if viewModel.filters.dateField.spotlightAttribute != nil && viewModel.filters.datePeriod != .any,
               viewModel.useIndex || viewModel.refinements.source != .spotlight {
                return "\(viewModel.filters.dateField.title) dates require the Spotlight source."
            }
            return nil
        }
        catch { return error.localizedDescription }
    }
}

struct ResultActions: View {
    @ObservedObject var viewModel: SearchViewModel
    let results: [SearchResult]

    var body: some View {
        Group {
            Button("Open") { viewModel.openResults(results) }
            if results.count == 1, let result = results.first, let line = result.lineNumber {
                Button("Open in Editor at Line \(line)") { viewModel.openInEditor(result) }
            }
            Button("Show in Finder") { viewModel.revealResults(results) }
            Divider()
            Button("Copy Files") { viewModel.copyFiles(results) }
            Button("Copy Paths") { viewModel.copyPaths(results) }
            if results.contains(where: { $0.snippet != nil }) {
                Button("Copy Matching Lines") { viewModel.copyMatchingLines(results) }
            }
            Button("Export Selected Results…") { viewModel.exportResults(results) }
        }
        .disabled(results.isEmpty)
    }
}

/// Keep in-progress separators in the editor. SearchState still owns the values;
/// rebuilding the text from its array on every keystroke would erase newlines.
private struct SearchListEditor<Content: View>: View {
    @Binding var values: [String]
    @State private var draft: String
    let content: (Binding<String>) -> Content

    init(values: Binding<[String]>, @ViewBuilder content: @escaping (Binding<String>) -> Content) {
        _values = values
        _draft = State(initialValue: values.wrappedValue.joined(separator: "\n"))
        self.content = content
    }

    private var lines: [String] { draft.split(separator: "\n").map(String.init) }

    var body: some View {
        content($draft)
            .onChange(of: draft) { _, _ in
                if values != lines { values = lines }
            }
            .onChange(of: values) { _, next in
                if lines != next { draft = next.joined(separator: "\n") }
            }
    }
}
