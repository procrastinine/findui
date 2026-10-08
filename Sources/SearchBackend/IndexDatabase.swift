import Foundation
import SQLite3

package struct IndexDelta: Sendable {
    package var baseGeneration: UUID?
    package var removed: Set<String> = []
    package var upserts: [IndexedEntry] = []
    package init(baseGeneration: UUID? = nil, removed: Set<String> = [], upserts: [IndexedEntry] = []) {
        self.baseGeneration = baseGeneration
        self.removed = removed
        self.upserts = upserts
    }

}

/// SQLite transactions update only changed entries. The filename is retained for
/// compatibility with saved CLI commands; the header identifies the new format.
package final class IndexDatabase: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    package static func isDatabase(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }
    package init(_ url: URL, writable: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &pointer, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw SearchServiceError.commandFailed("Cannot open filename index: \(url.path)")
        }
        database = pointer
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        sqlite3_busy_timeout(database, 10_000)
        if writable {
            try execute(
                "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS info (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS entries (path TEXT PRIMARY KEY, payload BLOB NOT NULL, record BLOB NOT NULL) WITHOUT ROWID;"
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS search_paths(id INTEGER PRIMARY KEY,path TEXT UNIQUE NOT NULL,normalized TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS search_info(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER);
                CREATE VIRTUAL TABLE IF NOT EXISTS name_candidates USING fts5(normalized,content='search_paths',content_rowid='id',tokenize='trigram case_sensitive 1',detail=none);
                CREATE TRIGGER IF NOT EXISTS path_insert AFTER INSERT ON search_paths BEGIN INSERT INTO name_candidates(rowid,normalized) VALUES(new.id,new.normalized); END;
                CREATE TRIGGER IF NOT EXISTS path_delete AFTER DELETE ON search_paths BEGIN INSERT INTO name_candidates(name_candidates,rowid,normalized) VALUES('delete',old.id,old.normalized); END;
                CREATE TRIGGER IF NOT EXISTS path_update AFTER UPDATE ON search_paths BEGIN
                  INSERT INTO name_candidates(name_candidates,rowid,normalized) VALUES('delete',old.id,old.normalized);
                  INSERT INTO name_candidates(rowid,normalized) VALUES(new.id,new.normalized); END;
                CREATE TRIGGER IF NOT EXISTS entry_delete AFTER DELETE ON entries BEGIN DELETE FROM search_paths WHERE path=old.path; END;
                """)
        } else {
            try execute("PRAGMA query_only=ON")
        }
    }
    deinit { sqlite3_close(database) }
    private func check(_ status: Int32, _ expected: Int32 = SQLITE_OK) throws {
        guard status == expected else {
            throw SearchServiceError.commandFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
    private func execute(_ sql: String) throws { try check(sqlite3_exec(database, sql, nil, nil, nil)) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        return statement!
    }
    private func bind(_ data: Data, to statement: OpaquePointer, at position: Int32) {
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient)
        }
    }
    private func data(_ statement: OpaquePointer, at column: Int32) -> Data {
        Data(bytes: sqlite3_column_blob(statement, column)!, count: Int(sqlite3_column_bytes(statement, column)))
    }
    package func load(includeEntries: Bool = true) throws -> IndexArtifact {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        var artifact = try information()
        if !includeEntries { return artifact }
        let read = try statement("SELECT payload FROM entries ORDER BY path")
        defer { sqlite3_finalize(read) }
        var entries: [IndexedEntry] = []
        entries.reserveCapacity(artifact.metadata.entryCount)
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(read)
            if status == SQLITE_DONE { break }
            try check(status, SQLITE_ROW)
            entries.append(try decoder.decode(IndexedEntry.self, from: data(read, at: 0)))
        }
        artifact.entries = entries
        artifact.catalog = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        return artifact
    }
    private func information() throws -> IndexArtifact {
        let read = try statement("SELECT payload FROM info WHERE id=1")
        defer { sqlite3_finalize(read) }
        try check(sqlite3_step(read), SQLITE_ROW)
        return try decoder.decode(IndexArtifact.self, from: data(read, at: 0))
    }
    package func entry(path: String) throws -> IndexedEntry? {
        lock.lock()
        defer { lock.unlock() }
        let read = try statement("SELECT payload FROM entries WHERE path=?")
        defer { sqlite3_finalize(read) }
        sqlite3_bind_text(read, 1, path, -1, Self.transient)
        let status = sqlite3_step(read)
        if status == SQLITE_DONE { return nil }
        try check(status, SQLITE_ROW)
        return try decoder.decode(IndexedEntry.self, from: data(read, at: 0))
    }
    /// Bound decoding and memory to one inspector page. Filtering runs inside
    /// SQLite and shares the localized path semantics of the previous inspector.
    package func page(_ number: Int, size: Int = 200, filter: String = "") throws -> (
        entries: [IndexedEntry], hasMore: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard number >= 0, (1...1000).contains(size) else { throw SearchServiceError.invalidQuery }
        sqlite3_progress_handler(database, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        try check(
            sqlite3_create_function_v2(
                database, "findui_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
                { context, _, values in
                    guard let values, let path = sqlite3_value_text(values[0]),
                        let pattern = sqlite3_value_text(values[1])
                    else {
                        sqlite3_result_int(context, 0)
                        return
                    }
                    sqlite3_result_int(
                        context,
                        String(cString: path).localizedCaseInsensitiveContains(String(cString: pattern)) ? 1 : 0)
                }, nil, nil, nil))
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let read = try statement(
            "SELECT payload FROM entries \(needle.isEmpty ? "" : "WHERE findui_contains(path,?)") ORDER BY path LIMIT ? OFFSET ?"
        )
        defer { sqlite3_finalize(read) }
        var bind: Int32 = 1
        if !needle.isEmpty {
            sqlite3_bind_text(read, bind, needle, -1, Self.transient)
            bind += 1
        }
        sqlite3_bind_int64(read, bind, Int64(size + 1))
        sqlite3_bind_int64(read, bind + 1, Int64(number) * Int64(size))
        var entries: [IndexedEntry] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(read)
            if status == SQLITE_DONE { break }
            try check(status, SQLITE_ROW)
            entries.append(try decoder.decode(IndexedEntry.self, from: data(read, at: 0)))
        }
        let hasMore = entries.count > size
        if hasMore { entries.removeLast() }
        return (entries, hasMore)
    }
    /// Hold a read transaction while making an APFS copy-on-write clone, so a
    /// reader always sees one complete generation, even during a watcher commit.
    package func freeze(from source: URL, to destination: URL, generation: UUID?) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        guard try information().metadata.queryGeneration == generation else { return false }
        if clonefile(source.path, destination.path, 0) != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return true
    }
    package func write(_ artifact: IndexArtifact, delta: IndexDelta?) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if let delta {
                guard try information().metadata.queryGeneration == delta.baseGeneration else {
                    throw SearchServiceError.commandFailed(
                        "The filename index changed in another process; refresh before updating it.")
                }
                let remove = try statement("DELETE FROM entries WHERE path=?")
                defer { sqlite3_finalize(remove) }
                for path in delta.removed {
                    sqlite3_bind_text(remove, 1, path, -1, Self.transient)
                    try check(sqlite3_step(remove), SQLITE_DONE)
                    sqlite3_reset(remove)
                    sqlite3_clear_bindings(remove)
                }
            } else {
                try execute("DELETE FROM entries")
            }
            let insert = try statement("INSERT OR REPLACE INTO entries VALUES (?,?,?)")
            defer { sqlite3_finalize(insert) }
            let candidate = try statement(
                "INSERT INTO search_paths(path,normalized) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET normalized=excluded.normalized"
            )
            defer { sqlite3_finalize(candidate) }
            func addCandidate(_ path: String) throws {
                let absolute = (artifact.metadata.scopePath == "/" ? "" : artifact.metadata.scopePath) + "/" + path
                let normalized = absolute.decomposedStringWithCanonicalMapping.folding(
                    options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
                ).decomposedStringWithCanonicalMapping
                sqlite3_bind_text(candidate, 1, path, -1, Self.transient)
                sqlite3_bind_text(candidate, 2, normalized, -1, Self.transient)
                try check(sqlite3_step(candidate), SQLITE_DONE)
                sqlite3_reset(candidate)
                sqlite3_clear_bindings(candidate)
            }
            let version = try statement("SELECT version FROM search_info WHERE id=1")
            let existingVersion = sqlite3_step(version) == SQLITE_ROW ? sqlite3_column_int(version, 0) : 0
            sqlite3_finalize(version)
            if existingVersion < 2 { try execute("DELETE FROM search_paths") }
            if delta != nil {
                // Upgrade old snapshots once, in the same transaction as their
                // first incremental update. Readers of old generations scan.
                let missing = try statement(
                    "SELECT path FROM entries WHERE path NOT IN (SELECT path FROM search_paths)")
                defer { sqlite3_finalize(missing) }
                while true {
                    let status = sqlite3_step(missing)
                    if status == SQLITE_DONE { break }
                    try check(status, SQLITE_ROW)
                    try Task.checkCancellation()
                    try addCandidate(String(cString: sqlite3_column_text(missing, 0)))
                }
            }
            for entry in delta?.upserts ?? artifact.entries {
                try Task.checkCancellation()
                sqlite3_bind_text(insert, 1, entry.relativePath, -1, Self.transient)
                bind(try encoder.encode(entry), to: insert, at: 2)
                bind(try Self.record(entry, root: artifact.metadata.scopePath), to: insert, at: 3)
                try check(sqlite3_step(insert), SQLITE_DONE)
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try addCandidate(entry.relativePath)
            }
            try execute("INSERT OR REPLACE INTO search_info VALUES(1,2)")
            let info = try statement("INSERT OR REPLACE INTO info VALUES (1,?)")
            defer { sqlite3_finalize(info) }
            bind(
                try encoder.encode(
                    IndexArtifact(metadata: artifact.metadata, entries: [], lastEventID: artifact.lastEventID)),
                to: info, at: 1)
            try check(sqlite3_step(info), SQLITE_DONE)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    package static func record(_ entry: IndexedEntry, root: String) throws -> Data {
        struct Record: Encodable {
            let path: String
            let directory: Bool
            let size: Int64?
            let modified: Double?
            let created: Double?
            let tags: [String]?
        }
        return try JSONEncoder().encode(
            Record(
                path: (root == "/" ? "" : root) + "/" + entry.relativePath, directory: entry.kind == .folder,
                size: entry.size, modified: entry.modifiedAt?.timeIntervalSince1970,
                created: entry.createdAt?.timeIntervalSince1970, tags: entry.tags))
    }
    package static func save(_ artifact: IndexArtifact, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if let delta = artifact.delta, isDatabase(url) {
            try IndexDatabase(url, writable: true).write(artifact, delta: delta)
        } else {
            let temporary = URL(fileURLWithPath: url.path + ".pending-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            FileManager.default.createFile(
                atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try IndexDatabase(temporary, writable: true).write(artifact, delta: nil)
            guard rename(temporary.path, url.path) == 0 else {
                throw SearchServiceError.commandFailed("Cannot publish filename index.")
            }
        }
        SnapshotLocations.shared.remember(artifact.metadata, at: url)
    }
}

package final class SnapshotLocations: @unchecked Sendable {
    package static let shared = SnapshotLocations()
    private let lock = NSLock()
    private var locations: [UUID: (UUID?, URL)] = [:]
    package func remember(_ index: ManagedIndex, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        locations[index.id] = (index.queryGeneration, url)
    }
    package func location(_ index: ManagedIndex) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = locations[index.id], value.0 == index.queryGeneration else { return nil }
        return value.1
    }
}
