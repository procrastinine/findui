@testable import SearchBackend
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FindUI

private actor FixtureTikaClient: TikaFetching {
    let artifact = Data([0x50, 0x4b, 0x03, 0x04]) + Data("test artifact".utf8)
    var requests: [URL] = []
    let badChecksum: Bool
    let delayed: Bool
    let fails: Bool
    init(badChecksum: Bool = false, delayed: Bool = false, fails: Bool = false) {
        self.badChecksum = badChecksum; self.delayed = delayed; self.fails = fails
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if fails { throw URLError(.notConnectedToInternet) }
        if url.pathExtension == "sha512" {
            let hash = badChecksum ? String(repeating: "0", count: 128) : SHA512.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
            return Data((hash + "\n").utf8)
        }
        let versions = url.host == "archive.apache.org" ? ["3.3.1", "3.3.2", "2.9.4", "4.1.0", "3.4.0-beta"] : ["4.1.0", "3.3.2"]
        return Data(versions.map { "<a href=\"\($0)/\">\($0)/</a>" }.joined().utf8)
    }
    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        requests.append(url)
        if delayed { progress(0.25); try await Task.sleep(for: .seconds(20)) }
        if fails { throw URLError(.networkConnectionLost) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tika-download-\(UUID())")
        try artifact.write(to: file); progress(1)
        return file
    }
}

private func tikaTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-tika-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func tikaJavaCheckUnderstandsLegacyAndModernRuntimeVersions() {
    #expect(TikaRuntime.majorVersion(in: "openjdk version \"24.0.1\" 2025-04-15\nOpenJDK Runtime Environment") == 24)
    #expect(TikaRuntime.majorVersion(in: "java version \"11.0.26\"\n") == 11)
    #expect(TikaRuntime.majorVersion(in: "java version \"1.8.0_382\"\n") == 8)
    #expect(TikaRuntime.majorVersion(in: "Unable to locate a Java Runtime") == nil)
}

@Test func tikaCatalogIncludesOnlyCompatibleStableVersionsAndSortsNumerically() throws {
    let html = #"<a href="3.3.2/">x</a><a href="3.10.0/">x</a><a href="3.3.2/">duplicate</a><a href="4.1.0/">x</a><a href="3.4.0-beta/">x</a><a href="../3.3.9/">x</a>"#
    #expect(TikaRelease.parseCatalog(Data(html.utf8), archived: false).map(\.version) == ["3.10.0", "3.3.2"])
    for input in ["../../outside", "3.3.2/../x", "3.3.02", "4.1.0", "3.3.2\n"] { #expect(!TikaRelease.isCompatible(input)) }
    let hash = String(repeating: "aF", count: 64)
    #expect(try TikaManager.parseChecksum(Data("SHA512 (tika-app.jar) = \(hash)\n".utf8)) == hash.lowercased())
    #expect(throws: (any Error).self) { try TikaManager.parseChecksum(Data("not a checksum".utf8)) }
    #expect(!TikaHTTPClient.isOfficial(URL(string: "http://downloads.apache.org/tika/")))
    #expect(!TikaHTTPClient.isOfficial(URL(string: "https://downloads.apache.org.evil.test/tika/")))
}

@Test func tikaVerifiedInstallSelectionSwitchingRemovalAndOfflineListing() async throws {
    let root = try tikaTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let client = FixtureTikaClient(), manager = TikaManager(directory: root, client: FixtureTikaClient())
    let store = TikaManager(directory: root, client: client)
    #expect(try store.status().installed.isEmpty)
    #expect(await client.requests.isEmpty)
    let catalog = try await store.refresh()
    #expect(catalog.available.map(\.version) == ["3.3.2", "3.3.1"])
    #expect(catalog.available[0].archived == false)
    #expect(catalog.available[1].archived == true)
    for release in catalog.available { _ = try await store.install(release) }
    let count = await client.requests.count
    _ = try await store.install(catalog.available[0])
    #expect(await client.requests.count == count, "Installing an existing version must not download it again")
    try store.select("3.3.2")
    #expect(manager.selectedJar == store.jarURL("3.3.2"), "Fresh processes read the same selection")
    try store.select("3.3.1")
    #expect(manager.selectedJar == store.jarURL("3.3.1"))
    try store.remove("3.3.2")
    #expect(try manager.status().installed.map(\.version) == ["3.3.1"])
    try store.remove("3.3.1")
    #expect(manager.selectedJar == nil)
    #expect(manager.hasSelection)
    #expect(try manager.status().selectedVersion == nil)
    #expect(throws: (any Error).self) { try store.select("3.3.2") }
    #expect(throws: (any Error).self) { try store.remove("../outside") }
    let offline = TikaManager(directory: root, client: FixtureTikaClient(fails: true))
    await #expect(throws: (any Error).self) { try await offline.refresh() }
    #expect(try offline.status().available.count == 2, "Failed refresh preserves the cached catalog")
}

@Test func tikaRejectsCorruptDownloadsAndKeepsExistingSelection() async throws {
    let root = try tikaTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TikaManager(directory: root, client: FixtureTikaClient())
    _ = try await store.install(.init(version: "3.3.1", archived: true)); try store.select("3.3.1")
    let broken = TikaManager(directory: root, client: FixtureTikaClient(badChecksum: true))
    await #expect(throws: (any Error).self) { try await broken.install(.init(version: "3.3.2", archived: false)) }
    #expect(try store.status().selectedVersion == "3.3.1")
    #expect(try store.status().installed.map(\.version) == ["3.3.1"])
    #expect(!FileManager.default.fileExists(atPath: store.jarURL("3.3.2").path))
    await #expect(throws: (any Error).self) { try await broken.install(.init(version: "../outside", archived: false)) }
}

@Test func tikaDownloadCancellationReleasesLockWithoutPublishingPartialVersion() async throws {
    let root = try tikaTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let client = FixtureTikaClient(delayed: true), release = TikaRelease(version: "3.3.2", archived: false)
    let store = TikaManager(directory: root, client: client)
    let task = Task { try await store.install(release) }
    let deadline = Date().addingTimeInterval(3)
    while await client.requests.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await client.requests.count == 2)
    #expect(throws: (any Error).self) { try store.select(nil) }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try store.status().installed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.jarURL(release.version).path))
    // A cancelled install does not strand the store lock.
    try store.select(nil)
    let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!contents.contains { $0.hasPrefix(".install-") })
}

