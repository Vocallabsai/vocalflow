import SwiftUI
import AppKit

// NSTextField wrapper that forces left alignment and supports secure mode.
private struct LeftAlignedTextField: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = isSecure ? NSSecureTextField() : NSTextField()
        field.alignment = .left
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = NSColor(Color.vlTextPrimary)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.textColor = NSColor(Color.vlTextPrimary)
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

// Branded secure key field on the control surface, with a show/hide toggle.
private struct APIKeyField: View {
    @Binding var text: String
    @Binding var isVisible: Bool
    var idSalt: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LeftAlignedTextField(text: $text, isSecure: !isVisible)
                .frame(maxWidth: .infinity, minHeight: 20)
                .id("\(idSalt)-\(isVisible)")
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .vlControlSurface()
            Button(isVisible ? "Hide" : "Show") { isVisible.toggle() }
                .buttonStyle(VLSecondaryButtonStyle())
        }
    }
}

// Thin in-card divider in the brand border color.
private struct VLInlineDivider: View {
    var body: some View {
        Rectangle().fill(Color.vlCardBorder).frame(height: 1).padding(.vertical, 2)
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

    @State private var section: SettingsSection = .dictation

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(width: 720, height: 560)
        .background(Color.vlWindowBg)
        .tint(.vlAccent)
        .preferredColorScheme(.dark)
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

    // MARK: - Chrome (sidebar + paged content)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vlAccent)
                Text("VocalFlow")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.vlTextPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { item in
                SidebarRow(
                    title: item.title,
                    icon: item.icon,
                    isSelected: section == item
                ) { section = item }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Color.vlCardBg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.vlCardBorder).frame(width: 1)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch section {
                case .dictation:
                    hotkeySection
                    microphoneSection
                case .transcription:
                    transcriptionSection
                case .aiPolish:
                    llmSection
                case .corrections:
                    correctionsSection
                    customPromptSection
                case .focusWords:
                    focusWordsSection
                case .permissions:
                    permissionsSection
                case .about:
                    aboutSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private var transcriptionSection: some View {
        VLCard {
            VLCardHeader(
                title: "Transcription (Deepgram)",
                actionLabel: appState.availableModels.isEmpty ? "Fetch Models" : "Refresh",
                isLoading: isFetchingModels,
                isDisabled: appState.deepgramAPIKey.isEmpty,
                action: { Task { await fetchModels() } }
            )

            APIKeyField(text: $apiKeyInput, isVisible: $showAPIKey, idSalt: "deepgram")

            HStack(spacing: 10) {
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
                .buttonStyle(VLAccentButtonStyle())
                .disabled(apiKeyInput.isEmpty)

                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(saveStatus.contains("failed") ? Color.vlError : Color.vlSuccess)
                }
                Spacer()
                Link("Get an API key →",
                     destination: URL(staticString: "https://console.deepgram.com/signup"))
                    .font(.system(size: 11))
            }

            if !appState.availableModels.isEmpty || !appState.deepgramAPIKey.isEmpty {
                VLInlineDivider()

                VLField(label: "Model") {
                    if appState.availableModels.isEmpty {
                        TextField("", text: $appState.selectedModel)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Color.vlTextPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .vlControlSurface()
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
                    VLField(label: "Language") {
                        Picker("", selection: $appState.selectedLanguage) {
                            ForEach(languages, id: \.self) { lang in
                                Text(lang == "multi" ? "multi (Code-switching)" : lang).tag(lang)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            if let error = modelFetchError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.vlError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var llmSection: some View {
        VLCard {
            VLCardHeader(
                title: "LLM Post-Processing",
                actionLabel: currentProviderModels.isEmpty ? "Fetch Models" : "Refresh",
                isLoading: isFetchingLLMModels,
                isDisabled: appState.currentLLMAPIKey.isEmpty,
                action: { Task { await fetchLLMModels() } }
            )

            VLField(label: "Provider") {
                Picker("", selection: $appState.selectedLLMProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .onChange(of: appState.selectedLLMProvider) { _ in
                    syncLLMKeyInputForCurrentProvider()
                    llmModelFetchError = nil
                    llmSaveStatus = ""
                }
            }

            APIKeyField(text: $llmKeyInput, isVisible: $showLLMKey,
                        idSalt: appState.selectedLLMProvider.rawValue)

            HStack(spacing: 10) {
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
                .buttonStyle(VLAccentButtonStyle())
                .disabled(llmKeyInput.isEmpty)

                if !llmSaveStatus.isEmpty {
                    Text(llmSaveStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(llmSaveStatus.contains("failed") ? Color.vlError : Color.vlSuccess)
                }
                Spacer()
                Link("Get a \(appState.selectedLLMProvider.displayName) key →",
                     destination: appState.selectedLLMProvider.signupURL)
                    .font(.system(size: 11))
            }

            if !currentProviderModels.isEmpty {
                VLInlineDivider()
                VLField(label: "Model") {
                    Picker("", selection: currentProviderSelectedModel) {
                        ForEach(currentProviderModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            if let error = llmModelFetchError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.vlError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var correctionsSection: some View {
        VLCard {
            VLCardHeader(title: "Corrections & Features")
            if !llmConfigured {
                Text("Configure an LLM provider above to enable these features.").vlCaption()
            }

            Toggle("Spelling Correction", isOn: $appState.correctionModeEnabled)
            Toggle("Grammar Correction", isOn: $appState.grammarCorrectionEnabled)
            Toggle("Code-Mix Input", isOn: $appState.codeMixEnabled)
            if appState.codeMixEnabled {
                VLField(label: "Style") {
                    Picker("", selection: $appState.selectedCodeMix) {
                        Text("Select…").tag("")
                        ForEach(codeMixOptions, id: \.name) { opt in
                            Text("\(opt.name) (\(opt.description))").tag(opt.name)
                        }
                    }
                    .labelsHidden()
                }
            }

            Toggle("Convert to Language", isOn: $appState.targetLanguageEnabled)
            if appState.targetLanguageEnabled {
                VLField(label: "Target") {
                    Picker("", selection: $appState.selectedTargetLanguage) {
                        ForEach(targetLanguages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .disabled(!llmConfigured)
    }

    private var customPromptSection: some View {
        VLCard {
            VLCardHeader(title: "Custom Instructions")
            Text("Prepended to the LLM system prompt on every dictation. Use it to bias output (e.g. \"always formal English\", \"use Markdown lists\", or supply a glossary).").vlCaption()

            TextEditor(text: $appState.customSystemPrompt)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.vlTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90, maxHeight: 180)
                .vlControlSurface()

            if !llmConfigured {
                Text("Configure an LLM provider above to enable.").vlCaption()
            } else if appState.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty — no custom instructions applied.").vlCaption()
            }
        }
        .disabled(!llmConfigured)
    }

    private var focusWordsSection: some View {
        VLCard {
            VLCardHeader(title: "Focus Words")
            Text("One entry per line. Use \"trigger : replacement\" to expand a phrase you say into longer text — e.g. \"my email : johndoe@gmail.com\" types the address whenever you say \"my email\". A line with no colon keeps that word spelled exactly as written (handy for names).").vlCaption()

            TextEditor(text: $appState.focusWords)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.vlTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90, maxHeight: 180)
                .vlControlSurface()
        }
    }

    private var microphoneSection: some View {
        VLCard {
            VLCardHeader(title: "Microphone", actionLabel: "Refresh",
                         action: { appState.refreshAudioDevices() })
            VLField(label: "Input device") {
                Picker("", selection: $appState.selectedAudioDeviceUID) {
                    Text("System default").tag("")
                    ForEach(appState.availableAudioDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                    if !appState.selectedAudioDeviceUID.isEmpty,
                       !appState.availableAudioDevices.contains(where: { $0.id == appState.selectedAudioDeviceUID }) {
                        Text("Unavailable (\(appState.selectedAudioDeviceUID))")
                            .tag(appState.selectedAudioDeviceUID)
                    }
                }
                .labelsHidden()
            }
            Text("Pin recording to a specific mic. Useful when macOS picks AirPods over your USB mic.").vlCaption()
        }
    }

    private var hotkeySection: some View {
        VLCard {
            VLCardHeader(title: "Hotkey")
            VLField(label: "Trigger key") {
                Picker("", selection: $appState.selectedHotkey) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
            }
            Text("Hold the selected key to record, release to transcribe.").vlCaption()

            VLField(label: "Feedback sound") {
                Picker("", selection: $appState.feedbackSoundName) {
                    Text("None (muted)").tag("")
                    ForEach(Self.feedbackSoundOptions, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .onChange(of: appState.feedbackSoundName) { newValue in
                    if !newValue.isEmpty {
                        NSSound(named: NSSound.Name(newValue))?.play()
                    }
                }
            }
        }
    }

    private static let feedbackSoundOptions: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private var permissionsSection: some View {
        VLCard {
            VLCardHeader(title: "Permissions")
            PermissionRowView(
                label: "Microphone",
                detail: "Required for audio capture",
                settingsURL: SystemPrefsURL.microphone
            )
            VLInlineDivider()
            PermissionRowView(
                label: "Accessibility",
                detail: "Required for global hotkey and text injection",
                settingsURL: SystemPrefsURL.accessibility
            )
        }
    }

    private var aboutSection: some View {
        VLCard {
            VLCardHeader(title: "About")
            HStack {
                Text("Version").foregroundStyle(Color.vlTextPrimary)
                Text(Self.appVersion).foregroundStyle(Color.vlTextSecondary)
                Spacer()
                Button("Check for Updates") {
                    updater.checkForUpdates()
                }
                .buttonStyle(VLAccentButtonStyle())
                .disabled(!updater.canCheckForUpdates)
            }
            Toggle("Automatically check for updates", isOn: $updater.automaticChecksEnabled)
            Text("VocalFlow — dictate into any text field using ASR").vlCaption()
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

// Sidebar navigation model: each case is one page in the settings window.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation, transcription, aiPolish, corrections, focusWords, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation:     return "Dictation"
        case .transcription: return "Transcription"
        case .aiPolish:      return "AI Polish"
        case .corrections:   return "Corrections"
        case .focusWords:    return "Focus Words"
        case .permissions:   return "Permissions"
        case .about:         return "About"
        }
    }

    var icon: String {
        switch self {
        case .dictation:     return "waveform"
        case .transcription: return "text.bubble"
        case .aiPolish:      return "sparkles"
        case .corrections:   return "text.badge.checkmark"
        case .focusWords:    return "character.book.closed"
        case .permissions:   return "lock.shield"
        case .about:         return "info.circle"
        }
    }
}

// One row in the sidebar: icon + label, with selected/hover highlight.
private struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.vlAccent : Color.vlTextSecondary)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.vlTextPrimary : Color.vlTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.vlAccent.opacity(0.16)
                                     : (hovering ? Color.vlControlBg : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PermissionRowView: View {
    let label: String
    let detail: String
    let settingsURL: URL

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium).foregroundStyle(Color.vlTextPrimary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.vlTextSecondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(settingsURL)
            }
            .buttonStyle(VLSecondaryButtonStyle())
        }
    }
}
