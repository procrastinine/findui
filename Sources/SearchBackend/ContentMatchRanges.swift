import Foundation

package enum ContentMatchRanges {
    /// Map the backend's original byte offsets, including malformed UTF-8,
    /// into the replacement-decoded string shown by AppKit.
    package static func utf16Range(bytes: Data, byteStart: Int, byteEnd: Int, trimmingNewlines: Bool) -> Range<Int>? {
        guard byteEnd > byteStart else { return nil }
        return utf16Ranges(bytes: bytes, offsets: [byteStart..<byteEnd], trimmingNewlines: trimmingNewlines).first
    }

    /// Decode each byte at most once. Keep only requested offsets, rather than
    /// allocating a table proportional to a potentially very large input line.
    /// Interior offsets have the same replacement-decoding meaning as decoding
    /// a byte prefix, including truncated and malformed UTF-8 sequences.
    package static func utf16Ranges(bytes: Data, offsets: [Range<Int>], trimmingNewlines: Bool,
                                    decoded: String? = nil) -> [Range<Int>] {
        let valid = offsets.filter { $0.lowerBound >= 0 && !$0.isEmpty && $0.upperBound <= bytes.count }
        guard !valid.isEmpty else { return [] }
        let full = decoded ?? String(decoding: bytes, as: UTF8.self)
        let leading = trimmingNewlines ? full.prefix(while: { $0.unicodeScalars.allSatisfy(CharacterSet.newlines.contains) }).utf16.count : 0
        let length = (trimmingNewlines ? full.trimmingCharacters(in: .newlines) : full).utf16.count
        // ASCII byte and UTF-16 offsets are identical. Dense ordinary text
        // needs no endpoint set, sorting or dictionary of converted offsets.
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return valid.compactMap { range in
                let lower = min(length, max(0, range.lowerBound - leading))
                let upper = min(length, max(0, range.upperBound - leading))
                return upper > lower ? lower..<upper : nil
            }
        }
        let endpoints = Set(valid.flatMap { [$0.lowerBound, $0.upperBound] }).sorted()
        var mapped: [Int: Int] = [:]; mapped.reserveCapacity(endpoints.count)
        bytes.withUnsafeBytes { raw in
            let data = raw.bindMemory(to: UInt8.self)
            var position = 0, units = 0, next = 0
            while next < endpoints.count {
                if position & 4095 == 0 && Task<Never, Never>.isCancelled { return }
                while next < endpoints.count && endpoints[next] == position {
                    mapped[position] = units; next += 1
                }
                guard next < endpoints.count, position < data.count else { break }
                let first = data[position]
                let width = first < 0x80 ? 1 : (0xC2...0xDF).contains(first) ? 2
                    : (0xE0...0xEF).contains(first) ? 3 : (0xF0...0xF4).contains(first) ? 4 : 1
                var consumed = 1
                while consumed < width && position + consumed < data.count {
                    let byte = data[position + consumed]
                    let lower: UInt8 = consumed == 1 && first == 0xE0 ? 0xA0 : consumed == 1 && first == 0xF0 ? 0x90 : 0x80
                    let upper: UInt8 = consumed == 1 && first == 0xED ? 0x9F : consumed == 1 && first == 0xF4 ? 0x8F : 0xBF
                    guard byte >= lower && byte <= upper else { break }
                    consumed += 1
                }
                while next < endpoints.count && endpoints[next] < position + consumed {
                    mapped[endpoints[next]] = units + 1; next += 1
                }
                units += consumed == 4 ? 2 : 1
                position += consumed
            }
        }
        return valid.compactMap { range in
            guard let a = mapped[range.lowerBound], let b = mapped[range.upperBound] else { return nil }
            let lower = min(length, max(0, a - leading)), upper = min(length, max(0, b - leading))
            return upper > lower ? lower..<upper : nil
        }
    }

    package static func literal(in text: String, query: String, caseSensitive: Bool) -> [Range<Int>] {
        let source = text as NSString
        let terms = ParsedSearchQuery.parseLiteral(query).includeTokens.filter { $0.field == .any }
        var ranges: [Range<Int>] = []
        for term in terms {
            var start = 0
            while start < source.length {
                let range = source.range(of: term.value, options: caseSensitive ? [] : [.caseInsensitive],
                                         range: NSRange(location: start, length: source.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                ranges.append(range.location..<(range.location + range.length))
                start = range.location + range.length
            }
        }
        return merged(ranges)
    }

    package static func utf16Range(in text: String, byteStart: Int, byteEnd: Int) -> Range<Int>? {
        guard byteStart >= 0, byteEnd > byteStart, byteEnd <= text.utf8.count else { return nil }
        let bytes = text.utf8
        guard let start = String.Index(bytes.index(bytes.startIndex, offsetBy: byteStart), within: text),
              let end = String.Index(bytes.index(bytes.startIndex, offsetBy: byteEnd), within: text) else { return nil }
        let nsRange = NSRange(start..<end, in: text)
        return nsRange.location..<(nsRange.location + nsRange.length)
    }

    package static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
