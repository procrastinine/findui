import SearchBackend
import Combine
import SwiftUI

@MainActor
final class AISearchSheetModel: ObservableObject {
    @Published var description = "" { didSet { if description != oldValue { invalidate() } } }
    @Published private(set) var clarification: String?
    @Published private(set) var error: String?
    @Published private(set) var isGenerating = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var settingsSubscription: AnyCancellable?
    let original: SearchState
    private let preferences: UserDefaults
    private let client: (any AISearchGenerating)?
    init(state: SearchState, preferences: UserDefaults = AISearchSettings.preferences, client: (any AISearchGenerating)? = nil) {
        original = state; self.preferences = preferences; self.client = client
    }
    func observeSettings(_ settings: AISearchSettingsModel) {
        settingsSubscription = settings.$configuration.removeDuplicates().dropFirst().sink { [weak self] _ in self?.invalidate() }
    }
    func generate(settings suppliedSettings: AISearchSettings? = nil, apply: @escaping @MainActor (SearchState) -> Void) {
        invalidate()
        let configurationData = preferences.data(forKey: AISearchSettings.preferencesKey)
        let request = description, token = UUID(), client = client
        generation = token; isGenerating = true
        task = Task { [weak self, original] in
            do {
                let settings: AISearchSettings
                if let suppliedSettings { settings = suppliedSettings }
                else { settings = await AISearchSettings.resolve(configurationData: configurationData).settings }
                try Task.checkCancellation()
                let service: AISearchService
                if let client { try settings.validate(); service = AISearchService(client: client) }
                else { service = try AISearchService(settings: settings) }
                let result = try await service.propose(request, state: original)
                guard let self, self.generation == token else { return }
                guard !Task.isCancelled, self.description == request,
                      self.preferences.data(forKey: AISearchSettings.preferencesKey) == configurationData else { self.cancel(); return }
                guard result.state != nil || result.clarification != nil else { throw AISearchError.message("The provider returned neither a search nor a clarification.") }
                // Consume this result before calling the parent: state changes,
                // dismissal and duplicate UI updates cannot apply it again.
                self.generation = UUID(); self.task = nil; self.isGenerating = false
                if let state = result.state { apply(state) }
                else { self.clarification = result.clarification }
            } catch {
                guard let self, self.generation == token else { return }
                self.generation = UUID(); self.task = nil; self.isGenerating = false
                guard !Task.isCancelled, !(error is CancellationError),
                      self.preferences.data(forKey: AISearchSettings.preferencesKey) == configurationData else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; isGenerating = false }
    func invalidate() { cancel(); clarification = nil; error = nil }
    deinit { task?.cancel() }
}

/// The toolbar entry stays available even when AI is disabled. Setup uses the
/// same settings view, and login discovery finishes before Search appears.
struct AISearchEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settingsModel: AISearchSettingsModel
    @StateObject private var searchModel: AISearchSheetModel
    @State private var isReady = false
    @State private var showsSetup = false
    @State private var settingsTask: Task<Void, Never>?
    @AppStorage private var configurationData: Data
    private let preferences: UserDefaults
    let apply: (SearchState) -> Void
    init(state: SearchState, preferences: UserDefaults = AISearchSettings.preferences,
         settingsModel: AISearchSettingsModel? = nil, client: (any AISearchGenerating)? = nil,
         apply: @escaping (SearchState) -> Void) {
        self.preferences = preferences; self.apply = apply
        _settingsModel = StateObject(wrappedValue: settingsModel ?? AISearchSettingsModel(preferences: preferences))
        _searchModel = StateObject(wrappedValue: AISearchSheetModel(state: state, preferences: preferences, client: client))
        _configurationData = AppStorage(wrappedValue: Data(), AISearchSettings.preferencesKey, store: preferences)
    }
    var body: some View {
        Group {
            if !isReady {
                VStack(spacing: 18) {
                    ProgressView("Checking AI Search setup…")
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelAISearch")
                }.padding(28).frame(width: 600, height: 160)
            } else if showsSetup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI Search Settings").font(.title2.weight(.semibold))
                    AISearchSettingsView(model: settingsModel)
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelAISearch")
                        Button("Continue") { showsSetup = false }
                            .disabled(!settingsModel.configuration.enabled || settingsModel.isResolving)
                            .keyboardShortcut(.defaultAction).accessibilityIdentifier("continueAISearch")
                    }
                }.padding(22).frame(width: 760, height: 620).nativeUtilityButtonStyle()
            } else {
                AISearchSheet(model: searchModel, preferences: preferences, configuration: settingsModel.configuration,
                              configure: { searchModel.invalidate(); showsSetup = true }, apply: apply)
            }
        }
        .task {
            searchModel.observeSettings(settingsModel)
            await settingsModel.resolve()
            guard !Task.isCancelled else { return }
            showsSetup = !settingsModel.configuration.enabled; isReady = true
        }
        .onChange(of: configurationData) { _, _ in
            let stored = AISearchSettings.load(from: preferences)
            guard stored != settingsModel.configuration else { return }
            searchModel.invalidate()
            settingsTask?.cancel()
            settingsTask = Task { await settingsModel.resolve(); if !Task.isCancelled, !settingsModel.configuration.enabled { showsSetup = true } }
        }
        .onDisappear { searchModel.cancel(); settingsTask?.cancel() }
    }
}

