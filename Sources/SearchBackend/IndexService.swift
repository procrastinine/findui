import Foundation

package struct IndexBuildResult: Sendable {
    package let metadata: ManagedIndex
    package let entries: [IndexedEntry]
    package let commandPreview: String
    package var catalog: [String: IndexedEntry]? = nil
    package var delta: IndexDelta? = nil
    package init(metadata: ManagedIndex, entries: [IndexedEntry], commandPreview: String, catalog: [String: IndexedEntry]? = nil, delta: IndexDelta? = nil) {
        self.metadata = metadata
        self.entries = entries
        self.commandPreview = commandPreview
        self.catalog = catalog
        self.delta = delta
    }

}

package struct IndexService: Sendable {
    package let tools: Toolchain

    package init(tools: Toolchain = .resolve()) { self.tools = tools }

    package func buildIndex(id: UUID = UUID(), name: String, scope: URL, includeHidden: Bool,
                    traversal: SearchTraversalOptions = .init()) async throws -> IndexBuildResult {
        try traversal.validate()
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: scope.path, isDirectory: &directory), directory.boolValue else {
            throw SearchServiceError.commandFailed("Index directory is unavailable: \(scope.path)")
        }
        guard let executable = tools.contentWorker ?? tools.fd ?? tools.find else { throw SearchServiceError.missingTool("fd or find") }
        let engine = tools.contentWorker != nil ? "FindUI" : tools.fd == nil ? "find" : "fd"
        let spec = try indexSpec(executable: executable, engine: engine, scope: scope, includeHidden: includeHidden,
                                traversal: traversal)
        let output = try await ProcessRunner.run(spec: spec, pathOverride: tools.searchPath)
        if output.exitCode != 0 {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SearchServiceError.commandFailed(message.isEmpty ? "Index build failed (exit \(output.exitCode))." : message)
        }
        try Task.checkCancellation()
        let entries = try await parseIndexedPaths(output.stdout, scope: scope, followSymlinks: traversal.followSymlinks)
            .filter { !traversal.excludes(scope.appendingPathComponent($0.relativePath), in: scope, isDirectory: $0.kind == .folder) }
            .sorted { $0.relativePath < $1.relativePath }
        let messages = [output.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let warning = messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: "\n")
        let metadata = ManagedIndex(id: id, name: name, scopePath: scope.path, includeHidden: includeHidden,
            createdAt: .now, updatedAt: .now, fileCount: entries.filter { $0.kind == .file }.count,
            folderCount: entries.filter { $0.kind == .folder }.count, entryCount: entries.count,
            engineName: engine, warning: warning, traversal: traversal.effective(for: engine), lastOpenedUsesSpotlight: true,
            queryGeneration: UUID())
        return IndexBuildResult(metadata: metadata, entries: entries,
                                commandPreview: spec.shellString)
    }

    package func commandPreview(for index: ManagedIndex) -> String {
        "Index file: \(FindUIPaths.indexEntriesFileURL(for: index.id).path)"
    }

    package func search(request: SearchRequest, index: ManagedIndex, entries: [IndexedEntry]) async throws -> SearchResponse {
        let collector = SearchResultCollector()
        let summary = try await streamSearch(request: request, index: index, entries: entries) { await collector.append($0) }
        return await SearchResponse(results: collector.results, commandPreview: summary.commandPreview,
            engineName: summary.engineName, isTruncated: summary.isTruncated, warning: summary.warning)
    }

    package func streamSearch(request: SearchRequest, index: ManagedIndex, entries: [IndexedEntry],
                      onChunk: @Sendable @escaping ([SearchResult]) async -> Void) async throws -> SearchExecutionSummary {
    let frozen = try await SnapshotQueryCache.shared.prepare(index: index, entries: entries)
    let prepared = try PreparedSearch(request: request, index: index, snapshot: frozen, tools: tools,
        location: SnapshotLocations.shared.location(index) ?? FindUIPaths.indexEntriesFileURL(for: index.id))
    return try await prepared.stream(tools: tools, onChunk: onChunk)
}

