import Foundation

/// Deterministic, bounded planning. Native commands are the reference plans.
/// A worker is selected only for a capability or composition the direct command
/// cannot preserve. Planning never scans the scope to estimate its size.
public struct SearchPlanner: Sendable {
    public let tools: ToolCapabilities
    public init(tools: ToolCapabilities) { self.tools = tools }

    public func plan(_ input: SearchQuery) throws -> ExecutionPlan {
        let query = try input.validated()
        if query.expression != nil {
            guard let worker = tools.worker else { throw PlanningError.missingTool("findui-content (included in FindUI.app)") }
            let request = try mixedWorkerRequest(query)
            return try ExecutionPlan(query: query, stages: [.init(.select,
                Invocation(worker, ["--execute", try encodeSearchJSON(request)]), output: query.output,
                label: "Mixed conditions")], reasons: ["File conditions prune Boolean branches before one shared content scan."])
        }
        if let command = nativeFD(query) {
            return try ExecutionPlan(query: query, stages: [.init(.enumerate, command, output: .paths, preservesOrder: false, label: "fd")],
                reasons: ["All requested filename conditions are expressed by one fd traversal."])
        }
        if let command = nativeRG(query) {
            return try ExecutionPlan(query: query, stages: [.init(.scan, command, output: query.output, preservesOrder: false, label: "rg")],
                reasons: ["The complete text search is expressed by one ripgrep invocation."])
        }
        if let command = nativeFind(query) {
            return try ExecutionPlan(query: query, stages: [.init(.enumerate, command, output: .paths, preservesOrder: false, label: "find")],
                reasons: ["These filename predicates are directly expressible by find; ignore files are explicitly disabled."])
        }
        var request = try workerRequest(query)
        var stages: [PlanStage] = []
        var reasons: [String] = []

        if query.source.kind == .spotlight {
            guard let mdfind = tools.mdfind else { throw PlanningError.missingTool("mdfind") }
            // Scope union is performed by the worker so roots are deduplicated
            // without shell set operations or repeated body searches.
            request.source.kind = .stdin
            var predicate = try spotlightContent(query.contents, caseSensitive: query.options.contentCaseSensitive)
            if let leaves = query.files.conjunction {
                for leaf in leaves {
                    guard case .date(let date) = leaf, !["modified", "created"].contains(date.field) else { continue }
                    if let from = date.from { predicate += " && \(date.field) >= \(from - 978307200)" }
                    if let before = date.before { predicate += " && \(date.field) < \(before - 978307200)" }
                }
                if var paths = request.paths {
                    paths.leaves = paths.leaves?.map { var leaf = $0; leaf.metadataDate = nil; return leaf }
                    request.paths = paths
                }
            }
            request.spotlight = SpotlightConfiguration(executable: mdfind, roots: query.traversal.roots, predicate: predicate)
            if query.contents?.leaves.allSatisfy(\.isSpotlight) == true { request.content = nil }
            reasons.append("Spotlight supplies candidates; the shared selector applies remaining file conditions.")
        } else if query.source.kind == .live, query.action == .search,
                  let ordered = orderedFuzzyConjunction(query), !ordered.isEmpty,
                  ResourceBudget(workers: query.options.workers).effectiveWorkers >= 1 + ordered.count + (query.contents == nil ? 0 : 1) {
            // Push every cheap AND condition ahead of ranking. Further fuzzy
            // conditions use --no-sort to preserve the first condition's rank.
            var sourceQuery = query; sourceQuery.contents = nil; sourceQuery.unit = .line
            sourceQuery.files = .all((query.files.conjunction ?? []).filter { $0.fuzzy == nil }.map(QueryTree.leaf))
            sourceQuery.options.filesOnly = false
            let allocations = ResourceBudget(workers: query.options.workers).allocation(stages: 1 + ordered.count + (query.contents == nil ? 0 : 1))
            sourceQuery.options.workers = allocations[0]
            if let source = nativeFD(sourceQuery) {
                stages.append(.init(.enumerate, source, output: .paths, preservesOrder: false, label: "fd"))
                for (i, fuzzy) in ordered.enumerated() {
                    var ranking = try fuzzyCommand(fuzzy, query: query, sorted: i == 0)
                    ranking.environment["GOMAXPROCS"] = String(allocations[i + 1])
                    stages.append(.init(.rank, ranking,
                        input: .paths, output: .paths, preservesOrder: i != 0, label: "fzf"))
                }
                if query.contents != nil {
                    guard let worker = tools.worker else { throw PlanningError.missingTool("findui-content") }
                    request.source.kind = .stdin; request.traversal = nil; request.paths = nil; request.selection = nil
                    request.content?.threads = allocations.last!
                    request.content?.ordered = true
                    request.budget = ResourceBudget(workers: allocations.last!)
                    stages.append(.init(.scan, Invocation(worker, ["--execute", try encodeSearchJSON(request)]),
                        input: .paths, output: query.output, label: "Shared content scan"))
                }
                return try ExecutionPlan(query: query, stages: stages,
                    reasons: ["Cheap file predicates precede fuzzy ranking; content conditions share one scan."])
            }
        }

        // Complex file predicates and content conditions share the worker's
        // traversal and budget. No intermediate path pipe loses metadata.
        guard let worker = tools.worker else { throw PlanningError.missingTool("findui-content (included in FindUI.app)") }
        let invocation = Invocation(worker, ["--execute", try encodeSearchJSON(request)])
        stages.append(.init(query.action == .wordSearch ? .queryIndex : .select, invocation,
            output: query.output, preservesOrder: query.isRanked, label: query.action == .wordSearch ? "Prepared words" : query.source.kind == .spotlight ? "Spotlight" : query.isRanked ? "FindUI + fzf" : "FindUI"))
        if reasons.isEmpty {
            reasons.append(query.action == .wordSearch ? "Query prepared words once and render only selected documents." :
                "Share traversal, file metadata and content scans across conditions not expressible by one native command.")
        }
        return try ExecutionPlan(query: query, stages: stages, reasons: reasons)
    }

