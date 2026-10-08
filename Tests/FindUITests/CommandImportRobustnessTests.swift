@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func groupedFindImportPreservesBooleanPrecedenceAndPerRuleCase() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in [("one.swift", "alpha\n"), ("TWO.MD", "beta\n"), ("skip.swift", "skip\n"), ("other.txt", "alpha\n")] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    let command = #"find . -type f \( \( -name '*.swift' ! -name 'skip*' \) -o -iname '*.md' \) -print0"#
    let state = try CLICommandParser.parse(command, currentDirectory: root)
    #expect(state.ruleSet != nil)
    #expect(state.ruleSet?.fileLeaves.count == 3)
    let actual = try await SearchService().search(request: state.makeRequest())
    #expect(Set(actual.results.map(\.name)) == ["one.swift", "TWO.MD"])
    let argv = try CLICommandParser.tokenize(command)[0]
    let oracle = try await ProcessRunner.run(spec: .init(executable: URL(fileURLWithPath: "/usr/bin/find"),
        arguments: Array(argv.dropFirst()), workingDirectory: root), pathOverride: Toolchain.defaultSearchPath)
    #expect(oracle.exitCode == 0)
    #expect(Set(oracle.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).lastPathComponent }) == Set(actual.results.map(\.name)))
    let pipeline = try SearchPipelineCompiler(tools: .resolve()).compile(state.makeRequest())
    let restored = try CLICommandParser.parse(pipeline.script, currentDirectory: root)
    #expect(restored.ruleSet == state.ruleSet)
}

@Test func ripgrepPatternListsAndNegationImportAsContentGroups() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("alpha\nbeta\ngamma\n".utf8).write(to: root.appendingPathComponent("one.txt"))
    for (command, expected) in [("rg -F -e alpha -e beta .", ["alpha", "beta"]),
                                 ("rg -F -v -e alpha -e beta .", ["gamma"])] {
        let state = try CLICommandParser.parse(command, currentDirectory: root)
        #expect(state.ruleSet?.contentLeaves.count == 2)
        let response = try await SearchService().search(request: state.makeRequest())
        #expect(response.results.compactMap(\.snippet).sorted() == expected.sorted())
    }
}

@Test func hiddenExclusionImportsRemainExplicitRegardlessOfFlagOrder() throws {
    let base = URL(fileURLWithPath: "/tmp")
    for command in ["fd --exclude '.*' --hidden needle", "fd --hidden --exclude '.*' needle",
                    "rg --glob '!.*' --hidden needle .", "rg --hidden --glob '!.*' needle .",
                    "rg --type-add 'findui:*.swift' --type findui --glob '!.*' needle ."] {
        #expect(try !CLICommandParser.parse(command, currentDirectory: base).includeHidden)
    }
    // Native rg whitelists hidden files but does not automatically descend
    // hidden directories. One hidden toggle cannot express that difference.
    #expect(throws: (any Error).self) {
        try CLICommandParser.parse("rg -g '*.swift' needle .", currentDirectory: base)
    }
    let explicit = try CLICommandParser.parse("rg --hidden -g '*.swift' needle .", currentDirectory: base)
    #expect(explicit.includeHidden)
}

@Test func nativeCommandKeepsUnrepresentableSemanticsAndRoundTrips() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".private"), withIntermediateDirectories: true)
    for path in ["visible.swift", ".Hidden.swift", ".private/inside.swift", "not text.txt", "unicode-文\nline.swift"] {
        try Data("needle\nother\n".utf8).write(to: root.appendingPathComponent(path))
    }
    let native = NativeSearchCommand(command: "rg -g '*.swift' --max-count 1 needle .", directory: root.path)
    let state = try native.snapshot()
    let response = try await SearchService().search(request: state.makeRequest())
    #expect(Set(response.results.map(\.name)) == ["visible.swift", ".Hidden.swift", "unicode-文\nline.swift"])
    #expect(response.results.allSatisfy { $0.lineNumber == 1 && $0.snippet == "needle" })
    #expect(response.engineName == "rg command")
    let restored = try CLICommandParser.parse(response.commandPreview, currentDirectory: URL(fileURLWithPath: "/"))
    #expect(restored.nativeCommand == native)
    let roundTrip = try await SearchService().search(request: restored.makeRequest())
    #expect(Set(roundTrip.results.map(\.path)) == Set(response.results.map(\.path)))
    var conflicting = state
    conflicting.refinements.name = "unrelated"
    #expect(throws: (any Error).self) { try SearchPipelineCompiler(tools: .resolve()).compile(conflicting.makeRequest()) }
}