package func streamDirectoryListing(scope: URL, index: ManagedIndex, entries: [IndexedEntry], includeHidden: Bool,
                            maxResults: Int = .max,
                            onChunk: @Sendable @escaping ([SearchResult]) async -> Void) async throws -> SearchExecutionSummary {
    var request = SearchRequest(query: "", mode: .everything, scope: scope, useIndex: true,
        includeHidden: includeHidden, caseSensitive: false, syntax: .literal, exactNameMatch: false,
        maxResults: maxResults, traversal: index.traversal ?? .init())
    request.isDirectoryListing = true
    return try await streamSearch(request: request, index: index, entries: entries, onChunk: onChunk)
}

    private func indexSpec(executable: URL, engine: String, scope: URL, includeHidden: Bool,
                           traversal: SearchTraversalOptions) throws -> CommandSpec {
        let request = SearchRequest(query: "", mode: .everything, scope: scope,
            includeHidden: includeHidden, caseSensitive: false, syntax: .literal, exactNameMatch: false,
            maxResults: .max, traversal: traversal)
        return SearchPipeline.command(SearchPipeline.preamble + (try SearchPipelineCompiler(tools: tools).enumerate(request)))
    }

    private func parseIndexedPaths(_ output: String, scope: URL, followSymlinks: Bool) async throws -> [IndexedEntry] {
        let paths = output.split(separator: "\0").map(String.init)
        return try await indexedEntries(paths, scope: scope, followSymlinks: followSymlinks)
    }

    /// Shared bounded metadata reader for full builds and incremental batches.
    package func indexedEntries(_ paths: [String], scope: URL, followSymlinks: Bool) async throws -> [IndexedEntry] {
        let workers = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
        return try await withThrowingTaskGroup(of: [IndexedEntry].self) { group in
            var next = 0
            func enqueue() {
                guard next < paths.count else { return }
                let batch = Array(paths[next..<min(paths.count, next + 128)]); next += batch.count
                group.addTask {
                    try batch.compactMap { path in
                        try Task.checkCancellation()
                        return indexedEntry(URL(fileURLWithPath: path), scope: scope, followSymlinks: followSymlinks)
                    }
                }
            }
            for _ in 0..<workers { enqueue() }
            var entries: [IndexedEntry] = []; entries.reserveCapacity(paths.count)
            while let batch = try await group.next() { entries += batch; enqueue() }
            return entries
        }
    }

    package func indexedEntry(_ url: URL, scope: URL, followSymlinks: Bool = false) -> IndexedEntry? {
            guard let relativePath = SearchPath.relativePath(of: url, in: scope), !relativePath.isEmpty else { return nil }
            let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
                                           .addedToDirectoryDateKey, .contentAccessDateKey, .fileSizeKey, .isDirectoryKey]
            let metadataURL = followSymlinks ? url.resolvingSymlinksInPath() : url
            guard let values = try? metadataURL.resourceValues(forKeys: keys) else { return nil }
            let kind: IndexedEntryKind = values.isDirectory == true ? .folder : .file
            return IndexedEntry(relativePath: relativePath, kind: kind, typeDescription: values.localizedTypeDescription,
                modifiedAt: values.contentModificationDate, createdAt: values.creationDate,
                addedAt: values.addedToDirectoryDate, lastOpenedAt: FileMetadata.lastOpened(url),
                size: kind == .folder ? nil : values.fileSize.map(Int64.init), tags: FileMetadata.finderTags(url, followSymlinks: followSymlinks))
    }

    package func coverageMatches(request: SearchRequest, index: ManagedIndex) -> Bool {
        let indexed = index.traversal ?? SearchTraversalOptions().effective(for: index.engineName)
        return indexed.normalized == request.traversal.effective(for: index.engineName)
            && (!request.includeHidden || index.includeHidden)
    }

    package func validateCoverage(request: SearchRequest, index: ManagedIndex) throws {
        try request.traversal.validate()
        guard request.scopes.allSatisfy({ SearchPath.contains($0, in: index.scopeURL) }) else {
            throw SearchServiceError.commandFailed("One or more search folders are outside this snapshot. Choose Live files to search across drives.")
        }
        guard coverageMatches(request: request, index: index) else {
            throw SearchServiceError.commandFailed("This snapshot uses different traversal or hidden-file settings. Refresh it to use the current options, or turn off Snapshot.")
        }
    }

    private func searchWarning(request: SearchRequest, index: ManagedIndex) -> String? {
        let warnings = [index.warning,
                        index.engineName == "find" && !request.traversal.includeIgnored ? SearchTraversalOptions.findWarning : nil]
            .compactMap { $0 }.joined(separator: " ")
        return warnings.isEmpty ? nil : warnings
    }

}
