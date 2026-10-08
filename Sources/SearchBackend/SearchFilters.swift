import Foundation

package enum SearchDateField: String, CaseIterable, Codable, Identifiable, Sendable {
    case modified, created, lastOpened, documentCreated
    package var id: Self { self }
    package var title: String { switch self { case .modified: "Modified"; case .created: "File created"; case .lastOpened: "Last opened"; case .documentCreated: "Document created" } }
    package var spotlightAttribute: String? {
        switch self { case .lastOpened: "kMDItemLastUsedDate"; case .documentCreated: "kMDItemContentCreationDate"; default: nil }
    }
}

package enum SearchDatePeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case any, today, yesterday, week, month, year, recentDays, recentCalendar, before, after, custom
    package var id: Self { self }
    package var title: String {
        switch self {
        case .any: "Any time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .before: "Before date"
        case .after: "After date"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .year: "Last 365 days"
        case .recentDays: "Last N days"
        case .recentCalendar: "Calendar duration"
        case .custom: "Date range"
        }
    }
}

package struct SearchFilters: Codable, Hashable, Sendable {
    package var minimumSize = ""
    package var maximumSize = ""
    package var dateField: SearchDateField = .modified
    package var datePeriod: SearchDatePeriod = .any
    // Optional so searches saved before this control existed still decode.
    package var relativeDays: Int? = nil
    package var calendarAge: String? = nil
    package var dateFrom: Date = Calendar.current.startOfDay(for: .now)
    package var dateThrough: Date = Calendar.current.startOfDay(for: .now)

    package var isActive: Bool {
        !minimumSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !maximumSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || datePeriod != .any
    }

    package var datePeriodDescription: String {
        if datePeriod == .recentCalendar { return "Last \(calendarAge ?? "1 month")" }
        return datePeriod == .recentDays ? "Last \(relativeDays ?? 7) days" : datePeriod.title
    }

    package mutating func setRelativeDays(_ days: Int) throws {
        guard (1...10_000).contains(days) else {
            throw SearchServiceError.commandFailed("Enter a number of days between 1 and 10000.")
        }
        datePeriod = days == 7 ? .week : days == 30 ? .month : days == 365 ? .year : .recentDays
        relativeDays = datePeriod == .recentDays ? days : nil
    }

    package static func parseDayInterval(_ text: String) throws -> Int {
        let aliases = ["1week": 7, "1month": 30, "1year": 365]
        if let days = aliases[text] { return days }
        let expression = try NSRegularExpression(pattern: #"^([1-9][0-9]{0,3}|10000)(?:d|days?)$"#)
        let value = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: value.length)),
              let days = Int(value.substring(with: match.range(at: 1))) else {
            throw SearchServiceError.commandFailed("Use a positive number of days, such as 20d (up to 10000d).")
        }
        return days
    }

    package func validated(now: Date = .now, calendar: Calendar = .current) throws -> ValidatedSearchFilters {
        let minimum = try Self.sizeBound(minimumSize, side: .minimum)
        let maximum = try Self.sizeBound(maximumSize, side: .maximum)
        if let minimum, let maximum, minimum > maximum {
            throw SearchServiceError.commandFailed("Minimum size must not exceed maximum size.")
        }
        let lowerDate: Date?
        let upperDate: Date?
        switch datePeriod {
        case .any: lowerDate = nil; upperDate = nil
        case .today:
            lowerDate = calendar.startOfDay(for: now)
            upperDate = calendar.date(byAdding: .day, value: 1, to: lowerDate!)
        case .yesterday:
            upperDate = calendar.startOfDay(for: now)
            lowerDate = calendar.date(byAdding: .day, value: -1, to: upperDate!)
        case .before:
            lowerDate = nil
            upperDate = calendar.startOfDay(for: dateFrom)
        case .after:
            lowerDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateFrom))
            upperDate = nil
        case .week, .month, .year, .recentDays:
            let days = datePeriod == .week ? 7 : datePeriod == .month ? 30 : datePeriod == .year ? 365 : relativeDays ?? 7
            guard (1...10_000).contains(days) else {
                throw SearchServiceError.commandFailed("Enter a number of days between 1 and 10000.")
            }
            lowerDate = now.addingTimeInterval(-Double(days) * 86_400)
            upperDate = now
        case .recentCalendar:
            lowerDate = try SearchValueUnits.calendarAge(calendarAge ?? "1 month").before(now, calendar: calendar)
            upperDate = now
        case .custom:
            lowerDate = calendar.startOfDay(for: dateFrom)
            upperDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateThrough))
            guard let lowerDate, let upperDate, lowerDate < upperDate else {
                throw SearchServiceError.commandFailed("The start date must be on or before the end date.")
            }
        }
        return ValidatedSearchFilters(minimumSize: minimum, maximumSize: maximum, dateField: dateField,
                                      from: lowerDate, before: upperDate)
    }

    package enum SizeSide: String { case minimum, maximum }

    /// UI/history keep the selected quantity; execution uses inclusive integer
    /// bounds. Explicit comparison symbols never silently lose strictness.
    package static func sizeBound(_ input: String, side: SizeSide) throws -> Int64? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var comparison = side == .minimum ? ">=" : "<="
        for (prefix, operation) in SearchValueUnits.catalog.sizeComparators[side.rawValue]!.sorted(by: { $0.key.count > $1.key.count }) {
            guard text.lowercased().hasPrefix(prefix) else { continue }
            let rest = text.dropFirst(prefix.count)
            if prefix.last!.isLetter && rest.first?.isWhitespace != true { continue }
            comparison = operation; text = rest.trimmingCharacters(in: .whitespacesAndNewlines); break
        }
        guard var value = try decimalBytes(text) else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, [">", "<="].contains(comparison) ? .down : .up)
        if comparison == ">" { rounded += 1 }
        if comparison == "<" { rounded -= 1 }
        guard rounded >= 0, rounded <= Decimal(Int64.max) else {
            throw SearchServiceError.commandFailed("That size bound cannot match any file.")
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    package static func bytes(_ input: String) throws -> Int64? {
        guard var value = try decimalBytes(input) else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private static func decimalBytes(_ input: String) throws -> Decimal? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.isEmpty { return nil }
        let regex = try NSRegularExpression(pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*([A-Z]+)?$"#)
        let ns = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)),
              ns.substring(with: match.range(at: 1)).filter(\.isNumber).count <= 25,
              let number = Decimal(string: ns.substring(with: match.range(at: 1)), locale: Locale(identifier: "en_US_POSIX")) else {
            throw SearchServiceError.commandFailed("Enter a size such as 500 KB, 10 MB, or 1.5 GB.")
        }
        let unit = match.range(at: 2).location == NSNotFound ? "B" : ns.substring(with: match.range(at: 2))
        guard let scale = SearchValueUnits.byteScales[unit.lowercased()] else {
            throw SearchServiceError.commandFailed("Enter a size such as 500 KB, 10 MB, or 1.5 GB.")
        }
        let bytes = number * Decimal(scale)
        guard !bytes.isNaN, bytes >= 0, bytes <= Decimal(Int64.max) else {
            throw SearchServiceError.commandFailed("That file size is too large.")
        }
        return bytes
    }
    package init(minimumSize: String = "", maximumSize: String = "", dateField: SearchDateField = .modified, datePeriod: SearchDatePeriod = .any, relativeDays: Int? = nil, calendarAge: String? = nil, dateFrom: Date = Calendar.current.startOfDay(for: .now), dateThrough: Date = Calendar.current.startOfDay(for: .now)) {
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.dateField = dateField
        self.datePeriod = datePeriod
        self.relativeDays = relativeDays
        self.calendarAge = calendarAge
        self.dateFrom = dateFrom
        self.dateThrough = dateThrough
    }

}