@Test func nativeFindKeepsTypeBranchesAndRootMembership() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("one.swift"))
    try Data("x".utf8).write(to: root.appendingPathComponent("two.txt"))
    let command = #"find . \( -type d -o \( -type f -name '*.swift' \) \) -print0"#
    let state = try NativeSearchCommand(command: command, directory: root.path).snapshot()
    let response = try await SearchService().search(request: state.makeRequest())
    #expect(Set(response.results.map(\.path)) == [root.path, root.appendingPathComponent("folder").path, root.appendingPathComponent("one.swift").path])
}

@Test(arguments: ["rm -rf .", "rg needle; touch /tmp/nope", "rg needle > /tmp/out", "rg $(pwd)",
    "fd x | sh", "find . -print0 | xargs -0 rm"])
func nativeCommandRejectsShellProgramsAndUnsupportedPipelines(command: String) {
    #expect(throws: (any Error).self) { try NativeSearchCommand(command: command, directory: "/tmp").parsed() }
}

@Test func nativeCommandWorkingDirectoriesAreIndependent() async throws {
    let first = try commandFixture(), second = try commandFixture()
    defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
    try Data("needle".utf8).write(to: first.appendingPathComponent("first.swift"))
    try Data("needle".utf8).write(to: second.appendingPathComponent("second.swift"))
    let cwd = FileManager.default.currentDirectoryPath
    let a = try NativeSearchCommand(command: "rg --files", directory: first.path).snapshot().makeRequest()
    let b = try NativeSearchCommand(command: "rg --files", directory: second.path).snapshot().makeRequest()
    async let left = SearchService().search(request: a)
    async let right = SearchService().search(request: b)
    let (x, y) = try await (left, right)
    #expect(x.results.map(\.name) == ["first.swift"])
    #expect(y.results.map(\.name) == ["second.swift"])
    #expect(FileManager.default.currentDirectoryPath == cwd)
}

@Test @MainActor func nativeCommandRestorationAndControlEditsNeverLeaveHiddenOverrides() throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("state")), loadSavedState: false)
    let state = try NativeSearchCommand(command: "rg --files", directory: root.path).snapshot()
    model.restoreSearchState(state)
    #expect(model.commandSearch != nil)
    #expect(!model.isBrowsingDirectory)
    #expect(model.searchState.nativeCommand == state.nativeCommand)
    var restored = state
    restored.sourceCommand = nil
    model.restoreSearchState(restored)
    #expect(model.commandSearch == state.nativeCommand)
    model.filenameInput = "something"
    #expect(model.commandSearch == nil)
    #expect(model.searchState.sourceCommand == nil)
    #expect(model.filenameInput == "something")
    model.stopSearch()
}

