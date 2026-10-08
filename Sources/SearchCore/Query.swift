import Foundation

/// The semantic boundary. UI state, presets and command imports normalize here;
/// backend selection never reads a widget, persisted control or shell string.
public struct SearchQuery: Codable, Hashable, Sendable {
    public var version = 2
    public var source = QuerySource()
    public var traversal = TraversalPolicy()
    public var files: QueryTree<FilePredicate> = .all([])
    public var contents: QueryTree<ContentPredicate>?
    public var expression: QueryTree<SearchPredicate>?
    public var unit: MatchUnit = .line
    public var options = QueryOptions()
    public var extraction: ExtractionConfiguration?
    public var action: QueryAction = .search
    public init() {}

    public var output: StreamFormat {
        if !hasContents && options.includeMetadata { return .metadata }
        return !hasContents || expression != nil || unit == .file || options.filesOnly || !contentPredicates.isEmpty && contentPredicates.allSatisfy(\.isSpotlight)
            ? .paths : .matches
    }
    public var isRanked: Bool { filePredicates.contains { $0.fuzzy != nil } || action == .wordSearch }
    public func validated() throws -> Self {
        guard version == 2 else { throw PlanningError.invalid("Unsupported search query version \(version).") }
        guard !traversal.roots.isEmpty, traversal.roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              (0...64).contains(options.workers), traversal.minimumDepth >= 0,
              traversal.maximumDepth.map({ $0 >= traversal.minimumDepth }) ?? true,
              (0...2).contains(options.typoTolerance) else {
            throw PlanningError.invalid("Invalid search scope, depth or resource limit.")
        }
        if let expression {
            guard files.isTrue, contents == nil else { throw PlanningError.invalid("Use one search expression.") }
            try expression.validate { leaf in
                switch leaf { case .file(let f): try f.validate(); case .content(let c): try c.validate(multiline: options.multiline) }
            }
        }
        try files.validate { try $0.validate() }
        try contents?.validate { try $0.validate(multiline: options.multiline) }
        if let extraction { try extraction.validate() }
        if source.kind == .snapshot && hasContents { throw PlanningError.invalid("Snapshots contain filenames and metadata. Choose live files for contents.") }
        if source.kind != .spotlight && (filePredicates.contains { if case .date(let date) = $0 { !["modified", "created"].contains(date.field) } else { false } }
            || contentPredicates.contains(where: \.isSpotlight)) {
            throw PlanningError.invalid("These document text or metadata date conditions require Spotlight.")
        }
        if source.kind == .spotlight && !traversal.pathRules.isEmpty { throw PlanningError.invalid("Path patterns require Live files.") }
        if contentPredicates.contains(where: \.isSpotlight) {
            guard !contentPredicates.isEmpty && contentPredicates.allSatisfy(\.isSpotlight), !options.wholeWords, options.typoTolerance == 0 else {
                throw PlanningError.invalid("Spotlight text cannot be mixed with live text options.")
            }
        }
        if [.snapshot, .manifest].contains(source.kind) && !(source.path?.hasPrefix("/") == true && source.path?.contains("\0") == false) {
            throw PlanningError.invalid("This source requires an absolute path.")
        }
        if unit != .line && !hasContents { throw PlanningError.invalid("A content matching unit requires content conditions.") }
        if action == .wordSearch && (unit == .line || source.kind == .snapshot || source.kind == .spotlight) {
            throw PlanningError.invalid("Indexed words require a local document or file search.")
        }
        if options.multiline && (action != .search || source.kind == .spotlight) {
            throw PlanningError.invalid("Multiline matching requires live text.")
        }
        var result = self
        if let expression { result.setExpression(expression) }
        result.files = result.files.simplified
        result.contents = result.contents?.simplified
        return result
    }
}

public enum PlanningError: Error, LocalizedError, Sendable {
    case invalid(String), missingTool(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text): text; case .missingTool(let name): "Required search tool is unavailable: \(name)." }
    }
}
public enum MatchUnit: String, Codable, Sendable { case line, document, file }
public enum QueryAction: String, Codable, Sendable { case search, prepareSignatures, prepareWords, wordSearch }
public enum StreamFormat: String, Codable, Sendable { case paths, metadata, matches, wordCandidates, text }
public enum IgnorePolicy: String, Codable, Sendable { case fd, ripgrep, none, combined }
public enum FileKind: String, Codable, Sendable { case file, directory, both }
public enum SourceKind: String, Codable, Sendable { case live, spotlight, snapshot, manifest }
public enum Freshness: String, Codable, Sendable { case live, frozen }

