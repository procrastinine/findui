import SearchCore
import Foundation

package enum PatternMatching: String, CaseIterable, Codable, Identifiable, Sendable {
    case contains, exact, glob, regex, fuzzy
    package var id: Self { self }
    package var title: String { switch self {
    case .contains: "Contains"; case .exact: "Exact"; case .glob: "Wildcard"
    case .regex: "Regex"; case .fuzzy: "Fuzzy"
    }}
}

package enum LiveSearchSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case filesystem, spotlight
    package var id: Self { self }
    package var title: String { self == .filesystem ? "Live files" : "Spotlight" }
}

package enum ContentSearchSource: String, Codable, Sendable {
    case fileText, indexedDocumentText
}

package enum ContentMatchingChoice: String, CaseIterable, Identifiable {
    case literal, regex, documentText, expression, indexedWords
    package var id: Self { self }
    package var title: String { switch self { case .literal: "Literal"; case .regex: "Regex"; case .documentText: "Spotlight text"; case .expression: "Expression"; case .indexedWords: "Indexed words" } }
}

package enum ContentQueryStyle: String, Codable, Sendable { case literal, expression }
package enum ContentTextEngine: String, CaseIterable, Identifiable {
    case live, indexedWords
    package var id: Self { self }
    package var title: String { self == .live ? "Live text" : "Indexed words" }
}
package enum TagMatch: String, Codable, CaseIterable, Sendable {
    case all, any, none
    package var title: String { rawValue.capitalized }
}

package enum SearchSourceChoice: String, CaseIterable {
    case live = "Live files", spotlight = "Spotlight", snapshot = "Saved snapshot"
}

/// Independent predicates shared by controls, history and the command compiler.
package struct SearchRefinements: Codable, Hashable, Sendable {
    package struct SavedFileQuery: Codable, Hashable, Sendable {
        package var text: String
        package var syntax: SearchSyntax
        package var exactName: Bool
        package init(text: String, syntax: SearchSyntax, exactName: Bool) {
            self.text = text
            self.syntax = syntax
            self.exactName = exactName
        }

    }
    package var additionalScopes: [String] = []
    package var source: LiveSearchSource = .filesystem
    // Nil preserves the original rg semantics of existing saved searches.
    package var contentSource: ContentSearchSource? = nil
    package var name = ""
    package var nameMatching: PatternMatching = .contains
    package var fileCaseSensitive: Bool? = nil
    package var path = ""
    package var pathMatching: PatternMatching = .contains
    package var absolutePathMatching: Bool? = nil
    package var extensions = ""
    package var excludedFiles = ""
    package var fileQuery = ""
    package var savedFileQuery: SavedFileQuery? = nil
    package var wholeWords = false
    package var matchingFilesOnly = false
    package var contextLines = 3
    package var fuzzyFullPath = true
    package var fuzzyNormalize: Bool? = nil
    /// Zero/nil lets the CLI engines choose a bounded parallelism level.
    package var workers: Int? = nil
    package var finderTags: [String]? = nil
    package var tagMatch: TagMatch? = nil
    package var useContentIndex: Bool? = nil
    package var textEncoding: String? = nil
    package var typoTolerance: Int? = nil
    package var wordSearch: Bool? = nil
    package var stemWords: Bool? = nil
    package var multiline: Bool? = nil
    package var wordLanguage: WordLanguage? = nil
    // Conversion and archive expansion are explicit per-search choices.
    package var extraction: SearchExtractionOptions? = nil

    package var hasFileConditions: Bool {
        !name.isEmpty || !path.isEmpty || !extensions.isEmpty || !excludedFiles.isEmpty || !fileQuery.isEmpty
            || !(savedFileQuery?.text.isEmpty ?? true)
            || !(finderTags?.isEmpty ?? true)
    }
    package init(additionalScopes: [String] = [], source: LiveSearchSource = .filesystem, contentSource: ContentSearchSource? = nil, name: String = "", nameMatching: PatternMatching = .contains, fileCaseSensitive: Bool? = nil, path: String = "", pathMatching: PatternMatching = .contains, absolutePathMatching: Bool? = nil, extensions: String = "", excludedFiles: String = "", fileQuery: String = "", savedFileQuery: SavedFileQuery? = nil, wholeWords: Bool = false, matchingFilesOnly: Bool = false, contextLines: Int = 3, fuzzyFullPath: Bool = true, workers: Int? = nil, finderTags: [String]? = nil, tagMatch: TagMatch? = nil, useContentIndex: Bool? = nil, textEncoding: String? = nil, typoTolerance: Int? = nil, wordSearch: Bool? = nil, stemWords: Bool? = nil, multiline: Bool? = nil, wordLanguage: WordLanguage? = nil, extraction: SearchExtractionOptions? = nil) {
        self.additionalScopes = additionalScopes
        self.source = source
        self.contentSource = contentSource
        self.name = name
        self.nameMatching = nameMatching
        self.fileCaseSensitive = fileCaseSensitive
        self.path = path
        self.pathMatching = pathMatching
        self.absolutePathMatching = absolutePathMatching
        self.extensions = extensions
        self.excludedFiles = excludedFiles
        self.fileQuery = fileQuery
        self.savedFileQuery = savedFileQuery
        self.wholeWords = wholeWords
        self.matchingFilesOnly = matchingFilesOnly
        self.contextLines = contextLines
        self.fuzzyFullPath = fuzzyFullPath
        self.workers = workers
        self.finderTags = finderTags
        self.tagMatch = tagMatch
        self.useContentIndex = useContentIndex
        self.textEncoding = textEncoding
        self.typoTolerance = typoTolerance
        self.wordSearch = wordSearch
        self.stemWords = stemWords
        self.multiline = multiline
        self.wordLanguage = wordLanguage
        self.extraction = extraction
    }

}

