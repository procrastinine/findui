import SearchBackend
#if canImport(FindUI)
@testable import FindUI
#endif
import Foundation

/// Model output is data. Only the existing command builder can produce commands.
struct NaturalSearchPlan: Sendable {
    var mode: SearchMode = .files
    var syntax: SearchSyntax = .literal
    var query = ""
    var scopePath = "."
    var caseSensitive = false
    var exactNameMatch = false
    var includeHidden: Bool?
    var includeIgnored: Bool?
    var excludedFolders: [String] = []
    var minimumSize = ""
    var maximumSize = ""
    var dateField: SearchDateField = .modified
    var datePeriod: SearchDatePeriod = .any
    var relativeDays: Int?
    var calendarAge: String?
    var minimumDepth = 1
    var maximumDepth: Int?
    var followSymlinks = false
    var dateFrom: String?
    var dateThrough: String?
    var unsupportedReason: String?
    var sourceCommand: String?
    var refinements = SearchRefinements()

    func validated(context: SearchSnapshot, tools: Toolchain) throws -> NaturalSearchProposal {
        let (snapshot, corrections) = try resolvedState(context: context)
        let command = try SearchCommandBuilder(tools: tools).preparedCommand(for: snapshot.makeRequest())
        var proposal = NaturalSearchProposal(snapshot: snapshot, command: command.spec.shellString, sourceCommand: sourceCommand)
        if !corrections.isEmpty { proposal.executionNote += " Folder spelling corrected: " + corrections.joined(separator: "; ") + "." }
        return proposal
    }

    /// Resolve one root state without compiling an intermediate search. Grouped
    /// inputs use this before attaching their validated trees, so no temporary
    /// file enumeration is required for an rg-only content expression.
    func resolvedState(context: SearchSnapshot, groupedContents: Bool = false) throws -> (SearchState, [String]) {
        func invalid(_ message: String) -> SearchServiceError { .commandFailed(message) }
        if let reason = unsupportedReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw invalid(reason)
        }
        let query = syntax == .regex ? query : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count <= 4096, !query.contains("\0"), !scopePath.contains("\0") else {
            throw invalid("The generated search contains invalid or excessively long text. Try a shorter description.")
        }
        if mode == .contents && syntax == .fuzzy {
            throw invalid("Fuzzy matching is only available for file and directory names.")
        }
        if syntax != .regex {
            var quote: Character?
            var escaped = false
            for character in query {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if let active = quote {
                    if character == active { quote = nil }
                } else if character == "\"" || character == "'" { quote = character }
            }
            guard quote == nil, !escaped else { throw invalid("The generated query has an unfinished quote or escape.") }
            if !query.isEmpty, ParsedSearchQuery.parseLiteral(query).tokens.isEmpty {
                throw invalid("The generated query has no search terms.")
            }
        }
        if exactNameMatch && (mode == .contents || syntax != .literal || !ParsedSearchQuery.parseLiteral(query).canUseExactNameMatch) {
            throw invalid("Exact Name requires one literal filename and no additional query terms.")
        }

