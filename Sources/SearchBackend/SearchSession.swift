import Foundation

/// Prepared once, inspected/exported and executed without consulting frontend
/// state. The snapshot lease pins one generation for the entire operation.
package struct PreparedSearch: Sendable {
    package let request: SearchRequest
    package let pipeline: SearchPipeline
    package let snapshot: PreparedSnapshot?
    package let index: ManagedIndex?
    package let command: String
    package let warning: String?
    package var engineName: String { index == nil ? pipeline.engineName : "Snapshot" }

    package init(request: SearchRequest, tools: Toolchain) throws {
        var request = request
        request.includeMetadata = true
        self.request = request
        pipeline = try SearchPipelineCompiler(tools: tools).compile(request)
        snapshot = nil
        index = nil
        command = pipeline.script
        warning = nil
    }
    package init(
        request: SearchRequest, index: ManagedIndex, snapshot: PreparedSnapshot,
        tools: Toolchain, location: URL
    ) throws {
        try IndexService(tools: tools).validateCoverage(request: request, index: index)
        var actual = request
        actual.useIndex = true
        if !index.includeHidden { actual.includeHidden = true }
        actual.mode =
            request.indexedFilter == .folders ? .folders : request.indexedFilter == .files ? .files : .everything
        self.request = actual
        self.index = index
        self.snapshot = snapshot
        pipeline = try SearchPipelineCompiler(tools: tools).compile(actual, source: snapshot.querySource)
        command = try HeadlessCLI.searchCommand(request, snapshot: location, index: index)
        warning = index.warning
    }
    package static func snapshot(
        request: SearchRequest, at location: URL, tools: Toolchain, legacyIndex: ManagedIndex? = nil
    ) async throws -> Self {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let artifact = try IndexArtifact.load(location, includeEntries: false, legacyMetadata: legacyIndex)
            do {
                let lease = try await SnapshotQueryCache.shared.prepare(
                    index: artifact.metadata, entries: artifact.entries)
                return try Self(
                    request: request, index: artifact.metadata, snapshot: lease, tools: tools, location: location)
            } catch SnapshotQueryError.generationChanged where attempt < 2 { continue }
        }
        throw SnapshotQueryError.generationChanged
    }
    package func present(_ row: SearchResult) -> SearchResult {
        let entry = snapshot?.entry(row.path)
        let kind: SearchResultKind = entry.map { $0.kind == .folder ? .folder : .file } ?? row.kind
        let folder = kind == .folder
        guard entry != nil || request.isDirectoryListing else { return row }
        return SearchResult(
            id: row.id, url: row.url, kind: kind, lineNumber: row.lineNumber,
            extractedOrigin: row.extractedOrigin, snippet: row.snippet, snippetMatchRanges: row.snippetMatchRanges,
            displayNameOverride: request.isDirectoryListing && folder ? row.name + "/" : nil,
            browseTargetURL: request.isDirectoryListing && folder ? row.url : nil,
            typeDescription: entry?.typeDescription ?? row.typeDescription,
            modifiedAt: entry?.modifiedAt ?? row.modifiedAt, createdAt: entry?.createdAt ?? row.createdAt,
            addedAt: entry?.addedAt ?? row.addedAt,
            lastOpenedAt: entry == nil
                ? row.lastOpenedAt : index?.lastOpenedUsesSpotlight == true ? entry?.lastOpenedAt : nil,
            size: entry?.size ?? row.size, tags: entry == nil ? row.tags : entry?.tags ?? [],
            matchRank: row.matchRank, sourceOrder: row.sourceOrder)
    }
    package func stream(tools: Toolchain,
        onOutput: @Sendable @escaping (CommandTextOutput) async -> Void = { _ in },
        onChunk: @Sendable @escaping ([SearchResult]) async throws -> Void)
        async throws -> SearchExecutionSummary
    {
        let summary = try await SearchService(tools: tools).streamSearch(request: request, pipeline: pipeline, onOutput: onOutput) { rows in
            try await onChunk(rows.map(present))
        }
        return SearchExecutionSummary(
            commandPreview: command, engineName: engineName,
            isTruncated: summary.isTruncated,
            warning: [warning, summary.warning].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                .nilIfEmpty,
            wordStatus: summary.wordStatus, commandOutput: summary.commandOutput)
    }
}

/// Result ingestion is independent of UI redraw frequency. First results and
/// completion always publish; intervening notifications are coalesced.
package struct SearchSession: Sendable {
    package let prepared: PreparedSearch
    package let results: ResultStore
    private let publication = SearchPublicationGate()
    package init(prepared: PreparedSearch) throws {
        self.prepared = prepared
        results = try ResultStore(followSymlinks: prepared.request.traversal.followSymlinks)
    }
    package func run(
        tools: Toolchain, prefix: [SearchResult] = [],
        onOutput: @Sendable @escaping (CommandTextOutput) async -> Void = { _ in },
        onChange: @Sendable @escaping () async -> Void
    ) async throws -> SearchExecutionSummary {
        if !prefix.isEmpty {
            try await results.append(prefix)
            await onChange()
        }
        do {
            let summary = try await prepared.stream(tools: tools, onOutput: onOutput) { rows in
                try await results.append(rows)
                if await publication.due() { await onChange() }
            }
            try await results.checkCollection()
            await onChange()
            return summary
        } catch {
            await onChange()
            throw error
        }
    }
    package static func debounce(indexed: Bool, browsing: Bool) -> Duration {
        .milliseconds(indexed || browsing ? 60 : 140)
    }
}

private actor SearchPublicationGate {
    private var last: ContinuousClock.Instant?
    func due() -> Bool {
        let now = ContinuousClock.now
        if let last, now - last < .milliseconds(50) { return false }
        last = now
        return true
    }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
