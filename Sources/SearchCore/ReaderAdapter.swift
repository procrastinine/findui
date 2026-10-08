import Foundation

public struct ReaderAdapter: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var extensions: [String]
    public var executable: String
    public var arguments: [String]
    public var enabled: Bool
    public init(
        id: String = UUID().uuidString, title: String = "", extensions: [String] = [], executable: String = "",
        arguments: [String] = ["{path}"], enabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.extensions = extensions
        self.executable = executable
        self.arguments = arguments
        self.enabled = enabled
    }
    private enum CodingKeys: String, CodingKey { case id, title, extensions, executable, arguments, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
            extensions: try c.decode([String].self, forKey: .extensions),
            executable: try c.decode(String.self, forKey: .executable),
            arguments: try c.decode([String].self, forKey: .arguments),
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !title.isEmpty, executable.hasPrefix("/"), !executable.contains("\0"),
            !extensions.isEmpty, extensions.count <= 64,
            extensions.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 32
                    && $0.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
            }), arguments.count <= 128, arguments.contains(where: { $0.contains("{path}") }),
            arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65_536 })
        else {
            throw PlanningError.invalid(
                "A reader needs a name, lowercase file extensions, an absolute program path, and arguments containing {path}."
            )
        }
    }
}
