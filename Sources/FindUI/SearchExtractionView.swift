import AppKit
import SearchBackend
import SwiftUI

/// The everyday control. Converter setup and cache maintenance live in Settings.
struct SearchExtractionView: View {
    @Binding var options: SearchExtractionOptions?
    @State private var hasCustomReaders = false
    @State private var previousOptions: SearchExtractionOptions?

    private func enabled(_ key: WritableKeyPath<SearchExtractionOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { options?[keyPath: key] ?? false },
            set: { enabled in
                var value = options ?? previousOptions ?? .init()
                if options == nil {
                    value.documents = false
                    value.archives = false
                    value.media = false
                    value.customReaders = false
                }
                value[keyPath: key] = enabled
                previousOptions = value
                options = value.documents || value.archives || value.media || value.customReaders ? value : nil
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Search inside documents", isOn: enabled(\.documents))
                .accessibilityIdentifier("searchExtractedText")
                .help(
                    "Includes PDF, Office, e-books, email, mailboxes and SQLite tables when searching Contents. Set up readers in Settings → Tools. Scanned images need an existing text layer."
                )
            Toggle("Media metadata and subtitles", isOn: enabled(\.media))
                .accessibilityIdentifier("searchMedia")
                .help(
                    "Reads media headers and text subtitles using FFmpeg. Does not transcribe audio or recognize images. Set up in Settings → Tools."
                )
            if hasCustomReaders || options?.customReaders == true {
                Toggle("Use custom readers", isOn: enabled(\.customReaders))
                    .accessibilityIdentifier("searchCustomReaders")
                    .help("Runs enabled programs configured in Settings → Tools for their selected file types.")
            }
            Toggle("Expand archives and attachments", isOn: enabled(\.archives))
                .accessibilityIdentifier("searchArchives")
                .help(
                    "Opt in to decompress archives and installer packages, and read email and PDF attachments in this scope. Also applies when preparing the content index."
                )
        }
        .task { reloadReaders() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderConfiguration.didChange)) { _ in reloadReaders() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadReaders()
        }
    }

    private func reloadReaders() {
        hasCustomReaders = (try? ReaderConfiguration().load().contains(where: \.enabled)) == true
    }
}

/// Advanced per-search overrides remain part of the headless search state.
struct SearchExtractionLimitsView: View {
    @Binding var options: SearchExtractionOptions?
    private var settings: Binding<SearchExtractionOptions> {
        Binding(get: { options ?? .init() }, set: { options = $0 })
    }
    var body: some View {
        if options != nil {
            Toggle("Reuse cached document text", isOn: settings.cacheText)
                .help(
                    "Stores extracted text locally to avoid converting unchanged documents again. Clear it in Settings → Tools."
                )
            HStack {
                Text("Document timeout")
                TextField("Seconds", value: settings.timeoutSeconds, format: .number).frame(width: 60)
                    .accessibilityLabel("Document timeout seconds")
                Text("seconds")
                Spacer()
                Text("Text limit")
                TextField("MiB", value: settings.maximumMegabytes, format: .number).frame(width: 60)
                    .accessibilityLabel("Maximum extracted megabytes")
                Text("MiB per file")
            }
            if settings.wrappedValue.archives {
                Stepper(
                    "Archive nesting depth: \(settings.wrappedValue.maximumArchiveDepth)",
                    value: settings.maximumArchiveDepth, in: 0...10
                )
                .help("Limits nested archive expansion. Incomplete searches are reported with the results.")
            }
            if settings.wrappedValue.documents && !settings.wrappedValue.useTika {
                HStack {
                    Text("Additional Office formats are disabled.").foregroundStyle(.secondary)
                    Button("Include all document formats") { settings.wrappedValue.useTika = true }
                }
            }
        }
    }
}
