import Foundation

/// A bounded display projection. Search, copy and export retain the complete
/// snippet and all backend match offsets. No GUI framework is required.
package struct SnippetWindow: Sendable {
    package let text: String
    package let ranges: [Range<Int>]
    package let shortened: Bool
    package init(text: String, ranges: [Range<Int>], match: Int = 0, limit: Int = 1_200, context: Int = 80) {
        let count = text.utf16.count
        let limit = max(16, limit)
        if count <= limit {
            self.text = text
            self.ranges = ranges
            shortened = false
            return
        }
        let target = ranges.isEmpty ? 0 : ranges[min(max(0, match), ranges.count - 1)].lowerBound
        // Keep the selected match near the top even at the end of a long line.
        // Filling the whole window backwards would hide it below the viewport.
        var lower = max(0, min(target - max(0, context), count))
        var upper = min(count, lower + limit)
        while lower > 0 && String.Index(utf16Offset: lower, in: text).samePosition(in: text.unicodeScalars) == nil {
            lower -= 1
        }
        while upper < count && String.Index(utf16Offset: upper, in: text).samePosition(in: text.unicodeScalars) == nil {
            upper += 1
        }
        let prefix = lower > 0 ? "…" : ""
        let suffix = upper < count ? "…" : ""
        self.text =
            prefix
            + String(text[String.Index(utf16Offset: lower, in: text)..<String.Index(utf16Offset: upper, in: text)])
            + suffix
        self.ranges = ranges.compactMap { range in
            let start = max(range.lowerBound, lower)
            let end = min(range.upperBound, upper)
            return end > start ? (start - lower + prefix.utf16.count)..<(end - lower + prefix.utf16.count) : nil
        }
        shortened = true
    }
}