struct AISearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AISearchSheetModel
    @AppStorage private var configurationData: Data
    private let suppliedConfiguration: AISearchSettings?
    private let configure: (() -> Void)?
    let apply: (SearchState) -> Void
    init(state: SearchState, preferences: UserDefaults = AISearchSettings.preferences, apply: @escaping (SearchState) -> Void) {
        self.init(model: AISearchSheetModel(state: state, preferences: preferences), preferences: preferences, apply: apply)
    }
    init(model: AISearchSheetModel, preferences: UserDefaults = AISearchSettings.preferences,
         configuration: AISearchSettings? = nil, configure: (() -> Void)? = nil, apply: @escaping (SearchState) -> Void) {
        _model = StateObject(wrappedValue: model); self.apply = apply
        suppliedConfiguration = configuration; self.configure = configure
        _configurationData = AppStorage(wrappedValue: Data(), AISearchSettings.preferencesKey, store: preferences)
    }
    private var configuration: AISearchSettings { suppliedConfiguration ?? (try? JSONDecoder().decode(AISearchSettings.self, from: configurationData)) ?? .init() }
    private var providerModelTitle: String {
        let settings = configuration
        let model = settings.provider == .codex ? (settings.codexModel.isEmpty ? "Codex default" : settings.codexModel) : settings.model
        return settings.connection.title + ": " + model
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Describe a Search").font(.title2.weight(.semibold))
                Spacer()
                Text(providerModelTitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(providerModelTitle)
                    .accessibilityIdentifier("aiSearchProviderModel")
                if let configure {
                    Button(action: configure) { Image(systemName: "gearshape") }
                        .help("AI Search settings").accessibilityLabel("AI Search settings").accessibilityIdentifier("configureAISearch")
                }
            }
            Text("For example: Swift files containing TODO or Markdown files containing FIXME, modified in the last week.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.description)
                .font(.body).padding(6).background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .frame(height: 105).accessibilityLabel("Search description").accessibilityIdentifier("aiSearchDescription")
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).accessibilityIdentifier("aiSearchError")
            }
            if let clarification = model.clarification {
                Label(clarification, systemImage: "questionmark.circle").textSelection(.enabled)
                    .accessibilityIdentifier("aiSearchClarification")
            }
            Text("Sends your description and current search settings. Files and results stay here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelAISearch")
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancel() }.accessibilityIdentifier("stopAISearch")
                } else {
                    Button("Search") { model.generate(settings: configuration) { state in apply(state); dismiss() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !configuration.enabled)
                        .accessibilityIdentifier("generateAISearch")
                }
            }
        }
        .padding(22).frame(width: 760)
        .nativeUtilityButtonStyle()
        .onDisappear { model.cancel() }
        .onChange(of: configurationData) { _, _ in model.invalidate() }
        .onChange(of: configuration) { _, _ in model.invalidate() }
    }
}
