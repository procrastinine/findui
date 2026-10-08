import Foundation
import SearchCore

/// Recursive Boolean expression shared by persistence, controls and compiler.
package indirect enum SearchRuleTree<Rule: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case rule(Rule)
    case all([Self])
    case any([Self])
    case none([Self])

    package func map<T>(_ transform: (Rule) -> T) -> SearchRuleTree<T> {
        switch self {
        case .rule(let value): .rule(transform(value))
        case .all(let children): .all(children.map { $0.map(transform) })
        case .any(let children): .any(children.map { $0.map(transform) })
        case .none(let children): .none(children.map { $0.map(transform) })
        }
    }
    package var queryTree: QueryTree<Rule> {
        switch self {
        case .rule(let value): .leaf(value)
        case .all(let children): .all(children.map(\.queryTree))
        case .any(let children): .any(children.map(\.queryTree))
        case .none(let children): .none(children.map(\.queryTree))
        }
    }
    package init(_ tree: QueryTree<Rule>) {
        switch tree {
        case .leaf(let value): self = .rule(value)
        case .all(let children): self = .all(children.map(Self.init))
        case .any(let children): self = .any(children.map(Self.init))
        case .none(let children): self = .none(children.map(Self.init))
        }
    }

    package var leaves: [Rule] {
        switch self {
        case .rule(let rule): [rule]
        case .all(let nodes), .any(let nodes), .none(let nodes): nodes.flatMap(\.leaves)
        }
    }

    /// Empty ALL at the file root means no restriction. An empty group being
    /// edited anywhere else is incomplete, never an accidentally broader query.
    package func validate(allowEmptyRoot: Bool = false, validateRule: (Rule) throws -> Void) throws {
        var count = 0
        func visit(_ node: Self, depth: Int) throws {
            count += 1
            guard depth <= 8, count <= 64 else {
                throw SearchServiceError.commandFailed("Use at most 64 conditions and 8 levels of groups.")
            }
            switch node {
            case .rule(let rule): try validateRule(rule)
            case .all(let nodes):
                guard !nodes.isEmpty || (depth == 0 && allowEmptyRoot) else {
                    throw SearchServiceError.commandFailed("Add a condition to the empty All group, or remove it.")
                }
                for node in nodes { try visit(node, depth: depth + 1) }
            case .any(let nodes), .none(let nodes):
                guard !nodes.isEmpty else {
                    throw SearchServiceError.commandFailed("Add a condition to the empty group, or remove it.")
                }
                for node in nodes { try visit(node, depth: depth + 1) }
            }
        }
        try visit(self, depth: 0)
    }

    /// Compiler-owned JSON contains only operators and integer leaf references.
    /// User text remains in separately quoted command arguments.
    package func indexedExpression(next: inout Int) -> [String: Any] {
        switch self {
        case .rule:
            defer { next += 1 }
            return ["leaf": next]
        case .all(let nodes): return ["all": nodes.map { $0.indexedExpression(next: &next) }]
        case .any(let nodes): return ["any": nodes.map { $0.indexedExpression(next: &next) }]
        case .none(let nodes): return ["none": nodes.map { $0.indexedExpression(next: &next) }]
        }
    }

    package var positiveLeafIndices: [Int] {
        var index = 0
        func visit(_ node: Self, negated: Bool) -> [Int] {
            switch node {
            case .rule:
                defer { index += 1 }
                return negated ? [] : [index]
            case .all(let nodes), .any(let nodes): return nodes.flatMap { visit($0, negated: negated) }
            case .none(let nodes): return nodes.flatMap { visit($0, negated: !negated) }
            }
        }
        return visit(self, negated: false)
    }
}

