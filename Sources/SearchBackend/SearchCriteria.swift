import SearchCore
import Foundation

package struct CompactSearchCriteria: Codable, Hashable, Sendable {
    package var query = ""
    package var syntax: SearchSyntax = .literal
    package var exactNameMatch = false
    package var filters = SearchFilters()
    package var refinements = SearchRefinements()
    package var contentQueryStyle: ContentQueryStyle? = nil
    package init(query: String = "", syntax: SearchSyntax = .literal, exactNameMatch: Bool = false, filters: SearchFilters = SearchFilters(), refinements: SearchRefinements = SearchRefinements(), contentQueryStyle: ContentQueryStyle? = nil) {
        self.query = query
        self.syntax = syntax
        self.exactNameMatch = exactNameMatch
        self.filters = filters
        self.refinements = refinements
        self.contentQueryStyle = contentQueryStyle
    }

}

/// Mutually exclusive representations, never a group layered on hidden compact
/// filters. Compact controls remain a lossless subset and old history migrates
/// into that case. Promoting moves every active predicate into the rule trees.
package enum SearchCriteria: Codable, Hashable, Sendable {
    case compact(CompactSearchCriteria)
    case grouped(SearchRuleSet, options: SearchSharedOptions)
}

/// Grouped options cannot contain name, path, type, size or date predicates.
/// Those fields have exactly one home: the file tree.
package struct SearchSharedOptions: Codable, Hashable, Sendable {
    package var additionalScopes: [String]
    package var source: LiveSearchSource
    package var fileCaseSensitive: Bool?
    package var wholeWords: Bool
    package var matchingFilesOnly: Bool
    package var contextLines: Int
    package var fuzzyFullPath: Bool
    package var fuzzyNormalize: Bool? = nil
    package var workers: Int? = nil
    package var extraction: SearchExtractionOptions? = nil
    package var useContentIndex: Bool? = nil
    package var textEncoding: String? = nil
    package var typoTolerance: Int? = nil
    package var wordSearch: Bool? = nil
    package var stemWords: Bool? = nil
    package var multiline: Bool? = nil
    package var wordLanguage: WordLanguage? = nil

    package init(_ value: SearchRefinements) {
        additionalScopes = value.additionalScopes; source = value.source
        fileCaseSensitive = value.fileCaseSensitive; wholeWords = value.wholeWords
        matchingFilesOnly = value.matchingFilesOnly; contextLines = value.contextLines
        fuzzyFullPath = value.fuzzyFullPath
        fuzzyNormalize = value.fuzzyNormalize
        workers = value.workers
        extraction = value.extraction
        useContentIndex = value.useContentIndex
        textEncoding = value.textEncoding; typoTolerance = value.typoTolerance
        wordSearch = value.wordSearch; stemWords = value.stemWords
        multiline = value.multiline; wordLanguage = value.wordLanguage
    }
    package var refinements: SearchRefinements {
        var value = SearchRefinements()
        value.additionalScopes = additionalScopes; value.source = source
        value.fileCaseSensitive = fileCaseSensitive; value.wholeWords = wholeWords
        value.matchingFilesOnly = matchingFilesOnly; value.contextLines = contextLines
        value.fuzzyFullPath = fuzzyFullPath
        value.fuzzyNormalize = fuzzyNormalize
        value.workers = workers
        value.extraction = extraction
        value.useContentIndex = useContentIndex
        value.textEncoding = textEncoding; value.typoTolerance = typoTolerance
        value.wordSearch = wordSearch; value.stemWords = stemWords
        value.multiline = multiline; value.wordLanguage = wordLanguage
        return value
    }
}

extension SearchRefinements {
    package var withoutFileConditions: Self {
        var value = self
        value.name = ""; value.path = ""; value.extensions = ""; value.excludedFiles = ""
        value.finderTags = nil; value.tagMatch = nil
        value.fileQuery = ""; value.savedFileQuery = nil
        value.nameMatching = .contains; value.pathMatching = .contains; value.absolutePathMatching = nil
        return value
    }
}

extension SearchState {
    package func validateExpressions() throws {
        if let rules = ruleSet {
            for rule in rules.fileLeaves {
                if case .expression(let value) = rule, value.syntax != .regex {
                    try ParsedSearchQuery.parseLiteral(value.text).validate()
                }
            }
        } else {
            if syntax != .regex { try ParsedSearchQuery.parseLiteral(query).validate() }
            try ParsedSearchQuery.parseLiteral(refinements.fileQuery).validate()
            if let saved = refinements.savedFileQuery, saved.syntax != .regex {
                try ParsedSearchQuery.parseLiteral(saved.text).validate()
            }
        }
    }

    package var ruleSet: SearchRuleSet? {
        if case .grouped(let rules, _) = criteria { return rules }
        return nil
    }

