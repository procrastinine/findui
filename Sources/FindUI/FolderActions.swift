import AppKit
import SearchBackend

/// Desktop actions belong to the app, independent of search execution.
@MainActor
enum FolderActions {
    static func terminalDirectory(for result: SearchResult) -> URL {
        // Archive members refer to the containing archive on disk, even when
        // the member itself is a directory. Opening Terminal must not extract it.
        result.kind == .folder && result.extractedOrigin?.memberPath == nil
            ? result.url : result.url.deletingLastPathComponent()
    }

    static func openTerminal(at directory: URL) async throws {
        try validate(directory)
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw failure("Terminal could not be found.")
        }
        // Terminal handles directory URLs by opening a shell in that directory.
        // No shell command interpolation or Apple Events permission is needed.
        _ = try await NSWorkspace.shared.open([directory], withApplicationAt: application, configuration: .init())
    }

    static func openFinder(at directory: URL) throws {
        try validate(directory)
        guard NSWorkspace.shared.open(directory) else {
            throw failure("Could not open this folder in Finder: \(directory.path)")
        }
    }

    private static func validate(_ directory: URL) throws {
        var isDirectory = ObjCBool(false)
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw failure("Folder not found: \(directory.path)")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FindUI.FolderActions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
