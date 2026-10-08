import Foundation
import MachO

/// Bundle.main.executableURL names CFBundleExecutable, which is the GUI even
/// when a CLI helper is running. Resolve the actual process image instead;
/// symlinked CLI entry points must still find their bundled sibling tools.
package enum ExecutableLocation {
    // Developer builds can discover checkout tools. Distributed builds must
    // neither depend on nor embed the machine that compiled them.
    package static var developmentRoot: URL? {
        #if FINDUI_DISTRIBUTION
        nil
        #else
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #endif
    }

    package static let current: URL? = {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer {
            URL(fileURLWithFileSystemRepresentation: $0.baseAddress!, isDirectory: false, relativeTo: nil)
                .resolvingSymlinksInPath()
        }
    }()
}
