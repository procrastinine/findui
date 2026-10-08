import Foundation

package enum SearchQueryField: Hashable, Sendable {
    case any, name, path, ext
}

package struct SearchQueryToken: Hashable, Sendable {
    package let field: SearchQueryField
    package let value: String
    package let isExcluded: Bool
    /// Quoted and escaped stars/question marks remain literal.
    package var globPattern: String? = nil

    package var extensions: [String] {
        value.split(separator: ";").map { SearchFileTypes.literalSuffix($0) }
            .filter { !$0.isEmpty }
    }
    package init(field: SearchQueryField, value: String, isExcluded: Bool, globPattern: String? = nil) {
        self.field = field
        self.value = value
        self.isExcluded = isExcluded
        self.globPattern = globPattern
    }

}

package struct ParsedSearchQuery: Sendable {
    package let raw: String
    package let tokens: [SearchQueryToken]
    package let usesAdvancedSyntax: Bool
    package var errorMessage: String? = nil

    package func validate() throws {
        if let errorMessage { throw SearchServiceError.commandFailed(errorMessage) }
    }

    package var includeTokens: [SearchQueryToken] { tokens.filter { !$0.isExcluded } }
    package var excludeTokens: [SearchQueryToken] { tokens.filter(\.isExcluded) }
    package var canUseExactNameMatch: Bool {
        includeTokens.count == 1 && excludeTokens.isEmpty
            && (includeTokens[0].field == .any || includeTokens[0].field == .name)
            && includeTokens[0].globPattern == nil
    }

    package func preferredAnchor(for mode: SearchMode) -> SearchQueryToken? {
        // Native tools only prefilter with a literal guaranteed to occur in every match.
        // Content's unfielded terms always stay literal, including * and ?.
        let candidates = includeTokens.filter {
            mode == .contents ? $0.field == .any : $0.globPattern == nil && ($0.field != .ext || $0.extensions.count == 1)
        }
        func priority(_ field: SearchQueryField) -> Int {
            switch field { case .name: 0; case .any: 1; case .path: 2; case .ext: 3 }
        }
        return candidates.sorted {
            if priority($0.field) != priority($1.field) { return priority($0.field) < priority($1.field) }
            return $0.value.count > $1.value.count
        }.first
    }

    package static func parseLiteral(_ raw: String) -> ParsedSearchQuery {
        var words: [[(Character, Bool)]] = []
        var word: [(Character, Bool)] = []
        var quote: Character?
        var escaped = false
        var sawQuotes = false
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaped { word.append((character, false)); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { word.append((character, false)) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; sawQuotes = true; continue }
            if character.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
                if !word.isEmpty { words.append(word); word = [] }
            } else { word.append((character, true)) }
        }
        if escaped { word.append(("\\", false)) }
        if !word.isEmpty { words.append(word) }

        var error = quote == nil ? nil : "Close the quote in the search expression. Use Literal to search quotation marks as text."

        let tokens = words.compactMap { characters -> SearchQueryToken? in
            var body = characters
            let excluded = body.count > 1 && body[0].0 == "-" && body[0].1
            if excluded { body.removeFirst() }
            let text = String(body.map(\.0)).lowercased()
            let field: SearchQueryField
            if text.hasPrefix("name:"), body.prefix(5).allSatisfy({ $0.1 }) { field = .name; body.removeFirst(5) }
            else if text.hasPrefix("path:"), body.prefix(5).allSatisfy({ $0.1 }) { field = .path; body.removeFirst(5) }
            else if text.hasPrefix("ext:"), body.prefix(4).allSatisfy({ $0.1 }) { field = .ext; body.removeFirst(4) }
            else { field = .any }
            guard !body.isEmpty else {
                error = error ?? "Enter a value after name:, path: or ext:. Quote the entire term to search it as literal text."
                return nil
            }
            var value = String(body.map(\.0))
            if field == .ext { value = SearchFileTypes.literalSuffix(value) }
            if field == .ext && (value.isEmpty || value.split(separator: ";").allSatisfy({ SearchFileTypes.literalSuffix($0).isEmpty })) {
                error = error ?? "Enter an extension after ext:, such as ext:pdf."
                return nil
            }
            guard !value.isEmpty else { return nil }
            let wildcard = field != .ext && body.contains { $0.1 && ($0.0 == "*" || $0.0 == "?") }
            return SearchQueryToken(field: field, value: value, isExcluded: excluded,
                                    globPattern: wildcard ? globRegex(body) : nil)
        }
        return ParsedSearchQuery(raw: raw, tokens: tokens, usesAdvancedSyntax: sawQuotes || tokens.count > 1
            || tokens.contains { $0.isExcluded || $0.field != .any || $0.globPattern != nil }, errorMessage: error)
    }

    private static func globRegex(_ characters: [(Character, Bool)]) -> String {
        var pattern = "\\A"
        var index = 0
        while index < characters.count {
            let (character, active) = characters[index]
            if active && character == "*" {
                if index + 1 < characters.count, characters[index + 1].0 == "*", characters[index + 1].1 {
                    index += 1
                    if index + 1 < characters.count, characters[index + 1].0 == "/" {
                        pattern += "(?:.*/)?"
                        index += 1
                    } else { pattern += ".*" }
                } else { pattern += "[^/]*" }
            } else if active && character == "?" { pattern += "[^/]" }
            else { pattern += NSRegularExpression.escapedPattern(for: String(character)) }
            index += 1
        }
        return pattern + "\\z"
    }
    package init(raw: String, tokens: [SearchQueryToken], usesAdvancedSyntax: Bool, errorMessage: String? = nil) {
        self.raw = raw
        self.tokens = tokens
        self.usesAdvancedSyntax = usesAdvancedSyntax
        self.errorMessage = errorMessage
    }

}

