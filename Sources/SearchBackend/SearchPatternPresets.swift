import Foundation

/// Named patterns are explicit choices. A literal or raw regex called "email"
/// stays unchanged. The same catalog supplies menus and structured AI input.
package enum SearchPatternPresets {
    package struct Preset: Decodable, Identifiable, Sendable {
        package let id: String
        package let title: String
        package let aliases: [String]
        package let pattern: String
        package let example: String
        package let nonexample: String
        package let detail: String
        package init(id: String, title: String, aliases: [String], pattern: String, example: String, nonexample: String, detail: String) {
            self.id = id
            self.title = title
            self.aliases = aliases
            self.pattern = pattern
            self.example = example
            self.nonexample = nonexample
            self.detail = detail
        }

    }
    package static let specification = #"""
    [
      {"id":"email","title":"Email address","aliases":["email","emails","email address","email addresses"],"pattern":"\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}\\b","example":"name@example.com","nonexample":"name at example dot com","detail":"Common ASCII email-shaped text; not full mailbox validation."},
      {"id":"website","title":"Website URL","aliases":["website","websites","url","urls","web address","web addresses"],"pattern":"\\bhttps?://[^\\s<>\"']+","example":"https://example.com/path","nonexample":"example without a URL","detail":"HTTP or HTTPS URLs. Trailing prose punctuation may be included."},
      {"id":"domain","title":"Domain name","aliases":["domain","domains","domain name","domain names"],"pattern":"\\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,63}\\b","example":"docs.example.org","nonexample":"localhost","detail":"Dotted ASCII domain names, including the domain part of emails."},
      {"id":"date","title":"ISO date","aliases":["date","dates","iso date","iso dates"],"pattern":"\\b[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])\\b","example":"2024-02-29","nonexample":"2024-13-40","detail":"YYYY-MM-DD shape. Does not validate month lengths or leap years."},
      {"id":"time","title":"24-hour time","aliases":["time","times","24-hour time"],"pattern":"\\b(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?\\b","example":"14:35:09","nonexample":"25:90","detail":"HH:MM with optional seconds, using a 24-hour clock."},
      {"id":"ipv4","title":"IPv4 address","aliases":["ipv4","ipv4 address","ipv4 addresses"],"pattern":"\\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\b","example":"192.168.1.10","nonexample":"999.999.999.999","detail":"Four decimal octets from 0 to 255; no leading zeroes."},
      {"id":"uuid","title":"UUID","aliases":["uuid","uuids","guid","guids"],"pattern":"\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\b","example":"123e4567-e89b-12d3-a456-426614174000","nonexample":"not-a-uuid","detail":"Canonical UUID shape, without restricting version or variant."},
      {"id":"mac","title":"MAC address","aliases":["mac address","mac addresses"],"pattern":"\\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\\b","example":"aa:bb:cc:dd:ee:ff","nonexample":"aa:bb:cc:dd:ee","detail":"Six hexadecimal pairs separated by colons."},
      {"id":"hexcolor","title":"Hex color","aliases":["hex color","hex colors","hex colour","hex colours"],"pattern":"#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})\\b","example":"#a1b2c3","nonexample":"#xyzxyz","detail":"CSS hexadecimal colors, with optional alpha."}
    ]
    """#
    package static let all = try! JSONDecoder().decode([Preset].self, from: Data(specification.utf8))

    package static func named(_ value: String) -> Preset? {
        all.first { $0.id == value.lowercased() || $0.aliases.contains(value.lowercased()) }
    }
}

extension SearchState {
    package mutating func applyContentPreset(_ preset: SearchPatternPresets.Preset) {
        // Preserve a filename search before switching the shared syntax. Store
        // the actual visible regex, so history/copy has no hidden preset layer.
        contentsInput = preset.pattern
        contentMatchingChoice = .regex
        contentsInput = preset.pattern
        refinements.wholeWords = false
    }
}
