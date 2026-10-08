@testable import FindUI
@testable import SearchBackend
import Foundation
import Testing
import Combine

private actor AISheetControlledClient: AISearchGenerating {
    private var replies: [Int: CheckedContinuation<String, any Error>] = [:]
    var calls = 0
    func generate(messages: [AISearchMessage], schema: Data) async throws -> String {
        let call = calls; calls += 1
        // Deliberately ignore cancellation here so the consumer must reject
        // late completions rather than trusting its transport to stop.
        return try await withCheckedThrowingContinuation { replies[call] = $0 }
    }
    func reply(_ text: String, to call: Int) { replies.removeValue(forKey: call)?.resume(returning: text) }
}

@Test @MainActor func aiApplyDoesNotScheduleTheSameSearchAgainWhenControlsPublish() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-ai-schedule-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SearchViewModel(persistence: AppPersistence(baseDirectory: root), loadSavedState: false)
    defer { model.stopSearch() }
    var state = model.searchState; state.scopePath = root.path
    state.refinements.name = "report"; state.refinements.nameMatching = .contains
    var compilations = 0
    let subscription = model.$commandPreview.dropFirst().sink { _ in compilations += 1 }
    defer { subscription.cancel() }
    model.applyGeneratedSearch(state)
    #expect(compilations == 1)
    model.scheduleSearchAfterControlChange()
    #expect(compilations == 1, "Control publication must not cancel and compile the immediate search again")
    model.filenameInput = "different"
    model.scheduleSearchAfterControlChange()
    #expect(compilations == 2, "A real edit must still schedule a new search")
    model.scheduleSearchAfterControlChange()
    #expect(compilations == 2)
    model.scheduleSearch(immediate: true)
    #expect(compilations == 3, "Explicit Search/Refresh must run even when the controls are unchanged")
}

@MainActor private struct AISheetFixture {
    let domain: String
    let preferences: UserDefaults
    let settings: AISearchSettings
    let state: SearchState
    init() throws {
        domain = "local.findui.ai-sheet-test.\(UUID())"
        preferences = UserDefaults(suiteName: domain)!
        var settings = AISearchSettings(); settings.enabled = true
        self.settings = settings; try settings.save(to: preferences)
        state = SearchRequest(query: "", mode: .files, scope: FileManager.default.temporaryDirectory,
            includeHidden: false, caseSensitive: false, syntax: .literal, exactNameMatch: false, maxResults: .max).state
    }
    func remove() { preferences.removePersistentDomain(forName: domain) }
    func settingsModel() -> AISearchSettingsModel {
        .init(preferences: preferences, writeKey: { _, _ in }, keyExists: { _ in false },
              checkLogin: { _ in .init(executable: nil, available: false, message: "Fixture") }, loadModels: { _ in [] })
    }
}

