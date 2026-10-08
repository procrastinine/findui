import SearchBackend
import SwiftUI

@MainActor
final class AISearchSettingsModel: ObservableObject {
    @Published var configuration: AISearchSettings {
        didSet {
            let destinationChanged = oldValue.baseURL != configuration.baseURL || oldValue.provider != configuration.provider
            if destinationChanged {
                apiKey = ""; hasSavedKey = nil; errorMessage = nil
                invalidateModels()
            } else if oldValue.codexPath != configuration.codexPath, configuration.provider == .codex {
                invalidateModels()
            }
            if !applyingResolution {
                do { try configuration.save(to: preferences) } catch { errorMessage = error.localizedDescription }
            }
            if destinationChanged { refreshKeyStatus() }
        }
    }
    @Published var apiKey = ""
    @Published private(set) var hasSavedKey: Bool?
    @Published var errorMessage: String?
    @Published private(set) var codexStatus: CodexSearchStatus?
    @Published private(set) var isChecking = false
    @Published private(set) var isResolving = false
    @Published private(set) var models: [AISearchModelOption] = []
    @Published private(set) var modelsError: String?
    @Published private(set) var isLoadingModels = false
    @Published private(set) var hasLoadedModels = false
    private var applyingResolution = false
    private var checkTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogGeneration = UUID()
    private let preferences: UserDefaults
    private let writeKey: (String, String) throws -> Void
    private let keyExists: (String) throws -> Bool?
    private let checkLogin: @Sendable (String) async -> CodexSearchStatus
    private let loadModels: @Sendable (AISearchSettings) async throws -> [AISearchModelOption]
    init(preferences: UserDefaults = AISearchSettings.preferences,
         writeKey: @escaping (String, String) throws -> Void = { try AISearchCredentials.write($0, account: $1) },
         keyExists: @escaping (String) throws -> Bool? = { try AISearchCredentials.contains(account: $0) },
         checkLogin: @escaping @Sendable (String) async -> CodexSearchStatus = { await CodexSearchClient.status(preferred: $0) },
         loadModels: @escaping @Sendable (AISearchSettings) async throws -> [AISearchModelOption] = { settings in
             var key = ""
             if settings.provider != .codex, !AISearchModelCatalog.isOpenRouter(settings) {
                 key = try AISearchCredentials.read(account: settings.credentialAccount) ?? ""
             }
             return try await AISearchModelCatalog.fetch(settings: settings, apiKey: key)
         }) {
        self.preferences = preferences; self.writeKey = writeKey; self.keyExists = keyExists; self.checkLogin = checkLogin
        self.loadModels = loadModels
        configuration = .load(from: preferences)
    }
    func resolve() async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        var data = preferences.data(forKey: AISearchSettings.preferencesKey)
        var result = await AISearchSettings.resolve(configurationData: data, detectCodex: checkLogin)
        while !Task.isCancelled, preferences.data(forKey: AISearchSettings.preferencesKey) != data {
            data = preferences.data(forKey: AISearchSettings.preferencesKey)
            result = await AISearchSettings.resolve(configurationData: data, detectCodex: checkLogin)
        }
        guard !Task.isCancelled else { return }
        let destinationChanged = configuration.baseURL != result.settings.baseURL || configuration.provider != result.settings.provider
        applyingResolution = true; configuration = result.settings; applyingResolution = false
        if let status = result.codexStatus { codexStatus = status }
        else if configuration.provider == .codex { checkCodex() }
        if !destinationChanged { refreshKeyStatus() }
    }
    func selectConnection(_ connection: AISearchConnection) {
        var next = configuration
        next.selectConnection(connection)
        configuration = next
        if next.provider == .codex { checkCodex() }
    }
    var selectedModel: String {
        get { configuration.provider == .codex ? configuration.codexModel : configuration.model }
        set { if configuration.provider == .codex { configuration.codexModel = newValue } else { configuration.model = newValue } }
    }
    var keyStatusTitle: String {
        switch hasSavedKey {
        case .some(true): "Key saved"
        case .some(false): "No key saved"
        case .none: "Key status unavailable"
        }
    }
    var keyInputPrompt: String { hasSavedKey == true ? "Replace saved key" : "Paste API key" }
    func fetchModelsIfNeeded() { if !hasLoadedModels && !isLoadingModels { fetchModels() } }
    private func invalidateModels() {
        catalogTask?.cancel(); catalogGeneration = UUID()
        models = []; modelsError = nil; isLoadingModels = false; hasLoadedModels = false
    }
    func fetchModels() {
        catalogTask?.cancel(); modelsError = nil; isLoadingModels = true
        let settings = configuration, token = UUID(), load = loadModels
        catalogGeneration = token
        catalogTask = Task { [weak self] in
            do {
                let values = try await load(settings)
                guard !Task.isCancelled, self?.catalogGeneration == token else { return }
                self?.models = values; self?.isLoadingModels = false; self?.hasLoadedModels = true
            } catch is CancellationError { if self?.catalogGeneration == token { self?.isLoadingModels = false } }
            catch {
                guard self?.catalogGeneration == token else { return }
                self?.modelsError = error.localizedDescription; self?.isLoadingModels = false
            }
        }
    }
    func saveKey() {
        do {
            let account = try configuration.credentialAccount
            try writeKey(apiKey, account)
            hasSavedKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            apiKey = ""; errorMessage = nil
            let reload = hasLoadedModels || isLoadingModels
            invalidateModels()
            if reload { fetchModels() }
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshKeyStatus() {
        guard configuration.provider != .codex, let account = try? configuration.credentialAccount else { hasSavedKey = nil; return }
        do { hasSavedKey = try keyExists(account) }
        catch { hasSavedKey = nil; errorMessage = error.localizedDescription }
    }
    func checkCodex() {
        checkTask?.cancel(); isChecking = true
        let path = configuration.codexPath
        let check = checkLogin
        checkTask = Task { [weak self] in
            let status = await check(path)
            guard !Task.isCancelled else { return }
            self?.codexStatus = status; self?.isChecking = false
        }
    }
    func chooseCodex() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the Codex executable."
        if panel.runModal() == .OK, let url = panel.url { configuration.codexPath = url.path; checkCodex() }
    }
    deinit { checkTask?.cancel(); catalogTask?.cancel() }
}

