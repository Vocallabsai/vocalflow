import SwiftUI
import AppKit

// NSTextField wrapper that forces left alignment and supports secure mode
private struct LeftAlignedTextField: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = isSecure ? NSSecureTextField() : NSTextField()
        field.alignment = .left
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { text = field.stringValue }
        }
    }
}

// Section header with a trailing action button (e.g. Fetch / Refresh)
private struct SectionHeader: View {
    let title: String
    let actionLabel: String?
    let isLoading: Bool
    let isDisabled: Bool
    let action: (() -> Void)?

    init(_ title: String,
         actionLabel: String? = nil,
         isLoading: Bool = false,
         isDisabled: Bool = false,
         action: (() -> Void)? = nil) {
        self.title = title
        self.actionLabel = actionLabel
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let actionLabel, let action {
                Button(action: action) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(actionLabel).font(.caption)
                    }
                }
                .disabled(isDisabled || isLoading)
            }
        }
    }
}

// Labeled secure key field with a show/hide toggle
private struct APIKeyField: View {
    @Binding var text: String
    @Binding var isVisible: Bool
    var idSalt: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LeftAlignedTextField(text: $text, isSecure: !isVisible)
                .frame(maxWidth: .infinity, minHeight: 20)
                .id("\(idSalt)-\(isVisible)")
            Button(isVisible ? "Hide" : "Show") {
                isVisible.toggle()
            }
            .buttonStyle(.borderless)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updater: UpdaterManager

    // Deepgram (transcription)
    @State private var apiKeyInput: String = ""
    @State private var showAPIKey = false
    @State private var saveStatus = ""
    @State private var isFetchingModels = false
    @State private var modelFetchError: String? = nil

    // LLM (Groq / OpenRouter)
    @State private var llmKeyInput: String = ""
    @State private var showLLMKey = false
    @State private var llmSaveStatus = ""
    @State private var isFetchingLLMModels = false
    @State private var llmModelFetchError: String? = nil

    private let codeMixOptions: [(name: String, description: String)] = [
        ("Hinglish",     "Hindi + English"),
        ("Tanglish",     "Tamil + English"),
        ("Benglish",     "Bengali + English"),
        ("Kanglish",     "Kannada + English"),
        ("Tenglish",     "Telugu + English"),
        ("Minglish",     "Marathi + English"),
        ("Punglish",     "Punjabi + English"),
        ("Spanglish",    "Spanish + English"),
        ("Franglais",    "French + English"),
        ("Portuñol",     "Portuguese + Spanish"),
        ("Chinglish",    "Chinese + English"),
        ("Japlish",      "Japanese + English"),
        ("Konglish",     "Korean + English"),
        ("Arabizi",      "Arabic + English"),
        ("Sheng",        "Swahili + English"),
        ("Camfranglais", "French + English + local languages"),
    ]
    private let targetLanguages: [String] = [
        "English", "Hindi", "Spanish", "French", "German",
        "Portuguese", "Japanese", "Korean", "Arabic", "Bengali",
        "Tamil", "Telugu", "Kannada", "Marathi", "Punjabi",
        "Russian", "Chinese (Simplified)", "Italian", "Dutch", "Swahili",
    ]

    private var currentProviderModels: [LLMModel] {
        switch appState.selectedLLMProvider {
        case .groq:       return appState.availableGroqModels
        case .openRouter: return appState.availableOpenRouterModels
        }
    }

    private var currentProviderSelectedModel: Binding<String> {
        switch appState.selectedLLMProvider {
        case .groq:       return $appState.selectedGroqModel
        case .openRouter: return $appState.selectedOpenRouterModel
        }
    }

    private var llmConfigured: Bool {
        !appState.currentLLMAPIKey.isEmpty && !appState.currentLLMModel.isEmpty
    }

