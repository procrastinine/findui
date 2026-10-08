import Foundation

package enum IndexedEntryKind: String, Codable, CaseIterable, Sendable {
    case file
    case folder

    package var title: String {
        switch self {
        case .file:
            "File"
        case .folder:
            "Directory"
        }
    }
}

package struct IndexedEntry: Identifiable, Codable, Hashable, Sendable {
    package let relativePath: String
    package let kind: IndexedEntryKind
    package let typeDescription: String?
    package let modifiedAt: Date?
    package let createdAt: Date?
    package let addedAt: Date?
    package let lastOpenedAt: Date?
    package let size: Int64?
    package var tags: [String]? = nil

    package init(
        relativePath: String,
        kind: IndexedEntryKind,
        typeDescription: String? = nil,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        addedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        size: Int64? = nil,
        tags: [String]? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.typeDescription = typeDescription
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.size = size
        self.tags = tags
    }

    package var id: String {
        "\(kind.rawValue):\(relativePath)"
    }

    package var name: String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    package var directoryPath: String {
        let path = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        return path == "." ? "/" : path
    }

    package var isHidden: Bool {
        relativePath
            .split(separator: "/")
            .contains { component in
                component.hasPrefix(".") && component != "." && component != ".."
            }
    }
}

package struct ManagedIndex: Identifiable, Codable, Hashable, Sendable {
    package let id: UUID
    package var name: String
    package var scopePath: String
    package var includeHidden: Bool
    package var createdAt: Date
    package var updatedAt: Date
    package var fileCount: Int
    package var folderCount: Int
    package var entryCount: Int
    package var engineName: String
    package var warning: String? = nil
    package var traversal: SearchTraversalOptions? = nil
    package var lastOpenedUsesSpotlight: Bool? = nil
    package var automaticRefresh: Bool? = nil
    package var queryGeneration: UUID? = nil

    package var scopeURL: URL {
        URL(fileURLWithPath: scopePath)
    }
    package init(id: UUID, name: String, scopePath: String, includeHidden: Bool, createdAt: Date, updatedAt: Date, fileCount: Int, folderCount: Int, entryCount: Int, engineName: String, warning: String? = nil, traversal: SearchTraversalOptions? = nil, lastOpenedUsesSpotlight: Bool? = nil, automaticRefresh: Bool? = nil, queryGeneration: UUID? = nil) {
        self.id = id
        self.name = name
        self.scopePath = scopePath
        self.includeHidden = includeHidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.entryCount = entryCount
        self.engineName = engineName
        self.warning = warning
        self.traversal = traversal
        self.lastOpenedUsesSpotlight = lastOpenedUsesSpotlight
        self.automaticRefresh = automaticRefresh
        self.queryGeneration = queryGeneration
    }

}

/// The one persisted search state used by controls, imports and execution.
/// Model output and legacy commands are adapters into this type, not parallel
/// stores of active options. A snapshot is a value copy of this same structure.
/// An editing preference, like an input mode, not a search predicate. Quick
/// input writes only existing contains/glob predicates into refinements.
package enum FilenameQueryStyle: String, Codable, Hashable, Sendable { case quick }

