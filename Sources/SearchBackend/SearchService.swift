import Foundation

package struct SearchService: Sendable {
    package let tools: Toolchain
    private let commandBuilder: SearchCommandBuilder

    package init(tools: Toolchain = .resolve()) {
        self.tools = tools
        self.commandBuilder = SearchCommandBuilder(tools: tools)
    }

    package func commandPreview(for request: SearchRequest) -> String {
        (try? commandBuilder.preparedCommand(for: request).preview) ?? ""
    }

    package func shellCommand(for request: SearchRequest) -> String? {
        try? commandBuilder.preparedCommand(for: request).preview
    }

    package func directoryListingCommandPreview(scope: URL, includeHidden: Bool) -> String {
        (try? commandBuilder.preparedDirectoryListingCommand(scope: scope, includeHidden: includeHidden).preview) ?? ""
    }

    package func search(request: SearchRequest) async throws -> SearchResponse {
        let collector = SearchResultCollector()
        let summary = try await streamSearch(request: request) { await collector.append($0) }
        return await SearchResponse(
            results: collector.results, commandPreview: summary.commandPreview,
            engineName: summary.engineName, isTruncated: summary.isTruncated, warning: summary.warning,
            commandOutput: summary.commandOutput)
    }

    package func streamSearch(
        request: SearchRequest,
        pipeline suppliedPipeline: SearchPipeline? = nil,
        onPrepared: @Sendable (SearchPipeline) async -> Void = { _ in },
        onOutput: @Sendable @escaping (CommandTextOutput) async -> Void = { _ in },
        onChunk: @Sendable @escaping ([SearchResult]) async throws -> Void
    ) async throws -> SearchExecutionSummary {
        let pipeline = try suppliedPipeline ?? SearchPipelineCompiler(tools: tools).compile(request)
        let prepared = PreparedCommand(spec: pipeline.spec, engineName: pipeline.engineName, preview: pipeline.script)
        // Reuse is scoped to a single plan. Live searches always enumerate the
        // current scope; a time-based candidate cache cannot prove freshness.
        let spec = pipeline.spec
        await onPrepared(pipeline)
        if pipeline.plan.output == .text {
            return try await streamCommandOutput(pipeline, onOutput: onOutput)
        }
        let accumulator = SearchStreamAccumulator(limit: request.maxResults)
        let metadataCache = SearchMetadataCache()
        let execution: ProcessExecution
        do {
            execution = try await withThrowingTaskGroup(of: ProcessExecution?.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
                        let batch = await accumulator.flush()
                        if !batch.isEmpty { try await onChunk(batch) }
                    }
                    return nil
                }
                group.addTask {
                    return try await ProcessRunner.stream(
                        spec: spec, pathOverride: tools.searchPath, separator: pipeline.outputIsJSON ? 10 : 0
                    ) { line in
                        try Task.checkCancellation()
                        let sourceOrder = await accumulator.nextSourceOrder()
                        let result: SearchResult?
                        if pipeline.outputIsJSON {
                            result = parseRipgrepJSONLine(
                                line, request: request, sourceOrder: sourceOrder, pipelineOutput: true,
                                metadataCache: metadataCache)
                        } else {
                            result = presentedPath(line, request: request, sourceOrder: sourceOrder)
                        }
                        try Task.checkCancellation()
                        guard let result else {
                            if pipeline.outputIsJSON {
                                guard let data = line.data(using: .utf8),
                                    let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                    let kind = event["type"] as? String, ["begin", "end", "summary"].contains(kind)
                                else {
                                    throw SearchServiceError.commandFailed(
                                        "The search tool returned an invalid match record.")
                                }
                            } else if !line.isEmpty {
                                throw SearchServiceError.commandFailed(
                                    "The search tool returned an invalid path record.")
                            }
                            return true
                        }
                        let update = await accumulator.append(result)
                        if !update.batch.isEmpty { try await onChunk(update.batch) }
                        return update.shouldContinue
                    }
                }
                defer { group.cancelAll() }
                while let value = try await group.next() {
                    if let execution = value { return execution }
                }
                throw CancellationError()
            }
        } catch {
            let pending = await accumulator.finish()
            if !pending.isEmpty { try await onChunk(pending) }
            throw error
        }
        let pending = await accumulator.finish()
        if !pending.isEmpty { try await onChunk(pending) }

        let diagnostics = SearchDiagnostics(execution.stderr)
        let stderr = diagnostics.warnings
        if let error = diagnostics.protocolError { throw SearchServiceError.commandFailed(error) }
        if !execution.stoppedEarly && pipeline.requiresCompletion && diagnostics.completion == nil {
            throw SearchServiceError.commandFailed("The search worker ended without a completion record. " + stderr)
        }
        if !execution.stoppedEarly, let status = diagnostics.completion?.status,
            status == .failed || status == .cancelled
        {
            throw SearchServiceError.commandFailed(diagnostics.completion?.message ?? "Search did not complete.")
        }
        if !execution.stoppedEarly && execution.exitCode != 0 && !pipeline.emptyExitCodes.contains(execution.exitCode)
            && diagnostics.completion?.status != .partial
        {
            throw SearchServiceError.commandFailed(
                stderr.isEmpty ? "Search command failed (exit \(execution.exitCode))." : stderr)
        }
        let warnings = [
            stderr.isEmpty ? nil : stderr,
            prepared.engineName.hasPrefix("find") && !request.traversal.includeIgnored
                ? SearchTraversalOptions.findWarning : nil,
            request.refinements.source == .spotlight
                ? "Spotlight coverage may be incomplete or stale; ignore files do not apply." : nil,
        ]
        .compactMap { $0 }.joined(separator: " ")
        return await SearchExecutionSummary(
            commandPreview: prepared.preview, engineName: prepared.engineName,
            isTruncated: accumulator.isTruncated, warning: warnings.isEmpty ? nil : warnings,
            wordStatus: diagnostics.wordStatus)
    }

    private func streamCommandOutput(
        _ pipeline: SearchPipeline,
        onOutput: @Sendable @escaping (CommandTextOutput) async -> Void
    ) async throws -> SearchExecutionSummary {
        let accumulator = CommandTextAccumulator()
        await onOutput(CommandTextOutput())
        let execution: ProcessExecution
        do {
            execution = try await withThrowingTaskGroup(of: ProcessExecution?.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
                        if let output = await accumulator.flush() { await onOutput(output) }
                    }
                    return nil
                }
                group.addTask {
                    try await ProcessRunner.streamBytes(spec: pipeline.spec, pathOverride: tools.searchPath) { bytes in
                        if let output = await accumulator.append(bytes) { await onOutput(output) }
                    }
                }
                defer { group.cancelAll() }
                while let execution = try await group.next() {
                    if let execution { return execution }
                }
                throw CancellationError()
            }
        } catch {
            await onOutput(accumulator.snapshot())
            throw error
        }
        let output = await accumulator.snapshot()
        await onOutput(output)
        // Text-mode stderr belongs to the invoked tool, not FindUI's worker
        // protocol. Preserve its diagnostics even if they resemble that protocol.
        guard execution.exitCode == 0 || pipeline.emptyExitCodes.contains(execution.exitCode) else {
            throw SearchServiceError.commandFailed(execution.stderr.isEmpty
                ? "Command failed (exit \(execution.exitCode))."
                : "Command failed (exit \(execution.exitCode)).\n\(execution.stderr)")
        }
        return SearchExecutionSummary(commandPreview: pipeline.script, engineName: pipeline.engineName,
            warning: execution.stderr.isEmpty ? nil : execution.stderr, commandOutput: output)
    }

    package func streamDirectoryListing(
        scope: URL,
        includeHidden: Bool,
        maxResults: Int = .max,
        onChunk: @Sendable @escaping ([SearchResult]) async -> Void
    ) async throws -> SearchExecutionSummary {
        var request = SearchRequest(
            query: "", mode: .everything, scope: scope, includeHidden: includeHidden,
            caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: maxResults)
        request.isDirectoryListing = true
        return try await PreparedSearch(request: request, tools: tools).stream(tools: tools, onChunk: onChunk)
    }

    package func parseNameSearchOutput(_ output: String, request: SearchRequest, matcher: NameQueryMatcher? = nil)
        -> [SearchResult]
    {
        output.split(separator: output.contains("\0") ? "\0" : "\n").enumerated().compactMap {
            parseNameSearchLine(String($0.element), request: request, sourceOrder: $0.offset, matcher: matcher)
        }
    }

    package func parseRipgrepJSON(_ output: String, request: SearchRequest, matcher: SearchQueryMatcher? = nil)
        -> [SearchResult]
    {
        output.split(separator: "\n").enumerated().compactMap {
            parseRipgrepJSONLine(String($0.element), request: request, sourceOrder: $0.offset, matcher: matcher)
        }
    }

    package func parseNameSearchLine(
        _ path: String, request: SearchRequest, sourceOrder: Int,
        matcher: NameQueryMatcher? = nil, filters: ValidatedSearchFilters? = nil
    ) -> SearchResult? {
        guard !path.isEmpty else { return nil }
        let url = normalizeURL(path, relativeTo: request.scope)
        guard SearchPath.contains(url, in: request.scope) else { return nil }
        guard !request.traversal.excludes(url, in: request.scope, isDirectory: request.mode == .folders) else {
            return nil
        }
        guard
            let matcher = matcher
                ?? (try? NameQueryMatcher(
                    query: request.query, syntax: request.syntax,
                    caseSensitive: request.caseSensitive, exactNameMatch: request.exactNameMatch)),
            let rank = matcher.rank(
                name: url.lastPathComponent, path: url.path,
                relativePath: SearchPath.relativePath(of: url, in: request.scope), fileExtension: url.pathExtension)
        else { return nil }
        let metadata = loadMetadata(for: url, includeLastOpened: request.refinements.source == .spotlight)
        let kind: SearchResultKind = request.mode == .folders ? .folder : .file
        guard let filters = filters ?? (try? request.filters.validated()),
            filters.matches(
                size: kind == .folder ? nil : metadata.size,
                modifiedAt: metadata.modifiedAt, createdAt: metadata.createdAt, lastOpenedAt: metadata.lastOpenedAt)
        else { return nil }
        return SearchResult(
            url: url, kind: kind, typeDescription: metadata.typeDescription,
            modifiedAt: metadata.modifiedAt, createdAt: metadata.createdAt, addedAt: metadata.addedAt,
            lastOpenedAt: metadata.lastOpenedAt, size: kind == .folder ? nil : metadata.size,
            matchRank: rank, sourceOrder: sourceOrder)
    }

    package func parseRipgrepJSONLine(
        _ line: String, request: SearchRequest, sourceOrder: Int,
        matcher: SearchQueryMatcher? = nil, filters: ValidatedSearchFilters? = nil,
        pipelineOutput: Bool = false, metadataCache: SearchMetadataCache? = nil
    ) -> SearchResult? {
        guard let record = try? JSONDecoder().decode(SearchMatchRecord.self, from: Data(line.utf8)),
            record.type == "match", let path = record.data.path.path
        else { return nil }
        let payload = record.data
        if let file = payload.file {
            return SearchResult(
                url: normalizeURL(path, relativeTo: request.scope, isDirectory: file.directory), kind: file.directory ? .folder : .file,
                modifiedAt: file.modified.map(Date.init(timeIntervalSince1970:)),
                createdAt: file.created.map(Date.init(timeIntervalSince1970:)),
                size: file.directory ? nil : file.size, tags: file.tags,
                matchRank: sourceOrder, sourceOrder: sourceOrder)
        }
        guard let snippetBytes = payload.lines?.decodedBytes else { return nil }
        // rg searches arbitrary non-NUL bytes. An undecodable display snippet
        // must never discard a match already selected by the backend.
        let rawSnippet = String(decoding: snippetBytes, as: UTF8.self)
        let url = normalizeURL(path, relativeTo: request.scope, isDirectory: false)
        if !pipelineOutput {
            guard request.scopes.contains(where: { SearchPath.contains(url, in: $0) }),
                !request.traversal.excludes(url, in: request.scope, isDirectory: false)
            else { return nil }
        }
        let snippet = rawSnippet.trimmingCharacters(in: .newlines)
        let relativePath = SearchPath.relativePath(of: url, in: request.scope)
        if !pipelineOutput, let matcher,
            !matcher.matchesContentCandidate(
                name: url.lastPathComponent, path: url.path,
                relativePath: relativePath, fileExtension: url.pathExtension, snippet: snippet)
        {
            return nil
        }
        let ranges: [Range<Int>]
        if !pipelineOutput && request.syntax == .literal && request.state.ruleSet == nil
            && request.refinements.wordSearch != true && (request.refinements.typoTolerance ?? 0) == 0
        {
            ranges = ContentMatchRanges.literal(in: snippet, query: request.query, caseSensitive: request.caseSensitive)
        } else {
            ranges = ContentMatchRanges.utf16Ranges(
                bytes: snippetBytes, offsets: payload.offsets,
                trimmingNewlines: true, decoded: rawSnippet)
        }
        var metadata =
            metadataCache?.value(for: url.path) {
                loadMetadata(
                    for: url, includeLastOpened: request.refinements.source == .spotlight,
                    includeTags: request.needsFinderTags && payload.tags == nil,
                    follow: request.traversal.followSymlinks)
            }
            ?? loadMetadata(
                for: url, includeLastOpened: request.refinements.source == .spotlight,
                includeTags: request.needsFinderTags && payload.tags == nil,
                follow: request.traversal.followSymlinks)
        if let tags = payload.tags { metadata.tags = tags }
        if !pipelineOutput {
            guard let filters = filters ?? (try? request.filters.validated()),
                filters.matches(
                    size: metadata.size, modifiedAt: metadata.modifiedAt, createdAt: metadata.createdAt,
                    lastOpenedAt: metadata.lastOpenedAt)
            else { return nil }
        }
        return SearchResult(
            url: url, kind: .contentMatch, lineNumber: payload.line, extractedOrigin: payload.origin,
            snippet: snippet, snippetMatchRanges: ranges, typeDescription: metadata.typeDescription,
            modifiedAt: metadata.modifiedAt, createdAt: metadata.createdAt, addedAt: metadata.addedAt,
            lastOpenedAt: metadata.lastOpenedAt, size: metadata.size, tags: metadata.tags,
            matchRank: pipelineOutput ? sourceOrder : 0, sourceOrder: sourceOrder)
    }

    /// Decode a path already selected by the exported pipeline. No predicates here.
    package func presentedPath(_ path: String, request: SearchRequest, sourceOrder: Int) -> SearchResult? {
        guard !path.isEmpty else { return nil }
        let url = normalizeURL(path, relativeTo: request.scope)
        let folder =
            request.useIndex
            ? request.mode == .folders
            : ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? (request.mode == .folders))
        let metadata: SearchMetadata =
            request.useIndex
            ? (nil, nil, nil, nil, nil, nil, nil)
            : loadMetadata(
                for: url, includeLastOpened: request.refinements.source == .spotlight,
                includeTags: request.needsFinderTags, follow: request.traversal.followSymlinks)
        return SearchResult(
            url: url, kind: folder ? .folder : .file, typeDescription: metadata.typeDescription,
            modifiedAt: metadata.modifiedAt, createdAt: metadata.createdAt, addedAt: metadata.addedAt,
            lastOpenedAt: metadata.lastOpenedAt, size: folder ? nil : metadata.size, tags: metadata.tags,
            matchRank: sourceOrder, sourceOrder: sourceOrder)
    }

    private func loadMetadata(
        for url: URL, includeLastOpened: Bool = false, includeTags: Bool = false, follow: Bool = false
    ) -> SearchMetadata {
        let keys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
            .addedToDirectoryDateKey, .contentAccessDateKey, .fileSizeKey, .isDirectoryKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return (
            values?.localizedTypeDescription, values?.contentModificationDate, values?.creationDate,
            values?.addedToDirectoryDate, includeLastOpened ? FileMetadata.lastOpened(url) : nil,
            values?.fileSize.map(Int64.init),
            includeTags ? FileMetadata.finderTags(url, followSymlinks: follow) : nil
        )
    }

    private func normalizeURL(_ path: String, relativeTo scope: URL, isDirectory: Bool? = nil) -> URL {
        var value = path
        // Native command searches preserve their working directory and can
        // emit ./name or . for the root. Remove only redundant leading dots;
        // resolving symlinks or interior .. would change the requested path.
        if value.hasPrefix("./") {
            var suffix = value[...]
            repeat { suffix = suffix.dropFirst(2) } while suffix.hasPrefix("./")
            value = String(suffix)
        }
        if value == "." || value.isEmpty { return scope }
        // JSON result records already identify the kind. Inferring it again
        // probes the filesystem for every matching line, even with cached metadata.
        if let isDirectory {
            return value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: isDirectory)
                : scope.appendingPathComponent(value, isDirectory: isDirectory)
        }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : scope.appendingPathComponent(value)
    }
}