extension SearchRefinements {
    // CLI callers and older saved states may provide only the options they use.
    // Missing values retain the same defaults as a new GUI search; malformed
    // values still throw instead of silently changing query meaning.
    private enum CodingKeys: String, CodingKey {
        case additionalScopes, source, contentSource, name, nameMatching, fileCaseSensitive
        case path, pathMatching, absolutePathMatching, extensions, excludedFiles, fileQuery, savedFileQuery
        case wholeWords, matchingFilesOnly, contextLines, fuzzyFullPath, fuzzyNormalize, workers, finderTags, tagMatch
        case useContentIndex, textEncoding, typoTolerance, wordSearch, stemWords, multiline, wordLanguage, extraction
    }
    package init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        additionalScopes = try c.decodeIfPresent([String].self, forKey: .additionalScopes) ?? additionalScopes
        source = try c.decodeIfPresent(LiveSearchSource.self, forKey: .source) ?? source
        contentSource = try c.decodeIfPresent(ContentSearchSource.self, forKey: .contentSource)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        nameMatching = try c.decodeIfPresent(PatternMatching.self, forKey: .nameMatching) ?? nameMatching
        fileCaseSensitive = try c.decodeIfPresent(Bool.self, forKey: .fileCaseSensitive)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? path
        pathMatching = try c.decodeIfPresent(PatternMatching.self, forKey: .pathMatching) ?? pathMatching
        absolutePathMatching = try c.decodeIfPresent(Bool.self, forKey: .absolutePathMatching)
        extensions = try c.decodeIfPresent(String.self, forKey: .extensions) ?? extensions
        excludedFiles = try c.decodeIfPresent(String.self, forKey: .excludedFiles) ?? excludedFiles
        fileQuery = try c.decodeIfPresent(String.self, forKey: .fileQuery) ?? fileQuery
        savedFileQuery = try c.decodeIfPresent(SavedFileQuery.self, forKey: .savedFileQuery)
        wholeWords = try c.decodeIfPresent(Bool.self, forKey: .wholeWords) ?? wholeWords
        matchingFilesOnly = try c.decodeIfPresent(Bool.self, forKey: .matchingFilesOnly) ?? matchingFilesOnly
        contextLines = try c.decodeIfPresent(Int.self, forKey: .contextLines) ?? contextLines
        fuzzyFullPath = try c.decodeIfPresent(Bool.self, forKey: .fuzzyFullPath) ?? fuzzyFullPath
        fuzzyNormalize = try c.decodeIfPresent(Bool.self, forKey: .fuzzyNormalize)
        workers = try c.decodeIfPresent(Int.self, forKey: .workers)
        finderTags = try c.decodeIfPresent([String].self, forKey: .finderTags)
        tagMatch = try c.decodeIfPresent(TagMatch.self, forKey: .tagMatch)
        useContentIndex = try c.decodeIfPresent(Bool.self, forKey: .useContentIndex)
        textEncoding = try c.decodeIfPresent(String.self, forKey: .textEncoding)
        typoTolerance = try c.decodeIfPresent(Int.self, forKey: .typoTolerance)
        wordSearch = try c.decodeIfPresent(Bool.self, forKey: .wordSearch)
        stemWords = try c.decodeIfPresent(Bool.self, forKey: .stemWords)
        multiline = try c.decodeIfPresent(Bool.self, forKey: .multiline)
        wordLanguage = try c.decodeIfPresent(WordLanguage.self, forKey: .wordLanguage)
        extraction = try c.decodeIfPresent(SearchExtractionOptions.self, forKey: .extraction)
    }
}

extension SearchRequest {
    package var scopes: [URL] {
        var roots = ([scope] + refinements.additionalScopes.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }).map(\.standardizedFileURL)
        roots.sort { $0.path.count < $1.path.count }
        // Nested roots matter when each root has its own depth boundary.
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }
    package var searchesDocumentText: Bool {
        if let rules = state.ruleSet { return rules.contentLeaves.contains(where: \.isDocumentText) == true }
        return mode == .contents && refinements.contentSource == .indexedDocumentText
    }
    package var producesContentLines: Bool {
        mode == .contents && (state.ruleSet == nil || state.ruleSet?.separated != nil)
            && state.ruleSet?.contentUnit != .file && !searchesDocumentText && !refinements.matchingFilesOnly
    }
}