private func commandFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-robust-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func exportedFilteredContentCommandsReimportWithoutEmptyGroups() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["one.swift", "TWO.SWIFT", ".Hidden.swift", "other.txt", "one.md"] {
        try Data("timeout retry\nother\n".utf8).write(to: root.appendingPathComponent(name))
    }
    let commands = [
        "fd -t f -g '*.swift' -0 | xargs -0 rg -F 'timeout retry'",
        "fd -t f --and swift -0 | xargs -0 rg -F 'timeout retry'",
        "find . -type f \\( -name '*.swift' -o -name '*.md' \\) -print0 | xargs -0 rg -e timeout -e other",
        "fd -t f -g '*s*' -0 | xargs -0 rg -F 'timeout retry'",
        "rg --type-add 'findui:*.[sS][wW][iI][fF][tT]' --type findui --glob '!.*' -F 'timeout retry' .",
        "rg --type-add 'findui:*.swift' --type findui --glob '!.*' -F -e timeout -e other .",
        "rg --type-add 'findui:*.swift' --type findui --glob '!.*' -F -v -e absent .",
        "rg --type-add 'findui:one.*' --type-add 'findui:TWO.*' --type findui --glob '!.*' -F -e timeout -e other ."
    ]
    for command in commands {
        var state = try CLICommandParser.parse(command, currentDirectory: root)
        let original = try await SearchService().search(request: state.makeRequest())
        #expect(!original.results.isEmpty)
        for _ in 0..<3 {
            let response = try await SearchService().search(request: state.makeRequest())
            state = try CLICommandParser.parse(response.commandPreview, currentDirectory: root)
            if command == commands[0] {
                #expect(!state.refinements.extensions.isEmpty || !state.refinements.name.isEmpty || state.ruleSet != nil)
                #expect(try SearchPipelineCompiler(tools: .resolve()).compile(state.makeRequest()).engineName == "rg")
            }
            try state.ruleSet?.validate(now: .now)
            let restored = try await SearchService().search(request: state.makeRequest())
            #expect(Set(restored.results.map { "\($0.path):\($0.lineNumber ?? 0)" }) == Set(original.results.map { "\($0.path):\($0.lineNumber ?? 0)" }), "\(command)")
        }
    }
}

@Test func importedFDAndConditionsCanStartFromAnUnrestrictedRoot() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("one.swift"))
    try Data().write(to: root.appendingPathComponent("other.txt"))
    let state = try CLICommandParser.parse("fd -t f --and swift --and one", currentDirectory: root)
    try state.ruleSet?.validate(now: .now)
    #expect(try await SearchService().search(request: state.makeRequest()).results.map(\.name) == ["one.swift"])
}

@Test func filenameGlobControlsStayUnicodeConsistentWhileImportedFDKeepsASCIIFolding() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["one.swift", "two.SWIFT", "fold.ſwift", "line\nbreak.swift"] {
        try Data("needle\n".utf8).write(to: root.appendingPathComponent(name))
    }
    var request = SearchRequest(query: "", mode: .files, scope: root, includeHidden: false,
        caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    request.refinements.name = "*.swift"; request.refinements.nameMatching = .glob
    let files = try await SearchService().search(request: request)
    #expect(Set(files.results.map(\.name)) == ["one.swift", "two.SWIFT", "fold.ſwift", "line\nbreak.swift"])
    request.mode = .contents; request.query = "needle"
    let contents = try await SearchService().search(request: request)
    #expect(Set(contents.results.map(\.name)) == Set(files.results.map(\.name)))
    let restored = try CLICommandParser.parse(contents.commandPreview, currentDirectory: root)
    #expect(restored.ruleSet == nil && restored.refinements.extensions == "swift")
    #expect(try await SearchService().search(request: restored.makeRequest()).engineName == "rg")
    let imported = try CLICommandParser.parse("fd -g '*.swift' -t f -0 | xargs -0 rg -F needle", currentDirectory: root)
    let raw = try await SearchService().search(request: imported.makeRequest())
    #expect(Set(raw.results.map(\.name)) == ["one.swift", "two.SWIFT", "line\nbreak.swift"])
    #expect(raw.engineName == "rg")
}