public struct QuerySource: Codable, Hashable, Sendable {
    public var kind: SourceKind = .live
    public var path: String?
    public var generation: String?
    public var records = false
    public init() {}
    public var freshness: Freshness { kind == .snapshot || kind == .manifest ? .frozen : .live }
}
public struct TraversalPolicy: Codable, Hashable, Sendable {
    public var roots: [String] = []
    public var kind: FileKind = .file
    public var hidden = true
    public var ignore: IgnorePolicy = .fd
    public var follow = false
    public var minimumDepth = 1
    public var maximumDepth: Int?
    public var excludedFolders = [".git"]
    public var excludedPaths: [String] = []
    public var packages = true
    public var packageExtensions: [String] = []
    public var pathRules: [String] = []
    public var ruleRoot: String?
    public init() {}
}
public struct QueryOptions: Codable, Hashable, Sendable {
    public var fuzzyNormalize: Bool? = nil
    public var includeMetadata = false
    public var fileCaseSensitive = false
    public var contentCaseSensitive = false
    public var wholeWords = false
    public var filesOnly = false
    public var workers = 0
    public var collectStatistics = false
    public var useContentIndex = false
    public var cacheDirectory: String?
    public var encoding: String?
    public var typoTolerance = 0
    public var stemWords = false
    public var multiline = false
    public var wordLanguage: WordLanguage? = nil
    public init() {}
}

public indirect enum QueryTree<Leaf: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case leaf(Leaf), all([Self]), any([Self]), none([Self])
    public var leaves: [Leaf] {
        switch self { case .leaf(let value): [value]; case .all(let xs), .any(let xs), .none(let xs): xs.flatMap(\.leaves) }
    }
    public var isTrue: Bool { if case .all(let xs) = self { xs.isEmpty } else { false } }
    public var single: Leaf? { if case .leaf(let x) = simplified { x } else { nil } }
    public var conjunction: [Leaf]? {
        switch simplified {
        case .leaf(let x): [x]
        case .all(let xs): xs.allSatisfy { $0.conjunction != nil } ? xs.flatMap { $0.conjunction! } : nil
        default: nil
        }
    }
    /// Stable reduction: preserve branch order because fuzzy ranking can make
    /// the order observable. No distributive expansion or exponential rewrite.
    public var simplified: Self {
        switch self {
        case .leaf: return self
        case .all(let xs):
            let children = stableUnique(xs.flatMap { node -> [Self] in
                if case .all(let nested) = node.simplified { return nested }; return [node.simplified]
            })
            if children.contains(where: { if case .any(let values) = $0 { values.isEmpty } else { false } }) { return .any([]) }
            return children.count == 1 ? children[0] : .all(children)
        case .any(let xs):
            let children = stableUnique(xs.flatMap { node -> [Self] in
                if case .any(let nested) = node.simplified { return nested }; return [node.simplified]
            })
            if children.contains(where: \.isTrue) { return .all([]) }
            return children.count == 1 ? children[0] : .any(children)
        case .none(let xs):
            let children = stableUnique(xs.map(\.simplified))
            if children.contains(where: \.isTrue) { return .any([]) }
            if children.isEmpty { return .all([]) }
            return .none(children)
        }
    }
    public func map<T>(_ transform: (Leaf) throws -> T) rethrows -> QueryTree<T> {
        switch self {
        case .leaf(let x): return .leaf(try transform(x))
        case .all(let xs): return .all(try xs.map { try $0.map(transform) })
        case .any(let xs): return .any(try xs.map { try $0.map(transform) })
        case .none(let xs): return .none(try xs.map { try $0.map(transform) })
        }
    }
    public func flatMap<T>(_ transform: (Leaf) throws -> QueryTree<T>) rethrows -> QueryTree<T> {
        switch self {
        case .leaf(let x): return try transform(x)
        case .all(let xs): return .all(try xs.map { try $0.flatMap(transform) })
        case .any(let xs): return .any(try xs.map { try $0.flatMap(transform) })
        case .none(let xs): return .none(try xs.map { try $0.flatMap(transform) })
        }
    }
    public func validate(_ leaf: (Leaf) throws -> Void) throws {
        var count = 0
        func visit(_ node: Self, _ depth: Int) throws {
            count += 1
            guard count <= 256, depth <= 12 else { throw PlanningError.invalid("Search expression is too large.") }
            switch node {
            case .leaf(let x): try leaf(x)
            case .all(let xs), .any(let xs), .none(let xs): for x in xs { try visit(x, depth + 1) }
            }
        }
        try visit(self, 0)
    }
    public func evaluate(_ predicate: (Leaf) -> Bool) -> Bool {
        switch self {
        case .leaf(let x): predicate(x)
        case .all(let xs): xs.allSatisfy { $0.evaluate(predicate) }
        case .any(let xs): xs.contains { $0.evaluate(predicate) }
        case .none(let xs): !xs.contains { $0.evaluate(predicate) }
        }
    }
}
private func stableUnique<T: Hashable>(_ xs: [T]) -> [T] {
    var seen = Set<T>(); return xs.filter { seen.insert($0).inserted }
}

