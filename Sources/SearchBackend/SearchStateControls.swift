import Foundation

/// UI projections and atomic transitions of the persisted root. There is no
/// second draft of these fields in a view, interpreter or execution request.
extension SearchState {
    package var hasFuzzyConditions: Bool {
        if let rules = ruleSet {
            return rules.fileLeaves.contains { rule in
                switch rule {
                case .name(_, let matching), .path(_, let matching, _): matching == .fuzzy
                case .expression(let saved): saved.syntax == .fuzzy
                default: false
                }
            }
        }
        return syntax == .fuzzy || refinements.nameMatching == .fuzzy || refinements.pathMatching == .fuzzy
            || refinements.savedFileQuery?.syntax == .fuzzy
    }
    package var singleContentLiteral: String? {
        if query.isEmpty { return "" }
        let tokens = ParsedSearchQuery.parseLiteral(query).tokens
        guard tokens.count == 1, let token = tokens.first, token.field == .any,
              !token.isExcluded else { return nil }
        // Unfielded contents are literal even when they contain * or ?.
        return token.value
    }

    package static func literalQuery(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let tokens = ParsedSearchQuery.parseLiteral(value).tokens
        if tokens.count == 1, let token = tokens.first, token.field == .any,
           !token.isExcluded, token.value == value { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    package var contentMatchingChoice: ContentMatchingChoice {
        get {
            if refinements.wordSearch == true { return .indexedWords }
            if refinements.contentSource == .indexedDocumentText { return .documentText }
            if syntax == .regex { return .regex }
            return contentQueryStyle == .expression || (contentQueryStyle == nil && singleContentLiteral == nil)
                ? .expression : .literal
        }
        set {
            guard contentMatchingChoices.contains(newValue) else { return }
            let value = contentsInput
            refinements.wordSearch = newValue == .indexedWords ? true : nil
            if newValue == .indexedWords {
                refinements.fileCaseSensitive = refinements.fileCaseSensitive ?? caseSensitive
                caseSensitive = false; refinements.typoTolerance = nil; refinements.multiline = nil; refinements.source = .filesystem
            }
            syntax = newValue == .regex ? .regex : .literal
            contentQueryStyle = newValue == .expression ? .expression : .literal
            refinements.contentSource = newValue == .documentText ? .indexedDocumentText : .fileText
            if mode == .contents { query = [.literal, .documentText, .indexedWords].contains(newValue) ? Self.literalQuery(value) : value }
            if newValue == .documentText { refinements.wholeWords = false; refinements.multiline = nil }
            selectRequiredSource()
        }
    }

    package var contentMatchingChoices: [ContentMatchingChoice] {
        ContentMatchingChoice.allCases.filter {
            $0 == contentMatchingChoice || (($0 != .indexedWords || !fileConditionsRequireSpotlight)
                && ($0 != .documentText || (resultScope == nil && traversal.pathRules?.isEmpty != false))
            )
        }
    }

    package var contentTextEngineChoices: [ContentTextEngine] {
        let supported = !fileConditionsRequireSpotlight && (ruleSet?.contentLeaves.allSatisfy {
            switch $0 { case .literal, .metadata, .allLines: true; default: false }
        } ?? true)
        return supported || refinements.wordSearch == true ? ContentTextEngine.allCases : [.live]
    }

    package var contentTextEngine: ContentTextEngine {
        get { refinements.wordSearch == true ? .indexedWords : .live }
        set {
            guard newValue != contentTextEngine, contentTextEngineChoices.contains(newValue) else { return }
            guard var rules = ruleSet else {
                contentMatchingChoice = newValue == .indexedWords ? .indexedWords : .literal
                return
            }
            var options = refinements
            options.wordSearch = newValue == .indexedWords ? true : nil
            if newValue == .indexedWords {
                options.fileCaseSensitive = options.fileCaseSensitive ?? caseSensitive
                caseSensitive = false; options.typoTolerance = nil; options.multiline = nil
                options.source = .filesystem
                if rules.contentUnit == .line { rules.contentUnit = .document }
            }
            criteria = .grouped(rules, options: .init(options))
            sourceCommand = nil
            selectRequiredSource()
        }
    }

    package var contentsInput: String {
        get {
            guard mode == .contents else { return "" }
            return [.literal, .documentText, .indexedWords].contains(contentMatchingChoice) ? singleContentLiteral ?? query : query
        }
        set {
            guard mode == .contents || !newValue.isEmpty else { return }
            if mode != .contents {
                preserveLegacyFileQuery()
                refinements.fileCaseSensitive = refinements.fileCaseSensitive ?? caseSensitive
                mode = .contents; useIndex = false
                if syntax == .fuzzy { syntax = .literal }
            }
            let choice = contentMatchingChoice
            if contentQueryStyle == nil { contentQueryStyle = choice == .expression ? .expression : .literal }
            query = [.literal, .documentText, .indexedWords].contains(choice) ? Self.literalQuery(newValue) : newValue
            if newValue.isEmpty {
                mode = .files; query = ""
                refinements.wordSearch = nil; refinements.multiline = nil
            }
            selectRequiredSource()
        }
    }

    package var fileConditionsRequireSpotlight: Bool {
        ruleSet?.fileLeaves.contains(where: \.needsSpotlight) == true
            || (filters.datePeriod != .any && filters.dateField.spotlightAttribute != nil)
    }

    package var availableDateFields: [SearchDateField] {
        SearchDateField.allCases.filter {
            $0.spotlightAttribute == nil || (refinements.wordSearch != true && resultScope == nil && traversal.pathRules?.isEmpty != false)
        }
    }

    package func validateSourceRequirements() throws {
        guard requiresSpotlight else { return }
        if refinements.wordSearch == true {
            throw SearchServiceError.commandFailed("Spotlight date conditions cannot use Indexed words. Choose Live text or remove the Spotlight condition.")
        }
        if resultScope != nil {
            throw SearchServiceError.commandFailed("Spotlight conditions cannot search saved results. Choose a folder scope or remove those conditions.")
        }
        if traversal.pathRules?.isEmpty == false {
            throw SearchServiceError.commandFailed("Spotlight conditions cannot use path patterns. Clear Path rules or remove the Spotlight condition.")
        }
    }

    package var requiresSpotlight: Bool {
        fileConditionsRequireSpotlight || (mode == .contents && refinements.contentSource == .indexedDocumentText)
    }

    package var sourceChoices: [SearchSourceChoice] {
        if requiresSpotlight { return [.spotlight] }
        if resultScope != nil || refinements.wordSearch == true { return [.live] }
        if traversal.pathRules?.isEmpty == false { return mode == .contents ? [.live] : [.live, .snapshot] }
        return mode == .contents ? [.live, .spotlight] : SearchSourceChoice.allCases
    }

    package var sourceChoice: SearchSourceChoice {
        get { useIndex ? .snapshot : refinements.source == .spotlight ? .spotlight : .live }
        set {
            guard sourceChoices.contains(newValue) else { return }
            useIndex = newValue == .snapshot
            refinements.source = newValue == .spotlight ? .spotlight : .filesystem
        }
    }

    package mutating func selectRequiredSource() {
        if requiresSpotlight { useIndex = false; refinements.source = .spotlight }
        else if refinements.wordSearch == true || resultScope != nil {
            useIndex = false; refinements.source = .filesystem
        }
        else if traversal.pathRules?.isEmpty == false { refinements.source = .filesystem }
        if mode == .contents { useIndex = false }
    }

    package mutating func preserveLegacyFileQuery() {
        guard mode != .contents, !query.isEmpty else { return }
        let parsed = ParsedSearchQuery.parseLiteral(query)
        if syntax == .literal, parsed.tokens.count == 1, let token = parsed.tokens.first, !token.isExcluded,
           (token.field == .name || (exactNameMatch && parsed.canUseExactNameMatch)), refinements.name.isEmpty {
            refinements.name = token.globPattern ?? token.value
            refinements.nameMatching = token.globPattern == nil ? (exactNameMatch ? .exact : .contains) : .regex
        } else if syntax == .literal && !exactNameMatch {
            refinements.fileQuery = [refinements.fileQuery, query].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            refinements.savedFileQuery = .init(text: query, syntax: syntax, exactName: exactNameMatch)
        }
        query = ""; syntax = .literal; exactNameMatch = false
    }
}
