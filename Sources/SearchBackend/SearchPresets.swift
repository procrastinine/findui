import Foundation
import Darwin

package enum SearchPresetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case search, filter, scope
    package var id: Self { self }
    package var title: String { switch self { case .search: "Search"; case .filter: "Filter"; case .scope: "Scope" } }
    package var plural: String { switch self { case .search: "Searches"; case .filter: "Filters"; case .scope: "Scopes" } }
    package var detail: String { switch self {
    case .search: "Restore the complete search, including its folders and options."
    case .filter: "Add these conditions to a search, using its current matching options."
    case .scope: "Restore the folders and traversal options, keeping the current conditions."
    } }
}

package struct SearchPreset: Codable, Hashable, Identifiable, Sendable {
    package var id = UUID()
    package var name: String
    package var kind: SearchPresetKind
    package var state: SearchState
    package var updatedAt = Date()
    package var summary: String {
        if kind == .filter {
            var value = state
            if (try? value.promoteToRules()) != nil { return value.ruleSet?.title ?? "Conditions" }
            return "Conditions"
        }
        if kind == .scope { return state.resultScope?.name ?? state.scopePath }
        return state.summary
    }

    package func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw SearchServiceError.commandFailed("Name the preset using 1–120 characters.")
        }
        try state.traversal.validate(allowRoot: state.resultScope != nil)
        if let native = state.nativeCommand {
            guard kind == .search else {
                throw SearchServiceError.commandFailed("A command can be saved as a complete search. Use Search Within These Results before creating editable filters or scopes.")
            }
            _ = try native.parsed()
            return
        }
        if kind != .scope {
            var copy = state; try copy.promoteToRules(); try copy.ruleSet?.validate(now: .now)
        }
    }

    package func applying(to current: SearchState) throws -> SearchState {
        try validate()
        if kind == .search {
            var restored = state
            restored.selectRequiredSource()
            try restored.validateSourceRequirements()
            return restored
        }
        guard current.nativeCommand == nil else {
            throw SearchServiceError.commandFailed("Use Search Within These Results before adding filters or changing the scope of a command search.")
        }
        var result = current
        result.sourceCommand = nil
        if kind == .scope {
            result.scopePath = state.scopePath; result.refinements.additionalScopes = state.refinements.additionalScopes
            result.includeHidden = state.includeHidden; result.traversal = state.traversal
            result.refinements.source = state.refinements.source; result.resultScope = state.resultScope
            result.useIndex = state.useIndex && result.mode != .contents
            result.selectedDrivePath = state.selectedDrivePath
            result.selectRequiredSource()
            try result.validateSourceRequirements()
            return result
        }
        var saved = state
        try saved.promoteToRules(); try result.promoteToRules()
        var rules = result.ruleSet!
        let extra = saved.ruleSet!
        func joined<R>(_ a: SearchRuleTree<R>, _ b: SearchRuleTree<R>) -> SearchRuleTree<R> {
            if case .all(let children) = a, children.isEmpty { return b }
            if case .all(let children) = b, children.isEmpty { return a }
            if a == b { return a }
            return .all([a, b])
        }
        if rules.hasContents && extra.hasContents && rules.contentUnit != extra.contentUnit {
            throw SearchServiceError.commandFailed("This filter uses \(extra.contentUnit.title.lowercased()). Select that content matching option before applying it.")
        }
        if !rules.hasContents && extra.hasContents { rules.contentUnit = extra.contentUnit }
        rules.expression = joined(rules.expression, extra.expression)
        try rules.validate(now: .now)
        result.replaceRules(rules)
        try result.validateSourceRequirements()
        return result.compactProjection ?? result
    }
    package init(id: UUID = UUID(), name: String, kind: SearchPresetKind, state: SearchState, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.updatedAt = updatedAt
    }

}

package struct SearchPresetCollection: Codable, Sendable {
    package var version = 1
    package var presets: [SearchPreset] = []
    package func validate() throws {
        guard version == 1, Set(presets.map(\.id)).count == presets.count else {
            throw SearchServiceError.commandFailed("Unsupported or duplicate preset data.")
        }
        for preset in presets { try preset.validate() }
    }
    package init(version: Int = 1, presets: [SearchPreset] = []) {
        self.version = version
        self.presets = presets
    }

}

/// The app and CLI use this same atomic, process-locked library. Each mutation
/// reads the latest generation while holding the lock, preventing lost edits.
package struct SearchPresetStore: Sendable {
    package var directory: URL
    package init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["FINDUI_PRESETS_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FindUIPaths.baseDirectory()
    }
    private var file: URL { directory.appendingPathComponent("presets.json") }
    package func read() throws -> SearchPresetCollection {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let value = try JSONDecoder().decode(SearchPresetCollection.self, from: Data(contentsOf: file))
        try value.validate(); return value
    }
    @discardableResult package func change(_ body: (inout SearchPresetCollection) throws -> Void) throws -> SearchPresetCollection {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SearchServiceError.commandFailed("Could not lock the preset library.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SearchServiceError.commandFailed("Could not lock the preset library.") }
        var collection = try read(); try body(&collection); try collection.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(collection).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return collection
    }
    package func resolve(_ reference: String) throws -> SearchPreset {
        let values = try read().presets.filter { $0.id.uuidString.lowercased() == reference.lowercased() || $0.name == reference }
        guard values.count == 1, let value = values.first else {
            throw SearchServiceError.commandFailed("Choose one preset by its unique name or ID. Use presets list.")
        }
        return value
    }
    package func importPresets(_ incoming: SearchPresetCollection) throws -> SearchPresetCollection {
        try incoming.validate()
        return try change { collection in
            for var preset in incoming.presets {
                if collection.presets.contains(where: { $0.id == preset.id }) { preset.id = UUID() }
                collection.presets.append(preset)
            }
        }
    }
}