    package var query: String {
        get { if case .compact(let value) = criteria { value.query } else { "" } }
        set { if newValue != query { updateCompact { $0.query = newValue } } }
    }
    package var syntax: SearchSyntax {
        get { if case .compact(let value) = criteria { value.syntax } else { .literal } }
        set { if newValue != syntax { updateCompact { $0.syntax = newValue } } }
    }
    package var exactNameMatch: Bool {
        get { if case .compact(let value) = criteria { value.exactNameMatch } else { false } }
        set { if newValue != exactNameMatch { updateCompact { $0.exactNameMatch = newValue } } }
    }
    package var filters: SearchFilters {
        get { if case .compact(let value) = criteria { value.filters } else { .init() } }
        set { if newValue != filters { updateCompact { $0.filters = newValue } } }
    }
    package var contentQueryStyle: ContentQueryStyle? {
        get { if case .compact(let value) = criteria { value.contentQueryStyle } else { nil } }
        set { if newValue != contentQueryStyle { updateCompact { $0.contentQueryStyle = newValue } } }
    }
    package var refinements: SearchRefinements {
        get {
            switch criteria {
            case .compact(let value): return value.refinements
            case .grouped(let rules, let options):
                var value = options.refinements
                value.contentSource = rules.contentLeaves.contains(where: \.isDocumentText) == true ? .indexedDocumentText : .fileText
                return value
            }
        }
        set {
            switch criteria {
            case .compact(var value): value.refinements = newValue; criteria = .compact(value)
            case .grouped(let rules, _):
                precondition(!newValue.hasFileConditions, "Edit the file tree instead of adding hidden compact filters.")
                criteria = .grouped(rules, options: .init(newValue))
            }
        }
    }

    private mutating func updateCompact(_ change: (inout CompactSearchCriteria) -> Void) {
        guard case .compact(var value) = criteria else {
            preconditionFailure("Edit grouped criteria through their rule trees.")
        }
        change(&value); criteria = .compact(value)
    }

    /// Shared options are retained, but every predicate belongs to the supplied
    /// trees. Used both for promotion and edits; history stores this same value.
    package mutating func replaceRules(_ rules: SearchRuleSet) {
        var options = refinements.withoutFileConditions
        if !rules.hasContents { options.wordSearch = nil; options.multiline = nil }
        options.contentSource = rules.contentLeaves.contains(where: \.isDocumentText) == true ? .indexedDocumentText : .fileText
        if options.contentSource == .indexedDocumentText { options.wholeWords = false }
        criteria = .grouped(rules, options: .init(options))
        if rules.hasContents { mode = .contents; useIndex = false }
        else if mode == .contents { mode = .files }
        sourceCommand = nil
        selectRequiredSource()
    }

    /// Compiler adapters explicitly create an empty compact candidate request;
    /// they cannot accidentally run compact fields alongside a grouped query.
    package mutating func clearCriteriaKeepingOptions() {
        criteria = .compact(.init(refinements: refinements.withoutFileConditions))
    }

