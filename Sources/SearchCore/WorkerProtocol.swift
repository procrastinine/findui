import Foundation

/// Stable wire types for the bundled worker. No Swift enum layout or control
/// model crosses this boundary. Old low-level commands remain input adapters.
public struct WorkerRequest: Codable, Hashable, Sendable {
    public var version = 1
    public var source = WorkerSource()
    public var traversal: WalkConfiguration?
    public var paths: PathsConfiguration?
    public var content: ContentConfiguration?
    public var selection: FileSelectionConfiguration?
    public var spotlight: SpotlightConfiguration?
    public var action: QueryAction = .search
    public var unit: MatchUnit = .line
    public var output: StreamFormat = .paths
    public var budget = ResourceBudget(workers: 0)
    public init() {}
}
public struct WorkerSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case live, stdin, snapshot, records, manifest, words }
    public var kind: Kind = .stdin
    public var path: String?
    public var generation: String?
    public init() {}
}
public struct WalkConfiguration: Codable, Hashable, Sendable {
    public var roots: [String] = []
    public var hidden = true
    public var ignored = false
    public var ignorePolicy: IgnorePolicy = .fd
    public var follow = false
    public var minimumDepth = 1
    public var maximumDepth: Int?
    public var excludedFolders: [String] = []
    public var excludedPaths: [String] = []
    public var pathRules: [String] = []
    public var ruleRoot: String?
    public var packageExtensions: [String] = []
    public var packages = true
    public var threads = 0
    public var kind = "f"
    public var minimum: UInt64?
    public var maximum: UInt64?
    public init() {}
    public init(_ query: SearchQuery, workers: Int? = nil) {
        self.init(); let t = query.traversal
        roots = t.roots; hidden = t.hidden; ignored = t.ignore == .none; ignorePolicy = t.ignore
        follow = t.follow; minimumDepth = t.minimumDepth; maximumDepth = t.maximumDepth
        excludedFolders = t.excludedFolders; excludedPaths = t.excludedPaths; pathRules = t.pathRules
        ruleRoot = t.ruleRoot; packageExtensions = t.packageExtensions; packages = t.packages
        threads = workers ?? query.options.workers
        kind = t.kind == .both ? "both" : t.kind == .directory ? "d" : "f"
    }
}
public indirect enum PredicateExpression: Codable, Hashable, Sendable {
    case leaf(Int), all([Self]), any([Self]), none([Self])
    private enum Keys: String, CodingKey { case leaf, all, any, none }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.count == 1 else { throw PlanningError.invalid("An expression needs exactly one operator.") }
        switch c.allKeys[0] {
        case .leaf: self = .leaf(try c.decode(Int.self, forKey: .leaf))
        case .all: self = .all(try c.decode([Self].self, forKey: .all))
        case .any: self = .any(try c.decode([Self].self, forKey: .any))
        case .none: self = .none(try c.decode([Self].self, forKey: .none))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .leaf(let x): try c.encode(x, forKey: .leaf)
        case .all(let x): try c.encode(x, forKey: .all)
        case .any(let x): try c.encode(x, forKey: .any)
        case .none(let x): try c.encode(x, forKey: .none)
        }
    }
    public var positive: [Int] {
        func visit(_ t: Self, negative: Bool) -> [Int] {
            switch t {
            case .leaf(let x): negative ? [] : [x]
            case .all(let xs), .any(let xs): xs.flatMap { visit($0, negative: negative) }
            case .none(let xs): xs.flatMap { visit($0, negative: !negative) }
            }
        }
        var seen = Set<Int>(); return visit(self, negative: false).filter { seen.insert($0).inserted }
    }
}
public extension QueryTree {
    func indexed() -> (expression: PredicateExpression, leaves: [Leaf]) {
        var leaves: [Leaf] = [], indices: [Leaf: Int] = [:]
        func visit(_ node: Self) -> PredicateExpression {
            switch node {
            case .leaf(let x):
                if let index = indices[x] { return .leaf(index) }
                let index = leaves.count; indices[x] = index; leaves.append(x); return .leaf(index)
            case .all(let xs): return .all(xs.map(visit))
            case .any(let xs): return .any(xs.map(visit))
            case .none(let xs): return .none(xs.map(visit))
            }
        }
        let expression = visit(self)
        return (expression, leaves)
    }
}
public struct PathCondition: Codable, Hashable, Sendable {
    public var field: String
    public var value: String
    public var regex: Bool
    public var exclude = false
    public init(field: String, value: String, regex: Bool) { self.field = field; self.value = value; self.regex = regex }
}
public struct PathsConfiguration: Codable, Hashable, Sendable {
    public var conditions: [PathCondition] = []
    public var caseSensitive = false
    public var semantics = "native"
    public var snapshot = false
    public var follow = false
    public var tags: [String] = []
    public var tagMatch: TagOperation = .all
    public var roots: [String] = []
    public var type = "f"
    public var minimum: UInt64?
    public var maximum: UInt64?
    public var from: Double?
    public var before: Double?
    public var bornFrom: Double?
    public var bornBefore: Double?
    public var hidden = true
    public var excludedFolders: [String] = []
    public var packages = true
    public var packageExtensions: [String] = []
    public var minimumDepth = 1
    public var maximumDepth: Int?
    public var leaves: [Self]?
    public var tree: PredicateExpression?
    public var metadataDate: TimeRange?
    public init() {}
}
public struct ContentLeaf: Codable, Hashable, Sendable {
    public var pattern = ""
    public var regex = false
    public var terms: [String] = []
    public var distance = 0
    public var ordered = false
    public var field: String?
    public var fileIndex: Int?
    public init() {}
}
public struct WordScope: Codable, Hashable, Sendable {
    public var files: QueryTree<FilePredicate>
    public var unfiltered: Bool
    public var traversal: TraversalPolicy
    public var hidden: Bool
    public var caseSensitive: Bool
    public var resultScope: String?
    public init(_ query: SearchQuery) {
        files = query.files; unfiltered = query.files.isTrue; traversal = query.traversal
        traversal.roots = traversal.roots.map(canonicalIdentityPath)
        traversal.ruleRoot = traversal.ruleRoot.map(canonicalIdentityPath)
        traversal.excludedPaths = traversal.excludedPaths.map(canonicalIdentityPath)
        hidden = query.traversal.hidden; caseSensitive = query.options.fileCaseSensitive
        resultScope = query.source.kind == .manifest ? query.source.path.map(canonicalIdentityPath) : nil
    }
}
public struct ContentConfiguration: Codable, Hashable, Sendable {
    public var tree: PredicateExpression = .all([])
    public var leaves: [ContentLeaf] = []
    public var filePredicates: PathsConfiguration?
    public var positive: [Int] = []
    public var caseSensitive = false
    public var wholeWords = false
    public var filesOnly = false
    public var fileUnit = false
    public var documentUnit = false
    public var threads = 0
    public var stats = false
    public var ordered = false
    public var extraction: ExtractionConfiguration?
    public var indexDirectory: String?
    public var indexOnly = false
    public var archiveNamesOnly = false
    public var useIndex = false
    public var encoding: String?
    public var typoTolerance = 0
    public var stemWords = false
    public var multiline = false
    public var wordLanguage: WordLanguage? = nil
    public var wordRoots: [String] = []
    public var wordScope: WordScope?
    public init() {}
}
public struct FuzzyConfiguration: Codable, Hashable, Sendable {
    public let leaf: Int
    public let invocation: Invocation
    public let relativeRoots: [String]?
    public init(leaf: Int, invocation: Invocation, relativeRoots: [String]? = nil) {
        self.leaf = leaf; self.invocation = invocation; self.relativeRoots = relativeRoots
    }
}
public struct FileSelectionConfiguration: Codable, Hashable, Sendable {
    public var predicates: PathsConfiguration
    public var fuzzies: [FuzzyConfiguration]
    public var masks = false
    public init(predicates: PathsConfiguration, fuzzies: [FuzzyConfiguration]) { self.predicates = predicates; self.fuzzies = fuzzies }
}
public struct SearchCompletion: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case complete, partial, cancelled, failed }
    public var version = 1
    public var status: Status
    public var skipped: Int
    public var message: String?
    public init(status: Status, skipped: Int = 0, message: String? = nil) { self.status = status; self.skipped = skipped; self.message = message }
}
public struct SpotlightConfiguration: Codable, Hashable, Sendable {
    public let executable: String
    public let roots: [String]
    public let predicate: String
    public init(executable: String, roots: [String], predicate: String) { self.executable = executable; self.roots = roots; self.predicate = predicate }
}
