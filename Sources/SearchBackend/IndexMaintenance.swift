import CoreServices
import Foundation

package enum IndexMaintenanceClock { package static var currentEventID: UInt64 { FSEventsGetCurrentEventId() } }

package struct IndexConfiguration: Codable, Hashable, Sendable {
    package var id: UUID?
    package var name: String
    package var scopePath: String
    package var includeHidden: Bool
    package var traversal: SearchTraversalOptions
    package init(_ index: ManagedIndex) {
        id = index.id; name = index.name; scopePath = index.scopePath
        includeHidden = index.includeHidden; traversal = index.traversal ?? .init()
    }
    package enum CodingKeys: String, CodingKey { case id, name, scopePath, includeHidden, traversal }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        scopePath = try c.decode(String.self, forKey: .scopePath)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: scopePath).lastPathComponent
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? true
        traversal = try c.decodeIfPresent(SearchTraversalOptions.self, forKey: .traversal) ?? .init()
    }
}

package struct IndexArtifact: Codable, Sendable {
    package var metadata: ManagedIndex
    package var entries: [IndexedEntry]
    package var lastEventID: UInt64?
    package var catalog: [String: IndexedEntry]? = nil
    package var delta: IndexDelta? = nil
    package enum CodingKeys: String, CodingKey { case metadata, entries, lastEventID }
    package static func load(_ url: URL, includeEntries: Bool = true, legacyMetadata: ManagedIndex? = nil) throws -> Self {
        try Task.checkCancellation()
        if IndexDatabase.isDatabase(url) {
            let artifact = try IndexDatabase(url).load(includeEntries: includeEntries)
            SnapshotLocations.shared.remember(artifact.metadata, at: url)
            return artifact
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        do { return try decoder.decode(Self.self, from: data) }
        catch {
            guard let legacyMetadata else { throw error }
            return try Self(metadata: legacyMetadata, entries: decoder.decode(CancellableIndexEntries.self, from: data).values)
        }
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try c.decode(ManagedIndex.self, forKey: .metadata)
        entries = try c.decode(CancellableIndexEntries.self, forKey: .entries).values
        lastEventID = try c.decodeIfPresent(UInt64.self, forKey: .lastEventID)
    }
    package func save(_ url: URL) throws { try IndexDatabase.save(self, to: url) }
    package init(metadata: ManagedIndex, entries: [IndexedEntry], lastEventID: UInt64? = nil, catalog: [String: IndexedEntry]? = nil, delta: IndexDelta? = nil) {
        self.metadata = metadata
        self.entries = entries
        self.lastEventID = lastEventID
        self.catalog = catalog
        self.delta = delta
    }


}

package struct CancellableIndexEntries: Decodable {
    package let values: [IndexedEntry]
    package init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var entries: [IndexedEntry] = []
        while !c.isAtEnd { try Task.checkCancellation(); entries.append(try c.decode(IndexedEntry.self)) }
        values = entries
    }
}

package struct IndexChange: Sendable { package let path: String; package let recursive: Bool
    package init(path: String, recursive: Bool) {
        self.path = path
        self.recursive = recursive
    }
}

/// FSEvents is an OS service accessible to headless processes. The GUI only
/// chooses configuration and displays generations produced by this service.
package final class IndexEventStream: @unchecked Sendable {
    private final class CallbackBox {
        let receive: @Sendable ([IndexChange], Bool, UInt64) -> Void
        init(_ receive: @escaping @Sendable ([IndexChange], Bool, UInt64) -> Void) { self.receive = receive }
    }
    private var stream: FSEventStreamRef?
    package init(root: URL, since: UInt64?, receive: @escaping @Sendable ([IndexChange], Bool, UInt64) -> Void) throws {
        let box = CallbackBox(receive)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { raw in
            guard let raw else { return nil }
            return UnsafeRawPointer(Unmanaged<CallbackBox>.fromOpaque(raw).retain().toOpaque())
        }, release: { raw in
            if let raw { Unmanaged<CallbackBox>.fromOpaque(raw).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, raw, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(raw, to: NSArray.self) as! [String]
            if ProcessInfo.processInfo.environment["FINDUI_INDEX_TRACE"] == "1" {
                HeadlessCLI.diagnostic("index-events: " + paths.joined(separator: "\n"))
            }
            var changes: [IndexChange] = []; var full = false; var last: UInt64 = 0
            for i in 0..<count {
                let f = flags[i]; last = max(last, ids[i])
                let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
                full = full || f & lost != 0
                if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                let directory = f & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                let structural = f & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
                changes.append(.init(path: paths[i], recursive: directory && structural))
            }
            owner.receive(changes, full, last)
        }
        let options = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
            since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, options) else {
            throw SearchServiceError.commandFailed("Cannot watch \(root.path)")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "FindUI.index-events"))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
            throw SearchServiceError.commandFailed("Cannot start filesystem notifications for \(root.path)")
        }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

