import AppKit
import Combine
import Foundation
import SearchBackend
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SearchViewModel: ObservableObject {
    private var restoringSearchState = false
    @Published private var activeSearch: SearchState {
        didSet {
            guard !restoringSearchState, let previous = oldValue.nativeCommand, activeSearch.nativeCommand == previous else { return }
            var before = oldValue, after = activeSearch
            before.nativeCommand = nil; after.nativeCommand = nil
            // Any ordinary control edit leaves command mode atomically. A
            // command can never invisibly override newly edited controls.
            if before != after { activeSearch.nativeCommand = nil; activeSearch.sourceCommand = nil }
        }
    }
    var query: String {
        get { activeSearch.query }
        set { activeSearch.query = newValue }
    }
    var mode: SearchMode {
        get { activeSearch.mode }
        set { activeSearch.mode = newValue }
    }
    var syntax: SearchSyntax {
        get { activeSearch.syntax }
        set { activeSearch.syntax = newValue }
    }
    var useIndex: Bool {
        get { activeSearch.useIndex }
        set { activeSearch.useIndex = newValue }
    }
    var includeHidden: Bool {
        get { activeSearch.includeHidden }
        set { activeSearch.includeHidden = newValue }
    }
    @Published var showIcons = true
    var caseSensitive: Bool {
        get { activeSearch.caseSensitive }
        set { activeSearch.caseSensitive = newValue }
    }
    var exactNameMatch: Bool {
        get { activeSearch.exactNameMatch }
        set { activeSearch.exactNameMatch = newValue }
    }
    @Published var preferredEditor: SourceEditor = .automatic
    @Published var editorError: String?
    @Published var actionError: String?
    @Published var fileExplanation: SearchExplanation?
    @Published var explainingFile = false
    var filters: SearchFilters {
        get { activeSearch.filters }
        set {
            var state = activeSearch
            state.filters = newValue
            state.selectRequiredSource()
            activeSearch = state
        }
    }
    var traversal: SearchTraversalOptions {
        get { activeSearch.traversal }
        set { activeSearch.traversal = newValue }
    }
    var refinements: SearchRefinements {
        get { activeSearch.refinements }
        set { activeSearch.refinements = newValue }
    }
    @Published var groupContentMatches = true
    @Published var presets: [SearchPreset] = []
    @Published var presetError: String?
    @Published var preparingContents = false
    @Published var contentPreparationStatus: String?
    @Published private(set) var wordIndexStatus: WordIndexStatus?
    private var wordStatusTask: Task<Void, Never>?
    @Published private(set) var savingResultScope = false
    var presetStore = SearchPresetStore()
    private var contentPreparationTask: Task<Void, Never>?
    @Published private(set) var searchStateRevision = 0

    enum FilenameInputMatching: Hashable, Identifiable {
        case quick
        case pattern(PatternMatching)
        case expression
        var id: Self { self }
        var title: String {
            switch self {
            case .quick: "Quick"
            case .pattern(let pattern): pattern.title
            case .expression: "Expression"
            }
        }
    }

    // Historical queries can match names and paths. Keep that meaning, but put
    // the active query in the primary input instead of leaving it apparently empty.
    var filenameUsesExpression: Bool {
        refinements.name.isEmpty
            && (!refinements.fileQuery.isEmpty || !(refinements.savedFileQuery?.text.isEmpty ?? true))
    }

    var filenameInput: String {
        get {
            if !refinements.name.isEmpty { return refinements.name }
            if !refinements.fileQuery.isEmpty { return refinements.fileQuery }
            return refinements.savedFileQuery?.text ?? ""
        }
        set {
            if filenameUsesExpression {
                if !refinements.fileQuery.isEmpty {
                    refinements.fileQuery = newValue
                } else if newValue.isEmpty {
                    refinements.savedFileQuery = nil
                } else {
                    refinements.savedFileQuery?.text = newValue
                }
            } else {
                var state = activeSearch
                state.refinements.name = newValue
                if state.filenameQueryStyle == .quick {
                    state.refinements.nameMatching = Self.quickFilenameMatching(newValue)
                }
                activeSearch = state
            }
        }
    }

    var filenameInputMatching: FilenameInputMatching {
        get {
            if filenameUsesExpression { return .expression }
            if activeSearch.filenameQueryStyle == .quick,
                refinements.nameMatching == Self.quickFilenameMatching(filenameInput)
            {
                return .quick
            }
            return .pattern(refinements.nameMatching)
        }
        set {
            guard newValue != .expression else { return }
            let text = filenameInput
            var state = activeSearch
            if filenameUsesExpression {
                if !state.refinements.fileQuery.isEmpty {
                    state.refinements.fileQuery = ""
                } else {
                    state.refinements.savedFileQuery = nil
                }
            }
            state.refinements.name = text
            state.filenameQueryStyle = newValue == .quick ? .quick : nil
            if case .pattern(let matching) = newValue {
                state.refinements.nameMatching = matching
            } else {
                state.refinements.nameMatching = Self.quickFilenameMatching(text)
            }
            activeSearch = state
        }
    }

    private static func quickFilenameMatching(_ text: String) -> PatternMatching {
        text.contains("*") || text.contains("?") ? .glob : .contains
    }

    var filenameMatchingChoices: [FilenameInputMatching] {
        [.quick] + PatternMatching.allCases.map(FilenameInputMatching.pattern)
            + (filenameUsesExpression ? [.expression] : [])
    }

    var fileTypePresetTitle: String {
        let selected = Set(
            refinements.extensions.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                .map { SearchFileTypes.literalSuffix($0).lowercased() })
        guard !selected.isEmpty else { return "File types" }
        return SearchFileTypes.groups.first(where: { Set($0.extensions) == selected })?.title
            ?? (selected.count == 1 ? "*." + selected.first! : "\(selected.count) types")
    }

    func selectFileTypePreset(_ group: SearchFileTypes.Group) {
        refinements.extensions = group.extensions.joined(separator: ", ")
    }

    var hasAdditionalOptions: Bool {
        let options = refinements
        return filters.isActive || traversal != .init() || !options.additionalScopes.isEmpty
            || options.source != .filesystem || !options.path.isEmpty || !options.extensions.isEmpty
            || !options.excludedFiles.isEmpty || options.wholeWords || options.matchingFilesOnly
            || options.contextLines != 3 || options.extraction != nil || (options.workers ?? 0) != 0 || useIndex
            || !(options.finderTags?.isEmpty ?? true) || options.useContentIndex == true
            || activeSearch.resultScope != nil
            || options.multiline == true || options.textEncoding != nil || (options.typoTolerance ?? 0) > 0
            || options.wordSearch == true || options.fuzzyNormalize == true
    }

    /// The two primary inputs describe one search. A nonempty contents field
    /// selects content search; clearing it returns to filename search.
    var contentsInput: String {
        get { activeSearch.contentsInput }
        set {
            activeSearch.contentsInput = newValue
            scheduleSearch()
        }
    }

    var sourceChoice: SearchSourceChoice {
        get { activeSearch.sourceChoice }
        set { activeSearch.sourceChoice = newValue }
    }
    var sourceChoices: [SearchSourceChoice] { activeSearch.sourceChoices }

    var searchState: SearchSnapshot { currentSnapshot() }
    var commandSearch: NativeSearchCommand? { activeSearch.nativeCommand }
    var searchRules: SearchRuleSet? { activeSearch.ruleSet }
    var producesContentLines: Bool { activeSearch.makeRequest().producesContentLines }
    var canUseCompactControls: Bool { activeSearch.compactProjection != nil }

    func enableRules() {
        do {
            var state = activeSearch
            try state.promoteToRules()
            activeSearch = state
        } catch { actionError = error.localizedDescription }
    }

    func updateRules(_ rules: SearchRuleSet) {
        var state = activeSearch
        state.replaceRules(rules)
        activeSearch = state
    }

    func useCompactControls() {
        guard let state = activeSearch.compactProjection else { return }
        activeSearch = state
    }

    func resetAdditionalFilters() {
        var state = activeSearch
        if state.ruleSet != nil {
            var options = SearchRefinements()
            options.fileCaseSensitive = state.refinements.fileCaseSensitive
            options.contentSource = state.refinements.contentSource
            options.wordSearch = state.refinements.wordSearch
            state.refinements = options
            state.traversal = .init(excludedFolders: [])
            state.selectRequiredSource()
            activeSearch = state
            return
        }
        let name = state.refinements.name
        let matching = state.refinements.nameMatching
        let fileCase = state.refinements.fileCaseSensitive
        let contentSource = state.refinements.contentSource
        let wordSearch = state.refinements.wordSearch
        let expression = filenameUsesExpression ? state.refinements.fileQuery : ""
        let savedExpression = filenameUsesExpression ? state.refinements.savedFileQuery : nil
        state.refinements = .init()
        state.refinements.name = name
        state.refinements.nameMatching = matching
        state.refinements.fileCaseSensitive = fileCase
        state.refinements.contentSource = contentSource
        state.refinements.wordSearch = wordSearch
        state.refinements.fileQuery = expression
        state.refinements.savedFileQuery = savedExpression
        state.filters = .init()
        state.traversal = .init(excludedFolders: [])
        state.selectRequiredSource()
        activeSearch = state
    }

    var scopeURL: URL {
        get { activeSearch.scopeURL }
        set { activeSearch.scopePath = newValue.path }
    }
    @Published var defaultSearchDirectoryPath: String
    @Published var defaultDirectoryError: String?
    @Published var emptySearchBehavior: EmptySearchBehavior = .browse
    @Published var selectedResultIDs = Set<SearchResult.ID>() { didSet { refreshMatchPosition() } }
    @Published var selectedHistoryEntryID: SearchHistoryEntry.ID?
    @Published var isScopeDropTargeted = false
    @Published var quickLookURL: URL?
    @Published var isInspectorPresented = false
    @Published var isIndexPromptPresented = false
    @Published var isPermissionHelpPresented = false
    @Published private(set) var hasPermissionFailure = false
    private var hasOfferedPermissionHelp = false

    @Published var availableVolumes: [StorageVolume]
    @Published var selectedManagerDrivePath: String
    @Published var inspectedIndexFilter = "" { didSet { refreshInspectedPage(reset: true) } }
    @Published private(set) var inspectedPage = 0
    @Published private(set) var inspectedHasMore = false
    private var inspectionTask: Task<Void, Never>?
    private var inspectionGeneration = UUID()
    @Published private(set) var inspectedEntries: [IndexedEntry] = []
    @Published private(set) var isBuildingIndex = false
    @Published private(set) var indexManagerStatusMessage = "Choose a drive in Settings to build or inspect its index."

    @Published private(set) var managedIndexes: [ManagedIndex] = []
    @Published private(set) var history: [SearchHistoryEntry] = []

    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var commandOutput: CommandTextOutput?
    @Published private(set) var commandError: String?
    @Published private(set) var totalResultCount = 0
    @Published private(set) var resultPage = 0
    @Published private(set) var resultTotals = ResultTotals()
    @Published private var storedMatchPosition: Int?
    private var resultPageTask: Task<Void, Never>?
    private var matchPositionTask: Task<Void, Never>?
    private var matchPositionID: UUID?
    var usesStoredResultOrder: Bool { resultStore != nil }
    @Published private(set) var isSearching = false
    @Published private var executionStatusMessage = "Enter a query to search."
    var ruleValidationMessage: String? {
        do {
            try activeSearch.validateExpressions()
            try activeSearch.validateSourceRequirements()
            try traversal.validate(allowRoot: activeSearch.resultScope != nil)
            try searchRules?.validate(now: .now)
            return nil
        } catch { return error.localizedDescription }
    }
    var statusMessage: String { ruleValidationMessage ?? executionStatusMessage }
    @Published private(set) var commandPreview = ""
    @Published private(set) var commandSummary = ""
    @Published private(set) var engineName = "fd"
    @Published private(set) var installedTools = ""
    @Published private(set) var toolLocations: [ToolLocationInfo] = []
    @Published private(set) var transientFooterMessage: String?

    private var liveSearchService: SearchService
    private var indexService: IndexService
    private var toolObservations: [AnyCancellable] = []
    private let persistence: AppPersistence

    private let libraryStore: SearchLibraryStore
    private var libraryObservation: AnyCancellable?
    private var libraryErrorObservation: AnyCancellable?
    private var library: PersistedLibrary {
        get { libraryStore.value }
        set { libraryStore.value = newValue }
    }
    private var pendingSearchTask: Task<Void, Never>?
    private var loadStateTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var cancelledTasks: [UUID: Task<Void, Never>] = [:]
    private var indexBuildTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var lastScheduledState: SearchState?
    private var enableIndexAfterBuild = false
    private var footerMessageTask: Task<Void, Never>?
    private var resultStore: ResultStore?
    private var lastPresentedRevision = -1
    private var resultSort: [ResultSort] = []
    private var pageGeneration = UUID()
    private var importedSnapshot: SearchSnapshot?

    var resultPageCount: Int { max(1, (totalResultCount + ResultStore.pageSize - 1) / ResultStore.pageSize) }

    func refreshSearch() {
        scheduleSearch(immediate: true)
    }

    func refreshTools() {
        let tools = Toolchain.resolve()
        let locations = Self.describeToolLocations(tools)
        let changed = locations.map { $0.path } != toolLocations.map { $0.path }
        liveSearchService = SearchService(tools: tools)
        indexService = IndexService(tools: tools)
        installedTools = Self.describeInstalledTools(tools)
        toolLocations = locations
        if changed { scheduleSearch(immediate: true) }
    }

    func showResultPage(_ page: Int) {
        guard (0..<resultPageCount).contains(page) else { return }
        resultPage = page
        selectedResultIDs = []
        reloadResultPage()
    }

    func sortResults(_ comparators: [KeyPathComparator<SearchResult>]) {
        let columns: [PartialKeyPath<SearchResult>: String] = [
            \SearchResult.name: "name", \SearchResult.path: "path", \SearchResult.sortableKind: "kind",
            \SearchResult.sortableModifiedAt: "modified", \SearchResult.sortableCreatedAt: "created",
            \SearchResult.sortableAddedAt: "added", \SearchResult.sortableLastOpenedAt: "opened",
            \SearchResult.sortableSize: "size",
        ]
        resultSort = comparators.compactMap { comparator in
            columns[comparator.keyPath].map { ResultSort(column: $0, descending: comparator.order == .reverse) }
        }
        resultPage = 0
        reloadResultPage()
    }

    private func reloadResultPage() {
        guard let resultStore else { return }
        resultPageTask?.cancel()
        pageGeneration = UUID()
        let generation = searchGeneration
        let pageID = pageGeneration
        let page = resultPage
        let sort = resultSort
        resultPageTask = Task {
            do {
                let rows = try await resultStore.page(page, sort: sort)
                let totals = try await resultStore.totals(for: rows)
                guard generation == searchGeneration, pageID == pageGeneration else { return }
                resultTotals = totals
                results = rows
                refreshMatchPosition()
            } catch is CancellationError {} catch { if !Task.isCancelled { actionError = error.localizedDescription } }
        }
    }

    init(
        service: SearchService = SearchService(),
        indexService: IndexService? = nil,
        persistence: AppPersistence = AppPersistence(),
        loadSavedState: Bool = true,
        libraryStore: SearchLibraryStore? = nil
    ) {
        let volumes = DriveDiscovery.availableVolumes()
        let primary = volumes.first(where: { $0.url.path == "/" }) ?? DriveDiscovery.primaryVolume()
        let sharedLibrary = libraryStore ?? SearchLibraryStore(persistence: persistence)
        let homeDirectory =
            Self.validDirectoryURL(from: sharedLibrary.value.defaultSearchDirectoryPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        self.liveSearchService = service
        self.indexService = indexService ?? IndexService(tools: service.tools)
        self.libraryStore = sharedLibrary
        self.persistence = sharedLibrary.persistence
        self.availableVolumes = volumes
        var initialSearch = SearchState(
            query: "", mode: .files, scopePath: homeDirectory.path,
            useIndex: false, includeHidden: true, caseSensitive: false, syntax: .literal,
            exactNameMatch: false, selectedDrivePath: primary.url.path, indexedFilter: .files)
        // Quick-entry defaults belong to new UI searches. CLI imports and
        // history retain their own explicitly stored semantics.
        initialSearch.filenameQueryStyle = .quick
        initialSearch.contentQueryStyle = .expression
        self.activeSearch = initialSearch
        self.defaultSearchDirectoryPath = homeDirectory.path
        self.selectedManagerDrivePath = primary.url.path
        self.installedTools = SearchViewModel.describeInstalledTools(service.tools)
        self.toolLocations = SearchViewModel.describeToolLocations(service.tools)

        for name in [TikaManager.toolsDidChange, NSApplication.didBecomeActiveNotification] {
            toolObservations.append(
                NotificationCenter.default.publisher(for: name)
                    .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshTools() })
        }

        libraryObservation = sharedLibrary.$value.sink { [weak self] library in
            guard let self else { return }
            if self.history != library.history { self.history = library.history }
            if self.managedIndexes != library.managedIndexes {
                let previous = self.currentDriveIndex?.updatedAt
                self.managedIndexes = library.managedIndexes
                if self.useIndex, previous != self.currentDriveIndex?.updatedAt { self.scheduleSearch(immediate: true) }
            }
            // Global preferences may change; never replace this window's live
            // scope, matching options, rules, selection, results or caches.
            if self.preferredEditor != library.preferredEditor { self.preferredEditor = library.preferredEditor }
            if self.emptySearchBehavior != library.emptySearchBehavior {
                self.emptySearchBehavior = library.emptySearchBehavior
            }
            if let path = library.defaultSearchDirectoryPath, path != self.defaultSearchDirectoryPath {
                self.defaultSearchDirectoryPath = path
            }
            if let selected = self.selectedHistoryEntryID, !library.history.contains(where: { $0.id == selected }) {
                self.selectedHistoryEntryID = nil
            }
        }
        libraryErrorObservation = sharedLibrary.$saveError.compactMap { $0 }.sink { [weak self] error in
            self?.actionError = "Could not save history and settings: " + error
        }
        if loadSavedState {
            loadStateTask = Task { [weak self] in
                await self?.loadPersistedState()
            }
        }
    }

    var selectedResult: SearchResult? {
        guard let selectedResultID else {
            return results.first
        }
        return results.first(where: { $0.id == selectedResultID }) ?? results.first
    }

    /// Keep a deterministic primary result for the inspector and Quick Look.
    var selectedResultID: SearchResult.ID? {
        get { results.first(where: { selectedResultIDs.contains($0.id) })?.id ?? selectedResultIDs.first }
        set { selectedResultIDs = newValue.map { [$0] } ?? [] }
    }

    var selectedResults: [SearchResult] {
        results.filter { selectedResultIDs.contains($0.id) && !$0.isParentDirectoryEntry }
            .sorted(by: SearchResult.bestMatchFirst)
    }

    var contentMatchesInSelectedFile: [SearchResult] {
        guard let selectedResult, selectedResult.kind == .contentMatch else { return [] }
        return results.filter { $0.documentIdentity == selectedResult.documentIdentity && $0.kind == .contentMatch }
            .sorted {
                ($0.lineNumber ?? $0.extractedOrigin?.line ?? 0) < ($1.lineNumber ?? $1.extractedOrigin?.line ?? 0)
            }
    }

    var contentMatchPosition: Int? {
        if resultStore != nil && contentMatchCount != contentMatchesInSelectedFile.count { return storedMatchPosition }
        return contentMatchesInSelectedFile.firstIndex { $0.id == selectedResultID }
    }

    var contentMatchCount: Int {
        guard let selectedResult else { return 0 }
        return resultTotals.documentCounts[selectedResult.documentIdentity] ?? contentMatchesInSelectedFile.count
    }

    private func refreshMatchPosition() {
        matchPositionTask?.cancel()
        if matchPositionID != selectedResultID {
            storedMatchPosition = nil
            matchPositionID = selectedResultID
        }
        guard let resultStore, let selectedResult, selectedResult.kind == .contentMatch else { return }
        let generation = searchGeneration
        matchPositionTask = Task {
            let position = try? await resultStore.documentPosition(selectedResult)
            guard !Task.isCancelled, generation == searchGeneration, selectedResult.id == selectedResultID else {
                return
            }
            storedMatchPosition = position
        }
    }

    func moveContentMatch(by offset: Int) {
        if contentMatchCount == contentMatchesInSelectedFile.count,
            let current = contentMatchesInSelectedFile.firstIndex(where: { $0.id == selectedResultID })
        {
            let next = current + offset
            if contentMatchesInSelectedFile.indices.contains(next) { selectResult(contentMatchesInSelectedFile[next]) }
            return
        }
        if let resultStore, let selectedResult {
            let generation = searchGeneration
            let sort = resultSort
            resultPageTask?.cancel()
            resultPageTask = Task {
                do {
                    guard let next = try await resultStore.adjacentMatch(to: selectedResult, offset: offset, sort: sort)
                    else { return }
                    let rows = try await resultStore.page(next.page, sort: sort)
                    let totals = try await resultStore.totals(for: rows)
                    guard !Task.isCancelled, generation == searchGeneration else { return }
                    pageGeneration = UUID()
                    resultPage = next.page
                    resultTotals = totals
                    results = rows
                    selectResult(next.result)
                } catch is CancellationError {} catch {
                    if !Task.isCancelled { actionError = error.localizedDescription }
                }
            }
            return
        }
        guard let current = contentMatchPosition else { return }
        let matches = contentMatchesInSelectedFile
        let next = current + offset
        guard matches.indices.contains(next) else { return }
        selectResult(matches[next])
    }

    var currentIndexNeedsRefresh: Bool {
        guard let index = currentDriveIndex else { return false }
        return !indexService.coverageMatches(request: buildRequest(), index: index)
    }

    func persistTraversalPreferences() {
        library.traversal = traversal.normalized
        persistLibrary()
    }

    var orderedHistory: [SearchHistoryEntry] {
        Self.orderHistory(history)
    }

    static func orderHistory(_ history: [SearchHistoryEntry]) -> [SearchHistoryEntry] {
        history.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.isPinned && rhs.isPinned {
                return (lhs.pinOrder ?? .max) < (rhs.pinOrder ?? .max)
            }
            return lhs.searchedAt > rhs.searchedAt
        }
    }

    var pinnedHistory: [SearchHistoryEntry] {
        orderedHistory.filter(\.isPinned)
    }

    var unpinnedHistory: [SearchHistoryEntry] {
        orderedHistory.filter { !$0.isPinned }
    }

    var filteredInspectedEntries: [IndexedEntry] { inspectedEntries }

    var modeSupportsExactName: Bool {
        mode != .contents && syntax != .fuzzy
    }

    var scopeLabel: String {
        if scopeURL.path == "/" {
            return DriveDiscovery.primaryVolume().name
        }
        return scopeURL.lastPathComponent.isEmpty ? scopeURL.path : scopeURL.lastPathComponent
    }

    var currentDrive: StorageVolume {
        volume(for: scopeURL)
    }

    var currentDriveIndex: ManagedIndex? {
        managedIndexes.first(where: { $0.scopePath == currentDrive.url.path })
    }

    var isBrowsingDirectory: Bool {
        let emptyRules = searchRules.map { $0.isEmpty } ?? true
        return activeSearch.nativeCommand == nil && emptySearchBehavior == .browse && mode != .contents && emptyRules
            && activeSearch.resultScope == nil
            && normalizedQuery.isEmpty && !filters.isActive && !refinements.hasFileConditions
            && refinements.additionalScopes.isEmpty && refinements.source == .filesystem
            && traversal.pathRules?.isEmpty != false
    }

    private var normalizedQuery: String {
        syntax == .regex ? query : query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var selectedManagerDrive: StorageVolume? {
        availableVolumes.first(where: { $0.url.path == selectedManagerDrivePath })
    }

    var selectedManagerIndex: ManagedIndex? {
        managedIndexes.first(where: { $0.scopePath == selectedManagerDrivePath })
    }

    /// A programmatic apply already schedules its search. SwiftUI publishes the
    /// corresponding control change afterward; that must not cancel/recompile it.
    func scheduleSearchAfterControlChange() {
        guard currentSnapshot() != lastScheduledState else { return }
        scheduleSearch()
    }

    func scheduleSearch(immediate: Bool = false) {
        guard shutdownTask == nil else { return }
        lastScheduledState = currentSnapshot()
        cancelPendingSearch()
        searchGeneration = UUID()

        if ruleValidationMessage != nil {
            // An unfinished row must not replace the previous result set
            // with an accidentally broader search.
            isSearching = false
            commandPreview = ""
            commandSummary = ""
            return
        }

        var request = buildRequest()
        request.isDirectoryListing = isBrowsingDirectory
        if request.isDirectoryListing { selectedHistoryEntryID = nil }
        let prepared: PreparedSearch?
        do {
            prepared = request.useIndex ? nil : try PreparedSearch(request: request, tools: liveSearchService.tools)
            commandPreview = prepared?.command ?? currentCommandPreview(for: request)
            commandSummary = prepared?.pipeline.displayCommand ?? ""
            engineName = prepared?.engineName ?? "Snapshot"
        } catch {
            isSearching = false
            executionStatusMessage = error.localizedDescription
            commandPreview = ""
            commandSummary = ""
            return
        }
        pendingSearchTask = Task { [request, prepared, generation = searchGeneration] in
            if !immediate {
                do {
                    try await Task.sleep(
                        for: SearchSession.debounce(
                            indexed: request.useIndex || request.refinements.wordSearch == true,
                            browsing: request.isDirectoryListing))
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            await performSearch(request: request, prepared: prepared, generation: generation)
        }
    }

    var contentMatchingChoice: ContentMatchingChoice {
        get { activeSearch.contentMatchingChoice }
        set { activeSearch.contentMatchingChoice = newValue }
    }
    var contentMatchingChoices: [ContentMatchingChoice] { activeSearch.contentMatchingChoices }
    var contentTextEngine: ContentTextEngine {
        get { activeSearch.contentTextEngine }
        set { activeSearch.contentTextEngine = newValue }
    }
    var contentTextEngineChoices: [ContentTextEngine] { activeSearch.contentTextEngineChoices }
    var availableDateFields: [SearchDateField] { activeSearch.availableDateFields }

    func importCommand(_ command: String, runNative: Bool = false) throws {
        let snapshot = try runNative
            ? NativeSearchCommand(command: command, directory: scopeURL.path).snapshot()
            : CLICommandParser.parse(command, currentDirectory: scopeURL)
        // Validate the complete translated search before changing any controls.
        _ = try SearchPipelineCompiler(tools: liveSearchService.tools).compile(snapshot.makeRequest())
        applySnapshot(snapshot)
    }

    func useSearchControls() {
        var state = activeSearch
        state.nativeCommand = nil; state.sourceCommand = nil
        state.mode = .files; state.syntax = .literal
        applySnapshot(state)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Directory"
        panel.directoryURL = scopeURL

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        updateScope(url)
    }

    @discardableResult
    func updateScopePath(_ rawPath: String) -> Bool {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            executionStatusMessage = "Enter a search folder."
            return false
        }
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expandedPath).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            executionStatusMessage = "Directory not found: \(candidate.path)"
            return false
        }
        updateScope(isDirectory.boolValue ? candidate : candidate.deletingLastPathComponent())
        return true
    }

    func stopSearch() {
        cancelPendingSearch()
        searchGeneration = UUID()
        isSearching = false
        executionStatusMessage = stoppedSearchMessage()
    }

    @discardableResult
    func shutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        let tasks = [contentPreparationTask, pendingSearchTask, indexBuildTask, footerMessageTask,
                     wordStatusTask, inspectionTask, resultPageTask, matchPositionTask, loadStateTask].compactMap { $0 }
            + Array(cancelledTasks.values)
        for task in tasks { task.cancel() }
        searchGeneration = UUID()
        inspectionGeneration = UUID()
        pageGeneration = UUID()
        isSearching = false
        toolObservations.removeAll()
        libraryObservation = nil
        libraryErrorObservation = nil
        contentPreparationTask = nil
        pendingSearchTask = nil
        indexBuildTask = nil
        footerMessageTask = nil
        wordStatusTask = nil
        inspectionTask = nil
        resultPageTask = nil
        matchPositionTask = nil
        loadStateTask = nil
        // Await cancellation so a worker that needs the runner's SIGKILL
        // fallback does not outlive the app. The app bounds the overall wait.
        let completion = Task { for task in tasks { await task.value } }
        shutdownTask = completion
        return completion
    }

    private func cancelPendingSearch() {
        trackCancellation(pendingSearchTask)
        pendingSearchTask = nil
    }

    private func trackCancellation(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        // A replacement query can finish before an older cancelled worker has
        // exited. Retain its completion until reaping finishes, including quit.
        let id = UUID()
        cancelledTasks[id] = Task { [weak self] in
            await task.value
            self?.cancelledTasks[id] = nil
        }
    }

    func usePrimaryDriveScope() {
        updateScope(DriveDiscovery.primaryVolume().url)
    }

    func browse(to url: URL) {
        updateScope(url)
    }

    func persistDisplayPreferences() {
        library.includeHidden = includeHidden
        library.showIcons = showIcons
        persistLibrary()
    }

    func persistEmptySearchPreference() {
        library.emptySearchBehavior = emptySearchBehavior
        persistLibrary()
        scheduleSearch(immediate: true)
    }

    func chooseDefaultSearchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Default Directory"
        panel.directoryURL = URL(fileURLWithPath: defaultSearchDirectoryPath)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        setDefaultSearchDirectory(url)
    }

    func updateDefaultSearchDirectoryPath(_ rawPath: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaultDirectoryError = "Choose a folder or enter its path."
            return
        }

        let expandedPath = (trimmed as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expandedPath).standardizedFileURL

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            defaultDirectoryError = "Folder not found: \(candidate.path)"
            return
        }

        setDefaultSearchDirectory(isDirectory.boolValue ? candidate : candidate.deletingLastPathComponent())
    }

    func useCurrentScopeAsDefaultDirectory() {
        setDefaultSearchDirectory(scopeURL)
    }

    func useHomeAsDefaultDirectory() {
        setDefaultSearchDirectory(FileManager.default.homeDirectoryForCurrentUser)
    }

    func openSelected() {
        openResults(selectedResults)
    }

    func openResults(_ results: [SearchResult]) {
        var seen = Set<String>()
        for result in results where seen.insert(result.documentIdentity).inserted { openResult(result) }
    }

    func openInEditor(_ result: SearchResult) {
        guard let line = result.lineNumber else { return }
        guard let destination = preferredEditor.installedApplication(),
            let link = destination.editor.fileURL(result.url, line: line)
        else {
            editorError =
                preferredEditor == .automatic
                ? "Install Visual Studio Code, Cursor, or VSCodium to open matches at their line. Choose an editor in Settings → General."
                : "\(preferredEditor.title) is unavailable. Choose an installed editor in Settings → General."
            return
        }
        NSWorkspace.shared.open([link], withApplicationAt: destination.application, configuration: .init()) {
            [weak self] _, error in
            if let error {
                Task { @MainActor [weak self] in self?.editorError = error.localizedDescription }
            }
        }
    }

    func persistEditorPreference() {
        library.preferredEditor = preferredEditor
        persistLibrary()
    }

    func revealSelected() {
        revealResults(selectedResults)
    }

    func copySelectedPath() {
        copyPaths(selectedResults)
    }

    func revealResults(_ results: [SearchResult]) {
        let urls = ResultExport.uniqueURLs(results)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyPaths(_ results: [SearchResult]) {
        copyText(ResultExport.paths(results), message: "Copied file paths.")
    }

    func copyMatchingLines(_ results: [SearchResult]) {
        copyText(ResultExport.matchingLines(results), message: "Copied matching lines.")
    }

    private func copyText(_ text: String, message: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showTransientFooterMessage(message)
    }

    func copyFiles(_ results: [SearchResult]) {
        let urls = ResultExport.uniqueURLs(results)
        guard !urls.isEmpty else { return }
        guard ResultTransfer.copyFiles(results, to: .general) else {
            showTransientFooterMessage("Could not copy files.")
            return
        }
        showTransientFooterMessage("Copied \(urls.count) file\(urls.count == 1 ? "" : "s").")
    }

    func exportResults(_ results: [SearchResult]) {
        guard !results.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "FindUI Results.csv"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ResultExport.csv(results).write(to: url, atomically: true, encoding: .utf8)
            showTransientFooterMessage("Exported \(results.filter { !$0.isParentDirectoryEntry }.count) results.")
        } catch { actionError = error.localizedDescription }
    }

    func exportAllResults() {
        guard let resultStore, totalResultCount > 0 else {
            exportResults(results)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "FindUI Results.csv"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sort = resultSort
        Task {
            do {
                let count = try await resultStore.exportCSV(to: url, sort: sort)
                showTransientFooterMessage("Exported \(count.formatted()) results.")
            } catch { actionError = error.localizedDescription }
        }
    }

    func copyCommandPreview(to pasteboard: NSPasteboard = .general) {
        guard !commandPreview.isEmpty else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(nativeCommand ?? commandPreview, forType: .string)
        showTransientFooterMessage(nativeCommand == nil ? "Copied search details." : "Copied command.")
    }

    var nativeCommand: String? {
        guard !commandPreview.isEmpty else { return nil }
        return commandPreview.isEmpty ? liveSearchService.shellCommand(for: buildRequest()) : commandPreview
    }

    func showQuickLook(for result: SearchResult) {
        selectResult(result)
        quickLookURL = result.url
    }

    func quickLookSelected() {
        guard let result = selectedResult else {
            return
        }
        showQuickLook(for: result)
    }

    func toggleQuickLook() {
        if quickLookURL != nil {
            closeQuickLook()
        } else {
            quickLookSelected()
        }
    }

    func toggleQuickLook(using orderedResults: [SearchResult]) {
        if quickLookURL != nil {
            closeQuickLook()
            return
        }

        guard let result = preferredQuickLookResult(in: orderedResults) else {
            return
        }
        showQuickLook(for: result)
    }

    func closeQuickLook() {
        quickLookURL = nil
    }

    func moveQuickLookSelection(in orderedResults: [SearchResult], by offset: Int) {
        guard
            offset != 0,
            !orderedResults.isEmpty,
            let currentIndex = preferredQuickLookSelectionIndex(in: orderedResults)
        else {
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), orderedResults.count - 1)
        guard nextIndex != currentIndex else {
            return
        }

        showQuickLook(for: orderedResults[nextIndex])
    }

    func canMoveQuickLookSelection(in orderedResults: [SearchResult], by offset: Int) -> Bool {
        guard
            offset != 0,
            !orderedResults.isEmpty,
            let currentIndex = preferredQuickLookSelectionIndex(in: orderedResults)
        else {
            return false
        }

        let nextIndex = currentIndex + offset
        return nextIndex >= 0 && nextIndex < orderedResults.count
    }

    func acceptDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
            guard
                let self,
                let data,
                let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.updateScope(Self.normalizeDroppedScope(url))
            }
        }

        return true
    }

    func runHistoryEntry(_ entry: SearchHistoryEntry) {
        selectedHistoryEntryID = entry.id
        applySnapshot(entry.snapshot)
    }

    func togglePinned(_ entry: SearchHistoryEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else {
            return
        }

        history[index].isPinned.toggle()
        history[index].pinOrder = history[index].isPinned ? nextPinnedOrder() : nil
        library.history = history
        persistLibrary()
    }

    func deleteHistoryEntry(_ entry: SearchHistoryEntry) {
        if selectedHistoryEntryID == entry.id {
            selectedHistoryEntryID = nil
        }
        history.removeAll { $0.id == entry.id }
        library.history = history
        persistLibrary()
    }

    func clearHistory() {
        history = []
        library.history = history
        selectedHistoryEntryID = nil
        persistLibrary()
    }

    func movePinnedHistory(from offsets: IndexSet, to destination: Int) {
        var pinned = pinnedHistory
        pinned.move(fromOffsets: offsets, toOffset: destination)

        for (index, item) in pinned.enumerated() {
            if let historyIndex = history.firstIndex(where: { $0.id == item.id }) {
                history[historyIndex].pinOrder = index
            }
        }

        library.history = history
        persistLibrary()
    }

    func chooseManagerDrive(path: String) {
        selectedManagerDrivePath = path
        library.selectedDrivePath = path
        persistLibrary()

        refreshInspectedPage(reset: true)
    }

    func buildIndexForSelectedManagerDrive() {
        guard !isBuildingIndex, let drive = selectedManagerDrive else {
            return
        }

        isBuildingIndex = true
        indexManagerStatusMessage = "Indexing \(drive.name)…"
        let existing = selectedManagerIndex
        let createdAt = existing?.createdAt ?? Date()
        let scanOptions = traversal.normalized

        indexBuildTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                isBuildingIndex = false
                indexBuildTask = nil
                if let existing { libraryStore.resumeMaintenance(for: existing.id) }
            }

            do {
                if let existing { await libraryStore.stopMaintenance(for: existing.id) }
                let eventID = IndexMaintenanceClock.currentEventID
                let build = try await indexService.buildIndex(
                    id: existing?.id ?? UUID(),
                    name: drive.name,
                    scope: drive.url,
                    includeHidden: true,
                    traversal: scanOptions
                )

                var metadata = build.metadata
                metadata.createdAt = createdAt
                metadata.updatedAt = Date()
                metadata.includeHidden = true
                metadata.automaticRefresh = existing?.automaticRefresh

                try Task.checkCancellation()
                try await persistence.saveIndex(
                    IndexArtifact(metadata: metadata, entries: build.entries, lastEventID: eventID))
                upsertIndex(metadata)
                refreshInspectedPage(reset: true)
                library.selectedDrivePath = drive.url.path
                persistLibrary()

                indexManagerStatusMessage =
                    metadata.warning == nil
                    ? "Indexed \(metadata.entryCount) items on \(drive.name)."
                    : "Partial index: some locations could not be read. \(metadata.entryCount) items indexed."

                if enableIndexAfterBuild && currentDrive.url.path == drive.url.path {
                    useIndex = true
                    enableIndexAfterBuild = false
                }

                if useIndex && currentDrive.url.path == drive.url.path {
                    scheduleSearch(immediate: true)
                }
            } catch is CancellationError {
                indexManagerStatusMessage = "Index refresh cancelled. The previous index is unchanged."
                enableIndexAfterBuild = false
            } catch {
                indexManagerStatusMessage = error.localizedDescription
                executionStatusMessage = "Index refresh failed: \(error.localizedDescription)"
                enableIndexAfterBuild = false
            }
        }
    }

    func refreshCurrentIndex() {
        guard !isBuildingIndex else { return }
        selectedManagerDrivePath = currentDrive.url.path
        buildIndexForSelectedManagerDrive()
    }

    func cancelIndexBuild() {
        indexBuildTask?.cancel()
    }

    func setAutomaticIndexRefresh(_ enabled: Bool, index: ManagedIndex) {
        var updated = index
        updated.automaticRefresh = enabled
        upsertIndex(updated)
        if enabled { libraryStore.resumeMaintenance(for: index.id) }
        persistLibrary()
    }

    func copyIndexMaintenanceCommand(_ index: ManagedIndex) {
        do {
            let command = try HeadlessCLI.indexCommand(index, output: persistence.indexURL(index.id), watch: true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } catch { indexManagerStatusMessage = error.localizedDescription }
    }

    func handleIndexedToggleChanged() {
        guard useIndex else {
            enableIndexAfterBuild = false
            return
        }
        guard mode != .contents else {
            useIndex = false
            return
        }
        guard currentDriveIndex == nil else {
            return
        }
        useIndex = false
        isIndexPromptPresented = true
    }

    func confirmIndexCurrentDrive() {
        isIndexPromptPresented = false
        enableIndexAfterBuild = true
        selectedManagerDrivePath = currentDrive.url.path
        buildIndexForSelectedManagerDrive()
    }

    func cancelIndexPrompt() {
        isIndexPromptPresented = false
        useIndex = false
        enableIndexAfterBuild = false
    }

    func deleteIndexForSelectedManagerDrive() {
        guard let index = selectedManagerIndex else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                await libraryStore.stopMaintenance(for: index.id)
                try await persistence.deleteEntries(for: index.id)
                managedIndexes.removeAll { $0.id == index.id }
                library.managedIndexes = managedIndexes
                persistLibrary()

                inspectedEntries = []
                indexManagerStatusMessage = "Deleted the index for \(selectedManagerDrive?.name ?? index.name)."

                if useIndex && currentDrive.url.path == index.scopePath {
                    results = []
                    selectedResultID = nil
                    commandPreview = currentCommandPreview()
                    executionStatusMessage = "No index exists for \(currentDrive.name). Build one in Settings."
                }
            } catch {
                indexManagerStatusMessage = error.localizedDescription
            }
        }
    }

    func revealSelectedManagerIndexFile() {
        guard let index = selectedManagerIndex else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([FindUIPaths.indexEntriesFileURL(for: index.id)])
    }

    func revealSelectedManagerDrive() {
        guard let drive = selectedManagerDrive else {
            return
        }
        NSWorkspace.shared.open(drive.url)
    }

    func refreshVolumes() {
        availableVolumes = DriveDiscovery.availableVolumes()
        if !availableVolumes.contains(where: { $0.url.path == selectedManagerDrivePath }) {
            selectedManagerDrivePath = DriveDiscovery.primaryVolume().url.path
        }
    }

    func openParentFolderForSelectedResult() {
        guard let url = selectedResult?.url.deletingLastPathComponent() else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openParentFolder(for result: SearchResult) {
        NSWorkspace.shared.open(result.url.deletingLastPathComponent())
    }

    func openScopeInFinder() {
        do { try FolderActions.openFinder(at: scopeURL) }
        catch { actionError = error.localizedDescription }
    }

    func openScopeInTerminal() {
        openTerminal(at: scopeURL)
    }

    func openTerminal(for result: SearchResult) {
        openTerminal(at: FolderActions.terminalDirectory(for: result))
    }

    private func openTerminal(at directory: URL) {
        Task {
            do { try await FolderActions.openTerminal(at: directory) }
            catch { actionError = error.localizedDescription }
        }
    }

    func openResult(_ result: SearchResult) {
        if result.extractedOrigin?.metadataOnly == true || result.extractedOrigin?.memberKind == "directory" {
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
            return
        }
        if let origin = result.extractedOrigin, origin.memberPath != nil && origin.memberKind != "directory" {
            let request = DocumentAccess.Request(
                path: result.path, origin: origin, extraction: refinements.extraction ?? .init())
            Task {
                do { NSWorkspace.shared.open(try await DocumentMaterializer.shared.file(request)) } catch {
                    actionError = error.localizedDescription
                }
            }
            return
        }
        NSWorkspace.shared.open(result.url)
    }

    func reloadPresets() {
        do {
            presets = try presetStore.read().presets
            presetError = nil
        } catch { presetError = error.localizedDescription }
    }
    func savePreset(name: String, kind: SearchPresetKind, replacing id: UUID? = nil) {
        var preset = SearchPreset(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, state: searchState)
        if let id { preset.id = id }
        do {
            presets = try presetStore.change { collection in
                if let index = collection.presets.firstIndex(where: { $0.id == preset.id }) {
                    collection.presets[index] = preset
                } else {
                    collection.presets.append(preset)
                }
            }.presets
            presetError = nil
        } catch { presetError = error.localizedDescription }
    }
    func renamePreset(_ preset: SearchPreset, name: String) {
        do {
            presets = try presetStore.change { collection in
                if let index = collection.presets.firstIndex(where: { $0.id == preset.id }) {
                    collection.presets[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    collection.presets[index].updatedAt = .now
                }
            }.presets
            presetError = nil
        } catch { presetError = error.localizedDescription }
    }
    func deletePreset(_ preset: SearchPreset) {
        do {
            presets = try presetStore.change { $0.presets.removeAll { $0.id == preset.id } }.presets
            presetError = nil
        } catch { presetError = error.localizedDescription }
    }
    @discardableResult func applyPreset(_ preset: SearchPreset) -> Bool {
        do {
            applySnapshot(try preset.applying(to: searchState))
            presetError = nil
            return true
        } catch {
            presetError = error.localizedDescription
            return false
        }
    }
    func searchTheseFiles() {
        guard !isSearching, !savingResultScope, let resultStore, totalResultCount > 0 else { return }
        let original = searchState
        savingResultScope = true
        Task {
            defer { savingResultScope = false }
            do {
                let scope = try await resultStore.saveScope(name: "Results of \(original.title)")
                guard searchState == original else { return }
                applySnapshot(original.searchingResults(scope))
            } catch { actionError = error.localizedDescription }
        }
    }
    func clearResultScope() {
        applySnapshot(searchState.clearingResultScope())
    }
    func explainFile() {
        let panel = NSOpenPanel()
        panel.title = "Explain a File"
        panel.prompt = "Explain"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = scopeURL
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let request = buildRequest()
        let snapshot = request.useIndex ? currentDriveIndex.map { persistence.indexURL($0.id) } : nil
        explainingFile = true
        Task {
            defer { explainingFile = false }
            do {
                fileExplanation = try await SearchExplainer(tools: liveSearchService.tools).explain(
                    request, file: file, snapshot: snapshot)
            } catch { actionError = error.localizedDescription }
        }
    }
    func prepareContentIndex() {
        if preparingContents {
            contentPreparationTask?.cancel()
            return
        }
        var request = buildRequest()
        do {
            try request.state.promoteToRules()
            let rules = SearchRuleSet(files: request.state.ruleSet!.candidateFiles, contents: .rule(.allLines))
            request.state.replaceRules(rules)
            request.buildWordIndex = refinements.wordSearch == true
            request.buildContentIndex = !request.buildWordIndex
            request.refinements.wordSearch = nil
            request.refinements.multiline = nil
            request.refinements.useContentIndex = true
            request.refinements.extraction?.cacheText = true
            let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(request)
            preparingContents = true
            contentPreparationStatus = "Preparing content for files in this scope…"
            contentPreparationTask = Task {
                defer {
                    preparingContents = false
                    contentPreparationTask = nil
                }
                do {
                    let result = try await ProcessRunner.run(
                        spec: pipeline.spec, pathOverride: Toolchain.resolve().searchPath)
                    if result.exitCode == 0 {
                        refinements.useContentIndex = true
                        let statistics = result.stderr.split(separator: "\n").first { $0.hasPrefix("findui-stats: ") }
                            .flatMap {
                                try? JSONSerialization.jsonObject(with: Data($0.dropFirst(14).utf8)) as? [String: Any]
                            }
                        let prepared = (statistics?["indexesUpdated"] as? NSNumber)?.intValue ?? 0
                        let reused = (statistics?["filesSkippedByIndex"] as? NSNumber)?.intValue ?? 0
                        contentPreparationStatus =
                            "Prepared \(prepared) files; reused \(reused) unchanged files. \(request.buildWordIndex ? "Word index updated." : "Small text files are searched directly.")"
                        if request.buildWordIndex && refinements.wordSearch == true { scheduleSearch(immediate: true) }
                    } else {
                        contentPreparationStatus = result.stderr
                    }
                } catch {
                    contentPreparationStatus =
                        Task.isCancelled
                        ? "Preparation cancelled. Completed files are retained." : error.localizedDescription
                }
            }
        } catch { contentPreparationStatus = error.localizedDescription }
    }

    func refreshWordStatus() {
        trackCancellation(wordStatusTask)
        wordIndexStatus = nil
        guard refinements.wordSearch == true else { return }
        // A running search returns its own status from the same index snapshot.
        guard contentsInput.isEmpty, searchRules == nil else { return }
        let request = buildRequest()
        wordStatusTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let status = try await WordIndexService.status(request)
                guard !Task.isCancelled else { return }
                wordIndexStatus = status
            } catch {}
        }
    }
    func wordCompletions(_ text: String) async -> [String] {
        await WordIndexService.completions(
            buildRequest(), text: text, history: history.map { $0.snapshot.contentsInput })
    }
    func resultFacets() async -> [ResultFacet] { (try? await resultStore?.facets()) ?? [] }
    func applyFacet(_ facet: ResultFacet) {
        do { applySnapshot(try facet.applying(to: searchState)) } catch { actionError = error.localizedDescription }
    }

    func selectResult(_ result: SearchResult) {
        selectedResultID = result.id
    }

    func maybePresentPermissionHelp(for message: String) {
        if FileAccessFailure.matches(message) { offerPermissionHelp() }
    }

    private func maybePresentPermissionHelp(for error: Error) {
        if FileAccessFailure.matches(error) { offerPermissionHelp() }
    }

    private func offerPermissionHelp() {
        hasPermissionFailure = true
        // Keep help available in the footer without interrupting each retry.
        if !hasOfferedPermissionHelp {
            hasOfferedPermissionHelp = true
            isPermissionHelpPresented = true
        }
    }

    private func loadPersistedState() async {
        do {
            let loaded = try await libraryStore.load()
            guard !Task.isCancelled, shutdownTask == nil else { return }
            managedIndexes = loaded.managedIndexes
            history = loaded.history
            includeHidden = loaded.includeHidden
            showIcons = loaded.showIcons
            preferredEditor = loaded.preferredEditor
            emptySearchBehavior = loaded.emptySearchBehavior
            traversal = loaded.traversal

            let defaultDirectory =
                Self.validDirectoryURL(from: loaded.defaultSearchDirectoryPath)
                ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            defaultSearchDirectoryPath = defaultDirectory.path
            scopeURL = defaultDirectory

            let persistedDrive = loaded.selectedDrivePath ?? DriveDiscovery.primaryVolume().url.path
            if availableVolumes.contains(where: { $0.url.path == persistedDrive }) {
                selectedManagerDrivePath = persistedDrive
            }

            await loadInspectedEntriesForSelectedDrive()
            commandPreview = currentCommandPreview()
            scheduleSearch(immediate: true)
        } catch {
            executionStatusMessage = "Failed to load saved settings."
        }
    }

    private func buildRequest() -> SearchRequest {
        currentSnapshot().makeRequest()
    }

    private func currentSnapshot() -> SearchSnapshot {
        var snapshot = activeSearch
        snapshot.query = normalizedQuery
        snapshot.useIndex = useIndex && mode != .contents
        snapshot.exactNameMatch = modeSupportsExactName ? exactNameMatch : false
        snapshot.selectedDrivePath = currentDrive.url.path
        snapshot.indexedFilter = mode == .everything ? .everything : mode == .folders ? .folders : .files
        snapshot.traversal = traversal.normalized
        snapshot.sourceCommand = nil
        if var imported = importedSnapshot {
            let command = imported.sourceCommand
            imported.sourceCommand = nil
            imported.selectedDrivePath = snapshot.selectedDrivePath
            if imported == snapshot { snapshot.sourceCommand = command }
        }
        return snapshot
    }

    private func applySnapshot(_ snapshot: SearchSnapshot) {
        restoreSearchState(snapshot)
        scheduleSearch(immediate: true)
    }

    /// AI proposals have already passed the shared backend validator and
    /// compact projection. Apply once and run through the ordinary search path.
    func applyGeneratedSearch(_ state: SearchState) {
        applySnapshot(state)
    }

    /// Restore every editable control in one publication. History and imports
    /// call this before running; the contract audit uses it without executing.
    func restoreSearchState(_ snapshot: SearchState) {
        restoringSearchState = true
        defer { restoringSearchState = false }
        importedSnapshot = nil
        var restored = snapshot
        restored.preserveLegacyFileQuery()
        restored.selectRequiredSource()
        activeSearch = restored
        if snapshot.sourceCommand != nil {
            var canonical = currentSnapshot()
            canonical.sourceCommand = snapshot.sourceCommand
            importedSnapshot = canonical
        }
        selectedHistoryEntryID = history.first(where: { $0.snapshot == snapshot })?.id
        searchStateRevision += 1
    }

    private func updateScope(_ url: URL) {
        activeSearch.resultScope = nil
        scopeURL = url.standardizedFileURL
        executionStatusMessage = "Scope set to \(scopeURL.path)."
        commandPreview = currentCommandPreview()
        scheduleSearch(immediate: true)
    }

    private func currentCommandPreview(for request: SearchRequest? = nil) -> String {
        var request = request ?? buildRequest()
        request.isDirectoryListing = isBrowsingDirectory
        if request.useIndex {
            engineName = "Snapshot"
            commandSummary = ""
            guard let index = currentDriveIndex else {
                return ""
            }
            return (try? HeadlessCLI.searchCommand(request, snapshot: persistence.indexURL(index.id), index: index))
                ?? ""
        }
        guard let pipeline = try? SearchPipelineCompiler(tools: liveSearchService.tools).compile(request) else {
            engineName = ""
            commandSummary = ""
            return ""
        }
        engineName = pipeline.engineName
        commandSummary = pipeline.displayCommand
        return pipeline.script
    }

    private func performSearch(request: SearchRequest, prepared: PreparedSearch?, generation: UUID) async {
        isSearching = true
        hasPermissionFailure = false
        results = []
        commandOutput = nil
        commandError = nil
        totalResultCount = 0
        resultPage = 0
        resultStore = nil
        lastPresentedRevision = -1
        selectedResultID = nil
        if request.isDirectoryListing { resultSort = [.init(column: "name", descending: false)] }
        executionStatusMessage =
            request.isDirectoryListing ? "Loading \(request.scope.path)…" : "Searching \(request.scope.path)…"
        do {
            let operation: PreparedSearch
            if let prepared {
                operation = prepared
            } else {
                guard let index = currentDriveIndex else { throw SearchServiceError.missingIndex }
                operation = try await PreparedSearch.snapshot(
                    request: request, at: persistence.indexURL(index.id), tools: liveSearchService.tools,
                    legacyIndex: index)
            }
            try Task.checkCancellation()
            guard generation == searchGeneration else { return }
            let session = try SearchSession(prepared: operation)
            resultStore = session.results
            commandPreview = operation.command
            commandSummary = operation.pipeline.displayCommand
            engineName = operation.engineName
            let prefix = request.isDirectoryListing ? directoryListingPrefixResults(for: request.scope) : []
            let summary = try await session.run(tools: liveSearchService.tools, prefix: prefix, onOutput: { [weak self] output in
                await self?.publishCommandOutput(output, generation: generation)
            }) { [weak self] in
                await self?.publishResults(generation: generation)
            }
            guard generation == searchGeneration else { return }
            wordIndexStatus = summary.wordStatus
            executionStatusMessage =
                request.isDirectoryListing && summary.warning == nil
                ? directoryListingMessage(resultCount: max(0, totalResultCount - prefix.count), scope: request.scope)
                : summary.commandOutput == nil && results.isEmpty && summary.warning == nil && !summary.isTruncated
                    ? noResultsMessage(for: request) : summary.statusMessage(resultCount: totalResultCount)
            if let warning = summary.warning { maybePresentPermissionHelp(for: warning) }
            if !request.isDirectoryListing { recordHistory(for: request) }
        } catch is CancellationError {} catch {
            guard generation == searchGeneration else { return }
            if request.state.nativeCommand != nil { commandError = error.localizedDescription }
            executionStatusMessage =
                results.isEmpty
                ? error.localizedDescription
                : "\(totalResultCount) matches. Search incomplete: \(error.localizedDescription)"
            maybePresentPermissionHelp(for: error)
        }
        if generation == searchGeneration {
            isSearching = false
            pendingSearchTask = nil
        }
    }

    private func publishCommandOutput(_ output: CommandTextOutput, generation: UUID) {
        guard generation == searchGeneration else { return }
        commandOutput = output
    }

    private func publishResults(generation: UUID) async {
        guard generation == searchGeneration, let resultStore else { return }
        do {
            let pageID = pageGeneration
            let page = resultPage
            let sort = resultSort
            let presentation = try await resultStore.presentation(page, sort: sort)
            let rows = presentation.rows
            let revision = presentation.revision
            let totals = presentation.totals
            let count = presentation.count
            guard generation == searchGeneration, pageID == pageGeneration else { return }
            totalResultCount = count
            resultTotals = totals
            if revision != lastPresentedRevision {
                lastPresentedRevision = revision
                results = rows
                refreshMatchPosition()
            }
            if selectedResultID == nil { selectedResultID = results.first?.id }
            executionStatusMessage = "\(count.formatted()) matches · Searching…"
        } catch is CancellationError {} catch {
            if generation == searchGeneration {
                actionError = error.localizedDescription
                stopSearch()
            }
        }
    }

    private func recordHistory(for request: SearchRequest) {
        let snapshot = currentSnapshot()
        let existingPinned = history.first(where: { $0.snapshot == snapshot })?.isPinned ?? false
        let existingPinOrder = history.first(where: { $0.snapshot == snapshot })?.pinOrder
        let entry = SearchHistoryEntry(
            id: history.first(where: { $0.snapshot == snapshot })?.id ?? UUID(),
            snapshot: snapshot,
            searchedAt: Date(),
            resultCount: totalResultCount,
            engineName: engineName,
            isPinned: existingPinned,
            pinOrder: existingPinOrder
        )

        history.removeAll { $0.snapshot == snapshot }
        history.insert(entry, at: 0)
        history = Array(history.prefix(150))
        library.history = history
        selectedHistoryEntryID = entry.id
        persistLibrary()
    }

    func moveInspectedPage(_ offset: Int) {
        inspectedPage = max(0, inspectedPage + offset)
        refreshInspectedPage(reset: false)
    }
    func refreshInspectedPage(reset: Bool) {
        inspectionTask?.cancel()
        if reset {
            inspectedPage = 0
            inspectedEntries = []
            inspectedHasMore = false
        }
        inspectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.loadInspectedEntriesForSelectedDrive()
        }
    }
    private func loadInspectedEntriesForSelectedDrive() async {
        let generation = UUID()
        inspectionGeneration = generation
        guard let index = selectedManagerIndex else {
            inspectedEntries = []
            inspectedHasMore = false
            indexManagerStatusMessage = "No index exists for \(selectedManagerDrive?.name ?? selectedManagerDrivePath)."
            return
        }
        let url = persistence.indexURL(index.id)
        let page = inspectedPage
        let filter = inspectedIndexFilter
        let work = Task.detached(priority: .userInitiated) { () throws -> ([IndexedEntry], Bool) in
            if IndexDatabase.isDatabase(url) { return try IndexDatabase(url).page(page, filter: filter) }
            // Legacy snapshots need a single migration read. Cancellation and
            // page slicing remain outside the main actor.
            let artifact = try IndexArtifact.load(url, legacyMetadata: index)
            try Task.checkCancellation()
            let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            let rows = artifact.entries.filter {
                needle.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(needle)
            }
            let start = min(rows.count, page * 200)
            let end = min(rows.count, start + 200)
            return (Array(rows[start..<end]), end < rows.count)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, inspectionGeneration == generation, selectedManagerIndex?.id == index.id else {
                return
            }
            inspectedEntries = result.0
            inspectedHasMore = result.1
            indexManagerStatusMessage = "Inspecting \(index.entryCount) indexed items for \(index.name)."
        } catch is CancellationError {} catch {
            guard inspectionGeneration == generation else { return }
            inspectedEntries = []
            inspectedHasMore = false
            indexManagerStatusMessage = error.localizedDescription
        }
    }

    private func upsertIndex(_ metadata: ManagedIndex) {
        managedIndexes.removeAll { $0.scopePath == metadata.scopePath }
        managedIndexes.append(metadata)
        managedIndexes.sort { lhs, rhs in
            if lhs.scopePath == "/" {
                return true
            }
            if rhs.scopePath == "/" {
                return false
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        library.managedIndexes = managedIndexes
    }

    private func persistLibrary() { libraryStore.save() }

    private func volume(for url: URL) -> StorageVolume {
        let path = url.standardizedFileURL.path
        return
            availableVolumes
            .sorted { $0.url.path.count > $1.url.path.count }
            .first(where: { SearchPath.contains(URL(fileURLWithPath: path), in: $0.url) })
            ?? DriveDiscovery.primaryVolume()
    }

    private func noResultsMessage(for request: SearchRequest) -> String {
        if request.state.resultScope != nil { return "No matches in the saved results." }
        return request.useIndex
            ? "No indexed matches in \(request.scope.path)."
            : "No matches in \(request.scope.path)."
    }

    private func directoryListingMessage(resultCount: Int, scope: URL) -> String {
        switch resultCount {
        case 0:
            return "Directory is empty."
        case 1:
            return "Showing 1 item in \(scope.path)."
        default:
            return "Showing \(resultCount) items in \(scope.path)."
        }
    }

    private func matchCountLabel(_ count: Int) -> String {
        count == 1 ? "1 match." : "\(count) matches."
    }

    private func stoppedSearchMessage() -> String {
        let trimmedQuery = normalizedQuery

        if trimmedQuery.isEmpty && isBrowsingDirectory {
            let count = results.filter { !$0.isParentDirectoryEntry }.count
            return count == 1
                ? "Stopped after showing 1 item in \(scopeURL.path)."
                : "Stopped after showing \(count) items in \(scopeURL.path)."
        }

        switch totalResultCount {
        case 0:
            return "Search stopped."
        case 1:
            return "Stopped after 1 match."
        default:
            return "Stopped after \(totalResultCount) matches."
        }
    }

    private func directoryListingPrefixResults(for scope: URL) -> [SearchResult] {
        guard scope.standardizedFileURL.path != "/" else {
            return []
        }

        let parentURL = scope.deletingLastPathComponent().standardizedFileURL
        return [
            SearchResult(
                url: parentURL,
                kind: .folder,
                displayNameOverride: "../",
                directoryPathOverride: scope.path,
                browseTargetURL: parentURL,
                isParentDirectoryEntry: true,
                typeDescription: "Directory",
                matchRank: -1,
                sourceOrder: -1
            )
        ]
    }

    private func nextPinnedOrder() -> Int {
        let maxValue = history.compactMap(\.pinOrder).max() ?? -1
        return maxValue + 1
    }

    private func showTransientFooterMessage(_ value: String) {
        transientFooterMessage = value
        footerMessageTask?.cancel()
        footerMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transientFooterMessage = nil
            }
        }
    }

    private static func normalizeDroppedScope(_ url: URL) -> URL {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        return url
    }

    private func preferredQuickLookResult(in orderedResults: [SearchResult]) -> SearchResult? {
        if let selectedResultID, let match = orderedResults.first(where: { $0.id == selectedResultID }) {
            return match
        }

        if let quickLookURL, let match = orderedResults.first(where: { $0.url == quickLookURL }) {
            return match
        }

        return orderedResults.first
    }

    private func preferredQuickLookSelectionIndex(in orderedResults: [SearchResult]) -> Int? {
        guard let result = preferredQuickLookResult(in: orderedResults) else {
            return nil
        }
        return orderedResults.firstIndex(of: result)
    }

    private func quickLookSelectionIndex(in orderedResults: [SearchResult]) -> Int? {
        if let selectedResultID, let index = orderedResults.firstIndex(where: { $0.id == selectedResultID }) {
            return index
        }

        guard let quickLookURL else {
            return nil
        }
        return orderedResults.firstIndex(where: { $0.url == quickLookURL })
    }

    private static func describeInstalledTools(_ tools: Toolchain) -> String {
        [
            tools.fd.map { _ in "fd" },
            tools.rg.map { _ in "rg" },
            tools.fzf.map { _ in "fzf" },
            tools.find.map { _ in "find" },
            tools.contentWorker.map { _ in "findui-content" },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private static func describeToolLocations(_ tools: Toolchain) -> [ToolLocationInfo] {
        [
            tools.fd.map { ToolLocationInfo(name: "fd", path: $0.path) },
            tools.rg.map { ToolLocationInfo(name: "rg", path: $0.path) },
            tools.fzf.map { ToolLocationInfo(name: "fzf", path: $0.path) },
            tools.find.map { ToolLocationInfo(name: "find", path: $0.path) },
            tools.mdfind.map { ToolLocationInfo(name: "mdfind", path: $0.path) },
            tools.contentWorker.map { ToolLocationInfo(name: "findui-content", path: $0.path) },
            tools.pandoc.map { ToolLocationInfo(name: "Pandoc", path: $0.path) },
            tools.pdftotext.map { ToolLocationInfo(name: "Poppler", path: $0.path) },
            tools.ffmpeg.map { ToolLocationInfo(name: "FFmpeg", path: $0.path) },
            tools.ffprobe.map { ToolLocationInfo(name: "FFprobe", path: $0.path) },
            tools.tikaJar.map { ToolLocationInfo(name: "Tika", path: $0.path) },
        ]
        .compactMap { $0 }
    }

    private func setDefaultSearchDirectory(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        defaultSearchDirectoryPath = standardizedURL.path
        defaultDirectoryError = nil
        library.defaultSearchDirectoryPath = standardizedURL.path
        persistLibrary()
    }

    private static func validDirectoryURL(from rawPath: String?) -> URL? {
        guard let rawPath else {
            return nil
        }

        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expandedPath).standardizedFileURL

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return nil
        }

        return candidate
    }
}
