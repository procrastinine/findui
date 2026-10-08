@testable import FindUI
@testable import SearchBackend
import Foundation
import Testing

@MainActor private final class AISettingsFixture {
    let domain = "local.findui.ai-settings-test.\(UUID())"
    let preferences: UserDefaults
    var keys: [String: String] = [:]
    init() throws {
        preferences = UserDefaults(suiteName: domain)!
        var settings = AISearchSettings(); settings.enabled = true
        try settings.save(to: preferences)
    }
    func remove() { preferences.removePersistentDomain(forName: domain) }
    func model(load: @escaping @Sendable (AISearchSettings) async throws -> [AISearchModelOption] = { _ in [] }) -> AISearchSettingsModel {
        AISearchSettingsModel(preferences: preferences,
            writeKey: { [self] key, account in keys[account] = key.isEmpty ? nil : key },
            keyExists: { [self] in keys[$0] != nil },
            checkLogin: { _ in .init(executable: nil, available: false, message: "Fixture") },
            loadModels: load)
    }
}

private actor AISettingsCatalogCounter {
    var count = 0
    func load(_ settings: AISearchSettings) -> [AISearchModelOption] {
        count += 1
        return [.init(id: "catalog-\(count)", name: settings.connection.title)]
    }
}

@Test @MainActor func aiProviderSwitchingKeepsSeparateKeysAndClearsDrafts() async throws {
    let fixture = try AISettingsFixture(); defer { fixture.remove() }
    var router = AISearchSettings(); router.selectConnection(.openRouter)
    var openAI = AISearchSettings(); openAI.selectConnection(.openAI)
    let routerAccount = try router.credentialAccount, openAIAccount = try openAI.credentialAccount
    fixture.keys[routerAccount] = "router-fixture-key"
    fixture.keys[openAIAccount] = "openai-fixture-key"
    let model = fixture.model()
    await model.resolve()
    #expect(model.hasSavedKey == true)

    model.apiKey = "draft-must-not-follow"
    model.selectConnection(.openAI)
    #expect(model.configuration.connection == .openAI && model.configuration.enabled)
    #expect(model.apiKey.isEmpty && model.hasSavedKey == true)
    #expect(model.keyStatusTitle == "Key saved" && model.keyInputPrompt == "Replace saved key")
    model.apiKey = "replacement-openai-key"; model.saveKey()
    #expect(fixture.keys[openAIAccount] == "replacement-openai-key")
    #expect(fixture.keys[routerAccount] == "router-fixture-key")

    model.selectConnection(.anthropic)
    #expect(model.configuration.provider == .anthropic && model.hasSavedKey == false)
    let anthropicAccount = try model.configuration.credentialAccount
    model.apiKey = "anthropic-fixture-key"; model.saveKey()
    model.selectConnection(.custom)
    #expect(model.configuration.connection == .custom && model.configuration.provider == .anthropic)
    #expect(model.hasSavedKey == true)
    model.apiKey = "another-draft"
    model.configuration.baseURL = "https://gateway.example/v1"
    #expect(model.apiKey.isEmpty && model.hasSavedKey == false)
    #expect(model.keyStatusTitle == "No key saved" && model.keyInputPrompt == "Paste API key")
    let gatewayAccount = try model.configuration.credentialAccount
    model.apiKey = "gateway-fixture-key"; model.saveKey()
    #expect(fixture.keys[anthropicAccount] == "anthropic-fixture-key")
    #expect(fixture.keys[gatewayAccount] == "gateway-fixture-key")

    model.apiKey = "format-draft"
    model.configuration.provider = .compatible
    #expect(model.configuration.connection == .custom)
    #expect(model.apiKey.isEmpty && model.hasSavedKey == false)
    #expect(try model.configuration.credentialAccount != gatewayAccount)
    model.selectConnection(.openRouter)
    #expect(model.hasSavedKey == true && model.keyStatusTitle == "Key saved")
    model.apiKey = ""; model.saveKey()
    #expect(model.hasSavedKey == false && fixture.keys[routerAccount] == nil)
    #expect(model.keyStatusTitle == "No key saved")
    #expect(fixture.keys[openAIAccount] == "replacement-openai-key")
    #expect(fixture.keys[anthropicAccount] == "anthropic-fixture-key")
    let data = try #require(fixture.preferences.data(forKey: AISearchSettings.preferencesKey))
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("fixture-key") && !json.contains("replacement-openai-key") && !json.contains("draft"))
}

@Test @MainActor func aiCredentialChangesRefreshOnlyAnAlreadyLoadedCatalog() async throws {
    let fixture = try AISettingsFixture(); defer { fixture.remove() }
    let catalog = AISettingsCatalogCounter(), model = fixture.model { await catalog.load($0) }
    model.apiKey = "first-key"; model.saveKey()
    #expect(await catalog.count == 0)
    model.fetchModelsIfNeeded()
    try await waitForCatalog(model)
    #expect(await catalog.count == 1 && model.models.first?.id == "catalog-1")
    model.fetchModelsIfNeeded()
    #expect(await catalog.count == 1)
    model.apiKey = "replacement-key"; model.saveKey()
    try await waitForCatalog(model)
    #expect(await catalog.count == 2 && model.models.first?.id == "catalog-2")
    model.apiKey = ""; model.saveKey()
    try await waitForCatalog(model)
    #expect(await catalog.count == 3)
    model.selectConnection(.google)
    #expect(model.models.isEmpty && !model.hasLoadedModels)
    #expect(await catalog.count == 3)
    model.fetchModelsIfNeeded()
    try await waitForCatalog(model)
    #expect(await catalog.count == 4)
}

@Test @MainActor func aiUnknownKeychainStatusStaysExplicitWithoutReadingSecrets() async throws {
    let fixture = try AISettingsFixture(); defer { fixture.remove() }
    let model = AISearchSettingsModel(preferences: fixture.preferences, writeKey: { _, _ in }, keyExists: { _ in nil },
        checkLogin: { _ in .init(executable: nil, available: false, message: "Fixture") }, loadModels: { _ in [] })
    await model.resolve()
    #expect(model.hasSavedKey == nil && model.keyStatusTitle == "Key status unavailable")
    #expect(model.keyInputPrompt == "Paste API key")
}

@Test @MainActor func aiFailedKeychainRefreshClearsThePreviousSavedIndicator() throws {
    let fixture = try AISettingsFixture(); defer { fixture.remove() }
    var unavailable = false
    let model = AISearchSettingsModel(preferences: fixture.preferences, keyExists: { _ in
        if unavailable { throw AISearchError.message("Fixture Keychain unavailable") }
        return true
    })
    model.refreshKeyStatus()
    #expect(model.hasSavedKey == true)
    unavailable = true; model.refreshKeyStatus()
    #expect(model.hasSavedKey == nil && model.keyStatusTitle == "Key status unavailable")
    #expect(model.errorMessage == "Fixture Keychain unavailable")
}

@MainActor private func waitForCatalog(_ model: AISearchSettingsModel) async throws {
    for _ in 0..<100 where model.isLoadingModels { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isLoadingModels && model.modelsError == nil && model.hasLoadedModels)
}
