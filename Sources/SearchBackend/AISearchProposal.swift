import Foundation
import CoreFoundation
import SearchCore

package struct AISearchProposal: Sendable {
    package let summary: String
    package let clarification: String?
    package let state: SearchState?
}

/// A small, explicit wire grammar instead of Swift's enum Codable layout or
/// model-generated shell. Every accepted property has one meaning in SearchState.
package enum AISearchGrammar {
    package static var schema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "properties": properties, "required": properties.keys.sorted()]
        }
        func values(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        func nullable(_ value: [String: Any]) -> [String: Any] { ["anyOf": [value, ["type": "null"]]] }
        func node(_ kind: String, _ properties: [String: Any] = [:]) -> [String: Any] {
            object(properties.merging(["kind": values([kind])]) { _, rhs in rhs })
        }
        let text: [String: Any] = ["type": "string"], boolean: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": "integer"]
        let strings: [String: Any] = ["type": "array", "items": text]
        let matching = values(PatternMatching.allCases.map(\.rawValue))
        let groups = ["all", "any", "none"].map { node($0, ["children": ["type": "array", "items": ["$ref": "#/$defs/node"]]]) }
        let leaves = [
            node("name", ["text": text, "matching": matching]),
            node("path", ["text": text, "matching": matching, "absolute": boolean]),
            node("extensions", ["values": strings]),
            node("tags", ["values": strings, "matching": values(TagMatch.allCases.map(\.rawValue))]),
            node("size", ["minimum": text, "maximum": text]),
            node("date", ["field": values(SearchDateField.allCases.map(\.rawValue)),
                "period": values(SearchDatePeriod.allCases.filter { $0 != .any }.map(\.rawValue)),
                "days": nullable(integer), "calendarAge": nullable(text), "from": nullable(text), "through": nullable(text)]),
            node("literal", ["text": text]), node("regex", ["text": text]), node("spotlightText", ["text": text]), node("allLines"),
            node("proximity", ["terms": strings, "distance": integer, "ordered": boolean]),
            node("metadata", ["field": values(DocumentMetadataField.allCases.map(\.rawValue)), "text": text])
        ]
        var options = Dictionary(uniqueKeysWithValues: booleanOptions.map { ($0, nullable(boolean)) })
        options["kind"] = nullable(values(["files", "folders", "everything"]))
        options["maximumDepth"] = nullable(integer)
        options["excludedFolders"] = nullable(strings)
        options["encoding"] = nullable(text)
        options["typoTolerance"] = nullable(integer)
        options["source"] = nullable(values(["live", "spotlight", "snapshot"]))
        options["wordLanguage"] = nullable(values(WordLanguage.allCases.map(\.rawValue)))
        var root = object(["version": ["type": "integer", "enum": [1]], "summary": text,
            "clarification": nullable(text), "rules": nullable(["$ref": "#/$defs/node"]),
            "contentUnit": values(SearchContentUnit.allCases.map(\.rawValue)), "options": object(options)])
        root["$defs"] = ["node": ["anyOf": groups + leaves]]
        return root
    }

    private static let booleanOptions = ["hidden", "ignored", "symlinks", "packages", "fileCaseSensitive", "contentCaseSensitive",
        "wholeWords", "filesOnly", "multiline", "documents", "archives", "media", "customReaders", "useContentIndex", "indexedWords", "stemWords"]

    package static func decode(_ data: Data, relativeTo original: SearchState, now: Date = .now) throws -> AISearchProposal {
        guard data.count <= 256 * 1024 else { throw invalid("The response exceeds 256 KB.") }
        try AISearchJSON.validateObjectKeys(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("Expected a JSON object.") }
        try keys(object, ["version", "summary", "clarification", "rules", "contentUnit", "options"])
        guard try integer(object, "version") == 1 else { throw invalid("Unsupported response version.") }
        let summary = try string(object, "summary")
        guard summary.count <= 2000 else { throw invalid("The summary is too long.") }
        let clarification = try optionalString(object, "clarification")
        guard let unit = SearchContentUnit(rawValue: try string(object, "contentUnit")) else { throw invalid("Unknown content unit.") }
        guard let options = object["options"] as? [String: Any] else { throw invalid("Missing options.") }
        let optionKeys = booleanOptions + ["kind", "maximumDepth", "excludedFolders", "encoding", "typoTolerance", "source", "wordLanguage"]
        try keys(options, optionKeys)
        if let clarification {
            guard !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, clarification.count <= 2000, object["rules"] is NSNull,
                  options.values.allSatisfy({ $0 is NSNull }) else {
                throw invalid("A clarification cannot include a runnable search or changed options.")
            }
            return .init(summary: summary, clarification: clarification, state: nil)
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Describe the search in a short summary.") }
        guard let tree = object["rules"] as? [String: Any] else { throw invalid("The response contains no search rules.") }
        var count = 0
        let expression = try decodeNode(tree, depth: 0, count: &count, now: now)
        var rules = SearchRuleSet(expression: expression, contentUnit: unit)
        try rules.expression.validate(allowEmptyRoot: true) { condition in
            switch condition { case .file(let rule): try rule.validate(now: now); case .content(let rule): try rule.validate() }
        }
        // An explicit match-all needs a visible condition: blank controls mean
        // browsing the current directory in the GUI, not a recursive search.
        if rules.isEmpty { rules.expression = .rule(.file(.name("*", .glob))) }
        var state = original
        var shared = SearchSharedOptions(state.refinements)
        // The proposal replaces conditions completely; traversal and expensive
        // reader choices remain unchanged unless the user explicitly asks for them.
        for key in booleanOptions {
            guard let value = try optionalBool(options, key) else { continue }
            switch key {
            case "hidden": state.includeHidden = value
            case "ignored": state.traversal.includeIgnored = value
            case "symlinks": state.traversal.followSymlinks = value
            case "packages": state.traversal.includePackageContents = value
            case "fileCaseSensitive": shared.fileCaseSensitive = value
            case "contentCaseSensitive": state.caseSensitive = value
            case "wholeWords": shared.wholeWords = value
            case "filesOnly": shared.matchingFilesOnly = value
            case "multiline": shared.multiline = value
            case "useContentIndex": shared.useContentIndex = value
            case "indexedWords": shared.wordSearch = value
            case "stemWords": shared.stemWords = value
            default:
                var extraction = shared.extraction ?? .init()
                if shared.extraction == nil { extraction.documents = false }
                switch key { case "documents": extraction.documents = value; case "archives": extraction.archives = value
                case "media": extraction.media = value; case "customReaders": extraction.customReaders = value; default: break }
                shared.extraction = extraction
            }
        }
        if let extraction = shared.extraction, !extraction.documents && !extraction.archives && !extraction.media && !extraction.customReaders { shared.extraction = nil }
        if let kind = try optionalString(options, "kind") {
            guard let mode = SearchMode(rawValue: kind), mode != .contents else { throw invalid("Unknown file kind.") }
            guard !rules.hasContents || mode == .files else { throw invalid("Content conditions can only search files.") }
            state.mode = mode
        }
        if let source = try optionalString(options, "source") {
            switch source {
            case "live": state.useIndex = false; shared.source = .filesystem
            case "spotlight": state.useIndex = false; shared.source = .spotlight
            case "snapshot": guard original.useIndex else { throw invalid("Select a saved snapshot in FindUI before requesting a snapshot search.") }
            default: throw invalid("Unknown source.")
            }
        }
        if !(options["maximumDepth"] is NSNull) {
            let depth = try integer(options, "maximumDepth")
            guard depth == -1 || (1...10000).contains(depth) else { throw invalid("Invalid maximum depth.") }
            state.traversal.maximumDepth = depth == -1 ? nil : depth
        }
        if !(options["excludedFolders"] is NSNull) { state.traversal.excludedFolders = try strings(options, "excludedFolders") }
        if let encoding = try optionalString(options, "encoding") { shared.textEncoding = encoding.isEmpty ? nil : encoding }
        if !(options["typoTolerance"] is NSNull) { shared.typoTolerance = try integer(options, "typoTolerance") }
        if let language = try optionalString(options, "wordLanguage") {
            guard let value = WordLanguage(rawValue: language) else { throw invalid("Unknown word language.") }
            shared.wordLanguage = value
        }
        state.criteria = .grouped(rules, options: shared)
        state.mode = rules.hasContents ? .contents : (state.mode == .contents ? .files : state.mode)
        state.sourceCommand = nil
        state.nativeCommand = nil
        // Unlike an interactive mode switch, model output must not silently
        // replace its selected source. Incompatible choices fail validation so
        // the proposal can explicitly request and explain the required source.
        // A snapshot's actual file is owned by the caller; normalization only
        // needs a source identity here to validate which predicates it supports.
        var snapshot = QuerySource(); snapshot.kind = .snapshot; snapshot.path = "/selected-snapshot"
        let source = state.useIndex ? snapshot : nil
        _ = try SearchRequest(state: state, referenceDate: now).normalizedQuery(source: source)
        // Presentation normalization belongs to the backend, so generated
        // states behave identically in the app, CLI and saved searches.
        if let compact = state.compactProjection {
            _ = try SearchRequest(state: compact, referenceDate: now).normalizedQuery(source: source)
            state = compact
        }
        return .init(summary: summary, clarification: nil, state: state)
    }

    private static func decodeNode(_ object: [String: Any], depth: Int, count: inout Int, now: Date) throws -> SearchRuleTree<SearchCondition> {
        count += 1
        guard depth <= 8, count <= 64 else { throw invalid("Use at most 64 conditions and 8 levels of groups.") }
        let kind = try string(object, "kind")
        func check(_ fields: [String]) throws { try keys(object, ["kind"] + fields) }
        func text() throws -> String { try string(object, "text") }
        func matching() throws -> PatternMatching {
            guard let value = PatternMatching(rawValue: try string(object, "matching")) else { throw invalid("Unknown matching mode.") }
            return value
        }
        switch kind {
        case "all", "any", "none":
            try check(["children"])
            guard let children = object["children"] as? [[String: Any]] else { throw invalid("Group children must be rule objects.") }
            let nodes = try children.map { try decodeNode($0, depth: depth + 1, count: &count, now: now) }
            return kind == "all" ? .all(nodes) : kind == "any" ? .any(nodes) : .none(nodes)
        case "name": try check(["text", "matching"]); return .rule(.file(.name(try text(), try matching())))
        case "path": try check(["text", "matching", "absolute"]); return .rule(.file(.path(try text(), try matching(), absolute: try boolean(object, "absolute"))))
        case "extensions": try check(["values"]); return .rule(.file(.extensions(try strings(object, "values"))))
        case "tags":
            try check(["values", "matching"])
            guard let value = TagMatch(rawValue: try string(object, "matching")) else { throw invalid("Unknown tag matching mode.") }
            return .rule(.file(.tags(try strings(object, "values"), value)))
        case "size": try check(["minimum", "maximum"]); return .rule(.file(.size(minimum: try string(object, "minimum"), maximum: try string(object, "maximum"))))
        case "date":
            try check(["field", "period", "days", "calendarAge", "from", "through"])
            guard let field = SearchDateField(rawValue: try string(object, "field")),
                  let period = SearchDatePeriod(rawValue: try string(object, "period")), period != .any else { throw invalid("Unknown date condition.") }
            var filters = SearchFilters(); filters.dateField = field; filters.datePeriod = period
            let dateKeys = ["days", "calendarAge", "from", "through"]
            let applicable: Set<String> = switch period {
            case .recentDays: ["days"]
            case .recentCalendar: ["calendarAge"]
            case .before, .after: ["from"]
            case .custom: ["from", "through"]
            default: []
            }
            guard dateKeys.allSatisfy({ applicable.contains($0) || object[$0] is NSNull }) else {
                throw invalid("This date period has unrelated bounds. Set unused date fields to null.")
            }
            if !(object["days"] is NSNull) { filters.relativeDays = try integer(object, "days") }
            filters.calendarAge = try optionalString(object, "calendarAge")
            if let value = try optionalString(object, "from") { filters.dateFrom = try date(value) }
            else if [.before, .after, .custom].contains(period) { throw invalid("This date condition needs from (YYYY-MM-DD).") }
            if let value = try optionalString(object, "through") { filters.dateThrough = try date(value) }
            else if period == .custom { throw invalid("A date range needs through (YYYY-MM-DD).") }
            if period == .recentDays && filters.relativeDays == nil { throw invalid("Last N days needs days.") }
            if period == .recentCalendar && filters.calendarAge == nil { throw invalid("Calendar duration needs calendarAge.") }
            return .rule(.file(.date(SearchDateCondition(filters))))
        case "literal", "regex", "spotlightText":
            try check(["text"])
            return .rule(.content(kind == "literal" ? .literal(try text()) : kind == "regex" ? .regex(try text()) : .documentText(try text())))
        case "allLines": try check([]); return .rule(.content(.allLines))
        case "proximity":
            try check(["terms", "distance", "ordered"])
            return .rule(.content(.proximity(.init(terms: try strings(object, "terms"), distance: try integer(object, "distance"), ordered: try boolean(object, "ordered")))))
        case "metadata":
            try check(["field", "text"])
            guard let field = DocumentMetadataField(rawValue: try string(object, "field")) else { throw invalid("Unknown metadata field.") }
            return .rule(.content(.metadata(field, try text())))
        default: throw invalid("Unsupported condition: \(kind.prefix(40)).")
        }
    }
    private static func date(_ text: String) throws -> Date {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard text.count == 10, let date = formatter.date(from: text), formatter.string(from: date) == text else { throw invalid("Use a valid date as YYYY-MM-DD.") }
        return date
    }
    private static func keys(_ object: [String: Any], _ allowed: [String]) throws {
        guard Set(object.keys) == Set(allowed) else { throw invalid("Missing or unsupported fields: \(Set(object.keys).symmetricDifference(allowed).sorted().joined(separator: ", ")).") }
    }
    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let text = object[key] as? String, text.count <= 16000, !text.contains("\0") else { throw invalid("Invalid text for \(key).") }; return text
    }
    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? { object[key] is NSNull ? nil : try string(object, key) }
    private static func strings(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let values = object[key] as? [String], values.count <= 100, values.allSatisfy({ $0.count <= 16000 && !$0.contains("\0") }) else { throw invalid("Invalid list for \(key).") }; return values
    }
    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) <= Double(Int32.max), number.doubleValue.rounded() == number.doubleValue else { throw invalid("Invalid integer for \(key).") }
        return number.intValue
    }
    private static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("Invalid Boolean for \(key).") }; return number.boolValue
    }
    private static func optionalBool(_ object: [String: Any], _ key: String) throws -> Bool? { object[key] is NSNull ? nil : try boolean(object, key) }
    private static func invalid(_ message: String) -> AISearchError { .message("Invalid AI search: " + message) }
}
