import Foundation
import SQLite3

package struct ResultSort: Sendable, Equatable {
    package let column: String
    package let descending: Bool
    package init(column: String, descending: Bool) {
        self.column = column
        self.descending = descending
    }

}
package struct ResultTotals: Codable, Sendable, Equatable {
    package var files = 0
    package var documents = 0
    package var matches = 0
    package var documentCounts: [String: Int] = [:]
    package init(files: Int = 0, documents: Int = 0, matches: Int = 0, documentCounts: [String: Int] = [:]) {
        self.files = files
        self.documents = documents
        self.matches = matches
        self.documentCounts = documentCounts
    }

}

/// Temporary, disk-backed results. Only a page of decoded rows is kept by the UI.
/// This stores search output, never copies the files being searched.
package actor ResultStore {
    package static let pageSize = 1_000
    private let directory: URL
    // All database operations are actor-isolated; only final cleanup runs in deinit.
    nonisolated(unsafe) private var database: OpaquePointer?
    package private(set) var count = 0
    private var fileCount = 0
    private var contentCount = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var sortIndexes: [(order: String, name: String)] = []
    private var nextSortIndex = 0
    package private(set) var sortBuildCount = 0
    private var collectionError: (any Error)?
    private let followSymlinks: Bool
    private var tagTask: Task<Void, Error>?
    private struct CachedPage {
        let number: Int
        let size: Int
        let sort: [ResultSort]
        let rows: [SearchResult]
    }
    private var cachedPage: CachedPage?
    package private(set) var pageRevision = 0
    package private(set) var decodedRowCount = 0
    package struct Presentation: Sendable {
        package let rows: [SearchResult]
        package let revision: Int
        package let totals: ResultTotals
        package let count: Int
    }
    package func presentation(_ number: Int, sort: [ResultSort] = []) throws -> Presentation {
        let rows = try page(number, sort: sort)
        return try Presentation(rows: rows, revision: pageRevision, totals: totals(for: rows), count: count)
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    package init(followSymlinks: Bool = false) throws {
        self.followSymlinks = followSymlinks
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("findui-results-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("results.sqlite").path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw SearchServiceError.commandFailed("Could not create temporary result storage.")
        }
        database = db
        sqlite3_exec(
            db, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-4096; PRAGMA temp_store=FILE;",
            nil, nil, nil)
        let schema = """
            CREATE TABLE results (position INTEGER PRIMARY KEY, payload BLOB NOT NULL,
              name TEXT, path TEXT, kind TEXT, modified REAL, created REAL, added REAL, opened REAL,
              size INTEGER, rank INTEGER, parent INTEGER, document TEXT, identifier TEXT, line INTEGER, content INTEGER);
            CREATE INDEX search_order ON results(parent DESC, rank ASC, position ASC);
            CREATE INDEX document_matches ON results(document,line,position);
            CREATE INDEX result_identifiers ON results(identifier);
            CREATE TABLE document_totals(document TEXT PRIMARY KEY,path TEXT,total INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE facet_files(path TEXT PRIMARY KEY,extension TEXT,folder TEXT,modified REAL,tags TEXT) WITHOUT ROWID;
            CREATE TRIGGER count_matches AFTER INSERT ON results WHEN new.content=1 BEGIN
              INSERT INTO document_totals VALUES(new.document,new.path,1) ON CONFLICT(document) DO UPDATE SET total=total+1;
            END;
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            database = nil
            throw SearchServiceError.commandFailed("Could not initialize result storage.")
        }
        sqlite3_create_collation(db, "FILENAME", SQLITE_UTF8, nil) { _, lhsSize, lhs, rhsSize, rhs in
            let l = String(
                decoding: UnsafeBufferPointer(start: lhs?.assumingMemoryBound(to: UInt8.self), count: Int(lhsSize)),
                as: UTF8.self)
            let r = String(
                decoding: UnsafeBufferPointer(start: rhs?.assumingMemoryBound(to: UInt8.self), count: Int(rhsSize)),
                as: UTF8.self)
            return Int32(l.localizedStandardCompare(r).rawValue)
        }
    }

    deinit {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: directory)
    }

    package func append(_ rows: [SearchResult]) throws {
        let previousCount = count
        let previousFiles = fileCount
        let previousMatches = contentCount
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(
                database, "INSERT INTO results VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_exec(database, "BEGIN", nil, nil, nil))
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        var facet: OpaquePointer?
        try check(sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO facet_files VALUES(?,?,?,?,?)", -1, &facet, nil))
        defer { sqlite3_finalize(facet) }
        var facetPaths = Set<String>()
        do {
            for row in rows {
                let data = try encoder.encode(row)
                sqlite3_bind_int64(statement, 1, Int64(count))
                _ = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), Self.transient)
                }
                for (index, text) in [(3, row.name), (4, row.path), (5, row.sortableKind)] {
                    sqlite3_bind_text(statement, Int32(index), text, -1, Self.transient)
                }
                for (index, date) in [(6, row.modifiedAt), (7, row.createdAt), (8, row.addedAt), (9, row.lastOpenedAt)]
                {
                    sqlite3_bind_double(
                        statement, Int32(index), date?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
                }
                sqlite3_bind_int64(statement, 10, row.size ?? -1)
                sqlite3_bind_int64(statement, 11, Int64(row.matchRank))
                sqlite3_bind_int(statement, 12, row.isParentDirectoryEntry ? 1 : 0)
                sqlite3_bind_text(
                    statement, 13, row.documentIdentity, Int32(row.documentIdentity.utf8.count), Self.transient)
                sqlite3_bind_text(statement, 14, row.id.uuidString, -1, Self.transient)
                sqlite3_bind_int64(statement, 15, Int64(row.lineNumber ?? row.extractedOrigin?.line ?? 0))
                sqlite3_bind_int(statement, 16, row.kind == .contentMatch ? 1 : 0)
                try check(sqlite3_step(statement), expected: SQLITE_DONE)
                if row.kind == .contentMatch { contentCount += 1 }
                if !row.isParentDirectoryEntry && facetPaths.insert(row.path).inserted {
                    sqlite3_bind_text(facet, 1, row.path, -1, Self.transient)
                    sqlite3_bind_text(facet, 2, row.url.pathExtension.lowercased(), -1, Self.transient)
                    sqlite3_bind_text(facet, 3, row.url.deletingLastPathComponent().path, -1, Self.transient)
                    sqlite3_bind_double(facet, 4, row.modifiedAt?.timeIntervalSince1970 ?? 0)
                    if let tags = row.tags {
                        sqlite3_bind_text(
                            facet, 5, String(decoding: try encoder.encode(Set(tags).sorted()), as: UTF8.self), -1,
                            Self.transient)
                    } else {
                        sqlite3_bind_null(facet, 5)
                    }
                    try check(sqlite3_step(facet), expected: SQLITE_DONE)
                    fileCount += Int(sqlite3_changes(database))
                    sqlite3_reset(facet)
                    sqlite3_clear_bindings(facet)
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                count += 1
            }
            try check(sqlite3_exec(database, "COMMIT", nil, nil, nil))
            if let page = cachedPage, !rows.isEmpty,
                page.rows.isEmpty || page.rows.count < page.size
                    || rows.contains(where: { Self.precedes($0, page.rows.last!, sort: page.sort) })
            {
                cachedPage = nil
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            count = previousCount
            fileCount = previousFiles
            contentCount = previousMatches
            throw error
        }
    }
    package func collect(_ rows: [SearchResult]) {
        guard collectionError == nil else { return }
        do { try append(rows) } catch { collectionError = error }
    }
    package func checkCollection() throws { if let collectionError { throw collectionError } }

    private func ordering(_ sort: [ResultSort]) throws -> String {
        let allowed = Set(["name", "path", "kind", "modified", "created", "added", "opened", "size", "rank"])
        let order = sort.filter { allowed.contains($0.column) }.map {
            $0.column + (["name", "path", "kind"].contains($0.column) ? " COLLATE FILENAME" : "")
                + ($0.descending ? " DESC" : " ASC")
        }
        let ordering = (["parent DESC"] + (order.isEmpty ? ["rank ASC"] : order) + ["position ASC"]).joined(
            separator: ",")
        if !order.isEmpty && !sortIndexes.contains(where: { $0.order == ordering }) {
            try Task.checkCancellation()
            sqlite3_progress_handler(database, 2_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            let name = "sort_\(nextSortIndex)"
            nextSortIndex += 1
            try check(sqlite3_exec(database, "CREATE INDEX \(name) ON results(\(ordering))", nil, nil, nil))
            sortIndexes.append((ordering, name))
            sortBuildCount += 1
            // SQLite updates retained orders incrementally on append. Two user
            // orders plus the native order bound disk use across column clicks.
            if sortIndexes.count > 2 {
                let old = sortIndexes.removeFirst()
                try check(sqlite3_exec(database, "DROP INDEX \(old.name)", nil, nil, nil))
            }
        }
        return ordering
    }

    package func page(_ number: Int, sort: [ResultSort] = [], size: Int = ResultStore.pageSize) throws -> [SearchResult]
    {
        guard size > 0 else { return [] }
        if let page = cachedPage, page.number == number, page.sort == sort, page.size == size { return page.rows }
        let ordering = try ordering(sort)
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(
                database, "SELECT payload FROM results ORDER BY \(ordering) LIMIT ? OFFSET ?", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(size))
        sqlite3_bind_int64(statement, 2, Int64(max(0, number)) * Int64(size))
        var rows: [SearchResult] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            try check(status, expected: SQLITE_ROW)
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            rows.append(
                try decoder.decode(
                    SearchResult.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
            decodedRowCount += 1
        }
        cachedPage = CachedPage(number: number, size: size, sort: sort, rows: rows)
        pageRevision += 1
        return rows
    }

    private static func precedes(_ a: SearchResult, _ b: SearchResult, sort: [ResultSort]) -> Bool {
        if a.isParentDirectoryEntry != b.isParentDirectoryEntry { return a.isParentDirectoryEntry }
        if sort.isEmpty { return a.matchRank < b.matchRank }
        let known = Set(["name", "path", "kind", "modified", "created", "added", "opened", "size", "rank"])
        let fields = sort.filter { known.contains($0.column) }
        for field in fields.isEmpty ? [ResultSort(column: "rank", descending: false)] : fields {
            let order: ComparisonResult
            switch field.column {
            case "name": order = a.name.localizedStandardCompare(b.name)
            case "path": order = a.path.localizedStandardCompare(b.path)
            case "kind": order = a.sortableKind.localizedStandardCompare(b.sortableKind)
            case "size": order = compare(a.size ?? -1, b.size ?? -1)
            case "rank": order = compare(a.matchRank, b.matchRank)
            default:
                func value(_ r: SearchResult) -> Double {
                    let date =
                        field.column == "modified"
                        ? r.modifiedAt
                        : field.column == "created"
                            ? r.createdAt
                            : field.column == "added" ? r.addedAt : r.lastOpenedAt
                    return date?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
                }
                order = compare(value(a), value(b))
            }
            if order != .orderedSame {
                return field.descending ? order == .orderedDescending : order == .orderedAscending
            }
        }
        // New rows follow existing rows when every explicit key is equal.
        return false
    }
    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    package func exportCSV(to destination: URL, sort: [ResultSort]) throws -> Int {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".findui-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(ResultExport.csv([]).utf8).write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var exported = 0
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(
                database, "SELECT payload FROM results ORDER BY \(try ordering(sort))", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        var rows: [SearchResult] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status != SQLITE_DONE {
                try check(status, expected: SQLITE_ROW)
                if let bytes = sqlite3_column_blob(statement, 0) {
                    rows.append(
                        try decoder.decode(
                            SearchResult.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
                    )
                }
                if rows.count < Self.pageSize { continue }
            }
            let csv = ResultExport.csv(rows)
            if let headerEnd = csv.range(of: "\r\n") {
                try handle.write(contentsOf: Data(csv[headerEnd.upperBound...].utf8))
            }
            exported += rows.filter { !$0.isParentDirectoryEntry }.count
            rows.removeAll(keepingCapacity: true)
            if status == SQLITE_DONE { break }
        }
        try handle.synchronize()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return exported
    }

    package func saveScope(
        name: String, directory: URL = FindUIPaths.baseDirectory().appendingPathComponent("Result Scopes")
    ) throws -> SearchResultScope {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(UUID().uuidString + ".nul")
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(
                database, "SELECT DISTINCT path FROM results WHERE parent=0 ORDER BY path", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        var total = 0
        do {
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                try check(status, expected: SQLITE_ROW)
                let count = Int(sqlite3_column_bytes(statement, 0))
                if let text = sqlite3_column_text(statement, 0) {
                    var data = Data(bytes: text, count: count)
                    data.append(0)
                    try handle.write(contentsOf: data)
                    total += 1
                }
            }
            try handle.synchronize()
            return .init(path: path.path, name: name, count: total)
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw error
        }
    }

    package func totals(for rows: [SearchResult]) throws -> ResultTotals {
        var value = ResultTotals()
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, "SELECT count(*) FROM document_totals", -1, &statement, nil))
        try check(sqlite3_step(statement), expected: SQLITE_ROW)
        value.files = fileCount
        value.documents = Int(sqlite3_column_int64(statement, 0))
        value.matches = contentCount
        sqlite3_finalize(statement)
        try check(
            sqlite3_prepare_v2(database, "SELECT total FROM document_totals WHERE document=?", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        for document in Set(rows.map(\.documentIdentity)) {
            sqlite3_bind_text(statement, 1, document, Int32(document.utf8.count), Self.transient)
            if sqlite3_step(statement) == SQLITE_ROW {
                value.documentCounts[document] = Int(sqlite3_column_int64(statement, 0))
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        return value
    }

    /// Metadata already supplied with results, counted once per outer file.
    /// Resolve missing tags only when facets are requested, once per result
    /// file. Ordinary searches never pay for this optional metadata.
    package func facets(now: Date = .now) async throws -> [ResultFacet] {
        if let tagTask {
            try await tagTask.value
        } else {
            let task = Task { try await populateTags() }
            tagTask = task
            defer { tagTask = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        var facets: [ResultFacet] = []
        for (kind, sql) in [
            (
                ResultFacet.Kind.fileType,
                "SELECT extension,count(*) AS n FROM facet_files WHERE extension<>'' GROUP BY extension ORDER BY n DESC,extension LIMIT 8"
            ),
            (.folder, "SELECT folder,count(*) AS n FROM facet_files GROUP BY folder ORDER BY n DESC,folder LIMIT 8"),
            (
                .tag,
                "SELECT value,count(*) AS n FROM facet_files,json_each(facet_files.tags) GROUP BY value ORDER BY n DESC,value LIMIT 8"
            ),
        ] {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                try check(status, expected: SQLITE_ROW)
                facets.append(
                    .init(
                        kind: kind, value: String(cString: sqlite3_column_text(statement, 0)),
                        count: Int(sqlite3_column_int64(statement, 1))))
            }
        }
        for days in [7, 30] {
            var filters = SearchFilters()
            try filters.setRelativeDays(days)
            let bounds = try filters.validated(now: now)
            var statement: OpaquePointer?
            try check(
                sqlite3_prepare_v2(
                    database, "SELECT count(*) FROM facet_files WHERE modified>=? AND modified<?", -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, bounds.from?.timeIntervalSince1970 ?? 0)
            sqlite3_bind_double(statement, 2, bounds.before?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)
            try check(sqlite3_step(statement), expected: SQLITE_ROW)
            let count = Int(sqlite3_column_int64(statement, 0))
            if count > 0 { facets.append(.init(kind: .modified, value: String(days), count: count)) }
        }
        return facets
    }

    private func populateTags() async throws {
        while true {
            try Task.checkCancellation()
            var statement: OpaquePointer?
            try check(
                sqlite3_prepare_v2(
                    database, "SELECT path FROM facet_files WHERE tags IS NULL LIMIT 256", -1, &statement, nil))
            var paths: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                do { try check(status, expected: SQLITE_ROW) } catch {
                    sqlite3_finalize(statement)
                    throw error
                }
                paths.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            sqlite3_finalize(statement)
            guard !paths.isEmpty else { return }
            let batch = paths
            let follow = followSymlinks
            let values = try await withThrowingTaskGroup(of: [(String, [String])].self) { group in
                for offset in stride(from: 0, to: batch.count, by: 32) {
                    let part = Array(batch[offset..<min(batch.count, offset + 32)])
                    group.addTask {
                        try part.map { path in
                            try Task.checkCancellation()
                            return (
                                path, FileMetadata.finderTags(URL(fileURLWithPath: path), followSymlinks: follow) ?? []
                            )
                        }
                    }
                }
                var values: [(String, [String])] = []
                for try await part in group { values += part }
                return values
            }
            try check(
                sqlite3_prepare_v2(
                    database, "UPDATE facet_files SET tags=? WHERE path=? AND tags IS NULL", -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            for (path, tags) in values {
                sqlite3_bind_text(
                    statement, 1, String(decoding: try encoder.encode(tags), as: UTF8.self), -1, Self.transient)
                sqlite3_bind_text(statement, 2, path, -1, Self.transient)
                try check(sqlite3_step(statement), expected: SQLITE_DONE)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    package func documentPosition(_ result: SearchResult) throws -> Int {
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(
                database,
                "SELECT count(*) FROM results WHERE document=? AND content=1 AND (line,position)<(SELECT line,position FROM results WHERE identifier=?)",
                -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(
            statement, 1, result.documentIdentity, Int32(result.documentIdentity.utf8.count), Self.transient)
        sqlite3_bind_text(statement, 2, result.id.uuidString, -1, Self.transient)
        try check(sqlite3_step(statement), expected: SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    package func adjacentMatch(to result: SearchResult, offset: Int, sort: [ResultSort]) throws -> (
        result: SearchResult, page: Int
    )? {
        guard offset == -1 || offset == 1 else { return nil }
        var statement: OpaquePointer?
        let comparison = offset < 0 ? "<" : ">"
        let direction = offset < 0 ? "DESC" : "ASC"
        try check(
            sqlite3_prepare_v2(
                database,
                "SELECT payload FROM results WHERE document=? AND content=1 AND (line,position)\(comparison)(SELECT line,position FROM results WHERE identifier=?) ORDER BY line \(direction),position \(direction) LIMIT 1",
                -1, &statement, nil))
        sqlite3_bind_text(
            statement, 1, result.documentIdentity, Int32(result.documentIdentity.utf8.count), Self.transient)
        sqlite3_bind_text(statement, 2, result.id.uuidString, -1, Self.transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE {
            sqlite3_finalize(statement)
            return nil
        }
        try check(status, expected: SQLITE_ROW)
        let next = try decoder.decode(
            SearchResult.self,
            from: Data(bytes: sqlite3_column_blob(statement, 0)!, count: Int(sqlite3_column_bytes(statement, 0))))
        sqlite3_finalize(statement)
        try check(
            sqlite3_prepare_v2(
                database,
                "SELECT ordinal FROM (SELECT identifier,row_number() OVER (ORDER BY \(try ordering(sort)))-1 AS ordinal FROM results) WHERE identifier=?",
                -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, next.id.uuidString, -1, Self.transient)
        try check(sqlite3_step(statement), expected: SQLITE_ROW)
        return (next, Int(sqlite3_column_int64(statement, 0)) / Self.pageSize)
    }

    private func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
        if status == SQLITE_INTERRUPT && Task.isCancelled { throw CancellationError() }
        guard status == expected else {
            throw SearchServiceError.commandFailed("Result storage: \(String(cString: sqlite3_errmsg(database)))")
        }
    }
}
