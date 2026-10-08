import Foundation

package struct Toolchain: Codable, Sendable {
    package let fd: URL?
    package let fzf: URL?
    package let rg: URL?
    package let find: URL?
    package let mdfind: URL?
    package var contentWorker: URL? = Toolchain.locateContentWorker()
    package var rgaPreproc: URL? = nil
    package var pandoc: URL? = nil
    package var pdftotext: URL? = nil
    package var pdfdetach: URL? = nil
    package var tikaJar: URL? = nil
    package var ffmpeg: URL? = nil
    package var ffprobe: URL? = nil
    private static var converterPreferences: UserDefaults {
        // The packaged app already owns this domain. Creating a suite with its
        // own bundle ID logs a warning and is not a supported preferences setup.
        Bundle.main.bundleIdentifier == "com.codex.findui" ? .standard
            : UserDefaults(suiteName: "com.codex.findui") ?? .standard
    }
    package static var savedTikaJarPath: String? { converterPreferences.string(forKey: "TikaJarPath") }
    package static func setTikaJar(_ url: URL?) {
        converterPreferences.set(url?.path, forKey: "TikaJarPath")
    }

    package static func locateContentWorker() -> URL? {
        let development = ExecutableLocation.developmentRoot?.appendingPathComponent(".build/content-worker/release/findui-content")
        let candidates = [ExecutableLocation.current?.deletingLastPathComponent().appendingPathComponent("findui-content"),
                          development].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    package static func resolve(for request: SearchRequest) -> Toolchain {
        resolve(includeDocumentReaders: request.refinements.extraction != nil)
    }

    package static func resolve(environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                        includeDocumentReaders: Bool = true) -> Toolchain {
        let bundled = ExecutableLocation.current?.deletingLastPathComponent()
        let development = ExecutableLocation.developmentRoot?.appendingPathComponent(".build/search-tools/bin")
        func coreTool(_ name: String) -> URL? {
            [bundled?.appendingPathComponent(name), development?.appendingPathComponent(name)].compactMap { $0 }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/Applications/Codex.app/Contents/Resources",
            "/usr/bin",
            "/bin",
        ]
        var searchRoots: [String] = environmentPath
            .split(separator: ":")
            .map(String.init)
        searchRoots.append(contentsOf: defaults)

        var seen = Set<String>()
        let uniqueRoots = searchRoots.filter { seen.insert($0).inserted }

        func locate(_ names: [String]) -> URL? {
            for root in uniqueRoots {
                for name in names {
                    let candidate = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name, isDirectory: false)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
            return nil
        }

        var result = Toolchain(
            fd: coreTool("fd") ?? locate(["fd", "fdfind"]),
            fzf: coreTool("fzf") ?? locate(["fzf"]),
            rg: coreTool("rg") ?? locate(["rg"]),
            find: locate(["find"]),
            mdfind: locate(["mdfind"])
        )
        // Settings requests the complete inventory. Searches only need optional
        // readers when extraction is enabled; do not read Tika preferences or
        // search PATH for converters on ordinary fd/rg invocations.
        guard includeDocumentReaders else { return result }
        result.pandoc = locate(["pandoc"])
        result.pdftotext = locate(["pdftotext"])
        result.pdfdetach = locate(["pdfdetach"])
        result.ffmpeg = locate(["ffmpeg"]); result.ffprobe = locate(["ffprobe"])
        let selectedPath: String?
        if let override = ProcessInfo.processInfo.environment["FINDUI_TIKA_JAR"] {
            selectedPath = override
        } else {
            let manager = TikaManager()
            selectedPath = manager.hasSelection ? manager.selectedJar?.path : savedTikaJarPath
        }
        if let path = selectedPath, !path.isEmpty {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.isReadableFile(atPath: url.path) { result.tikaJar = url }
        }
        return result
    }

    package var searchPath: String { Self.defaultSearchPath }

    package static var defaultSearchPath: String {
        let preferredRoots = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/Applications/Codex.app/Contents/Resources",
            "/usr/bin",
            "/bin",
        ]
        var roots = preferredRoots
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        roots.append(contentsOf: inherited)

        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }.joined(separator: ":")
    }
    package init(fd: URL? = nil, fzf: URL? = nil, rg: URL? = nil, find: URL? = nil, mdfind: URL? = nil, contentWorker: URL? = Toolchain.locateContentWorker(), rgaPreproc: URL? = nil, pandoc: URL? = nil, pdftotext: URL? = nil, pdfdetach: URL? = nil, tikaJar: URL? = nil) {
        self.fd = fd
        self.fzf = fzf
        self.rg = rg
        self.find = find
        self.mdfind = mdfind
        self.contentWorker = contentWorker
        self.rgaPreproc = rgaPreproc
        self.pandoc = pandoc
        self.pdftotext = pdftotext
        self.pdfdetach = pdfdetach
        self.tikaJar = tikaJar
    }

}

package struct CommandSpec: Sendable {
    package let executable: URL
    package let arguments: [String]
    package let workingDirectory: URL?

    package var shellString: String {
        let command = ([executable.path] + arguments).map(shellQuote).joined(separator: " ")
        return workingDirectory.map { "(cd -- " + shellQuote($0.path) + " && " + command + ")" } ?? command
    }
    package init(executable: URL, arguments: [String], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

}

package struct PreparedCommand: Sendable {
    package let spec: CommandSpec
    package let engineName: String
    package let preview: String

    package init(spec: CommandSpec, engineName: String, preview: String? = nil) {
        self.spec = spec
        self.engineName = engineName
        self.preview = preview ?? spec.shellString
    }
}

package struct SearchCommandBuilder: Sendable {
    package let tools: Toolchain

    package func preparedCommand(for request: SearchRequest) throws -> PreparedCommand {
        let pipeline = try SearchPipelineCompiler(tools: tools).compile(request)
        return PreparedCommand(spec: pipeline.spec, engineName: pipeline.engineName, preview: pipeline.script)
    }

    package func preparedDirectoryListingCommand(scope: URL, includeHidden: Bool) throws -> PreparedCommand {
    var request = SearchRequest(query: "", mode: .everything, scope: scope, includeHidden: includeHidden,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.isDirectoryListing = true
    let pipeline = try SearchPipelineCompiler(tools: tools).compile(request)
    return PreparedCommand(spec: pipeline.spec, engineName: pipeline.engineName, preview: pipeline.script)
}
    package init(tools: Toolchain) {
        self.tools = tools
    }



}

package func escapeFindGlob(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "*", with: "\\*")
        .replacingOccurrences(of: "?", with: "\\?")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
}

package func shellQuote(_ value: String) -> String {
    guard !value.isEmpty else {
        return "''"
    }

    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._:=@"))
    if value.unicodeScalars.allSatisfy(allowed.contains(_:)) {
        return value
    }

    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
