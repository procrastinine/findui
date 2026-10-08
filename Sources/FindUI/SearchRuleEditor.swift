import SearchBackend
import SwiftUI

private struct RuleListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 28
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum RuleJoin: String, CaseIterable {
    case all = "All (AND)", any = "Any (OR)", none = "None (NOT)"
}

/// This editor holds only bindings into SearchState. A leaf or group is never
/// copied into a second draft, and removing a row removes that exact predicate.
private struct RuleTreeEditor<Rule: Codable & Hashable & Sendable, Row: View>: View {
    @Binding var tree: SearchRuleTree<Rule>
    let choices: [(String, Rule)]
    let row: (Binding<Rule>, String) -> Row
    let depth: Int
    let path: String
    let title: String?
    let extra: AnyView?
    let scrollHeight: CGFloat?
    @State private var measuredHeight: CGFloat = 28

    init(tree: Binding<SearchRuleTree<Rule>>, choices: [(String, Rule)], depth: Int = 0, path: String,
         title: String? = nil, extra: AnyView? = nil, scrollHeight: CGFloat? = nil,
         @ViewBuilder row: @escaping (Binding<Rule>, String) -> Row) {
        _tree = tree; self.choices = choices; self.row = row; self.depth = depth
        self.path = path
        self.title = title; self.extra = extra; self.scrollHeight = scrollHeight
    }

