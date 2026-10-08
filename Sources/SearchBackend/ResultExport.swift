import Foundation

package enum ResultExport {
    package static func uniqueURLs(_ results: [SearchResult]) -> [URL] {
        var seen = Set<String>()
        return results.filter { !$0.isParentDirectoryEntry }.compactMap {
            seen.insert($0.url.standardizedFileURL.path).inserted ? $0.url : nil
        }
    }

    package static func paths(_ results: [SearchResult]) -> String {
        uniqueURLs(results).map(\.path).joined(separator: "\n")
    }

    package static func matchingLines(_ results: [SearchResult]) -> String {
        results.compactMap { result in
            guard let snippet = result.snippet else { return nil }
            if let origin = result.extractedOrigin { return "\(result.path): [\(origin.label)] \(snippet)" }
            guard let line = result.lineNumber else { return nil }
            return "\(result.path):\(line): \(snippet)"
        }.joined(separator: "\n")
    }

    package static func csv(_ results: [SearchResult]) -> String {
        func row(_ fields: [String]) -> String {
            fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        let header = row(["Name", "Path", "Line", "Match", "Size (bytes)", "Modified", "Created", "Extracted location"])
        let rows = results.filter { !$0.isParentDirectoryEntry }.map {
            row([$0.name, $0.path, $0.lineNumber.map(String.init) ?? "", $0.snippet ?? "",
                 $0.size.map(String.init) ?? "", $0.modifiedAt?.ISO8601Format() ?? "", $0.createdAt?.ISO8601Format() ?? "",
                 $0.extractedOrigin?.label ?? ""])
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

package struct ContentResultGroup: Identifiable {
    package let id: String
    package let matches: [SearchResult]
    package var first: SearchResult { matches[0] }

    package static func groups(from results: [SearchResult]) -> [Self] {
        var order: [String] = []
        var grouped: [String: [SearchResult]] = [:]
        for result in results {
            if grouped[result.documentIdentity] == nil { order.append(result.documentIdentity) }
            grouped[result.documentIdentity, default: []].append(result)
        }
        return order.map { path in
            Self(id: path, matches: grouped[path]!.sorted {
                let firstLine = $0.lineNumber ?? $0.extractedOrigin?.line ?? 0
                let secondLine = $1.lineNumber ?? $1.extractedOrigin?.line ?? 0
                if firstLine != secondLine { return firstLine < secondLine }
                return $0.sourceOrder < $1.sourceOrder
            })
        }
    }
    package init(id: String, matches: [SearchResult]) {
        self.id = id
        self.matches = matches
    }

}
