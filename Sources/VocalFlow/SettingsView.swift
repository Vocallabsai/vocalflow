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
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(width: 760, height: 580)
        .background(Color.vlWindowBg)
        .tint(.vlAccent)
        .toggleStyle(.switch)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(LinearGradient.vlAccent)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 25, height: 25)
                .shadow(color: Color.vlAccent.opacity(0.5), radius: 8, y: 1)

                VStack(alignment: .leading, spacing: 0) {
                    Text("VocalFlow")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.vlTextPrimary)
                    Text("Settings")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.vlTextSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { item in
                SidebarRow(
                    section: item,
                    isSelected: section == item,
                    namespace: pillNamespace
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        section = item
                    }
                }
            }
            Spacer(minLength: 0)

            Text("Version \(Self.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(Color.vlTextSecondary.opacity(0.7))
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 10)
        // Titlebar is transparent + full-size, so the sidebar runs the full window
        // height; this clears the traffic lights.
        .padding(.top, 46)
        .padding(.bottom, 14)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(Color.vlSidebarBg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.vlCardBorder).frame(width: 1)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader

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
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(section)                 // new identity per page → crossfade on switch
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Soft accent glow bleeding in from the top-right gives the content pane depth.
        .background(alignment: .topTrailing) {
            Circle()
                .fill(Color.vlAccent.opacity(0.13))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: 110, y: -150)
                .allowsHitTesting(false)
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(section.chipColor)
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .shadow(color: section.chipColor.opacity(0.45), radius: 8, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color.vlTextPrimary)
                Text(section.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vlTextSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Sections

    private var transcriptionSection: some View {
        VLCard {
            VLCardHeader(
                title: "Deepgram API",
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
                            .frame(width: 220)
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
            VLCardHeader(title: "Features")
            if !llmConfigured {
                Text("Configure an LLM provider in the AI Polish tab to enable these features.").vlCaption()
            }

            toggleRow("Spelling Correction", isOn: $appState.correctionModeEnabled)
            VLInlineDivider()
            toggleRow("Grammar Correction", isOn: $appState.grammarCorrectionEnabled)
            VLInlineDivider()
            toggleRow("Code-Mix Input", isOn: $appState.codeMixEnabled)
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

            VLInlineDivider()
            toggleRow("Convert to Language", isOn: $appState.targetLanguageEnabled)
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
                Text("Configure an LLM provider in the AI Polish tab to enable.").vlCaption()
            } else if appState.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty — no custom instructions applied.").vlCaption()
            }
        }
        .disabled(!llmConfigured)
    }

    // MARK: Dictionary (focus words)

    @State private var newTrigger = ""
    @State private var newReplacement = ""
    /// Original key of the entry being edited; nil = adding a new one.
    @State private var editingKey: String? = nil

    private var dictionaryEntries: [DictionaryEntry] {
        FocusWordsDictionary.parseEntries(appState.focusWords)
    }

    /// Favorites pinned first; original order preserved within each group.
    private var displayedEntries: [DictionaryEntry] {
        let favs = appState.favoriteFocusWords
        let all = dictionaryEntries
        return all.filter { favs.contains($0.key.lowercased()) }
             + all.filter { !favs.contains($0.key.lowercased()) }
    }

    /// Serialize back to the newline "key : value" format `FocusWordsDictionary`
    /// parses (and the type-over auto-learn appends to).
    private func saveEntries(_ entries: [DictionaryEntry]) {
        appState.focusWords = entries
            .map { $0.key == $0.value ? $0.key : "\($0.key) : \($0.value)" }
            .joined(separator: "\n")
    }

    private func isFavorite(_ entry: DictionaryEntry) -> Bool {
        appState.favoriteFocusWords.contains(entry.key.lowercased())
    }

    private func toggleFavorite(_ entry: DictionaryEntry) {
        let key = entry.key.lowercased()
        if appState.favoriteFocusWords.contains(key) {
            appState.favoriteFocusWords.remove(key)
        } else {
            appState.favoriteFocusWords.insert(key)
        }
    }

    private func beginEdit(_ entry: DictionaryEntry) {
        editingKey = entry.key
        newTrigger = entry.key
        newReplacement = entry.value == entry.key ? "" : entry.value
    }

    private func deleteEntry(_ entry: DictionaryEntry) {
        saveEntries(dictionaryEntries.filter { $0.key != entry.key })
        appState.favoriteFocusWords.remove(entry.key.lowercased())
        if editingKey == entry.key { resetEntryEditor() }
    }

    private func resetEntryEditor() {
        editingKey = nil
        newTrigger = ""
        newReplacement = ""
    }

    private func commitEntry() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let repl = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return }
        let entry = DictionaryEntry(key: trigger, value: repl.isEmpty ? trigger : repl)

        var entries = dictionaryEntries
        if let editing = editingKey, let idx = entries.firstIndex(where: { $0.key == editing }) {
            // Carry a favorite across a rename.
            if appState.favoriteFocusWords.contains(editing.lowercased()), editing.lowercased() != trigger.lowercased() {
                appState.favoriteFocusWords.remove(editing.lowercased())
                appState.favoriteFocusWords.insert(trigger.lowercased())
            }
            entries[idx] = entry
        } else if let idx = entries.firstIndex(where: { $0.key.lowercased() == trigger.lowercased() }) {
            entries[idx] = entry     // re-adding an existing trigger updates it
        } else {
            entries.append(entry)
        }
        saveEntries(entries)
        resetEntryEditor()
    }

    @ViewBuilder
    private var focusWordsSection: some View {
        VLCard {
            VLCardHeader(title: editingKey == nil ? "Add Entry" : "Edit “\(editingKey ?? "")”")
            Text("A plain entry locks the exact spelling of a name or term. Add a replacement to expand a spoken trigger into longer text — say “my email” and it types the full address.").vlCaption()

            HStack(spacing: 8) {
                TextField("Word or phrase", text: $newTrigger)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.vlTextPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .vlControlSurface()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vlTextSecondary)
                TextField("Replacement (optional)", text: $newReplacement)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.vlTextPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .vlControlSurface()
            }
            .onSubmit { commitEntry() }

            HStack(spacing: 10) {
                Button(editingKey == nil ? "Add to Dictionary" : "Save Changes") { commitEntry() }
                    .buttonStyle(VLAccentButtonStyle())
                    .disabled(newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editingKey != nil {
                    Button("Cancel") { resetEntryEditor() }
                        .buttonStyle(VLSecondaryButtonStyle())
                }
                Spacer()
            }
        }

        VLCard {
            VLCardHeader(title: "Entries (\(dictionaryEntries.count))")
            if dictionaryEntries.isEmpty {
                Text("Nothing here yet. Words you add — or spellings VocalFlow auto-learns when you correct a dictated word — will show up in this list.").vlCaption()
            } else {
                ForEach(Array(displayedEntries.enumerated()), id: \.element.key) { index, entry in
                    if index > 0 { VLInlineDivider() }
                    DictionaryEntryRow(
                        entry: entry,
                        isFavorite: isFavorite(entry),
                        isEditing: editingKey == entry.key,
                        onFavorite: { toggleFavorite(entry) },
                        onEdit: { beginEdit(entry) },
                        onDelete: { deleteEntry(entry) }
                    )
                }
            }
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

    /// Full-width row: label on the left, switch pinned to the trailing edge.
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.vlTextPrimary)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
    }

    private static let feedbackSoundOptions: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private var permissionsSection: some View {
        VLCard {
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
            toggleRow("Automatically check for updates", isOn: $updater.automaticChecksEnabled)
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
        case .focusWords:    return "Dictionary"
        case .permissions:   return "Permissions"
        case .about:         return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation:     return "Hotkey, feedback sound & microphone"
        case .transcription: return "Deepgram speech-to-text engine"
        case .aiPolish:      return "LLM cleanup applied after transcription"
        case .corrections:   return "Spelling, grammar, code-mix & translation"
        case .focusWords:    return "Exact spellings & spoken text expansions"
        case .permissions:   return "System access VocalFlow needs to work"
        case .about:         return "Version & software updates"
        }
    }

    var icon: String {
        switch self {
        case .dictation:     return "waveform"
        case .transcription: return "text.bubble.fill"
        case .aiPolish:      return "sparkles"
        case .corrections:   return "checkmark.seal.fill"
        case .focusWords:    return "character.book.closed.fill"
        case .permissions:   return "lock.shield.fill"
        case .about:         return "info"
        }
    }

    /// Icon-chip tint, System Settings-style: one hue per area so pages are
    /// recognizable at a glance. Hues picked to sit comfortably on the
    /// dark-purple ground.
    var chipColor: Color {
        switch self {
        case .dictation:     return Color(hex: 0x8B5CF6) // violet
        case .transcription: return Color(hex: 0x3B82F6) // blue
        case .aiPolish:      return Color(hex: 0xEC4899) // magenta
        case .corrections:   return Color(hex: 0x10B981) // emerald
        case .focusWords:    return Color(hex: 0xF59E0B) // amber
        case .permissions:   return Color(hex: 0xEF4444) // red
        case .about:         return Color(hex: 0x64748B) // slate
        }
    }
}

// One row in the sidebar: colored icon chip + label. The selected row gets an
// accent-gradient pill that slides between rows via matchedGeometryEffect.
private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(section.chipColor)
                    Image(systemName: section.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : Color.vlTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient.vlAccent)
                        .shadow(color: Color.vlAccent.opacity(0.4), radius: 7, y: 2)
                        .matchedGeometryEffect(id: "sidebar-pill", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// One dictionary entry: star (favorite) + key/replacement + edit/delete actions.
// Action icons stay subdued until the row is hovered, Wispr-style.
private struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let isFavorite: Bool
    let isEditing: Bool
    let onFavorite: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavorite ? Color(hex: 0xF59E0B) : Color.vlTextSecondary.opacity(hovering ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Unfavorite" : "Favorite (pins to top)")

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.key)
                    .fontWeight(.medium)
                    .foregroundStyle(isEditing ? Color.vlAccentHover : Color.vlTextPrimary)
                if entry.value != entry.key {
                    Text("→ \(entry.value)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vlTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            if hovering || isEditing {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vlTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vlError.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
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
