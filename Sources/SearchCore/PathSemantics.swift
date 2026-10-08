import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Foundation rewrites /private/var back to /var on macOS. Native walkers use
/// POSIX spelling, so compare the actual root without resolving every child.
public func canonicalIdentityPath(_ path: String) -> String {
    var ancestor = path
    var suffix: [String] = []
    while true {
        if let resolved = realpath(ancestor, nil) {
            defer { free(resolved) }
            let root = String(cString: resolved)
            return suffix.isEmpty ? root : (root == "/" ? "" : root) + "/" + suffix.reversed().joined(separator: "/")
        }
        let parent = (ancestor as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != ancestor else { return path }
        suffix.append((ancestor as NSString).lastPathComponent)
        ancestor = parent
    }
}

func canonicalRoot(_ path: String) -> String { canonicalIdentityPath(path) }

func overlappingRoots(_ roots: [String]) -> Bool {
    let paths = roots.map(canonicalRoot)
    return paths.indices.contains { i in
        paths.indices.contains { j in
            i != j && (paths[i] == paths[j] || paths[j].hasPrefix(paths[i] == "/" ? "/" : paths[i] + "/"))
        }
    }
}

/// macOS filenames can be composed or decomposed Unicode. Literal filename
/// controls accept both forms; regex controls retain their explicit semantics.
/// The same bounded regex is passed to fd and the shared predicate executor.
func filenameLiteralRegex(_ text: String) -> String {
    text.reduce(into: "") { out, character in
        let composed = String(character).precomposedStringWithCanonicalMapping
        let decomposed = String(character).decomposedStringWithCanonicalMapping
        if composed.utf8.elementsEqual(decomposed.utf8) { out += escapeRegex(composed) }
        else { out += "(?:" + escapeRegex(composed) + "|" + escapeRegex(decomposed) + ")" }
    }
}

/// Inverse of the canonical-Unicode literal lowering above. Only accept the
/// exact generated grammar, then prove it by rendering again. Other regexes
/// stay regexes; this is not a heuristic interpretation of user expressions.
public func filenameLiteralFromRegex(_ pattern: String) -> String? {
    var rest = pattern[...], text = "", alternatives = false
    while !rest.isEmpty {
        if rest.hasPrefix("(?:"), let end = rest.firstIndex(of: ")") {
            let pair = rest.dropFirst(3)[..<end].split(separator: "|", omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].count == 1,
                  String(pair[0]).decomposedStringWithCanonicalMapping.utf8.elementsEqual(pair[1].utf8) else { return nil }
            text += pair[0]; rest = rest[rest.index(after: end)...]; alternatives = true
        } else if rest.first == "\\" {
            rest.removeFirst()
            guard let char = rest.first, "\\.^$|?*+()[]{}".contains(char) else { return nil }
            text.append(char); rest.removeFirst()
        } else {
            guard let char = rest.first, !".^$|?*+()[]{}".contains(char) else { return nil }
            text.append(char); rest.removeFirst()
        }
    }
    return alternatives && filenameLiteralRegex(text).utf8.elementsEqual(pattern.utf8) ? text : nil
}

func needsCanonicalFilenamePattern(_ text: String) -> Bool {
    !text.precomposedStringWithCanonicalMapping.utf8.elementsEqual(text.decomposedStringWithCanonicalMapping.utf8)
}
