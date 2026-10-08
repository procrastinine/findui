import Foundation

package struct ResultFacet: Codable, Hashable, Identifiable, Sendable {
    package enum Kind: String, Codable, Sendable { case fileType, folder, modified, tag }
    package let kind: Kind
    package let value: String
    package let count: Int
    package var id: String { kind.rawValue + ":" + value }
    package var title: String {
        switch kind {
        case .fileType: value.uppercased()
        case .folder: URL(fileURLWithPath:value).lastPathComponent
        case .modified: "Modified in the last \(value) days"
        case .tag: value
        }
    }
    package func applying(to state: SearchState) throws -> SearchState {
        let rule: SearchFileRule
        switch kind {
        case .fileType:
            rule = value.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" })
                ? .name("\\." + NSRegularExpression.escapedPattern(for:value) + "$",.regex) : .extensions([value])
        case .folder:
            let path = value == "/" ? "/" : value + "/"
            rule = .path("^" + NSRegularExpression.escapedPattern(for:path),.regex,absolute:true)
        case .tag: rule = .tags([value],.all)
        case .modified:
            var filters = SearchFilters(); try filters.setRelativeDays(Int(value) ?? 7)
            rule = .date(.init(filters))
        }
        var filter = state; filter.replaceRules(.init(files:.rule(rule),contents:nil))
        return try SearchPreset(name:title,kind:.filter,state:filter).applying(to:state)
    }
    package init(kind: Kind, value: String, count: Int) {
        self.kind = kind
        self.value = value
        self.count = count
    }

}
