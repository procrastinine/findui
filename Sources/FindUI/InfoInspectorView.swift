import SearchBackend
import QuickLookUI
import SwiftUI

struct InfoInspectorView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var showsFilePreview = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Inspector")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.selectedResults.count > 1 {
                        Text("\(viewModel.selectedResults.count) selected; showing the first result.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let result = viewModel.selectedResult {
                        if let origin = result.extractedOrigin {
                            if let member = origin.memberPath { infoSection("Archive member", value: member) }
                            if origin.metadataOnly == true {
                                Text(origin.location).font(.caption).foregroundStyle(.secondary)
                            } else { MatchContextView(viewModel: viewModel, result: result) }
                            if let title = origin.documentTitle, !title.isEmpty { infoSection("Document title", value: title) }
                            if let author = origin.author, !author.isEmpty { infoSection("Author", value: author) }
                            if origin.memberPath != nil && origin.memberKind != "directory" && origin.metadataOnly != true {
                                Button("Open Extracted Copy") { viewModel.openResult(result) }.nativePrimaryButtonStyle()
                                    .help("Opens this member in a temporary file. Changes to the copy do not update the archive.")
                            }
                            if origin.page != nil {
                                DocumentMatchPreview(result: result, extraction: viewModel.refinements.extraction ?? .init())
                            }
                        }
                        if let line = result.lineNumber {
                            MatchContextView(viewModel: viewModel, result: result)
                            Button("Open in Editor at Line \(line)") { viewModel.openInEditor(result) }
                                .nativePrimaryButtonStyle()
                            ExpandableSection("File Preview", isExpanded: $showsFilePreview, identifier: "inspectorFilePreview") {
                                preview(result.url)
                            }
                        } else if result.extractedOrigin == nil {
                            preview(result.url)
                        }
                        Divider()
                        infoSection("Name", value: result.displayName)
                        infoSection("Kind", value: result.typeDescription ?? result.kind.title)
                        infoSection("Path", value: result.path, monospace: true)
                        if let date = result.createdAt {
                            infoSection(ResultMetadataLabels.created, value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let date = result.modifiedAt {
                            infoSection(ResultMetadataLabels.modified, value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let date = result.addedAt {
                            infoSection(ResultMetadataLabels.added, value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let date = result.lastOpenedAt {
                            infoSection(ResultMetadataLabels.lastOpened, value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let size = result.size {
                            infoSection("Size", value: ByteCountFormatStyle().format(size))
                        }
                        Divider()
                        HStack(spacing: 10) {
                            Button(ResultPresentationLabels.showInFinder) { viewModel.revealSelected() }
                            Button(ResultPresentationLabels.copyPath) { viewModel.copySelectedPath() }
                            Button { viewModel.openTerminal(for: result) } label: {
                                Image(systemName: "terminal").frame(width: 18, height: 18)
                            }
                            .help("Open \(FolderActions.terminalDirectory(for: result).path) in Terminal")
                            .accessibilityLabel(result.kind == .folder && result.extractedOrigin?.memberPath == nil
                                ? "Open folder in Terminal" : "Open containing folder in Terminal")
                            .accessibilityIdentifier("openInspectorTerminal")
                        }
                        .nativeUtilityButtonStyle()
                    } else {
                        Text("Select a result to inspect it.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .nativeUtilityButtonStyle()
    }

    private func preview(_ url: URL) -> some View {
        InspectorQuickLookPreview(url: url)
            .frame(height: 220)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func infoSection(_ label: String, value: String, monospace: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? .system(size: 12, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InspectorQuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if nsView.previewItem?.previewItemURL != url {
            nsView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}
