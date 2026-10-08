import SwiftUI
import SearchBackend

struct SearchExplanationView: View {
    let report: SearchExplanation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why this file?").font(.headline)
            Text(report.path).font(.caption).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.passed ? "checkmark.circle" : "minus.circle").foregroundStyle(step.passed ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).fontWeight(.medium)
                                Text(step.detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if !report.command.isEmpty {
                    Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.command, forType: .string) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500, height: 420)
            .background(Color(nsColor: .windowBackgroundColor)).nativeUtilityButtonStyle()
    }
}