    private var children: [SearchRuleTree<Rule>] {
        switch tree {
        case .rule: [tree]
        case .all(let values), .any(let values), .none(let values): values
        }
    }
    private var join: RuleJoin {
        switch tree { case .all, .rule: .all; case .any: .any; case .none: .none }
    }
    private func replace(_ values: [SearchRuleTree<Rule>], join: RuleJoin? = nil) {
        // Removing the final top-level row clears the section. Empty nested
        // groups remain incomplete so an edit cannot silently broaden a query.
        if depth == 0 && values.isEmpty { tree = .all([]); return }
        switch join ?? self.join { case .all: tree = .all(values); case .any: tree = .any(values); case .none: tree = .none(values) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let title { Text(title).font(.headline).frame(width: 66, alignment: .leading) }
                Text("Match")
                UtilityPicker(title: "Combine conditions", selection: Binding(
                    get: { join }, set: { replace(children, join: $0) }), values: RuleJoin.allCases, label: \.rawValue)
                    .frame(width: 112)
                    .disabled(children.isEmpty)
                    .accessibilityIdentifier("ruleJoin.\(path)")
                Text("of these conditions").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let extra { extra }
                Menu("Add") {
                    ForEach(choices.indices, id: \.self) { index in
                        Button(choices[index].0) { replace(children + [.rule(choices[index].1)]) }
                    }
                    Divider()
                    Button("Any group (OR)") { replace(children + [.any([.rule(choices[0].1)])]) }.disabled(depth >= 7)
                    Button("All group (AND)") { replace(children + [.all([.rule(choices[0].1)])]) }.disabled(depth >= 7)
                    Button("Exclude group (NOT)") { replace(children + [.none([.rule(choices[0].1)])]) }.disabled(depth >= 7)
                }.fixedSize().accessibilityIdentifier("addRule.\(path)")
            }
            if let scrollHeight {
                ScrollView {
                    childList.padding(.trailing, 4).padding(.vertical, 3)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: RuleListHeightKey.self, value: geometry.size.height)
                        })
                }
                .onPreferenceChange(RuleListHeightKey.self) { measuredHeight = $0 }
                .frame(height: min(scrollHeight, max(28, measuredHeight)))
                .scrollIndicators(.visible)
            } else { childList }
        }
        .padding(depth == 0 ? 0 : 10)
        .background {
            if depth > 0 { RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)) }
        }
        .overlay {
            if depth > 0 { RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary.opacity(0.25)) }
        }
    }

    private var childList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if children.isEmpty {
                Text(depth == 0 && join == .all ? "No conditions" : "Add a condition or remove this group")
                    .foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(children.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    child(index)
                        .contextMenu {
                            Button("Wrap in All group (AND)") { wrap(index, in: .all) }.disabled(depth >= 7)
                            Button("Wrap in Any group (OR)") { wrap(index, in: .any) }.disabled(depth >= 7)
                            Button("Negate this condition (NOT)") { wrap(index, in: .none) }.disabled(depth >= 7)
                            Divider()
                            Button("Move up") { move(index, by: -1) }.disabled(index == 0)
                            Button("Move down") { move(index, by: 1) }.disabled(index == children.count - 1)
                        }
                    Button {
                        var values = children
                        guard values.indices.contains(index) else { return }
                        values.remove(at: index); replace(values)
                    } label: {
                        Image(systemName: "minus").font(.system(size: 12, weight: .medium))
                            .frame(width: 14, height: 18)
                    }
                        .help("Remove this condition or group").accessibilityLabel("Remove condition")
                        .accessibilityIdentifier("removeRule.\(path).\(index)")
                        .controlSize(.regular)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func wrap(_ index: Int, in operation: RuleJoin) {
        var values = children; guard values.indices.contains(index) else { return }
        let node = values[index]
        switch operation { case .all: values[index] = .all([node]); case .any: values[index] = .any([node]); case .none: values[index] = .none([node]) }
        replace(values)
    }
    private func move(_ index: Int, by offset: Int) {
        var values = children; guard values.indices.contains(index), values.indices.contains(index + offset) else { return }
        values.swapAt(index, index + offset); replace(values)
    }

    private func child(_ index: Int) -> AnyView {
        let binding = Binding<SearchRuleTree<Rule>>(
            get: { children.indices.contains(index) ? children[index] : .rule(choices[0].1) },
            set: { value in
                var values = children
                guard values.indices.contains(index) else { return }
                values[index] = value; replace(values)
            })
        if case .rule = binding.wrappedValue {
            return AnyView(row(Binding(get: {
                if case .rule(let value) = binding.wrappedValue { return value }
                return choices[0].1
            }, set: { binding.wrappedValue = .rule($0) }), "\(path).\(index)").frame(maxWidth: .infinity, alignment: .leading))
        }
        return AnyView(RuleTreeEditor(tree: binding, choices: choices, depth: depth + 1, path: "\(path).\(index)", row: row))
    }
}

struct SearchRuleEditor: View {
    @ObservedObject var viewModel: SearchViewModel
    var focusRequest = 0
    @FocusState private var focusedRule: String?
    private var rules: SearchRuleSet { viewModel.searchRules ?? .init() }
    private var tree: Binding<SearchRuleTree<SearchCondition>> {
        Binding(get: { rules.expression }, set: { expression in
            var value = rules; value.expression = expression
            if !value.hasContents { value.contentUnit = .line }
            else if value.contentLeaves.allSatisfy(\.isDocumentText) { value.contentUnit = .file }
            else if viewModel.refinements.wordSearch == true && value.contentUnit == .line { value.contentUnit = .document }
            viewModel.updateRules(value)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RuleTreeEditor(tree: tree, choices: RuleField.allCases.filter { $0 != .expression && $0 != .anyText }.map {
                ($0.rawValue, $0.condition(text: ""))
            }, path: "rules", scrollHeight: 310) { binding, path in
                UnifiedRuleRow(condition: binding, focus: $focusedRule, focusID: path,
                    availableDateFields: viewModel.availableDateFields,
                    indexedWords: viewModel.refinements.wordSearch == true)
            }
            HStack(spacing: 12) {
                Text("Match case:").foregroundStyle(.secondary)
                Toggle("File names", isOn: Binding(
                    get: { viewModel.refinements.fileCaseSensitive ?? viewModel.caseSensitive },
                    set: { viewModel.refinements.fileCaseSensitive = $0 }))
                if rules.hasContents {
                    Toggle("Contents", isOn: Binding(get: { viewModel.caseSensitive }, set: {
                        viewModel.refinements.fileCaseSensitive = viewModel.refinements.fileCaseSensitive ?? viewModel.caseSensitive
                        viewModel.caseSensitive = $0
                    })).disabled(viewModel.refinements.wordSearch == true)
                }
                Spacer(minLength: 0)
            }
            if rules.hasContents {
                HStack(spacing: 8) {
                    UtilityPicker(title: "Content search engine", selection: $viewModel.contentTextEngine,
                        values: viewModel.contentTextEngineChoices, label: \.title)
                        .frame(width: 145).accessibilityIdentifier("ruleContentEngine")
                    Text("Text matches").foregroundStyle(.secondary)
                    UtilityPicker(title: "Content matching unit", selection: Binding(
                        get: { rules.contentUnit }, set: { var value = rules; value.contentUnit = $0; viewModel.updateRules(value) }),
                        values: viewModel.refinements.wordSearch == true ? [.document, .file] : SearchContentUnit.allCases,
                        label: { $0 == .line && viewModel.refinements.multiline == true ? "Same matching block" : $0.title })
                        .frame(width: 205)
                    Spacer(minLength: 0)
                    if rules.separated == nil || rules.contentUnit == .file {
                        Text("Returns files").foregroundStyle(.secondary).help("Each file is returned once when the full expression matches. File-only branches also match empty files.")
                    }
                }
            }
            if let error = viewModel.ruleValidationMessage { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.25)))
        .textFieldStyle(.roundedBorder).nativeUtilityButtonStyle().toggleStyle(.checkbox)
        .menuStyle(NativeUtilityMenuStyle())
        .onSubmit { viewModel.scheduleSearch(immediate: true) }
        .onChange(of: focusRequest) { _, _ in focusedRule = firstField(rules.expression, path: "rules") }
        .accessibilityElement(children: .contain).accessibilityIdentifier("searchRuleEditor")
    }
    private func firstField(_ node: SearchRuleTree<SearchCondition>, path: String) -> String? {
        switch node {
        case .rule(.content(.allLines)): return nil
        case .rule: return path == "rules" ? "rules.0" : path
        case .all(let children), .any(let children), .none(let children):
            return children.enumerated().lazy.compactMap { firstField($0.element, path: "\(path).\($0.offset)") }.first
        }
    }
}

struct FileRuleRow: View {
    @Binding var rule: SearchFileRule
    let focus: FocusState<String?>.Binding
    let focusID: String
    var availableDateFields = SearchDateField.allCases
    var showFieldLabel = true
    var body: some View {
        HStack(spacing: 8) {
            switch rule {
            case .name, .path:
                pattern
            case .extensions(let values):
                if showFieldLabel { Text("File type").frame(width: 76, alignment: .leading) }
                TextField("pdf, png, swift", text: Binding(get: { values.joined(separator: ", ") },
                    set: { rule = .extensions($0.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)) }))
                    .accessibilityLabel("File extensions")
                    .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                Menu("Add type") {
                    ForEach(SearchFileTypes.groups) { type in
                        Button(type.title) { rule = .extensions(Array(Set(values + type.extensions)).sorted()) }
                            .help(type.extensions.joined(separator: ", "))
                    }
                }.fixedSize()
            case .size(let minimum, let maximum):
                if showFieldLabel { Text("Size").frame(width: 76, alignment: .leading) }
                TextField("Minimum", text: Binding(get: { minimum }, set: { rule = .size(minimum: $0, maximum: maximum) }))
                    .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                Text("to").foregroundStyle(.secondary)
                TextField("Maximum", text: Binding(get: { maximum }, set: { rule = .size(minimum: minimum, maximum: $0) }))
            case .date(let value):
                date(value)
            case .tags(let values, let matching):
                if showFieldLabel { Text("Finder tags").frame(width: 76, alignment: .leading) }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(values.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                        TextField("Tag name", text: Binding(get: { values[index] }, set: {
                            var next = values; next[index] = $0; rule = .tags(next, matching)
                        }))
                        .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID).tag.\(index)")
                        if values.count > 1 {
                            Button { var next = values; next.remove(at: index); rule = .tags(next, matching) } label: { Image(systemName: "minus").frame(width: 14, height: 18) }
                                .help("Remove this tag").accessibilityLabel("Remove tag \(values[index])")
                        }
                        }
                    }
                }
                UtilityPicker(title: "Match tags", selection: Binding(get: { matching }, set: { rule = .tags(values, $0) }),
                              values: TagMatch.allCases, label: \.title).frame(width: 96)
                Button { rule = .tags(values + [""], matching) } label: { Image(systemName: "plus").frame(width: 14, height: 18) }
                    .help("Add a tag to this condition")
            case .expression(let value):
                if showFieldLabel { Text("Name / path").frame(width: 76, alignment: .leading) }
                TextField("File expression", text: Binding(get: { value.text }, set: {
                    var next = value; next.text = $0; rule = .expression(next)
                }))
                .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                Text(value.syntax.title + (value.exactName ? " · exact" : "")).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 28)
    }

    private var pattern: some View {
        let text: String, matching: PatternMatching, absolute: Bool, isName: Bool
        switch rule {
        case .name(let value, let style): text = value; matching = style; absolute = false; isName = true
        case .path(let value, let style, let full): text = value; matching = style; absolute = full; isName = false
        default: text = ""; matching = .contains; absolute = false; isName = true
        }
        func replace(_ value: String, _ style: PatternMatching, _ full: Bool) {
            rule = isName ? .name(value, style) : .path(value, style, absolute: full)
        }
        return HStack(spacing: 8) {
            if showFieldLabel { Text(isName ? "Filename" : "Path").frame(width: 76, alignment: .leading) }
            TextField(matching == .glob ? "*.swift" : "Search text", text: Binding(get: { text }, set: { replace($0, matching, absolute) }))
                .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
            UtilityPicker(title: "Pattern matching", selection: Binding(get: { matching }, set: { replace(text, $0, absolute) }),
                          values: PatternMatching.allCases, label: \.title).frame(width: 112)
            if !isName {
                Toggle("Full path only", isOn: Binding(get: { absolute }, set: { replace(text, matching, $0) }))
            }
        }
    }

    private func date(_ value: SearchDateCondition) -> some View {
        func field<T>(_ key: WritableKeyPath<SearchDateCondition, T>) -> Binding<T> {
            Binding(get: { value[keyPath: key] }, set: { var next = value; next[keyPath: key] = $0; rule = .date(next) })
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if showFieldLabel { Text("Date").frame(width: 76, alignment: .leading) }
                UtilityPicker(title: "Date field", selection: field(\.field),
                              values: SearchDateField.allCases.filter { availableDateFields.contains($0) || $0 == value.field }, label: \.title)
                    .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                UtilityPicker(title: "Date period", selection: field(\.period),
                              values: SearchDatePeriod.allCases.filter { $0 != .any }, label: \.title)
                if value.period == .recentDays {
                    TextField("Days", value: Binding(get: { value.days ?? 7 }, set: {
                        var next = value; next.days = $0; rule = .date(next)
                    }), format: .number.grouping(.never)).frame(width: 60)
                    Text("days")
                }
            }
            if value.period == .recentCalendar {
                HStack {
                    Text("Last").frame(width: 76, alignment: .leading)
                    TextField("5 months and 4 days", text: Binding(
                        get: { value.calendarAge ?? "1 month" }, set: {
                            var next = value; next.calendarAge = $0; rule = .date(next)
                        }))
                        .accessibilityLabel("Calendar duration")
                        .accessibilityIdentifier("calendarDuration.rule.\(focusID)")
                        .help("Counts calendar months, then calendar days, back from the search time.")
                }
            }
            if [.custom, .before, .after].contains(value.period) {
                HStack {
                    DatePicker(value.period == .custom ? "From" : "Date", selection: field(\.from), displayedComponents: .date)
                    if value.period == .custom { DatePicker("Through", selection: field(\.through), displayedComponents: .date) }
                }
            }
        }
    }
}

