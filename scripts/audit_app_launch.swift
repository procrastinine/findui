import AppKit
import Foundation

/// Exercises Finder-style launch of the packaged GUI. Uses a disposable library
/// and closes only its own instance.
@main @MainActor enum AppLaunchAudit {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "FindUILaunchAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func main() async {
        do { try await check() }
        catch { try? FileHandle.standardError.write(contentsOf: Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(2) }
    }
    static func check() async throws {
        guard CommandLine.arguments.count == 2 else { throw failure("Pass FindUI.app.") }
        let application = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("findui-launch-\(UUID())")
        let data = temporary.appendingPathComponent("data"), files = temporary.appendingPathComponent("files")
        for directory in [data, files] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("launch fixture\n".utf8).write(to: files.appendingPathComponent("sample.txt"))
        let library: [String: Any] = ["defaultSearchDirectoryPath": files.path, "history": [],
                                      "managedIndexes": [], "explicitConversionChoices": true]
        try JSONSerialization.data(withJSONObject: library).write(to: data.appendingPathComponent("library.json"))
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: []) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.environment = ["FINDUI_DATA_DIRECTORY": data.path,
            "FINDUI_CACHE_DIRECTORY": temporary.appendingPathComponent("cache").path,
            "FINDUI_TIKA_DIRECTORY": temporary.appendingPathComponent("tika").path,
            "FINDUI_TIKA_JAR": "", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let running = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        defer { if !running.isTerminated { running.forceTerminate() } }
        var visible = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !running.isTerminated {
            let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            visible = windows.contains {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == running.processIdentifier
                    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }
            if visible && running.isFinishedLaunching { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !running.isTerminated, running.isFinishedLaunching, visible else {
            throw failure("The packaged app did not produce a GUI window: terminated=\(running.isTerminated), finished=\(running.isFinishedLaunching), window=\(visible), active=\(running.isActive), hidden=\(running.isHidden), bundle=\(String(describing: running.bundleIdentifier)), executable=\(String(describing: running.executableURL)).")
        }
        guard running.bundleIdentifier == "com.codex.findui",
              running.bundleURL?.resolvingSymlinksInPath() == application,
              running.localizedName == "FindUI" else {
            throw failure("GUI launch lost the app's bundle identity: \(String(describing: running.bundleIdentifier)), \(String(describing: running.bundleURL)), \(String(describing: running.localizedName)).")
        }
        guard running.terminate() else { throw failure("GUI rejected termination.") }
        let shutdownDeadline = Date().addingTimeInterval(10)
        while !running.isTerminated && Date() < shutdownDeadline { try await Task.sleep(for: .milliseconds(50)) }
        guard running.isTerminated else { throw failure("GUI did not finish normal shutdown.") }
        print("PASS: packaged GUI launch, FindUI bundle identity, native window and normal shutdown; isolated data directory")
    }
}
