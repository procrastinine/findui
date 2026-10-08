import SearchBackend
#if canImport(FindUI)
@testable import FindUI
#endif
import Foundation

/// Sparse, versioned model/template output mapped to the same controls as manual
/// searches. Values are data; the pipeline compiler alone produces shell code.
struct SearchIntent: Codable {
    private static let selectedTypeAliases = CodingUserInfoKey(rawValue: "FindUI.selectedTypeAliases")!

    /// Model output contains selected source values. Ordinary JSON/history
    /// decoding remains literal, so an extension named "python" stays python.
    static func decodeModelOutput(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[selectedTypeAliases] = true
        return try decoder.decode(Self.self, from: data)
    }

    let mode: String
    var name: String?
    var nameMatching: PatternMatching?
    var path: String?
    var pathMatching: PatternMatching?
    var content: String?
    var contentMatching: SearchSyntax?
    var contentSource: ContentSearchSource?
    var roots: [String]?
    var extensions: [String]?
    var minimum: Quantity?
    var maximum: Quantity?
    var date: String?
    var dateField: SearchDateField?
    var relativeDays: Int?
    var calendarAge: String?
    var calendarBoundary: String?
    var dateFrom: String?
    var dateThrough: String?
    var calendarPeriod: String?
    var source: LiveSearchSource?
    var fileCase: String?
    var caseSensitive: Bool?
    var hidden: Bool?
    var ignored: Bool?
    var followSymlinks: Bool?
    var wholeWords: Bool?
    var filesOnly: Bool?
    var minDepth: Int?
    var maxDepth: Int?
    var contextLines: Int?
    var excludedFolders: [String]?
    var excludedFiles: [String]?
    var excludedExtensions: [String]?
    var files: SearchIntentTree?
    var contents: SearchIntentTree?
    var contentUnit: SearchContentUnit?