    public func nativeFD(_ query: SearchQuery) -> Invocation? {
        guard query.expression == nil else { return nil }
        guard let fd = tools.fd, query.source.kind == .live, query.contents == nil, query.action == .search,
              query.traversal.ignore == .fd || query.traversal.ignore == .none,
              query.traversal.pathRules.isEmpty, query.traversal.packages,
              !overlappingRoots(query.traversal.roots),
              let conditions = query.files.conjunction else { return nil }
        var patterns: [PathMatch] = []
        var sizes: [ByteRange] = []
        var extensions: [String] = []
        let aliases = query.traversal.roots.map { ($0, canonicalRoot($0)) }.filter { $0.0 != $0.1 }
        for condition in conditions {
            switch condition {
            case .text(let match):
                guard match.kind != .fuzzy, match.field != .relative,
                      match.kind != .glob || !match.text.contains(where: { "[]{}\\".contains($0) }),
                      match.field != .any || match.kind == .literal,
                      match.field != .name || !match.text.contains("/"),
                      match.kind != .regex || portableRegex(match.text) else { return nil }
                if match.field != .name && !aliases.isEmpty {
                    guard match.kind == .literal, !match.text.contains("/"), aliases.allSatisfy({ old, new in
                        (old.range(of: match.text, options: query.options.fileCaseSensitive ? [] : .caseInsensitive) != nil)
                            == (new.range(of: match.text, options: query.options.fileCaseSensitive ? [] : .caseInsensitive) != nil)
                    }) else { return nil }
                }
                patterns.append(match)
            case .size(let range): sizes.append(range)
            case .extensions(let values):
                guard extensions.isEmpty else { return nil }
                extensions = values
            default: return nil
            }
        }
        // fd's --extension is always case-insensitive, independently of -s.
        // Use its regex engine when extension case is part of the query.
        if query.options.fileCaseSensitive && !extensions.isEmpty {
            patterns.append(.init(.name, .regex, "\\.(?:" + extensions.map(escapeRegex).joined(separator: "|") + ")\\z"))
            extensions = []
        }
        let fullPath = patterns.contains { $0.field != .name }
        if fullPath && patterns.contains(where: { $0.field == .name && $0.kind == .regex }) { return nil }
        let kinds = Set(patterns.map(\.kind))
        let simple = Set(patterns.map(\.field)).count <= 1 && kinds.count <= 1
            && !patterns.contains { [.literal, .exact].contains($0.kind) && needsCanonicalFilenamePattern($0.text) }
        // Roots are already absolute. --absolute-path needlessly resolves
        // aliases such as /var and symlinked roots, changing result spelling.
        var args = ["--print0", "--color", "never", "--show-errors"]
        if query.traversal.kind != .directory { args += ["--type", "f"] }
        if query.traversal.kind != .file { args += ["--type", "d"] }
        args.append(query.options.fileCaseSensitive ? "--case-sensitive" : "--ignore-case")
        if query.traversal.hidden { args.append("--hidden") }
        else { args += ["--exclude", ".*"] }
        if query.traversal.ignore == .none { args.append("--no-ignore") }
        if query.traversal.follow { args.append("--follow") }
        if query.traversal.minimumDepth != 1 { args += ["--min-depth", String(query.traversal.minimumDepth)] }
        if let max = query.traversal.maximumDepth { args += ["--max-depth", String(max)] }
        if query.options.workers > 0 { args += ["--threads", String(query.options.workers)] }
        for folder in query.traversal.excludedFolders { args += ["--exclude", escapeGlob(folder) + "/"] }
        // Native defaults do not write derived content. Explicit excluded paths
        // are used by worker scans and do not burden ordinary filename searches.
        guard query.traversal.excludedPaths.isEmpty else { return nil }
        for size in sizes {
            if let lo = size.minimum { args += ["--size", "+\(lo)b"] }
            if let hi = size.maximum { args += ["--size", "-\(hi)b"] }
        }
        for value in extensions { args += ["--extension", value] }
        if fullPath { args.append("--full-path") }
        let values: [String]
        if simple {
            switch patterns.first?.kind {
            case .literal: args.append("--fixed-strings")
            case .exact: args.append("--exact")
            case .glob:
                if !fullPath && query.options.fileCaseSensitive && !patterns.contains(where: { needsCanonicalFilenamePattern($0.text) }) { args.append("--glob") }
            default: break
            }
            values = patterns.map {
                guard $0.kind == .glob && !args.contains("--glob") else { return $0.text }
                // fd rejects '/' even inside a negated class in basename mode.
                // The basename cannot contain '/', so dot is equivalent there.
                let pattern = fullPath ? regexPattern($0) : regexPattern($0).replacingOccurrences(of: "[^/]", with: ".")
                return "(?s:" + pattern + ")"
            }
        } else {
            values = patterns.map { match in
                let pattern = regexPattern(match)
                if match.field == .name && fullPath {
                    // An anchored basename condition is independent of the
                    // root spelling; no interpretation of shell text occurs.
                    switch match.kind {
                    case .literal: return "(?:^|/)[^/]*" + filenameLiteralRegex(match.text) + "[^/]*\\z"
                    case .exact: return "(?:^|/)" + filenameLiteralRegex(match.text) + "\\z"
                    case .glob: return "(?:^|/)(?:" + String(pattern.dropFirst(2).dropLast(2)) + ")\\z"
                    default: return pattern
                    }
                }
                return pattern
            }
        }
        for pattern in values.dropFirst() { args += ["--and", pattern] }
        args += ["--", values.first ?? ""] + query.traversal.roots
        return Invocation(fd, args)
    }

