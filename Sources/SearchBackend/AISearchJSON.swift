import Foundation

/// Foundation's JSON parser accepts duplicate object keys, keeping only the
/// last value. Reject that ambiguity before decoding a model's instructions.
/// This pass only inspects structure/keys; Foundation validates the JSON syntax.
enum AISearchJSON {
    static func validateObjectKeys(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw AISearchError.message("Invalid AI search: expected UTF-8 JSON.")
        }
        let bytes = Array(data)
        var stack: [(object: Bool, keys: Set<String>)] = []
        var index = 0
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91: // { [
                guard stack.count < 32 else { throw AISearchError.message("Invalid AI search: JSON nesting is too deep.") }
                stack.append((bytes[index] == 123, []))
            case 125, 93: // } ]
                guard let last = stack.popLast(), last.object == (bytes[index] == 125) else {
                    throw AISearchError.message("Invalid AI search: mismatched JSON containers.")
                }
            case 34: // quoted string, including escaped quotation marks
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw AISearchError.message("Invalid AI search: incomplete JSON string.") }
                var next = index + 1
                while next < bytes.count && whitespace(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 && stack.last?.object == true {
                    // Decode escapes too: "hidden" and "\u0068idden" are the same key.
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard stack[stack.count - 1].keys.insert(key).inserted else {
                        throw AISearchError.message("Invalid AI search: duplicate JSON object key.")
                    }
                }
            default: break
            }
            index += 1
        }
        guard stack.isEmpty else { throw AISearchError.message("Invalid AI search: incomplete JSON object.") }
    }
}