public enum PathField: String, Codable, Sendable { case name, relative, absolute, any }
public enum PatternKind: String, Codable, Sendable { case literal, exact, glob, regex, fuzzy }
public struct PathMatch: Codable, Hashable, Sendable {
    public var field: PathField
    public var kind: PatternKind
    public var text: String
    public init(_ field: PathField, _ kind: PatternKind, _ text: String) { self.field = field; self.kind = kind; self.text = text }
}
public struct ByteRange: Codable, Hashable, Sendable {
    public var minimum: UInt64?
    public var maximum: UInt64?
    public init(minimum: UInt64? = nil, maximum: UInt64? = nil) { self.minimum = minimum; self.maximum = maximum }
}
public struct TimeRange: Codable, Hashable, Sendable {
    public var field: String
    public var from: Double?
    public var before: Double?
    public init(field: String, from: Double?, before: Double?) { self.field = field; self.from = from; self.before = before }
}
public enum TagOperation: String, Codable, Sendable { case all, any, none }
public struct TagPredicate: Codable, Hashable, Sendable {
    public var values: [String]
    public var operation: TagOperation
    public init(_ values: [String], _ operation: TagOperation) { self.values = values; self.operation = operation }
}
public enum FilePredicate: Codable, Hashable, Sendable {
    case text(PathMatch), extensions([String]), size(ByteRange), date(TimeRange), tags(TagPredicate)
    public var fuzzy: PathMatch? { if case .text(let x) = self, x.kind == .fuzzy { x } else { nil } }
    public var needsMetadata: Bool { switch self { case .text, .extensions: false; default: true } }
    public func validate() throws {
        switch self {
        case .text(let x): guard !x.text.contains("\0") else { throw PlanningError.invalid("Patterns cannot contain NUL.") }
        case .extensions(let values):
            guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty && !$0.contains(where: { "/\0".contains($0) }) }) else { throw PlanningError.invalid("Invalid filename extension.") }
        case .size(let x):
            if let a = x.minimum, let b = x.maximum, a > b { throw PlanningError.invalid("Minimum size exceeds maximum size.") }
        case .date(let x):
            guard x.from.map(\.isFinite) ?? true, x.before.map(\.isFinite) ?? true else { throw PlanningError.invalid("Invalid date bound.") }
        case .tags(let x):
            guard !x.values.isEmpty, x.values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw PlanningError.invalid("Invalid Finder tag.") }
        }
    }
}
public struct ProximityPredicate: Codable, Hashable, Sendable {
    public var terms: [String]
    public var distance: Int
    public var ordered: Bool
    public init(terms: [String], distance: Int, ordered: Bool) { self.terms = terms; self.distance = distance; self.ordered = ordered }
}
public struct MetadataPredicate: Codable, Hashable, Sendable {
    public var field: String
    public var text: String
    public init(field: String, text: String) { self.field = field; self.text = text }
}
public enum ContentPredicate: Codable, Hashable, Sendable {
    case allLines, literal(String), regex(String), proximity(ProximityPredicate), metadata(MetadataPredicate), spotlight(String)
    public var isSpotlight: Bool { if case .spotlight = self { true } else { false } }
    public func validate(multiline: Bool = false) throws {
        switch self {
        case .allLines: break
        case .literal(let x), .regex(let x), .spotlight(let x):
            guard !x.contains("\0") else { throw PlanningError.invalid("Patterns cannot contain NUL.") }
            if !multiline && !isSpotlight && x.contains("\n") { throw PlanningError.invalid("Content patterns cannot contain line breaks. Use separate conditions to match different lines.") }
        case .proximity(let x):
            guard !x.terms.isEmpty, x.distance >= 0, x.terms.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw PlanningError.invalid("Invalid proximity condition.") }
        case .metadata(let x):
            guard ["author", "title", "member"].contains(x.field), !x.text.contains("\0") else { throw PlanningError.invalid("Invalid metadata condition.") }
        }
    }
}
public struct ExtractionConfiguration: Codable, Hashable, Sendable {
    public var documents = false
    public var archives = false
    public var media = false
    public var adapters: [ReaderAdapter] = []
    public var ffmpeg: String?
    public var ffprobe: String?
    public var maxDepth = 5
    public var maxMegabytes = 64
    public var timeoutSeconds = 60
    public var cacheDirectory: String?
    public var pandoc: String?
    public var pdftotext: String?
    public var pdfdetach: String?
    public var tikaJar: String?
    public var useTika = true
    public init() {}
    public func validate() throws {
        try adapters.forEach { try $0.validate() }
        guard documents || archives || media || !adapters.isEmpty, (0...10).contains(maxDepth), (1...1024).contains(maxMegabytes), (1...600).contains(timeoutSeconds) else {
            throw PlanningError.invalid("Invalid document/archive extraction options.")
        }
    }
}