@Test func tikaCannotRemoveVersionUsedByAnotherProcess() async throws {
    let root = try tikaTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TikaManager(directory: root, client: FixtureTikaClient())
    _ = try await store.install(.init(version: "3.3.2", archived: false)); try store.select("3.3.2")
    let file = root.appendingPathComponent("3.3.2/.in-use")
    let descriptor = open(file.path, O_CREAT | O_RDWR, 0o600)
    defer { close(descriptor) }
    #expect(descriptor >= 0)
    #expect(flock(descriptor, LOCK_SH | LOCK_NB) == 0)
    #expect(throws: (any Error).self) { try store.remove("3.3.2") }
    #expect(try store.status().selectedVersion == "3.3.2")
    #expect(flock(descriptor, LOCK_UN) == 0)
    try store.remove("3.3.2")
    #expect(try store.status().installed.isEmpty)
}

@Test @MainActor func tikaSettingsKeepsProgressAndCancellationInTheSharedManager() async throws {
    let root = try tikaTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let client = FixtureTikaClient(delayed: true)
    let model = TikaSettingsModel(manager: TikaManager(directory: root, client: client))
    #expect(await client.requests.isEmpty, "Opening Settings must not check or download automatically")
    model.download(.init(version: "3.3.2", archived: false))
    #expect(model.busy && model.downloading && model.progress == nil,
            "Show an indeterminate download bar before byte progress arrives")
    let deadline = Date().addingTimeInterval(3)
    while model.progress == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.busy && model.progress == 0.25)
    model.cancel()
    while model.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.busy && !model.downloading)
    #expect(model.progress == nil)
    #expect(model.status?.installed.isEmpty == true)
    #expect(model.error == nil)
}

@Test func documentConversionIsOptInAndChoicesSurviveSaveGroupsAndCommands() throws {
    #expect(SearchRefinements().extraction == nil)
    var enabled = SearchRefinements(); enabled.extraction = .init()
    #expect(enabled.extraction == SearchExtractionOptions())
    #expect(enabled.extraction?.documents == true)
    #expect(enabled.extraction?.archives == false)
    #expect(try JSONDecoder().decode(SearchExtractionOptions.self, from: Data("{}".utf8)).archives == false)
    var off = enabled; off.extraction = nil
    #expect(try JSONDecoder().decode(SearchRefinements.self, from: JSONEncoder().encode(off)).extraction == nil)
    #expect(try JSONDecoder().decode(SearchRefinements.self, from: JSONEncoder().encode(enabled)).extraction != nil)
    var request = SearchRequest(query: "needle", mode: .contents, scope: FileManager.default.temporaryDirectory,
        includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements = enabled
    try request.state.promoteToRules()
    #expect(request.refinements.extraction != nil)
    let imported = try CLICommandParser.parse("rg --fixed-strings needle /tmp", currentDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(imported.refinements.extraction == nil, "Import must not expand a plain rg command to document search")
}

@Test func unavailableReadersDoNotBlockTextMatchesAndReportSkippedDocuments() async throws {
    let root = try tikaTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try Data("needle\n".utf8).write(to: root.appendingPathComponent("found.txt"))
    try Data("%PDF-placeholder".utf8).write(to: root.appendingPathComponent("report.pdf"))
    let detected = Toolchain.resolve()
    let missing = Toolchain(fd: detected.fd, fzf: detected.fzf, rg: detected.rg, find: detected.find, mdfind: nil)
    var request = SearchRequest(query: "needle", mode: .contents, scope: root,
        includeHidden: true, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.extraction = .init()
    let results = try await SearchService(tools: missing).search(request: request)
    #expect(results.results.map(\.name) == ["found.txt"])
    #expect(results.warning?.contains("report.pdf") == true)
    #expect(results.warning?.contains("Settings") == true)
    let plan = try SearchExtractionOptions().plan(tools: missing)
    #expect(plan["rga"] is NSNull)
    #expect(plan["tikaJar"] is NSNull)
}