    public func nativeRG(_ query: SearchQuery) -> Invocation? {
        guard query.expression == nil else { return nil }
        guard let rg = tools.rg, query.source.kind == .live, query.action == .search,
              query.traversal.ignore == .ripgrep || query.traversal.ignore == .none,
              query.traversal.minimumDepth == 1, query.traversal.packages,
              !overlappingRoots(query.traversal.roots),
              query.traversal.pathRules.isEmpty,
              !query.traversal.excludedPaths.contains(where: { path in query.traversal.roots.contains {
                  path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") || $0.hasPrefix(path == "/" ? "/" : path + "/")
              } }),
              query.contents != nil,
              !(query.options.collectStatistics && query.output == .paths),
              query.extraction == nil, !query.options.useContentIndex, query.options.typoTolerance == 0 else { return nil }
        let boolean = nativeBooleanPattern(query)
        let pattern: String
        let literal: Bool
        if let boolean { pattern = boolean; literal = false }
        else {
            guard let leaf = query.contents?.single, query.unit == .line || (query.unit == .file && isOrdinaryText(leaf)) else { return nil }
            switch leaf {
            case .literal(let x): pattern = x; literal = true
            case .regex(let x): pattern = x; literal = false
            case .allLines: pattern = ""; literal = true
            default: return nil
            }
        }
        var args = ["--no-config"]
        if !query.files.isTrue {
            guard let patterns = fileTypeGlobs(query) else { return nil }
            for pattern in patterns { args += ["--type-add", "findui:" + pattern] }
            args += ["--type", "findui"]
        }
        if query.output == .paths { args += ["--files-with-matches", "--null"] }
        else { args += ["--json", "--line-number"] }
        args.append(query.options.contentCaseSensitive || boolean != nil ? "--case-sensitive" : "--ignore-case")
        if boolean != nil { args += ["--pcre2", "--no-unicode"] }
        if literal { args.append("--fixed-strings") }
        if query.options.multiline { args.append("--multiline") }
        if query.options.wholeWords && !pattern.isEmpty { args.append("--word-regexp") }
        if let encoding = query.options.encoding { args += ["--encoding", encoding] }
        if query.options.workers > 0 { args += ["--threads", String(query.options.workers)] }
        if query.traversal.hidden { args.append("--hidden") }
        // Type and ignore-file whitelists override rg's implicit hidden filter.
        // This explicit exclusion keeps the user's traversal policy invariant.
        else { args += ["--glob", "!.*"] }
        if query.traversal.ignore == .none { args.append("--no-ignore") }
        if query.traversal.follow { args.append("--follow") }
        if let depth = query.traversal.maximumDepth { args += ["--max-depth", String(depth)] }
        for folder in query.traversal.excludedFolders { args += ["--glob", "!**/" + escapeGlob(folder) + "/**"] }
        if query.options.collectStatistics { args.append("--stats") }
        args += ["--", pattern] + query.traversal.roots
        return Invocation(rg, args, emptyExitCodes: [1])
    }

