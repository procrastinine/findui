import Foundation

/// Shared presentation of the exact saved/executed state. No inferred filters.
extension SearchSnapshot {
    package var activeFilterDescriptions: [String] {
        if nativeCommand != nil { return [] }
        var values: [String] = []
        if useIndex { values.append("Saved snapshot") }
        else if refinements.source == .spotlight { values.append("Source: Spotlight") }
        if mode == .contents && refinements.contentSource == .indexedDocumentText { values.append("Indexed document text") }
        if includeHidden { values.append("Include hidden files") }
        if traversal.includeIgnored { values.append("Include ignored files") }
        if traversal.followSymlinks { values.append("Follow symbolic links") }
        if !traversal.includePackageContents { values.append("Skip package contents") }
        if let workers = refinements.workers, workers > 0 { values.append("Parallel workers: \(workers)") }
        if hasFuzzyConditions && refinements.fuzzyNormalize == true { values.append("Fuzzy: match accented variants") }
        if !refinements.additionalScopes.isEmpty { values.append("Also in: " + refinements.additionalScopes.joined(separator: ", ")) }
        if !refinements.path.isEmpty {
            values.append((refinements.absolutePathMatching == true ? "Full path " : "Path ")
                + refinements.pathMatching.title.lowercased() + ": " + refinements.path)
        }
        if !refinements.extensions.isEmpty { values.append("Extensions: " + refinements.extensions) }
        if let tags = refinements.finderTags, !tags.isEmpty {
            values.append("Tags · " + (refinements.tagMatch ?? .all).title + ": " + tags.joined(separator: ", "))
        }
        if !refinements.fileQuery.isEmpty { values.append("File conditions: " + refinements.fileQuery) }
        if let saved = refinements.savedFileQuery, !saved.text.isEmpty {
            values.append("File " + saved.syntax.title.lowercased() + (saved.exactName ? " (exact name)" : "") + ": " + saved.text)
        }
        if mode != .contents, !query.isEmpty { values.append("File " + syntax.title.lowercased() + ": " + query) }
        if !filters.minimumSize.isEmpty { values.append("Size ≥ " + filters.minimumSize) }
        if !filters.maximumSize.isEmpty { values.append("Size ≤ " + filters.maximumSize) }
        if filters.datePeriod != .any {
            var date = filters.datePeriodDescription
            if [.before, .after, .custom].contains(filters.datePeriod) {
                date += " " + filters.dateFrom.formatted(date: .abbreviated, time: .omitted)
                if filters.datePeriod == .custom { date += " – " + filters.dateThrough.formatted(date: .abbreviated, time: .omitted) }
            }
            values.append(filters.dateField.title + ": " + date)
        }
        if traversal.minimumDepth != 1 || traversal.maximumDepth != nil {
            values.append("Depth: \(traversal.minimumDepth)–\(traversal.maximumDepth.map(String.init) ?? "unlimited")")
        }
        if !traversal.normalized.excludedFolders.isEmpty {
            values.append("Exclude folders: " + traversal.normalized.excludedFolders.joined(separator: ", "))
        }
        for pattern in traversal.pathRules ?? [] {
            values.append(pattern.hasPrefix("!") ? "Exclude paths: " + pattern.dropFirst() : "Include paths: " + pattern)
        }
        if !refinements.excludedFiles.isEmpty { values.append("Exclude files: " + refinements.excludedFiles.replacingOccurrences(of: "\n", with: ", ")) }
        if mode == .contents {
            if refinements.wordSearch == true {
                let language = refinements.wordLanguage?.title ?? "English"
                values.append(refinements.stemWords == true ? "Prepared words · \(language) word forms" : "Prepared words · relevance ranking")
            }
            if let encoding = refinements.textEncoding, !encoding.isEmpty { values.append("Text encoding: " + encoding) }
            if let edits = refinements.typoTolerance, edits > 0 { values.append("Contents: up to \(edits) typos per phrase") }
            if let extraction = refinements.extraction, refinements.contentSource != .indexedDocumentText {
                var formats: [String] = []
                if extraction.documents { formats.append("documents") }
                if extraction.archives { formats.append("archives") }
                if extraction.media { formats.append("media metadata and subtitles") }
                if extraction.customReaders { formats.append("custom reader formats") }
                values.append("Search inside " + (formats.isEmpty ? "no document formats" : formats.joined(separator: " and ")))
                if !extraction.useTika { values.append("Additional Office formats disabled") }
                if !extraction.cacheText { values.append("Extracted text cache: bypassed") }
                if extraction.maximumArchiveDepth != 5 || extraction.maximumMegabytes != 64 || extraction.timeoutSeconds != 60 {
                    values.append("Extraction limits: \(extraction.maximumArchiveDepth) steps, \(extraction.maximumMegabytes) MiB, \(extraction.timeoutSeconds) seconds per file")
                }
            }
            if refinements.multiline == true { values.append("Contents: match across line breaks") }
            if refinements.wholeWords { values.append("Contents: whole words") }
            if refinements.matchingFilesOnly { values.append("Output: matching files") }
            if refinements.contextLines != 3 { values.append("Preview: \(refinements.contextLines) context lines") }
        }
        return values
    }

