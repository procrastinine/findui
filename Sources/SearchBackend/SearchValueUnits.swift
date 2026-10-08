import Foundation

/// Exact units and calendar values used by search filters.
/// It converts an already selected value; it never scans a search request.
package enum SearchValueUnits {
    package struct Unit: Decodable, Sendable { package let scale: Int64; package let aliases: [String]
        package init(scale: Int64, aliases: [String]) {
            self.scale = scale
            self.aliases = aliases
        }
}
    package struct Catalog: Decodable, Sendable {
        package let bytes: [Unit]
        package let days: [Unit]
        package let months: [[String]]
        package let calendarUnits: [String: [Int]]
        package let sizeComparators: [String: [String: String]]
        package init(bytes: [Unit], days: [Unit], months: [[String]], calendarUnits: [String: [Int]], sizeComparators: [String: [String: String]]) {
            self.bytes = bytes
            self.days = days
            self.months = months
            self.calendarUnits = calendarUnits
            self.sizeComparators = sizeComparators
        }

    }
    package static let specification = #"""
    {"bytes":[
      {"scale":1,"aliases":["b","byte","bytes"]},
      {"scale":1000,"aliases":["k","kb","kilobyte","kilobytes"]},
      {"scale":1000000,"aliases":["m","mb","megabyte","megabytes"]},
      {"scale":1000000000,"aliases":["g","gb","gigabyte","gigabytes"]},
      {"scale":1000000000000,"aliases":["t","tb","terabyte","terabytes"]},
      {"scale":1000000000000000,"aliases":["p","pb","petabyte","petabytes"]},
      {"scale":1000000000000000000,"aliases":["e","eb","exabyte","exabytes"]},
      {"scale":1024,"aliases":["ki","kib","kibibyte","kibibytes"]},
      {"scale":1048576,"aliases":["mi","mib","mebibyte","mebibytes"]},
      {"scale":1073741824,"aliases":["gi","gib","gibibyte","gibibytes"]},
      {"scale":1099511627776,"aliases":["ti","tib","tebibyte","tebibytes"]},
      {"scale":1125899906842624,"aliases":["pi","pib","pebibyte","pebibytes"]},
      {"scale":1152921504606846976,"aliases":["ei","eib","exbibyte","exbibytes"]}
    ],"days":[
      {"scale":1,"aliases":["d","day","days"]},
      {"scale":7,"aliases":["w","wk","wks","week","weeks"]},
      {"scale":14,"aliases":["fortnight","fortnights"]}
    ],"months":[["january","jan"],["february","feb"],["march","mar"],
      ["april","apr"],["may"],["june","jun"],["july","jul"],["august","aug"],
      ["september","sep","sept"],["october","oct"],["november","nov"],["december","dec"]],
      "calendarUnits":{"y":[12,0],"yr":[12,0],"yrs":[12,0],"year":[12,0],"years":[12,0],
        "mo":[1,0],"mos":[1,0],"month":[1,0],"months":[1,0],
        "w":[0,7],"wk":[0,7],"wks":[0,7],"week":[0,7],"weeks":[0,7],
        "d":[0,1],"day":[0,1],"days":[0,1]},
      "sizeComparators":{
        "minimum":{">=":">=","≥":">=",">":">","at least":">=","over":">","more than":">","larger than":">","greater than":">","bigger than":">","above":">"},
        "maximum":{"<=":"<=","≤":"<=","<":"<","at most":"<=","up to":"<=","under":"<","less than":"<","smaller than":"<","below":"<"}
      }}
    """#
    package static let catalog = try! JSONDecoder().decode(Catalog.self, from: Data(specification.utf8))
    package static let byteScales = Dictionary(uniqueKeysWithValues: catalog.bytes.flatMap { unit in unit.aliases.map { ($0, unit.scale) } })
    package static let dayScales = Dictionary(uniqueKeysWithValues: catalog.days.flatMap { unit in unit.aliases.map { ($0, unit.scale) } })
    package static let months = Dictionary(uniqueKeysWithValues: catalog.months.enumerated().flatMap { index, names in names.map { ($0, index + 1) } })

    package struct CalendarAge: Equatable, Sendable {
        package let months: Int
        package let days: Int
        package var text: String {
            "\(months) \(months == 1 ? "month" : "months")" + (days == 0 ? "" : " and \(days) \(days == 1 ? "day" : "days")")
        }
        package func before(_ now: Date, calendar: Calendar) throws -> Date {
            // Subtract months first, clamping to the destination month's last
            // day; then subtract calendar days. Never approximate a month by 30d.
            guard let monthDate = calendar.date(byAdding: .month, value: -months, to: now),
                  let date = calendar.date(byAdding: .day, value: -days, to: monthDate) else {
                throw SearchServiceError.commandFailed("That calendar duration cannot be represented.")
            }
            return date
        }
        package init(months: Int, days: Int) {
            self.months = months
            self.days = days
        }

    }

    package static func calendarAge(_ input: String) throws -> CalendarAge {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units = catalog.calendarUnits.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let term = "([0-9]{1,5})\\s*(" + units + ")(?![a-z])"
        let separator = #"(?:\s+and\s+|\s*,\s*(?:and\s+)?|\s+)"#
        guard text.range(of: "^(?:" + term + ")(?:(?:" + separator + ")(?:" + term + "))*$", options: .regularExpression) != nil else {
            throw SearchServiceError.commandFailed("Use a calendar duration such as 5 months and 4 days.")
        }
        let ns = text as NSString
        let matches = try NSRegularExpression(pattern: term).matches(in: text, range: NSRange(location: 0, length: ns.length))
        var months = 0, days = 0
        for match in matches {
            let count = Int(ns.substring(with: match.range(at: 1)))!
            let scale = catalog.calendarUnits[ns.substring(with: match.range(at: 2))]!
            months += count * scale[0]; days += count * scale[1]
        }
        guard (1...1200).contains(months), (0...10_000).contains(days) else {
            throw SearchServiceError.commandFailed("Use 1–1200 calendar months, with at most 10000 additional days. Use Last N days for a day-only duration.")
        }
        return CalendarAge(months: months, days: days)
    }

    package static func relativeDays(_ text: String) throws -> Int {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let regex = try NSRegularExpression(pattern: #"^([0-9]{1,5})\s*([a-z]+)?$"#)
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let count = Int(ns.substring(with: match.range(at: 1))) else { throw invalidDuration() }
        let unit = match.range(at: 2).location == NSNotFound ? "d" : ns.substring(with: match.range(at: 2))
        guard let scale = dayScales[unit], count > 0, count <= 10_000 / Int(scale) else { throw invalidDuration() }
        return count * Int(scale)
    }

    private static func invalidDuration() -> SearchServiceError {
        .commandFailed("Use a whole number of days or weeks, up to 10000 days.")
    }

    /// Convert a selected, unambiguous named calendar day. ISO dates already
    /// use the ordinary date validator. Numeric date order is never guessed.
    package static func calendarDay(_ input: String) throws -> String {
        if input.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return input }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let forms = ["^(" + names + #")\.?\s*([0-9]{1,2})(st|nd|rd|th)?(?:\s*,\s*|\s+)([0-9]{4})$"#,
                     #"^([0-9]{1,2})(st|nd|rd|th)?\s*("# + names + #")\.?\s*,?\s*([0-9]{4})$"#]
        let ns = text as NSString
        for (index, pattern) in forms.enumerated() {
            guard let match = try NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String { match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i)) }
            let day = Int(group(index == 0 ? 2 : 1))!, month = months[group(index == 0 ? 1 : 3)]!, year = Int(group(4))!
            let ordinal = group(index == 0 ? 3 : 2)
            let suffix = (11...13).contains(day % 100) ? "th" : [1:"st",2:"nd",3:"rd"][day % 10] ?? "th"
            guard (1900...2100).contains(year), ordinal.isEmpty || ordinal == suffix else { break }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: parts) else { break }
            let checked = calendar.dateComponents([.year,.month,.day], from: date)
            guard checked.year == year, checked.month == month, checked.day == day else { break }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        throw SearchServiceError.commandFailed("Use an ISO date or an unambiguous date such as Jan 1, 2024.")
    }

    package struct CalendarRange: Sendable, Equatable { package let from: String; package let through: String
        package init(from: String, through: String) {
            self.from = from
            self.through = through
        }
}
    package static func calendarRange(_ input: String) throws -> CalendarRange {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : (text as NSString).substring(with: m.range(at: $0)) }
        }
        var year: Int?, first: Int?, last: Int?
        if let g = groups(#"^(\d{4})$"#) { year = Int(g[0]); first = 1; last = 12 }
        else if let g = groups(#"^(\d{4})-(0[1-9]|1[0-2])$"#) { year = Int(g[0]); first = Int(g[1]); last = first }
        else if let g = groups(#"^q([1-4])\s+(\d{4})$"#) { year = Int(g[1]); first = (Int(g[0])! - 1) * 3 + 1; last = first! + 2 }
        else if let g = groups(#"^([a-z]+)(?:\s*(or|and|through|to|-|–)\s*([a-z]+))?\s+(\d{4})$"#) {
            year = Int(g[3]); first = months[g[0]]; last = g[2].isEmpty ? first : months[g[2]]
            if ["or", "and"].contains(g[1]), let first, let last, last - first > 1 {
                throw SearchServiceError.commandFailed("Separate calendar months require separate searches; use a contiguous date range.")
            }
        }
        guard let year, let first, let last, (1900...2100).contains(year), first <= last else {
            throw SearchServiceError.commandFailed("Use a calendar month, quarter, or year, such as January 2025 or Q1 2025.")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: last, day: 1))!
        let finalDay = calendar.range(of: .day, in: .month, for: date)!.count
        return CalendarRange(from: String(format: "%04d-%02d-01", year, first),
                             through: String(format: "%04d-%02d-%02d", year, last, finalDay))
    }
}
