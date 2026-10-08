import CryptoKit
import Foundation
import SearchCore

package enum SnapshotQueryError: LocalizedError {
    case generationChanged
    package var errorDescription: String? { "Snapshot advanced before the query started; retry the search." }
}

/// A generation is prepared once across windows and CLI processes. Its shared
/// lock keeps the immutable input alive while a newer generation is published.
package final class PreparedSnapshot: @unchecked Sendable {
    package let source: URL
    package let byPath: [String: IndexedEntry]
    private let lease: FileHandle
    private let database: IndexDatabase?
    private let root: String
    package init(source: URL, byPath: [String: IndexedEntry], lease: FileHandle, database: IndexDatabase? = nil, root: String = "") {
        self.source = source; self.byPath = byPath; self.lease = lease; self.database = database; self.root = root
    }
    package func entry(_ path: String) -> IndexedEntry? {
        try? recordedEntry(path)
    }
    /// Diagnostics must distinguish an absent path from an unreadable record.
    package func recordedEntry(_ path: String) throws -> IndexedEntry? {
        if let value = byPath[path] { return value }
        guard let database, path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        return try database.entry(path: String(path.dropFirst(root == "/" ? 1 : root.count + 1)))
    }
    package var querySource: QuerySource {
        var value = QuerySource(); value.kind = .snapshot; value.path = source.path
        value.records = database == nil; value.generation = source.deletingPathExtension().lastPathComponent
        return value
    }
    deinit { try? lease.close() }
}