    public func workerRequest(_ query: SearchQuery) throws -> WorkerRequest {
        if query.expression != nil { return try mixedWorkerRequest(query) }
        var result = WorkerRequest()
        result.action = query.action; result.unit = query.unit; result.output = query.output
        result.budget = ResourceBudget(workers: query.options.workers)
        switch query.source.kind {
        case .live: result.source.kind = .live; result.traversal = WalkConfiguration(query)
        case .manifest: result.source.kind = .manifest; result.source.path = query.source.path; result.traversal = WalkConfiguration(query)
        case .snapshot: result.source.kind = query.source.records ? .records : .snapshot; result.source.path = query.source.path
        case .spotlight: result.source.kind = .stdin
        }
        result.source.generation = query.source.generation
        let (expression, leaves) = query.files.indexed()
        var config = pathBase(query)
        config.tree = expression
        config.leaves = try leaves.map { try pathLeaf($0, query: query) }
        let fuzzies = try leaves.enumerated().compactMap { index, leaf -> FuzzyConfiguration? in
            guard let fuzzy = leaf.fuzzy else { return nil }
            return FuzzyConfiguration(leaf: index, invocation: try fuzzyCommand(fuzzy, query: query, sorted: true),
                relativeRoots: fuzzy.field == .relative ? query.traversal.roots : nil)
        }
        if fuzzies.isEmpty {
            if !(query.source.kind == .live && query.action == .search && query.files.isTrue) { result.paths = config }
        }
        else { result.selection = FileSelectionConfiguration(predicates: config, fuzzies: fuzzies) }
        if let tree = query.contents, !tree.leaves.allSatisfy(\.isSpotlight) {
            let (expression, leaves) = tree.indexed()
            var content = ContentConfiguration()
            content.tree = expression; content.positive = expression.positive
            content.leaves = try leaves.map { leaf in
                var value = ContentLeaf()
                switch leaf {
                case .allLines: break
                case .literal(let text): value.pattern = text
                case .regex(let text): value.pattern = text; value.regex = true
                case .proximity(let near): value.terms = near.terms; value.distance = near.distance; value.ordered = near.ordered
                case .metadata(let metadata): value.field = metadata.field; value.pattern = metadata.text
                case .spotlight: throw PlanningError.invalid("Spotlight text cannot be mixed with live text conditions.")
                }
                return value
            }
            let options = query.options
            content.caseSensitive = options.contentCaseSensitive; content.wholeWords = options.wholeWords
            content.filesOnly = query.output == .paths; content.fileUnit = query.unit != .line; content.documentUnit = query.unit == .document
            content.threads = options.workers; content.stats = options.collectStatistics; content.ordered = query.isRanked
            content.extraction = query.extraction; content.useIndex = options.useContentIndex
            content.encoding = options.encoding; content.typoTolerance = options.typoTolerance
            content.multiline = options.multiline; content.wordLanguage = options.wordLanguage
            content.stemWords = options.stemWords; content.indexOnly = query.action == .prepareSignatures
            if options.useContentIndex || query.action != .search { content.indexDirectory = options.cacheDirectory }
            content.archiveNamesOnly = query.extraction?.archives != true && !leaves.isEmpty && leaves.allSatisfy {
                if case .metadata(let value) = $0 { value.field == "member" } else { false }
            }
            for leaf in leaves {
                if case .metadata(let field) = leaf {
                    let supported = field.field == "member" ? (content.archiveNamesOnly || query.extraction?.archives == true) : query.extraction?.documents == true
                    guard supported else { throw PlanningError.invalid("Enable document or archive search for this metadata condition.") }
                }
            }
            if query.action == .wordSearch || query.action == .prepareWords {
                content.wordRoots = query.traversal.roots; content.wordScope = WordScope(query)
            }
            result.content = content
        }
        return result
    }