package typealias SearchMetadata = (
    typeDescription: String?, modifiedAt: Date?, createdAt: Date?,
    addedAt: Date?, lastOpenedAt: Date?, size: Int64?, tags: [String]?
)

extension SearchRequest {
    package var needsFinderTags: Bool {
        refinements.finderTags?.isEmpty == false
            || state.ruleSet?.fileLeaves.contains { if case .tags = $0 { true } else { false } } == true
    }
}

/// Scoped to one execution: repeated matches share a single metadata lookup,
/// and a later search cannot inherit stale metadata. Access is synchronized.
package final class SearchMetadataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SearchMetadata] = [:]
    private var keys: [String] = []
    private var oldest = 0
    package func value(for path: String, load: () -> SearchMetadata) -> SearchMetadata {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[path] { return value }
        let value = load()
        if keys.count == 4_096 {
            values.removeValue(forKey: keys[oldest])
            keys[oldest] = path
            oldest = (oldest + 1) % keys.count
        } else {
            keys.append(path)
        }
        values[path] = value
        return value
    }
}

package actor SearchResultCollector {
    package init() {}
    package private(set) var results: [SearchResult] = []
    package func append(_ chunk: [SearchResult]) { results.append(contentsOf: chunk) }
}

private actor SearchStreamAccumulator {
    private var pending: [SearchResult] = []
    private var sourceOrder = 0
    private var count = 0
    private let limit: Int
    private var overflowed = false
    private var ranked: RankedSearchResults?
    var isTruncated: Bool { ranked?.isTruncated ?? overflowed }

    init(limit: Int, ranked: Bool = false) {
        self.limit = max(0, limit)
        self.ranked = ranked && limit != .max ? RankedSearchResults(limit: limit) : nil
    }

    func nextSourceOrder() -> Int {
        defer { sourceOrder += 1 }
        return sourceOrder
    }

    func append(_ result: SearchResult) -> (batch: [SearchResult], shouldContinue: Bool) {
        if ranked != nil {
            ranked?.append(result)
            return ([], true)
        }
        guard count < limit else {
            overflowed = true
            return (flush(), false)
        }
        count += 1
        pending.append(result)
        // Publish the first hit immediately, then batch updates for large searches.
        return (count == 1 || pending.count >= 512 ? flush() : [], true)
    }

    func flush() -> [SearchResult] {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        return batch
    }

    func finish() -> [SearchResult] { ranked?.results ?? flush() }
}
