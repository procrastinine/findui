import Foundation
import SearchCore

/// Imports an allowlisted command into controls. Input is never handed to a shell.
package enum CLICommandParser {
    package static let maximumCommandBytes = 4 * 1024 * 1024
    private static func invalid(_ message: String) -> SearchServiceError { .commandFailed(message) }

    package static func parse(_ input: String, currentDirectory: URL) throws -> SearchSnapshot {
        if let exported = try SearchCommandExport.restore(input) { return exported }
        let stages = try tokenize(input)
        guard let first = stages.first, let tool = first.first else { throw invalid("Enter an fd, rg, or find command.") }
        var snapshot = SearchSnapshot(query: "", mode: .everything, scopePath: currentDirectory.path,
            useIndex: false, includeHidden: false, caseSensitive: false, syntax: .literal,
            exactNameMatch: false, selectedDrivePath: nil, indexedFilter: .everything,
            traversal: .init(excludedFolders: []))
        // Importing rg must preserve its plain-file semantics.
        snapshot.refinements.extraction = nil
        var nullSeparated = false
        switch URL(fileURLWithPath: tool).lastPathComponent {
        case "FindUI", "findui":
            guard stages.count == 1 else { throw invalid("Import the copied snapshot command without extra pipeline stages.") }
            return try NativeSearchCommand(command: input, directory: currentDirectory.path).snapshot()
        case "fd", "fdfind": nullSeparated = try parseFD(Array(first.dropFirst()), into: &snapshot, base: currentDirectory)
        case "rg": nullSeparated = try parseRG(Array(first.dropFirst()), into: &snapshot, base: currentDirectory, piped: false)
        case "find": nullSeparated = try parseFind(Array(first.dropFirst()), into: &snapshot, base: currentDirectory)
        default: throw invalid("Supported tools are fd, rg, find, and a final fzf --filter stage.")
        }
        for stage in stages.dropFirst() {
            guard snapshot.mode != .contents else { throw invalid("The content search must be the last stage.") }
            guard nullSeparated else { throw invalid("Use fd -0 or find -print0 before a pipeline so filenames with spaces and newlines are preserved.") }
            switch URL(fileURLWithPath: stage[0]).lastPathComponent {
            case "xargs":
                guard snapshot.mode == .files else {
                    throw invalid("Select regular files before searching contents, such as fd --type f. Passing directories to rg changes the traversal.")
                }
                var args = try SearchCommandArguments.expand(Array(stage.dropFirst()), tool: .xargs)
                var hasNull = false
                while let option = args.first, ["-0", "--null", "-r", "--no-run-if-empty"].contains(option) {
                    if option == "-0" || option == "--null" { hasNull = true }
                    args.removeFirst()
                }
                guard hasNull else { throw invalid("Use xargs -0 rg for a content-search stage.") }
                guard let executable = args.first, URL(fileURLWithPath: executable).lastPathComponent == "rg" else {
                    throw invalid("Only xargs -0 rg is supported. Other commands cannot be shown as search controls.")
                }
                _ = try parseRG(Array(args.dropFirst()), into: &snapshot, base: currentDirectory, piped: true)
                nullSeparated = false
            case "fzf": try parseFZF(Array(stage.dropFirst()), into: &snapshot)
            default: throw invalid("Use xargs -0 rg to search inside candidate files, or fzf --read0 --filter to rank their paths.")
            }
        }
        snapshot.indexedFilter = snapshot.mode == .folders ? .folders : snapshot.mode == .everything ? .everything : .files
        snapshot.traversal = snapshot.traversal.normalized
        try snapshot.traversal.validate(allowRoot: snapshot.resultScope != nil)
        _ = try snapshot.filters.validated()
        try snapshot.ruleSet?.validate(now: .now)
        snapshot.sourceCommand = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot
    }

    /// POSIX quoting without expansions, substitutions, redirections, or shell actions.
    package static func tokenize(_ input: String, maximumBytes: Int = maximumCommandBytes) throws -> [[String]] {
        guard input.utf8.count <= maximumBytes, !input.contains("\0") else { throw invalid("The command is too long or contains a NUL character.") }
        var stages: [[String]] = []; var words: [String] = []; var word = ""
        var quote: Character?; var started = false; var escape = false
        let chars = Array(input)
        func finishWord() { if started { words.append(word); word = ""; started = false } }
        for (index, char) in chars.enumerated() {
            if escape {
                if char != "\n" {
                    if quote == "\"", !"\\\"$`".contains(char) { word.append("\\") }
                    word.append(char); started = true
                }
                escape = false; continue
            }
            if char == "\\" && quote != "'" { escape = true; continue }
            if char == quote { quote = nil; continue }
            if quote == "'" { word.append(char); continue }
            if char == "`" || (char == "$" && index + 1 < chars.count && (chars[index + 1].isLetter || "({_0123456789?!#*@".contains(chars[index + 1]))) {
                throw invalid("Shell substitutions and variables are not supported. Enter literal paths and patterns.")
            }
            if quote != nil { word.append(char); continue }
            if char == "'" || char == "\"" { quote = char; started = true; continue }
            if ";&<>()".contains(char) { throw invalid("Shell actions, redirections, and grouped commands cannot be imported.") }
            if char == "|" {
                finishWord()
                guard !words.isEmpty else { throw invalid("Each pipeline stage needs a command.") }
                stages.append(words); words = []; continue
            }
            if char == "#", !started {
                throw invalid("Shell comments are not supported. Paste the search command without an explanatory comment.")
            }
            if char.isWhitespace {
                if (char == "\n" || char == "\r"), (started || !words.isEmpty),
                    chars.dropFirst(index + 1).contains(where: { !$0.isWhitespace }) {
                    throw invalid("Use one command. Continue long commands with a backslash before the line break.")
                }
                finishWord(); continue
            }
            word.append(char); started = true
        }
        guard quote == nil, !escape else { throw invalid("Close the quote or finish the escaped character.") }
        finishWord()
        guard !words.isEmpty else { throw invalid("Enter a complete command.") }
        stages.append(words)
        guard stages.count <= 3 else { throw invalid("Use an enumeration, optional fzf filter, and optional content-search stage.") }
        return stages
    }

    private struct Arguments {
        var words: [String]; var index = 0; var ended = false
        mutating func next() -> (String, String?)? {
            guard index < words.count else { return nil }
            let word = words[index]; index += 1
            if !ended && word == "--" { ended = true; return next() }
            if !ended && word.hasPrefix("--"), let equal = word.firstIndex(of: "=") {
                return (String(word[..<equal]), String(word[word.index(after: equal)...]))
            }
            return (word, nil)
        }
        mutating func value(_ flag: String, _ inline: String?) throws -> String {
            if let inline { return inline }
            guard index < words.count else { throw invalid("\(flag) needs a value.") }
            defer { index += 1 }; return words[index]
        }
    }

    private static func roots(_ paths: [String], into s: inout SearchSnapshot, base: URL) throws {
        let resolved = (paths.isEmpty ? [base.path] : paths).map { path in
            let expanded = (path as NSString).expandingTildeInPath
            return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)).standardizedFileURL.path
        }
        s.scopePath = resolved[0]; s.refinements.additionalScopes = Array(resolved.dropFirst())
    }

    private static func parseFD(_ words: [String], into s: inout SearchSnapshot, base: URL) throws -> Bool {
        let words = try SearchCommandArguments.expand(words, tool: .fd)
        var args = Arguments(words: words); var positional: [String] = []; var extensions: [String] = []
        var matching = PatternMatching.regex; var fullPath = false; var sensitive: Bool?; var null = false
        var types = Set<String>(); var requiredPatterns: [String] = []; var excludesHidden = false
        while let (flag, inline) = args.next() {
            if args.ended || !flag.hasPrefix("-") || flag == "-" { positional.append(flag); continue }
            switch flag {
            case "-t", "--type": types.insert(try args.value(flag, inline))
            case "-g", "--glob": matching = .glob
            case "-F", "--fixed-strings": matching = .contains
            case "--exact": matching = .exact
            case "--and": requiredPatterns.append(try args.value(flag, inline))
            case "--threads", "-j": s.refinements.workers = try integer(args.value(flag, inline), flag)
            case "--show-errors": break
            case "-p", "--full-path": fullPath = true
            case "-i", "--ignore-case": sensitive = false
            case "-s", "--case-sensitive": sensitive = true
            case "-H", "--hidden": s.includeHidden = true
            case "-I", "--no-ignore": s.traversal.includeIgnored = true
            case "-u", "--unrestricted": s.includeHidden = true; s.traversal.includeIgnored = true
            case "-L", "--follow": s.traversal.followSymlinks = true
            case "-e", "--extension": extensions.append(try args.value(flag, inline))
            case "-E", "--exclude":
                let value = try args.value(flag, inline)
                if value == ".*" { excludesHidden = true; continue }
                if value.hasSuffix("/"), let folder = literalGlob(String(value.dropLast())), !folder.contains("/") {
                    s.traversal.excludedFolders.append(folder); continue
                }
                guard !value.contains(where: { "*?".contains($0) }) else {
                    throw invalid("fd exclusion globs also prune matching directories. Import literal folder exclusions, or set file-only wildcards in Filters.")
                }
                try exclusion(value, into: &s)
                if !value.contains("/") { s.traversal.excludedFolders.append(value) }
            case "-S", "--size": try size(args.value(flag, inline), find: false, into: &s)
            case "--changed-within": try s.filters.setRelativeDays(SearchFilters.parseDayInterval(args.value(flag, inline)))
            case "-d", "--max-depth": s.traversal.maximumDepth = try integer(args.value(flag, inline), flag)
            case "--min-depth": s.traversal.minimumDepth = try integer(args.value(flag, inline), flag)
            case "-0", "--print0": null = true
            case "--absolute-path", "--no-ignore-vcs":
                if flag == "--no-ignore-vcs" { throw invalid("--no-ignore-vcs differs from --no-ignore and has no matching control.") }
            case "--color": guard try args.value(flag, inline) == "never" else { throw invalid("Use --color never.") }
            default: throw invalid("The fd option \(flag) cannot be represented by editable controls. Use command mode to pass it to fd.")
            }
            if inline != nil && !["--type", "--extension", "--exclude", "--size", "--changed-within", "--max-depth", "--min-depth", "--color", "--and", "--threads"].contains(flag) {
                throw invalid("\(flag) does not take a value.")
            }
        }
        if excludesHidden { s.includeHidden = false }
        guard types.isSubset(of: ["f", "file", "d", "directory"]) else { throw invalid("Only regular files and directories can be selected.") }
        let file = !types.isDisjoint(with: ["f", "file"]), directory = !types.isDisjoint(with: ["d", "directory"])
        s.mode = file && !directory ? .files : directory && !file ? .folders : .everything
        var pattern = positional.first ?? ""
        if matching == .regex, requiredPatterns.isEmpty, let literal = filenameLiteralFromRegex(pattern) {
            pattern = literal; matching = .contains
        }
        if matching == .glob { try validateGlob(pattern) }
        s.caseSensitive = sensitive ?? pattern.contains(where: \.isUppercase)
        s.refinements.fileCaseSensitive = s.caseSensitive
        if matching == .glob && (!s.caseSensitive || !pattern.unicodeScalars.allSatisfy(\.isASCII)) {
            // fd's glob engine folds ASCII only. Preserve its exact meaning;
            // the ordinary controls intentionally use Unicode filename folds.
            func nativeGlob(_ value: String) -> String {
                var body = String(SearchCore.globRegex(value).dropFirst(2).dropLast(2))
                if !fullPath { body = body.replacingOccurrences(of: "[^/]", with: ".") }
                return "(?s-i:\\A" + body.map { character -> String in
                    if !s.caseSensitive, character.isASCII, character.isLetter {
                        return "[" + character.lowercased() + character.uppercased() + "]"
                    }
                    return String(character)
                }.joined() + "\\z)"
            }
            pattern = nativeGlob(pattern)
            requiredPatterns = requiredPatterns.map(nativeGlob)
            matching = .regex
        }
        if fullPath {
            s.refinements.path = pattern; s.refinements.pathMatching = matching
            s.refinements.absolutePathMatching = true
        }
        else { s.refinements.name = pattern; s.refinements.nameMatching = matching }
        guard extensions.allSatisfy({ !$0.isEmpty && !$0.contains(where: { ",;/*?[]{}\\".contains($0) || $0.isWhitespace }) }) else {
            throw invalid("Use literal extensions such as swift or tar.gz.")
        }
        s.refinements.extensions = extensions.joined(separator: ",")
        try roots(Array(positional.dropFirst()), into: &s, base: base)
        if !requiredPatterns.isEmpty {
            try s.promoteToRules()
            var rules = s.ruleSet!
            for pattern in requiredPatterns {
                rules.addFileCondition(fullPath ? .path(pattern, matching, absolute: true) : .name(pattern, matching))
            }
            s.replaceRules(rules)
        }
        return null
    }

    private static func parseRG(_ words: [String], into s: inout SearchSnapshot, base: URL, piped: Bool) throws -> Bool {
        let words = try SearchCommandArguments.expand(words, tool: .rg)
        var args = Arguments(words: words); var positional: [String] = []; var explicitPatterns: [String] = []
        var sensitive = true; var smart = false; var fixed = false; var files = false; var null = false
        var inverted = false, unrestricted = 0
        var globs: [String] = [], typePatterns: [String] = []
        var usesType = false
        while let (flag, inline) = args.next() {
            if args.ended || !flag.hasPrefix("-") || flag == "-" { positional.append(flag); continue }
            switch flag {
            case "-e", "--regexp":
                explicitPatterns.append(try args.value(flag, inline))
            case "-F", "--fixed-strings": fixed = true
            case "-i", "--ignore-case": sensitive = false; smart = false
            case "-s", "--case-sensitive": sensitive = true; smart = false
            case "-S", "--smart-case": smart = true
            case "-v", "--invert-match": inverted = true
            case "--no-invert-match": inverted = false
            case "--threads", "-j": s.refinements.workers = try integer(args.value(flag, inline), flag)
            case "--encoding": s.refinements.textEncoding = try args.value(flag, inline)
            case "--stats": break
            case "--type-add":
                let value = try args.value(flag, inline)
                guard value.hasPrefix("findui:") else { throw invalid("Use the findui type name for custom filename filters.") }
                let pattern = String(value.dropFirst(7))
                _ = try typeGlobRegex(pattern)
                typePatterns.append(pattern)
            case "--type", "-t":
                guard try args.value(flag, inline) == "findui" else { throw invalid("Define a findui extension type with --type-add.") }
                usesType = true
            case "-U", "--multiline": s.refinements.multiline = true
            case "-w", "--word-regexp": s.refinements.wholeWords = true
            case "-l", "--files-with-matches": s.refinements.matchingFilesOnly = true
            case "--files": files = true
            case "--hidden": if !piped { s.includeHidden = true }
            case "--no-hidden": if !piped { s.includeHidden = false }
            case "-u", "--unrestricted":
                unrestricted += 1
                guard unrestricted <= 2 else { throw invalid("rg -uuu also searches binary files. Use command mode to preserve that choice.") }
                if !piped {
                    s.traversal.includeIgnored = true
                    if unrestricted >= 2 { s.includeHidden = true }
                }
            case "--no-ignore": if !piped { s.traversal.includeIgnored = true }
            case "-L", "--follow": if !piped { s.traversal.followSymlinks = true }
            case "-g", "--glob": globs.append(try args.value(flag, inline))
            case "--max-depth":
                guard !piped else { throw invalid("Set depth on fd/find before the content stage.") }
                s.traversal.maximumDepth = try integer(args.value(flag, inline), flag)
            case "-C", "--context": s.refinements.contextLines = try integer(args.value(flag, inline), flag, allowZero: true)
            case "-0", "--null": null = true
            case "-n", "--line-number", "--no-heading", "--with-filename", "-H", "--json", "--no-config": break
            case "--color": guard try args.value(flag, inline) == "never" else { throw invalid("Use --color never.") }
            default: throw invalid("The rg option \(flag) cannot be represented by editable controls. Use command mode to pass it to rg.")
            }
            if inline != nil && !["--regexp", "--glob", "--max-depth", "--context", "--color", "--threads", "--encoding", "--type-add", "--type"].contains(flag) { throw invalid("\(flag) does not take a value.") }
        }
        let pattern: String
        if files { guard !piped, explicitPatterns.isEmpty, !inverted else { throw invalid("rg --files must start a pipeline and has no pattern.") }; pattern = "" }
        else if !explicitPatterns.isEmpty { pattern = explicitPatterns[0] }
        else { guard !positional.isEmpty else { throw invalid("rg needs a content pattern.") }; pattern = positional.removeFirst() }
        if piped { guard positional.isEmpty else { throw invalid("An xargs rg stage must take its files from the preceding stage, without extra paths.") } }
        else { try roots(positional, into: &s, base: base) }
        let precedingFiles = piped ? s.ruleSet?.files : nil
        if precedingFiles != nil { s.clearCriteriaKeepingOptions() }
        s.mode = files ? .files : .contents
        s.caseSensitive = smart ? (explicitPatterns.isEmpty ? [pattern] : explicitPatterns).contains(where: { $0.contains(where: \.isUppercase) }) : sensitive
        s.syntax = fixed ? .literal : .regex
        s.query = files ? "" : fixed ? quoteQuery(pattern) : pattern
        if let precedingFiles, precedingFiles != .all([]) {
            try s.promoteToRules()
            var rules = s.ruleSet!
            rules.addFileConditions(precedingFiles)
            s.replaceRules(rules)
        }
        if !files && (explicitPatterns.count > 1 || inverted) {
            try s.promoteToRules()
            var rules = s.ruleSet!
            let conditions: [SearchRuleTree<SearchContentRule>] = (explicitPatterns.isEmpty ? [pattern] : explicitPatterns).map {
                .rule($0.isEmpty ? .allLines : fixed ? .literal($0) : .regex($0))
            }
            rules.contents = inverted ? .none(conditions) : .any(conditions)
            s.replaceRules(rules)
        }
        guard usesType == !typePatterns.isEmpty else { throw invalid("A filename type needs both --type-add and --type findui.") }
        if usesType && !piped {
            s.refinements.fileCaseSensitive = true
            let controls = typePatterns.compactMap(typeGlobControl)
            let representable = controls.count == typePatterns.count && Set(controls.map(\.sensitive)).count == 1
            let patterns = representable ? controls.map(\.pattern) : typePatterns
            if representable { s.refinements.fileCaseSensitive = controls[0].sensitive }
            let extensions = patterns.compactMap { $0.hasPrefix("*.") ? literalGlob(String($0.dropFirst(2))) : nil }
            let literalExtensions = representable && extensions.count == typePatterns.count && extensions.allSatisfy({ !$0.isEmpty && !$0.contains(where: { "/,;".contains($0) || $0.isWhitespace }) })
            if literalExtensions && s.ruleSet == nil {
                s.refinements.extensions = extensions.joined(separator: ",")
            } else if representable && patterns.count == 1 && s.ruleSet == nil {
                s.refinements.name = patterns[0]; s.refinements.nameMatching = .glob
            } else {
                try s.promoteToRules()
                var rules = s.ruleSet!
                if literalExtensions { rules.addFileCondition(.extensions(extensions)) }
                else if representable { rules.addFileConditions(.any(patterns.map { .rule(.name($0, .glob)) })) }
                else { rules.addFileConditions(.any(try typePatterns.map { .rule(.name(try typeGlobRegex($0), .regex)) })) }
                s.replaceRules(rules)
            }
        }
        if piped {
            // rg checks glob syntax but explicit file arguments bypass its
            // traversal globs, hidden-file rules and ignore files.
            for glob in globs { try validateGlob(glob) }
            return null
        }
        let hasInclusionGlob = globs.contains { !$0.hasPrefix("!") }
        let lastHiddenExclusion = globs.lastIndex(of: "!.*")
        let hiddenExclusionWins = lastHiddenExclusion.map { index in
            !globs.suffix(from: index + 1).contains { !$0.hasPrefix("!") }
        } ?? false
        if !s.includeHidden, (hasInclusionGlob || usesType), !hiddenExclusionWins {
            throw invalid("This rg filter admits hidden files but can still skip hidden folders. Run it as a command to preserve that behavior, or add --hidden or a final --glob '!.*' to make the hidden-file setting explicit.")
        }
        globs = globs.filter { glob in
            if glob == "!.*", hiddenExclusionWins { s.includeHidden = false; return false }
            if glob.hasPrefix("!**/"), glob.hasSuffix("/**"),
               let folder = literalGlob(String(glob.dropFirst(4).dropLast(3))), !folder.contains("/") {
                s.traversal.excludedFolders.append(folder); return false
            }
            return true
        }
        if !piped, !globs.isEmpty {
            // rg's overrides operate during traversal, are always case-sensitive,
            // and can admit hidden/ignored files. A later filename predicate
            // cannot reproduce those semantics.
            let relativeGlobs = globs.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).contains("/") }
            guard !relativeGlobs || positional.isEmpty || positional == ["."] || positional == ["./"] else {
                throw invalid("rg path globs depend on how its roots are spelled. Import them with the current folder (.), or use Path patterns in Scope & Options for patterns relative to the search folder.")
            }
            s.traversal.pathRules = globs
            return null
        }
        return null
    }

    /// The emitted rg types use basename wildcards and explicit Unicode case
    /// classes. Import their exact meaning as a regex without shell evaluation.
    /// Recognize the compiler's complete case-fold sets first, preserving both
    /// compact controls and the native rg fast path across repeated exports.
    private static func typeGlobControl(_ pattern: String) -> (pattern: String, sensitive: Bool)? {
        let chars = Array(pattern)
        var output = "", i = 0, folded = false, literalLetter = false
        while i < chars.count {
            let c = chars[i]
            if c == "[" {
                guard i + 3 < chars.count, chars[i + 3] == "]" else { return nil }
                let lower = String(chars[i + 1]), upper = String(chars[i + 2])
                guard lower != upper, lower == lower.lowercased(), upper == lower.uppercased(),
                    lower.unicodeScalars.allSatisfy(\.isASCII), chars[i + 1].isLetter,
                    lower != "s", lower != "k" else { return nil }
                output += lower; folded = true; i += 4; continue
            }
            if c == "{" {
                guard let end = chars[i...].firstIndex(of: "}") else { return nil }
                switch String(chars[i...end]) {
                case "{s,S,ſ}": output += "s"
                case "{k,K,K}": output += "k"
                default: return nil
                }
                folded = true; i = end + 1; continue
            }
            // Escaped glob metacharacters cannot be represented in the simple
            // wildcard control. Keep their exact regex representation instead.
            if "\\]}".contains(c) { return nil }
            // Controls normalize literal filename text; a raw native type glob
            // matches its byte spelling. Keep Unicode literals as exact regexes.
            guard c.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
            if c.isLetter { literalLetter = true }
            output.append(c); i += 1
        }
        guard !(folded && literalLetter) else { return nil }
        return (output, !folded)
    }

    private static func typeGlobRegex(_ pattern: String) throws -> String {
        let chars = Array(pattern)
        var regex = "\\A", i = 0
        guard !pattern.isEmpty, !pattern.contains("/") else { throw invalid("Use a basename pattern for the findui type.") }
        while i < chars.count {
            let char = chars[i]
            if char == "\\" {
                i += 1; guard i < chars.count else { throw invalid("Incomplete filename type escape.") }
                regex += SearchCore.escapeRegex(String(chars[i]))
            } else if char == "*" { regex += ".*" }
            else if char == "?" { regex += "." }
            else if char == "[" {
                guard let end = chars[(i + 1)...].firstIndex(of: "]") else { throw invalid("Incomplete filename type class.") }
                let members = String(chars[(i + 1)..<end])
                guard !members.isEmpty, members.allSatisfy(\.isLetter) else { throw invalid("Only letter classes are supported in imported filename types.") }
                regex += "[" + members + "]"; i = end
            } else if char == "{" {
                guard let end = chars[(i + 1)...].firstIndex(of: "}") else { throw invalid("Incomplete filename type alternatives.") }
                let members = String(chars[(i + 1)..<end]).split(separator: ",", omittingEmptySubsequences: false)
                guard members.count > 1, members.allSatisfy({ $0.count == 1 && $0.allSatisfy(\.isLetter) }) else {
                    throw invalid("Only single letter alternatives are supported in imported filename types.")
                }
                regex += "(?:" + members.map { SearchCore.escapeRegex(String($0)) }.joined(separator: "|") + ")"; i = end
            } else if "}]".contains(char) { throw invalid("Unsupported filename type glob.") }
            else { regex += SearchCore.escapeRegex(String(char)) }
            i += 1
        }
        return regex + "\\z"
    }

    private static func parseFind(_ words: [String], into s: inout SearchSnapshot, base: URL) throws -> Bool {
        let operators: Set<String> = ["(", ")", "!", "-not", "-a", "-and", "-o", "-or"]
        let patterns = words.filter { ["-name", "-iname", "-path", "-ipath"].contains($0) }.count
        if words.contains(where: operators.contains) || patterns > 1 {
            return try parseGroupedFind(words, into: &s, base: base)
        }
        return try parseSimpleFind(words, into: &s, base: base)
    }

    private static func parseSimpleFind(_ words: [String], into s: inout SearchSnapshot, base: URL) throws -> Bool {
        var args = Arguments(words: words); var paths: [String] = []; var null = false
        var predicatesStarted = false; var sawType = false; var sawPattern = false
        var pathPattern: String?
        s.includeHidden = true; s.traversal.includeIgnored = true; s.caseSensitive = true
        while let (flag, inline) = args.next() {
            if !flag.hasPrefix("-") {
                guard !predicatesStarted, flag != "!" else { throw invalid("Place find roots before predicates; boolean expressions are not supported.") }
                paths.append(flag); continue
            }
            if flag != "-L" && flag != "-P" { predicatesStarted = true }
            switch flag {
            case "-L": s.traversal.followSymlinks = true
            case "-P": s.traversal.followSymlinks = false
            case "-type":
                guard !sawType else { throw invalid("Use a single find -type predicate.") }; sawType = true
                switch try args.value(flag, inline) {
                case "f": s.mode = .files
                case "d": s.mode = .folders
                default: throw invalid("Only find -type f or -type d is supported.")
                }
            case "-name", "-iname", "-path", "-ipath":
                let value = try args.value(flag, inline); try validateGlob(value)
                guard !sawPattern else { throw invalid("Use one find name/path predicate.") }
                sawPattern = true
                s.caseSensitive = flag == "-name" || flag == "-path"
                if flag.contains("path") { pathPattern = value }
                else {
                    s.refinements.name = value.isEmpty ? "\\A\\z" : value
                    s.refinements.nameMatching = value.isEmpty ? .regex : .glob
                }
            case "-size": try size(args.value(flag, inline), find: true, into: &s)
            case "-mtime":
                let value = try args.value(flag, inline)
                guard value.hasPrefix("-") else { throw invalid("Use find -mtime with a negative number of days, such as -20.") }
                try s.filters.setRelativeDays(SearchFilters.parseDayInterval(String(value.dropFirst()) + "d"))
            case "-mindepth": s.traversal.minimumDepth = try integer(args.value(flag, inline), flag)
            case "-maxdepth": s.traversal.maximumDepth = try integer(args.value(flag, inline), flag)
            case "-print": break
            case "-print0": null = true
            default: throw invalid("Unsupported find predicate: \(flag). Actions and boolean expressions cannot be imported.")
            }
        }
        if s.mode != .files && !words.contains("-mindepth") { throw invalid("Use -mindepth 1 for a directory search; FindUI searches inside the selected root.") }
        s.refinements.fileCaseSensitive = s.caseSensitive
        try roots(paths, into: &s, base: base)
        if let pattern = pathPattern {
            func regex(_ value: String) -> String {
                value.map { $0 == "*" ? ".*" : $0 == "?" ? "." : SearchPipelineCompiler.escapeRegex(String($0)) }.joined()
            }
            let body: String
            if pattern.isEmpty || (!paths.isEmpty && paths.allSatisfy { $0.hasPrefix("/") }) {
                body = regex(pattern)
            } else {
                let rawRoot = paths.first ?? "."
                let prefix = rawRoot.hasSuffix("/") ? rawRoot : rawRoot + "/"
                let startsWithRoot = s.caseSensitive ? pattern.hasPrefix(prefix) : pattern.lowercased().hasPrefix(prefix.lowercased())
                guard paths.count <= 1, startsWithRoot else {
                    throw invalid("Use an absolute find root for -path patterns, or start the pattern with the literal relative root (for example ./src/*). Otherwise the original path spelling cannot be preserved in the controls.")
                }
                let absolute = s.scopePath == "/" ? "/" : s.scopePath + "/"
                body = SearchPipelineCompiler.escapeRegex(absolute) + regex(String(pattern.dropFirst(prefix.count)))
            }
            // Unlike the UI's segment glob, find's * and ? also match /.
            s.refinements.path = "\\A" + body + "\\z"
            s.refinements.pathMatching = .regex; s.refinements.absolutePathMatching = true
        }
        return null
    }

    private indirect enum FindExpression {
        case rule(SearchFileRule)
        case kind(SearchMode)
        case all([Self])
        case any([Self])
        case not(Self)
    }

    /// find's precedence is NOT, implicit/explicit AND, OR. Parentheses arrive
    /// as quoted/escaped argv tokens; they are never evaluated by a shell.
    private static func parseGroupedFind(_ words: [String], into s: inout SearchSnapshot, base: URL) throws -> Bool {
        var index = 0, rawRoots: [String] = [], null = false, steps = 0
        s.includeHidden = true; s.traversal.includeIgnored = true; s.caseSensitive = true
        s.refinements.fileCaseSensitive = true
        while index < words.count {
            let value = words[index]
            if value == "-L" || value == "-P" {
                s.traversal.followSymlinks = value == "-L"; index += 1; continue
            }
            if value.hasPrefix("-") || ["(", ")", "!"].contains(value) { break }
            rawRoots.append(value); index += 1
        }
        try roots(rawRoots, into: &s, base: base)
        var expressionWords = Array(words.dropFirst(index))
        if ["-print", "-print0"].contains(expressionWords.last ?? "") {
            null = expressionWords.removeLast() == "-print0"
        }
        index = 0
        func takeValue(_ flag: String) throws -> String {
            guard index < expressionWords.count else { throw invalid("\(flag) needs a value.") }
            defer { index += 1 }; return expressionWords[index]
        }
        func pathRegex(_ pattern: String, insensitive: Bool) throws -> String {
            try validateGlob(pattern)
            func glob(_ text: String) -> String {
                text.map { $0 == "*" ? ".*" : $0 == "?" ? "." : SearchCore.escapeRegex(String($0)) }.joined()
            }
            var body: String
            if !rawRoots.isEmpty && rawRoots.allSatisfy({ $0.hasPrefix("/") }) { body = glob(pattern) }
            else {
                let raw = rawRoots.first ?? "."
                let prefix = raw.hasSuffix("/") ? raw : raw + "/"
                let matches = insensitive ? pattern.lowercased().hasPrefix(prefix.lowercased()) : pattern.hasPrefix(prefix)
                guard rawRoots.count <= 1, matches else {
                    throw invalid("For grouped find -path rules, use absolute roots or start each pattern with the literal relative root, such as ./src/*. Otherwise run the original command in command mode.")
                }
                body = SearchCore.escapeRegex(s.scopePath == "/" ? "/" : s.scopePath + "/") + glob(String(pattern.dropFirst(prefix.count)))
            }
            if insensitive { body = "(?i:" + body + ")" }
            return "\\A" + body + "\\z"
        }
        func atom(_ depth: Int) throws -> FindExpression {
            steps += 1
            guard steps <= 256, depth <= 12, index < expressionWords.count else {
                throw invalid("The find expression is incomplete or too deeply nested.")
            }
            let flag = expressionWords[index]; index += 1
            switch flag {
            case "!", "-not": return .not(try atom(depth + 1))
            case "(":
                let result = try disjunction(depth + 1)
                guard index < expressionWords.count, expressionWords[index] == ")" else { throw invalid("Close every find expression group.") }
                index += 1; return result
            case "-type":
                switch try takeValue(flag) {
                case "f": return .kind(.files)
                case "d": return .kind(.folders)
                default: throw invalid("Import regular-file or directory conditions; other find types can run in command mode.")
                }
            case "-name", "-iname":
                let value = try takeValue(flag); try validateGlob(value)
                if flag == "-iname" {
                    let body = value.map { $0 == "*" ? ".*" : $0 == "?" ? "." : SearchCore.escapeRegex(String($0)) }.joined()
                    return .rule(.name("\\A(?i:" + body + ")\\z", .regex))
                }
                return .rule(.name(value.isEmpty ? "\\A\\z" : value, value.isEmpty ? .regex : .glob))
            case "-path", "-ipath": return .rule(.path(try pathRegex(takeValue(flag), insensitive: flag == "-ipath"), .regex, absolute: true))
            case "-size":
                var scratch = s; scratch.filters = .init()
                try size(takeValue(flag), find: true, into: &scratch)
                return .rule(.size(minimum: scratch.filters.minimumSize, maximum: scratch.filters.maximumSize))
            case "-mtime":
                let value = try takeValue(flag)
                guard value.hasPrefix("-") else { throw invalid("Use find -mtime -N in editable rules; other date comparisons can run in command mode.") }
                var filters = SearchFilters()
                try filters.setRelativeDays(SearchFilters.parseDayInterval(String(value.dropFirst()) + "d"))
                return .rule(.date(.init(filters)))
            case "-mindepth", "-maxdepth":
                let value = try integer(takeValue(flag), flag, allowZero: true)
                if flag == "-mindepth" { s.traversal.minimumDepth = value }
                else { s.traversal.maximumDepth = value }
                return .all([])
            default: throw invalid("Unsupported find predicate: \(flag). Only a final -print or -print0 action can become editable rules. Use command mode to pass other options to find.")
            }
        }
        func conjunction(_ depth: Int) throws -> FindExpression {
            var nodes = [try atom(depth)]
            while index < expressionWords.count, !["-o", "-or", ")"].contains(expressionWords[index]) {
                if ["-a", "-and"].contains(expressionWords[index]) { index += 1 }
                nodes.append(try atom(depth))
            }
            return nodes.count == 1 ? nodes[0] : .all(nodes)
        }
        func disjunction(_ depth: Int) throws -> FindExpression {
            var nodes = [try conjunction(depth)]
            while index < expressionWords.count, ["-o", "-or"].contains(expressionWords[index]) {
                index += 1; nodes.append(try conjunction(depth))
            }
            return nodes.count == 1 ? nodes[0] : .any(nodes)
        }
        let parsed = try disjunction(0)
        guard index == expressionWords.count else { throw invalid("Unexpected closing find group.") }
        var kinds = Set<SearchMode>()
        func translate(_ node: FindExpression, conjunctive: Bool) throws -> SearchRuleTree<SearchFileRule> {
            switch node {
            case .rule(let rule): return .rule(rule)
            case .kind(let kind):
                guard conjunctive else { throw invalid("A find type condition inside OR/NOT cannot be represented by one file/directory mode. Run this read-only command in command mode.") }
                kinds.insert(kind); return .all([])
            case .all(let nodes): return .all(try nodes.map { try translate($0, conjunctive: conjunctive) })
            case .any(let nodes): return .any(try nodes.map { try translate($0, conjunctive: false) })
            case .not(let node): return .none([try translate(node, conjunctive: false)])
            }
        }
        var tree = try translate(parsed, conjunctive: true).queryTree.simplified
        if kinds.count > 1 { tree = .leaf(.name("\\A\\z", .regex)) }
        s.mode = kinds.count == 1 ? kinds.first! : .everything
        guard s.mode == .files || words.contains("-mindepth") else {
            throw invalid("Use -mindepth 1 for editable directory searches, or command mode to include the root itself.")
        }
        if tree == .any([]) { tree = .leaf(.name("\\A\\z", .regex)) }
        let rules = SearchRuleSet(files: SearchRuleTree(tree))
        try rules.validate(now: .now)
        s.replaceRules(rules)
        return null
    }

    private static func parseFZF(_ words: [String], into s: inout SearchSnapshot) throws {
        let words = try SearchCommandArguments.expand(words, tool: .fzf)
        var args = Arguments(words: words); var pattern: String?; var read0 = false; var print0 = false
        var extended = true; var sensitive: Bool?; var basename = false; var delimiter = false; var normalize = true
        while let (flag, inline) = args.next() {
            switch flag {
            case "-f", "--filter": pattern = try args.value(flag, inline)
            case "--read0": read0 = true
            case "--print0": print0 = true
            case "--no-extended": extended = false
            case "-i", "--ignore-case": sensitive = false
            case "+i", "--no-ignore-case": sensitive = true
            case "--literal": normalize = false
            case "--scheme": guard try args.value(flag, inline) == "path" else { throw invalid("FindUI uses fzf --scheme path.") }
            case "--algo": guard try args.value(flag, inline) == "v2" else { throw invalid("FindUI uses fzf --algo v2.") }
            case "--delimiter": guard try args.value(flag, inline) == "/" else { throw invalid("Only the / path delimiter is supported.") }; delimiter = true
            case "--nth": guard try args.value(flag, inline) == "-1" else { throw invalid("Only --nth -1 (basename) is supported.") }; basename = true
            default: throw invalid("Unsupported fzf option: \(flag). Use noninteractive --filter.")
            }
        }
        guard let pattern, !pattern.isEmpty, read0, print0, basename == delimiter else {
            throw invalid("Use fzf --read0 --print0 --filter 'text', optionally --delimiter / --nth -1 for basenames.")
        }
        guard !extended || pattern.allSatisfy({ $0.isLetter || $0.isNumber || "._-/".contains($0) }) else {
            throw invalid("Use fzf --no-extended for literal fuzzy matching.")
        }
        let caseFlag = sensitive ?? pattern.contains(where: \.isUppercase)
        guard s.refinements.fileCaseSensitive == caseFlag || (!s.refinements.hasFileConditions) else {
            throw invalid("Use the same case setting for fd/find and fzf.")
        }
        s.refinements.fileCaseSensitive = caseFlag
        s.refinements.fuzzyNormalize = normalize ? true : nil
        if basename {
            guard s.refinements.name.isEmpty else { throw invalid("A filename filter is already set; use full-path fuzzy ranking.") }
            s.refinements.name = pattern; s.refinements.nameMatching = .fuzzy
        } else {
            guard s.refinements.path.isEmpty else { throw invalid("A path filter is already set; use basename fuzzy ranking.") }
            s.refinements.path = pattern; s.refinements.pathMatching = .fuzzy
        }
    }

    private static func literalGlob(_ value: String) -> String? {
        var output = "", escaped = false
        for character in value {
            if escaped { output.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if "*?[]{}".contains(character) { return nil }
            else { output.append(character) }
        }
        return escaped ? nil : output
    }
    private static func validateGlob(_ value: String) throws {

        guard !value.contains(where: { "[]{}\\".contains($0) }) else { throw invalid("Wildcard controls support * and ?; use Regex for character classes or alternatives.") }
    }
    private static func exclusion(_ value: String, into s: inout SearchSnapshot) throws {
        try validateGlob(value)
        let folder: String?
        if value.hasPrefix("**/"), value.hasSuffix("/**") { folder = String(value.dropFirst(3).dropLast(3)) }
        else if value.hasSuffix("/") { folder = String(value.dropLast()) }
        else { folder = nil }
        if let folder, !folder.contains(where: { "/*?".contains($0) }) { s.traversal.excludedFolders.append(folder) }
        else {
            guard !value.contains("/") else { throw invalid("Exclude folders by name with a trailing /, or files by a basename wildcard.") }
            s.refinements.excludedFiles += (s.refinements.excludedFiles.isEmpty ? "" : "\n") + value
        }
    }
    private static func integer(_ value: String, _ flag: String, allowZero: Bool = false) throws -> Int {
        guard let number = Int(value), number >= (allowZero ? 0 : 1), number <= 10_000 else { throw invalid("\(flag) needs a positive whole number.") }
        return number
    }
    private static func size(_ value: String, find: Bool, into s: inout SearchSnapshot) throws {
        let regex = try NSRegularExpression(pattern: find ? #"^([+-]?)([0-9]+)c$"# : #"^([+-]?)([0-9]+)(b|k|m|g|t|ki|mi|gi|ti)$"#, options: .caseInsensitive)
        let ns = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { throw invalid("Use byte sizes for find (e.g. +100c), or fd units such as +10m or -1gi.") }
        let sign = ns.substring(with: match.range(at: 1)), number = ns.substring(with: match.range(at: 2))
        let units = ["b": "B", "k": "KB", "m": "MB", "g": "GB", "t": "TB", "ki": "KiB", "mi": "MiB", "gi": "GiB", "ti": "TiB"]
        let unit = find ? "B" : units[ns.substring(with: match.range(at: 3)).lowercased()]!
        guard let bytes = try SearchFilters.bytes(number + unit) else { return }
        if sign != "-" {
            if find && sign == "+" && bytes == Int64.max {
                throw invalid("That strict minimum is larger than the supported file size.")
            }
            let previous = try SearchFilters.bytes(s.filters.minimumSize) ?? 0
            s.filters.minimumSize = "\(max(previous, bytes + (find && sign == "+" ? 1 : 0))) B"
        }
        if sign != "+" {
            let maximum = bytes - (find && sign == "-" ? 1 : 0)
            guard maximum >= 0 else { throw invalid("A file cannot have a negative size.") }
            s.filters.maximumSize = "\(min(try SearchFilters.bytes(s.filters.maximumSize) ?? Int64.max, maximum)) B"
        }
    }
    private static func quoteQuery(_ value: String) -> String {
        let parsed = ParsedSearchQuery.parseLiteral(value)
        if parsed.tokens.count == 1, let token = parsed.tokens.first,
           token.field == .any, !token.isExcluded, token.globPattern == nil, token.value == value {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
