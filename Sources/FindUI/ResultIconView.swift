import SearchBackend
import AppKit
import SwiftUI

struct ResultIconView: View {
    let result: SearchResult

    var body: some View {
        Image(nsImage: FileIconCache.shared.icon(for: result))
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
    }
}

@MainActor
private final class FileIconCache {
    static let shared = FileIconCache()

    private var icons: [String: NSImage] = [:]

    func icon(for result: SearchResult) -> NSImage {
        let key = result.url.path
        if let cached = icons[key] {
            return cached
        }

        let image = NSWorkspace.shared.icon(forFile: result.url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[key] = image
        return image
    }
}