package struct ValidatedSearchFilters: Sendable {
    package let minimumSize: Int64?
    package let maximumSize: Int64?
    package let dateField: SearchDateField
    package let from: Date?
    package let before: Date?

    package func matches(size: Int64?, modifiedAt: Date?, createdAt: Date?, lastOpenedAt: Date? = nil, documentCreatedAt: Date? = nil) -> Bool {
        if let minimumSize, (size ?? -1) < minimumSize { return false }
        if let maximumSize, size == nil || size! > maximumSize { return false }
        let date = switch dateField { case .modified: modifiedAt; case .created: createdAt; case .lastOpened: lastOpenedAt; case .documentCreated: documentCreatedAt }
        if let from, date == nil || date! < from { return false }
        if let before, date == nil || date! >= before { return false }
        return true
    }
    package init(minimumSize: Int64? = nil, maximumSize: Int64? = nil, dateField: SearchDateField, from: Date? = nil, before: Date? = nil) {
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.dateField = dateField
        self.from = from
        self.before = before
    }

}

package struct SearchTraversalOptions: Codable, Hashable, Sendable {
    package var includeIgnored = false
    /// Exact directory names at any depth, relative to the search root.
    package var excludedFolders: [String] = [".git"]
    package var minimumDepth: Int = 1
    package var maximumDepth: Int? = nil
    package var followSymlinks: Bool = false
    package var includePackageContents: Bool = true
    /// Ordered ripgrep-style traversal overrides. A leading ! excludes.
    /// Kept separate from file predicates because these prune directories and
    /// explicit inclusions override ignore files and hidden-file defaults.
    package var pathRules: [String]? = nil
    package static let packageExtensions = ["app", "bundle", "framework", "plugin", "kext", "pkg", "rtfd",
        "pages", "numbers", "key", "xcodeproj", "xcworkspace", "playground", "photoslibrary"]
    package static var packageGlobs: [String] {
        packageExtensions.map { "*." + $0.map { "[\($0)\($0.uppercased())]" }.joined() }
    }

    package enum CodingKeys: String, CodingKey { case includeIgnored, excludedFolders, minimumDepth, maximumDepth, followSymlinks, includePackageContents, pathRules }
    package init(includeIgnored: Bool = false, excludedFolders: [String] = [".git"], minimumDepth: Int = 1,
         maximumDepth: Int? = nil, followSymlinks: Bool = false, includePackageContents: Bool = true, pathRules: [String]? = nil) {
        self.includeIgnored = includeIgnored; self.excludedFolders = excludedFolders
        self.minimumDepth = minimumDepth; self.maximumDepth = maximumDepth; self.followSymlinks = followSymlinks
        self.includePackageContents = includePackageContents
        self.pathRules = pathRules
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeIgnored = try c.decodeIfPresent(Bool.self, forKey: .includeIgnored) ?? false
        excludedFolders = try c.decodeIfPresent([String].self, forKey: .excludedFolders) ?? [".git"]
        // Older versions excluded .git implicitly. Preserve their actual scan
        // coverage, while allowing new snapshots to explicitly clear this rule.
        if !c.contains(.minimumDepth), !excludedFolders.contains(".git") { excludedFolders.append(".git") }
        minimumDepth = try c.decodeIfPresent(Int.self, forKey: .minimumDepth) ?? 1
        maximumDepth = try c.decodeIfPresent(Int.self, forKey: .maximumDepth)
        followSymlinks = try c.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? false
        includePackageContents = try c.decodeIfPresent(Bool.self, forKey: .includePackageContents) ?? true
        pathRules = try c.decodeIfPresent([String].self, forKey: .pathRules)
    }

    package var normalized: Self {
        Self(includeIgnored: includeIgnored, excludedFolders: Array(Set(excludedFolders
            .filter { !$0.isEmpty })).sorted(),
             minimumDepth: minimumDepth, maximumDepth: maximumDepth, followSymlinks: followSymlinks,
             includePackageContents: includePackageContents, pathRules: pathRules?.isEmpty == false ? pathRules : nil)
    }

    package func validate(allowRoot: Bool = false) throws {
        // A captured result list may explicitly contain its root. Ordinary
        // traversals and saved indexes continue to search descendants only.
        let firstDepth = allowRoot ? 0 : 1
        guard minimumDepth >= firstDepth, maximumDepth == nil || maximumDepth! >= minimumDepth else {
            throw SearchServiceError.commandFailed("Depth must start at \(firstDepth), with a maximum at least as large as the minimum.")
        }
        if normalized.excludedFolders.contains(where: { $0 == "." || $0 == ".." || $0.contains("/") || $0.contains("\0") }) {
            throw SearchServiceError.commandFailed("Exclude folders by name, such as node_modules or .venv, without a path.")
        }
        if let pathRules, pathRules.contains(where: { $0.isEmpty || $0 == "!" || $0.contains("\0") || $0.contains("\n") }) {
            throw SearchServiceError.commandFailed("Enter one path pattern per line; use ! followed by a pattern to exclude paths.")
        }
    }

    package func effective(for engine: String) -> Self {
        var options = normalized
        // find has no ignore-file parser; retain its documented all-files behavior.
        if engine == "find" { options.includeIgnored = true }
        return options
    }

    package func excludes(_ url: URL, in scope: URL, isDirectory: Bool) -> Bool {
        guard let relative = SearchPath.relativePath(of: url, in: scope) else { return true }
        let components = relative.split(separator: "/").map(String.init)
        let directories = isDirectory ? components[...] : components.dropLast()
        return directories.contains(where: normalized.excludedFolders.contains)
            || (!includePackageContents && components.dropLast().contains { Self.packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
    }

    package static let findWarning = "find does not honor ignore files. Install fd to exclude ignored files from filename searches and indexes."
}

/// Bounded best-N storage. Fuzzy searches must examine all candidates before choosing winners.
package struct RankedSearchResults: Sendable {
    package let limit: Int
    package private(set) var results: [SearchResult] = []
    package private(set) var matchCount = 0
    package var isTruncated: Bool { matchCount > max(0, limit) }

    package mutating func append(_ result: SearchResult) {
        matchCount += 1
        guard limit > 0 else { return }
        if results.count == limit, let last = results.last, !SearchResult.bestMatchFirst(result, last) { return }
        var low = 0
        var high = results.count
        while low < high {
            let middle = (low + high) / 2
            if SearchResult.bestMatchFirst(result, results[middle]) { high = middle } else { low = middle + 1 }
        }
        results.insert(result, at: low)
        if results.count > limit { results.removeLast() }
    }
    package init(limit: Int, results: [SearchResult] = [], matchCount: Int = 0) {
        self.limit = limit
        self.results = results
        self.matchCount = matchCount
    }

}
