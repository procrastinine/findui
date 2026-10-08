import SearchBackend
import AppKit
import SwiftUI

// Uses the same scene/command setup as the app, with a disposable library.
@main
struct WindowCommandAudit: App {
    @NSApplicationDelegateAdaptor(WindowCommandAuditDelegate.self) private var delegate
    var body: some Scene {
        Settings { Text("FindUI window audit settings").padding().frame(width: 400, height: 150) }
            .commands { SearchWindowCommands(windows: delegate.windows) }
    }
}

@MainActor
final class WindowCommandAuditDelegate: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FindUI-Window-Audit-\(UUID())")
    let previousApplication = NSWorkspace.shared.frontmostApplication
    var lastWindowClosed = false
    lazy var windows: SearchWindowManager = {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = SearchLibraryStore(persistence: AppPersistence(baseDirectory: root.appendingPathComponent("library")))
        library.value.defaultSearchDirectoryPath = root.path
        return SearchWindowManager(libraryStore: library, loadSavedState: false,
            onLastWindowClosed: { [weak self] in self?.lastWindowClosed = true })
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { exit(2) }
        Task { @MainActor in
            defer { previousApplication?.activate(options: []); try? FileManager.default.removeItem(at: root) }
            do {
                let first = windows.newWindow()
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(400))
                print("Initial activation: active=\(NSApp.isActive), key=\(NSApp.keyWindow === first)")
                let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.windowNumber,
                    context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                guard NSApplication.shared.mainMenu?.performKeyEquivalent(with: space) != true else {
                    throw failure("A global Space shortcut would intercept text entry.")
                }
                try await shortcut("n", keyCode: 45)
                guard windows.windows.count == 2 else { throw failure("Command-N did not open a second window.") }
                let second = windows.windows.last!
                print("New window activation: active=\(NSApp.isActive), key=\(NSApp.keyWindow === second)")
                guard first.tabGroup !== second.tabGroup || first.tabGroup == nil else {
                    throw failure("Command-N incorrectly created a tab.")
                }
                try await shortcut("t", keyCode: 17)
                guard windows.windows.count == 3, second.tabGroup?.windows.count == 2 else {
                    throw failure("Command-T did not create a native tab in the active window.")
                }
                let tab = windows.windows.last!
                print("New tab activation: active=\(NSApp.isActive), key=\(NSApp.keyWindow === tab), visible=\(tab.isVisible), canBecomeKey=\(tab.canBecomeKey), selected=\(tab.tabGroup?.selectedWindow === tab)")
                guard windows.activeViewModel === windows.viewModel(for: tab) else {
                    throw failure("Commands did not follow the selected tab.")
                }
                guard NSApplication.shared.keyWindow === tab else {
                    throw failure("New Tab did not make its native window key: key=\(String(describing: NSApplication.shared.keyWindow)), tab=\(tab).")
                }
                try await shortcut("w", keyCode: 13)
                guard windows.windows.count == 2, windows.windows.contains(where: { $0 === first }), !lastWindowClosed else {
                    throw failure("Command-W did not close only the selected tab: count=\(windows.windows.count), first=\(windows.windows.contains(where: { $0 === first })), tabStillOpen=\(windows.windows.contains(where: { $0 === tab })), finalClose=\(lastWindowClosed).")
                }
                // Settings must never join the search tab group or keep an
                // otherwise closed app alive.
                try await shortcut(",", keyCode: 43)
                guard NSApplication.shared.windows.contains(where: { $0.isVisible && !windows.windows.contains($0) }) else {
                    throw failure("Command-comma did not open Settings.")
                }
                for window in windows.windows { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                guard lastWindowClosed else { throw failure("Settings prevented final search-window close handling.") }
                await windows.libraryStore.flush()
                print("Command-N, Command-T, Command-W, Settings, independent native tab groups, and final search-window close passed.")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }

    private func shortcut(_ character: String, keyCode: UInt16) async throws {
        // A user sends these shortcuts to the foreground app. Tool-driven
        // launches can lose activation to the caller between assertions.
        try await requireActivation("before Command-\(character)")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApplication.shared.keyWindow?.windowNumber ?? 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
        guard NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) == true else {
            throw failure("No enabled menu action for Command-\(character).")
        }
        try await Task.sleep(for: .milliseconds(300))
        // Restore the foreground precondition before asserting key-window
        // behavior too. Do not make a particular window key: the command must
        // have selected the correct one, which the caller still verifies.
        try await requireActivation("after Command-\(character)")
    }

    private func requireActivation(_ context: String) async throws {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<20 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard NSApp.isActive else { throw failure("macOS did not activate the audit \(context).") }
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "FindUIWindowAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
