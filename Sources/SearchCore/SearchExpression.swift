import Foundation

/// A condition's domain does not constrain where it may appear in the tree.
public enum SearchPredicate: Codable, Hashable, Sendable {
    case file(FilePredicate)
    case content(ContentPredicate)
    public var file: FilePredicate? { if case .file(let value) = self { value } else { nil } }
    public var content: ContentPredicate? { if case .content(let value) = self { value } else { nil } }
}

public extension QueryTree {
    /// Split independent AND factors without distributing OR over AND. Pure
    /// subtrees retain their nesting; a genuinely mixed OR/NOT stays intact.
    func partition<A, B>(_ classify: (Leaf) -> Either<A, B>) -> (QueryTree<A>?, QueryTree<B>?)? {
        switch self {
        case .leaf(let value):
            switch classify(value) { case .left(let a): return (.leaf(a), nil); case .right(let b): return (nil, .leaf(b)) }
        case .all(let children):
            var a: [QueryTree<A>] = [], b: [QueryTree<B>] = []
            for child in children {
                guard let pair = child.partition(classify) else { return nil }
                if let value = pair.0 { a.append(value) }
                if let value = pair.1 { b.append(value) }
            }
            return (a.isEmpty ? nil : .all(a), b.isEmpty ? nil : .all(b))
        case .any(let children), .none(let children):
            var a: [QueryTree<A>] = [], b: [QueryTree<B>] = []
            for child in children {
                guard let pair = child.partition(classify), pair.0 == nil || pair.1 == nil else { return nil }
                if let value = pair.0 { a.append(value) }
                if let value = pair.1 { b.append(value) }
            }
            guard a.isEmpty || b.isEmpty else { return nil }
            let negated: Bool = if case .none = self { true } else { false }
            if b.isEmpty { return (negated ? .none(a) : .any(a), nil) }
            return (nil, negated ? .none(b) : .any(b))
        }
    }
}
public enum Either<A: Codable & Hashable & Sendable, B: Codable & Hashable & Sendable> {
    case left(A), right(B)
}

public extension SearchQuery {
    /// The optimizer stores separable searches in the existing native form.
    /// Only cross-domain Boolean branches require the mixed executor.
    mutating func setExpression(_ value: QueryTree<SearchPredicate>) {
        let value = value.simplified
        if let (f, c) = value.partition({ predicate -> Either<FilePredicate, ContentPredicate> in
            switch predicate { case .file(let file): .left(file); case .content(let content): .right(content) }
        }) {
            files = f?.simplified ?? .all([]); contents = c?.simplified; expression = nil
        } else {
            expression = value; files = .all([]); contents = nil
        }
    }
    var filePredicates: [FilePredicate] { expression?.leaves.compactMap(\.file) ?? files.leaves }
    var contentPredicates: [ContentPredicate] { expression?.leaves.compactMap(\.content) ?? contents?.leaves ?? [] }
    var hasContents: Bool { expression == nil ? contents != nil : !contentPredicates.isEmpty }
}
