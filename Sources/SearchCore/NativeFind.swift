import Foundation

extension SearchPlanner {
    /// Portable fallback for an explicit no-ignore filename search. `find`
    /// cannot implement ignore-file semantics, so it never silently drops them.
    func nativeFind(_ query: SearchQuery) -> Invocation? {
        guard query.expression == nil else { return nil }
        guard tools.fd == nil, let find = tools.find, query.source.kind == .live,
              query.contents == nil, query.action == .search, query.traversal.ignore == .none,
              !overlappingRoots(query.traversal.roots),
              query.traversal.pathRules.isEmpty, query.traversal.packages, query.traversal.excludedPaths.isEmpty else { return nil }
        func predicate(_ node: QueryTree<FilePredicate>) -> [String]? {
            switch node {
            case .leaf(.text(let text)):
                guard [.name, .absolute, .any].contains(text.field), [.literal, .exact].contains(text.kind) else { return nil }
                guard !needsCanonicalFilenamePattern(text.text) else { return nil }
                let name = text.field == .name
                let flag = name ? (query.options.fileCaseSensitive ? "-name" : "-iname") : (query.options.fileCaseSensitive ? "-path" : "-ipath")
                return [flag, (text.kind == .literal ? "*" : "") + escapeGlob(text.text) + (text.kind == .literal ? "*" : "")]
            case .leaf(.extensions(let values)):
                return ["("] + values.enumerated().flatMap { i, value in (i > 0 ? ["-o"] : []) + [query.options.fileCaseSensitive ? "-name" : "-iname", "*." + escapeGlob(value)] } + [")"]
            case .leaf: return nil
            case .all(let xs), .any(let xs), .none(let xs):
                let any: Bool = if case .all = node { false } else { true }
                let negative: Bool = if case .none = node { true } else { false }
                if xs.isEmpty { return any != negative ? ["-false"] : ["-true"] }
                var args = negative ? ["!", "("] : ["("]
                for (i, child) in xs.enumerated() {
                    guard let values = predicate(child) else { return nil }
                    if i > 0 { args.append(any ? "-o" : "-a") }; args += values
                }
                return args + [")"]
            }
        }
        guard let expression = predicate(query.files) else { return nil }
        var args = [query.traversal.follow ? "-L" : "-P"] + query.traversal.roots
        args += ["-mindepth", String(query.traversal.minimumDepth)]
        if let depth = query.traversal.maximumDepth { args += ["-maxdepth", String(depth)] }
        var prune: [String] = []
        if !query.traversal.hidden { prune += ["-name", ".*"] }
        for folder in query.traversal.excludedFolders {
            if !prune.isEmpty { prune.append("-o") }
            prune += ["(", "-type", "d", "-name", escapeGlob(folder), ")"]
        }
        if !prune.isEmpty { args += ["("] + prune + [")", "-prune", "-o"] }
        args += query.traversal.kind == .both ? ["(", "-type", "f", "-o", "-type", "d", ")"] : ["-type", query.traversal.kind == .directory ? "d" : "f"]
        args += expression + ["-print0"]
        return Invocation(find, args)
    }
}