struct AISearchSettingsView: View {
    @ObservedObject var model: AISearchSettingsModel
    var body: some View {
        Form {
            Section {
                Toggle("Enable AI Search", isOn: $model.configuration.enabled)
                    .accessibilityIdentifier("enableAISearch")
                Text("Describe a search to fill in FindUI’s controls. Your description and current search settings are sent to the selected provider. Files and search results stay on your Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Provider") {
                HStack {
                    Text("Use")
                    Spacer()
                    UtilityPicker(title: "AI provider", selection: Binding(
                        get: { model.configuration.connection }, set: { model.selectConnection($0) }),
                        values: AISearchConnection.allCases, label: \.title).frame(width: 245)
                        .accessibilityIdentifier("aiSearchProvider")
                }
                if model.configuration.provider != .codex {
                    if model.configuration.connection == .custom {
                        HStack {
                            Text("API format")
                            Spacer()
                            UtilityPicker(title: "API format", selection: $model.configuration.provider,
                                values: [AISearchProvider.compatible, .anthropic], label: \.title)
                                .frame(width: 245).accessibilityIdentifier("aiSearchFormat")
                        }
                        LabeledContent("API URL") {
                            TextField("API URL", text: $model.configuration.baseURL, prompt: Text("https://example.com/v1"))
                                .labelsHidden().multilineTextAlignment(.leading)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("API URL").accessibilityIdentifier("aiSearchURL")
                        }
                    }
                    LabeledContent("Model") {
                        AISearchModelPicker(model: model).accessibilityIdentifier("aiSearchModel")
                    }
                    LabeledContent {
                        HStack {
                            SecureField("API key", text: $model.apiKey, prompt: Text(model.keyInputPrompt))
                                .labelsHidden().multilineTextAlignment(.leading)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("API key").accessibilityIdentifier("aiSearchKey")
                            Button("Save Key") { model.saveKey() }.disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("saveAISearchKey")
                            Button("Remove Key") { model.apiKey = ""; model.saveKey() }
                                .disabled(model.hasSavedKey == false)
                                .accessibilityIdentifier("removeAISearchKey")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API key")
                            if model.hasSavedKey == true {
                                Label(model.keyStatusTitle, systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green).accessibilityIdentifier("aiSearchKeySaved")
                            } else {
                                Text(model.keyStatusTitle).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("aiSearchKeyStatus")
                            }
                        }
                    }
                    if model.configuration.connection != .custom {
                        Text(model.configuration.baseURL)
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("aiSearchDestination")
                    }
                    if model.configuration.connection == .custom {
                        Text("Use a model that supports JSON output. Local servers can use http://localhost and an empty key.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(model.codexStatus?.message ?? "Check for an existing ChatGPT login in Codex.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("aiCodexStatus")
                        if model.isChecking { ProgressView().controlSize(.small) }
                        Button { model.checkCodex() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Check Codex and its login").accessibilityLabel("Check Codex login")
                            .disabled(model.isChecking).accessibilityIdentifier("checkAICodex")
                    }
                    LabeledContent("Model") {
                        AISearchModelPicker(model: model).accessibilityIdentifier("aiCodexModel")
                    }
                    HStack {
                        Text(model.configuration.codexPath.isEmpty ? (model.codexStatus?.executable ?? "Automatic executable detection") : model.configuration.codexPath)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { model.chooseCodex() }
                        if !model.configuration.codexPath.isEmpty { Button("Automatic") { model.configuration.codexPath = ""; model.checkCodex() } }
                    }
                    Text("Uses Codex’s existing ChatGPT login and model access. FindUI does not read or copy its tokens. Requests run without tools, plugins or project instructions. Install Codex separately and sign in with codex login.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.footnote).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task { await model.resolve() }
    }
}
