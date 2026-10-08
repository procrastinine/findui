import SearchBackend
import SwiftUI
import PDFKit

struct DocumentMatchPreview: View {
    let result: SearchResult
    let extraction: SearchExtractionOptions
    @State private var url: URL?
    @State private var error: String?
    var body: some View {
        Group {
            if let url { PDFMatchView(url: url, page: result.extractedOrigin?.page ?? 1).frame(height: 300) }
            else if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small).frame(height: 80) }
        }
        .task(id: result.documentIdentity + (result.extractedOrigin?.sourceIdentity ?? "")) {
            url = nil; error = nil
            do {
                if let origin = result.extractedOrigin, origin.memberPath != nil {
                    let loaded = try await DocumentMaterializer.shared.file(.init(path: result.path, origin: origin, extraction: extraction))
                    if !Task.isCancelled { url = loaded }
                } else { url = result.url }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct PDFMatchView: NSViewRepresentable {
    let url: URL
    let page: Int
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        if let target = view.document?.page(at: max(0, page - 1)) { view.go(to: target) }
    }
}