    var body: some View {
        Form {
            transcriptionSection
            llmSection
            correctionsSection
            customPromptSection
            microphoneSection
            hotkeySection
            permissionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onAppear {
            apiKeyInput = appState.deepgramAPIKey
            syncLLMKeyInputForCurrentProvider()
            if appState.availableModels.isEmpty && !appState.deepgramAPIKey.isEmpty {
                Task { await fetchModels() }
            }
            if currentProviderModels.isEmpty && !appState.currentLLMAPIKey.isEmpty {
                Task { await fetchLLMModels() }
            }
            appState.refreshAudioDevices()
        }
    }

    private var microphoneSection: some View {
        Section(header: SectionHeader(
            "Microphone",
            actionLabel: "Refresh",
            action: { appState.refreshAudioDevices() }
        )) {
            Picker("Input device", selection: $appState.selectedAudioDeviceUID) {
                Text("System default").tag("")
                ForEach(appState.availableAudioDevices) { device in
                    Text(device.name).tag(device.id)
                }
                // Surface a stale selection so the user knows they're on a
                // device that isn't currently plugged in.
                if !appState.selectedAudioDeviceUID.isEmpty,
                   !appState.availableAudioDevices.contains(where: { $0.id == appState.selectedAudioDeviceUID }) {
                    Text("Unavailable (\(appState.selectedAudioDeviceUID))")
                        .tag(appState.selectedAudioDeviceUID)
                }
            }
            Text("Pin recording to a specific mic. Useful when macOS picks AirPods over your USB mic.")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Sections

    private var transcriptionSection: some View {
        Section(header: SectionHeader(
            "Transcription (Deepgram)",
            actionLabel: appState.availableModels.isEmpty ? "Fetch Models" : "Refresh",
            isLoading: isFetchingModels,
            isDisabled: appState.deepgramAPIKey.isEmpty,
            action: { Task { await fetchModels() } }
        )) {
            APIKeyField(text: $apiKeyInput, isVisible: $showAPIKey, idSalt: "deepgram")

            HStack {
                Button("Save & Verify") {
                    appState.keychainService.store(key: "deepgram_api_key", value: apiKeyInput)
                    appState.deepgramAPIKey = apiKeyInput
                    saveStatus = "Verifying…"
                    Task { @MainActor in
                        let ok = await fetchModels()
                        saveStatus = ok ? "Saved & verified ✓" : "Saved (verification failed)"
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        saveStatus = ""
                    }
                }
                .disabled(apiKeyInput.isEmpty)

                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .foregroundColor(saveStatus.contains("failed") ? .red : .green)
                        .font(.caption)
                }
                Spacer()
                Link("Get an API key →",
                     destination: URL(staticString: "https://console.deepgram.com/signup"))
                    .font(.caption)
            }

            if !appState.availableModels.isEmpty || !appState.deepgramAPIKey.isEmpty {
                Divider().padding(.vertical, 2)

                HStack {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    if appState.availableModels.isEmpty {
                        TextField("", text: $appState.selectedModel)
                    } else {
                        Picker("", selection: $appState.selectedModel) {
                            ForEach(appState.availableModels) { model in
                                Text(model.canonicalName).tag(model.canonicalName)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: appState.selectedModel) { _ in
                            resetLanguageForCurrentModel()
                        }
                    }
                }

                let languages = appState.availableModels
                    .first(where: { $0.canonicalName == appState.selectedModel })?.languages ?? []

                if !languages.isEmpty {
                    Picker("Language", selection: $appState.selectedLanguage) {
                        ForEach(languages, id: \.self) { lang in
                            Text(lang == "multi" ? "multi (Code-switching)" : lang).tag(lang)
                        }
                    }
                }
            }

            if let error = modelFetchError {
                Text(error).foregroundColor(.red).font(.caption)
            }
        }
    }

    private var llmSection: some View {
        Section(header: SectionHeader(
            "LLM Post-Processing",
            actionLabel: currentProviderModels.isEmpty ? "Fetch Models" : "Refresh",
            isLoading: isFetchingLLMModels,
            isDisabled: appState.currentLLMAPIKey.isEmpty,
            action: { Task { await fetchLLMModels() } }
        )) {
            Picker("Provider", selection: $appState.selectedLLMProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .onChange(of: appState.selectedLLMProvider) { _ in
                syncLLMKeyInputForCurrentProvider()
                llmModelFetchError = nil
                llmSaveStatus = ""
            }

            APIKeyField(text: $llmKeyInput, isVisible: $showLLMKey,
                        idSalt: appState.selectedLLMProvider.rawValue)

            HStack {
                Button("Save & Verify") {
                    let provider = appState.selectedLLMProvider
                    appState.keychainService.store(key: provider.keychainKey, value: llmKeyInput)
                    switch provider {
                    case .groq:       appState.groqAPIKey = llmKeyInput
                    case .openRouter: appState.openRouterAPIKey = llmKeyInput
                    }
                    llmSaveStatus = "Verifying…"
                    Task { @MainActor in
                        let ok = await fetchLLMModels()
                        llmSaveStatus = ok ? "Saved & verified ✓" : "Saved (verification failed)"
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        llmSaveStatus = ""
                    }
                }
                .disabled(llmKeyInput.isEmpty)

                if !llmSaveStatus.isEmpty {
                    Text(llmSaveStatus)
                        .foregroundColor(llmSaveStatus.contains("failed") ? .red : .green)
                        .font(.caption)
                }
                Spacer()
                Link("Get a \(appState.selectedLLMProvider.displayName) key →",
                     destination: appState.selectedLLMProvider.signupURL)
                    .font(.caption)
            }

            if !currentProviderModels.isEmpty {
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: currentProviderSelectedModel) {
                        ForEach(currentProviderModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            if let error = llmModelFetchError {
                Text(error).foregroundColor(.red).font(.caption)
            }
        }
    }

    private var correctionsSection: some View {
        Section("Corrections & Features") {
            if !llmConfigured {
                Text("Configure an LLM provider above to enable these features.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Toggle("Spelling Correction", isOn: $appState.correctionModeEnabled)
            Toggle("Grammar Correction", isOn: $appState.grammarCorrectionEnabled)

            Toggle("Code-Mix Input", isOn: $appState.codeMixEnabled)
            if appState.codeMixEnabled {
                Picker("Style", selection: $appState.selectedCodeMix) {
                    Text("Select…").tag("")
                    ForEach(codeMixOptions, id: \.name) { opt in
                        Text("\(opt.name) (\(opt.description))").tag(opt.name)
                    }
                }
            }

            Toggle("Convert to Language", isOn: $appState.targetLanguageEnabled)
            if appState.targetLanguageEnabled {
                Picker("Target", selection: $appState.selectedTargetLanguage) {
                    ForEach(targetLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
            }
        }
        .disabled(!llmConfigured)
    }

    private var customPromptSection: some View {
        Section("Custom Instructions") {
            Text("Prepended to the LLM system prompt on every dictation. Use it to bias output (e.g. \"always formal English\", \"use Markdown lists\", or supply a glossary).")
                .foregroundColor(.secondary)
                .font(.caption)

            TextEditor(text: $appState.customSystemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            if !llmConfigured {
                Text("Configure an LLM provider above to enable.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else if appState.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty — no custom instructions applied.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .disabled(!llmConfigured)
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            Picker("Trigger key", selection: $appState.selectedHotkey) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Text("Hold the selected key to record, release to transcribe.")
                .foregroundColor(.secondary)
                .font(.caption)

            Picker("Feedback sound", selection: $appState.feedbackSoundName) {
                Text("None (muted)").tag("")
                ForEach(Self.feedbackSoundOptions, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .onChange(of: appState.feedbackSoundName) { newValue in
                if !newValue.isEmpty {
                    NSSound(named: NSSound.Name(newValue))?.play()
                }
            }
        }
    }

    private static let feedbackSoundOptions: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRowView(
                label: "Microphone",
                detail: "Required for audio capture",
                settingsURL: SystemPrefsURL.microphone
            )
            PermissionRowView(
                label: "Accessibility",
                detail: "Required for global hotkey and text injection",
                settingsURL: SystemPrefsURL.accessibility
            )
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                LabeledContent("Version", value: Self.appVersion)
                Spacer()
                Button("Check for Updates") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            Toggle("Automatically check for updates", isOn: $updater.automaticChecksEnabled)
            Text("VocalFlow — dictate into any text field using ASR")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }

    // MARK: - Actions

    private func syncLLMKeyInputForCurrentProvider() {
        switch appState.selectedLLMProvider {
        case .groq:       llmKeyInput = appState.groqAPIKey
        case .openRouter: llmKeyInput = appState.openRouterAPIKey
        }
    }

    @MainActor
    @discardableResult
    private func fetchModels() async -> Bool {
        isFetchingModels = true
        modelFetchError = nil
        defer { isFetchingModels = false }
        do {
            let models = try await appState.deepgramService.fetchModels(apiKey: appState.deepgramAPIKey)
            guard !models.isEmpty else {
                modelFetchError = "Deepgram returned no streaming models."
                return false
            }
            appState.availableModels = models
            if !models.contains(where: { $0.canonicalName == appState.selectedModel }) {
                appState.selectedModel = models[0].canonicalName
            }
            resetLanguageForCurrentModel()
            return true
        } catch let error as APIError {
            modelFetchError = error.userMessage
            return false
        } catch {
            modelFetchError = error.localizedDescription
            return false
        }
    }

    @MainActor
    @discardableResult
    private func fetchLLMModels() async -> Bool {
        let provider = appState.selectedLLMProvider
        let apiKey = appState.currentLLMAPIKey
        isFetchingLLMModels = true
        llmModelFetchError = nil
        defer { isFetchingLLMModels = false }
        do {
            let models = try await appState.llmService.fetchModels(provider: provider, apiKey: apiKey)
            // Provider may have changed during the await; ignore the stale result.
            guard provider == appState.selectedLLMProvider else { return false }
            guard !models.isEmpty else {
                llmModelFetchError = "\(provider.displayName) returned no models."
                return false
            }
            switch provider {
            case .groq:
                appState.availableGroqModels = models
                if !models.contains(where: { $0.id == appState.selectedGroqModel }) {
                    appState.selectedGroqModel = models[0].id
                }
            case .openRouter:
                appState.availableOpenRouterModels = models
                if !models.contains(where: { $0.id == appState.selectedOpenRouterModel }) {
                    appState.selectedOpenRouterModel = models[0].id
                }
            }
            return true
        } catch let error as APIError {
            guard provider == appState.selectedLLMProvider else { return false }
            llmModelFetchError = error.userMessage
            return false
        } catch {
            guard provider == appState.selectedLLMProvider else { return false }
            llmModelFetchError = error.localizedDescription
            return false
        }
    }

    private func resetLanguageForCurrentModel() {
        let languages = appState.availableModels
            .first(where: { $0.canonicalName == appState.selectedModel })?.languages ?? []
        if !languages.isEmpty && !languages.contains(appState.selectedLanguage) {
            appState.selectedLanguage = languages.first!
        }
    }
}

private struct PermissionRowView: View {
    let label: String
    let detail: String
    let settingsURL: URL

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(settingsURL)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
        }
    }
}
