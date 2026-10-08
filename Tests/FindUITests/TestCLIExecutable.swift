import Foundation
import Testing

private final class TestCLIImage: NSObject {}

/// Use the CLI built beside this test bundle, including custom SwiftPM
/// scratch paths. The production launcher should not know about XCTest.
func currentTestCLIExecutable() throws -> URL {
    let bundle = Bundle(for: TestCLIImage.self).bundleURL
    let candidate = bundle.deletingLastPathComponent().appendingPathComponent("FindUI", isDirectory: false)
    try #require(FileManager.default.isExecutableFile(atPath: candidate.path),
        "Build the current FindUI CLI beside the test bundle: \(candidate.path)")
    return candidate
}