    struct Quantity: Codable {
        let text: String
        init(text: String) { self.text = text }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer(); try value.encode(text)
        }
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let bytes = try? value.decode(Int64.self) { text = "\(bytes) B" }
            else if let source = try? value.decode(String.self) { text = source }
            else {
                let object = try decoder.container(keyedBy: InputKey.self)
                guard Set(object.allKeys.map(\.stringValue)) == ["value", "unit"] else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A quantity needs exactly a value and a unit."))
                }
                let key = InputKey(stringValue: "value")!
                let number: String
                if let string = try? object.decode(String.self, forKey: key) { number = string }
                else { number = NSDecimalNumber(decimal: try object.decode(Decimal.self, forKey: key)).stringValue }
                text = number + " " + (try object.decode(String.self, forKey: InputKey(stringValue: "unit")!))
            }
        }
    }

    private struct InputKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws { try self.init(from: decoder, defaultMode: nil) }

    init(from decoder: Decoder, defaultMode: String?) throws {
        let raw = try decoder.container(keyedBy: InputKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(forKey: unknown, in: raw,
                debugDescription: "Unknown search field: \(unknown.stringValue)")
        }
        let value = try decoder.container(keyedBy: CodingKeys.self)
        if let defaultMode { mode = defaultMode }
        else { mode = try value.decode(String.self, forKey: .mode) }
        name = try value.decodeIfPresent(String.self, forKey: .name)
        nameMatching = try value.decodeIfPresent(PatternMatching.self, forKey: .nameMatching)
        path = try value.decodeIfPresent(String.self, forKey: .path)
        pathMatching = try value.decodeIfPresent(PatternMatching.self, forKey: .pathMatching)
        content = try value.decodeIfPresent(String.self, forKey: .content)
        if try value.decodeIfPresent(String.self, forKey: .contentMatching) == "preset" {
            guard let selected = content, let preset = SearchPatternPresets.named(selected) else {
                throw DecodingError.dataCorruptedError(forKey: .content, in: value, debugDescription: "Unknown named content pattern")
            }
            content = preset.pattern; contentMatching = .regex
        } else { contentMatching = try value.decodeIfPresent(SearchSyntax.self, forKey: .contentMatching) }
        contentSource = try value.decodeIfPresent(ContentSearchSource.self, forKey: .contentSource)
        roots = try value.decodeIfPresent([String].self, forKey: .roots)
        if decoder.userInfo[Self.selectedTypeAliases] as? Bool == true, let roots {
            self.roots = Array(Set(roots)).sorted()
        }
        extensions = try value.decodeIfPresent([String].self, forKey: .extensions)
        if decoder.userInfo[Self.selectedTypeAliases] as? Bool == true, let extensions {
            self.extensions = Array(Set(try extensions.flatMap(SearchFileTypes.selectedExtensions))).sorted()
        }
        minimum = try value.decodeIfPresent(Quantity.self, forKey: .minimum)
        maximum = try value.decodeIfPresent(Quantity.self, forKey: .maximum)
        date = try value.decodeIfPresent(String.self, forKey: .date)
        dateField = try value.decodeIfPresent(SearchDateField.self, forKey: .dateField)
        if let days = try? value.decode(String.self, forKey: .relativeDays) {
            relativeDays = try SearchValueUnits.relativeDays(days)
        } else { relativeDays = try value.decodeIfPresent(Int.self, forKey: .relativeDays) }
        dateFrom = try value.decodeIfPresent(String.self, forKey: .dateFrom)
        dateThrough = try value.decodeIfPresent(String.self, forKey: .dateThrough)
        if let dateFrom, !dateFrom.isEmpty { self.dateFrom = try SearchValueUnits.calendarDay(dateFrom) }
        if let dateThrough, !dateThrough.isEmpty { self.dateThrough = try SearchValueUnits.calendarDay(dateThrough) }
        calendarPeriod = try value.decodeIfPresent(String.self, forKey: .calendarPeriod)
        if let calendarPeriod {
            guard date == nil, dateFrom == nil, dateThrough == nil else {
                throw DecodingError.dataCorruptedError(forKey: .calendarPeriod, in: value, debugDescription: "Duplicate date specification")
            }
            let interval = try SearchValueUnits.calendarRange(calendarPeriod)
            date = "custom"; dateFrom = interval.from; dateThrough = interval.through
            self.calendarPeriod = nil
        }
        calendarAge = try value.decodeIfPresent(String.self, forKey: .calendarAge)
        if let calendarAge {
            guard date == nil || date == "recentCalendar", relativeDays == nil,
                  dateFrom?.isEmpty != false, dateThrough?.isEmpty != false, calendarPeriod == nil else {
                throw DecodingError.dataCorruptedError(forKey: .calendarAge, in: value, debugDescription: "Duplicate date specification")
            }
            self.calendarAge = try SearchValueUnits.calendarAge(calendarAge).text
            date = "recentCalendar"
        }
        calendarBoundary = try value.decodeIfPresent(String.self, forKey: .calendarBoundary)
        if let calendarBoundary {
            guard date == "before" || date == "after", dateFrom?.isEmpty != false, dateThrough?.isEmpty != false,
                  calendarAge == nil, relativeDays == nil, calendarPeriod == nil else {
                throw DecodingError.dataCorruptedError(forKey: .calendarBoundary, in: value,
                    debugDescription: "A calendar boundary requires before or after, without another date value")
            }
            let interval = try SearchValueUnits.calendarRange(calendarBoundary)
            dateFrom = date == "before" ? interval.from : interval.through
            self.calendarBoundary = nil
        }
        source = try value.decodeIfPresent(LiveSearchSource.self, forKey: .source)
        fileCase = try value.decodeIfPresent(String.self, forKey: .fileCase)
        caseSensitive = try value.decodeIfPresent(Bool.self, forKey: .caseSensitive)
        hidden = try value.decodeIfPresent(Bool.self, forKey: .hidden)
        ignored = try value.decodeIfPresent(Bool.self, forKey: .ignored)
        followSymlinks = try value.decodeIfPresent(Bool.self, forKey: .followSymlinks)
        wholeWords = try value.decodeIfPresent(Bool.self, forKey: .wholeWords)
        filesOnly = try value.decodeIfPresent(Bool.self, forKey: .filesOnly)
        minDepth = try value.decodeIfPresent(Int.self, forKey: .minDepth)
        maxDepth = try value.decodeIfPresent(Int.self, forKey: .maxDepth)
        contextLines = try value.decodeIfPresent(Int.self, forKey: .contextLines)
        excludedFolders = try value.decodeIfPresent([String].self, forKey: .excludedFolders)
        excludedFiles = try value.decodeIfPresent([String].self, forKey: .excludedFiles)
        excludedExtensions = try value.decodeIfPresent([String].self, forKey: .excludedExtensions)
        if let excludedExtensions {
            let patterns = try excludedExtensions.flatMap { try SearchFileTypes.selectedExtensions($0).map { "*." + $0 } }
            excludedFiles = (excludedFiles ?? []) + patterns
            self.excludedExtensions = nil
        }
        // Compact exclusions are an unordered conjunction, including when no
        // type aliases occur. Keep the fixture adapter's canonical order aligned
        // with command export; ordered rule branches stay intact.
        excludedFiles = excludedFiles.map { Array(Set($0)).sorted() }
        files = try value.decodeIfPresent(SearchIntentTree.self, forKey: .files)
        contents = try value.decodeIfPresent(SearchIntentTree.self, forKey: .contents)
        contentUnit = try value.decodeIfPresent(SearchContentUnit.self, forKey: .contentUnit)
        let keys = Set(raw.allKeys.map(\.stringValue))
        if files != nil && !keys.isDisjoint(with: SearchIntentTree.fileFields) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Put every file predicate in Files when using a file rule tree."))
        }
        if contents != nil && !keys.isDisjoint(with: SearchIntentTree.contentFields) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Put every content predicate in Contents when using a content rule tree."))
        }
        if contents != nil && mode != "contents" || contentUnit != nil && mode != "contents" {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Content rules require contents mode."))
        }
        try files?.validateShape(); try contents?.validateShape()
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case mode, name, nameMatching, path, pathMatching, content, contentMatching, contentSource, roots, extensions, minimum, maximum, date, dateField, relativeDays, calendarAge, calendarBoundary, dateFrom, dateThrough, calendarPeriod, source, fileCase, caseSensitive, hidden, ignored, followSymlinks, wholeWords, filesOnly, minDepth, maxDepth, contextLines, excludedFolders, excludedFiles, excludedExtensions, files, contents, contentUnit
    }

    func proposal(context: SearchSnapshot, tools: Toolchain) throws -> NaturalSearchProposal {
        let plan = try naturalPlan()
        // Model/template intents are complete searches with explicit defaults;
        // unlike the interactive AFM draft they do not inherit exclusions.
        var base = context; base.traversal.excludedFolders = []
        if files != nil || contents != nil || contentUnit != nil {
            let (resolved, corrections) = try plan.resolvedState(context: base, groupedContents: contents != nil)
            var state = resolved
            // Promote existing flat predicates from the other domain. The two
            // forms are mutually exclusive within each domain, never additive.
            if contents != nil { state.mode = .files }
            try state.promoteToRules()
            var rules = state.ruleSet ?? .init()
            if let files { rules.files = try files.fileRules(context: base) }
            if let contents { rules.contents = try contents.contentRules(context: base) }
            if let contentUnit { rules.contentUnit = contentUnit }
            else if rules.contents?.leaves.allSatisfy(\.isDocumentText) == true { rules.contentUnit = .file }
            try rules.validate(now: .now)
            if wholeWords == true && rules.contents?.leaves.contains(where: \.isDocumentText) == true {
                throw SearchServiceError.commandFailed("Document text does not support whole-word matching.")
            }
            guard rules.contents != nil || mode != "contents" else { throw SearchServiceError.invalidQuery }
            if source == .filesystem && rules.needsSpotlight {
                throw SearchServiceError.commandFailed("These conditions require Spotlight.")
            }
            state.replaceRules(rules)
            let pipeline = try SearchPipelineCompiler(tools: tools).compile(state.makeRequest())
            var result = NaturalSearchProposal(snapshot: state, command: pipeline.spec.shellString)
            if !corrections.isEmpty { result.executionNote += " Folder spelling corrected: " + corrections.joined(separator: "; ") + "." }
            return result
        }
        return try plan.validated(context: base, tools: tools)
    }

    func naturalPlan() throws -> NaturalSearchPlan {
        guard let mode = SearchMode(rawValue: mode) else {
            throw SearchServiceError.commandFailed("This request is outside the supported search operations.")
        }
        var plan = NaturalSearchPlan()
        plan.mode = mode
        plan.syntax = contentMatching ?? .literal
        if mode == .contents {
            // One extracted value is one literal, even when it contains quotes,
            // spaces, colons, or text that looks like a search modifier.
            let value = content ?? ""
            plan.query = plan.syntax == .regex ? value : SearchState.literalQuery(value)
        } else if !(content ?? "").isEmpty || wholeWords == true || filesOnly == true || plan.syntax != .literal {
            throw SearchServiceError.commandFailed("Content options require a content search.")
        }
        let folders = roots ?? ["."]
        guard let folder = folders.first else { throw SearchServiceError.commandFailed("A search needs a folder.") }
        plan.scopePath = folder
        plan.caseSensitive = caseSensitive ?? false
        plan.includeHidden = hidden ?? false
        plan.includeIgnored = ignored ?? false
        plan.minimumDepth = minDepth ?? 1
        plan.maximumDepth = maxDepth
        plan.minimumSize = minimum?.text ?? ""
        plan.maximumSize = maximum?.text ?? ""
        plan.dateField = dateField ?? .modified
        let period = date ?? "any"
        if period.hasSuffix("d"), let days = try? SearchFilters.parseDayInterval(period) {
            var filter = SearchFilters(); try filter.setRelativeDays(days)
            plan.datePeriod = filter.datePeriod; plan.relativeDays = filter.relativeDays
        } else if let selected = SearchDatePeriod(rawValue: period) {
            plan.datePeriod = selected; plan.relativeDays = relativeDays
        } else { throw SearchServiceError.commandFailed("Unknown date period: \(period)") }
        if period != "recentDays" && relativeDays != nil {
            throw SearchServiceError.commandFailed("A day count requires the Last N days period.")
        }
        guard (period == "recentCalendar") == (calendarAge != nil) else {
            throw SearchServiceError.commandFailed("A calendar duration needs a month or year value.")
        }
        plan.calendarAge = calendarAge
        plan.dateFrom = dateFrom.flatMap { $0.isEmpty ? nil : $0 }
        plan.dateThrough = dateThrough.flatMap { $0.isEmpty ? nil : $0 }
        // A metadata operation determines its backend. The model does not have
        // to repeat Spotlight when it already selected indexed text or dates.
        let requiresMetadata = contentSource == .indexedDocumentText
            || (plan.datePeriod != .any && [.lastOpened, .documentCreated].contains(plan.dateField))
        if requiresMetadata && source == .filesystem {
            throw SearchServiceError.commandFailed("Indexed text and metadata dates require Spotlight.")
        }
        plan.refinements.source = source ?? (requiresMetadata ? .spotlight : .filesystem)
        plan.refinements.contentSource = contentSource
        plan.refinements.name = name ?? ""
        plan.refinements.nameMatching = nameMatching ?? .contains
        plan.refinements.path = path ?? ""
        plan.refinements.pathMatching = pathMatching ?? .contains
        plan.refinements.additionalScopes = Array(folders.dropFirst())
        plan.refinements.extensions = (extensions ?? []).joined(separator: ",")
        plan.refinements.excludedFiles = (excludedFiles ?? []).joined(separator: "\n")
        plan.refinements.wholeWords = wholeWords ?? false
        plan.refinements.matchingFilesOnly = filesOnly ?? false
        plan.refinements.contextLines = contextLines ?? 3
        switch fileCase ?? "inherit" {
        case "inherit": break
        case "sensitive": plan.refinements.fileCaseSensitive = true
        case "insensitive": plan.refinements.fileCaseSensitive = false
        default: throw SearchServiceError.commandFailed("Unknown filename case option.")
        }
        plan.excludedFolders = excludedFolders ?? []
        plan.followSymlinks = followSymlinks ?? false
        return plan
    }
}
