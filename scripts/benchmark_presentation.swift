import Darwin
import Foundation
import SearchBackend

/// Audit the production backend paths used to present search results. This
/// measures preparation and storage, not SwiftUI frame rendering or cold I/O.
@main struct PresentationBenchmark {
    static func milliseconds(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tools = Toolchain.resolve(includeDocumentReaders: false)
        let service = SearchService(tools: tools)
        var report: [String: Any] = [
            "note":
                "Release-optimized source probe; warm synthetic fixtures. No GUI rendering, process launch or cold-cache claim. Production code is not modified."
        ]

        let files = root.appendingPathComponent("browse")
        try FileManager.default.createDirectory(
            at: files.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for name in ["visible.txt", "ignored.txt"] {
            try Data("needle\n".utf8).write(to: files.appendingPathComponent(name))
        }
        try Data("ignored.txt\n".utf8).write(to: files.appendingPathComponent(".ignore"))
        let collector = SearchResultCollector()
        let summary = try await service.streamDirectoryListing(scope: files, includeHidden: false) {
            await collector.append($0)
        }
        let presented = await collector.results.map(\.url.lastPathComponent).sorted()
        let command = try SearchCommandBuilder(tools: tools).preparedDirectoryListingCommand(
            scope: files, includeHidden: false)
        let exported = try await ProcessRunner.run(spec: command.spec, pathOverride: tools.searchPath)
        precondition(exported.exitCode == 0)
        let terminal = exported.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).lastPathComponent }
            .sorted()
        report["directoryBrowsing"] = [
            "presented": presented, "exported": terminal,
            "sameMembership": presented == terminal, "summaryCommand": summary.commandPreview,
            "preparedCommand": command.preview,
        ]

        let tagged = root.appendingPathComponent("tagged.txt")
        try Data("needle\n".utf8).write(to: tagged)
        let tag = "FindUIAuditTag"
        let plist = try PropertyListSerialization.data(fromPropertyList: [tag + "\n0"], format: .binary, options: 0)
        let status = plist.withUnsafeBytes {
            setxattr(tagged.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0)
        }
        if status == 0 {
            precondition(FileMetadata.finderTags(tagged) == [tag])
            var request = SearchRequest(
                query: "tagged", mode: .files, scope: root,
                includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
            request.refinements.finderTags = [tag]
            let collector = SearchResultCollector()
            _ = try await PreparedSearch(request: request, tools: tools).stream(tools: tools) {
                await collector.append($0)
            }
            let matches = await collector.results
            precondition(matches.count == 1)
            let store = try ResultStore()
            try await store.append(matches)
            let facets = try await store.facets().filter { $0.kind == .tag }.map(\.value)
            report["finderTags"] = [
                "storedTags": [tag], "matchingRows": matches.count,
                "liveResultTags": matches.first!.tags ?? [], "liveTagFacets": facets,
                "snapshotEntryTags": IndexService(tools: tools).indexedEntry(tagged, scope: root)?.tags ?? [],
            ]
        } else {
            report["finderTags"] = ["skipped": "xattr unavailable", "errno": errno]
        }

        var ranges: [[String: Any]] = []
        let request = SearchRequest(
            query: "a", mode: .contents, scope: root,
            includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
        for count in [1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536] {
            let snippet = String(repeating: "a ", count: count) + "\n"
            let matches: [[String: Any]] = (0..<count).map {
                ["start": $0 * 2, "end": $0 * 2 + 1, "match": ["text": "a"]]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "match",
                "data": [
                    "path": ["text": tagged.path], "lines": ["text": snippet], "line_number": 1, "submatches": matches,
                ],
            ])
            let line = String(decoding: data, as: UTF8.self)
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                let row = service.parseRipgrepJSONLine(line, request: request, sourceOrder: 0, pipelineOutput: true)
                samples.append(milliseconds(start))
                precondition(row?.snippetMatchRanges.count == count)
                precondition(row?.snippetMatchRanges.last == ((count - 1) * 2)..<((count - 1) * 2 + 1))
            }
            ranges.append(["lineBytes": snippet.utf8.count, "matches": count, "milliseconds": samples])
        }
        report["denseLineDecoding"] = ranges

