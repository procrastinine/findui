import AppKit
import SearchBackend

@MainActor
class FindUIApplicationDelegate: NSObject, NSApplicationDelegate {
    let windows: SearchWindowManager
    private let termination: ApplicationTermination

    override init() {
        let windows = SearchWindowManager()
        self.windows = windows
        self.termination = ApplicationTermination(
            gracePeriod: .seconds(2),
            stop: {
                windows.shutdown()
                if let panel = NSApplication.shared.modalWindow {
                    NSApplication.shared.stopModal(withCode: .cancel)
                    panel.orderOut(nil)
                }
            },
            cleanup: {
                async let documents: Void = DocumentMaterializer.shared.clear()
                async let searches: Void = windows.waitForShutdown()
                await windows.libraryStore.shutdown()
                await searches
                await documents
            },
            terminate: {
                // AppKit's final termination observers must also run outside
                // a Swift concurrency job; SwiftUI may drain queued work here.
                RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                }
            })
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        windows.newWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func newWindowForTab(_ sender: Any?) { windows.newTab() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !termination.isQuitting else { return false }
        if let window = windows.windows.first {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else { windows.newWindow() }
        return true
    }

    // The manager counts search windows (including tabs and minimized windows),
    // so Settings cannot keep the app alive or trigger a second quit request.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request()
    }

    func applicationWillTerminate(_ notification: Notification) { windows.shutdown() }
}