struct ContentRuleRow: View {
    @Binding var rule: SearchContentRule
    let focus: FocusState<String?>.Binding
    let focusID: String
    var indexedWords = false
    var showFieldLabel = true
    private var text: String {
        switch rule {
        case .allLines: ""
        case .literal(let value), .regex(let value), .documentText(let value), .metadata(_, let value): value
        case .proximity(let value): value.terms.joined(separator: " ")
        }
    }
    private var matching: ContentMatchingChoice {
        switch rule { case .literal, .allLines, .proximity, .metadata: .literal; case .regex: .regex; case .documentText: .documentText }
    }
    private func replace(_ text: String, _ style: ContentMatchingChoice) {
        switch style { case .literal, .expression, .indexedWords: rule = .literal(text); case .regex: rule = .regex(text); case .documentText: rule = .documentText(text) }
    }
    var body: some View {
        HStack(spacing: 8) {
            if case .allLines = rule { Text(indexedWords ? "Any indexed document" : "Any text line").foregroundStyle(.secondary); Spacer() }
            else if case .metadata(let field, let value) = rule {
                if showFieldLabel { UtilityPicker(title: "Document field", selection: Binding(get: { field }, set: { rule = .metadata($0, value) }),
                              values: DocumentMetadataField.allCases, label: \.title).frame(width: 140) }
                TextField(indexedWords ? "Words or phrase" : "Contains text", text: Binding(get: { value }, set: { rule = .metadata(field, $0) }))
                    .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                    .help(field == .member ? "ZIP, JAR and wheel member names need no expansion. Enable archive expansion to search other formats, nested archives or member contents." : "Enable Search inside documents in Scope & Options.")
            }
            else if case .proximity(let value) = rule {
                if showFieldLabel { Text("Near words") }
                TextField("Two or more words", text: Binding(get: { value.terms.joined(separator: " ") }, set: {
                    var next = value; next.terms = $0.components(separatedBy: .whitespaces); rule = .proximity(next)
                })).focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                Text("within")
                TextField("10", value: Binding(get: { value.distance }, set: {
                    var next = value; next.distance = $0; rule = .proximity(next)
                }), format: .number.grouping(.never)).frame(width: 48)
                Text("extra words").foregroundStyle(.secondary)
                Toggle("In order", isOn: Binding(get: { value.ordered }, set: {
                    var next = value; next.ordered = $0; rule = .proximity(next)
                }))
            }
            else {
                TextField("Text inside files", text: Binding(get: { text }, set: { replace($0, matching) }))
                    .focused(focus, equals: focusID).accessibilityIdentifier("rule.\(focusID)")
                if !indexedWords && (showFieldLabel || matching != .documentText) {
                UtilityPicker(title: "Content matching", selection: Binding(get: { matching }, set: { replace(text, $0) }),
                    values: showFieldLabel ? [.literal, .regex, .documentText] : [.literal, .regex], label: \.title).frame(width: 130)
                Menu {
                    ForEach(SearchPatternPresets.all) { preset in
                        Button("\(preset.title) · \(preset.example)") { rule = .regex(preset.pattern) }.help(preset.detail)
                    }
                } label: { Image(systemName: "text.magnifyingglass") }
                    .help("Insert a regex example").accessibilityLabel("Pattern examples")
                }
            }
        }.frame(minHeight: 28)
    }
}
