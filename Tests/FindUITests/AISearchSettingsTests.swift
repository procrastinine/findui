@testable import SearchBackend
import Foundation
import Testing

private actor AISearchDetectionCounter {
    var count = 0
    func detect() -> CodexSearchStatus {
        count += 1
        return .init(executable: "/fixture/codex", available: true, message: "Fixture ChatGPT login")
    }
}

@Test func aiUnconfiguredSearchUsesDetectedChatGPTWithoutSavingConfiguration() async {
    let detector = AISearchDetectionCounter()
    let result = await AISearchSettings.resolve(configurationData: nil) { _ in await detector.detect() }
    #expect(result.automaticallyDetected)
    #expect(result.settings.enabled && result.settings.provider == .codex)
    #expect(result.settings.codexModel == "gpt-6.1-sol")
    #expect(result.settings.baseURL == "https://openrouter.ai/api/v1")
    #expect(result.settings.model == "google/gemini-3.8-flash")
    #expect(result.settings.codexPath.isEmpty)
    #expect(await detector.count == 1)
}

@Test func aiExplicitDisabledAndCustomProviderSettingsNeverTriggerDetection() async throws {
    let detector = AISearchDetectionCounter()
    var disabled = AISearchSettings(); disabled.provider = .codex; disabled.enabled = false
    var api = AISearchSettings(); api.enabled = true; api.baseURL = "http://localhost:9000/v1"; api.model = "local-model"
    var previous = AISearchSettings(); previous.enabled = true; previous.baseURL = "https://api.openai.com/v1"; previous.model = "gpt-6-astra"
    for settings in [disabled, api, previous] {
        let result = await AISearchSettings.resolve(configurationData: try JSONEncoder().encode(settings)) { _ in await detector.detect() }
        #expect(result.settings == settings)
        #expect(!result.automaticallyDetected && result.codexStatus == nil)
    }
    let invalid = await AISearchSettings.resolve(configurationData: Data("invalid saved settings".utf8)) { _ in await detector.detect() }
    #expect(!invalid.settings.enabled && !invalid.automaticallyDetected)
    #expect(await detector.count == 0)
}

@Test func aiMissingChatGPTLoginOffersOpenRouterSetupAndCancellationDoesNotEnableAI() async throws {
    let result = await AISearchSettings.resolve(configurationData: nil) { _ in
        .init(executable: nil, available: false, message: "No login")
    }
    #expect(!result.settings.enabled && result.settings.provider == .compatible)
    #expect(result.settings.baseURL == "https://openrouter.ai/api/v1")
    #expect(result.settings.model == "google/gemini-3.8-flash")
    let task = Task {
        await AISearchSettings.resolve(configurationData: nil) { _ in
            try? await Task.sleep(for: .seconds(5))
            return .init(executable: "/fixture/codex", available: true, message: "Late login")
        }
    }
    try await Task.sleep(for: .milliseconds(10)); task.cancel()
    let cancelled = await task.value
    #expect(!cancelled.settings.enabled && !cancelled.automaticallyDetected)
}
