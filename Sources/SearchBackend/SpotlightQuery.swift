import Foundation

/// Only compiler-owned metadata predicates reach mdfind. Query text remains an
/// argv value, including when the complete pipeline is copied to a shell.
package enum SpotlightQuery {
    package static func predicate(for request: SearchRequest, bounds: ValidatedSearchFilters) throws -> String {
        var clauses = ["kMDItemFSName == '*'"]
        if request.searchesDocumentText {
            guard request.syntax == .literal, !request.refinements.wholeWords else {
                throw SearchServiceError.commandFailed("Document text uses Spotlight matching. Use Literal without Whole words, or choose file text for regex and whole-word searches.")
            }
            for token in ParsedSearchQuery.parseLiteral(request.query).tokens where token.field == .any {
                // Spotlight's wildcard escaping is not specified consistently
                // across importers. Do not silently turn literal * or ? into
                // broader matches or treat a byte regex as document text.
                guard !token.value.contains(where: { "*?".contains($0) }) else {
                    throw SearchServiceError.commandFailed("Document text cannot match literal * or ? characters. Use file text for these patterns.")
                }
                let escaped = token.value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                // mdfind/MDQuery use the suffix modifier. The archived Cocoa
                // ==[c] spelling parses alone but fails in compound MDQuery
                // expressions on macOS 27; exercise the actual native parser.
                let match = "kMDItemTextContent == \"*\(escaped)*\"\(request.caseSensitive ? "" : "c")"
                clauses.append(token.isExcluded ? "!(\(match))" : "(\(match))")
            }
        }
        if let attribute = request.filters.dateField.spotlightAttribute {
            // CFDate seconds since 2001, rather than Unix seconds since 1970.
            if let from = bounds.from { clauses.append("\(attribute) >= \(from.timeIntervalSinceReferenceDate)") }
            if let before = bounds.before { clauses.append("\(attribute) < \(before.timeIntervalSinceReferenceDate)") }
        }
        return clauses.joined(separator: " && ")
    }
}
