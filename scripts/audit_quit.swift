import AppKit
import SearchBackend
import SwiftUI

// The production delegate owns termination. Only fixture setup and the input
// action differ here; an external launcher verifies that the process exits.
@main struct QuitAudit: App {
    @NSApplicationDelegateAdaptor(QuitAuditDelegate.self) private var delegate
    var body: some Scene {
        Settings { Text("Quit audit settings").padding() }
            .commands { SearchWindowCommands(windows: delegate.windows) }
    }
}

@MainActor final class QuitAuditDelegate: FindUIApplicationDelegate {
    private let mode = CommandLine.arguments.dropFirst().first ?? "command-q"
    private var requestedAt: ContinuousClock.Instant?

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)
        let samplePath = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]! + "/quit.sample"
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "1", "-file", samplePath]
            sample.standardOutput = FileHandle.nullDevice
            sample.standardError = FileHandle.nullDevice
            try? sample.run()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
            FileHandle.standardError.write(Data("FAIL: quit did not exit within 12 seconds.\n".utf8))
            exit(2)
        }
        Task { @MainActor in
            do {
                _ = try await windows.libraryStore.load()
                try await Task.sleep(for: .milliseconds(500))
                guard let first = windows.windows.first else { throw failure("Missing search window.") }
                if mode == "settings-close" {
                    try await shortcut(",", keyCode: 43)
                    try await Task.sleep(for: .milliseconds(200))
                    guard NSApp.windows.contains(where: { $0.isVisible && !windows.windows.contains($0) }) else {
                        throw failure("Settings did not open.")
                    }
                }
                if mode == "multiple-windows" {
                    let other = windows.newWindow()
                    first.miniaturize(nil)
                    other.standardWindowButton(.closeButton)!.performClick(nil)
                    try await Task.sleep(for: .milliseconds(150))
                    guard windows.windows.count == 1, first.isMiniaturized else {
                        throw failure("Closing one window lost the minimized search window.")
                    }
                    first.deminiaturize(nil)
                }
                if mode == "active-search" {
                    let model = windows.viewModel(for: first)!
                    model.filenameInput = "quit fixture"
                    model.scheduleSearch(immediate: true)
                    let marker = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]!)
                        .appendingPathComponent("workers")
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard model.isSearching, FileManager.default.fileExists(atPath: marker.path) else {
                        throw failure("Slow search worker did not start.")
                    }
                }
                // Quit immediately after an edit, before its queued save runs.
                windows.libraryStore.value.showIcons = false
                windows.libraryStore.save()
                requestedAt = .now
                switch mode {
                case "command-q": try await shortcut("q", keyCode: 12)
                case "command-w":
                    first.makeKeyAndOrderFront(nil)
                    try await shortcut("w", keyCode: 13)
                case "close-button", "settings-close", "multiple-windows", "active-search":
                    first.standardWindowButton(.closeButton)!.performClick(nil)
                case "repeated-quit":
                    NSApp.terminate(nil)
                    NSApp.terminate(nil)
                case "modal-panel":
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = first.representedURL
                    RunLoop.main.perform(inModes: [.modalPanel]) {
                        MainActor.assumeIsolated {
                            guard NSApp.modalWindow != nil else { return }
                            self.requestedAt = .now
                            do { try self.invokeShortcut("q", keyCode: 12) }
                            catch {
                                FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
                                exit(1)
                            }
                        }
                    }
                    panel.runModal()
                default: throw failure("Unknown quit scenario.")
                }
                if !["command-q", "repeated-quit", "modal-panel"].contains(mode) {
                    for _ in 0..<10 where !windows.windows.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                    guard windows.windows.isEmpty else { throw failure("Close action did not close the last search window.") }
                }
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = super.applicationShouldTerminate(sender)
        print("Quit delegate reply: \(reply.rawValue)")
        return reply
    }

    override func applicationWillTerminate(_ notification: Notification) {
        super.applicationWillTerminate(notification)
        do {
            guard let requestedAt else { throw failure("Quit occurred before the test action.") }
            let data = try Data(contentsOf: FindUIPaths.libraryFileURL())
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["showIcons"] as? Bool == false else { throw failure("Quit lost the pending settings save.") }
            let elapsed = requestedAt.duration(to: .now)
            guard elapsed < .seconds(3) else { throw failure("Quit took longer than three seconds.") }
            print("READY: \(mode) with pending settings saved (\(elapsed)).")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private func shortcut(_ character: String, keyCode: UInt16) async throws {
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<20 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(50)) }
        guard NSApp.isActive else { throw failure("macOS did not activate the app for Command-\(character).") }
        try invokeShortcut(character, keyCode: keyCode)
    }

    private func invokeShortcut(_ character: String, keyCode: UInt16) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
        guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
            throw failure("No enabled menu action for Command-\(character).")
        }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "FindUIQuitAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
