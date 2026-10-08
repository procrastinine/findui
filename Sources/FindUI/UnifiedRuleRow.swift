import SearchBackend
import SwiftUI

enum RuleField: String, CaseIterable {
    case filename = "Filename", path = "Path", fileType = "File type", size = "Size", date = "Date", tags = "Finder tags"
    case contents = "Contents", near = "Near words", title = "Document title", author = "Author", member = "Member name", spotlight = "Spotlight text"
    case expression = "Name / path", anyText = "Any text"
    init(_ condition: SearchCondition) {
        switch condition {
        case .file(.name): self = .filename
        case .file(.path): self = .path
        case .file(.extensions): self = .fileType
        case .file(.size): self = .size
        case .file(.date): self = .date
        case .file(.tags): self = .tags
        case .file(.expression): self = .expression
        case .content(.literal), .content(.regex): self = .contents
        case .content(.proximity): self = .near
        case .content(.metadata(.title, _)): self = .title
        case .content(.metadata(.author, _)): self = .author
        case .content(.metadata(.member, _)): self = .member
        case .content(.documentText): self = .spotlight
        case .content(.allLines): self = .anyText
        }
    }
    func condition(text: String) -> SearchCondition {
        switch self {
        case .filename: .file(.name(text, .contains))
        case .path: .file(.path(text, .contains, absolute: false))
        case .fileType: .file(.extensions(text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)))
        case .size: .file(.size(minimum: "", maximum: ""))
        case .date: .file(.date(.init(SearchFilters(datePeriod: .week))))
        case .tags: .file(.tags([text], .all))
        case .contents: .content(.literal(text))
        case .near: .content(.proximity(.init(terms: text.split(separator: " ").map(String.init))))
        case .title: .content(.metadata(.title, text))
        case .author: .content(.metadata(.author, text))
        case .member: .content(.metadata(.member, text))
        case .spotlight: .content(.documentText(text))
        case .expression: .file(.expression(.init(text: text, syntax: .literal, exactName: false)))
        case .anyText: .content(.allLines)
        }
    }
}

struct UnifiedRuleRow: View {
    @Binding var condition: SearchCondition
    let focus: FocusState<String?>.Binding
    let focusID: String
    var availableDateFields: [SearchDateField]
    var indexedWords: Bool
    private var text: String {
        switch condition {
        case .file(.name(let value, _)), .file(.path(let value, _, _)), .content(.literal(let value)), .content(.regex(let value)),
             .content(.documentText(let value)), .content(.metadata(_, let value)): value
        case .file(.extensions(let values)), .file(.tags(let values, _)): values.joined(separator: ", ")
        case .file(.expression(let value)): value.text
        default: ""
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UtilityPicker(title: "Condition type", selection: Binding(get: { RuleField(condition) }, set: { condition = $0.condition(text: text) }),
                values: RuleField.allCases.filter { $0 != .expression && $0 != .anyText || $0 == RuleField(condition) }, label: \.rawValue)
                .frame(width: 128).accessibilityIdentifier("ruleType.\(focusID)")
            switch condition {
            case .file(let value):
                FileRuleRow(rule: Binding(get: { if case .file(let rule) = condition { rule } else { value } }, set: { condition = .file($0) }),
                    focus: focus, focusID: focusID, availableDateFields: availableDateFields, showFieldLabel: false)
            case .content(let value):
                ContentRuleRow(rule: Binding(get: { if case .content(let rule) = condition { rule } else { value } }, set: { condition = .content($0) }),
                    focus: focus, focusID: focusID, indexedWords: indexedWords, showFieldLabel: false)
            }
        }.frame(minHeight: 28)
    }
}
