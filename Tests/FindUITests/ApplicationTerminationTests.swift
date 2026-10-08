import AppKit
import Testing
@testable import SearchBackend
@testable import FindUI

@Test @MainActor func quitFinishesCleanupWithoutEnteringAModalLoop() async throws {
    var stopped = 0, cleaned = 0, terminated = 0
    let termination = ApplicationTermination(gracePeriod: .seconds(2), stop: { stopped += 1 }, cleanup: {
        await Task.yield()
        cleaned += 1
    }, terminate: { terminated += 1 })
    #expect(termination.request() == .terminateCancel)
    #expect(termination.request() == .terminateCancel)
    #expect(stopped == 1)
    for _ in 0..<100 where terminated == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(cleaned == 1 && terminated == 1)
    #expect(termination.request() == .terminateNow)
    #expect(stopped == 1)
}

@Test @MainActor func stalledCleanupCannotKeepTheAppAliveOrTerminateTwice() async throws {
    var continuation: CheckedContinuation<Void, Never>?
    var terminated = 0
    let termination = ApplicationTermination(gracePeriod: .milliseconds(50), stop: {}, cleanup: {
        await withCheckedContinuation { continuation = $0 }
    }, terminate: { terminated += 1 })
    #expect(termination.request() == .terminateCancel)
    for _ in 0..<100 where terminated == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(terminated == 1)
    #expect(termination.request() == .terminateNow)
    continuation?.resume()
    for _ in 0..<10 { await Task.yield() }
    #expect(terminated == 1)
}

@Test @MainActor func libraryShutdownSavesSettingsAndReleasesAllIndexWriters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-shutdown-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AppPersistence(baseDirectory: root.appendingPathComponent("data"))
    let library = SearchLibraryStore(persistence: persistence)
    _ = try await library.load()
    for name in ["first", "second"] {
        let files = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: files.appendingPathComponent("file.txt"))
        var index = try await IndexService().buildIndex(name: name, scope: files, includeHidden: false).metadata
        index.automaticRefresh = true
        library.value.managedIndexes.append(index)
    }
    library.save()
    let indexes = library.value.managedIndexes
    for _ in 0..<200 {
        if indexes.allSatisfy({ FileManager.default.fileExists(atPath: persistence.indexURL($0.id).path) }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(indexes.allSatisfy { FileManager.default.fileExists(atPath: persistence.indexURL($0.id).path) })
    library.value.showIcons = false
    library.save()
    await library.shutdown()
    #expect(try await persistence.loadLibrary().showIcons == false)
    // A late save must not recreate background maintenance during quit.
    library.save()
    await library.flush()
    for index in indexes {
        let descriptor = open(persistence.indexURL(index.id).path + ".lock", O_RDWR)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            close(descriptor)
        }
    }
}