package struct SearchQueryMatcher: Sendable {
    private let parsed: ParsedSearchQuery
    private let caseSensitive: Bool
    private let exactNameMatch: Bool
    private let fuzzy: Bool
    private let globs: [SearchQueryToken: NSRegularExpression]

    package init(query: String, caseSensitive: Bool, exactNameMatch: Bool, fuzzy: Bool = false) {
        let parsed = ParsedSearchQuery.parseLiteral(query)
        self.parsed = parsed
        self.caseSensitive = caseSensitive
        self.exactNameMatch = exactNameMatch
        self.fuzzy = fuzzy
        var globs: [SearchQueryToken: NSRegularExpression] = [:]
        for token in parsed.tokens {
            if let pattern = token.globPattern {
                globs[token] = try? NSRegularExpression(pattern: pattern,
                    options: caseSensitive ? [.dotMatchesLineSeparators] : [.caseInsensitive, .dotMatchesLineSeparators])
            }
        }
        self.globs = globs
    }

    package var usesAdvancedSyntax: Bool { parsed.usesAdvancedSyntax }

    package func rankForNameCandidate(name: String, path: String, relativePath: String? = nil, fileExtension: String? = nil) -> Int? {
        let paths = [relativePath, path].compactMap { $0 }
        var highestRank = parsed.includeTokens.isEmpty ? 4 : 0
        for token in parsed.includeTokens {
            guard let rank = rank(token, name: name, paths: paths, fileExtension: fileExtension ?? "",
                                  exact: exactNameMatch && parsed.canUseExactNameMatch, allowFuzzy: fuzzy) else { return nil }
            highestRank = max(highestRank, rank)
        }
        for token in parsed.excludeTokens {
            if rank(token, name: name, paths: paths, fileExtension: fileExtension ?? "", exact: false, allowFuzzy: false) != nil {
                return nil
            }
        }
        return highestRank
    }

    package func matchesContentCandidate(name: String, path: String, relativePath: String? = nil,
                                 fileExtension: String? = nil, snippet: String) -> Bool {
        for token in parsed.tokens {
            let matches = token.field == .any
                ? normalized(snippet).contains(normalized(token.value))
                : rank(token, name: name, paths: [relativePath, path].compactMap { $0 },
                       fileExtension: fileExtension ?? "", exact: false, allowFuzzy: false) != nil
            if matches == token.isExcluded { return false }
        }
        return true
    }

    private func normalized(_ value: String) -> String { caseSensitive ? value : value.lowercased() }

    private func rank(_ token: SearchQueryToken, name: String, paths: [String],
                      fileExtension: String, exact: Bool, allowFuzzy: Bool) -> Int? {
        if let glob = globs[token] {
            let candidates = token.field == .path || (token.field == .any && token.value.contains("/")) ? paths : [name]
            return candidates.contains { glob.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ? 2 : nil
        }
        let name = normalized(name)
        let term = normalized(token.value)
        switch token.field {
        case .any, .name:
            if exact { return name == term ? 0 : nil }
            if allowFuzzy { return FuzzyFilenameMatcher.rank(term: term, name: name) }
            if name == term { return 0 }
            if name.hasPrefix(term) { return 1 }
            if name.contains(term) { return 2 }
            return token.field == .any && paths.contains { normalized($0).contains(term) } ? 3 : nil
        case .path:
            return paths.contains { normalized($0).contains(term) } ? 3 : nil
        case .ext:
            return token.extensions.contains {
                let suffix = normalized($0)
                return normalized(fileExtension) == suffix || name.hasSuffix("." + suffix)
            } ? 1 : nil
        }
    }
}

package enum FuzzyFilenameMatcher {
    /// Ordered character matching, with exact/contiguous names ahead of scattered matches.
    package static func rank(term: String, name: String) -> Int? {
        if term.isEmpty { return 4 }
        if name == term { return 0 }
        if name.hasPrefix(term) { return 1 }
        if name.contains(term) { return 2 }
        let needle = Array(term)
        let haystack = Array(name)
        var next = 0
        var start = 0
        var previous = 0
        var gaps = 0
        for (index, character) in haystack.enumerated() where character == needle[next] {
            if next == 0 { start = index } else { gaps += index - previous - 1 }
            previous = index
            next += 1
            if next == needle.count { return 100 + start * 4 + gaps * 3 + max(0, haystack.count - needle.count) }
        }
        return nil
    }
}

package struct NameQueryMatcher: Sendable {
    private let literal: SearchQueryMatcher?
    private let regex: NSRegularExpression?
    private let exactName: Bool

    package init(query: String, syntax: SearchSyntax = .literal, caseSensitive: Bool, exactNameMatch: Bool) throws {
        exactName = exactNameMatch && syntax != .fuzzy
        literal = syntax != .regex
            ? SearchQueryMatcher(query: query, caseSensitive: caseSensitive,
                                 exactNameMatch: exactNameMatch && syntax != .fuzzy, fuzzy: syntax == .fuzzy)
            : nil
        regex = syntax == .regex
            ? try NSRegularExpression(pattern: exactNameMatch ? "\\A(?:\(query))\\z" : query,
                                      options: caseSensitive ? [] : [.caseInsensitive])
            : nil
    }

    package func rank(name: String, path: String, relativePath: String?, fileExtension: String) -> Int? {
        if let literal {
            return literal.rankForNameCandidate(name: name, path: path, relativePath: relativePath, fileExtension: fileExtension)
        }
        guard let regex else { return nil }
        if regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { return 1 }
        guard !exactName else { return nil }
        return [path, relativePath].compactMap { $0 }.contains {
            regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        } ? 3 : nil
    }
}
