import Foundation

/// Expands tool options, never shell syntax. A value belongs to its preceding
/// flag even when it looks like another option, and -- ends expansion.
package enum SearchCommandArguments {
    package enum Tool: String { case fd, rg, fzf, xargs }

    private struct Schema {
        var flags: Set<Character>
        var values: Set<Character>
        var longValues: Set<String>
        var stopAtOperand = false
    }

    private static func schema(_ tool: Tool) -> Schema {
        switch tool {
        case .fd:
            return .init(flags: Set("HIusiFgpL0"), values: Set("teESdj"),
                longValues: ["--type", "--extension", "--exclude", "--ignore-file", "--max-depth", "--min-depth",
                    "--exact-depth", "--size", "--changed-within", "--changed-before", "--owner", "--and",
                    "--threads", "--max-results", "--color"])
        case .rg:
            return .init(flags: Set("FisSPUwxlLvaHINn0u"), values: Set("egtTjmC"),
                longValues: ["--regexp", "--glob", "--iglob", "--type", "--type-not", "--type-add", "--type-clear",
                    "--threads", "--encoding", "--max-depth", "--max-filesize", "--max-count", "--regex-size-limit",
                    "--dfa-size-limit", "--engine", "--sort", "--sortr", "--ignore-file", "--context", "--color"])
        case .fzf:
            return .init(flags: ["i"], values: ["f"],
                longValues: ["--filter", "--scheme", "--algo", "--delimiter", "--nth"])
        case .xargs:
            return .init(flags: ["0", "r"], values: [], longValues: [], stopAtOperand: true)
        }
    }

    package static func expand(_ words: [String], tool: Tool) throws -> [String] {
        let schema = schema(tool)
        var result: [String] = [], index = 0
        func checkLimit() throws {
            guard result.count <= 4096 else {
                throw SearchServiceError.commandFailed("The command has too many arguments.")
            }
        }
        while index < words.count {
            let word = words[index]; index += 1
            if word == "--" || (schema.stopAtOperand && (!word.hasPrefix("-") || word == "-")) {
                result.append(word); result += words.dropFirst(index); try checkLimit(); break
            }
            if word.hasPrefix("--") {
                result.append(word)
                let flag = String(word.prefix { $0 != "=" })
                if schema.longValues.contains(flag), !word.contains("=") {
                    guard index < words.count else { throw SearchServiceError.commandFailed("\(flag) needs a value.") }
                    result.append(words[index]); index += 1
                }
            } else if word.hasPrefix("-"), word.count > 1 {
                let letters = Array(word.dropFirst())
                var offset = 0
                while offset < letters.count {
                    let flag = letters[offset]; offset += 1
                    if schema.flags.contains(flag) { result.append("-" + String(flag)) }
                    else if schema.values.contains(flag) {
                        result.append("-" + String(flag))
                        if offset < letters.count { result.append(String(letters.dropFirst(offset))) }
                        else {
                            guard index < words.count else { throw SearchServiceError.commandFailed("-\(flag) needs a value.") }
                            result.append(words[index]); index += 1
                        }
                        break
                    } else {
                        throw SearchServiceError.commandFailed("Unsupported \(tool.rawValue) option -\(flag) in \(word). No command was applied.")
                    }
                }
            } else { result.append(word) }
            try checkLimit()
        }
        return result
    }
}