        let resolution = try SearchPath.resolveFolder(scopePath, relativeTo: context.scopeURL)
        let scope = resolution.url
        var resolvedRefinements = refinements
        var corrections = resolution.corrected ? ["\(scopePath) → \(scope.path)"] : []
        resolvedRefinements.additionalScopes = try refinements.additionalScopes.map { path in
            let result = try SearchPath.resolveFolder(path, relativeTo: context.scopeURL)
            if result.corrected { corrections.append("\(path) → \(result.url.path)") }
            return result.url.path
        }
        var filters = SearchFilters(minimumSize: minimumSize, maximumSize: maximumSize,
                                    dateField: dateField, datePeriod: datePeriod, relativeDays: relativeDays, calendarAge: calendarAge)
        if [.custom, .before, .after].contains(datePeriod) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let dateFrom, let from = formatter.date(from: dateFrom), formatter.string(from: from) == dateFrom else {
                throw invalid("The generated date range must contain valid dates in YYYY-MM-DD format.")
            }
            filters.dateFrom = from
            if datePeriod == .custom {
                guard let dateThrough, let through = formatter.date(from: dateThrough), formatter.string(from: through) == dateThrough else {
                    throw invalid("The generated date range must contain valid dates in YYYY-MM-DD format.")
                }
                filters.dateThrough = through
            } else if dateThrough != nil { throw invalid("Before and After filters need only one date.") }
        } else if dateFrom != nil || dateThrough != nil {
            throw invalid("The generated dates do not match the selected date filter.")
        }
        _ = try filters.validated()
        guard groupedContents || mode != .contents || !query.isEmpty || filters.isActive || refinements.hasFileConditions else {
            throw invalid("Describe a filename, file type, text to find, or size/date filter.")
        }
        let traversal = SearchTraversalOptions(includeIgnored: includeIgnored ?? context.traversal.includeIgnored,
            excludedFolders: context.traversal.excludedFolders + excludedFolders,
            minimumDepth: minimumDepth, maximumDepth: maximumDepth, followSymlinks: followSymlinks).normalized
        try traversal.validate()
        let snapshot = SearchSnapshot(query: query, mode: mode, scopePath: scope.standardizedFileURL.path,
            useIndex: false, includeHidden: includeHidden ?? context.includeHidden, caseSensitive: caseSensitive,
            syntax: syntax, exactNameMatch: exactNameMatch, selectedDrivePath: nil,
            indexedFilter: mode == .folders ? .folders : .files, filters: filters, traversal: traversal, refinements: resolvedRefinements)
        return (snapshot, corrections)
    }
}

struct NaturalSearchProposal: Sendable {
    let snapshot: SearchSnapshot
    let command: String
    var sourceCommand: String? = nil
    var executionNote = "The command includes every search filter. Review the options before applying."

    func preservingIndexPreference(_ enabled: Bool, index: ManagedIndex?, service: IndexService) -> Self {
        guard enabled, snapshot.mode != .contents else { return self }
        guard let index, SearchPath.contains(snapshot.scopeURL, in: index.scopeURL),
              service.coverageMatches(request: snapshot.makeRequest(), index: index) else {
            var proposal = self
            proposal.executionNote = "Live search: the saved index does not cover this folder or these scan options."
            return proposal
        }
        var indexed = snapshot
        indexed.useIndex = true
        return Self(snapshot: indexed,
            command: "\(service.commandPreview(for: index)) · scoped to \(snapshot.scopePath)",
            sourceCommand: sourceCommand,
            executionNote: "Uses paths and metadata from the snapshot updated \(index.updatedAt.formatted(date: .abbreviated, time: .shortened)). Copying provides snapshot details, not a live filesystem command.")
    }

    var optionSummary: String {
        var parts = [snapshot.useIndex ? "Saved index" : "Live search", snapshot.mode.title, snapshot.syntax.title,
                     snapshot.caseSensitive ? "Case sensitive" : "Ignore case",
                     snapshot.includeHidden ? "Include hidden files" : "Hide hidden files",
                     snapshot.traversal.includeIgnored ? "Include ignored files" : "Respect ignore files"]
        if snapshot.exactNameMatch { parts.append("Exact name") }
        if !snapshot.refinements.extensions.isEmpty { parts.append("Extensions: \(snapshot.refinements.extensions)") }
        if !snapshot.filters.minimumSize.isEmpty { parts.append("At least \(snapshot.filters.minimumSize)") }
        if !snapshot.filters.maximumSize.isEmpty { parts.append("At most \(snapshot.filters.maximumSize)") }
        if snapshot.filters.datePeriod != .any {
            let period = snapshot.filters.datePeriod == .custom
                ? "\(snapshot.filters.dateFrom.formatted(date: .abbreviated, time: .omitted)) – \(snapshot.filters.dateThrough.formatted(date: .abbreviated, time: .omitted))"
                : snapshot.filters.datePeriodDescription
            parts.append("\(snapshot.filters.dateField.title): \(period)")
        }
        if !snapshot.traversal.excludedFolders.isEmpty {
            parts.append("Exclude folders: \(snapshot.traversal.excludedFolders.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}
