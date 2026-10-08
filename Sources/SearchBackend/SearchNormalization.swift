import Foundation
import SearchCore

extension SearchRequest {
    /// Browsing is the ordinary one-level, unfiltered filename search. Lower
    /// the action into visible controls once, so exports cannot hide a browse
    /// override behind a query that the user sees and edits.
    package func resolvingBrowseAction() -> SearchRequest {
        guard isDirectoryListing, state.nativeCommand == nil else { return self }
        var result = self
        var traversal = traversal
        traversal.minimumDepth = 1; traversal.maximumDepth = 1
        traversal.includeIgnored = true; traversal.excludedFolders = [".git"]; traversal.pathRules = nil
        result.state = SearchState(query: "", mode: .everything, scopePath: state.scopePath,
            useIndex: useIndex, includeHidden: includeHidden, caseSensitive: false, syntax: .literal,
            exactNameMatch: false, selectedDrivePath: selectedDrivePath, indexedFilter: .everything,
            traversal: traversal, refinements: .init(additionalScopes: refinements.additionalScopes, workers: refinements.workers))
        result.state.resultScope = state.resultScope
        result.isDirectoryListing = false; result.includeMetadata = false
        result.buildContentIndex = false; result.buildWordIndex = false; result.excludesDerivedContent = false
        return result
    }

    /// The only adapter from persisted controls into executable search meaning.
    /// Compact and grouped controls converge before any backend is considered.
    package func normalizedQuery(source override: QuerySource? = nil) throws -> SearchQuery {
        if isDirectoryListing, state.nativeCommand == nil { return try resolvingBrowseAction().normalizedQuery(source: override) }
        try state.validateExpressions()
        try state.validateSourceRequirements()
        try traversal.validate(allowRoot: state.resultScope != nil)
        if searchesDocumentText && (syntax != .literal || refinements.wholeWords) {
            throw SearchServiceError.commandFailed("Spotlight document text supports literal phrases. Regex and whole-word matching require live text search.")
        }
        guard !useIndex || override?.kind == .snapshot else {
            throw SearchServiceError.commandFailed("A saved snapshot search needs --snapshot /path/to/index.sqlite.")
        }
        var normalized = state
        try normalized.promoteToRules(now: referenceDate)
        guard let rules = normalized.ruleSet else { throw SearchServiceError.invalidQuery }
        try rules.validate(now: referenceDate)
        var query = SearchQuery()
        if let override { query.source = override }
        else if let scope = state.resultScope {
            _ = try scope.source()
            guard refinements.source == .filesystem else { throw SearchServiceError.invalidQuery }
            query.source.kind = .manifest; query.source.path = scope.path
        } else { query.source.kind = refinements.source == .spotlight ? .spotlight : .live }
        query.traversal.roots = scopes.map(\.path)
        query.traversal.kind = mode == .folders ? .directory : mode == .everything ? .both : .file
        query.traversal.hidden = includeHidden
        query.traversal.ignore = traversal.includeIgnored ? .none : mode == .contents ? .ripgrep : .fd
        query.traversal.follow = traversal.followSymlinks
        query.traversal.minimumDepth = traversal.minimumDepth; query.traversal.maximumDepth = traversal.maximumDepth
        query.traversal.excludedFolders = traversal.normalized.excludedFolders
        query.traversal.packages = traversal.includePackageContents
        query.traversal.packageExtensions = SearchTraversalOptions.packageExtensions
        query.traversal.pathRules = traversal.pathRules ?? []; query.traversal.ruleRoot = scope.path
        if mode == .contents || excludesDerivedContent || buildWordIndex || buildContentIndex {
            let cache = SearchExtractionOptions.cacheDirectory
            query.traversal.excludedPaths = [cache.path] + ["lock", "init"].map {
                cache.deletingLastPathComponent().appendingPathComponent(".\(cache.lastPathComponent).findui-\($0)").path
            }
        }
        let expression = try rules.expression.queryTree.flatMap { condition -> QueryTree<SearchPredicate> in
            switch condition {
            case .file(let rule): return try normalizeFiles(.rule(rule)).map(SearchPredicate.file)
            case .content(let rule): return try normalizeContents(.rule(rule)).map(SearchPredicate.content)
            }
        }
        query.setExpression(expression)
        query.unit = rules.hasContents ? MatchUnit(rawValue: rules.contentUnit.rawValue)! : .line
        query.options.fileCaseSensitive = refinements.fileCaseSensitive ?? caseSensitive
        query.options.fuzzyNormalize = refinements.fuzzyNormalize
        query.options.contentCaseSensitive = caseSensitive
        query.options.wholeWords = refinements.wholeWords
        query.options.includeMetadata = includeMetadata && needsFinderTags && !useIndex
        query.options.filesOnly = refinements.matchingFilesOnly
        query.options.workers = refinements.workers ?? 0
        query.options.collectStatistics = collectStatistics
        // A prepared index is an explicit execution choice. Ordinary text
        // searches remain ordinary rg commands, without speculative cache I/O.
        query.options.useContentIndex = refinements.useContentIndex == true || buildContentIndex || buildWordIndex
        query.options.cacheDirectory = canonicalIdentityPath(SearchExtractionOptions.cacheDirectory.path)
        query.options.encoding = refinements.textEncoding
        query.options.typoTolerance = refinements.typoTolerance ?? 0
        query.options.stemWords = refinements.stemWords == true
        query.options.multiline = query.hasContents && refinements.multiline == true
        query.options.wordLanguage = refinements.wordLanguage
        if buildWordIndex { query.action = .prepareWords }
        else if buildContentIndex { query.action = .prepareSignatures }
        else if query.hasContents && refinements.wordSearch == true { query.action = .wordSearch }
        if query.hasContents, let extraction = refinements.extraction {
            try extraction.validate()
            var value = ExtractionConfiguration()
            value.documents = extraction.documents; value.archives = extraction.archives; value.media = extraction.media
            if extraction.customReaders {
                value.adapters = try ReaderConfiguration().load().filter(\.enabled)
                guard !value.adapters.isEmpty else {
                    throw SearchServiceError.commandFailed("Enable a custom reader in Settings, or turn off Use custom readers in Scope & Options.")
                }
            }
            value.useTika = extraction.useTika
            value.maxDepth = extraction.maximumArchiveDepth; value.maxMegabytes = extraction.maximumMegabytes
            value.timeoutSeconds = extraction.timeoutSeconds
            value.cacheDirectory = extraction.cacheText ? canonicalIdentityPath(SearchExtractionOptions.cacheDirectory.path) : nil
            query.extraction = value
        }
        return try query.validated()
    }

