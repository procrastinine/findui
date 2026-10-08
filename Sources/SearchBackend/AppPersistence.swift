import Foundation

package enum FindUIPaths {
    package static func baseDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["FINDUI_DATA_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("FindUI", isDirectory: true)
    }

    package static func indexesDirectory() -> URL {
        baseDirectory().appendingPathComponent("Indexes", isDirectory: true)
    }

    package static func libraryFileURL() -> URL {
        baseDirectory().appendingPathComponent("library.json")
    }

    package static func indexEntriesFileURL(for indexID: UUID) -> URL {
        indexFile(in: indexesDirectory(), id: indexID)
    }

    package static func indexFile(in directory: URL, id: UUID) -> URL {
        let database = directory.appendingPathComponent("\(id.uuidString).sqlite")
        let legacy = directory.appendingPathComponent("\(id.uuidString).json")
        return !FileManager.default.fileExists(atPath: database.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : database
    }

    package static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: baseDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexesDirectory(), withIntermediateDirectories: true)
    }
}

package actor AppPersistence {
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(baseDirectory: URL = FindUIPaths.baseDirectory()) {
        self.baseDirectory = baseDirectory
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: baseDirectory.appendingPathComponent("Indexes"), withIntermediateDirectories: true)
    }

    nonisolated private func entriesURL(_ id: UUID) -> URL {
        FindUIPaths.indexFile(in: baseDirectory.appendingPathComponent("Indexes"), id: id)
    }
    package nonisolated func indexURL(_ id: UUID) -> URL { entriesURL(id) }

    package func saveIndex(_ artifact: IndexArtifact) throws {
        try ensureDirectories()
        let url = entriesURL(artifact.metadata.id)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SearchServiceError.commandFailed("Cannot create index lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw SearchServiceError.commandFailed("Another process is maintaining this index. Stop that watcher before rebuilding.")
        }
        try artifact.save(url)
    }

    package func loadLibrary() throws -> PersistedLibrary {
        try ensureDirectories()
        let url = baseDirectory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedLibrary()
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(PersistedLibrary.self, from: data)
    }

    package func saveLibrary(_ library: PersistedLibrary) throws {
        try ensureDirectories()
        let data = try encoder.encode(library)
        try data.write(to: baseDirectory.appendingPathComponent("library.json"), options: .atomic)
    }

    package func loadEntries(for indexID: UUID) throws -> [IndexedEntry] {
        try ensureDirectories()
        let url = entriesURL(indexID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        if IndexDatabase.isDatabase(url) { return try IndexArtifact.load(url).entries }
        let data = try Data(contentsOf: url)
        if let artifact = try? decoder.decode(IndexArtifact.self, from: data) { return artifact.entries }
        return try decoder.decode(CancellableIndexEntries.self, from: data).values
    }

    package func saveEntries(_ entries: [IndexedEntry], for indexID: UUID) throws {
        try ensureDirectories()
        let data = try encoder.encode(entries)
        try data.write(to: baseDirectory.appendingPathComponent("Indexes/\(indexID.uuidString).json"), options: .atomic)
    }

    package func deleteEntries(for indexID: UUID) throws {
        let url = entriesURL(indexID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