    package var parameterDescription: String {
        if let nativeCommand {
            return "Command search\nWorking folder: " + nativeCommand.directory + "\n" + nativeCommand.command
        }
        if let rules = ruleSet {
            return ([summary, "Folder: " + scopePath, rules.parameterDescription,
                     "Filename case: \((refinements.fileCaseSensitive ?? caseSensitive) ? "sensitive" : "insensitive")"]
                    + (!rules.hasContents ? [] : ["Contents case: \(caseSensitive ? "sensitive" : "insensitive")"])
                    + activeFilterDescriptions).joined(separator: "\n")
        }
        return ([summary, "Folder: " + scopePath]
         + (refinements.name.isEmpty ? [] : ["Filename \(refinements.nameMatching.title.lowercased()): \(refinements.name)"])
         + (mode == .contents ? ["Contents \(contentMatchingChoice.title.lowercased()): \(contentsInput)"] : [])
         + ["Filename case: \((refinements.fileCaseSensitive ?? caseSensitive) ? "sensitive" : "insensitive")"]
         + (mode == .contents ? ["Contents case: \(caseSensitive ? "sensitive" : "insensitive")"] : [])
         + activeFilterDescriptions).joined(separator: "\n")
    }
}

extension SearchRuleTree {
    package func description(_ label: (Rule) -> String, level: Int = 0) -> String {
        let padding = String(repeating: "  ", count: level)
        let title: String, children: [Self]
        switch self {
        case .rule(let rule): return padding + label(rule)
        case .all(let values): title = "All"; children = values
        case .any(let values): title = "Any"; children = values
        case .none(let values): title = "None"; children = values
        }
        if children.isEmpty { return padding + "No conditions" }
        return ([padding + title + " of:"] + children.map { $0.description(label, level: level + 1) }).joined(separator: "\n")
    }
}

extension SearchFileRule {
    package var summary: String {
        switch self {
        case .name(let value, let matching): "Filename \(matching.title.lowercased()): \(value)"
        case .path(let value, let matching, let full): "\(full ? "Full path" : "Path") \(matching.title.lowercased()): \(value)"
        case .extensions(let values): "Extensions: " + values.joined(separator: ", ")
        case .tags(let values, let matching): "Tags · " + matching.title + ": " + values.joined(separator: ", ")
        case .size(let minimum, let maximum): "Size: " + [(minimum.isEmpty ? nil : "minimum " + minimum), (maximum.isEmpty ? nil : "maximum " + maximum)].compactMap { $0 }.joined(separator: "; ")
        case .date(let value):
            value.field.title + ": " + value.filters.datePeriodDescription
            + ([.before, .after, .custom].contains(value.period) ? " " + value.from.formatted(date: .abbreviated, time: .omitted) : "")
            + (value.period == .custom ? " through " + value.through.formatted(date: .abbreviated, time: .omitted) : "")
        case .expression(let value): "Name/path \(value.syntax.title.lowercased())\(value.exactName ? " (exact)" : ""): \(value.text)"
        }
    }
}

extension SearchContentRule {
    package var summary: String {
        switch self {
        case .allLines: "Any text line"
        case .literal(let value): "Literal: " + value
        case .regex(let value): "Regex: " + value
        case .documentText(let value): "Document text: " + value
        case .metadata(let field, let value): field.title + ": " + value
        case .proximity(let value): "Near words: " + value.terms.joined(separator: ", ") + " · within \(value.distance) intervening words" + (value.ordered ? " · in order" : "")
        }
    }
}

extension SearchRuleSet {
    package var title: String {
        let terms = expression.leaves.map(\.summary)
        return terms.isEmpty ? "All files" : terms.joined(separator: " · ")
    }
    package var parameterDescription: String {
        expression.description(\.summary) + (hasContents ? "\nContent conditions: " + contentUnit.title : "")
    }
}
