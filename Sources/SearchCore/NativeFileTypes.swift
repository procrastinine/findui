import Foundation

extension SearchPlanner {
    /// Unlike positive -g overrides, rg types respect ignore-file exclusions.
    /// They still whitelist hidden basenames; nativeRG adds a hidden exclusion.
    /// A single basename predicate (or OR of them) is representable by types;
    /// arbitrary intersections remain in the shared selector.
    func fileTypeGlobs(_ query: SearchQuery) -> [String]? {
        func literal(_ text: String) -> String? {
            if needsCanonicalFilenamePattern(text) { return nil }
            if query.options.fileCaseSensitive { return escapeGlob(text) }
            guard text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
            return text.reduce(into: "") { value, character in
                // globset classes operate on bytes. Multibyte fold partners
                // need alternatives, not a character class.
                if character == "k" || character == "K" { value += "{k,K,K}" }
                else if character == "s" || character == "S" { value += "{s,S,ſ}" }
                else if character.isLetter { value += "[" + character.lowercased() + character.uppercased() + "]" }
                else { value += escapeGlob(String(character)) }
            }
        }
        func render(_ node: QueryTree<FilePredicate>) -> [String]? {
            switch node {
            case .leaf(.extensions(let values)):
                let patterns = values.compactMap { literal($0).map { "*." + $0 } }
                return patterns.count == values.count ? patterns : nil
            case .leaf(.text(let match)):
                guard match.field == .name, !match.text.contains("/") else { return nil }
                switch match.kind {
                case .literal: return literal(match.text).map { ["*" + $0 + "*"] }
                case .exact: return literal(match.text).map { [$0] }
                case .glob:
                    guard !match.text.contains(where: { "[]{}\\".contains($0) }) else { return nil }
                    var pattern = ""
                    for char in match.text {
                        if char == "*" || char == "?" { pattern.append(char) }
                        else if let value = literal(String(char)) { pattern += value }
                        else { return nil }
                    }
                    return [pattern]
                case .regex:
                    return basenameGlob(from: match.text, caseSensitive: query.options.fileCaseSensitive).map { [$0] }
                default: return nil
                }
            case .any(let children):
                var patterns: [String] = []
                for child in children { guard let values = render(child) else { return nil }; patterns += values }
                return !patterns.isEmpty && patterns.count <= 64 ? patterns : nil
            default: return nil
            }
        }
        return render(query.files.simplified)
    }

    /// Recognize the anchored wildcard regex emitted by command import. This
    /// preserves native glob semantics (including ASCII-only folds) without
    /// forcing a file filter plus content search through the shared worker.
    private func basenameGlob(from regex: String, caseSensitive: Bool) -> String? {
        let body: String
        if regex.hasPrefix("(?s-i:\\A"), regex.hasSuffix("\\z)") {
            body = String(regex.dropFirst(8).dropLast(3))
        } else if caseSensitive, regex.hasPrefix("\\A"), regex.hasSuffix("\\z") {
            body = String(regex.dropFirst(2).dropLast(2))
        } else { return nil }
        let chars = Array(body)
        var result = "", i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "." {
                if i + 1 < chars.count && chars[i + 1] == "*" { result += "*"; i += 2 }
                else { result += "?"; i += 1 }
                continue
            }
            if char == "\\" {
                i += 1
                guard i < chars.count, ".^$|?*+()[]{}\\".contains(chars[i]) else { return nil }
                result += escapeGlob(String(chars[i])); i += 1; continue
            }
            if char == "[" {
                guard let end = chars[(i + 1)...].firstIndex(of: "]"), end > i + 1,
                      chars[(i + 1)..<end].allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
                result += String(chars[i...end]); i = end + 1; continue
            }
            if ".^$|?*+()[]{}\\/".contains(char) { return nil }
            result += escapeGlob(String(char)); i += 1
        }
        return result.isEmpty ? nil : result
    }
}
