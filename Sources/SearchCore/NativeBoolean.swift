import Foundation

extension SearchPlanner {
    /// A files-only, same-line Boolean search needs no highlight reconstruction.
    /// Byte-mode PCRE2 assertions express literal groups directly. Explicit case
    /// folds preserve Rust's Unicode simple folds for ASCII patterns, including
    /// Kelvin K and long s, while accepting invalid UTF-8 source bytes.
    func nativeBooleanPattern(_ query: SearchQuery) -> String? {
        guard tools.rgPCRE2, query.output == .paths, query.unit == .line,
              !query.options.wholeWords, !query.options.multiline, let tree = query.contents,
              tree.single == nil, tree.leaves.allSatisfy({ leaf in
                  if case .allLines = leaf { return true }
                  if case .literal(let text) = leaf { return text.utf8.allSatisfy { $0 < 128 && $0 != 10 && $0 != 0 } }
                  return false
              }) else { return nil }
        func literal(_ text: String) -> String {
            if query.options.contentCaseSensitive { return escapeRegex(text) }
            return text.reduce(into: "") { out, char in
                switch char.lowercased() {
                case "k": out += "(?:[kK]|\\xE2\\x84\\xAA)"
                case "s": out += "(?:[sS]|\\xC5\\xBF)"
                default:
                    if char.isLetter { out += "[" + char.lowercased() + char.uppercased() + "]" }
                    else { out += escapeRegex(String(char)) }
                }
            }
        }
        func render(_ node: QueryTree<ContentPredicate>) -> String {
            switch node {
            case .leaf(.literal(let text)): return "(?=[^\\n]*" + literal(text) + ")"
            case .leaf: return ""
            case .all(let children): return children.map(render).joined()
            case .any(let children): return children.isEmpty ? "(?!)" : "(?:" + children.map(render).joined(separator: "|") + ")"
            case .none(let children): return children.isEmpty ? "" : "(?!" + children.map(render).joined(separator: "|") + ")"
            }
        }
        let pattern = "^" + render(tree)
        return pattern.utf8.count <= 16_384 ? pattern : nil
    }
}
