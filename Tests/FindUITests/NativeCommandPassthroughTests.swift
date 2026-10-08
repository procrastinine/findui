import Foundation
import Testing
@testable import SearchBackend
@testable import FindUI

@Test(arguments: ["rg -f patterns.txt one.swift", "rg --pre /bin/cat needle one.swift",
    "rg --count needle one.swift", "rg --replace changed needle one.swift",
    "rg -A1 needle one.swift", "fd --format '{/}' one", "find . -type f -ls"])
func commandOptionsRunThroughTheToolAndPreserveItsOutput(command: String) async throws {
    let root = try passthroughFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = Toolchain.resolve(includeDocumentReaders: false)
    let native = NativeSearchCommand(command: command, directory: root.path)
    let parsed = try native.parsed()
    #expect(parsed.output == .text)
    let words = try #require(CLICommandParser.tokenize(command).first)
    #expect(parsed.arguments == Array(words.dropFirst()))
    let executable = try #require(parsed.tool == "rg" ? tools.rg : parsed.tool == "fd" ? tools.fd : tools.find)
    let expected = try await ProcessRunner.run(spec: CommandSpec(executable: executable,
        arguments: parsed.arguments, workingDirectory: root), pathOverride: tools.searchPath)
    #expect(expected.exitCode == 0)
    let response = try await SearchService(tools: tools).search(request: native.snapshot().makeRequest())
    #expect(response.results.isEmpty)
    #expect(response.commandOutput?.text == expected.stdout)
    let restored = try CLICommandParser.parse(response.commandPreview, currentDirectory: root)
    #expect(restored.nativeCommand == native)
    let again = try await SearchService(tools: tools).search(request: restored.makeRequest())
    #expect(again.commandOutput == response.commandOutput)
    #expect(again.commandPreview == response.commandPreview)
}

@Test func commandActionsArePassedThroughWithoutASecondExecution() async throws {
    let root = try passthroughFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    // A harmless action emits output without a newline and appends one marker.
    let action = root.appendingPathComponent("action.sh")
    try Data("#!/bin/sh\nprintf x >> calls\nprintf 'output without newline'\n".utf8).write(to: action)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: action.path)
    let state = try NativeSearchCommand(command: "fd -t f '^one\\.swift$' --exec ./action.sh", directory: root.path).snapshot()
    let response = try await SearchService().search(request: state.makeRequest())
    #expect(response.commandOutput?.text == "output without newline")
    #expect(try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8) == "x")
}

@Test(arguments: ["rg --option-that-does-not-exist needle .", "fd --option-that-does-not-exist", "find . -option-that-does-not-exist"])
func unrecognizedOptionsReachTheToolAndReturnItsDiagnostic(command: String) async throws {
    let root = try passthroughFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = try NativeSearchCommand(command: command, directory: root.path).snapshot()
    do {
        _ = try await SearchService().search(request: state.makeRequest())
        Issue.record("The tool should reject an unknown option.")
    } catch {
        #expect(error.localizedDescription.contains("Command failed (exit"))
        #expect(error.localizedDescription.contains("option-that-does-not-exist"))
    }
}

@Test(arguments: ["find . -delete", #"find . -exec echo {} \;"#, "fd --exec-batch=echo x", "rg --pre=cat needle", "rg -f /tmp/patterns"])
func allToolActionsCanBeStoredWithoutExecutingThem(command: String) throws {
    let native = NativeSearchCommand(command: command, directory: "/tmp")
    let saved = try JSONEncoder().encode(native)
    #expect(try JSONDecoder().decode(NativeSearchCommand.self, from: saved) == native)
    #expect(try native.parsed().output == .text)
}

@Test func commandTextRetentionIsBoundedAndReassemblesUTF8Chunks() async {
    let accumulator = CommandTextAccumulator()
    let bytes = Data("café".utf8)
    _ = await accumulator.append(bytes.prefix(4))
    _ = await accumulator.append(bytes.suffix(1))
    #expect(await accumulator.snapshot().text == "café")
    _ = await accumulator.append(Data(repeating: 65, count: CommandTextOutput.maximumBytes + 100))
    let output = await accumulator.snapshot()
    #expect(output.isTruncated)
    #expect(output.text.utf8.count == CommandTextOutput.maximumBytes)
}

@Test func headlessCommandOutputRetainsExactBytesAndExitStatus() async throws {
    let root = try passthroughFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let action = root.appendingPathComponent("output.sh")
    try Data("#!/bin/sh\nprintf plain\n".utf8).write(to: action)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: action.path)
    let cli = try currentTestCLIExecutable()
    let tools = Toolchain.resolve(includeDocumentReaders: false)
    for (command, expectedOutput, expectedExit) in [
        ("rg --count needle one.swift", "2\n", Int32(0)),
        ("rg --quiet absent one.swift", "", Int32(1)),
        ("fd -t f '^one\\.swift$' --exec ./output.sh", "plain", Int32(0))
    ] {
        let state = try NativeSearchCommand(command: command, directory: root.path).snapshot()
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let run = try await ProcessRunner.run(spec: CommandSpec(executable: cli,
            arguments: ["--cli", "search", json]), pathOverride: tools.searchPath)
        #expect(run.stdout == expectedOutput, "\(command): \(run.stderr)")
        #expect(run.exitCode == expectedExit, "\(command): \(run.stderr)")
    }
}

@Test @MainActor func commandOutputAndErrorsReachTheGUIAndClearForTheNextSearch() async throws {
    let root = try passthroughFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("state")), loadSavedState: false)
    defer { model.shutdown() }
    model.scopeURL = root
    for command in ["rg --count needle one.swift", "rg --option-that-does-not-exist needle one.swift", "rg needle one.swift"] {
        try model.importCommand(command, runNative: true)
        model.scheduleSearch(immediate: true)
        let deadline = ContinuousClock.now + .seconds(10)
        // Wait for the scheduled task to begin before observing its completion.
        try await Task.sleep(for: .milliseconds(30))
        while model.isSearching && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isSearching)
        if command.contains("--count") {
            #expect(model.commandOutput?.text == "2\n")
            #expect(model.commandError == nil)
        } else if command.contains("does-not-exist") {
            #expect(model.commandError?.contains("option-that-does-not-exist") == true)
        } else {
            #expect(model.commandOutput == nil && model.commandError == nil)
            #expect(model.results.count == 2)
        }
    }
}

private func passthroughFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-command-options-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("needle\ncontext\nneedle\n".utf8).write(to: root.appendingPathComponent("one.swift"))
    try Data("needle\n".utf8).write(to: root.appendingPathComponent("patterns.txt"))
    return root
}
