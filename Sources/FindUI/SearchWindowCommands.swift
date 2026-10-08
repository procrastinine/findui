import SearchBackend
import SwiftUI

struct SearchWindowCommands: Commands {
    @ObservedObject var windows: SearchWindowManager
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { windows.newWindow() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(windows.isShuttingDown)
            Button("New Tab") { windows.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(windows.isShuttingDown)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Quick Look") { windows.activeViewModel?.toggleQuickLook() }
                .disabled(windows.activeViewModel == nil)
            Button("Close Quick Look") { windows.activeViewModel?.closeQuickLook() }
            Button(windows.activeViewModel?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                windows.activeViewModel?.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(windows.activeViewModel == nil)
        }
    }
}
