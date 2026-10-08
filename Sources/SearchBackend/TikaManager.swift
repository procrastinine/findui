import CryptoKit
import Darwin
import Foundation

package enum TikaRuntime {
    package static func majorVersion(in output: String) -> Int? {
        let pattern = try! NSRegularExpression(pattern: #"(?:java|openjdk)\s+(?:version\s+)?"(?:1\.)?([0-9]+)"#)
        guard let match = pattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[range])
    }
    package static func installedMajorVersion() async -> Int? {
        let path = Toolchain.resolve().searchPath
        // Check registration first, so /usr/bin/java cannot open macOS's Java
        // installer dialog. Then inspect the runtime actually used by Tika.
        let home = try? await ProcessRunner.run(spec: .init(executable: URL(fileURLWithPath: "/usr/libexec/java_home"),
            arguments: ["-F"]), pathOverride: path)
        guard home?.exitCode == 0 else { return nil }
        let java = try? await ProcessRunner.run(spec: .init(executable: URL(fileURLWithPath: "/usr/bin/java"),
            arguments: ["-version"]), pathOverride: path)
        guard let java, java.exitCode == 0 else { return nil }
        return majorVersion(in: java.stderr + java.stdout)
    }
}

package struct TikaRelease: Codable, Hashable, Identifiable, Sendable {
    package let version: String
    package let archived: Bool
    package var id: String { version }
    package var downloadURL: URL {
        let base = archived ? "https://archive.apache.org/dist/tika" : "https://downloads.apache.org/tika"
        return URL(string: "\(base)/\(version)/tika-app-\(version).jar")!
    }
    // The extraction adapter deliberately uses the supported 3.x Office parser
    // API. 4.x has a different distribution and configuration format.
    package static func isCompatible(_ version: String) -> Bool {
        version.range(of: #"\A3\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\z"#, options: .regularExpression) != nil
    }
    package static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        a.version.compare(b.version, options: .numeric) == .orderedDescending
    }
    package static func parseCatalog(_ data: Data, archived: Bool) -> [Self] {
        let html = String(decoding: data, as: UTF8.self)
        let pattern = try! NSRegularExpression(pattern: #"href=["'](3\.[0-9]+\.[0-9]+)/["']"#)
        let versions = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            let version = String(html[range]); return isCompatible(version) ? version : nil
        }
        return Set(versions).map { Self(version: $0, archived: archived) }.sorted(by: newestFirst)
    }
    package init(version: String, archived: Bool) {
        self.version = version
        self.archived = archived
    }

}

package struct InstalledTika: Codable, Identifiable, Sendable {
    package let version: String
    package let sha512: String
    package let source: URL
    package let installedAt: Date
    package let bytes: Int64
    package var id: String { version }
    package init(version: String, sha512: String, source: URL, installedAt: Date, bytes: Int64) {
        self.version = version
        self.sha512 = sha512
        self.source = source
        self.installedAt = installedAt
        self.bytes = bytes
    }

}

package struct TikaStatus: Codable, Sendable {
    package let installed: [InstalledTika]
    package let selectedVersion: String?
    package let available: [TikaRelease]
    package let checkedAt: Date?
    package let directory: URL
    package init(installed: [InstalledTika], selectedVersion: String? = nil, available: [TikaRelease], checkedAt: Date? = nil, directory: URL) {
        self.installed = installed
        self.selectedVersion = selectedVersion
        self.available = available
        self.checkedAt = checkedAt
        self.directory = directory
    }

}

package protocol TikaFetching: Sendable {
    func data(from url: URL) async throws -> Data
    /// The caller owns the returned temporary file, including on cancellation.
    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

private final class TikaDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var file: URL?
    private var failure: (any Error)?
    private var cancelled = false

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func download(from url: URL, configuration: URLSessionConfiguration) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                // The async download convenience API does not deliver the
                // download delegate's byte updates. Use a delegate-owned task.
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            let task = self.lock.withLock { self.cancelled = true; return self.task }
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try TikaHTTPClient.validate(downloadTask.response)
            // URLSession removes its file when this callback returns. Move it
            // before resuming the caller, who then owns its cleanup.
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("findui-tika-download-\(UUID())")
            try FileManager.default.moveItem(at: location, to: saved)
            lock.withLock { file = saved }
        } catch { lock.withLock { failure = error } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        let file = self.file
        let error: (any Error)? = cancelled ? CancellationError() : (error ?? failure)
        self.continuation = nil; self.file = nil; self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: error)
        } else if let file {
            progress(1)
            continuation.resume(returning: file)
        } else {
            continuation.resume(throwing: TikaManager.failure("The Tika download did not produce a file. Please try again."))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(TikaHTTPClient.isOfficial(request.url) ? request : nil)
    }
}