package struct SearchDateCondition: Codable, Hashable, Sendable {
    package var field: SearchDateField = .modified
    package var period: SearchDatePeriod = .week
    package var days: Int? = nil
    package var calendarAge: String? = nil
    package var from: Date = Calendar.current.startOfDay(for: .now)
    package var through: Date = Calendar.current.startOfDay(for: .now)

    package init(_ filters: SearchFilters) {
        field = filters.dateField; period = filters.datePeriod; days = filters.relativeDays
        calendarAge = filters.calendarAge
        from = filters.dateFrom; through = filters.dateThrough
    }

    package var filters: SearchFilters {
        var value = SearchFilters()
        value.dateField = field; value.datePeriod = period; value.relativeDays = days
        value.calendarAge = calendarAge
        value.dateFrom = from; value.dateThrough = through
        return value
    }
}

package enum SearchFileRule: Codable, Hashable, Sendable {
    case name(String, PatternMatching)
    case path(String, PatternMatching, absolute: Bool)
    case extensions([String])
    case tags([String], TagMatch)
    case size(minimum: String, maximum: String)
    case date(SearchDateCondition)
    /// Lossless compatibility for old name/path expressions and fuzzy queries.
    case expression(SearchRefinements.SavedFileQuery)

    package var needsSpotlight: Bool {
        if case .date(let value) = self { return value.field.spotlightAttribute != nil }
        return false
    }

    package var usesFuzzy: Bool {
        switch self {
        case .name(_, .fuzzy), .path(_, .fuzzy, _): true
        case .expression(let value): value.syntax == .fuzzy
        default: false
        }
    }

    package func validate(now: Date) throws {
        func text(_ value: String) throws {
            guard !value.isEmpty, !value.contains("\0") else {
                throw SearchServiceError.commandFailed("Enter a value for each file condition, or remove the empty condition.")
            }
        }
        switch self {
        case .name(let value, _), .path(let value, _, _): try text(value)
        case .tags(let values, _):
            guard !values.isEmpty else { throw SearchServiceError.invalidQuery }
            for value in values { try text(value) }
        case .extensions(let values):
            guard !values.isEmpty else { throw SearchServiceError.invalidQuery }
            for value in values {
                try text(value)
                guard !value.contains(where: { $0.isWhitespace || ",;/\\".contains($0) }) else {
                    throw SearchServiceError.commandFailed("Use individual filename extensions, such as pdf or swift.")
                }
            }
        case .size(let minimum, let maximum):
            guard !minimum.isEmpty || !maximum.isEmpty else { throw SearchServiceError.invalidQuery }
            var filters = SearchFilters(); filters.minimumSize = minimum; filters.maximumSize = maximum
            _ = try filters.validated(now: now)
        case .date(let date):
            guard date.period != .any else {
                throw SearchServiceError.commandFailed("Choose a date condition, or remove this rule.")
            }
            _ = try date.filters.validated(now: now)
        case .expression(let value): try text(value.text)
        }
    }

    package func apply(to request: inout SearchRequest) {
        switch self {
        case .tags(let values, let matching): request.refinements.finderTags = values; request.refinements.tagMatch = matching
        case .name(let text, let matching):
            request.refinements.name = text; request.refinements.nameMatching = matching
        case .path(let text, let matching, let absolute):
            request.refinements.path = text; request.refinements.pathMatching = matching
            request.refinements.absolutePathMatching = absolute
        case .extensions(let values): request.refinements.extensions = values.joined(separator: ",")
        case .size(let minimum, let maximum):
            request.filters.minimumSize = minimum; request.filters.maximumSize = maximum
        case .date(let value): request.filters = value.filters
        case .expression(let value):
            request.query = value.text; request.syntax = value.syntax; request.exactNameMatch = value.exactName
        }
    }
}

