import SearchBackend
import AppKit
import QuickLookUI
import SwiftUI

struct QuickLookSheet: View {
    let url: URL
    let title: String
    let subtitle: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                UtilityIconButton(title: "Close preview", systemImage: "xmark", action: onClose)
                    .accessibilityIdentifier("closeQuickLook")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    UtilityIconButton(title: "Previous result", systemImage: "chevron.up", action: onMoveUp)
                        .disabled(!canMoveUp)
                        .accessibilityIdentifier("previousQuickLookResult")
                    UtilityIconButton(title: "Next result", systemImage: "chevron.down", action: onMoveDown)
                        .disabled(!canMoveDown)
                        .accessibilityIdentifier("nextQuickLookResult")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            QuickLookView(
                url: url,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onClose: onClose
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .nativeUtilityButtonStyle()
        .onExitCommand(perform: onClose)
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> InteractiveQuickLookView {
        let view = InteractiveQuickLookView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = true
        view.autostarts = true
        view.show(url)
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: InteractiveQuickLookView, context: Context) {
        nsView.show(url)
        nsView.onMoveUp = onMoveUp
        nsView.onMoveDown = onMoveDown
        nsView.onClose = onClose
    }

    static func dismantleNSView(_ nsView: InteractiveQuickLookView, coordinator: ()) {
        nsView.onMoveUp = {}; nsView.onMoveDown = {}; nsView.onClose = {}
        nsView.close()
    }
}

private final class InteractiveQuickLookView: QLPreviewView {
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onClose: () -> Void = {}
    private var displayedURL: URL?

    func show(_ url: URL) {
        guard displayedURL != url else { return }
        displayedURL = url
        previewItem = url as NSURL
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            onMoveUp()
        case 125:
            onMoveDown()
        case 49, 53:
            onClose()
        default:
            super.keyDown(with: event)
        }
    }

    func ensureFirstResponder() {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}