package actor IndexMaintenance {
    package let configuration: IndexConfiguration
    package let output: URL
    private let service: IndexService
    private let published: @Sendable (IndexArtifact) async -> Void
    private let failed: @Sendable (String) async -> Void
    private var artifact: IndexArtifact?
    private var watcher: IndexEventStream?
    private var pending: [String: Bool] = [:]
    private var needsFullScan = false
    private var newestEvent: UInt64 = 0
    private var scheduled: Task<Void, Never>?
    private var working = false
    private var stopped = false
    private var outputLock: FileHandle?

    package init(configuration: IndexConfiguration, output: URL, service: IndexService = .init(),
         published: @escaping @Sendable (IndexArtifact) async -> Void = { _ in },
         failed: @escaping @Sendable (String) async -> Void = { HeadlessCLI.diagnostic($0) }) {
        self.configuration = configuration; self.output = output; self.service = service
        self.published = published; self.failed = failed
    }
    private func acquireLock() throws {
        guard outputLock == nil else { return }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(output.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SearchServiceError.commandFailed("Cannot create index lock.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw SearchServiceError.commandFailed("Another process is maintaining this index: \(output.path)")
        }
        outputLock = handle
    }
    package func start() async throws {
        try acquireLock()
        try configuration.traversal.validate()
        let root = URL(fileURLWithPath: configuration.scopePath).standardizedFileURL
        if let saved = try? IndexArtifact.load(output), saved.metadata.scopePath == root.path,
           saved.metadata.includeHidden == configuration.includeHidden,
           saved.metadata.traversal?.normalized == configuration.traversal.effective(for: saved.metadata.engineName) { artifact = saved }
        watcher = try IndexEventStream(root: root, since: artifact?.lastEventID) { [weak self] changes, full, id in
            Task { await self?.enqueue(changes, full: full, event: id) }
        }
        if artifact == nil || artifact?.lastEventID == nil { _ = try await rebuild() }
        else if let artifact { await published(artifact) }
    }
    package func stop() async {
        stopped = true; scheduled?.cancel(); watcher = nil
        // A cancelled/in-flight refresh checks stopped before it publishes.
        await scheduled?.value
        scheduled = nil
        try? outputLock?.close(); outputLock = nil
    }
    @discardableResult package func rebuild() async throws -> IndexArtifact {
        try acquireLock()
        working = true
        defer { working = false; scheduleIfNeeded() }
        let before = FSEventsGetCurrentEventId()
        let build = try await service.buildIndex(id: configuration.id ?? artifact?.metadata.id ?? UUID(),
            name: configuration.name, scope: URL(fileURLWithPath: configuration.scopePath),
            includeHidden: configuration.includeHidden, traversal: configuration.traversal)
        var metadata = build.metadata
        metadata.createdAt = artifact?.metadata.createdAt ?? metadata.createdAt
        metadata.automaticRefresh = artifact?.metadata.automaticRefresh
        let next = IndexArtifact(metadata: metadata, entries: build.entries, lastEventID: before, catalog: Dictionary(uniqueKeysWithValues: build.entries.map { ($0.relativePath, $0) }))
        try await commit(next)
        return next
    }
    package func enqueue(_ changes: [IndexChange], full: Bool, event: UInt64) {
        guard !stopped else { return }
        newestEvent = max(newestEvent, event); needsFullScan = needsFullScan || full
        let ignoredOutput = output.standardizedFileURL.path
        for change in changes {
            // Our artifact and lock must never cause an index/write feedback loop.
            if change.path == ignoredOutput || change.path.hasPrefix(ignoredOutput + ".")
                || ["-journal", "-wal", "-shm"].contains(where: { change.path == ignoredOutput + $0 }) { continue }
            if !change.recursive && [output.deletingLastPathComponent().path, configuration.scopePath].contains(change.path) { continue }
            pending[change.path] = (pending[change.path] ?? false) || change.recursive
            if [".gitignore", ".ignore", ".fdignore", ".rgignore"].contains(URL(fileURLWithPath: change.path).lastPathComponent) {
                needsFullScan = true
            }
        }
        scheduleIfNeeded()
    }
    private func scheduleIfNeeded() {
        guard !stopped, !working, scheduled == nil, needsFullScan || !pending.isEmpty else { return }
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)); await self?.refreshPending() } catch { }
        }
    }
    private func refreshPending() async {
        guard !stopped, let old = artifact else { scheduled = nil; return }
        let changes = pending.map { IndexChange(path: $0.key, recursive: $0.value) }
        let full = needsFullScan, event = newestEvent
        pending.removeAll(); needsFullScan = false; working = true
        defer { working = false; scheduled = nil; scheduleIfNeeded() }
        do {
            if full {
                _ = try await rebuild()
            } else {
                let updated = try await service.refreshIndex(old, changes: changes)
                try await commit(IndexArtifact(metadata: updated.metadata, entries: updated.entries,
                                               lastEventID: max(old.lastEventID ?? 0, event), catalog: updated.catalog, delta: updated.delta))
            }
        } catch is CancellationError { }
        catch { await failed("Index update failed; previous snapshot retained: \(error.localizedDescription)") }
    }
    private func commit(_ next: IndexArtifact) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try next.save(output)
        artifact = next
        await published(next)
    }
}
