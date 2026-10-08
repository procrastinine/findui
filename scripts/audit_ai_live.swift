// Opt-in live provider evaluation. Credentials remain in memory; only synthetic
// prompts, generated rules, timings and fixture results enter the report.
import Foundation
import SearchBackend
import SearchCore

private actor MeasuredAIClient: AISearchGenerating {
    let client: any AISearchGenerating
    var calls = 0
    var outputs: [String] = []
    init(_ client: any AISearchGenerating) { self.client = client }
    func generate(messages: [AISearchMessage], schema: Data) async throws -> String {
        calls += 1
        let output = try await client.generate(messages: messages, schema: schema)
        outputs.append(output)
        return output
    }
}

@main struct LiveAISearchAudit {
    struct Check {
        let id: String
        let prompt: String
        let expected: Set<String>?
        var documents = false
        var archives = false
    }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let provider = option("--provider"), ["codex", "openrouter"].contains(provider),
              let output = option("--output") else {
            throw AISearchError.message("Use --provider codex|openrouter --output report.json [--key-file key.txt] [--model ID] [--cases comma,separated]. This makes real model requests.")
        }
        var settings = AISearchSettings(); settings.enabled = true
        let client: any AISearchGenerating
        if provider == "codex" {
            settings.provider = .codex; settings.codexModel = option("--model") ?? "gpt-6.1-sol"
            client = CodexSearchClient(settings: settings)
        } else {
            settings.baseURL = "https://openrouter.ai/api/v1"; settings.model = option("--model") ?? "google/gemini-3.8-flash"
            guard let keyFile = option("--key-file") else { throw AISearchError.message("OpenRouter needs --key-file. Do not put the key itself in arguments.") }
            let data = try Data(contentsOf: URL(fileURLWithPath: keyFile))
            guard data.count < 64 * 1024, let text = String(data: data, encoding: .utf8) else { throw AISearchError.message("Invalid key file.") }
            let regex = try NSRegularExpression(pattern: "sk-or-v1-[A-Za-z0-9_-]+")
            let keys = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
            guard keys.count == 1, let key = keys.first else { throw AISearchError.message("The key file must contain one OpenRouter key.") }
            client = AISearchHTTPClient(settings: settings, apiKey: key)
        }
        let measured = MeasuredAIClient(client)
        let service = AISearchService(client: measured)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-live-ai-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [String: String] = [
            "report.txt": "annual report\n", "Report-final.md": "summary\n", "unrelated.txt": "ordinary\n",
            "task.swift": "TODO implement\n", "wrong.swift": "FIXME\n", "notes.md": "FIXME revise\n", "wrong.md": "TODO\n",
            "generated.swift": "TODO\n", "generated-notes.md": "FIXME\n", ".Hidden.swift": "TODO\n",
            "split.txt": "alpha\nbeta\n", "together.txt": "alpha beta\n", "banned.txt": "alpha beta\nbanned\n",
            "keep-empty.bin": "", "keep-binary.bin": "\0binary", "needle.txt": "needle\n", "alpha.txt": "alpha\n"]
        for (name, contents) in fixtures { try Data(contents.utf8).write(to: root.appendingPathComponent(name)) }
        var initial = SearchRequest(query: "", mode: .files, scope: root, includeHidden: false, caseSensitive: false,
            syntax: .literal, exactNameMatch: false, maxResults: 100).state
        initial.traversal.excludedFolders = [".git"]
        let cases = [
            Check(id: "filename", prompt: "Find files whose filename contains report, case insensitive. Return filenames.", expected: ["report.txt", "Report-final.md"]),
            Check(id: "typed_hidden", prompt: "Return filenames of Swift files containing the literal TODO, case sensitive contents. Exclude hidden files. Match the extension case insensitively.", expected: ["task.swift", "generated.swift"]),
            Check(id: "mixed", prompt: "Return files matching ((Swift files containing literal TODO) OR (Markdown files containing literal FIXME)) AND filename does not contain generated. Content is case sensitive, and may occur anywhere in the same file. Do not include hidden files.", expected: ["task.swift", "notes.md"]),
            Check(id: "whole_file_not", prompt: "Find txt files containing both alpha and beta anywhere in the same file, even on different lines, with no occurrence of banned anywhere in the file. Literal, case-sensitive text. Return filenames.", expected: ["split.txt", "together.txt"]),
            Check(id: "file_only_branch", prompt: "Return files whose filename contains keep OR whose contents contain the literal needle anywhere in the file. The filename branch must also admit empty and binary files without requiring content. Exclude hidden files.", expected: ["keep-empty.bin", "keep-binary.bin", "needle.txt"]),
            Check(id: "documents", prompt: "Find PDF and Office documents containing the literal budget using document readers, without OCR or expanding archives. Return filenames.", expected: [], documents: true),
            Check(id: "scope_clarification", prompt: "Search in /Volumes/Accounting instead of the currently selected folder for invoices.", expected: nil),
            Check(id: "unsupported_clarification", prompt: "Find scanned PDFs whose images contain the word invoice using OCR.", expected: nil)
        ]
        let selected = option("--cases").map { Set($0.split(separator: ",").map(String.init)) }
        let model = provider == "codex" ? settings.codexModel : settings.model
        var rows: [[String: Any]] = []
        let binary = URL(fileURLWithPath: option("--binary") ?? "dist/FindUI.app/Contents/MacOS/FindUI").standardizedFileURL
        func save() throws {
            let report: [String: Any] = ["provider": provider, "model": model, "date": ISO8601DateFormatter().string(from: .now),
                "fixtureOnly": true, "cases": rows]
            let target = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: target, options: .atomic)
        }
        for check in cases where selected == nil || selected!.contains(check.id) {
            print("RUN \(provider)/\(model): \(check.id)")
            fflush(stdout)
            let started = Date(), before = await measured.calls
            var row: [String: Any] = ["case": check.id, "prompt": check.prompt]
            do {
                let proposal = try await service.propose(check.prompt, state: initial)
                row["summary"] = proposal.summary
                if let expected = check.expected {
                    guard let state = proposal.state, proposal.clarification == nil else { throw AISearchError.message("Unexpected clarification: \(proposal.clarification ?? "none")") }
                    guard state.scopePath == initial.scopePath, !state.includeHidden,
                          (state.refinements.extraction?.documents ?? false) == check.documents,
                          (state.refinements.extraction?.archives ?? false) == check.archives else { throw AISearchError.message("Scope, hidden or extraction settings changed incorrectly.") }
                    let data = try JSONEncoder().encode(state)
                    row["state"] = try JSONSerialization.jsonObject(with: data)
                    let response = try await AICommandProcess.run(binary, arguments: ["--cli", "search", String(decoding: data, as: UTF8.self)], timeout: 30)
                    guard response.exitCode == 0 else { throw AISearchError.message("Compiled search failed: \(response.stderr)") }
                    let paths: [String]
                    if response.stdout.first == "{" {
                        paths = try response.stdout.split(separator: "\n").compactMap { line in
                            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                            guard row?["type"] as? String == "match", let data = row?["data"] as? [String: Any], let path = data["path"] as? [String: Any] else { return nil }
                            return path["text"] as? String
                        }
                    } else { paths = response.stdout.split(separator: "\0").map(String.init) }
                    let actual = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
                    row["actual"] = actual.sorted(); row["expected"] = expected.sorted()
                    guard actual == expected else { throw AISearchError.message("Independent fixture results disagree.") }
                } else {
                    guard proposal.state == nil, proposal.clarification?.isEmpty == false else { throw AISearchError.message("Unsupported request became a runnable search.") }
                    row["clarification"] = proposal.clarification
                }
                row["passed"] = true
            } catch {
                row["passed"] = false; row["error"] = error.localizedDescription
            }
            row["seconds"] = Date().timeIntervalSince(started)
            row["modelCalls"] = await measured.calls - before
            row["responses"] = Array(await measured.outputs.suffix(row["modelCalls"] as! Int))
            rows.append(row); try save()
            print("\(row["passed"] as? Bool == true ? "PASS" : "FAIL") \(check.id): \(String(format: "%.2f", row["seconds"] as! Double)) s, \(row["modelCalls"]!) call(s)\(row["error"].map { ": \($0)" } ?? "")")
            fflush(stdout)
            // A failed transport cannot benefit from spending on more prompts.
            if row["passed"] as? Bool != true && row["summary"] == nil { break }
        }
        guard !rows.isEmpty, rows.allSatisfy({ $0["passed"] as? Bool == true }) else { throw AISearchError.message("Live AI audit failed; inspect the credential-free report.") }
    }
}
