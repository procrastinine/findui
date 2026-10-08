import SearchBackend
#if canImport(FindUI)
@testable import FindUI
#endif
import Foundation

/// Sparse input format: a group has exactly one all/any/none key; a leaf reuses
/// the ordinary intent's predicate fields. Fields in the same leaf are ANDed.
/// Global scope/traversal options cannot appear inside a conditional branch.
indirect enum SearchIntentTree: Codable {
    case all([Self]), any([Self]), none([Self]), predicate(SearchIntent)

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static let fileFields: Set<String> = ["name", "nameMatching", "path", "pathMatching", "extensions",
        "minimum", "maximum", "date", "dateField", "relativeDays", "dateFrom", "dateThrough",
        "calendarPeriod", "calendarAge", "calendarBoundary", "excludedFiles", "excludedExtensions"]
    static let contentFields: Set<String> = ["content", "contentMatching", "contentSource"]

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: Key.self)
        let keys = Set(value.allKeys.map(\.stringValue))
        let groups = keys.intersection(["all", "any", "none"])
        if let group = groups.first {
            guard keys.count == 1 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "A rule group has exactly one all, any, or none key."))
            }
            let children = try value.decode([Self].self, forKey: Key(group))
            switch group { case "all": self = .all(children); case "any": self = .any(children); default: self = .none(children) }
        } else {
            guard !keys.isEmpty, keys.isSubset(of: Self.fileFields) || keys.isSubset(of: Self.contentFields) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "A condition contains either file predicates or a content predicate; scope options belong at the root."))
            }
            self = .predicate(try SearchIntent(from: decoder, defaultMode: keys.isSubset(of: Self.contentFields) ? "contents" : "files"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: Key.self)
        switch self {
        case .all(let children): try value.encode(children, forKey: Key("all"))
        case .any(let children): try value.encode(children, forKey: Key("any"))
        case .none(let children): try value.encode(children, forKey: Key("none"))
        case .predicate(let leaf):
            let fields = try JSONDecoder().decode([String: SearchWireValue].self, from: JSONEncoder().encode(leaf))
            for (key, field) in fields where key != "mode" { try value.encode(field, forKey: Key(key)) }
        }
    }

    func fileRules(context: SearchState) throws -> SearchRuleTree<SearchFileRule> {
        switch self {
        case .all(let children): return .all(try children.map { try $0.fileRules(context: context) })
        case .any(let children): return .any(try children.map { try $0.fileRules(context: context) })
        case .none(let children): return .none(try children.map { try $0.fileRules(context: context) })
        case .predicate(let leaf):
            guard leaf.mode == "files" else { throw SearchServiceError.commandFailed("Content predicates belong in Contents.") }
            var state = try leaf.naturalPlan().resolvedState(context: context).0
            try state.promoteToRules()
            guard let tree = state.ruleSet?.files, !tree.leaves.isEmpty else { throw SearchServiceError.invalidQuery }
            if case .all(let children) = tree, children.count == 1 { return children[0] }
            return tree
        }
    }

    func contentRules(context: SearchState) throws -> SearchRuleTree<SearchContentRule> {
        switch self {
        case .all(let children): return .all(try children.map { try $0.contentRules(context: context) })
        case .any(let children): return .any(try children.map { try $0.contentRules(context: context) })
        case .none(let children): return .none(try children.map { try $0.contentRules(context: context) })
        case .predicate(let leaf):
            guard leaf.mode == "contents", let text = leaf.content, !text.isEmpty else {
                throw SearchServiceError.commandFailed("Each content condition needs a literal, regex, or document-text value.")
            }
            _ = try leaf.naturalPlan() // Validate matching/source combinations.
            if leaf.contentSource == .indexedDocumentText {
                guard leaf.contentMatching == nil || leaf.contentMatching == .literal else {
                    throw SearchServiceError.commandFailed("Document text does not use regular expressions.")
                }
                return .rule(.documentText(text))
            }
            guard leaf.contentMatching != .fuzzy else { throw SearchServiceError.invalidQuery }
            return .rule(leaf.contentMatching == .regex ? .regex(text) : .literal(text))
        }
    }

    func validateShape() throws {
        var nodes = 0
        func visit(_ tree: Self, depth: Int) throws {
            nodes += 1
            guard depth <= 8, nodes <= 64 else {
                throw SearchServiceError.commandFailed("Use at most 64 conditions and 8 group levels.")
            }
            switch tree {
            case .predicate: break
            case .all(let children), .any(let children), .none(let children):
                guard !children.isEmpty else { throw SearchServiceError.invalidQuery }
                for child in children { try visit(child, depth: depth + 1) }
            }
        }
        try visit(self, depth: 0)
    }
}

/// Lossless JSON scalars for removing the redundant mode key from a leaf.
/// Decimal avoids changing exact byte quantities through a Double conversion.
private indirect enum SearchWireValue: Codable {
    case string(String), number(Decimal), bool(Bool), array([Self]), object([String: Self]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([Self].self) { self = .array(item) }
        else if let item = try? value.decode([String: Self].self) { self = .object(item) }
        else { self = .number(try value.decode(Decimal.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}
