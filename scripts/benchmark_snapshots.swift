import SearchBackend
import Foundation

/// Synthetic, immutable metadata: measures query and update overhead, not disk traversal.
@main struct SnapshotBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = IndexService()
        var report: [[String: Any]] = []
        for count in [10_000, 100_000] {
            let entries = (0..<count).map { IndexedEntry(relativePath: "folder-\($0 % 100)/document-\($0).txt", kind: .file, size: Int64($0), tags: []) }
            let metadata = ManagedIndex(id: UUID(), name: "Synthetic benchmark", scopePath: root.path, includeHidden: true,
                createdAt: .now, updatedAt: .now, fileCount: count, folderCount: 0, entryCount: count,
                engineName: "FindUI", traversal: .init(), queryGeneration: UUID())
            let file = root.appendingPathComponent("synthetic-\(count).sqlite")
            let started = Date()
            try IndexArtifact(metadata: metadata, entries: entries).save(file)
            let initialSave = Date().timeIntervalSince(started) * 1000
            let loaded = try IndexArtifact.load(file)
            let request = SearchRequest(query: "zzzz-never-present", mode: .files, scope: root, useIndex: true,
                includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
            var samples: [Double] = []
            for _ in 0..<5 {
                let started = Date()
                let snapshot = try IndexArtifact.load(file, includeEntries: false)
                let response = try await service.search(request: request, index: snapshot.metadata, entries: snapshot.entries)
                precondition(response.results.isEmpty)
                samples.append(Date().timeIntervalSince(started) * 1000)
            }
            let refreshStarted = Date()
            _ = try await service.refreshIndex(loaded, changes: [])
            let emptyRefresh = Date().timeIntervalSince(refreshStarted) * 1000
            let touched = root.appendingPathComponent("folder-0/document-0.txt")
            try FileManager.default.createDirectory(at: touched.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("changed file".utf8).write(to: touched)
            let updateStarted = Date()
            let update = try await service.refreshIndex(loaded, changes: [.init(path: touched.path, recursive: false)])
            let refresh = Date().timeIntervalSince(updateStarted) * 1000
            let commitStarted = Date()
            try IndexArtifact(metadata: update.metadata, entries: update.entries, catalog: update.catalog, delta: update.delta).save(file)
            let commit = Date().timeIntervalSince(commitStarted) * 1000
            precondition(update.delta?.upserts.count == 1)
            report.append(["entries": count, "queryMilliseconds": samples,
                "warmMedianMilliseconds": samples.dropFirst().sorted()[1], "initialSaveMilliseconds": initialSave,
                "emptyRefreshMilliseconds": emptyRefresh, "singleFileRefreshMilliseconds": refresh,
                "singleFileCommitMilliseconds": commit,
                "artifactBytes": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("scaling.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
