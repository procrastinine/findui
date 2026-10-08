import SearchBackend
import AppKit
import SwiftUI

/// Preserve the command's edge-to-edge hover emphasis over the native bezel.
/// The system still owns the button's pressed, disabled and glass appearance.
struct CommandHoverHighlight: ViewModifier {
    var isActive = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let highlighted = isEnabled && (isHovered || isActive)
        content
            .buttonBorderShape(.roundedRectangle(radius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(highlighted ? (contrast == .increased ? 0.24 : 0.16) : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

extension View {
    @ViewBuilder func nativeUtilityButtonStyle() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) }
        else { buttonStyle(.bordered) }
    }

    /// Let the OS draw the primary action, with its normal older-macOS fallback.
    @ViewBuilder func nativePrimaryButtonStyle() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) }
        else { buttonStyle(.borderedProminent) }
    }
}

/// One native treatment for small navigation, dismiss, and utility controls.
/// Keep the symbol box constant so pressed/disabled states cannot change layout.
struct UtilityIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14, height: 14)
        }
        .nativeUtilityButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// The entire header is a button, including the label and space beside it.
/// Own the indentation here so expanded rows stay inside their parent's width.
struct ExpandableSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let identifier: String
    @ViewBuilder let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title; _isExpanded = isExpanded; self.identifier = identifier; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(identifier)

            if isExpanded {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCommandRow: View {
    let title: String
    let command: String
    let identifier: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                UtilityIconButton(title: copied ? "Copied" : "Copy \(title.lowercased()) command",
                                  systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(command, forType: .string)
                }
                .accessibilityIdentifier(identifier)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false }
            catch { }
        }
    }
}

/// Menu triggers use a pop-up cell on macOS, which ignores .glass buttonStyle.
/// Keep the native menu and its tracking; let the system draw its glass surface.
struct NativeUtilityMenuStyle: MenuStyle {
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            Menu(configuration)
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 6))
        } else {
            Menu(configuration).menuStyle(.button).buttonStyle(.bordered)
        }
    }
}

struct PaneHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// A native pop-up button, including its keyboard behavior, menu, and bezel.
struct UtilityPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let label: (Value) -> String

    var body: some View {
        if #available(macOS 26, *) {
            control.padding(.horizontal, 6)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 6))
        } else { control }
    }

    private var control: some View {
        NativeUtilityPopUp(title: title, selection: $selection, values: values, label: label)
    }
}

private struct NativeUtilityPopUp<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let label: (Value) -> String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.font = .systemFont(ofSize: 12)
        button.controlSize = .regular
        if #available(macOS 26, *) { button.isBordered = false }
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel(title)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = values.map(label)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.selectItem(at: values.firstIndex(of: selection) ?? 0)
        button.isEnabled = isEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 28)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: NativeUtilityPopUp
        init(_ parent: NativeUtilityPopUp) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            guard parent.values.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.values[sender.indexOfSelectedItem]
        }
    }
}
