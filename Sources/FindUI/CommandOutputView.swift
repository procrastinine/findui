import AppKit
import SwiftUI
import SearchBackend

struct CommandOutputView: View {
    let output: CommandTextOutput
    let failure: String?
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Command Output").fontWeight(.semibold)
                Spacer()
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
                .disabled(output.text.isEmpty)
                .nativeUtilityButtonStyle()
            }
            .font(.system(size: 12)).padding(.horizontal, 12).frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor))
            if let failure { CommandFailureView(message: failure) }
            if output.text.isEmpty {
                Text(isRunning ? "Waiting for output…" : failure == nil ? "Command finished without output." : "No output.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(output.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("commandOutputText")
            }
            if output.isTruncated {
                Text("Showing the first 1 MiB. Run the copied command in Terminal for complete output.")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("commandOutputPane")
    }
}

struct CommandFailureView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command failed", systemImage: "exclamationmark.triangle").font(.headline)
            ScrollView {
                Text(message).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("commandFailure")
    }
}