    private func mixedWorkerRequest(_ query: SearchQuery) throws -> WorkerRequest {
        guard let tree = query.expression else { return try workerRequest(query) }
        guard query.action == .search || query.action == .wordSearch else {
            throw PlanningError.invalid("Prepare indexes using the candidate file conditions, then search their contents.")
        }
        let (expression, leaves) = tree.indexed()
        var simple = query
        simple.expression = nil; simple.files = .all([])
        let ordinary = leaves.compactMap(\.content).filter { !$0.isSpotlight }
        simple.contents = ordinary.isEmpty ? .leaf(.allLines) : .any(ordinary.map(QueryTree.leaf))
        simple.options.filesOnly = true
        var request = try workerRequest(simple)
        var content = request.content!
        content.tree = expression
        var paths = pathBase(query); paths.leaves = []
        var external: [FuzzyConfiguration] = []
        var contentIndex = 0
        let textLeaves = content.leaves
        content.leaves = try leaves.map { predicate in
            if case .content(let leaf) = predicate, !leaf.isSpotlight {
                defer { contentIndex += 1 }; return textLeaves[contentIndex]
            }
            var value = ContentLeaf()
            let index = paths.leaves!.count; value.fileIndex = index
            switch predicate {
            case .file(let file):
                paths.leaves!.append(try pathLeaf(file, query: query))
                if let fuzzy = file.fuzzy {
                    external.append(.init(leaf: index, invocation: try fuzzyCommand(fuzzy, query: query, sorted: true),
                        relativeRoots: fuzzy.field == .relative ? query.traversal.roots : nil))
                }
            case .content(let text):
                guard let mdfind = tools.mdfind else { throw PlanningError.missingTool("mdfind") }
                paths.leaves!.append(pathBase(query))
                external.append(.init(leaf: index, invocation: Invocation(mdfind, ["-0",
                    try spotlightContent(.leaf(text), caseSensitive: query.options.contentCaseSensitive)])))
            }
            return value
        }
        func possible(_ node: PredicateExpression) -> (PredicateExpression, PredicateExpression) {
            switch node {
            case .leaf(let i):
                if let file = content.leaves[i].fileIndex { return (.none([.leaf(file)]), .leaf(file)) }
                return (.all([]), .all([]))
            case .all(let children):
                let pairs = children.map(possible); return (.any(pairs.map(\.0)), .all(pairs.map(\.1)))
            case .any(let children):
                let pairs = children.map(possible); return (.all(pairs.map(\.0)), .any(pairs.map(\.1)))
            case .none(let children):
                let pairs = children.map(possible); return (.any(pairs.map(\.1)), .all(pairs.map(\.0)))
            }
        }
        paths.tree = possible(expression).1
        content.filePredicates = paths
        content.ordered = query.isRanked
        content.positive = expression.positive.filter { content.leaves[$0].fileIndex == nil }
        if !external.isEmpty || paths.leaves!.contains(where: { $0.metadataDate != nil }) {
            var selection = FileSelectionConfiguration(predicates: paths, fuzzies: external)
            selection.masks = true; request.paths = nil; request.selection = selection
        }
        if query.source.kind == .spotlight {
            guard let mdfind = tools.mdfind else { throw PlanningError.missingTool("mdfind") }
            request.spotlight = SpotlightConfiguration(executable: mdfind, roots: query.traversal.roots,
                predicate: try spotlightContent(nil, caseSensitive: query.options.contentCaseSensitive))
            if request.selection == nil { request.paths = pathBase(query) }
        }
        request.content = content; request.output = .paths
        return request
    }

