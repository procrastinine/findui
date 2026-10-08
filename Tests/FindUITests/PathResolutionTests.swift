@testable import SearchBackend
import Foundation
import Testing
@testable import FindUI

@Test func folderTyposUseExistingUnambiguousDirectoriesOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-spelling-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let documents = root.appendingPathComponent("Documents")
    try FileManager.default.createDirectory(at: documents.appendingPathComponent("Papers"), withIntermediateDirectories: true)
    for typo in ["Docmuents", "Docments", "Documments", "Documxnts"] {
        let result = try SearchPath.resolveFolder("~/\(typo)/Papers", relativeTo: root, home: root)
        #expect(result.url == documents.appendingPathComponent("Papers"))
        #expect(result.corrected)
    }
    let exact = try SearchPath.resolveFolder("~/Documents", relativeTo: root, home: root)
    #expect(!exact.corrected)
    let misspelled = root.appendingPathComponent("Docmuents")
    try FileManager.default.createDirectory(at: misspelled, withIntermediateDirectories: true)
    #expect(try SearchPath.resolveFolder("~/Docmuents", relativeTo: root, home: root).url.path == misspelled.path)
    #expect(try !SearchPath.resolveFolder("~/Docmuents", relativeTo: root, home: root).corrected)
}

@Test func folderCorrectionsDoNotGuessAmbiguitiesFilesOrShortNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-spelling-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Reports", "Reparts", "src", "Documents"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("Docmuents"))
    for input in ["Reperts", "scr", "Docmuents", "Nonesuch", "Documents/Papres"] {
        #expect(throws: (any Error).self) { try SearchPath.resolveFolder(input, relativeTo: root, home: root, filesystemRoot: root) }
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents/Papers"), withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try SearchPath.resolveFolder("Docments/Papres", relativeTo: root, home: root, filesystemRoot: root) }
    #expect(try SearchPath.resolveFolder("Documents/Papers", relativeTo: root, home: root, filesystemRoot: root).corrected == false)
}

@Test func bareFoldersTryCurrentThenHomeThenRootBeforeAnyCorrection() throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("findui-scope-\(UUID())")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let current = fixture.appendingPathComponent("current")
    let home = fixture.appendingPathComponent("home")
    let root = fixture.appendingPathComponent("root")
    for location in [current, home, root] {
        try FileManager.default.createDirectory(at: location.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }
    func resolve(_ path: String) throws -> SearchPath.Resolution {
        try SearchPath.resolveFolder(path, relativeTo: current, home: home, filesystemRoot: root)
    }
    #expect(try resolve("Documents").url.path == current.appendingPathComponent("Documents").path)
    try FileManager.default.removeItem(at: current.appendingPathComponent("Documents"))
    #expect(try resolve("Documents").url.path == home.appendingPathComponent("Documents").path)
    try FileManager.default.removeItem(at: home.appendingPathComponent("Documents"))
    #expect(try resolve("Documents").url.path == root.appendingPathComponent("Documents").path)
    try FileManager.default.createDirectory(at: current.appendingPathComponent("Docmuents"), withIntermediateDirectories: true)
    #expect(try resolve("Documents").url.path == root.appendingPathComponent("Documents").path)
    #expect(try !resolve("Documents").corrected)
    #expect(try resolve("Docmuents").url.path == current.appendingPathComponent("Docmuents").path)
    try Data().write(to: current.appendingPathComponent("Documents"))
    #expect(try resolve("Documents").url.path == root.appendingPathComponent("Documents").path)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Documents"))
    #expect(throws: (any Error).self) { try resolve("Documents") }
}

@Test func explicitFolderPrefixesAndLiteralSpacesRetainTheirMeaning() throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("findui-prefix-\(UUID())")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let current = fixture.appendingPathComponent("current")
    let home = fixture.appendingPathComponent("home")
    let root = fixture.appendingPathComponent("root")
    for location in [current, home, root] {
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    }
    for name in ["OnlyHome", " Documents "] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    func resolve(_ path: String) throws -> SearchPath.Resolution {
        try SearchPath.resolveFolder(path, relativeTo: current, home: home, filesystemRoot: root)
    }
    #expect(throws: (any Error).self) { try resolve("./OnlyHome") }
    #expect(throws: (any Error).self) { try resolve("../OnlyHome") }
    #expect(throws: (any Error).self) { try resolve("~/OnlyRoot") }
    #expect(try resolve("~/OnlyHome").url.path == home.appendingPathComponent("OnlyHome").path)
    #expect(try resolve(home.appendingPathComponent("OnlyHome").path).url.path == home.appendingPathComponent("OnlyHome").path)
    #expect(try resolve(" Documents ").url.path == home.appendingPathComponent(" Documents ").path)
    #expect(try !resolve(" Documents ").corrected)
    #expect(try resolve(".").url.path == current.path)
    #expect(try resolve("~").url.path == home.path)
}
