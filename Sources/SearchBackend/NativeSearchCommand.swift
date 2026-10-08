import Foundation
import SearchCore

/// An explicitly selected command search. Only the original text and its
/// working directory are persisted. Recognized result formats are adapted to
/// rows; all other tool options run unchanged and stream as command output.
/// Tokenization still accepts one tool invocation rather than a shell program.
package struct NativeSearchCommand: Codable, Equatable, Hashable, Sendable {
    package var command: String
    package var directory: String
    package init(command: String, directory: String) {
        self.command = command
        self.directory = directory
    }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private enum CodingKeys: String, CodingKey { case command, directory }
    package init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["command", "directory"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A native command accepts only command and directory."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        command = try values.decode(String.self, forKey: .command)
        directory = try values.decode(String.self, forKey: .directory)
        _ = try parsed()
    }

    package struct Parsed: Sendable {
        package var tool: String
        package var arguments: [String]
        package var output: StreamFormat
        package var followsLinks: Bool
        package var scopePath: String? = nil
    }

    package func parsed() throws -> Parsed {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw Self.invalid("The command needs an absolute working folder.")
        }
        let stages = try CLICommandParser.tokenize(command)
        guard stages.count == 1, let words = stages.first, let executable = words.first else {
            throw Self.invalid("Command mode supports one fd, rg, or find command. Import supported pipelines into the controls instead.")
        }
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        let args = Array(words.dropFirst())
        switch tool {
        case "rg":
            return (try? Self.ripgrep(SearchCommandArguments.expand(args, tool: .rg)))
                ?? Self.unadapted(tool: "rg", arguments: args)
        case "fd", "fdfind":
            return (try? Self.fd(SearchCommandArguments.expand(args, tool: .fd)))
                ?? Self.unadapted(tool: "fd", arguments: args)
        case "find": return (try? Self.find(args)) ?? Self.unadapted(tool: "find", arguments: args)
        case "FindUI", "findui": return try Self.snapshotSearch(args)
        default: throw Self.invalid("Command mode supports fd, rg, and find commands.")
        }
    }

    private static func unadapted(tool: String, arguments: [String]) -> Parsed {
        // Do not guess the arity or output semantics of an unfamiliar option,
        // drop arguments, or retry a command after it has already executed.
        Parsed(tool: tool, arguments: arguments, output: .text, followsLinks: false)
    }

    package func snapshot() throws -> SearchState {
        snapshot(try parsed())
    }

    private func snapshot(_ parsed: Parsed) -> SearchState {
        var state = SearchState(query: "", mode: parsed.output == .paths ? .everything : .contents,
            scopePath: parsed.scopePath ?? directory, useIndex: false, includeHidden: false, caseSensitive: true,
            syntax: .regex, exactNameMatch: false, selectedDrivePath: nil,
            indexedFilter: parsed.output == .paths ? .everything : .files,
            traversal: .init(excludedFolders: []), sourceCommand: command)
        state.traversal.followSymlinks = parsed.followsLinks
        state.refinements.extraction = nil
        state.nativeCommand = self
        return state
    }

    package func pipeline(tools: Toolchain, state: SearchState) throws -> SearchPipeline {
        let parsed = try parsed()
        var expected = snapshot(parsed)
        expected.sourceCommand = state.sourceCommand
        expected.selectedDrivePath = state.selectedDrivePath
        // Inactive date-picker values are presentation state and can have
        // been saved on an earlier day. They never constrain command mode.
        expected.filters.dateFrom = state.filters.dateFrom
        expected.filters.dateThrough = state.filters.dateThrough
        guard expected == state else {
            throw Self.invalid("Command searches use the displayed command. Switch to search controls before adding other conditions.")
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Self.invalid("Search folder is unavailable: \(directory)")
        }
        let executable: URL?
        switch parsed.tool {
        case "rg": executable = tools.rg
        case "fd": executable = tools.fd
        case "FindUI": executable = HeadlessCLI.executable
        default: executable = tools.find
        }
        guard let executable else { throw SearchServiceError.missingTool(parsed.tool) }
        var invocation = Invocation(executable.path, parsed.arguments,
            emptyExitCodes: parsed.tool == "rg" ? [1] : [])
        invocation.workingDirectory = parsed.tool == "FindUI" ? nil : directory
        // Disable ambient tool configuration as for ordinary FindUI searches.
        if parsed.tool != "FindUI" {
            invocation.unsetEnvironment = ["RIPGREP_CONFIG_PATH", "FZF_DEFAULT_OPTS", "FZF_DEFAULT_OPTS_FILE", "FZF_DEFAULT_COMMAND"]
        }
        var query = SearchQuery()
        query.traversal.roots = [directory]
        if parsed.output != .paths { query.contents = .leaf(.allLines) }
        let stage = PlanStage(parsed.output == .text ? .command : parsed.output == .paths ? .enumerate : .scan, invocation,
            output: parsed.output, label: parsed.tool == "FindUI" ? "Snapshot command" : parsed.tool + " command")
        return SearchPipeline(plan: try ExecutionPlan(query: query, stages: [stage],
            reasons: [parsed.output == .text
                ? "Tool arguments run unchanged; output is displayed as text."
                : "Explicit native command: search options are preserved and result output is adapted for the table."]))
    }

    private static func invalid(_ message: String) -> SearchServiceError { .commandFailed(message) }

    /// Copied snapshot commands keep their explicit artifact and reference
    /// clock. An external snapshot is shown in command mode; it must never be
    /// silently replaced with a live walk or an unrelated managed drive index.
    private static func snapshotSearch(_ args: [String]) throws -> Parsed {
        guard args.count == 5 || (args.count == 6 && args.last == "--stats"),
              args[0] == "--cli", ["search", "browse"].contains(args[1]),
              args[3] == "--snapshot", args[4].hasPrefix("/"), !args[4].contains("\0"),
              let object = try JSONSerialization.jsonObject(with: Data(args[2].utf8)) as? [String: Any],
              let stateObject = (object["state"] ?? object) as? [String: Any],
              stateObject["nativeCommand"] == nil || stateObject["nativeCommand"] is NSNull else {
            throw invalid("Import a copied FindUI snapshot search with inline JSON and an absolute --snapshot path. Other FindUI commands and nested command searches are not supported.")
        }
        let description = try JSONDecoder().decode(HeadlessCLI.SearchDescription.self, from: Data(args[2].utf8))
        let state = description.state
        guard state.mode != .contents, state.resultScope == nil, description.referenceDate.timeIntervalSince1970.isFinite else {
            throw invalid("A snapshot command must search filenames in its saved index.")
        }
        try state.validateExpressions()
        try state.traversal.validate()
        try state.ruleSet?.validate(now: description.referenceDate)
        // Only the resolved local CLI is executed. The pasted executable path
        // is never trusted, and mutating CLI subcommands cannot reach here.
        return Parsed(tool: "FindUI", arguments: args, output: .paths,
            followsLinks: state.traversal.followSymlinks, scopePath: state.scopePath)
    }

    private struct Reader {
        var words: [String]
        var index = 0
        mutating func take() -> String? {
            guard index < words.count else { return nil }
            defer { index += 1 }; return words[index]
        }
        mutating func value(_ flag: String, _ inline: String?) throws -> String {
            if let inline { return inline }
            guard let value = take() else { throw invalid("\(flag) needs a value.") }
            return value
        }
    }

    private static func splitFlag(_ word: String) -> (String, String?) {
        guard word.hasPrefix("--"), let separator = word.firstIndex(of: "=") else { return (word, nil) }
        return (String(word[..<separator]), String(word[word.index(after: separator)...]))
    }

    private static func ripgrep(_ words: [String]) throws -> Parsed {
        let flags: Set<String> = ["-F", "--fixed-strings", "-i", "--ignore-case", "-s", "--case-sensitive",
            "-S", "--smart-case", "-P", "--pcre2", "--no-pcre2", "-U", "--multiline", "--no-multiline",
            "--multiline-dotall", "--no-multiline-dotall", "-w", "--word-regexp", "-x", "--line-regexp",
            "-v", "--invert-match", "-a", "--text", "--no-text", "--hidden", "--no-hidden", "--no-ignore",
            "--ignore", "--no-ignore-vcs", "--no-ignore-parent", "--no-ignore-global", "--no-ignore-dot",
            "--no-ignore-exclude", "--no-ignore-files", "--ignore-file-case-insensitive", "--no-require-git",
            "-L", "--follow", "--no-follow", "--one-file-system", "--crlf", "--no-crlf", "--null-data",
            "--unicode", "--no-unicode", "--no-messages", "--messages", "--no-mmap", "--mmap",
            "--no-line-buffered", "--line-buffered", "--block-buffered", "--no-config", "-u", "--unrestricted",
            "--binary", "--no-binary", "--no-invert-match"]
        let values: Set<String> = ["-e", "--regexp", "-g", "--glob", "--iglob", "-t", "--type", "-T", "--type-not",
            "--type-add", "--type-clear", "-j", "--threads", "--encoding", "--max-depth", "--max-filesize",
            "-m", "--max-count", "--regex-size-limit", "--dfa-size-limit", "--engine", "--sort", "--sortr",
            "--ignore-file"]
        let presentation: Set<String> = ["-n", "--line-number", "-N", "--no-line-number", "--heading", "--no-heading",
            "-H", "--with-filename", "-I", "--no-filename", "--json", "-0", "--null", "--stats", "--no-stats"]
        var reader = Reader(words: words), options = ["--no-config"], positional: [String] = []
        var ended = false, hasPattern = false, files = false, filesWithMatches = false, filesWithoutMatches = false
        var follow = false
        while let word = reader.take() {
            if ended || !word.hasPrefix("-") || word == "-" { positional.append(word); continue }
            if word == "--" { ended = true; continue }
            let (flag, inline) = splitFlag(word)
            if values.contains(flag) {
                let value = try reader.value(flag, inline)
                if flag == "-e" || flag == "--regexp" { hasPattern = true }
                options += [flag, value]
            } else if flags.contains(flag) {
                guard inline == nil else { throw invalid("\(flag) does not take a value.") }
                options.append(flag)
                if ["-L", "--follow"].contains(flag) { follow = true }
                if flag == "--no-follow" { follow = false }
            } else if presentation.contains(flag) {
                guard inline == nil else { throw invalid("\(flag) does not take a value.") }
            } else if flag == "--color" {
                _ = try reader.value(flag, inline)
            } else if ["--files", "-l", "--files-with-matches", "--files-without-match"].contains(flag) {
                guard inline == nil else { throw invalid("\(flag) does not take a value.") }
                if flag == "--files" { files = true }
                else if flag == "--files-without-match" { filesWithoutMatches = true; filesWithMatches = false }
                else { filesWithMatches = true; filesWithoutMatches = false }
            } else {
                throw invalid("This rg option requires unadapted command output: \(flag).")
            }
        }
        if files {
            guard !hasPattern, !filesWithMatches, !filesWithoutMatches else { throw invalid("Use rg --files without content patterns or match-output flags.") }
        } else if !hasPattern {
            guard !positional.isEmpty else { throw invalid("rg needs a content pattern.") }
            options += ["--regexp", positional.removeFirst()]
        }
        guard !positional.contains("-") else { throw invalid("Search a file or folder; command mode does not read standard input.") }
        let output: StreamFormat = files || filesWithMatches || filesWithoutMatches ? .paths : .matches
        if files { options += ["--files", "--null"] }
        else if filesWithMatches { options += ["--files-with-matches", "--null"] }
        else if filesWithoutMatches { options += ["--files-without-match", "--null"] }
        else { options += ["--json", "--line-number"] }
        options += ["--color", "never", "--"] + (positional.isEmpty ? ["."] : positional)
        return Parsed(tool: "rg", arguments: options, output: output, followsLinks: follow)
    }

    private static func fd(_ words: [String]) throws -> Parsed {
        let flags: Set<String> = ["-H", "--hidden", "--no-hidden", "-I", "--no-ignore", "--ignore", "--no-ignore-vcs",
            "--no-ignore-parent", "-u", "--unrestricted", "-s", "--case-sensitive", "-i", "--ignore-case",
            "-F", "--fixed-strings", "-g", "--glob", "--regex", "--exact", "-p", "--full-path", "-L", "--follow",
            "--one-file-system", "--prune", "--show-errors", "--no-require-git"]
        let values: Set<String> = ["-t", "--type", "-e", "--extension", "-E", "--exclude", "--ignore-file",
            "-d", "--max-depth", "--min-depth", "--exact-depth", "-S", "--size", "--changed-within",
            "--changed-before", "--owner", "--and", "-j", "--threads", "--max-results"]
        let presentation: Set<String> = ["-0", "--print0", "--absolute-path", "--strip-cwd-prefix"]
        var reader = Reader(words: words), output: [String] = [], positional: [String] = []
        var ended = false, follow = false
        while let word = reader.take() {
            if ended || !word.hasPrefix("-") || word == "-" { positional.append(word); continue }
            if word == "--" { ended = true; continue }
            let (flag, inline) = splitFlag(word)
            if values.contains(flag) { output += [flag, try reader.value(flag, inline)] }
            else if flags.contains(flag) {
                guard inline == nil else { throw invalid("\(flag) does not take a value.") }
                output.append(flag); if ["-L", "--follow"].contains(flag) { follow = true }
            } else if presentation.contains(flag) {
                guard inline == nil else { throw invalid("\(flag) does not take a value.") }
            } else if flag == "--color" { _ = try reader.value(flag, inline) }
            else { throw invalid("This fd option requires unadapted command output: \(flag).") }
        }
        output += ["--print0", "--absolute-path", "--color", "never", "--"] + positional
        return Parsed(tool: "fd", arguments: output, output: .paths, followsLinks: follow)
    }

    private static func find(_ words: [String]) throws -> Parsed {
        let values: Set<String> = ["-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-type", "-size",
            "-mtime", "-atime", "-ctime", "-mmin", "-amin", "-cmin", "-newer", "-anewer", "-cnewer",
            "-user", "-group", "-uid", "-gid", "-perm", "-inum", "-links", "-flags", "-fstype", "-mindepth", "-maxdepth"]
        let predicates: Set<String> = ["-empty", "-nouser", "-nogroup", "-true", "-false", "-prune", "-xdev", "-depth"]
        let operators: Set<String> = ["(", ")", "!", "-not", "-a", "-and", "-o", "-or"]
        var reader = Reader(words: words), preamble: [String] = [], roots: [String] = [], expression: [String] = []
        var started = false, hasOutput = false, follow = false, balance = 0
        while let word = reader.take() {
            if !started, ["-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d"].contains(word), roots.isEmpty {
                preamble.append(word)
                if word == "-L" || word == "-H" { follow = true }; if word == "-P" { follow = false }
                continue
            }
            if !started, !word.hasPrefix("-"), !operators.contains(word) { roots.append(word); continue }
            started = true
            if values.contains(word) { expression += [word, try reader.value(word, nil)] }
            else if predicates.contains(word) || operators.contains(word) {
                if word == "(" { balance += 1 }; if word == ")" { balance -= 1 }
                guard balance >= 0, balance <= 64 else { throw invalid("Unbalanced or excessively nested find groups.") }
                expression.append(word)
            } else if word == "-print" || word == "-print0" { expression.append("-print0"); hasOutput = true }
            else { throw invalid("This find predicate requires unadapted command output: \(word).") }
        }
        guard balance == 0 else { throw invalid("Close every find expression group.") }
        if !hasOutput { expression = expression.isEmpty ? ["-print0"] : ["("] + expression + [")", "-print0"] }
        return Parsed(tool: "find", arguments: preamble + (roots.isEmpty ? ["."] : roots) + expression,
            output: .paths, followsLinks: follow)
    }
}