    private func normalizeFiles(_ tree: SearchRuleTree<SearchFileRule>) throws -> QueryTree<FilePredicate> {
        switch tree {
        case .all(let xs): return .all(try xs.map(normalizeFiles))
        case .any(let xs): return .any(try xs.map(normalizeFiles))
        case .none(let xs): return .none(try xs.map(normalizeFiles))
        case .rule(let rule):
            switch rule {
            case .name(let value, let matching): return .leaf(.text(.init(.name, normalizedMatching(matching), value)))
            case .path(let value, let matching, let absolute):
                let expanded = [.contains, .exact, .glob].contains(matching) ? SearchPath.expandPatternPrefix(value, relativeTo: scope) : nil
                return .leaf(.text(.init(expanded != nil || absolute ? .absolute : .relative, normalizedMatching(matching), expanded ?? value)))
            case .extensions(let values):
                return .leaf(.extensions(values))
            case .tags(let values, let operation): return .leaf(.tags(.init(values, TagOperation(rawValue: operation.rawValue)!)))
            case .size(let lower, let upper):
                var filters = SearchFilters(); filters.minimumSize = lower; filters.maximumSize = upper
                let limits = try filters.validated(now: referenceDate)
                return .leaf(.size(.init(minimum: limits.minimumSize.map(UInt64.init), maximum: limits.maximumSize.map(UInt64.init))))
            case .date(let value):
                let limits = try value.filters.validated(now: referenceDate)
                return .leaf(.date(.init(field: value.field.spotlightAttribute ?? value.field.rawValue,
                    from: limits.from?.timeIntervalSince1970, before: limits.before?.timeIntervalSince1970)))
            case .expression(let value):
                if value.syntax == .regex {
                    let pattern = value.exactName ? "\\A(?:" + value.text + ")\\z" : value.text
                    return .leaf(.text(.init(value.exactName ? .name : .any, .regex, pattern)))
                }
                let parsed = ParsedSearchQuery.parseLiteral(value.text)
                let parts: [QueryTree<FilePredicate>] = parsed.tokens.map { token in
                    let field: PathField = token.field == .name || token.field == .ext ? .name : token.field == .path ? .relative : .any
                    let match: PathMatch
                    if token.field == .ext {
                        match = .init(.name, .regex, "\\.(?:" + token.extensions.map(SearchCore.escapeRegex).joined(separator: "|") + ")\\z")
                    } else if value.exactName && parsed.canUseExactNameMatch {
                        match = .init(.name, .exact, token.value)
                    } else if value.syntax == .fuzzy && !token.isExcluded && token.globPattern == nil && token.field != .path {
                        match = .init(token.field == .name || !refinements.fuzzyFullPath ? .name : .absolute, .fuzzy, token.value)
                    } else if let glob = token.globPattern {
                        // A segment-only glob can match only the basename.
                        // Keep path globs and regexes on the full legacy field.
                        let basename = field == .any && !token.value.contains("/") && !token.value.contains("**")
                        match = .init(basename ? .name : field, .regex,
                            basename ? glob.replacingOccurrences(of: "[^/]", with: ".") : glob)
                    } else { match = .init(field, .literal, token.value) }
                    let leaf: QueryTree<FilePredicate> = .leaf(.text(match))
                    return token.isExcluded ? .none([leaf]) : leaf
                }
                return .all(parts)
            }
        }
    }
    private func normalizeContents(_ tree: SearchRuleTree<SearchContentRule>) throws -> QueryTree<ContentPredicate> {
        switch tree {
        case .all(let xs): return .all(try xs.map(normalizeContents))
        case .any(let xs): return .any(try xs.map(normalizeContents))
        case .none(let xs): return .none(try xs.map(normalizeContents))
        case .rule(let rule):
            switch rule {
            case .allLines: return .leaf(.allLines)
            case .literal(let value): return .leaf(.literal(value))
            case .regex(let value): return .leaf(.regex(value))
            case .documentText(let value): return .leaf(.spotlight(value))
            case .metadata(let field, let value): return .leaf(.metadata(.init(field: field.rawValue, text: value)))
            case .proximity(let near): return .leaf(.proximity(.init(terms: near.terms, distance: near.distance, ordered: near.ordered)))
            }
        }
    }
}
private func normalizedMatching(_ value: PatternMatching) -> PatternKind {
    switch value { case .contains: .literal; case .exact: .exact; case .glob: .glob; case .regex: .regex; case .fuzzy: .fuzzy }
}
extension Toolchain {
    package var capabilities: ToolCapabilities {
        var value = ToolCapabilities(); value.fd = fd?.path; value.rg = rg?.path
        value.fzf = fzf?.path; value.find = find?.path; value.mdfind = mdfind?.path; value.worker = contentWorker?.path
        let developmentRG = ExecutableLocation.developmentRoot?.appendingPathComponent(".build/search-tools/bin/rg")
        // Our pinned builds enable static PCRE2. Unknown external builds retain
        // the shared executor rather than assuming an optional rg feature.
        value.rgPCRE2 = rg != nil && (rg == developmentRG || rg?.deletingLastPathComponent() == contentWorker?.deletingLastPathComponent())
        return value
    }
    package func resolveReaders(in query: inout SearchQuery) {
        guard var extraction = query.extraction else { return }
        extraction.pandoc = pandoc?.path; extraction.pdftotext = pdftotext?.path; extraction.pdfdetach = pdfdetach?.path
        extraction.ffmpeg = ffmpeg?.path; extraction.ffprobe = ffprobe?.path
        extraction.tikaJar = extraction.documents && extraction.useTika ? tikaJar?.path : nil
        query.extraction = extraction
    }
}