    private func pathBase(_ query: SearchQuery) -> PathsConfiguration {
        var value = PathsConfiguration()
        value.roots = query.traversal.roots; value.follow = query.traversal.follow
        value.snapshot = query.source.kind == .snapshot
        value.type = query.traversal.kind == .both ? "both" : query.traversal.kind == .directory ? "d" : "f"
        value.caseSensitive = query.options.fileCaseSensitive
        value.hidden = query.traversal.hidden
        value.packages = query.traversal.packages; value.packageExtensions = query.traversal.packageExtensions
        value.minimumDepth = query.traversal.minimumDepth; value.maximumDepth = query.traversal.maximumDepth
        value.excludedFolders = query.traversal.excludedFolders
        return value
    }
    private func pathLeaf(_ leaf: FilePredicate, query: SearchQuery) throws -> PathsConfiguration {
        var value = pathBase(query)
        switch leaf {
        case .text(let match):
            if match.kind != .fuzzy {
                let regex = match.kind != .literal || needsCanonicalFilenamePattern(match.text)
                value.conditions = [.init(field: match.field == .relative ? "path" : match.field.rawValue,
                    value: regex ? regexPattern(match) : match.text, regex: regex)]
            }
        case .size(let bounds): value.minimum = bounds.minimum; value.maximum = bounds.maximum
        case .extensions(let values):
            value.conditions = [.init(field: "name", value: "\\.(?:" + values.map(escapeRegex).joined(separator: "|") + ")\\z", regex: true)]
        case .date(let bounds):
            switch bounds.field {
            case "modified": value.from = bounds.from; value.before = bounds.before
            case "created": value.bornFrom = bounds.from; value.bornBefore = bounds.before
            default: value.metadataDate = bounds
            }
        case .tags(let tags): value.tags = tags.values; value.tagMatch = tags.operation
        }
        return value
    }
    private func orderedFuzzyConjunction(_ query: SearchQuery) -> [PathMatch]? {
        guard query.traversal.ignore != .ripgrep, let conditions = query.files.conjunction else { return nil }
        let matches = conditions.compactMap(\.fuzzy)
        // Relative paths need a reversible projection before ranking. The
        // shared selector joins them back to their original absolute paths.
        guard !matches.contains(where: { $0.field == .relative }) else { return nil }
        if matches.contains(where: { $0.field != .name }) && query.traversal.roots.contains(where: { canonicalRoot($0) != $0 }) { return nil }
        return matches
    }
    private func fuzzyCommand(_ match: PathMatch, query: SearchQuery, sorted: Bool) throws -> Invocation {
        guard let fzf = tools.fzf else { throw PlanningError.missingTool("fzf") }
        var args = ["--read0", "--print0", "--no-extended"]
        if query.options.fuzzyNormalize != true { args.append("--literal") }
        args += ["--scheme=path", "--algo=v2",
                    query.options.fileCaseSensitive ? "+i" : "--ignore-case", "--filter", match.text]
        if match.field == .name { args += ["--delimiter", "/", "--nth", "-1"] }
        if !sorted { args.append("--no-sort") }
        var invocation = Invocation(fzf, args, emptyExitCodes: [1])
        invocation.environment["GOMAXPROCS"] = String(ResourceBudget(workers: query.options.workers).effectiveWorkers)
        invocation.unsetEnvironment = ["FZF_DEFAULT_OPTS", "FZF_DEFAULT_OPTS_FILE", "FZF_DEFAULT_COMMAND"]
        return invocation
    }
}

