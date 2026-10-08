import SearchBackend
import AppKit
import SwiftUI

/// Keep the glyphs, insertion point, and search/cancel icons in one native control.
struct SearchInputView: NSViewRepresentable {
    @Binding var text: String
    // One selection shared by both inputs: two outlines can never be active.
    @Binding var focusedInput: String?
    var focusRequest = 0
    var placeholder = "Search files or contents"
    var identifier = "searchInput"
    var accessibilityLabel = "Search query"
    var completionProvider: (@MainActor @Sendable (String) async -> [String])?
    @Environment(\.isEnabled) private var isEnabled
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusReportingSearchField {
        let field = FocusReportingSearchField()
        field.cell = SearchInputCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: 17)
        field.stringValue = text
        field.controlSize = .large
        field.isBezeled = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.sendsWholeSearchString = true
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator else { return }
            let parent = coordinator.parent
            if focused {
                if parent.focusedInput != parent.identifier { parent.focusedInput = parent.identifier }
            } else if parent.focusedInput == parent.identifier {
                parent.focusedInput = nil
            }
        }
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier(identifier)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: FocusReportingSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.isEnabled = isEnabled
        field.isEditable = isEnabled
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.refreshCompletions()
        if context.coordinator.focusRequest != focusRequest && isEnabled {
            context.coordinator.focusRequest = focusRequest
            // Wait until the representable has joined its window.
            Task { @MainActor [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
                field.reportFocus()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusReportingSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: 46)
    }

    static func dismantleNSView(_ field: FocusReportingSearchField, coordinator: Coordinator) {
        // An outgoing field's delayed responder callback must not change the
        // focus of the replacement fields after switching Rules/Simple.
        field.onFocusChange = nil
        field.delegate = nil
        field.target = nil
        coordinator.completionTask?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchInputView
        var focusRequest: Int
        weak var field: NSSearchField?
        var completionTask: Task<Void,Never>?
        var completionQuery = ""
        var completions: [String] = []
        init(parent: SearchInputView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            refreshCompletions()
        }

        func refreshCompletions() {
            guard let field else { return }
            let text = field.stringValue
            guard parent.completionProvider != nil else { completionTask?.cancel(); field.searchMenuTemplate = nil; completions = []; completionQuery = ""; return }
            guard text != completionQuery else { return }
            completionQuery = text; completionTask?.cancel(); completions = []
            field.searchMenuTemplate = nil
            guard text.count >= 2, let provider = parent.completionProvider else { return }
            completionTask = Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(200))
                guard !Task.isCancelled else { return }
                let values = await provider(text)
                guard let self, !Task.isCancelled, self.field?.stringValue == text else { return }
                self.completions = values
                guard !values.isEmpty else { return }
                let menu = NSMenu(title:"Word suggestions")
                let title = NSMenuItem(title:"Word suggestions",action:nil,keyEquivalent:""); title.isEnabled = false
                menu.addItem(title)
                for value in values {
                    let item = NSMenuItem(title:value,action:#selector(self.acceptCompletion(_:)),keyEquivalent:"")
                    item.target = self; item.representedObject = value; menu.addItem(item)
                }
                self.field?.searchMenuTemplate = menu
            }
        }

        @objc func acceptCompletion(_ item: NSMenuItem) {
            guard let value = item.representedObject as? String, let field else { return }
            field.stringValue = value; parent.text = value
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location:value.utf16.count,length:0) }
            parent.onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            guard range.location == 0, range.length == textView.string.utf16.count else { return [] }
            return completions
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? FocusReportingSearchField)?.reportFocus()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? FocusReportingSearchField)?.reportFocus()
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}

/// Editing notifications start with the first keystroke, not the first click.
/// Report actual responder ownership without requesting focus again on redraw.
final class FocusReportingSearchField: NSSearchField {
    var onFocusChange: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        reportFocus()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        reportFocus()
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        reportFocus()
    }

    func reportFocus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let window else { onFocusChange?(false); return }
            let responder = window.firstResponder
            onFocusChange?(responder === self || (currentEditor() != nil && responder === currentEditor()))
        }
    }
}

/// Suppress only the intrinsic-height bezel. Keep the native cell's editing
/// geometry, which is different for a borderless NSTextField.
private final class SearchInputCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.searchTextRect(forBounds: rect)
        textRect.origin.x += 10
        textRect.size.width = max(0, textRect.width - 10)
        return textRect
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}