package struct SearchState: Codable, Equatable, Hashable, Sendable {
    package var criteria: SearchCriteria
    package var mode: SearchMode
    package var scopePath: String
    package var useIndex: Bool
    package var includeHidden: Bool
    package var caseSensitive: Bool
    package var selectedDrivePath: String?
    package var indexedFilter: IndexedEntryFilter
    package var traversal: SearchTraversalOptions
    package var sourceCommand: String?
    package var filenameQueryStyle: FilenameQueryStyle? = nil
    package var resultScope: SearchResultScope? = nil
    package var nativeCommand: NativeSearchCommand? = nil

    package init(
        query: String,
        mode: SearchMode,
        scopePath: String,
        useIndex: Bool,
        includeHidden: Bool,
        caseSensitive: Bool,
        syntax: SearchSyntax,
        exactNameMatch: Bool,
        selectedDrivePath: String?,
        indexedFilter: IndexedEntryFilter,
        filters: SearchFilters = .init(),
        traversal: SearchTraversalOptions = .init(),
        refinements: SearchRefinements = .init(),
        sourceCommand: String? = nil
    ) {
        self.criteria = .compact(.init(query: query, syntax: syntax, exactNameMatch: exactNameMatch,
                                       filters: filters, refinements: refinements))
        self.mode = mode
        self.scopePath = scopePath
        self.useIndex = useIndex
        self.includeHidden = includeHidden
        self.caseSensitive = caseSensitive
        self.selectedDrivePath = selectedDrivePath
        self.indexedFilter = indexedFilter
        self.traversal = traversal
        self.sourceCommand = sourceCommand
    }

    package enum CodingKeys: String, CodingKey {
        case criteria
        case query
        case mode
        case scopePath
        case useIndex
        case includeHidden
        case caseSensitive
        case syntax
        case exactNameMatch
        case selectedDrivePath
        case indexedFilter
        case filters
        case traversal
        case refinements
        case sourceCommand
        case contentQueryStyle
        case filenameQueryStyle
        case resultScope
        case nativeCommand
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let criteria = try container.decodeIfPresent(SearchCriteria.self, forKey: .criteria) {
            if [CodingKeys.query, .syntax, .exactNameMatch, .filters, .refinements, .contentQueryStyle].contains(where: container.contains) {
                throw DecodingError.dataCorruptedError(forKey: .criteria, in: container,
                    debugDescription: "Use one criteria representation; compact controls cannot accompany a criteria object.")
            }
            self.criteria = criteria
        } else {
            self.criteria = .compact(.init(
                query: try container.decode(String.self, forKey: .query),
                syntax: try container.decodeIfPresent(SearchSyntax.self, forKey: .syntax) ?? .literal,
                exactNameMatch: try container.decodeIfPresent(Bool.self, forKey: .exactNameMatch) ?? false,
                filters: try container.decodeIfPresent(SearchFilters.self, forKey: .filters) ?? .init(),
                refinements: try container.decodeIfPresent(SearchRefinements.self, forKey: .refinements) ?? .init(),
                contentQueryStyle: try container.decodeIfPresent(ContentQueryStyle.self, forKey: .contentQueryStyle)))
        }
        self.mode = try container.decode(SearchMode.self, forKey: .mode)
        if case .grouped(let rules, _) = criteria, (rules.hasContents) != (mode == .contents) {
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container,
                debugDescription: "The search mode must agree with the presence of content conditions.")
        }
        self.scopePath = try container.decode(String.self, forKey: .scopePath)
        self.useIndex = try container.decodeIfPresent(Bool.self, forKey: .useIndex) ?? false
        self.includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? true
        self.caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        self.selectedDrivePath = try container.decodeIfPresent(String.self, forKey: .selectedDrivePath)
        self.indexedFilter = try container.decodeIfPresent(IndexedEntryFilter.self, forKey: .indexedFilter) ?? .files
        self.traversal = try container.decodeIfPresent(SearchTraversalOptions.self, forKey: .traversal) ?? .init()
        self.sourceCommand = try container.decodeIfPresent(String.self, forKey: .sourceCommand)
        self.filenameQueryStyle = try container.decodeIfPresent(FilenameQueryStyle.self, forKey: .filenameQueryStyle)
        self.resultScope = try container.decodeIfPresent(SearchResultScope.self, forKey: .resultScope)
        self.nativeCommand = try container.decodeIfPresent(NativeSearchCommand.self, forKey: .nativeCommand)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(filenameQueryStyle, forKey: .filenameQueryStyle)
        try container.encodeIfPresent(resultScope, forKey: .resultScope)
        try container.encodeIfPresent(nativeCommand, forKey: .nativeCommand)
        switch criteria {
        case .compact(let value):
            try container.encode(value.query, forKey: .query)
            try container.encode(value.syntax, forKey: .syntax)
            try container.encode(value.exactNameMatch, forKey: .exactNameMatch)
            try container.encode(value.filters, forKey: .filters)
            try container.encode(value.refinements, forKey: .refinements)
            try container.encodeIfPresent(value.contentQueryStyle, forKey: .contentQueryStyle)
        case .grouped: try container.encode(criteria, forKey: .criteria)
        }
        try container.encode(mode, forKey: .mode)
        try container.encode(scopePath, forKey: .scopePath)
        try container.encode(useIndex, forKey: .useIndex)
        try container.encode(includeHidden, forKey: .includeHidden)
        try container.encode(caseSensitive, forKey: .caseSensitive)
        try container.encodeIfPresent(selectedDrivePath, forKey: .selectedDrivePath)
        try container.encode(indexedFilter, forKey: .indexedFilter)
        try container.encode(traversal, forKey: .traversal)
        try container.encodeIfPresent(sourceCommand, forKey: .sourceCommand)
    }

    package var scopeURL: URL {
        URL(fileURLWithPath: scopePath)
    }

    package var title: String {
        if let nativeCommand { return nativeCommand.command }
        if let sourceCommand, !SearchCommandExport.isWrappedExport(sourceCommand) { return sourceCommand }
        if let rules = ruleSet { return rules.title }
        if !query.isEmpty { return query }
        if refinements.name.isEmpty, let saved = refinements.savedFileQuery, !saved.text.isEmpty { return saved.text }
        return refinements.name.isEmpty ? mode.title : refinements.name
    }

    package var summary: String {
        let scopeName = scopeURL.lastPathComponent.isEmpty ? scopeURL.path : scopeURL.lastPathComponent
        if nativeCommand != nil { return "Command search in \(scopeName)" }
        return "\(mode.title) in \(scopeName)"
    }

    package func makeRequest(maxResults: Int = .max) -> SearchRequest {
        SearchRequest(state: self, maxResults: maxResults)
    }
}