        var ordinary: [[String: Any]] = []
        for snippet in ["a short matching line\n", "a café 🍎 matching line\n"] {
            let data = try JSONSerialization.data(withJSONObject: ["type": "match", "data": [
                "path": ["text": tagged.path], "lines": ["text": snippet], "line_number": 1,
                "submatches": [["start": 0, "end": 1, "match": ["text": "a"]]],
            ]])
            let line = String(decoding: data, as: UTF8.self)
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                for order in 0..<5_000 {
                    let row = service.parseRipgrepJSONLine(line, request: request, sourceOrder: order, pipelineOutput: true)
                    precondition(row?.snippetMatchRanges == [0..<1] && row?.sourceOrder == order)
                }
                samples.append(milliseconds(start))
            }
            ordinary.append(["snippet": snippet, "records": 5_000, "milliseconds": samples])
        }
        report["ordinaryLineDecoding"] = ordinary

        let rowCount = 50_000
        let rows = (0..<rowCount).map {
            SearchResult(
                url: tagged, kind: .contentMatch, lineNumber: $0 + 1,
                snippet: "needle line \($0)", snippetMatchRanges: [0..<6], matchRank: 0, sourceOrder: $0)
        }
        var ingestion: [[String: Any]] = []
        for round in 0..<3 {
            for refresh in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                let store = try ResultStore()
                var pageReads = 0
                var returnedRows = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for offset in stride(from: 0, to: rows.count, by: 512) {
                    try await store.append(Array(rows[offset..<min(rows.count, offset + 512)]))
                    if refresh {
                        let page = try await store.page(0)
                        _ = try await store.totals(for: page)
                        pageReads += 1
                        returnedRows += page.count
                    }
                }
                let final = try await store.page(0)
                let totals = try await store.totals(for: final)
                let time = milliseconds(start)
                precondition(totals.matches == rowCount && final.map(\.id) == rows.prefix(1_000).map(\.id))
                ingestion.append([
                    "round": round, "rows": rowCount, "pageRefreshPerBatch": refresh,
                    "milliseconds": time, "pageReadsBeforeFinal": pageReads, "rowsReturnedBeforeFinal": returnedRows,
                    "rowsActuallyDecoded": await store.decodedRowCount,
                ])
            }
        }
        report["resultIngestion"] = ingestion

        let directory = root.appendingPathComponent("snapshot")
        let count = 100_000
        let entries = (0..<count).map {
            IndexedEntry(relativePath: "folder-\($0 % 100)/document-\($0).txt", kind: .file, size: Int64($0))
        }
        let metadata = ManagedIndex(
            id: UUID(), name: "Presentation audit", scopePath: root.path, includeHidden: true,
            createdAt: .now, updatedAt: .now, fileCount: count, folderCount: 0, entryCount: count,
            engineName: "FindUI", traversal: .init(), queryGeneration: UUID())
        let file = directory.appendingPathComponent("Indexes/\(metadata.id.uuidString).sqlite")
        try IndexArtifact(metadata: metadata, entries: entries).save(file)
        let persistence = AppPersistence(baseDirectory: directory)
        var loading: [[String: Any]] = []
        for round in 0..<3 {
            for eager in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                let start = DispatchTime.now().uptimeNanoseconds
                if eager {
                    let loaded = try await persistence.loadEntries(for: metadata.id)
                    let elapsed = milliseconds(start)
                    precondition(loaded.count == count)
                    loading.append(["round": round, "loadsEveryEntry": true, "milliseconds": elapsed])
                } else {
                    let request = SearchRequest(
                        query: "document-99999", mode: .files, scope: root, useIndex: true,
                        includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false,
                        maxResults: .max)
                    let prepared = try await PreparedSearch.snapshot(request: request, at: file, tools: tools)
                    let elapsed = milliseconds(start)
                    precondition(prepared.index?.entryCount == count)
                    loading.append(["round": round, "loadsEveryEntry": false, "milliseconds": elapsed])
                }
            }
        }
        let startInspection = DispatchTime.now().uptimeNanoseconds
        let page = try IndexDatabase(file).page(0)
        precondition(page.entries.count == 200 && page.hasMore)
        report["snapshotInspection"] = [
            "entriesDecoded": page.entries.count, "milliseconds": milliseconds(startInspection),
        ]
        report["snapshotLoading"] = ["entries": count, "samples": loading]
        var explanations = [Double]()
        let explanationRequest = SearchRequest(
            query: "document-99999", mode: .files, scope: root, useIndex: true,
            includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let explanation = try await SearchExplainer(tools: tools).explain(
                explanationRequest, file: root.appendingPathComponent("folder-99/document-99999.txt"), snapshot: file)
            explanations.append(milliseconds(start))
            precondition(explanation.steps.count == 2 && explanation.steps.allSatisfy(\.passed))
        }
        report["snapshotExplanation"] = ["entries": count, "milliseconds": explanations]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try output.write(to: root.appendingPathComponent("presentation.json"))
        print(String(decoding: output, as: UTF8.self))
    }
}
