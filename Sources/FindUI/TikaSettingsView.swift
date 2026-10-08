import SearchBackend
import SwiftUI

@MainActor
final class TikaSettingsModel: ObservableObject {
    @Published private(set) var status: TikaStatus?
    @Published private(set) var busy = false
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    @Published private(set) var javaReady: Bool?
    private let manager: TikaManager
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    init(manager: TikaManager = TikaManager()) { self.manager = manager; reload() }
    var legacyJar: String? {
        guard manager.directory == TikaManager.defaultDirectory, !manager.hasSelection,
              let path = Toolchain.savedTikaJarPath, FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }
    func reload() {
        do { status = try manager.status() } catch { self.error = error.localizedDescription }
    }
    func checkJava() async {
        javaReady = (await TikaRuntime.installedMajorVersion() ?? 0) >= 11
    }
    func checkForUpdates() {
        perform("Checking Apache for versions…") { model in
            model.status = try await model.manager.refresh()
            model.message = "Version list is up to date."
        }
    }
    func download(_ release: TikaRelease? = nil) {
        perform("Preparing download…", downloading: true) { model in
            var release = release
            if release == nil {
                model.status = try await model.manager.refresh()
                release = model.status?.available.first(where: { !$0.archived })
            }
            guard let release else { throw TikaManager.failure("No compatible version is available. Try checking for updates.") }
            model.message = "Downloading Tika \(release.version)…"
            let operationID = model.operationID
            let installed = try await model.manager.install(release) { [weak model] fraction in
                Task { @MainActor in
                    guard let model, model.busy, model.operationID == operationID else { return }
                    model.progress = fraction
                    if fraction >= 1 { model.message = "Verifying download…" }
                }
            }
            try Task.checkCancellation()
            try model.manager.select(installed.version)
            model.reload()
            model.message = "Downloaded and selected Tika \(installed.version)."
        }
    }
    func select(_ version: String?) {
        do {
            try manager.select(version); reload(); error = nil
            message = version.map { "Using Tika \($0)." } ?? "Tika is turned off. Downloaded versions are kept."
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ version: String) {
        do { try manager.remove(version); reload(); error = nil; message = "Removed Tika \(version)." }
        catch { self.error = error.localizedDescription }
    }
    func cancel() { task?.cancel() }
    private func perform(_ message: String, downloading: Bool = false,
                         operation: @escaping @MainActor (TikaSettingsModel) async throws -> Void) {
        guard !busy else { return }
        operationID = UUID()
        busy = true; self.downloading = downloading; error = nil; progress = nil; self.message = message
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; self.downloading = false; progress = nil; task = nil }
            do { try await operation(self) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { self.message = "Download or update check cancelled." }
                else { self.error = error.localizedDescription; self.message = "" }
                reload()
            }
        }
    }
}

