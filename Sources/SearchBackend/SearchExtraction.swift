import Foundation

package struct SearchExtractionOptions: Codable, Hashable, Sendable {
    package var documents = true
    package var archives = false
    package var media = false
    package var customReaders = false
    // Automatically use the selected version. Older searches can opt out.
    package var useTika = true
    package var cacheText = true
    package var maximumArchiveDepth = 5
    package var maximumMegabytes = 64
    package var timeoutSeconds = 60

    package init() {}
    package enum CodingKeys: String, CodingKey {
        case documents, archives, media, customReaders, useTika, cacheText, maximumArchiveDepth, maximumMegabytes, timeoutSeconds
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documents = try values.decodeIfPresent(Bool.self, forKey: .documents) ?? true
        archives = try values.decodeIfPresent(Bool.self, forKey: .archives) ?? false
        media = try values.decodeIfPresent(Bool.self, forKey: .media) ?? false
        customReaders = try values.decodeIfPresent(Bool.self, forKey: .customReaders) ?? false
        useTika = try values.decodeIfPresent(Bool.self, forKey: .useTika) ?? true
        cacheText = try values.decodeIfPresent(Bool.self, forKey: .cacheText) ?? true
        maximumArchiveDepth = try values.decodeIfPresent(Int.self, forKey: .maximumArchiveDepth) ?? 5
        maximumMegabytes = try values.decodeIfPresent(Int.self, forKey: .maximumMegabytes) ?? 64
        timeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
    }

    package static var cacheDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FindUI/ExtractedText", isDirectory: true)
    }

    package func validate() throws {
        guard documents || archives || media || customReaders else {
            throw SearchServiceError.commandFailed("Select documents or archives, or turn off extracted text search.")
        }
        guard (0...10).contains(maximumArchiveDepth), (1...1024).contains(maximumMegabytes), (1...600).contains(timeoutSeconds) else {
            throw SearchServiceError.commandFailed("Extraction limits: archive depth 0–10, size 1–1024 MiB, timeout 1–600 seconds.")
        }
    }

    package func plan(tools: Toolchain) throws -> [String: Any] {
        try validate()
        let adapters = customReaders ? try ReaderConfiguration().load().filter(\.enabled) : []
        return ["media": media, "adapters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(adapters)),
            "ffmpeg": tools.ffmpeg?.path as Any? ?? NSNull(), "ffprobe": tools.ffprobe?.path as Any? ?? NSNull(),
            "documents": documents, "archives": archives, "maxDepth": maximumArchiveDepth,
            "maxMegabytes": maximumMegabytes, "timeoutSeconds": timeoutSeconds,
            "cacheDirectory": cacheText ? Self.cacheDirectory.path as Any : NSNull(),
            "rga": tools.rgaPreproc?.path as Any? ?? NSNull(), "pandoc": tools.pandoc?.path as Any? ?? NSNull(),
            "pdftotext": tools.pdftotext?.path as Any? ?? NSNull(),
            "pdfdetach": tools.pdfdetach?.path as Any? ?? NSNull(),
            "tikaJar": documents && useTika ? tools.tikaJar?.path as Any? ?? NSNull() : NSNull()]
    }
}

package struct ExtractedMatchOrigin: Codable, Hashable, Sendable {
    package struct Member: Codable, Hashable, Sendable { package let name: String; package let index: UInt64; package var kind: String? = nil
        package init(name: String, index: UInt64, kind: String? = nil) {
            self.name = name
            self.index = index
            self.kind = kind
        }
}
    package let extractor: String
    package let line: Int
    package let page: Int?
    package var sheet: String? = nil
    package var slide: Int? = nil
    package var members: [Member]? = nil
    package var documentTitle: String? = nil
    package var author: String? = nil
    package var sourceIdentity: String? = nil
    package var metadataOnly: Bool? = nil
    package var memberKind: String? = nil
    package var reader: String? = nil
    package var timecode: String? = nil
    package var recordKey: String? = nil
    package var table: String? = nil
    package var row: String? = nil
    package var message: String? = nil
    package var memberPath: String? {
        guard let members, !members.isEmpty else { return nil }
        return members.map(\.name).joined(separator: " › ")
    }
    package var label: String {
        [memberPath, location].compactMap { $0 }.joined(separator: " · ")
    }
    package var location: String {
        if metadataOnly == true { return memberKind == "directory" ? "Directory name · not expanded" : "Member name · not expanded" }
        if let timecode { return "\(reader ?? "Subtitles") · \(timecode)" }
        if let reader { return reader + " · extracted text" }
        if let table { return "Table \(table) · row \(row ?? "?")" }
        if let message { return "Message \(message) · line \(line)" }
        if let page { return "Page \(page) · extracted text" }
        if let sheet { return "Sheet \(sheet) · extracted text" }
        if let slide { return "Slide \(slide) · extracted text" }
        return "Extracted text · line \(line)"
    }
    package init(extractor: String, line: Int, page: Int? = nil, sheet: String? = nil, slide: Int? = nil, members: [Member]? = nil, documentTitle: String? = nil, author: String? = nil, sourceIdentity: String? = nil, metadataOnly: Bool? = nil, memberKind: String? = nil, recordKey: String? = nil, table: String? = nil, row: String? = nil, message: String? = nil) {
        self.extractor = extractor
        self.line = line
        self.page = page
        self.sheet = sheet
        self.slide = slide
        self.members = members
        self.documentTitle = documentTitle
        self.author = author
        self.sourceIdentity = sourceIdentity
        self.metadataOnly = metadataOnly
        self.memberKind = memberKind
        self.recordKey = recordKey
        self.table = table
        self.row = row
        self.message = message
    }

}