private func sheetOutput(pattern: String = "*.swift", clarification: String? = nil) throws -> String {
    let root = AISearchGrammar.schema
    let properties = root["properties"] as! [String: Any]
    let options = properties["options"] as! [String: Any]
    let optionProperties = options["properties"] as! [String: Any]
    let object: [String: Any] = ["version": 1, "summary": clarification == nil ? "Matching files" : "", "contentUnit": "line",
        "clarification": clarification as Any? ?? NSNull(),
        "options": Dictionary(uniqueKeysWithValues: optionProperties.keys.map { ($0, NSNull()) }),
        "rules": clarification == nil ? ["kind": "name", "matching": "glob", "text": pattern] : NSNull()]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Test(arguments: [false, true]) @MainActor func aiSuccessfulGenerationAppliesExactlyOnceWithoutReview(repair: Bool) async throws {
    let fixture = try AISheetFixture(); defer { fixture.remove() }
    let client = AISheetControlledClient()
    let model = AISearchSheetModel(state: fixture.state, preferences: fixture.preferences, client: client)
    var applied: [SearchState] = []
    model.description = "Swift files"
    model.generate(settings: fixture.settings) { applied.append($0) }
    try await waitForCalls(1, client: client)
    if repair {
        await client.reply("{}", to: 0)
        try await waitForCalls(2, client: client)
        #expect(applied.isEmpty)
    }
    await client.reply(try sheetOutput(), to: repair ? 1 : 0)
    try await waitForGeneration(model)
    #expect(applied.count == 1 && applied.first?.refinements.name == "*.swift" && applied.first?.ruleSet == nil)
    #expect(model.error == nil && model.clarification == nil)
    model.cancel(); model.invalidate()
    #expect(applied.count == 1)
}

@Test @MainActor func aiClarificationAndFailedRepairNeverApplySearchState() async throws {
    let fixture = try AISheetFixture(); defer { fixture.remove() }
    let client = AISheetControlledClient()
    let model = AISearchSheetModel(state: fixture.state, preferences: fixture.preferences, client: client)
    var current = fixture.state, applied = 0
    model.description = "Some files"
    model.generate(settings: fixture.settings) { current = $0; applied += 1 }
    try await waitForCalls(1, client: client)
    await client.reply(try sheetOutput(clarification: "Which filename?"), to: 0)
    try await waitForGeneration(model)
    #expect(applied == 0 && current == fixture.state && model.clarification == "Which filename?")
    model.description = "Swift files"
    #expect(model.clarification == nil)
    model.generate(settings: fixture.settings) { current = $0; applied += 1 }
    try await waitForCalls(2, client: client)
    await client.reply("not JSON", to: 1)
    try await waitForCalls(3, client: client)
    await client.reply("[]", to: 2)
    try await waitForGeneration(model)
    #expect(applied == 0 && current == fixture.state && model.error != nil)
}

private enum AISheetInvalidation: CaseIterable, Sendable { case stop, edit, settings, externalSettings }

@Test(arguments: AISheetInvalidation.allCases) @MainActor
private func aiInvalidatedGenerationRejectsLateTransportReplies(_ reason: AISheetInvalidation) async throws {
    let fixture = try AISheetFixture(); defer { fixture.remove() }
    let client = AISheetControlledClient(), settings = fixture.settingsModel()
    let model = AISearchSheetModel(state: fixture.state, preferences: fixture.preferences, client: client)
    model.observeSettings(settings)
    var applied = 0
    model.description = "Swift files"
    model.generate(settings: fixture.settings) { _ in applied += 1 }
    try await waitForCalls(1, client: client)
    switch reason {
    case .stop: model.cancel()
    case .edit: model.description = "Different files"
    case .settings: settings.configuration.model = "new-model"
    case .externalSettings:
        var changed = fixture.settings; changed.model = "external-model"
        try changed.save(to: fixture.preferences)
    }
    if reason != .externalSettings { #expect(!model.isGenerating) }
    await client.reply(try sheetOutput(), to: 0)
    try await waitForGeneration(model)
    try await Task.sleep(for: .milliseconds(20))
    #expect(applied == 0 && model.error == nil && model.clarification == nil)
}

@Test @MainActor func aiNewGenerationCannotReceiveAnOlderGenerationResult() async throws {
    let fixture = try AISheetFixture(); defer { fixture.remove() }
    let client = AISheetControlledClient()
    let model = AISearchSheetModel(state: fixture.state, preferences: fixture.preferences, client: client)
    var applied: [SearchState] = []
    model.description = "Swift files"
    model.generate(settings: fixture.settings) { applied.append($0) }
    try await waitForCalls(1, client: client)
    model.description = "Markdown files"
    model.generate(settings: fixture.settings) { applied.append($0) }
    try await waitForCalls(2, client: client)
    await client.reply(try sheetOutput(), to: 0)
    try await Task.sleep(for: .milliseconds(20))
    #expect(applied.isEmpty && model.isGenerating)
    await client.reply(try sheetOutput(pattern: "*.md"), to: 1)
    try await waitForGeneration(model)
    #expect(applied.count == 1 && applied.first?.refinements.name == "*.md" && applied.first?.ruleSet == nil)
}

@Test @MainActor func aiSettingsChangesDuringRepairPreventAutomaticApplication() async throws {
    let fixture = try AISheetFixture(); defer { fixture.remove() }
    let client = AISheetControlledClient(), settings = fixture.settingsModel()
    let model = AISearchSheetModel(state: fixture.state, preferences: fixture.preferences, client: client)
    model.observeSettings(settings)
    var applied = 0
    model.description = "Swift files"
    model.generate(settings: fixture.settings) { _ in applied += 1 }
    try await waitForCalls(1, client: client)
    await client.reply("{}", to: 0)
    try await waitForCalls(2, client: client)
    settings.configuration.enabled = false
    await client.reply(try sheetOutput(), to: 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(applied == 0 && !model.isGenerating && model.error == nil)
}

private func waitForCalls(_ count: Int, client: AISheetControlledClient) async throws {
    for _ in 0..<100 {
        if await client.calls >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await client.calls >= count)
}

@MainActor private func waitForGeneration(_ model: AISearchSheetModel) async throws {
    for _ in 0..<100 where model.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isGenerating)
}