struct TikaSettingsView: View {
    @ObservedObject var model: TikaSettingsModel
    @State private var showsVersions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adds spreadsheets, presentations and older Office documents to content searches.")
                .foregroundStyle(.secondary)
            HStack {
                Text("Use version")
                UtilityPicker(title: "Use version", selection: Binding(
                    get: { model.status?.selectedVersion ?? (model.legacyJar == nil ? "" : "legacy") },
                    set: { if $0 != "legacy" { model.select($0.isEmpty ? nil : $0) } }
                ), values: [""] + (model.legacyJar == nil ? [] : ["legacy"]) + (model.status?.installed.map(\.version) ?? []),
                              label: { $0.isEmpty ? "Off" : $0 == "legacy" ? "Previously selected jar" : "Tika \($0)" })
                    .frame(width: 190).disabled(model.busy)
                    .accessibilityIdentifier("tikaSelectedVersion")
                Spacer()
                if model.javaReady == true { Label("Java ready", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            if model.legacyJar != nil {
                Text("Your previously selected jar is still in use. Download a managed version to switch, or choose Off to disable it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.javaReady == false {
                HStack {
                    Label("Java 11 or newer is required to read Office documents.", systemImage: "exclamationmark.circle")
                    Spacer()
                    Link("Get Java", destination: URL(string: "https://adoptium.net/temurin/releases/?os=mac&version=21")!)
                    Button("Recheck") { Task { await model.checkJava() } }
                }.font(.caption)
            }
            HStack(spacing: 10) {
                if model.busy {
                    if model.downloading {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .frame(minWidth: 200, maxWidth: .infinity)
                            .accessibilityLabel("Tika download progress")
                            .accessibilityIdentifier("tikaDownloadProgress")
                        if let fraction = model.progress {
                            Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption)
                                .frame(width: 38, alignment: .trailing)
                        }
                    } else { ProgressView().controlSize(.small) }
                    Button("Cancel") { model.cancel() }.accessibilityIdentifier("tikaCancelDownload")
                } else {
                    Button(downloadTitle) { model.download(recommended) }
                        .disabled(recommended.map { release in model.status?.installed.contains { $0.version == release.version } == true } ?? false)
                        .accessibilityIdentifier("tikaDownload")
                    Button("Check for Updates") { model.checkForUpdates() }.accessibilityIdentifier("tikaCheckUpdates")
                }
                if let date = model.status?.checkedAt, !model.busy {
                    Text("Checked \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).font(.caption) }
            else if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
            if !(model.status?.installed.isEmpty ?? true) || !(model.status?.available.isEmpty ?? true) {
                ExpandableSection("Manage versions", isExpanded: $showsVersions, identifier: "tikaManageVersions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.status?.installed ?? []) { item in
                            HStack(spacing: 8) {
                                Text("Tika \(item.version)")
                                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).foregroundStyle(.secondary)
                                if model.status?.selectedVersion == item.version { Text("In use").foregroundStyle(.secondary) }
                                Spacer()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.status!.directory.appendingPathComponent(item.version)]) }
                                    .fixedSize()
                                    .accessibilityIdentifier("tikaReveal.\(item.version)")
                                Button("Remove", role: .destructive) { model.remove(item.version) }
                                    .fixedSize()
                                    .accessibilityIdentifier("tikaRemove.\(item.version)")
                            }
                        }
                        Menu("Download another version") {
                            ForEach(model.status?.available ?? []) { release in
                                Button("\(release.version)\(release.archived ? " (archived)" : " (recommended)")") { model.download(release) }
                                    .disabled(model.status?.installed.contains { $0.version == release.version } == true)
                            }
                        }.fixedSize()
                        Text("Downloading a version selects it for new searches. Previous versions stay available until you remove them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.busy)
                }
            }
            Text("Downloads are manual, from Apache, and checked against its SHA-512 checksum. FindUI supports Tika 3.x; document processing stays on your computer.")
                .font(.caption).foregroundStyle(.secondary)
            if ProcessInfo.processInfo.environment["FINDUI_TIKA_JAR"] != nil {
                Text("FINDUI_TIKA_JAR is set and overrides the version selected here.").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.checkJava() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload(); Task { await model.checkJava() }
        }
    }
    private var recommended: TikaRelease? { model.status?.available.first { !$0.archived } }
    private var downloadTitle: String {
        guard let release = recommended else { return "Download Tika" }
        if model.status?.installed.contains(where: { $0.version == release.version }) == true { return "Latest version installed" }
        return "Download & Use \(release.version)"
    }
}

struct DocumentCacheSettingsView: View {
    @State private var status: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reuses document text, archive listings and content indexes for unchanged files. Clearing it frees space; later searches rebuild what they need.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Calculate Size") { run(action: "info") }
                Button("Retry Failed Readers") { run(action: "retry") }
                    .help("Forget remembered reader failures and retry them on the next search. Successful cached text is kept.")
                Button("Clear Cache") { run(action: "clear") }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            if let status { Text(status).foregroundStyle(.secondary).font(.caption).textSelection(.enabled) }
        }
    }
    private func run(action: String) {
        let tools = Toolchain.resolve()
        guard let worker = tools.contentWorker else { status = "The document reader is unavailable. Reinstall FindUI."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await ProcessRunner.run(spec: .init(executable: worker,
                    arguments: ["--cache-" + action, SearchExtractionOptions.cacheDirectory.path]), pathOverride: tools.searchPath)
                guard result.exitCode == 0 else { status = result.stderr; return }
                let payload = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
                let bytes = (payload?["bytes"] as? Int64) ?? 0
                status = action == "retry" ? "Failed readers will be retried on the next search."
                    : "\(action == "clear" ? "Cleared" : "Stored") \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
            } catch { status = error.localizedDescription }
        }
    }
}
