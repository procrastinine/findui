import Foundation
import SearchCore

/// CLI entry points use the same compiler and index services as the app, without
/// constructing NSApplication, windows, or view models.
package enum HeadlessCLI {
    package struct SearchDescription: Codable {
        package let state: SearchState
        package let referenceDate: Date
        package var index: ManagedIndex? = nil

        package init(state: SearchState, referenceDate: Date, index: ManagedIndex? = nil) {
            self.state = state; self.referenceDate = referenceDate; self.index = index
        }
        private enum CodingKeys: String, CodingKey { case state, referenceDate, index }
        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.state) {
                state = try values.decode(SearchState.self, forKey: .state)
                referenceDate = try values.decode(Date.self, forKey: .referenceDate)
                index = try values.decodeIfPresent(ManagedIndex.self, forKey: .index)
            } else {
                // Both accepted input forms share one JSON parse. Ordinary
                // state input does not first construct and catch a decode error.
                state = try SearchState(from: decoder)
                referenceDate = .now
            }
        }
    }
    package static var executable: URL {
        if let executable = ExecutableLocation.current {
            let cli = executable.deletingLastPathComponent().appendingPathComponent("FindUI", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
        }
        if let development = ExecutableLocation.developmentRoot {
            return development.appendingPathComponent(".build/debug/FindUI")
        }
        return (ExecutableLocation.current?.deletingLastPathComponent() ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS"))
            .appendingPathComponent("FindUI")
    }
    package static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    package static func searchCommand(_ request: SearchRequest, snapshot: URL, index: ManagedIndex? = nil) throws -> String {
        SearchPipelineCompiler.command(executable.path, ["--cli", request.isDirectoryListing ? "browse" : "search",
            try encoded(SearchDescription(state: request.state, referenceDate: request.referenceDate, index: index)), "--snapshot", snapshot.path]
            + (request.collectStatistics ? ["--stats"] : []))
    }
    package static func indexCommand(_ index: ManagedIndex, output: URL, watch: Bool) throws -> String {
        SearchPipelineCompiler.command(executable.path, ["--cli", "index", watch ? "watch" : "build",
            try encoded(IndexConfiguration(index)), output.path])
    }
    package static func explainCommand(_ request: SearchRequest, file: URL, snapshot: URL? = nil) throws -> String {
        SearchPipelineCompiler.command(executable.path, ["--cli", "explain",
            try encoded(SearchDescription(state: request.state, referenceDate: request.referenceDate)), file.path]
            + (snapshot.map { ["--snapshot", $0.path] } ?? []))
    }
    private static func facets(_ args: [String]) async throws -> Int32 {
        if args.count == 3, args[0] == "apply" {
            let facet = try JSONDecoder().decode(ResultFacet.self,from:input(args[1]))
            let state = try JSONDecoder().decode(SearchState.self,from:input(args[2]))
            print(try encoded(facet.applying(to:state))); return 0
        }
        guard (args.count == 2 || args.count == 4), args[0] == "search" else { throw SearchServiceError.invalidQuery }
        let state = try JSONDecoder().decode(SearchState.self,from:input(args[1]))
        var request = state.makeRequest()
        let tools = Toolchain.resolve(for: request)
        let prepared: PreparedSearch
        if args.count == 4 {
            guard args[2] == "--snapshot" else { throw SearchServiceError.invalidQuery }
            request.useIndex = true
            prepared = try await PreparedSearch.snapshot(request: request, at: URL(fileURLWithPath: args[3]), tools: tools)
        } else {
            prepared = try PreparedSearch(request: request, tools: tools)
        }
        let session = try SearchSession(prepared: prepared)
        let summary = try await session.run(tools: tools, onChange: {})
        let store = session.results
        struct FacetReport: Encodable {
            let facets: [ResultFacet]; let totals: ResultTotals; let count: Int; let isTruncated: Bool; let warning: String?
        }
        print(try encoded(await FacetReport(facets:store.facets(),totals:store.totals(for:[]),count:store.count,isTruncated:summary.isTruncated,warning:summary.warning)))
        return 0
    }

    package static func input(_ argument: String) throws -> Data {
        argument.hasPrefix("@") ? try Data(contentsOf: URL(fileURLWithPath: String(argument.dropFirst()))) : Data(argument.utf8)
    }
    package static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments
        do {
            if args.isEmpty || args == ["--help"] {
                print("""
                FindUI --cli search JSON|@state.json [--stats] [--within paths.nul] [--print-command | --explain-plan] [--snapshot index.sqlite]
                FindUI --cli browse JSON|@state.json [--print-command | --explain-plan] [--snapshot index.sqlite]
                FindUI --cli import-command COMMAND|@command.txt [--directory PATH] [--native]
                FindUI --cli index build|watch JSON|@config.json output.sqlite
                FindUI --cli index export index.sqlite
                FindUI --cli index contents|words JSON|@state.json
                FindUI --cli index status JSON|@state.json
                FindUI --cli suggest JSON|@state.json PREFIX
                FindUI --cli readers
                FindUI --cli readers list|export
                FindUI --cli readers import JSON|@readers.json
                FindUI --cli readers remove|enable|disable ID
                FindUI --cli benchmark
                FindUI --cli facets search JSON|@state.json [--snapshot index.sqlite]
                FindUI --cli facets apply JSON|@facet.json JSON|@state.json
                FindUI --cli explain JSON|@state.json /path/to/file [--snapshot index.sqlite]
                FindUI --cli presets list|export
                FindUI --cli presets save search|filter|scope NAME JSON|@state.json
                FindUI --cli presets get|remove NAME_OR_ID
                FindUI --cli presets apply NAME_OR_ID JSON|@state.json
                FindUI --cli presets import JSON|@presets.json
                FindUI --cli document preview|materialize JSON|@location.json
                FindUI --cli text preview JSON|@location.json
                FindUI --cli cache info|clear|retry
                FindUI --cli tika list|check
                FindUI --cli tika install VERSION|latest [--select]
                FindUI --cli tika select VERSION|off
                FindUI --cli tika remove VERSION
                FindUI --cli ai schema|status
                FindUI --cli ai models [openrouter|openai|anthropic|google|codex|@settings.json]
                FindUI --cli ai configure JSON|@settings.json
                FindUI --cli ai key set|remove
                FindUI --cli ai propose DESCRIPTION JSON|@state.json
                FindUI --cli ai apply JSON|@proposal.json JSON|@state.json

                Search JSON is a saved SearchState, or {state, referenceDate}.
                import-command prints validated SearchState JSON without running the search.
                --native passes tool options through; file results use the table and other output is text.
                Index config: {"scopePath":"/absolute/folder","name":"My files","includeHidden":true}
                Index watch uses FSEvents and SQLite transactions after coalesced changes.
                Index export prints inspectable JSON; older JSON snapshots remain readable.
                Search output: NUL paths, or JSON lines for content matches. Diagnostics: stderr.
                Document text uses optional FOSS Poppler, Pandoc and Tika; archives use system libarchive.
                Tika list is local; check and install contact Apache. Downloads verify SHA-512.
                Tika versions and selection are shared with Settings, without a GUI or restart.
                AI propose contacts the configured provider and prints a validated search description;
                it does not execute the search. AI apply validates model JSON locally. AI key set reads stdin.
                Presets apply writes SearchState JSON; pass it to search. Filters add conditions.
                --within reads a NUL file list and searches those paths with the same predicates.
                benchmark measures synthetic SHA-256 and cache round-trips; no personal files are read.
                index contents prewarms document text and conservative content signatures.
                index words prepares optional ranked word/phrase search. Set refinements.wordSearch
                to true to query it. stemWords enables related forms; wordLanguage selects a language
                (en, fr, de, es, pt, it, nl, sv, da, no, fi, ru, ro, hu, tr, ar, el, ta).
                Update explicitly after changes; unchanged word-index status reuses filesystem events.
                refinements.multiline allows regex matches across lines (native rg --multiline).
                extraction.media reads media metadata and text subtitles; customReaders uses readers.json.
                Reader programs receive argv literally, with {path} replaced by the source path.
                cache retry forgets reader failures without removing successful cached text.
                explain reports actual traversal, file and content decisions for one file.
                Document location JSON: {path, origin, extraction?, context?, expectedSnippet?, encoding?}.
                Text preview JSON: {path, line, context?, encoding?, expectedSnippet?}.
                origin comes from findui_origin in match JSON. Materialize returns a temporary path;
                the caller owns that file and should remove it after use.
                """)
                return 0
            }
            if args.first == "tika" { return try await tika(Array(args.dropFirst())) }
            if args.first == "import-command" {
                print(try encoded(importCommand(Array(args.dropFirst())))); return 0
            }
            if args.first == "ai" { return try await AISearchCLI.run(Array(args.dropFirst())) }
            if args.first == "presets" { return try presets(Array(args.dropFirst())) }
            if args.first == "facets" { return try await facets(Array(args.dropFirst())) }
            if args == ["benchmark"] {
                guard let worker = Toolchain.locateContentWorker() else { throw SearchServiceError.missingTool("findui-content") }
                return try await relay(.init(executable: worker, arguments: ["--benchmark-primitives"]), json: true)
            }
            if args.count == 3, args[0] == "text", args[1] == "preview" {
                guard let worker = Toolchain.locateContentWorker() else { throw SearchServiceError.missingTool("findui-content") }
                return try await relay(.init(executable: worker, arguments: ["--text-preview", String(decoding: try input(args[2]), as: UTF8.self)]), json: true)
            }
            if args.count == 3, args[0] == "index", args[1] == "export" {
                let artifact = try IndexArtifact.load(URL(fileURLWithPath: args[2]))
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(artifact), as: UTF8.self)); return 0
            }
            if args.first == "explain", args.count == 3 || (args.count == 5 && args[3] == "--snapshot") {
                let data = try input(args[1])
                let description = try JSONDecoder().decode(SearchDescription.self, from: data)
                let request = SearchRequest(state: description.state, referenceDate: description.referenceDate)
                let report = try await SearchExplainer(tools: .resolve(for: request)).explain(request,
                    file: URL(fileURLWithPath: args[2]).standardizedFileURL,
                    snapshot: args.count == 5 ? URL(fileURLWithPath: args[4]) : nil)
                print(try encoded(report)); return 0
            }
            if args.count == 3, args[0] == "document", ["preview", "materialize"].contains(args[1]) {
                let request = try JSONDecoder().decode(DocumentAccess.Request.self, from: input(args[2]))
                return try await relay(DocumentAccess.command(args[1] == "preview" ? "--document-preview" : "--materialize-member", request: request), json: true)
            }
            if args == ["readers"] { print(try encoded(await ReaderRegistry.load())); return 0 }
            if args.first == "readers" { return try readers(Array(args.dropFirst())) }
            let buildContents = args.count == 3 && args[0] == "index" && ["contents", "words"].contains(args[1])
            if args.count == 3 && args[0] == "index" && args[1] == "status" {
                let state = try JSONDecoder().decode(SearchState.self,from:input(args[2]))
                print(try encoded(await WordIndexService.status(state.makeRequest()))); return 0
            }
            if args.count == 3 && args[0] == "suggest" {
                let state = try JSONDecoder().decode(SearchState.self,from:input(args[1]))
                print(try encoded(await WordIndexService.suggestions(state.makeRequest(),prefix:args[2]))); return 0
            }
            let buildWords = buildContents && args[1] == "words"
            if buildContents { args = ["search", args[2]] }
            if args.count == 2, args[0] == "cache", ["info", "clear", "retry"].contains(args[1]) {
                guard let worker = Toolchain.locateContentWorker() else { throw SearchServiceError.missingTool("findui-content") }
                return try await relay(.init(executable: worker, arguments: ["--cache-" + args[1], SearchExtractionOptions.cacheDirectory.path]), json: true)
            }
            if args.count == 4, args[0] == "index", ["build", "watch"].contains(args[1]) {
                let config = try JSONDecoder().decode(IndexConfiguration.self, from: input(args[2]))
                let output = URL(fileURLWithPath: args[3]).standardizedFileURL
                let maintenance = IndexMaintenance(configuration: config, output: output)
                if args[1] == "build" { _ = try await maintenance.rebuild(); return 0 }
                try await maintenance.start()
                // SIGINT/TERM end the foreground CLI. Every published generation
                // is atomic, so interruption cannot leave half an index behind.
                while !Task.isCancelled { try await Task.sleep(for: .seconds(30)) }
                await maintenance.stop()
                return 0
            }
            if args.count >= 2, ["search", "browse"].contains(args[0]) {
                guard !(args.dropFirst(2).contains("--within") && args.dropFirst(2).contains("--snapshot")) else {
                    throw SearchServiceError.commandFailed("Choose either --within saved results or --snapshot; they cannot be combined.")
                }
                let data = try input(args[1])
                let description = try JSONDecoder().decode(SearchDescription.self, from: data)
                var request = SearchRequest(state: description.state, referenceDate: description.referenceDate)
                request.isDirectoryListing = args[0] == "browse"
                if args.dropFirst(2).contains("--stats") { request.collectStatistics = true; args.removeAll { $0 == "--stats" } }
                if let index = args.dropFirst(2).firstIndex(of: "--within"), args.indices.contains(index + 1) {
                    request.state = request.state.searchingResults(.init(path: URL(fileURLWithPath: args[index + 1]).standardizedFileURL.path, name: "Saved files", count: 0))
                    args.removeSubrange(index...index + 1)
                }
                let explainPlan = args.dropFirst(2).contains("--explain-plan")
                if let option = args.dropFirst(2).firstIndex(of: "--explain-plan") { args.remove(at: option) }
                let printCommand = args.dropFirst(2).contains("--print-command")
                if let option = args.dropFirst(2).firstIndex(of: "--print-command") { args.remove(at: option) }
                guard !(printCommand && explainPlan) else {
                    throw SearchServiceError.commandFailed("Choose either --print-command or --explain-plan.")
                }
                if buildContents {
                    try request.state.promoteToRules()
                    let rules = SearchRuleSet(files: request.state.ruleSet!.candidateFiles, contents: .rule(.allLines))
                    request.state.replaceRules(rules); request.buildContentIndex = !buildWords; request.buildWordIndex = buildWords; request.refinements.wordSearch = nil; request.refinements.multiline = nil; request.refinements.useContentIndex = true
                    request.refinements.extraction?.cacheText = true
                }
                if args.count == 4, args[2] == "--snapshot" {
    let file = URL(fileURLWithPath: args[3])
    request.useIndex = true
    let tools = Toolchain.resolve(for: request)
                    let prepared = try await PreparedSearch.snapshot(request: request, at: file, tools: tools, legacyIndex: description.index)
    if explainPlan { print(try encodeSearchJSON(prepared.pipeline.plan)); return 0 }
    if printCommand { print(prepared.command); return 0 }
    if let warning = prepared.warning { diagnostic(warning) }
    // Keep the frozen generation leased until the child exits.
    defer { withExtendedLifetime(prepared) {} }
    return try await relay(prepared.pipeline.spec, json: false,
        emptyExitCodes: prepared.pipeline.emptyExitCodes, statistics: request.collectStatistics)
}
                guard args.count == 2 else { throw SearchServiceError.invalidQuery }
                let tools = Toolchain.resolve(for: request)
                let pipeline = try SearchPipelineCompiler(tools: tools).compile(request, includeCommandMetadata: printCommand)
                if explainPlan { print(try encodeSearchJSON(pipeline.plan)); return 0 }
                if printCommand { print(pipeline.script); return 0 }
                if pipeline.plan.output == .text {
                    // Preserve arbitrary stdout bytes and the tool's own exit
                    // status; the path/JSON relays would change this output.
                    try ProcessRunner.replace(with: pipeline.spec, pathOverride: tools.searchPath)
                }
                if pipeline.plan.direct?.executable == tools.rg?.path && pipeline.outputIsJSON {
                    let result = try await ProcessRunner.relayRipgrep(pipeline.spec, pathOverride: tools.searchPath, collectStatistics: request.collectStatistics)
                    if !result.stderr.isEmpty { diagnostic(result.stderr) }
                    return pipeline.emptyExitCodes.contains(result.exitCode) ? 0 : result.exitCode
                }
                if request.collectStatistics || !pipeline.emptyExitCodes.isEmpty {
                    return try await relay(pipeline.spec, json: pipeline.outputIsJSON,
                        emptyExitCodes: pipeline.emptyExitCodes, statistics: request.collectStatistics)
                }
                try ProcessRunner.replace(with: pipeline.spec, pathOverride: tools.searchPath)
            }
            throw SearchServiceError.commandFailed("Unknown arguments. Use FindUI --cli --help.")
        } catch { diagnostic(error.localizedDescription); return 2 }
    }
    package static func importCommand(_ args: [String]) throws -> SearchState {
        guard let text = args.first, let command = String(data: try input(text), encoding: .utf8) else {
            throw SearchServiceError.commandFailed("Use import-command COMMAND [--directory PATH] [--native].")
        }
        var directory = FileManager.default.currentDirectoryPath, native = false, directorySet = false, index = 1
        while index < args.count {
            if args[index] == "--native", !native { native = true; index += 1 }
            else if args[index] == "--directory", !directorySet, index + 1 < args.count {
                directory = (args[index + 1] as NSString).expandingTildeInPath
                directorySet = true; index += 2
            } else { throw SearchServiceError.commandFailed("Use import-command COMMAND [--directory PATH] [--native]. Unknown or repeated option: \(args[index])") }
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let state = try native ? NativeSearchCommand(command: command, directory: base.path).snapshot()
            : CLICommandParser.parse(command, currentDirectory: base)
        _ = try SearchPipelineCompiler(tools: .resolve(for: state.makeRequest())).compile(
            state.makeRequest(), includeCommandMetadata: false)
        return state
    }

    private static func readers(_ args: [String]) throws -> Int32 {
        let store = ReaderConfiguration()
        if args.count == 1, ["list", "export"].contains(args[0]) { print(try encoded(store.load())); return 0 }
        guard args.count == 2 else { throw SearchServiceError.commandFailed("Use readers list, export, import JSON, or remove|enable|disable ID.") }
        let rows = try store.update { rows in
            if args[0] == "import" {
                let imported = try JSONDecoder().decode([SearchCore.ReaderAdapter].self, from: input(args[1]))
                try ReaderConfiguration.validate(imported)
                for reader in imported {
                    if let i = rows.firstIndex(where: { $0.id == reader.id }) { rows[i] = reader } else { rows.append(reader) }
                }
            } else {
                guard let i = rows.firstIndex(where: { $0.id == args[1] }) else { throw SearchServiceError.commandFailed("Reader ID not found.") }
                switch args[0] {
                case "remove": rows.remove(at: i)
                case "enable": rows[i].enabled = true
                case "disable": rows[i].enabled = false
                default: throw SearchServiceError.commandFailed("Unknown reader action.")
                }
            }
        }
        print(try encoded(rows)); return 0
    }

    private static func presets(_ args: [String]) throws -> Int32 {
        let store = SearchPresetStore()
        if args == ["list"] || args == ["export"] { print(try encoded(store.read())); return 0 }
        if args.count == 4, args[0] == "save", let kind = SearchPresetKind(rawValue: args[1]) {
            let value = SearchPreset(name: args[2], kind: kind, state: try JSONDecoder().decode(SearchState.self, from: input(args[3])))
            try store.change { $0.presets.append(value) }; print(try encoded(value)); return 0
        }
        if args.count == 2, args[0] == "get" { print(try encoded(store.resolve(args[1]))); return 0 }
        if args.count == 2, args[0] == "remove" {
            let value = try store.resolve(args[1]); try store.change { $0.presets.removeAll { $0.id == value.id } }; return 0
        }
        if args.count == 3, args[0] == "apply" {
            let state = try JSONDecoder().decode(SearchState.self, from: input(args[2]))
            print(try encoded(store.resolve(args[1]).applying(to: state))); return 0
        }
        if args.count == 2, args[0] == "import" {
            let incoming = try JSONDecoder().decode(SearchPresetCollection.self, from: input(args[1])); try incoming.validate()
            let value = try store.importPresets(incoming)
            print(try encoded(value)); return 0
        }
        throw SearchServiceError.commandFailed("Unknown preset command. Use FindUI --cli --help.")
    }
    private static func tika(_ args: [String]) async throws -> Int32 {
        let manager = TikaManager()
        if args == ["list"] { print(try encoded(manager.status())); return 0 }
        if args == ["check"] { print(try encoded(await manager.refresh())); return 0 }
        if args.count == 2, args[0] == "select" {
            try manager.select(args[1] == "off" ? nil : args[1])
        } else if args.count == 2, args[0] == "remove" {
            try manager.remove(args[1])
        } else if (args.count == 2 || (args.count == 3 && args[2] == "--select")), args[0] == "install" {
            let requested = args[1]
            guard requested == "latest" || TikaRelease.isCompatible(requested) else {
                throw TikaManager.failure("Choose a Tika 3.x version, or latest.")
            }
            var status = try manager.status()
            let version: String
            if status.installed.contains(where: { $0.version == requested }) { version = requested }
            else {
                if requested == "latest" || !status.available.contains(where: { $0.version == requested }) {
                    status = try await manager.refresh()
                }
                guard let release = status.available.first(where: { requested == "latest" ? !$0.archived : $0.version == requested }) else {
                    throw TikaManager.failure("Apache does not list that compatible version. Use tika check to see available downloads.")
                }
                diagnostic("Downloading Tika \(release.version) from Apache and verifying SHA-512…")
                version = try await manager.install(release).version
            }
            if args.count == 3 { try manager.select(version) }
        } else { throw TikaManager.failure("Use tika list, check, install VERSION|latest [--select], select VERSION|off, or remove VERSION.") }
        print(try encoded(manager.status()))
        return 0
    }
    private static func relay(_ spec: CommandSpec, json: Bool, emptyExitCodes: [Int32] = [], statistics: Bool = false) async throws -> Int32 {
        let counter = CLIRelayCounter()
        let started = ContinuousClock.now
        let separator: UInt8 = json ? 10 : 0
        let result = try await ProcessRunner.stream(spec: spec, pathOverride: Toolchain.defaultSearchPath, separator: separator) { line in
            if statistics { await counter.increment() }
            var data = Data(line.utf8); data.append(separator)
            do { try FileHandle.standardOutput.write(contentsOf: data); return true } catch { return false }
        }
        if !result.stderr.isEmpty { diagnostic(result.stderr) }
if statistics {
    diagnostic("findui-stats: " + (try encoded(["records": Double(await counter.count),
        "elapsedSeconds": Double((ContinuousClock.now - started).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - started).components.seconds)])))
}
return emptyExitCodes.contains(result.exitCode) ? 0 : result.exitCode
    }
    package static func diagnostic(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8)) }
}

private actor CLIRelayCounter { var count = 0; func increment() { count += 1 } }