package typealias SearchSnapshot = SearchState

package struct SearchHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    package let id: UUID
    package var snapshot: SearchSnapshot
    package var searchedAt: Date
    package var resultCount: Int
    package var engineName: String
    package var isPinned: Bool
    package var pinOrder: Int?

    package init(
        id: UUID,
        snapshot: SearchSnapshot,
        searchedAt: Date,
        resultCount: Int,
        engineName: String,
        isPinned: Bool,
        pinOrder: Int?
    ) {
        self.id = id
        self.snapshot = snapshot
        self.searchedAt = searchedAt
        self.resultCount = resultCount
        self.engineName = engineName
        self.isPinned = isPinned
        self.pinOrder = pinOrder
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case snapshot
        case searchedAt
        case resultCount
        case engineName
        case isPinned
        case pinOrder
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.snapshot = try container.decode(SearchSnapshot.self, forKey: .snapshot)
        self.searchedAt = try container.decode(Date.self, forKey: .searchedAt)
        self.resultCount = try container.decodeIfPresent(Int.self, forKey: .resultCount) ?? 0
        self.engineName = try container.decodeIfPresent(String.self, forKey: .engineName) ?? ""
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.pinOrder = try container.decodeIfPresent(Int.self, forKey: .pinOrder)
    }
}

package enum EmptySearchBehavior: String, Codable, CaseIterable, Sendable {
    case browse, search
    package var title: String { self == .browse ? "Browse this folder" : "Search subfolders" }
}

package struct PersistedLibrary: Codable, Sendable {
    // Earlier versions enabled conversion and expansion by default.
    // Migrate that history once; newly saved explicit choices remain intact.
    package var explicitConversionChoices = true
    package var selectedDrivePath: String?
    package var defaultSearchDirectoryPath: String?
    package var includeHidden: Bool
    package var showIcons: Bool
    package var managedIndexes: [ManagedIndex]
    package var history: [SearchHistoryEntry]
    package var preferredEditor: SourceEditor
    package var traversal: SearchTraversalOptions
    package var emptySearchBehavior: EmptySearchBehavior

    package init(
        selectedDrivePath: String? = nil,
        defaultSearchDirectoryPath: String? = nil,
        includeHidden: Bool = true,
        showIcons: Bool = true,
        managedIndexes: [ManagedIndex] = [],
        history: [SearchHistoryEntry] = [],
        preferredEditor: SourceEditor = .automatic,
        traversal: SearchTraversalOptions = .init(),
        emptySearchBehavior: EmptySearchBehavior = .browse
    ) {
        self.selectedDrivePath = selectedDrivePath
        self.defaultSearchDirectoryPath = defaultSearchDirectoryPath
        self.includeHidden = includeHidden
        self.showIcons = showIcons
        self.managedIndexes = managedIndexes
        self.history = history
        self.preferredEditor = preferredEditor
        self.traversal = traversal
        self.emptySearchBehavior = emptySearchBehavior
    }

    package enum CodingKeys: String, CodingKey {
        case explicitConversionChoices
        case selectedDrivePath
        case defaultSearchDirectoryPath
        case includeHidden
        case showIcons
        case managedIndexes
        case history
        case preferredEditor
        case traversal
        case emptySearchBehavior
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedDrivePath = try container.decodeIfPresent(String.self, forKey: .selectedDrivePath)
        self.defaultSearchDirectoryPath = try container.decodeIfPresent(String.self, forKey: .defaultSearchDirectoryPath)
        self.includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? true
        self.showIcons = try container.decodeIfPresent(Bool.self, forKey: .showIcons) ?? true
        self.managedIndexes = try container.decodeIfPresent([ManagedIndex].self, forKey: .managedIndexes) ?? []
        self.history = try container.decodeIfPresent([SearchHistoryEntry].self, forKey: .history) ?? []
        if try container.decodeIfPresent(Bool.self, forKey: .explicitConversionChoices) != true {
            for index in history.indices where history[index].snapshot.refinements.extraction != nil {
                history[index].snapshot.refinements.extraction = nil
                history[index].snapshot.sourceCommand = nil
            }
        }
        self.preferredEditor = try container.decodeIfPresent(SourceEditor.self, forKey: .preferredEditor) ?? .automatic
        self.traversal = try container.decodeIfPresent(SearchTraversalOptions.self, forKey: .traversal) ?? .init()
        self.emptySearchBehavior = try container.decodeIfPresent(EmptySearchBehavior.self, forKey: .emptySearchBehavior) ?? .browse
    }
}
