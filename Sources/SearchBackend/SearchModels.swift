import Foundation

package enum SearchMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case files
    case folders
    case everything
    case contents

    package var id: Self { self }

    package var title: String {
        switch self {
        case .files:
            "Files"
        case .folders:
            "Directories"
        case .everything:
            "Files & Directories"
        case .contents:
            "Contents"
        }
    }

    package var systemImage: String {
        switch self {
        case .files:
            "doc.text"
        case .folders:
            "folder"
        case .everything:
            "square.stack"
        case .contents:
            "text.magnifyingglass"
        }
    }
}

package enum SearchSyntax: String, CaseIterable, Identifiable, Codable, Sendable {
    case literal
    case regex
    case fuzzy

    package var id: Self { self }

    package var title: String {
        switch self {
        case .literal:
            "Literal"
        case .regex:
            "Regex"
        case .fuzzy:
            "Fuzzy"
        }
    }
}

package enum SortField: String, CaseIterable, Identifiable, Codable, Sendable {
    case match
    case name
    case path
    case modified
    case size

    package var id: Self { self }

    package var title: String {
        switch self {
        case .match:
            "Best Match"
        case .name:
            "Name"
        case .path:
            "Path"
        case .modified:
            ResultMetadataLabels.modified
        case .size:
            "Size"
        }
    }
}

package enum SortDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case ascending
    case descending

    package var id: Self { self }

    package var title: String {
        switch self {
        case .ascending:
            "Ascending"
        case .descending:
            "Descending"
        }
    }
}

package enum IndexedEntryFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case everything
    case files
    case folders

    package var id: Self { self }

    package var title: String {
        switch self {
        case .everything:
            "Everything"
        case .files:
            "Files"
        case .folders:
            "Directories"
        }
    }
}

package enum SearchResultKind: String, Codable, Sendable {
    case file
    case folder
    case contentMatch

    package var title: String {
        switch self {
        case .file:
            "File"
        case .folder:
            "Directory"
        case .contentMatch:
            "Match"
        }
    }
}

package struct SearchRequest: Sendable {
    package var state: SearchState
    package var maxResults: Int
    package var referenceDate: Date = .now
    package var collectStatistics = false
    package var buildContentIndex = false
    package var buildWordIndex = false
    package var excludesDerivedContent = false
    package var isDirectoryListing = false
    package var includeMetadata = false

    package var query: String { get { state.query } set { state.query = newValue } }
    package var mode: SearchMode { get { state.mode } set { state.mode = newValue } }
    package var scope: URL { get { state.scopeURL } set { state.scopePath = newValue.path } }
    package var useIndex: Bool { get { state.useIndex } set { state.useIndex = newValue } }
    package var includeHidden: Bool { get { state.includeHidden } set { state.includeHidden = newValue } }
    package var caseSensitive: Bool { get { state.caseSensitive } set { state.caseSensitive = newValue } }
    package var syntax: SearchSyntax { get { state.syntax } set { state.syntax = newValue } }
    package var exactNameMatch: Bool { get { state.exactNameMatch } set { state.exactNameMatch = newValue } }
    package var selectedDrivePath: String? { get { state.selectedDrivePath } set { state.selectedDrivePath = newValue } }
    package var indexedFilter: IndexedEntryFilter { get { state.indexedFilter } set { state.indexedFilter = newValue } }
    package var filters: SearchFilters { get { state.filters } set { state.filters = newValue } }
    package var traversal: SearchTraversalOptions { get { state.traversal } set { state.traversal = newValue } }
    package var refinements: SearchRefinements { get { state.refinements } set { state.refinements = newValue } }

    package init(state: SearchState, maxResults: Int = .max, referenceDate: Date = .now) {
        self.state = state; self.maxResults = maxResults; self.referenceDate = referenceDate
    }

    // Compatibility initializer for existing callers. All values immediately
    // enter the canonical root instead of creating another field store.
    package init(query: String, mode: SearchMode, scope: URL, useIndex: Bool = false,
         includeHidden: Bool, caseSensitive: Bool, syntax: SearchSyntax, exactNameMatch: Bool,
         maxResults: Int, selectedDrivePath: String? = nil, indexedFilter: IndexedEntryFilter = .everything,
         filters: SearchFilters = .init(), traversal: SearchTraversalOptions = .init(),
         refinements: SearchRefinements = .init(), referenceDate: Date = .now) {
        state = SearchState(query: query, mode: mode, scopePath: scope.path, useIndex: useIndex,
            includeHidden: includeHidden, caseSensitive: caseSensitive, syntax: syntax, exactNameMatch: exactNameMatch,
            selectedDrivePath: selectedDrivePath, indexedFilter: indexedFilter, filters: filters,
            traversal: traversal, refinements: refinements)
        self.maxResults = maxResults; self.referenceDate = referenceDate
    }
}

