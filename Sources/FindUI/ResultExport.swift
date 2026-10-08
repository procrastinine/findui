import SearchBackend
import AppKit
import Foundation

@MainActor
enum ResultTransfer {
    static func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    @discardableResult
    static func copyFiles(_ results: [SearchResult], to pasteboard: NSPasteboard) -> Bool {
        let urls = ResultExport.uniqueURLs(results)
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
