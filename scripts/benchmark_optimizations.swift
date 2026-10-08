import SearchBackend
import Foundation

@main struct OptimizationBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        var report: [String: Any] = ["note": "Synthetic warm-cache measurements; run with the computer idle."]
        let service = IndexService()
        var snapshots: [[String: Any]] = []
        for count in [10_000, 100_000, 300_000] {
            let directory = root.appendingPathComponent("snapshot-\(count)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entries = (0..<count).map { IndexedEntry(relativePath: "folder-\($0 % 100)/document-\($0).txt", kind: .file, size: Int64($0), tags: []) }
            let metadata = ManagedIndex(id: UUID(), name: "Audit", scopePath: directory.path, includeHidden: true,
                createdAt: .now, updatedAt: .now, fileCount: count, folderCount: 0, entryCount: count,
                engineName: "FindUI", traversal: .init(), queryGeneration: UUID())
            let file = directory.appendingPathComponent("index.sqlite")
            let start = Date()
            try IndexArtifact(metadata: metadata, entries: entries).save(file)
            let build = Date().timeIntervalSince(start) * 1000
            let request = SearchRequest(query: "zzzz-never-present", mode: .files, scope: directory, useIndex: true,
                includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
            var times: [Double] = []
            for _ in 0..<4 {
                let begin = Date()
                let snapshot = try IndexArtifact.load(file, includeEntries: false)
                let response = try await service.search(request: request, index: snapshot.metadata, entries: snapshot.entries)
                precondition(response.results.isEmpty)
                times.append(Date().timeIntervalSince(begin) * 1000)
            }
            snapshots.append(["entries": count, "queryMilliseconds": times, "buildMilliseconds": build, "databaseBytes": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
            print("snapshot \(count): \(times)")
        }
        report["snapshots"] = snapshots
        let store = try ResultStore()
        let count = 12_000
        let rows = (0..<count).map { i in SearchResult(url: root.appendingPathComponent("document-\(count-i).txt"), kind: .file,
            modifiedAt: Date(timeIntervalSince1970: Double(i % 97)), size: Int64(i), matchRank: 0, sourceOrder: i) }
        try await store.append(rows)
        var paging: [[String: Any]] = []
        for name in ["default", "name", "modified"] {
            let sort: [ResultSort] = name == "default" ? [] : [.init(column: name, descending: false)]
            for page in [0, 6, 11] {
                var times: [Double] = []
                for _ in 0..<3 {
                    let start = Date()
                    let results = try await store.page(page, sort: sort)
                    times.append(Date().timeIntervalSince(start) * 1000)
                    precondition(results.count == 1000)
                    if name == "name" { precondition(results.first!.name == "document-\(page*1000+1).txt") }
                }
                paging.append(["sort": name, "page": page, "milliseconds": times])
                print("page \(name) \(page): \(times)")
            }
        }
        var exports: [[String: Any]] = []
        for name in ["default", "name"] {
            let start = Date()
            let destination = root.appendingPathComponent("export-\(name).csv")
            let amount = try await store.exportCSV(to: destination, sort: name == "default" ? [] : [.init(column: name, descending: false)])
            precondition(amount == count)
            exports.append(["sort": name, "milliseconds": Date().timeIntervalSince(start)*1000, "count": amount])
            try FileManager.default.removeItem(at: destination)
        }
        report["paging"] = paging; report["exports"] = exports; report["sortIndexBuilds"] = await store.sortBuildCount
        let grouped = try ResultStore()
        let file = root.appendingPathComponent("many-matches.txt")
        try await grouped.append((1...1200).map { SearchResult(url: file, kind: .contentMatch, lineNumber: $0, snippet: "needle", matchRank: 0, sourceOrder: $0) })
        let first = try await grouped.page(0), second = try await grouped.page(1)
        let totals = try await grouped.totals(for:first)
        let next = try await grouped.adjacentMatch(to:first.last!,offset:1,sort:[])
        precondition(totals.documentCounts[file.path] == 1200 && next?.page == 1 && next?.result.id == second.first?.id)
        report["grouping"] = ["totalMatches": totals.matches, "files": totals.files,
            "documentMatchesOnBothPages": totals.documentCounts[file.path]!,
            "page0Rows": first.count, "page1Rows": second.count, "nextCrossesPage": next?.page == 1]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