@Test func copiedSnapshotCommandsRoundTripWithTheirArtifactAndFrozenMembership() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("frozen.txt")
    try Data("needle".utf8).write(to: file)
    let built = try await IndexService().buildIndex(name: "Round trip", scope: root, includeHidden: false)
    let artifact = root.appendingPathComponent("saved.sqlite")
    try IndexArtifact(metadata: built.metadata, entries: built.entries).save(artifact)
    try FileManager.default.removeItem(at: file)
    var request = SearchRequest(query: "frozen", mode: .files, scope: root, useIndex: true,
        includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max)
    for browsing in [false, true] {
        request.isDirectoryListing = browsing
        var command = try HeadlessCLI.searchCommand(request, snapshot: artifact, index: built.metadata)
        for _ in 0..<3 {
            let state = try CLICommandParser.parse(command, currentDirectory: root)
            #expect(state.scopePath == root.path && state.nativeCommand != nil)
            let response = try await SearchService().search(request: state.makeRequest())
            #expect(response.results.map(\.name) == ["frozen.txt"])
            command = response.commandPreview
        }
    }
    for command in ["FindUI --cli index build '{}' /tmp/index.sqlite", "FindUI --cli cache clear", "FindUI --cli search @state.json --snapshot /tmp/index.sqlite"] {
        #expect(throws: (any Error).self) { try CLICommandParser.parse(command, currentDirectory: root) }
    }
    let nested = try NativeSearchCommand(command: "rg --files", directory: root.path).snapshot()
    let recursive = SearchPipelineCompiler.command("FindUI", ["--cli", "search", try HeadlessCLI.encoded(nested), "--snapshot", artifact.path])
    #expect(throws: (any Error).self) { try CLICommandParser.parse(recursive, currentDirectory: root) }
}

@Test func commandImportCLIValidatesWithoutExecutingAndUsesTheSharedParser() throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let command = "rg -e alpha -e beta ."
    let state = try HeadlessCLI.importCommand([command, "--directory", root.path])
    let editable = try CLICommandParser.parse(command, currentDirectory: root)
    #expect(state == editable)
    let native = try HeadlessCLI.importCommand(["rg --max-count 2 needle .", "--native", "--directory", root.path])
    #expect(native.nativeCommand?.command == "rg --max-count 2 needle .")
    #expect(throws: (any Error).self) { try HeadlessCLI.importCommand(["rg needle", "--native=false"]) }
    #expect(throws: (any Error).self) { try HeadlessCLI.importCommand(["rg needle", "--native", "--native"]) }
}

@Test(arguments: [
    #"{"command":"rg --files","directory":"/tmp","allowShell":true}"#,
    #"{"command":true,"directory":"/tmp"}"#,
    #"{"command":"rg --files","directory":3}"#,
    #"{"command":"rg --files","directory":"relative"}"#
])
func persistedNativeCommandsRejectUnknownFieldsAndTypeCoercions(json: String) {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(NativeSearchCommand.self, from: Data(json.utf8)) }
}

@Test func commandCLIRejectsCombiningSavedResultsWithSnapshot() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = try NativeSearchCommand(command: "rg --files", directory: root.path).snapshot()
    let command = CommandSpec(executable: try currentTestCLIExecutable(), arguments: ["--cli", "search",
        try HeadlessCLI.encoded(state), "--within", root.appendingPathComponent("missing.nul").path,
        "--snapshot", root.appendingPathComponent("missing.sqlite").path])
    let response = try await ProcessRunner.run(spec: command, pathOverride: Toolchain.defaultSearchPath)
    #expect(response.exitCode == 2)
    #expect(response.stdout.isEmpty)
    #expect(response.stderr.contains("Choose either --within saved results or --snapshot"))
}

