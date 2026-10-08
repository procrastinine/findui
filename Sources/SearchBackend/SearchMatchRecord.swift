import Foundation

/// Decode only the fields consumed by presentation. In particular, ripgrep's
/// repeated submatch text does not need a second object graph or string copy.
package struct SearchMatchRecord: Decodable {
    let type: String
    let data: Payload

    struct Text: Decodable {
        let text: String?
        let bytes: String?
        enum CodingKeys: String, CodingKey { case text, bytes }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try? values.decodeIfPresent(String.self, forKey: .text)
            bytes = try? values.decodeIfPresent(String.self, forKey: .bytes)
        }
        var decodedBytes: Data? { text.map { Data($0.utf8) } ?? bytes.flatMap { Data(base64Encoded: $0) } }
        var path: String? { text ?? decodedBytes.flatMap { String(data: $0, encoding: .utf8) } }
    }
    struct Offset: Decodable {
        let range: Range<Int>?
        enum CodingKeys: String, CodingKey { case start, end }
        init(from decoder: Decoder) throws {
            guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { range = nil; return }
            if let start = try? values.decodeIfPresent(Int.self, forKey: .start),
               let end = try? values.decodeIfPresent(Int.self, forKey: .end), end > start {
                range = start..<end
            } else { range = nil }
        }
    }
    struct File: Decodable {
        let directory: Bool
        let modified: Double?
        let created: Double?
        let size: Int64?
        let tags: [String]?
        enum CodingKeys: String, CodingKey { case directory, modified, created, size, tags }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            directory = try values.decode(Bool.self, forKey: .directory)
            modified = try? values.decodeIfPresent(Double.self, forKey: .modified)
            created = try? values.decodeIfPresent(Double.self, forKey: .created)
            size = try? values.decodeIfPresent(Int64.self, forKey: .size)
            tags = try? values.decodeIfPresent([String].self, forKey: .tags)
        }
    }
    struct Payload: Decodable {
        let path: Text
        let lines: Text?
        let line: Int?
        let offsets: [Range<Int>]
        let file: File?
        let tags: [String]?
        let origin: ExtractedMatchOrigin?
        enum CodingKeys: String, CodingKey {
            case path, lines, submatches, line = "line_number", file = "findui_file"
            case tags = "findui_tags", origin = "findui_origin"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(Text.self, forKey: .path)
            lines = try? values.decodeIfPresent(Text.self, forKey: .lines)
            line = try? values.decodeIfPresent(Int.self, forKey: .line)
            offsets = (try? values.decodeIfPresent([Offset].self, forKey: .submatches))?.compactMap(\.range) ?? []
            file = try? values.decodeIfPresent(File.self, forKey: .file)
            tags = try? values.decodeIfPresent([String].self, forKey: .tags)
            origin = try? values.decodeIfPresent(ExtractedMatchOrigin.self, forKey: .origin)
        }
    }
}
