import AppKit
import SearchBackend

extension SourceEditor {
    @MainActor
    func installedApplication() -> (editor: SourceEditor, application: URL)? {
        let choices = self == .automatic ? Self.allCases.filter { $0 != .automatic } : [self]
        for editor in choices {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) {
                return (editor, app)
            }
        }
        return nil
    }
}
