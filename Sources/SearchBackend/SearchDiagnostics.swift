import Foundation
import SearchCore

/// Machine state has a versioned protocol. Human diagnostics may change wording
/// without changing failure/partial-result handling.
package struct SearchDiagnostics {
    package var completion: SearchCompletion?
    package var wordStatus: WordIndexStatus?
    package var warnings = ""
    package var protocolError: String?
    package init(_ stderr: String) {
        var messages: [String] = []
        for line in stderr.split(separator: "\n") {
            if line.hasPrefix("findui-completion: ") {
                do {
                    let value = try JSONDecoder().decode(SearchCompletion.self, from: Data(line.dropFirst("findui-completion: ".count).utf8))
                    guard value.version == 1, completion == nil else { throw PlanningError.invalid("Invalid search completion record.") }
                    completion = value
                } catch { protocolError = "Invalid search completion record: \(error.localizedDescription)" }
            } else if line.hasPrefix("findui-word-status: ") {
                wordStatus = try? JSONDecoder().decode(WordIndexStatus.self, from: Data(line.dropFirst("findui-word-status: ".count).utf8))
            } else if !line.hasPrefix("findui-stats: ") { messages.append(String(line)) }
        }
        warnings = messages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
