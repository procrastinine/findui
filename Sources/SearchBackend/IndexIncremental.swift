import Foundation

extension IndexService {
    /// Only changed metadata is reread, and only changed records are committed.
    /// Keep the catalog resident between FSEvents batches; sorting belongs to
    /// result presentation, not to every filesystem event.
    package func refreshIndex(_ previous: IndexArtifact, changes: [IndexChange]) async throws -> IndexBuildResult {
        let index = previous.metadata, root = index.scopeURL
        guard !changes.isEmpty else {
            return IndexBuildResult(metadata: index, entries: previous.entries, commandPreview: commandPreview(for: index),
                catalog: previous.catalog, delta: IndexDelta(baseGeneration: index.queryGeneration))
        }
        let traversal = index.traversal ?? .init()
        let original = previous.catalog ?? Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.relativePath, $0) })
        var entries = original
        var changed: Set<String> = [], touched: Set<String> = [], recursive: Set<String> = []
        func relative(_ url: URL) -> String? { SearchPath.relativePath(of: url, in: root) }
        func remove(_ path: String, descendantsOnly: Bool = false) {
            if !descendantsOnly { entries.removeValue(forKey: path); changed.insert(path) }
            // Structural events need the old descendants; ordinary file edits
            // perform a dictionary lookup and never scan unrelated entries.
            let keys = entries.keys.filter { $0.hasPrefix(path + "/") }
            for key in keys { entries.removeValue(forKey: key); changed.insert(key) }
        }
        var candidates: [URL] = []
        var batch: [String: Bool] = [:]
        for change in changes {
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            batch[path] = (batch[path] ?? false) || change.recursive
        }
        let recursiveRoots = batch.filter { path, recursive in
            recursive && relative(URL(fileURLWithPath: path)).map { !$0.isEmpty } == true
        }.keys.sorted { $0.count < $1.count }.reduce(into: [String]()) { roots, path in
            if !roots.contains(where: { path.hasPrefix($0 + "/") }) { roots.append(path) }
        }
        // FSEvents can report a created directory and every child together.
        // Handle that subtree once, before even reading descendant metadata.
        for (changedPath, recurse) in batch where !recursiveRoots.contains(where: { changedPath.hasPrefix($0 + "/") }) {
            let change = IndexChange(path: changedPath, recursive: recurse)
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: change.path).standardizedFileURL
            guard let path = relative(url), !path.isEmpty else { continue }
            var directory = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
                if entries[path]?.kind == .folder || change.recursive { remove(path) }
                else { entries.removeValue(forKey: path); changed.insert(path) }
                continue
            }
            let symbolic = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if symbolic && !traversal.followSymlinks { remove(path); continue }
            let old = entries[path]?.kind
            if !directory.boolValue && old == .folder { remove(path, descendantsOnly: true) }
            touched.insert(path); candidates.append(url)
            if directory.boolValue && (change.recursive || old != .folder) { recursive.insert(path) }
        }
        // Directories below minimumDepth may need traversal, but must not
        // themselves become results. Apply that lower bound when publishing.
        let eligible = try await admittedIndexPaths(candidates, index: index, minimumDepth: 0)
        let subtrees = recursive.sorted { $0.count < $1.count }.reduce(into: [String]()) { selected, path in
            if !selected.contains(where: { path.hasPrefix($0 + "/") }) { selected.append(path) }
        }
        var metadataPaths: Set<String> = []
        for subtree in subtrees {
            remove(subtree, descendantsOnly: true)
            let url = root.appendingPathComponent(subtree), depth = subtree.split(separator: "/").count
            guard eligible.contains(url.path) else { continue }
            if let maximum = traversal.maximumDepth, depth >= maximum { continue }
            let paths = try await indexPaths(scope: url, index: index, maximumDepth: traversal.maximumDepth.map { $0 - depth })
            // Admission is always anchored at the original root, including its
            // ignore files. Walking a new subtree cannot reset ignore context.
            let accepted = try await admittedIndexPaths(paths, index: index)
            for file in paths where accepted.contains(file.path) {
                metadataPaths.insert(file.path)
            }
        }
        for path in touched {
            // The subtree pass already updated or excluded every descendant.
            if subtrees.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            let url = root.appendingPathComponent(path)
            entries.removeValue(forKey: path)
            if path.split(separator: "/").count >= traversal.minimumDepth,
               eligible.contains(url.path) { metadataPaths.insert(url.path) }
            changed.insert(path)
        }
        for entry in try await indexedEntries(Array(metadataPaths), scope: root, followSymlinks: traversal.followSymlinks) {
            entries[entry.relativePath] = entry; changed.insert(entry.relativePath)
        }
        changed = changed.filter { entries[$0] != original[$0] }
        var metadata = index
        metadata.updatedAt = .now
        if !changed.isEmpty { metadata.queryGeneration = UUID() }
        for path in changed {
            if original[path]?.kind == .file { metadata.fileCount -= 1 }
            if original[path]?.kind == .folder { metadata.folderCount -= 1 }
            if entries[path]?.kind == .file { metadata.fileCount += 1 }
            if entries[path]?.kind == .folder { metadata.folderCount += 1 }
        }
        metadata.entryCount = entries.count
        let delta = IndexDelta(baseGeneration: index.queryGeneration,
            removed: Set(changed.filter { entries[$0] == nil }), upserts: changed.compactMap { entries[$0] })
        return IndexBuildResult(metadata: metadata, entries: changed.isEmpty ? previous.entries : Array(entries.values),
            commandPreview: commandPreview(for: metadata), catalog: entries, delta: delta)
    }
    private func admittedIndexPaths(_ paths: [URL], index: ManagedIndex, minimumDepth: Int? = nil) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        if let worker = tools.contentWorker {
            let request = SearchRequest(query: "", mode: .everything, scope: index.scopeURL, includeHidden: index.includeHidden,
                caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max, traversal: index.traversal ?? .init())
            var config = try SearchPipelineCompiler(tools: tools).traversalConfiguration(request)
            if let minimumDepth { config["minimumDepth"] = minimumDepth }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
            // One reader shares compiled ignore rules for the whole batch.
            // A NUL file avoids both shell argument limits and one process per
            // 256 paths. The process group still supports cancellation.
            let input = FileManager.default.temporaryDirectory.appendingPathComponent("findui-admission-\(UUID())")
            try Data((paths.map(\.path).joined(separator: "\0") + "\0").utf8).write(to: input, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: input) }
            let script = SearchPipelineCompiler.command(worker.path, ["--admit", json])
                + " < " + SearchPipelineCompiler.command(input.path, [])
            let output = try await ProcessRunner.run(spec: SearchPipeline.command(script), pathOverride: tools.searchPath)
            guard output.exitCode == 0 else { throw SearchServiceError.commandFailed(output.stderr) }
            return Set(output.stdout.split(separator: "\0").map(String.init))
        }
        var accepted: Set<String> = []
        for parent in Set(paths.map { $0.deletingLastPathComponent() }) {
            accepted.formUnion(try await indexPaths(scope: parent, index: index, maximumDepth: 1).map(\.path))
        }
        return accepted
    }
    private func indexPaths(scope: URL, index: ManagedIndex, maximumDepth: Int?) async throws -> [URL] {
        var traversal = index.traversal ?? .init(); traversal.minimumDepth = 1; traversal.maximumDepth = maximumDepth
        let request = SearchRequest(query: "", mode: .everything, scope: scope, includeHidden: index.includeHidden,
            caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max, traversal: traversal)
        let compiler = SearchPipelineCompiler(tools: tools)
        var query = try request.normalizedQuery()
        query.traversal.ruleRoot = index.scopePath
        let pipeline = try compiler.compile(query)
        let output = try await ProcessRunner.run(spec: pipeline.spec, pathOverride: tools.searchPath)
        guard output.exitCode == 0, SearchDiagnostics(output.stderr).warnings.isEmpty else {
            throw SearchServiceError.commandFailed(output.stderr)
        }
        return output.stdout.split(separator: "\0").compactMap {
            let path = URL(fileURLWithPath: String($0)).standardizedFileURL
            return SearchPath.relativePath(of: path, in: index.scopeURL).map { index.scopeURL.appendingPathComponent($0) }
        }
    }
}
