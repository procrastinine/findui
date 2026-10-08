import Foundation
import Darwin

package enum SearchPath {
    package struct Resolution {
        package let url: URL
        package let original: String
        package let corrected: Bool
        package init(url: URL, original: String, corrected: Bool) {
            self.url = url
            self.original = original
            self.corrected = corrected
        }

    }

    /// Resolve a model-extracted folder against the local filesystem. An exact
    /// existing path always wins. Bare names try the current search folder, home,
    /// then the filesystem root; explicit prefixes retain their scope. Only one
    /// unambiguous, one-edit directory name may be corrected. Search predicates
    /// and explicitly pasted commands are not passed through this resolver.
    package static func resolveFolder(_ input: String, relativeTo base: URL,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              filesystemRoot: URL = URL(fileURLWithPath: "/")) throws -> Resolution {
        let manager = FileManager.default
        // The extractor has already chosen the substring. Spaces can be part of
        // a real directory name, so do not silently trim a nonempty path.
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0") else {
            throw SearchServiceError.commandFailed("Enter a search folder.")
        }
        let candidates: [(start: URL, path: String)]
        if text == "~" || text.hasPrefix("~/") {
            candidates = [(home, text == "~" ? "" : String(text.dropFirst(2)))]
        } else if text.hasPrefix("/") {
            candidates = [(URL(fileURLWithPath: "/"), String(text.dropFirst()))]
        } else if text == "." || text == ".." || text.hasPrefix("./") || text.hasPrefix("../") {
            candidates = [(base, text)]
        } else {
            candidates = [(base, text), (home, text), (filesystemRoot, text)]
        }
        var seen = Set<String>()
        let locations = candidates.filter {
            seen.insert($0.start.appendingPathComponent($0.path).standardizedFileURL.path).inserted
        }
        var existingFile: URL?
        // Inspect all exact candidates before attempting any spelling repair.
        for candidate in locations {
            let requested = candidate.start.appendingPathComponent(candidate.path).standardizedFileURL
            var directory = ObjCBool(false)
            if manager.fileExists(atPath: requested.path, isDirectory: &directory) {
                if directory.boolValue {
                    return Resolution(url: requested, original: input, corrected: false)
                }
                existingFile = existingFile ?? requested
            }
        }
        if let existingFile {
            throw SearchServiceError.commandFailed("Search folder is a file: \(existingFile.path)")
        }
        for candidate in locations {
            if let corrected = try correctedFolder(candidate.path, relativeTo: candidate.start) {
                return Resolution(url: corrected.standardizedFileURL, original: input, corrected: true)
            }
        }
        throw SearchServiceError.commandFailed("Search folder not found: \(input)")
    }

    private static func correctedFolder(_ path: String, relativeTo base: URL) throws -> URL? {
        let manager = FileManager.default
        var current = base
        var corrections = 0
        for component in path.split(separator: "/").map(String.init) {
            let next = current.appendingPathComponent(component)
            var directory = ObjCBool(false)
            if manager.fileExists(atPath: next.path, isDirectory: &directory) {
                guard directory.boolValue else { return nil }
                current = next
                continue
            }
            // Do not infer short names, traverse a tree, or repeatedly repair a
            // badly guessed path. Only inspect this component's actual siblings.
            guard corrections == 0, component.count >= 4, component != ".." else {
                return nil
            }
            guard let children = try? manager.contentsOfDirectory(at: current, includingPropertiesForKeys: nil),
                  children.count <= 10_000 else {
                return nil
            }
            let matches = children.filter { child in
                guard oneEditApart(component, child.lastPathComponent) else { return false }
                var isDirectory = ObjCBool(false)
                return manager.fileExists(atPath: child.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if matches.isEmpty { return nil }
            guard matches.count == 1 else {
                let hint = matches.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
                throw SearchServiceError.commandFailed("Search folder is ambiguous: \(path). Possible folders: \(hint).")
            }
            current = matches[0]
            corrections += 1
        }
        return current
    }

    /// Includes adjacent transpositions (Docmuents), unlike plain Levenshtein.
    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.precomposedStringWithCanonicalMapping.lowercased())
        let b = Array(rhs.precomposedStringWithCanonicalMapping.lowercased())
        guard abs(a.count - b.count) <= 1 else { return false }
        if a == b { return true }
        if a.count == b.count {
            let changed = a.indices.filter { a[$0] != b[$0] }
            return changed.count == 1 || (changed.count == 2 && changed[1] == changed[0] + 1
                && a[changed[0]] == b[changed[1]] && a[changed[1]] == b[changed[0]])
        }
        let short = a.count < b.count ? a : b
        let long = a.count < b.count ? b : a
        var i = 0
        while i < short.count && short[i] == long[i] { i += 1 }
        return Array(short.dropFirst(i)) == Array(long.dropFirst(i + 1))
    }

    package static func contains(_ url: URL, in scope: URL) -> Bool {
        let root = scope.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return root == "/" || path == root || path.hasPrefix(root + "/")
    }

    package static func relativePath(of url: URL, in scope: URL) -> String? {
        let path = url.standardizedFileURL.path
        let selected = scope.standardizedFileURL.path
        func relative(_ path: String, to root: String) -> String? {
            guard root == "/" || path == root || path.hasPrefix(root + "/") else { return nil }
            return String(path.dropFirst(root == "/" ? 1 : min(path.count, root.count + 1)))
        }
        if let result = relative(path, to: selected) { return result }
        // Foundation can expose /var for an existing URL and /private/var
        // for the same now-missing file. Resolve only the selected root, so a
        // frozen entry and child symlinks do not require live target metadata.
        func canonical(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // Foundation's resolver rewrites /private/var back to /var. POSIX
        // realpath supplies the same spelling used by the Rust backend.
        guard let root = canonical(selected) else { return nil }
        if let result = relative(path, to: root) { return result }
        guard let parent = canonical(url.deletingLastPathComponent().path) else { return nil }
        return relative(parent + "/" + url.lastPathComponent, to: root)
    }

    /// Lexical path-prefix expansion only. Never repairs spelling or scans the
    /// filesystem, and is not used for regex or fuzzy pattern fragments.
    package static func expandPatternPrefix(_ value: String, relativeTo base: URL,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        if value.hasPrefix("/") { return value }
        if value == "~" { return home.path }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))).path }
        if value == "." || value == ".." || value.hasPrefix("./") || value.hasPrefix("../") {
            return base.appendingPathComponent(value).standardizedFileURL.path
        }
        return nil
    }
}
