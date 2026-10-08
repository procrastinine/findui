import Foundation
import SearchCore

/// The GUI and CLI manage the same small, inspectable file. Updates lock and
/// atomically replace it; loading configuration never executes a reader.
package struct ReaderConfiguration: Sendable {
    package static let didChange = Notification.Name("FindUIReaderConfigurationDidChange")
    package let location: URL
    package init(location: URL? = nil) {
        self.location =
            location ?? ProcessInfo.processInfo.environment["FINDUI_READER_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FindUI/readers.json")
    }
    package func load() throws -> [ReaderAdapter] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let data = try Data(contentsOf: location)
        guard data.count <= 1_048_576 else {
            throw SearchServiceError.commandFailed("Reader configuration exceeds 1 MiB.")
        }
        let readers = try JSONDecoder().decode([ReaderAdapter].self, from: data)
        try Self.validate(readers)
        return readers
    }
    package static func validate(_ readers: [ReaderAdapter]) throws {
        guard readers.count <= 64, Set(readers.map(\.id)).count == readers.count else {
            throw SearchServiceError.commandFailed("Use unique reader IDs and no more than 64 readers.")
        }
        var claimed = Set<String>()
        for reader in readers {
            try reader.validate()
            for ext in reader.extensions where reader.enabled {
                guard claimed.insert(ext).inserted else {
                    throw SearchServiceError.commandFailed(
                        "More than one enabled reader handles .\(ext). Choose one reader for each extension.")
                }
            }
        }
    }
    @discardableResult package func update(_ change: (inout [ReaderAdapter]) throws -> Void) throws -> [ReaderAdapter] {
        let parent = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let descriptor = open(location.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SearchServiceError.commandFailed("Cannot open reader configuration lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SearchServiceError.commandFailed("Reader settings are being changed by another process. Try again.")
        }
        var readers = try load()
        try change(&readers)
        try Self.validate(readers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(readers).write(to: location, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return readers
    }
}
