import SearchBackend
import SwiftUI

struct MatchContextView: View {
    @ObservedObject var viewModel: SearchViewModel
    let result: SearchResult
    @State private var preview: ContentPreview?
    @State private var loading = false
    @State private var snippetMatch = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.extractedOrigin?.location ?? "Line \(result.lineNumber ?? 1)").font(.headline)
                Spacer()
                if let position = viewModel.contentMatchPosition {
                    Text("\(position + 1) of \(viewModel.contentMatchCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    UtilityIconButton(title: "Previous match in this file", systemImage: "chevron.up") {
                        viewModel.moveContentMatch(by: -1)
                    }.disabled(position == 0)
                    UtilityIconButton(title: "Next match in this file", systemImage: "chevron.down") {
                        viewModel.moveContentMatch(by: 1)
                    }.disabled(position + 1 >= viewModel.contentMatchCount)
                }
            }
            if loading { ProgressView().controlSize(.small) }
            if (result.snippet?.utf16.count ?? 0) > 1_200, result.snippetMatchRanges.count > 1 {
                HStack {
                    Text("Highlight \(snippetMatch + 1) of \(result.snippetMatchRanges.count)").font(.caption)
                        .foregroundStyle(.secondary)
                    UtilityIconButton(title: "Previous highlight", systemImage: "chevron.left") {
                        snippetMatch = max(0, snippetMatch - 1)
                    }.disabled(snippetMatch == 0)
                    UtilityIconButton(title: "Next highlight", systemImage: "chevron.right") {
                        snippetMatch = min(result.snippetMatchRanges.count - 1, snippetMatch + 1)
                    }.disabled(snippetMatch + 1 >= result.snippetMatchRanges.count)
                }
            }
            if let preview, !preview.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(preview.lines) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(line.number)").foregroundStyle(.secondary).frame(
                                    minWidth: 30, alignment: .trailing)
                                if line.isMatch
                                    && (preview.warning == nil
                                        || preview.warning == "Long preview lines are shortened.")
                                {
                                    HighlightedSnippet(result: result, match: snippetMatch)
                                } else {
                                    Text(line.text.isEmpty ? " " : line.text)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)
                            .background(line.isMatch ? Color.accentColor.opacity(0.12) : .clear)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                }
            } else {
                HighlightedSnippet(result: result, match: snippetMatch)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            if let warning = preview?.warning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .task(id: "\(result.id)-\(viewModel.refinements.contextLines)-\(viewModel.refinements.textEncoding ?? "auto")")
        {
            preview = nil
            snippetMatch = 0
            loading = true
            let result = result
            let radius = viewModel.refinements.contextLines
            let extraction = viewModel.refinements.extraction ?? .init()
            let encoding = viewModel.refinements.textEncoding
            let task = Task.detached(priority: .userInitiated) {
                if let origin = result.extractedOrigin {
                    return try await DocumentAccess.preview(
                        .init(
                            path: result.path, origin: origin, extraction: extraction,
                            context: radius, expectedSnippet: result.snippet, encoding: encoding))
                }
                return try await ContentPreviewReader.readShared(
                    url: result.url, lineNumber: result.lineNumber ?? 1, expectedSnippet: result.snippet,
                    radius: radius, encoding: encoding)
            }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                guard !Task.isCancelled else { return }
                preview = loaded
            } catch {
                guard !Task.isCancelled else { return }
                preview = ContentPreview(lines: [], warning: "Could not load context: \(error.localizedDescription)")
            }
            loading = false
        }
    }
}
