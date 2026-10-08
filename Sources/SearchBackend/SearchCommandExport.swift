import Foundation

/// A comment allows a compiled multi-tool command to restore its controls.
/// Import regenerates the complete script and requires an exact match. Neither
/// the pasted shell program nor its executable paths are used for execution.
package struct SearchCommandExport: Codable, Sendable {
    private static let prefix = "# FindUI search v1: "
    package static func isWrappedExport(_ input: String) -> Bool {
        (input.hasPrefix("/bin/bash ") || input.hasPrefix("'/bin/bash' ")) && input.contains(prefix)
    }
    package let state: SearchState
    package let referenceDate: Date
    package let tools: Toolchain
    /// Request-level options also affect execution and must survive import.
    /// Omit ordinary defaults so simple commands and existing exports stay small.
    private let execution: ExecutionOptions?

    private struct ExecutionOptions: Codable, Sendable {
        var statistics: Bool
        var browse: Bool
        var buildContents: Bool
        var buildWords: Bool
        var excludeDerived: Bool
        var metadata: Bool
        init(_ request: SearchRequest) {
            statistics = request.collectStatistics; browse = request.isDirectoryListing
            buildContents = request.buildContentIndex; buildWords = request.buildWordIndex
            excludeDerived = request.excludesDerivedContent; metadata = request.includeMetadata
        }
        var isDefault: Bool { !statistics && !browse && !buildContents && !buildWords && !excludeDerived && !metadata }
        func apply(to request: inout SearchRequest) {
            request.collectStatistics = statistics; request.isDirectoryListing = browse
            request.buildContentIndex = buildContents; request.buildWordIndex = buildWords
            request.excludesDerivedContent = excludeDerived; request.includeMetadata = metadata
        }
    }

    package static func needsExecutionMetadata(_ request: SearchRequest) -> Bool { !ExecutionOptions(request).isDefault }

    package init(_ request: SearchRequest, tools: Toolchain) {
        var state = request.state
        state.sourceCommand = nil
        // Drive selection is presentation state; it does not change this live
        // search's explicitly recorded scope. Do not encode a changing clock
        // when no condition uses it, so identical searches export identically.
        state.selectedDrivePath = nil
        let periods = state.ruleSet?.fileLeaves.compactMap { rule -> SearchDatePeriod? in
            if case .date(let date) = rule { return date.period }
            return nil
        } ?? [state.filters.datePeriod]
        let relative = periods.contains { [.today, .yesterday, .week, .month, .year, .recentDays, .recentCalendar].contains($0) }
        self.state = state
        referenceDate = relative ? request.referenceDate : Date(timeIntervalSince1970: 0)
        var relevantTools = tools
        if state.refinements.extraction == nil {
            // GUI inventory discovery and lightweight CLI discovery must not
            // serialize different, unused document-reader configurations.
            relevantTools.rgaPreproc = nil; relevantTools.pandoc = nil; relevantTools.pdftotext = nil
            relevantTools.pdfdetach = nil; relevantTools.tikaJar = nil
            relevantTools.ffmpeg = nil; relevantTools.ffprobe = nil
        }
        self.tools = relevantTools
        let options = ExecutionOptions(request)
        execution = options.isDefault ? nil : options
    }

    package func header() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.prefix + (try encoder.encode(self)).base64EncodedString() + "\n"
    }

    package static func restore(_ input: String) throws -> SearchState? {
        guard let descriptor = try decode(input) else { return nil }
        var state = descriptor.state
        state.sourceCommand = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return state
    }

    /// Reuse the parsed search's clock and request options only while the
    /// controls still describe it. Both forms are compared through the same
    /// normalizer that execution uses. The original shell text is never replayed.
    package static func restoringContext(_ request: SearchRequest) -> SearchRequest {
        guard let source = request.state.sourceCommand,
              let descriptor = try? decode(source) else { return request }
        var candidate = request
        candidate.state.sourceCommand = nil
        candidate.state.selectedDrivePath = nil
        candidate.referenceDate = descriptor.referenceDate
        var original = SearchRequest(state: descriptor.state, maxResults: request.maxResults, referenceDate: descriptor.referenceDate)
        descriptor.execution?.apply(to: &original)
        descriptor.execution?.apply(to: &candidate)
        let matches: Bool
        if original.state.nativeCommand != nil || candidate.state.nativeCommand != nil || descriptor.execution?.browse == true {
            candidate.state.filters.dateFrom = original.state.filters.dateFrom
            candidate.state.filters.dateThrough = original.state.filters.dateThrough
            matches = candidate.state == original.state
        } else {
            let expected = try? original.normalizedQuery()
            matches = expected != nil && (try? candidate.normalizedQuery()) == expected
        }
        guard matches else { return request }
        // Explicit execution options on a new request can add diagnostics, etc.
        // An ordinary import has defaults and restores the recorded options.
        if needsExecutionMetadata(request) { ExecutionOptions(request).apply(to: &original) }
        return original
    }

    private static func decode(_ input: String) throws -> Self? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/bin/bash ") || trimmed.hasPrefix("'/bin/bash' ") else { return nil }
        let tokens = try CLICommandParser.tokenize(trimmed)
        guard tokens.count == 1, let command = tokens.first, command.count == 5,
              Array(command.prefix(4)) == ["/bin/bash", "--noprofile", "--norc", "-c"],
              command[4].hasPrefix(prefix) else { return nil }
        let script = command[4]
        guard let end = script.firstIndex(of: "\n"),
              let encoded = Data(base64Encoded: String(script[script.index(script.startIndex, offsetBy: prefix.count)..<end])),
              encoded.count <= 256 * 1024 else {
            throw SearchServiceError.commandFailed("The FindUI command has invalid search metadata.")
        }
        let descriptor = try JSONDecoder().decode(Self.self, from: encoded)
        guard !descriptor.state.useIndex, descriptor.state.sourceCommand == nil,
              descriptor.referenceDate.timeIntervalSince1970.isFinite else {
            throw SearchServiceError.commandFailed("This exported search cannot be restored as a live search.")
        }
        let allowed: [(URL?, Set<String>)] = [
            (descriptor.tools.fd, ["fd", "fdfind"]), (descriptor.tools.rg, ["rg"]),
            (descriptor.tools.fzf, ["fzf"]), (descriptor.tools.find, ["find"]),
            (descriptor.tools.mdfind, ["mdfind"]), (descriptor.tools.contentWorker, ["findui-content"]),
            (descriptor.tools.rgaPreproc, ["rga-preproc"]), (descriptor.tools.pandoc, ["pandoc"]),
            (descriptor.tools.pdftotext, ["pdftotext"]),
            (descriptor.tools.pdfdetach, ["pdfdetach"]),
            (descriptor.tools.tikaJar, descriptor.tools.tikaJar.map { [$0.lastPathComponent] } ?? [])
        ]
        guard allowed.allSatisfy({ url, names in
            guard let url else { return true }
            return url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") && names.contains(url.lastPathComponent)
        }) else {
            throw SearchServiceError.commandFailed("The FindUI command names an unsupported search tool.")
        }
        var request = SearchRequest(state: descriptor.state, referenceDate: descriptor.referenceDate)
        descriptor.execution?.apply(to: &request)
        let regenerated = try SearchPipelineCompiler(tools: descriptor.tools).compile(request, includeCommandMetadata: false)
        // Older exports wrapped even ordinary GUI searches. Validate their
        // recorded context and regenerated command independently of whether a
        // new export still needs that wrapper.
        let expected = try Self(request, tools: descriptor.tools).header() + regenerated.executionScript
        guard expected == script else {
            throw SearchServiceError.commandFailed("This FindUI command was edited and no longer matches its search options. Paste the original export, or import a plain fd, rg, or find command.")
        }
        // The app compiles this state again using its own resolved tools. It
        // never executes command[4] or trusts executable paths from the paste.
        return descriptor
    }
}
