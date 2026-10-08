@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func fileAccessErrorsUseNativeCodesForLocalizedMessages() {
    #expect(FileAccessFailure.matches(NSError(domain: NSCocoaErrorDomain,
        code: NSFileReadNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "Zugriff verweigert"])))
    #expect(FileAccessFailure.matches(NSError(domain: NSPOSIXErrorDomain,
        code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "Accès refusé"])))
    #expect(FileAccessFailure.matches(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
    #expect(!FileAccessFailure.matches(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    #expect(!FileAccessFailure.matches("rg: regex parse error"))
}

@Test @MainActor func permissionHelpRemainsAvailableWithoutInterruptingEveryRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("findui-file-access-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: directory.appendingPathComponent("settings")), loadSavedState: false)
    defer { model.stopSearch() }
    model.maybePresentPermissionHelp(for: "2 matches. rg: a protected folder: Operation not permitted (os error 1)")
    #expect(model.hasPermissionFailure)
    #expect(model.isPermissionHelpPresented)
    model.isPermissionHelpPresented = false
    model.maybePresentPermissionHelp(for: "find: a protected folder: Permission denied")
    #expect(model.hasPermissionFailure)
    #expect(!model.isPermissionHelpPresented)

    model.scopeURL = directory
    model.scheduleSearch(immediate: true)
    for _ in 0..<100 {
        if !model.hasPermissionFailure && !model.isSearching { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!model.hasPermissionFailure)
    #expect(!model.isPermissionHelpPresented)
}
