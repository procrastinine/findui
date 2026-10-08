import SearchBackend
#if canImport(FindUI)
@testable import FindUI
#endif
import Foundation

/// A small, allowlisted CLI grammar. Neither this draft nor model text is executed.
struct CLISearchDraft: Sendable {
    enum Tool: String, Sendable { case fd, rg, find }
    struct Option: Sendable {
        let flag: String
        var value: String? = nil
    }
    let tool: Tool
    let pattern: String
    let scopePath: String
    let options: [Option]
    var unsupportedReason: String?

    static let flags = ["--type", "--glob", "--fixed-strings", "--exact", "--full-path", "--ignore-case", "--case-sensitive",
                        "--hidden", "--no-ignore", "--extension", "--exclude", "--size", "--changed-within",
                        "--min-depth", "--max-depth", "-type", "-name", "-iname", "-size", "-mtime", "-mindepth", "-maxdepth"]

    func plan() throws -> NaturalSearchPlan {
        func invalid(_ message: String) -> SearchServiceError { .commandFailed(message) }
        if let reason = unsupportedReason, !reason.isEmpty { throw invalid(reason) }
        guard options.count <= 32, !pattern.contains("\0"), !scopePath.contains("\0") else {
            throw invalid("The command contains invalid arguments or too many options.")
        }
        let allowed: Set<String>
        switch tool {
        case .fd: allowed = ["--type", "--glob", "--fixed-strings", "--exact", "--full-path", "--ignore-case", "--case-sensitive",
                             "--hidden", "--no-ignore", "--extension", "--exclude", "--size", "--changed-within", "--min-depth", "--max-depth"]
        case .rg: allowed = ["--glob", "--fixed-strings", "--ignore-case", "--case-sensitive", "--hidden", "--no-ignore", "--max-depth"]
        case .find: allowed = ["-type", "-name", "-iname", "-size", "-mtime", "-mindepth", "-maxdepth"]
        }
        let switches: Set<String> = ["--fixed-strings", "--exact", "--full-path", "--ignore-case", "--case-sensitive", "--hidden", "--no-ignore"]
        let repeatable: Set<String> = ["--extension", "--exclude", "--size", "--glob", "-name", "-iname", "-size"]
        var seen = Set<String>()
        for option in options {
            guard allowed.contains(option.flag) else { throw invalid("\(option.flag) is not supported for \(tool.rawValue) in FindUI.") }
            guard repeatable.contains(option.flag) || seen.insert(option.flag).inserted else {
                throw invalid("Repeated option: \(option.flag)")
            }
            let isSwitch = switches.contains(option.flag) || (tool == .fd && option.flag == "--glob")
            guard isSwitch ? option.value == nil : (option.value?.isEmpty == false && option.value?.contains("\0") == false) else {
                throw invalid("\(option.flag) has a missing or unexpected argument.")
            }
        }
        func has(_ flag: String) -> Bool { options.contains { $0.flag == flag } }
        func values(_ flag: String) -> [String] { options.filter { $0.flag == flag }.compactMap(\.value) }
        guard !(has("--ignore-case") && has("--case-sensitive")) else { throw invalid("Conflicting case options.") }

        var plan = NaturalSearchPlan(scopePath: scopePath)
        func depth(_ flag: String) throws -> Int? {
            guard let raw = values(flag).first else { return nil }
            guard let value = Int(raw), (1...10_000).contains(value) else {
                throw invalid("\(flag) needs a whole number between 1 and 10000.")
            }
            return value
        }
        plan.minimumDepth = try depth(tool == .find ? "-mindepth" : "--min-depth") ?? 1
        plan.maximumDepth = try depth(tool == .find ? "-maxdepth" : "--max-depth")
        if let maximum = plan.maximumDepth, maximum < plan.minimumDepth { throw invalid("Depth bounds are reversed.") }
        plan.includeHidden = tool == .find || has("--hidden")
        plan.includeIgnored = tool == .find || has("--no-ignore")
        var terms: [String] = []
        switch tool {
        case .fd:
            plan.mode = try Self.mode(values("--type").first)
            plan.caseSensitive = has("--case-sensitive") || (!has("--ignore-case") && pattern.contains(where: \.isUppercase))
            guard ["--fixed-strings", "--glob", "--exact"].filter(has).count == 1 else {
                throw invalid("Use one of fd --fixed-strings, --glob, or --exact. Filename regex is not supported by this translator.")
            }
            if has("--full-path") && (!has("--fixed-strings") || pattern.isEmpty) {
                throw invalid("Full-path translation requires a nonempty literal pattern with --fixed-strings.")
            }
            if !pattern.isEmpty {
                terms.append((has("--full-path") ? "path:" : "name:") + (has("--glob") ? try Self.glob(pattern) : Self.quote(pattern)))
            } else if has("--exact") { throw invalid("An exact filename cannot be empty.") }
            plan.exactNameMatch = has("--exact")
            let extensions = values("--extension")
            if !extensions.isEmpty {
                guard extensions.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" } }) else {
                    throw invalid("Extensions must be single suffixes such as pdf or swift, without dots or wildcards.")
                }
                terms.append("ext:" + extensions.joined(separator: ";"))
            }
            plan.excludedFolders = try values("--exclude").map { value in
                guard value.hasSuffix("/") else { throw invalid("Use a trailing slash to exclude a directory, such as build/.") }
                let folder = String(value.dropLast())
                guard !folder.contains(where: { "*?[]{}\\".contains($0) }) else {
                    throw invalid("Exclude folders by literal name, without glob patterns.")
                }
                return folder
            }
            for size in values("--size") { try Self.applySize(size, find: false, to: &plan) }
            if let age = values("--changed-within").first { try Self.applyPeriod(age, to: &plan) }
        case .rg:
            guard !pattern.isEmpty else { throw invalid("A content search needs text or a regex pattern.") }
            plan.mode = .contents
            plan.caseSensitive = !has("--ignore-case")
            plan.syntax = has("--fixed-strings") ? .literal : .regex
            if plan.syntax == .literal { terms.append(Self.quote(pattern)) }
            else { plan.query = pattern }
            var extensions: [String] = []
            for glob in values("--glob") {
                if glob.hasPrefix("!**/"), glob.hasSuffix("/**") {
                    plan.excludedFolders.append(String(glob.dropFirst(4).dropLast(3)))
                } else if glob.hasPrefix("*."), glob.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), glob.count > 2 {
                    extensions.append(String(glob.dropFirst(2)))
                } else {
                    throw invalid("The CLI translator supports *.extension and !**/folder/** globs. Other filename patterns can be set in Filters.")
                }
            }
            if !extensions.isEmpty {
                if plan.syntax == .regex { plan.refinements.extensions = extensions.joined(separator: ",") }
                else { terms.append("ext:" + extensions.joined(separator: ";")) }
            }
        case .find:
            guard pattern.isEmpty else { throw invalid("find uses -name/-iname predicates, not a positional pattern.") }
            plan.mode = try Self.mode(values("-type").first)
            guard !(has("-name") && has("-iname")) else { throw invalid("The UI cannot mix case-sensitive and insensitive filename predicates.") }
            plan.caseSensitive = !has("-iname")
            for name in values("-name") + values("-iname") { terms.append("name:" + (try Self.glob(name))) }
            for size in values("-size") { try Self.applySize(size, find: true, to: &plan) }
            if let age = values("-mtime").first {
                guard age.hasPrefix("-") else { throw invalid("Use find -mtime with a negative number of days, such as -20.") }
                try Self.applyPeriod(String(age.dropFirst()) + "d", to: &plan)
            }
        }
        if plan.syntax != .regex { plan.query = terms.isEmpty ? "name:*" : terms.joined(separator: " ") }
        plan.sourceCommand = shellDescription
        return plan
    }

    var shellDescription: String {
        let flags = options.flatMap { [$0.flag] + ($0.value.map { [$0] } ?? []) }
        let path = (scopePath as NSString).expandingTildeInPath
        let arguments = tool == .find ? [path] + flags : flags + ["--", pattern, path]
        return ([tool.rawValue] + arguments).map(shellQuote).joined(separator: " ")
    }

    private static func mode(_ value: String?) throws -> SearchMode {
        switch value {
        case "f": return .files
        case "d": return .folders
        default: throw SearchServiceError.commandFailed("Choose exactly one file type: f (files) or d (directories).")
        }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func glob(_ pattern: String) throws -> String {
        guard !pattern.contains(where: { "[]{}\\/".contains($0) }) else {
            throw SearchServiceError.commandFailed("Filename globs support * and ? only, without paths or character classes.")
        }
        guard !pattern.isEmpty else { throw SearchServiceError.commandFailed("A filename glob cannot be empty.") }
        // Keep only wildcard characters active; quote every literal run.
        var result = ""
        var literal = ""
        for character in pattern {
            if character == "*" || character == "?" {
                if !literal.isEmpty { result += quote(literal); literal = "" }
                result.append(character)
            } else { literal.append(character) }
        }
        if !literal.isEmpty { result += quote(literal) }
        // Without wildcards, glob semantics are exact. Anchored ?/* machinery also
        // handles this through the plan's Exact Name setting below the translator.
        if !pattern.contains("*"), !pattern.contains("?") {
            throw SearchServiceError.commandFailed("For an exact filename use fd --exact; for a fragment use fd --fixed-strings.")
        }
        return result
    }

    private static func applyPeriod(_ text: String, to plan: inout NaturalSearchPlan) throws {
        var filters = SearchFilters()
        try filters.setRelativeDays(SearchFilters.parseDayInterval(text))
        plan.datePeriod = filters.datePeriod
        plan.relativeDays = filters.relativeDays
    }

    private static func applySize(_ text: String, find: Bool, to plan: inout NaturalSearchPlan) throws {
        let pattern = find ? #"^([+-]?)([0-9]+)c$"# : #"^([+-]?)([0-9]+)(b|k|m|g|t|ki|mi|gi|ti)$"#
        let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            throw SearchServiceError.commandFailed(find
                ? "Use find -size with bytes (c suffix); rounded block units cannot be represented exactly in the UI."
                : "Use fd --size with a whole number and b/k/m/g/t/ki/mi/gi/ti units, for example +500m.")
        }
        let sign = ns.substring(with: match.range(at: 1))
        let number = ns.substring(with: match.range(at: 2))
        let units = ["b": "B", "k": "KB", "m": "MB", "g": "GB", "t": "TB", "ki": "KiB", "mi": "MiB", "gi": "GiB", "ti": "TiB"]
        let size = find ? number + " B" : number + " " + units[ns.substring(with: match.range(at: 3)).lowercased()]!
        guard let bytes = try SearchFilters.bytes(size) else { return }
        // find +/- are strict comparisons; fd +/- are inclusive.
        let minimum = find && sign == "+" ? bytes + 1 : bytes
        let maximum = find && sign == "-" ? bytes - 1 : bytes
        if sign != "-" {
            let existing = try SearchFilters.bytes(plan.minimumSize) ?? 0
            plan.minimumSize = "\(max(existing, minimum)) B"
        }
        if sign != "+" {
            let existing = try SearchFilters.bytes(plan.maximumSize) ?? .max
            plan.maximumSize = "\(min(existing, maximum)) B"
        }
    }
}