private func isOrdinaryText(_ value: ContentPredicate) -> Bool {
    switch value { case .literal, .regex, .allLines: true; default: false }
}
public func escapeRegex(_ text: String) -> String {
    text.reduce(into: "") { out, c in if "\\.^$|?*+()[]{}".contains(c) { out.append("\\") }; out.append(c) }
}
public func escapeGlob(_ text: String) -> String {
    text.reduce(into: "") { out, c in if "\\*?[]{}".contains(c) { out.append("\\") }; out.append(c) }
}
public func globRegex(_ text: String) -> String {
    var result = "\\A", i = 0
    let chars = Array(text)
    while i < chars.count {
        if chars[i] == "*" {
            if i + 1 < chars.count && chars[i + 1] == "*" {
                i += 1
                if i + 1 < chars.count && chars[i + 1] == "/" { result += "(?:.*/)?"; i += 1 }
                else { result += ".*" }
            } else { result += "[^/]*" }
        } else if chars[i] == "?" { result += "[^/]" }
        else { result += escapeRegex(String(chars[i])) }
        i += 1
    }
    return result + "\\z"
}
private func regexPattern(_ match: PathMatch) -> String {
    switch match.kind {
    case .literal: filenameLiteralRegex(match.text)
    case .exact: "\\A" + filenameLiteralRegex(match.text) + "\\z"
    case .glob: globRegex(match.text)
    case .regex, .fuzzy: match.text
    }
}
private func portableRegex(_ text: String) -> Bool {
    !["(?=", "(?!", "(?<", "(?>", "(?(", "(?R", "\\K", "\\g", "\\k"].contains(where: text.contains)
        && !(1...9).contains { text.contains("\\\($0)") }
}
private func spotlightContent(_ tree: QueryTree<ContentPredicate>?, caseSensitive: Bool) throws -> String {
    guard let tree, tree.leaves.allSatisfy(\.isSpotlight) else { return "kMDItemFSName == '*'" }
    func render(_ node: QueryTree<ContentPredicate>) throws -> String {
        switch node {
        case .leaf(.spotlight(let text)):
            guard !text.contains(where: { "*?".contains($0) }) else { throw PlanningError.invalid("Spotlight cannot match literal * or ? in document text.") }
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "kMDItemTextContent == \"*\(escaped)*\"\(caseSensitive ? "" : "c")"
        case .leaf: throw PlanningError.invalid("Invalid Spotlight content condition.")
        case .all(let xs): return "(" + (try xs.map(render)).joined(separator: " && ") + ")"
        case .any(let xs): return "(" + (try xs.map(render)).joined(separator: " || ") + ")"
        case .none(let xs): return "!(" + (try xs.map(render)).joined(separator: " || ") + ")"
        }
    }
    return "kMDItemFSName == '*' && (" + (try render(tree)) + ")"
}
