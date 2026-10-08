import Foundation

package struct ContentPreviewLine: Identifiable, Codable, Sendable {
    package let number: Int
    package let text: String
    package let isMatch: Bool
    package var id: Int { number }
    package init(number: Int, text: String, isMatch: Bool) {
        self.number = number
        self.text = text
        self.isMatch = isMatch
    }

}

package struct ContentPreview: Codable, Sendable {
    package let lines: [ContentPreviewLine]
    package var warning: String? = nil
    package init(lines: [ContentPreviewLine], warning: String? = nil) {
        self.lines = lines
        self.warning = warning
    }

}

package enum ContentPreviewReader {
    package static func readShared(url: URL, lineNumber: Int, expectedSnippet: String?, radius: Int, encoding: String?) async throws -> ContentPreview {
        let tools = Toolchain.resolve()
        guard let worker = tools.contentWorker else {
            return try read(url: url, lineNumber: lineNumber, expectedSnippet: expectedSnippet, radius: radius)
        }
        let options: [String: Any] = ["path": url.path, "line": lineNumber, "context": radius,
            "expectedSnippet": expectedSnippet as Any? ?? NSNull(), "encoding": encoding as Any? ?? NSNull()]
        let json = try JSONSerialization.data(withJSONObject: options)
        let output = try await ProcessRunner.run(spec: .init(executable: worker, arguments: ["--text-preview", String(decoding: json, as: UTF8.self)]), pathOverride: tools.searchPath)
        guard output.exitCode == 0 else { throw SearchServiceError.commandFailed(output.stderr) }
        return try JSONDecoder().decode(ContentPreview.self, from: Data(output.stdout.utf8))
    }
    /// Read only as far as the selected context, with explicit memory and I/O bounds.
    package static func read(url: URL, lineNumber: Int, expectedSnippet: String? = nil,
                     radius: Int = 3, byteLimit: Int = 16 * 1024 * 1024) throws -> ContentPreview {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let firstLine = max(1, lineNumber - max(0, radius))
        let expected = expectedSnippet?.components(separatedBy: "\n") ?? []
        let span = max(1, expected.count)
        let lastMatch = lineNumber + span - 1
        let lastLine = lastMatch + max(0, radius)
        var verified = 0
        var lines: [ContentPreviewLine] = []
        var pending = Data()
        var number = 1
        var bytesRead = 0
        var reachedEnd = false
        var warning: String?
        var scanned = 0

        func appendLine(_ bytes: Data) {
            guard number >= firstLine && number <= lastLine else { return }
            var text = String(decoding: bytes, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            if number >= lineNumber && number <= lastMatch {
                verified += 1
                if !expected.isEmpty, text != expected[number - lineNumber].trimmingCharacters(in: .newlines) {
                    warning = "This file changed since the search. Run the search again to update matches."
                }
                if number != lineNumber { return }
            }
            if text.count > 4_000 {
                text = String(text.prefix(4_000)) + "…"
                warning = warning ?? "Long preview lines are shortened."
            }
            lines.append(ContentPreviewLine(number: number, text: text, isMatch: number == lineNumber))
        }

        while number <= lastLine && bytesRead < byteLimit {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, byteLimit - bytesRead)) ?? Data()
            if chunk.isEmpty { reachedEnd = true; break }
            bytesRead += chunk.count
            pending.append(chunk)
            var start = pending.startIndex
            for index in pending.indices.dropFirst(scanned) where pending[index] == 10 {
                appendLine(Data(pending[start..<index]))
                number += 1
                start = index + 1
                if number > lastLine { break }
            }
            if start > pending.startIndex { pending = Data(pending[start...]) }
            scanned = pending.count
        }
        if reachedEnd && !pending.isEmpty && number <= lastLine { appendLine(pending) }
        if !reachedEnd && number <= lastLine && bytesRead >= byteLimit {
            warning = "Context preview reached its 16 MB read limit. Open this match in an editor for the full file."
        } else if !lines.contains(where: \.isMatch) || verified < span {
            warning = "The matching line is no longer available. Run the search again."
        }
        return ContentPreview(lines: lines, warning: warning)
    }
}