package actor SnapshotQueryCache {
    package static let shared = SnapshotQueryCache()
    private let directory: URL
    private var prepared: [String: PreparedSnapshot] = [:]
    private var order: [String] = []
    private struct LegacyGeneration { let entries: [IndexedEntry]; let address: UInt; let scope: String; let key: String }
    private var legacy: [UUID: LegacyGeneration] = [:]
    package init(directory: URL = ProcessInfo.processInfo.environment["FINDUI_QUERY_CACHE_DIRECTORY"].map { URL(fileURLWithPath:$0) }
         ?? FileManager.default.temporaryDirectory.appendingPathComponent("findui-query-generations")) {
        self.directory = directory
    }
    private struct Record: Encodable {
        let path: String
        let directory: Bool
        let size: Int64?
        let modified: Double?
        let created: Double?
        let tags: [String]?
    }
    package func prepare(index: ManagedIndex, entries: [IndexedEntry]) throws -> PreparedSnapshot {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Older snapshots have no generation ID. Include the entries in that
        // one-time migration key, never trust a seconds-resolution timestamp.
        var identity = Data("v2|\(index.id)|\(index.scopePath)|\(index.queryGeneration?.uuidString ?? "legacy")".utf8)
        let key: String
        if index.queryGeneration == nil {
            let address = entries.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            // Retain the immutable array to prevent address reuse. Mutation
            // produces a new COW buffer and therefore a fresh content hash.
            if let previous = legacy[index.id], previous.address == address,
               previous.entries.count == entries.count, previous.scope == index.scopePath {
                key = previous.key
            } else {
                identity.append(try encoder.encode(entries))
                key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
                if legacy.count >= 4 { legacy.removeAll() }
                legacy[index.id] = LegacyGeneration(entries: entries, address: address, scope: index.scopePath, key: key)
            }
        } else { key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined() }
        if let value = prepared[key] { return value }
        let root = directory.appendingPathComponent(index.id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stored = Toolchain.locateContentWorker() == nil ? nil : SnapshotLocations.shared.location(index)
        let source = root.appendingPathComponent(key + (stored == nil ? ".records" : ".sqlite"))
        let fd = open(source.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SearchServiceError.commandFailed("Cannot lock snapshot query data.") }
        let lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_SH) == 0 else { throw SearchServiceError.commandFailed("Cannot lease snapshot query data.") }
        // Serialize first publication on a separate lock. Upgrading the lease
        // would deadlock concurrent first readers once one retained LOCK_SH.
        var writer: Int32 = -1
        if !FileManager.default.fileExists(atPath: source.path) {
            writer = open(source.path + ".build-lock", O_CREAT | O_RDWR, 0o600)
            guard writer >= 0, flock(writer, LOCK_EX) == 0 else {
                if writer >= 0 { close(writer) }
                throw SearchServiceError.commandFailed("Cannot prepare snapshot query data.")
            }
        }
        defer { if writer >= 0 { close(writer) } }
        if let stored {
            if !FileManager.default.fileExists(atPath: source.path) {
                let database = try IndexDatabase(stored)
                if try database.freeze(from: stored, to: source, generation: index.queryGeneration) {
                    let value = PreparedSnapshot(source: source, byPath: [:], lease: lease, database: try IndexDatabase(source), root: index.scopePath)
                    retain(value, key: key, root: root); return value
                }
                // Reconstruct only when the requested generation raced a commit.
                guard entries.count == index.entryCount else {
                    throw SnapshotQueryError.generationChanged
                }
                try IndexDatabase.save(IndexArtifact(metadata: index, entries: entries), to: source)
                SnapshotLocations.shared.remember(index, at: stored)
                let value = PreparedSnapshot(source: source, byPath: [:], lease: lease, database: try IndexDatabase(source), root: index.scopePath)
                retain(value, key: key, root: root); return value
            } else {
                let value = PreparedSnapshot(source: source, byPath: [:], lease: lease, database: try IndexDatabase(source), root: index.scopePath)
                retain(value, key: key, root: root); return value
            }
        }
        var byPath: [String: IndexedEntry] = [:]; byPath.reserveCapacity(entries.count)
        let needsWrite = !FileManager.default.fileExists(atPath: source.path)
        let staging = root.appendingPathComponent(key + ".pending-" + UUID().uuidString)
        var handle: FileHandle?
        if needsWrite {
            FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handle = try FileHandle(forWritingTo: staging)
        }
        defer { try? handle?.close(); try? FileManager.default.removeItem(at: staging) }
        var buffer = Data(); buffer.reserveCapacity(256 * 1024)
        for entry in entries {
            try Task.checkCancellation()
            let url = index.scopeURL.appendingPathComponent(entry.relativePath).standardizedFileURL
            guard SearchPath.contains(url, in: index.scopeURL) else { continue }
            byPath[url.path] = entry
            if let handle {
                buffer.append(try encoder.encode(Record(path: url.path, directory: entry.kind == .folder, size: entry.size,
                    modified: entry.modifiedAt?.timeIntervalSince1970, created: entry.createdAt?.timeIntervalSince1970, tags: entry.tags)))
                buffer.append(0)
                if buffer.count >= 256 * 1024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
        }
        if let handle {
            try handle.write(contentsOf: buffer); try handle.close()
            guard rename(staging.path, source.path) == 0 else { throw SearchServiceError.commandFailed("Cannot publish snapshot query data.") }
        }
        guard flock(fd, LOCK_SH) == 0 else { throw SearchServiceError.commandFailed("Cannot lease snapshot query data.") }
        let value = PreparedSnapshot(source: source, byPath: byPath, lease: lease)
        retain(value, key: key, root: root)
        return value
    }
    private func retain(_ value: PreparedSnapshot, key: String, root: URL) {
        prepared[key] = value; order.append(key)
        // Retain only a few resident generations. Active queries hold their own
        // lease and old on-disk generations are reclaimed only without readers.
        while order.count > 4 { prepared.removeValue(forKey: order.removeFirst()) }
        for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where ["records", "sqlite"].contains(old.pathExtension) && old != value.source {
            let lock = open(old.path + ".lock", O_CREAT | O_RDWR, 0o600)
            if lock >= 0 {
                if flock(lock, LOCK_EX | LOCK_NB) == 0 { try? FileManager.default.removeItem(at: old) }
                close(lock)
            }
        }
    }
}
