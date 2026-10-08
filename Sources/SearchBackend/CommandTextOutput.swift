import Foundation

/// Text output is separate from file results: counts, formatted paths, help and
/// tool actions must never acquire invented filenames or clickable file rows.
package struct CommandTextOutput: Sendable, Equatable {
    package static let maximumBytes = 1_048_576
    package var text: String
    package var isTruncated: Bool
    package init(text: String = "", isTruncated: Bool = false) {
        self.text = text; self.isTruncated = isTruncated
    }
}

package actor CommandTextAccumulator {
    private var bytes = Data()
    private var truncated = false
    private var changed = false
    private var first = true

    package init() {}
    package func append(_ chunk: Data) -> CommandTextOutput? {
        let remaining = CommandTextOutput.maximumBytes - bytes.count
        if remaining > 0 { bytes.append(chunk.prefix(remaining)); changed = true }
        if chunk.count > remaining && !truncated { truncated = true; changed = true }
        guard first else { return nil }
        first = false
        return flush()
    }
    package func flush() -> CommandTextOutput? {
        guard changed else { return nil }
        changed = false
        return snapshot()
    }
    package func snapshot() -> CommandTextOutput {
        // Decode retained bytes together so a UTF-8 scalar split across reads
        // is reconstructed. Non-text bytes use the ordinary replacement glyph.
        CommandTextOutput(text: String(decoding: bytes, as: UTF8.self), isTruncated: truncated)
    }
}