package enum SearchContentRule: Codable, Hashable, Sendable {
    case allLines
    case literal(String)
    case regex(String)
    case documentText(String)
    case proximity(SearchProximity)
    case metadata(DocumentMetadataField, String)

    package var isDocumentText: Bool { if case .documentText = self { true } else { false } }

    package func validate() throws {
        let text: String
        switch self {
        case .allLines: return
        case .proximity(let value): try value.validate(); return
        case .metadata(_, let value): text = value
        case .literal(let value), .regex(let value), .documentText(let value): text = value
        }
        guard !text.isEmpty, !text.contains("\0") else {
            throw SearchServiceError.commandFailed("Enter text for each content condition, or remove the empty condition.")
        }
    }

    package func apply(to request: inout SearchRequest) {
        request.mode = .contents
        switch self {
        case .allLines: request.query = ""; request.syntax = .literal
        case .proximity, .metadata:
            request.state.replaceRules(.init(contents: .rule(self), contentUnit: .document))
        case .literal(let text): request.query = SearchState.literalQuery(text); request.syntax = .literal
        case .regex(let text): request.query = text; request.syntax = .regex
        case .documentText(let text):
            request.query = SearchState.literalQuery(text); request.syntax = .literal
            request.refinements.contentSource = .indexedDocumentText
        }
    }
}

package enum SearchContentUnit: String, Codable, CaseIterable, Sendable {
    case line, document, file
    package var title: String { switch self {
    case .line: "On the same line"
    case .document: "Same document / member"
    case .file: "Whole file / container"
    }}
}

package enum DocumentMetadataField: String, Codable, CaseIterable, Sendable {
    case title, author, member
    package var title: String { switch self { case .title: "Document title"; case .author: "Author"; case .member: "Archive member" } }
}
package struct SearchProximity: Codable, Hashable, Sendable {
    package var terms: [String] = []
    package var distance: Int = 10
    package var ordered = false
    package func validate() throws {
        guard (2...16).contains(terms.count), (0...1000).contains(distance),
              terms.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isWhitespace || $0 == "\0" }) }) else {
            throw SearchServiceError.commandFailed("Near words needs 2–16 words and 0–1000 intervening words.")
        }
    }
    package init(terms: [String] = [], distance: Int = 10, ordered: Bool = false) {
        self.terms = terms
        self.distance = distance
        self.ordered = ordered
    }

}

package enum SearchCondition: Codable, Hashable, Sendable {
    case file(SearchFileRule)
    case content(SearchContentRule)
    package var file: SearchFileRule? { if case .file(let value) = self { value } else { nil } }
    package var content: SearchContentRule? { if case .content(let value) = self { value } else { nil } }
    package var summary: String {
        switch self { case .file(let value): value.summary; case .content(let value): "Contents · " + value.summary }
    }
}