@Test func nativeCommandsRefineOnlyWithinCapturedResultsAcrossRootsAndHiddenPaths() async throws {
    let first = try commandFixture(), second = try commandFixture()
    defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
    try FileManager.default.createDirectory(at: second.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    let included = [first.appendingPathComponent("one.swift"), second.appendingPathComponent(".hidden/two.swift")]
    for file in included { try Data("needle\n".utf8).write(to: file) }
    try Data("needle\n".utf8).write(to: second.appendingPathComponent("not-captured.swift"))
    let native = try NativeSearchCommand(command: "rg --files --hidden", directory: first.path).snapshot()
    let facet = ResultFacet(kind: .fileType, value: "swift", count: 2)
    #expect(throws: (any Error).self) { try facet.applying(to: native) }
    #expect(throws: (any Error).self) { try SearchPreset(name: "Invalid filter", kind: .filter, state: native).validate() }
    #expect(try SearchPreset(name: "Command", kind: .search, state: native).applying(to: native).nativeCommand == native.nativeCommand)
    let list = first.appendingPathComponent("results.nul")
    try Data((included.map(\.path).joined(separator: "\0") + "\0").utf8).write(to: list)
    let captured = native.searchingResults(.init(path: list.path, name: "Captured", count: included.count))
    #expect(captured.nativeCommand == nil && captured.mode == .everything)
    #expect(captured.resultScope?.previousFolderPath == first.path)
    let narrowed = try facet.applying(to: captured)
    let results = try await SearchService().search(request: narrowed.makeRequest())
    #expect(Set(results.results.map(\.path)) == Set(included.map(\.path)))
    #expect(narrowed.clearingResultScope().scopePath == first.path)
    #expect(narrowed.clearingResultScope().resultScope == nil)
    let cleared = narrowed.clearingResultScope()
    let folderResults = try await SearchService().search(request: cleared.makeRequest())
    #expect(folderResults.results.map(\.name) == ["one.swift"])
}

@Test func shortOptionClustersPreserveFlagValuesAndOperands() throws {
    let continued = "rg \\\n  -niF \\\n  -eNeedle ."
    #expect(try CLICommandParser.tokenize(continued) == CLICommandParser.tokenize("rg -niF -eNeedle ."))
    #expect(try SearchCommandArguments.expand(["-niF", "-eNeedle", "--regexp", "-ni", "--glob=-*", "--", "-ni", "."], tool: .rg)
        == ["-n", "-i", "-F", "-e", "Needle", "--regexp", "-ni", "--glob=-*", "--", "-ni", "."])
    #expect(try SearchCommandArguments.expand(["-HI", "-tf", "-eswift", "-0"], tool: .fd)
        == ["-H", "-I", "-t", "f", "-e", "swift", "-0"])
    #expect(try SearchCommandArguments.expand(["-r0", "rg", "-ni", "-eNeedle"], tool: .xargs)
        == ["-r", "-0", "rg", "-ni", "-eNeedle"])
    #expect(throws: (any Error).self) { try SearchCommandArguments.expand(["-niQ", "needle"], tool: .rg) }
    #expect(throws: (any Error).self) { try SearchCommandArguments.expand(["--regexp"], tool: .rg) }
    #expect(throws: (any Error).self) { try SearchCommandArguments.expand(["-e"], tool: .rg) }
}

@Test func compactShortOptionsExecuteEquallyThroughEditableAndNativeCommands() async throws {
    let root = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("Needle\nliteral -ni\n".utf8).write(to: root.appendingPathComponent("one.swift"))
    try Data("no match\n".utf8).write(to: root.appendingPathComponent("two.swift"))
    for command in ["rg -niF -eNeedle .", "rg \\\n  -niF \\\n  -eNeedle .", "fd -tf -eswift -0 | xargs -r0 rg -niF -eNeedle"] {
        let state = try CLICommandParser.parse(command, currentDirectory: root)
        let results = try await SearchService().search(request: state.makeRequest())
        #expect(results.results.map(\.name) == ["one.swift"])
        #expect(results.results.map(\.snippet) == ["Needle"])
    }
    for command in ["rg -niF -eNeedle .", "rg -F -e'-ni' .", "rg -- -ni ."] {
        let native = try NativeSearchCommand(command: command, directory: root.path).snapshot()
        let results = try await SearchService().search(request: native.makeRequest())
        #expect(results.results.map(\.name) == ["one.swift"])
    }
    let fuzzy = try CLICommandParser.parse("fd -tf -0 | fzf --read0 --print0 --no-extended -fone", currentDirectory: root)
    #expect(fuzzy.refinements.path == "one" && fuzzy.refinements.pathMatching == .fuzzy)
    #expect(try CLICommandParser.parse("rg -uu needle .", currentDirectory: root).includeHidden)
    #expect(throws: (any Error).self) { try CLICommandParser.parse("rg -niQ needle .", currentDirectory: root) }
    #expect(try NativeSearchCommand(command: "rg -niQ needle .", directory: root.path).parsed().arguments == ["-niQ", "needle", "."])
}
