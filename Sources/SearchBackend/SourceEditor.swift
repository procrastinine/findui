import Foundation

package enum SourceEditor: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, vscode, vscodeInsiders, cursor, vscodium

    package var id: Self { self }
    package var title: String {
        switch self {
        case .automatic: "Automatic"
        case .vscode: "Visual Studio Code"
        case .vscodeInsiders: "Visual Studio Code Insiders"
        case .cursor: "Cursor"
        case .vscodium: "VSCodium"
        }
    }
    package var bundleIdentifier: String {
        switch self {
        case .automatic: ""
        case .vscode: "com.microsoft.VSCode"
        case .vscodeInsiders: "com.microsoft.VSCodeInsiders"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .vscodium: "com.vscodium"
        }
    }
    private var scheme: String {
        switch self {
        case .automatic, .vscode: "vscode"
        case .vscodeInsiders: "vscode-insiders"
        case .cursor: "cursor"
        case .vscodium: "vscodium"
        }
    }

    package func fileURL(_ file: URL, line: Int) -> URL? {
        guard self != .automatic, file.isFileURL, line > 0 else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~"))
        guard let path = file.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        components.percentEncodedPath = "\(path):\(line)"
        return components.url
    }

}
