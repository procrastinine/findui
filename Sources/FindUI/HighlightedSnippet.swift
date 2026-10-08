import SearchBackend
import SwiftUI

struct HighlightedSnippet: View {
    let result: SearchResult
    var match = 0

    var body: some View { Text(attributedText) }

    private var attributedText: AttributedString {
        let window = SnippetWindow(text: result.snippet ?? "", ranges: result.snippetMatchRanges, match: match)
        let snippet = window.text
        var output = AttributedString()
        var start = snippet.startIndex
        for offsets in ContentMatchRanges.merged(window.ranges) {
            guard let range = Range(NSRange(location: offsets.lowerBound, length: offsets.count), in: snippet),
                  range.lowerBound >= start else { continue }
            output.append(AttributedString(snippet[start..<range.lowerBound]))
            var match = AttributedString(snippet[range])
            match.backgroundColor = Color.yellow.opacity(0.3)
            match.foregroundColor = Color.primary
            output.append(match)
            start = range.upperBound
        }
        output.append(AttributedString(snippet[start...]))
        return output
    }
}