/// One persisted tree. The split projection is only available when it is
/// lossless; execution and the detailed editor never flatten mixed branches.
package struct SearchRuleSet: Codable, Hashable, Sendable {
    package var expression: SearchRuleTree<SearchCondition>
    package var contentUnit: SearchContentUnit = .line
    package var fileLeaves: [SearchFileRule] { expression.leaves.compactMap(\.file) }
    package var contentLeaves: [SearchContentRule] { expression.leaves.compactMap(\.content) }
    package var hasContents: Bool { !contentLeaves.isEmpty }
    package var isEmpty: Bool { expression == .all([]) }
    /// Conservative admission for index preparation and diagnostics. Unknown
    /// text predicates may be true or false, including underneath NOT.
    package var candidateFiles: SearchRuleTree<SearchFileRule> {
        func bounds(_ tree: SearchRuleTree<SearchCondition>) -> (QueryTree<SearchFileRule>, QueryTree<SearchFileRule>) {
            switch tree {
            case .rule(.file(let file)): return (.none([.leaf(file)]), .leaf(file))
            case .rule(.content): return (.all([]), .all([]))
            case .all(let children):
                let parts = children.map(bounds); return (.any(parts.map(\.0)), .all(parts.map(\.1)))
            case .any(let children):
                let parts = children.map(bounds); return (.all(parts.map(\.0)), .any(parts.map(\.1)))
            case .none(let children):
                let parts = children.map(bounds); return (.any(parts.map(\.1)), .all(parts.map(\.0)))
            }
        }
        return SearchRuleTree(bounds(expression).1.simplified)
    }
    package var separated: (files: SearchRuleTree<SearchFileRule>, contents: SearchRuleTree<SearchContentRule>?)? {
        guard let pair = expression.queryTree.partition({ rule -> Either<SearchFileRule, SearchContentRule> in
            switch rule { case .file(let f): .left(f); case .content(let c): .right(c) }
        }) else { return nil }
        return (pair.0.map { SearchRuleTree($0.simplified) } ?? .all([]), pair.1.map { SearchRuleTree($0.simplified) })
    }
    // Compatibility for callers constructing separated legacy searches. Mixed
    // edits use expression; silently projecting one branch would be incorrect.
    package var files: SearchRuleTree<SearchFileRule> {
        get { precondition(separated != nil); return separated!.files }
        set { precondition(separated != nil); self = .init(files: newValue, contents: separated!.contents, contentUnit: contentUnit) }
    }
    package var contents: SearchRuleTree<SearchContentRule>? {
        get { precondition(separated != nil); return separated!.contents }
        set { precondition(separated != nil); self = .init(files: separated!.files, contents: newValue, contentUnit: contentUnit) }
    }
    package var needsSpotlight: Bool {
        fileLeaves.contains(where: \.needsSpotlight) || contentLeaves.contains(where: \.isDocumentText)
    }
    package func validate(now: Date) throws {
        try expression.validate(allowEmptyRoot: true) { rule in
            switch rule { case .file(let f): try f.validate(now: now); case .content(let c): try c.validate() }
        }
        let documents = contentLeaves.filter(\.isDocumentText).count
        if documents > 0 {
            guard documents == contentLeaves.count, contentUnit == .file else {
                throw SearchServiceError.commandFailed("Spotlight document text matches whole files. Use Spotlight text for every content condition, or choose live text.")
            }
        }
    }
    package mutating func addFileCondition(_ condition: SearchFileRule) {
        addFileConditions(.rule(condition))
    }
    package mutating func addFileConditions(_ conditions: SearchRuleTree<SearchFileRule>) {
        let addition = conditions.map(SearchCondition.file)
        // The empty root is the identity for AND. Retain an existing root's
        // children instead of nesting an empty or ever-deeper All group.
        if case .all(let children) = expression { expression = .all(children + [addition]) }
        else { expression = .all([expression, addition]) }
    }
    package init(expression: SearchRuleTree<SearchCondition>, contentUnit: SearchContentUnit = .line) {
        self.expression = expression; self.contentUnit = contentUnit
    }
    package init(files: SearchRuleTree<SearchFileRule> = .all([]), contents: SearchRuleTree<SearchContentRule>? = nil, contentUnit: SearchContentUnit = .line) {
        var nodes: [SearchRuleTree<SearchCondition>] = []
        if case .all(let children) = files { nodes += children.map { $0.map(SearchCondition.file) } }
        else { nodes.append(files.map(SearchCondition.file)) }
        if let contents { nodes.append(contents.map(SearchCondition.content)) }
        expression = .all(nodes); self.contentUnit = contentUnit
    }
    private enum CodingKeys: String, CodingKey { case expression, files, contents, contentUnit }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let unit = try c.decodeIfPresent(SearchContentUnit.self, forKey: .contentUnit) ?? .line
        if let expression = try c.decodeIfPresent(SearchRuleTree<SearchCondition>.self, forKey: .expression) {
            guard !c.contains(.files), !c.contains(.contents) else {
                throw DecodingError.dataCorruptedError(forKey: .expression, in: c, debugDescription: "Use one rule tree.")
            }
            self.init(expression: expression, contentUnit: unit)
        } else {
            self.init(files: try c.decodeIfPresent(SearchRuleTree<SearchFileRule>.self, forKey: .files) ?? .all([]),
                contents: try c.decodeIfPresent(SearchRuleTree<SearchContentRule>.self, forKey: .contents), contentUnit: unit)
        }
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expression, forKey: .expression); try c.encode(contentUnit, forKey: .contentUnit)
    }
}