    package mutating func promoteToRules(now: Date = .now) throws {
        try validateExpressions()
        guard ruleSet == nil else { return }
        var state = self
        state.preserveLegacyFileQuery()
        let r = state.refinements
        var files: [SearchRuleTree<SearchFileRule>] = []
        if !r.name.isEmpty { files.append(.rule(.name(r.name, r.nameMatching))) }
        if let tags = r.finderTags, !tags.isEmpty { files.append(.rule(.tags(tags, r.tagMatch ?? .all))) }
        if !r.path.isEmpty { files.append(.rule(.path(r.path, r.pathMatching, absolute: r.absolutePathMatching == true))) }
        let extensions = r.extensions.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
        if !extensions.isEmpty { files.append(.rule(.extensions(extensions))) }
        if !r.fileQuery.isEmpty { files.append(.rule(.expression(.init(text: r.fileQuery, syntax: .literal, exactName: false)))) }
        if let value = r.savedFileQuery { files.append(.rule(.expression(value))) }
        for excluded in r.excludedFiles.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let rule: SearchFileRule = excluded.contains("/") ? .path(excluded, .glob, absolute: false) : .name(excluded, .glob)
            files.append(.none([.rule(rule)]))
        }
        if !filters.minimumSize.isEmpty || !filters.maximumSize.isEmpty {
            files.append(.rule(.size(minimum: filters.minimumSize, maximum: filters.maximumSize)))
        }
        if filters.datePeriod != .any { files.append(.rule(.date(.init(filters)))) }
        var content: SearchRuleTree<SearchContentRule>?
        if mode == .contents {
            if syntax == .regex { content = query.isEmpty ? .rule(.allLines) : .rule(.regex(query)) }
            else {
                var terms: [SearchRuleTree<SearchContentRule>] = []
                for token in ParsedSearchQuery.parseLiteral(query).tokens {
                    if token.field == .any {
                        let term: SearchRuleTree<SearchContentRule> = .rule(r.contentSource == .indexedDocumentText
                            ? .documentText(token.value) : .literal(token.value))
                        terms.append(token.isExcluded ? .none([term]) : term)
                    } else {
                        let rule: SearchFileRule
                        switch token.field {
                        case .name: rule = .name(token.globPattern ?? token.value, token.globPattern == nil ? .contains : .regex)
                        case .path: rule = .path(token.globPattern ?? token.value, token.globPattern == nil ? .contains : .regex, absolute: false)
                        case .ext: rule = .extensions(token.extensions)
                        case .any: preconditionFailure("Unfielded term handled above")
                        }
                        files.append(token.isExcluded ? .none([.rule(rule)]) : .rule(rule))
                    }
                }
                if !terms.isEmpty { content = terms.count == 1 ? terms[0] : .all(terms) }
                else if r.contentSource != .indexedDocumentText { content = .rule(.allLines) }
            }
        }
        let rules = SearchRuleSet(files: .all(files), contents: content,
            contentUnit: r.contentSource == .indexedDocumentText ? .file : r.wordSearch == true ? .document : .line)
        try rules.validate(now: now)
        replaceRules(rules)
    }

    /// Return a compact projection only when every condition has a place in the
    /// original controls. Mixed OR and same-file multi-term searches stay expanded.
    package var compactProjection: Self? {
        guard let rules = ruleSet else { return self }; guard let separate = rules.separated else { return nil }
        if rules.hasContents && rules.contentUnit == .document && refinements.wordSearch != true { return nil }
        var compact = CompactSearchCriteria(refinements: refinements.withoutFileConditions)
        var used = Set<String>()
        func reserve(_ key: String) -> Bool { used.insert(key).inserted }
        func file(_ node: SearchRuleTree<SearchFileRule>) -> Bool {
            switch node {
            case .all(let children): return children.allSatisfy(file)
            case .none(let children):
                for child in children {
                    let text: String
                    switch child {
                    case .rule(.name(let value, .glob)) where !value.contains("/"): text = value
                    case .rule(.path(let value, .glob, false)) where value.contains("/"): text = value
                    default: return false
                    }
                    guard !text.contains(where: \.isNewline) else { return false }
                    compact.refinements.excludedFiles = [compact.refinements.excludedFiles, text].filter { !$0.isEmpty }.joined(separator: "\n")
                }
                return !children.isEmpty
            case .any(let children):
                // A list of types already means OR in the compact controls.
                var extensions: [String] = []
                for child in children {
                    guard case .rule(.extensions(let values)) = child else { return false }
                    for value in values where !extensions.contains(value) { extensions.append(value) }
                }
                guard !extensions.isEmpty else { return false }
                return file(.rule(.extensions(extensions)))
            case .rule(let rule):
                switch rule {
                case .tags(let values, let matching):
                    guard reserve("tags") else { return false }
                    compact.refinements.finderTags = values; compact.refinements.tagMatch = matching
                case .name(let text, let matching):
                    guard reserve("name") else { return false }
                    compact.refinements.name = text; compact.refinements.nameMatching = matching
                case .path(let text, let matching, let absolute):
                    guard reserve("path") else { return false }
                    compact.refinements.path = text; compact.refinements.pathMatching = matching
                    compact.refinements.absolutePathMatching = absolute
                case .extensions(let values):
                    guard reserve("extensions") else { return false }
                    compact.refinements.extensions = values.joined(separator: ",")
                case .size(let minimum, let maximum):
                    guard reserve("size") else { return false }
                    compact.filters.minimumSize = minimum; compact.filters.maximumSize = maximum
                case .date(let value):
                    guard reserve("date") else { return false }
                    let minimum = compact.filters.minimumSize, maximum = compact.filters.maximumSize
                    compact.filters = value.filters
                    compact.filters.minimumSize = minimum; compact.filters.maximumSize = maximum
                case .expression(let value):
                    if compact.refinements.savedFileQuery == nil { compact.refinements.savedFileQuery = value }
                    else if value.syntax == .literal && !value.exactName && compact.refinements.fileQuery.isEmpty {
                        compact.refinements.fileQuery = value.text
                    } else { return false }
                }
                return true
            }
        }
        guard file(separate.files) else { return nil }
        if let contents = separate.contents {
            let documents = contents.leaves.allSatisfy(\.isDocumentText)
            if rules.contentUnit == .file && !documents {
                // Same-file AND is not the old same-line AND with file output.
                // Ranked word results also distinguish document/file units.
                guard case .rule = contents, refinements.wordSearch != true else { return nil }
                compact.refinements.matchingFilesOnly = true
            }
            if case .rule(.regex(let text)) = contents {
                compact.query = text; compact.syntax = .regex
            } else if case .rule(.allLines) = contents {
                compact.query = ""
            } else {
                var terms: [String] = []
                func content(_ node: SearchRuleTree<SearchContentRule>, negative: Bool = false) -> Bool {
                    switch node {
                    case .rule(.literal(let value)), .rule(.documentText(let value)):
                        terms.append((negative ? "-" : "") + Self.literalQuery(value)); return true
                    case .all(let children) where !negative: return children.allSatisfy { content($0) }
                    case .none(let children) where !negative: return children.allSatisfy { content($0, negative: true) }
                    default: return false
                    }
                }
                guard content(contents) else { return nil }
                compact.query = terms.joined(separator: " ")
                compact.contentQueryStyle = terms.count == 1 && !terms[0].hasPrefix("-") ? .literal : .expression
            }
        }
        var result = self
        result.criteria = .compact(compact)
        return result
    }
}