package struct SearchResult: Identifiable, Hashable, Codable, Sendable {
    package let id: UUID
    package let url: URL
    package let kind: SearchResultKind
    package let lineNumber: Int?
    package var extractedOrigin: ExtractedMatchOrigin? = nil
    package let snippet: String?
    package let snippetMatchRanges: [Range<Int>]
    package let displayNameOverride: String?
    package let directoryPathOverride: String?
    package let browseTargetURL: URL?
    package let isParentDirectoryEntry: Bool
    package let typeDescription: String?
    package let modifiedAt: Date?
    package let createdAt: Date?
    package let addedAt: Date?
    package let lastOpenedAt: Date?
    package let size: Int64?
    package var tags: [String]? = nil
    package let matchRank: Int
    package let sourceOrder: Int

    package init(
        id: UUID = UUID(),
        url: URL,
        kind: SearchResultKind,
        lineNumber: Int? = nil,
        extractedOrigin: ExtractedMatchOrigin? = nil,
        snippet: String? = nil,
        snippetMatchRanges: [Range<Int>] = [],
        displayNameOverride: String? = nil,
        directoryPathOverride: String? = nil,
        browseTargetURL: URL? = nil,
        isParentDirectoryEntry: Bool = false,
        typeDescription: String? = nil,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        addedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        size: Int64? = nil,
        tags: [String]? = nil,
        matchRank: Int,
        sourceOrder: Int
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.lineNumber = lineNumber
        self.extractedOrigin = extractedOrigin
        self.snippet = snippet
        self.snippetMatchRanges = snippetMatchRanges
        self.displayNameOverride = displayNameOverride
        self.directoryPathOverride = directoryPathOverride
        self.browseTargetURL = browseTargetURL
        self.isParentDirectoryEntry = isParentDirectoryEntry
        self.typeDescription = typeDescription
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.size = size
        self.tags = tags
        self.matchRank = matchRank
        self.sourceOrder = sourceOrder
    }

    package var name: String {
        url.lastPathComponent
    }

    package var displayName: String {
        displayNameOverride ?? extractedOrigin?.members?.last.map { URL(fileURLWithPath: $0.name).lastPathComponent } ?? name
    }

    package var path: String {
        url.path
    }

    package var directoryPath: String {
        directoryPathOverride ?? (extractedOrigin?.memberPath == nil ? url.deletingLastPathComponent().path : path)
    }

    package var documentIdentity: String {
        guard let origin = extractedOrigin else { return path }
        return path + "\0" + (origin.members ?? []).map { ($0.kind ?? "archive") + ":" + String($0.index) }.joined(separator: "/")
            + "\0" + (origin.recordKey ?? "")
    }

    package var sortableKind: String {
        typeDescription ?? kind.title
    }

    package var sortableModifiedAt: Date {
        modifiedAt ?? .distantPast
    }

    package var sortableCreatedAt: Date {
        createdAt ?? .distantPast
    }

    package var sortableAddedAt: Date {
        addedAt ?? .distantPast
    }

    package var sortableLastOpenedAt: Date {
        lastOpenedAt ?? .distantPast
    }

    package var sortableSize: Int64 {
        size ?? -1
    }

    package var lineLabel: String {
        if let extractedOrigin { return extractedOrigin.label }
        guard let lineNumber else {
            return kind.title
        }
        return "Line \(lineNumber)"
    }

    package var isBrowsableDirectoryEntry: Bool {
        browseTargetURL != nil
    }

    package static func bestMatchFirst(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.matchRank != rhs.matchRank { return lhs.matchRank < rhs.matchRank }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.lineNumber != rhs.lineNumber { return (lhs.lineNumber ?? 0) < (rhs.lineNumber ?? 0) }
        return lhs.sourceOrder < rhs.sourceOrder
    }
}

package struct SearchResponse: Sendable {
    package let results: [SearchResult]
    package let commandPreview: String
    package let engineName: String
    package var isTruncated = false
    package var warning: String? = nil
    package var commandOutput: CommandTextOutput? = nil
    package init(results: [SearchResult], commandPreview: String, engineName: String, isTruncated: Bool = false, warning: String? = nil, commandOutput: CommandTextOutput? = nil) {
        self.results = results
        self.commandPreview = commandPreview
        self.engineName = engineName
        self.isTruncated = isTruncated
        self.warning = warning
        self.commandOutput = commandOutput
    }

}

package struct SearchExecutionSummary: Sendable {
    package let commandPreview: String
    package let engineName: String
    package var isTruncated = false
    package var warning: String? = nil
    package var wordStatus: WordIndexStatus? = nil
    package var commandOutput: CommandTextOutput? = nil

    package func statusMessage(resultCount: Int) -> String {
        if let commandOutput {
            let message = commandOutput.isTruncated ? "Command finished. Showing the first 1 MiB of output."
                : commandOutput.text.isEmpty ? "Command finished without output." : "Command finished."
            return warning.map { "\(message) Note: \($0)" } ?? message
        }
        let count = isTruncated
            ? "Showing \(resultCount) matches (result limit reached). Refine your search for more."
            : resultCount == 1 ? "1 match." : "\(resultCount) matches."
        return warning.map { "\(count) Note: \($0)" } ?? count
    }
    package init(commandPreview: String, engineName: String, isTruncated: Bool = false, warning: String? = nil, wordStatus: WordIndexStatus? = nil, commandOutput: CommandTextOutput? = nil) {
        self.commandPreview = commandPreview
        self.engineName = engineName
        self.isTruncated = isTruncated
        self.warning = warning
        self.wordStatus = wordStatus
        self.commandOutput = commandOutput
    }

}

package struct ToolLocationInfo: Identifiable, Sendable {
    package let name: String
    package let path: String

    package var id: String { name }
    package init(name: String, path: String) {
        self.name = name
        self.path = path
    }

}

package enum SearchServiceError: LocalizedError {
    case missingTool(String)
    case invalidQuery
    case missingIndex
    case commandFailed(String)
    case launchFailed(String)

    package var errorDescription: String? {
        switch self {
        case let .missingTool(tool):
            return "\(tool) was not found. Install it or pick a different search mode."
        case .invalidQuery:
            return "Enter a query before searching."
        case .missingIndex:
            return "Choose or build a drive index in Settings before using indexed search."
        case let .commandFailed(message):
            return message
        case let .launchFailed(message):
            return message
        }
    }
}
