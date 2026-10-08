import SearchBackend
#if canImport(FindUI)
@testable import FindUI
#endif
import Foundation

extension SearchState {
    /// Exact projection into the legacy fixture format. Wider GUI searches
    /// fail explicitly rather than losing conditions in a compatibility test.
    func modelIntent() throws -> SearchIntent {
        if let rules = ruleSet {
            var shared = self
            shared.clearCriteriaKeepingOptions()
            let root = try shared.modelIntent()
            var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(root)) as! [String: Any]
            for key in SearchIntentTree.fileFields.union(SearchIntentTree.contentFields) { raw.removeValue(forKey: key) }
            if !rules.files.leaves.isEmpty { raw["files"] = try rules.files.modelFields() }
            if let contents = rules.contents {
                raw["contents"] = try contents.modelFields()
                raw["contentUnit"] = rules.contentUnit.rawValue
            }
            return try JSONDecoder().decode(SearchIntent.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        var state = self
        state.preserveLegacyFileQuery()
        let r = state.refinements
        guard !state.useIndex, state.query.isEmpty || state.mode == .contents,
              r.fileQuery.isEmpty, r.savedFileQuery == nil,
              r.absolutePathMatching != true else {
            throw SearchServiceError.commandFailed("This search uses controls outside the learned search contract.")
        }
        var content = ""
        if state.mode == .contents {
            guard state.syntax != .fuzzy else { throw SearchServiceError.commandFailed("Contents cannot use fuzzy matching.") }
            if state.syntax == .regex { content = state.query }
            else if let literal = state.singleContentLiteral { content = literal }
            else { throw SearchServiceError.commandFailed("Multiple content conditions are outside the learned search contract.") }
        }
        let bounds = try state.filters.validated()
        var raw: [String: Any] = [
            "mode": state.mode.rawValue, "name": r.name, "nameMatching": r.nameMatching.rawValue,
            "path": r.path, "pathMatching": r.pathMatching.rawValue,
            "content": content, "contentMatching": state.mode == .contents ? state.syntax.rawValue : "literal",
            "contentSource": state.mode == .contents ? (r.contentSource ?? .fileText).rawValue : "fileText",
            "roots": [state.scopePath] + r.additionalScopes,
            "extensions": r.extensions.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init),
            "excludedFolders": state.traversal.normalized.excludedFolders,
            "excludedFiles": r.excludedFiles.split(separator: "\n").map(String.init),
            "source": r.source.rawValue,
            "fileCase": r.fileCaseSensitive.map { $0 ? "sensitive" : "insensitive" } ?? "inherit",
            "caseSensitive": state.caseSensitive, "hidden": state.includeHidden,
            "ignored": state.traversal.includeIgnored, "followSymlinks": state.traversal.followSymlinks,
            "wholeWords": state.mode == .contents && r.wholeWords,
            "filesOnly": state.mode == .contents && r.matchingFilesOnly,
            "contextLines": r.contextLines, "minDepth": state.traversal.minimumDepth,
            "date": state.filters.datePeriod.rawValue, "dateField": state.filters.dateField.rawValue
        ]
        raw["minimum"] = bounds.minimumSize; raw["maximum"] = bounds.maximumSize
        raw["maxDepth"] = state.traversal.maximumDepth
        if state.filters.datePeriod == .recentDays { raw["relativeDays"] = state.filters.relativeDays }
        if state.filters.datePeriod == .recentCalendar {
            raw["calendarAge"] = try SearchValueUnits.calendarAge(state.filters.calendarAge ?? "1 month").text
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        if [.before, .after, .custom].contains(state.filters.datePeriod) {
            raw["dateFrom"] = formatter.string(from: state.filters.dateFrom)
            if state.filters.datePeriod == .custom { raw["dateThrough"] = formatter.string(from: state.filters.dateThrough) }
        }
        return try JSONDecoder().decode(SearchIntent.self, from: JSONSerialization.data(withJSONObject: raw))
    }
}

private extension SearchRuleTree where Rule == SearchFileRule {
    func modelFields() throws -> [String: Any] {
        switch self {
        case .all(let nodes): return ["all": try nodes.map { try $0.modelFields() }]
        case .any(let nodes): return ["any": try nodes.map { try $0.modelFields() }]
        case .none(let nodes): return ["none": try nodes.map { try $0.modelFields() }]
        case .rule(let rule):
            switch rule {
            case .name(let value, let matching): return ["name": value, "nameMatching": matching.rawValue]
            case .path(let value, let matching, let absolute):
                guard !absolute else { throw SearchServiceError.commandFailed("This path condition uses a flag outside the learned contract.") }
                return ["path": value, "pathMatching": matching.rawValue]
            case .extensions(let values): return ["extensions": values]
            case .tags: throw SearchServiceError.commandFailed("Finder tags are outside the legacy learned contract.")
            case .size(let minimum, let maximum):
                var fields: [String: Any] = [:]
                fields["minimum"] = try SearchFilters.sizeBound(minimum, side: .minimum)
                fields["maximum"] = try SearchFilters.sizeBound(maximum, side: .maximum)
                return fields
            case .date(let value):
                var fields: [String: Any] = ["date": value.period.rawValue, "dateField": value.field.rawValue]
                if value.period == .recentDays { fields["relativeDays"] = value.days }
                if value.period == .recentCalendar {
                    fields["calendarAge"] = try SearchValueUnits.calendarAge(value.calendarAge ?? "1 month").text
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
                if [.before, .after, .custom].contains(value.period) { fields["dateFrom"] = formatter.string(from: value.from) }
                if value.period == .custom { fields["dateThrough"] = formatter.string(from: value.through) }
                return fields
            case .expression:
                throw SearchServiceError.commandFailed("Legacy file expressions must be expanded into individual conditions before using the learned contract.")
            }
        }
    }
}

private extension SearchRuleTree where Rule == SearchContentRule {
    func modelFields() throws -> [String: Any] {
        switch self {
        case .all(let nodes): return ["all": try nodes.map { try $0.modelFields() }]
        case .any(let nodes): return ["any": try nodes.map { try $0.modelFields() }]
        case .none(let nodes): return ["none": try nodes.map { try $0.modelFields() }]
        case .rule(let rule):
            switch rule {
            case .literal(let text): return ["content": text]
            case .regex(let text): return ["content": text, "contentMatching": "regex"]
            case .documentText(let text): return ["content": text, "contentSource": "indexedDocumentText"]
            case .proximity, .metadata: throw SearchServiceError.commandFailed("This condition is outside the legacy learned contract.")
            case .allLines: throw SearchServiceError.commandFailed("An explicit any-line condition is outside the learned contract.")
            }
        }
    }
}
