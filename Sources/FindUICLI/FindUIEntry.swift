import Foundation
import SearchBackend

/// The terminal entry has no UI linkage. Finder launches FindUIApp directly;
/// invoking this legacy executable without --cli still opens the GUI.
@main enum FindUIEntry {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            exit(await HeadlessCLI.run(Array(arguments.dropFirst())))
        }
        guard let executable = ExecutableLocation.current else {
            HeadlessCLI.diagnostic("Cannot locate the FindUI executable.")
            exit(126)
        }
        let gui = executable.deletingLastPathComponent().appendingPathComponent("FindUIApp", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: gui.path) else {
            HeadlessCLI.diagnostic("The FindUI GUI executable is missing. Reinstall FindUI.app, or build both products with swift build.")
            exit(126)
        }
        do { try ProcessRunner.replace(with: CommandSpec(executable: gui, arguments: arguments)) }
        catch { HeadlessCLI.diagnostic(error.localizedDescription); exit(126) }
    }
}