package struct TikaHTTPClient: TikaFetching {
    package static func isOfficial(_ url: URL?) -> Bool {
        url?.scheme == "https" && ["downloads.apache.org", "archive.apache.org"].contains(url?.host ?? "")
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 900
        return config
    }
    fileprivate static func validate(_ response: URLResponse?) throws {
        guard Self.isOfficial(response?.url), let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TikaManager.failure("Apache could not supply this download. Check for updates and try again.")
        }
    }
    package func data(from url: URL) async throws -> Data {
        guard Self.isOfficial(url) else { throw TikaManager.failure("Tika downloads must come from Apache over HTTPS.") }
        let session = URLSession(configuration: configuration()); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url, delegate: TikaDownloadDelegate(progress: { _ in }))
        try Self.validate(response)
        guard data.count < 4 * 1024 * 1024 else { throw TikaManager.failure("Apache returned an unexpectedly large version list or checksum.") }
        return data
    }
    package func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard Self.isOfficial(url) else { throw TikaManager.failure("Tika downloads must come from Apache over HTTPS.") }
        return try await TikaDownloadDelegate(progress: progress).download(from: url, configuration: configuration())
    }
    package init() {

    }

}

/// Owns downloads, installed versions and selection for both Settings and the
/// headless CLI. Opening the app or reading this store never makes a request.
package struct TikaManager: Sendable {
    package static let toolsDidChange = Notification.Name("FindUIToolsDidChange")
    package static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["FINDUI_TIKA_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FindUI/Tools/Tika", isDirectory: true)
    }
    package let directory: URL
    package let client: any TikaFetching
    package init(directory: URL = Self.defaultDirectory, client: any TikaFetching = TikaHTTPClient()) {
        self.directory = directory; self.client = client
    }
    private struct Selection: Codable { let version: String? }
    private struct Catalog: Codable { let releases: [TikaRelease]; let checkedAt: Date }
    private var selectionURL: URL { directory.appendingPathComponent("selected.json") }
    private var catalogURL: URL { directory.appendingPathComponent("releases.json") }
    package var hasSelection: Bool { FileManager.default.fileExists(atPath: selectionURL.path) }
    package func status() throws -> TikaStatus {
        let fm = FileManager.default
        let selection = hasSelection ? try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL)) : nil
        let catalog = try? JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        let installed = folders.compactMap { folder -> InstalledTika? in
            guard TikaRelease.isCompatible(folder.lastPathComponent),
                  (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let manifest = try? JSONDecoder().decode(InstalledTika.self, from: Data(contentsOf: folder.appendingPathComponent("installed.json"))),
                  manifest.version == folder.lastPathComponent,
                  fm.isReadableFile(atPath: jarURL(manifest.version).path) else { return nil }
            return manifest
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return TikaStatus(installed: installed, selectedVersion: selection?.version,
                          available: catalog?.releases ?? [], checkedAt: catalog?.checkedAt, directory: directory)
    }
    package func jarURL(_ version: String) -> URL {
        directory.appendingPathComponent(version).appendingPathComponent("tika-app-\(version).jar")
    }
    package var selectedJar: URL? {
        guard let status = try? status(), let version = status.selectedVersion,
              status.installed.contains(where: { $0.version == version }) else { return nil }
        return jarURL(version)
    }
    @discardableResult
    package func refresh() async throws -> TikaStatus {
        async let currentData = client.data(from: URL(string: "https://downloads.apache.org/tika/")!)
        async let archiveData = try? client.data(from: URL(string: "https://archive.apache.org/dist/tika/")!)
        let current = TikaRelease.parseCatalog(try await currentData, archived: false)
        guard !current.isEmpty else { throw Self.failure("Apache lists no compatible Tika 3.x release. Installed versions are still available.") }
        let archived = TikaRelease.parseCatalog(await archiveData ?? Data(), archived: true)
        let releases = (current + archived.filter { old in !current.contains { $0.version == old.version } }).sorted(by: TikaRelease.newestFirst)
        try Task.checkCancellation()
        let lock = try lockStore(); defer { lock.close() }
        try write(Catalog(releases: releases, checkedAt: .now), to: catalogURL)
        return try status()
    }
    @discardableResult
    package func install(_ release: TikaRelease, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> InstalledTika {
        guard TikaRelease.isCompatible(release.version) else { throw Self.failure("Choose a supported Tika 3.x version.") }
        // A process-wide file lock also prevents two app windows or a CLI from
        // downloading the same version, switching, or removing it mid-install.
        let lock = try lockStore(); defer { lock.close() }
        if let installed = try status().installed.first(where: { $0.version == release.version }) { return installed }
        let checksum = try await client.data(from: URL(string: release.downloadURL.absoluteString + ".sha512")!)
        let expected = try Self.parseChecksum(checksum)
        let download = try await client.download(from: release.downloadURL, progress: progress)
        defer { try? FileManager.default.removeItem(at: download) }
        try Task.checkCancellation()
        let hash = try Self.digest(download)
        guard hash == expected else { throw Self.failure("The Tika download failed its SHA-512 check. Nothing was installed; try downloading again.") }
        let file = try FileHandle(forReadingFrom: download); defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw Self.failure("Apache did not return a Tika application jar.")
        }
        let fm = FileManager.default
        let stage = directory.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let jar = stage.appendingPathComponent(jarURL(release.version).lastPathComponent)
        try fm.moveItem(at: download, to: jar)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jar.path)
        let bytes = (try fm.attributesOfItem(atPath: jar.path)[.size] as? NSNumber)?.int64Value ?? 0
        let manifest = InstalledTika(version: release.version, sha512: hash, source: release.downloadURL, installedAt: .now, bytes: bytes)
        try write(manifest, to: stage.appendingPathComponent("installed.json"))
        try Task.checkCancellation()
        try fm.moveItem(at: stage, to: directory.appendingPathComponent(release.version))
        return manifest
    }
    package func select(_ version: String?) throws {
        let lock = try lockStore(); defer { lock.close() }
        if let version, !((try status()).installed.contains { $0.version == version }) {
            throw Self.failure("Download that Tika version before selecting it.")
        }
        try write(Selection(version: version), to: selectionURL)
        NotificationCenter.default.post(name: Self.toolsDidChange, object: nil)
    }
    package func remove(_ version: String) throws {
        let lock = try lockStore(); defer { lock.close() }
        let state = try status()
        guard state.installed.contains(where: { $0.version == version }) else { throw Self.failure("That Tika version is not installed.") }
        let usage = try TikaStoreLock(directory.appendingPathComponent(version).appendingPathComponent(".in-use"),
            message: "Tika \(version) is reading documents. Finish or cancel those searches before removing it.")
        defer { usage.close() }
        if state.selectedVersion == version { try write(Selection(version: nil), to: selectionURL) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(version))
        NotificationCenter.default.post(name: Self.toolsDidChange, object: nil)
    }
    package static func parseChecksum(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        let tokens = text.split(whereSeparator: { !$0.isHexDigit })
        let hashes = tokens.filter { $0.count == 128 }
        guard hashes.count == 1 else { throw failure("Apache returned an invalid SHA-512 checksum.") }
        return hashes[0].lowercased()
    }
    package static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA512()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
    }
    private func lockStore() throws -> TikaStoreLock {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw Self.failure("The Tika installation directory must not be a symbolic link.")
        }
        return try TikaStoreLock(directory.appendingPathComponent(".lock"))
    }
    package static func failure(_ message: String) -> SearchServiceError { .commandFailed(message) }
}

private final class TikaStoreLock: @unchecked Sendable {
    private var descriptor: Int32
    init(_ file: URL, message: String = "Another Tika download or version change is in progress. Wait for it to finish and try again.") throws {
        descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TikaManager.failure("Could not open the Tika version store.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw TikaManager.failure(message)
        }
    }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
