import SearchBackend
import AppKit
import SwiftUI

/// macOS exposes no public Full Disk Access request/status API. The user grants
/// access in System Settings; do not infer it by probing unrelated private files.
struct FullDiskAccessControls: View {
    @State private var settingsOpenFailed = false

    private var applicationURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow FindUI to search protected locations, including Mail and backups. Enable FindUI in System Settings → Privacy & Security → Full Disk Access.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Open Full Disk Access…") { openSettings() }
                    .accessibilityIdentifier("openFullDiskAccess")
                Button("Show FindUI in Finder") {
                    if let applicationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
                    }
                }
                .disabled(applicationURL == nil)
                .accessibilityIdentifier("revealFindUIApplication")
                .help("Show the running copy of FindUI to add in System Settings.")
            }
            .nativeUtilityButtonStyle()

            Text("If FindUI isn’t listed, click + and select the app shown in Finder. After enabling access, quit and reopen FindUI, then reload your search or rebuild any partial index.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if applicationURL == nil {
                Text("Open the packaged FindUI.app to grant access to the app.")
                    .font(.footnote)
            }
            if settingsOpenFailed {
                Text("Couldn’t open System Settings. Open it from the Apple menu, then choose Privacy & Security → Full Disk Access.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openSettings() {
        let links = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        ]
        for link in links {
            if let url = URL(string: link), NSWorkspace.shared.open(url) {
                settingsOpenFailed = false
                return
            }
        }
        settingsOpenFailed = true
    }
}

struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Full Disk Access", systemImage: "folder.badge.questionmark")
                .font(.title2.weight(.semibold))
            Text("A search location couldn’t be read. Full Disk Access can allow searches in locations protected by macOS. File ownership and other access restrictions still apply.")
                .font(.system(size: 12))
            FullDiskAccessControls()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .nativeUtilityButtonStyle()
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

enum FileAccessFailure {
    static func matches(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("operation not permitted") || message.contains("permission denied")
    }

    static func matches(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        return matches(error.localizedDescription)
    }
}
