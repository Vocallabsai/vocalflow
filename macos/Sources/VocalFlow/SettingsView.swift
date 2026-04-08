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

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var showAPIKey = false
    @State private var saveStatus = ""
    @State private var isFetchingModels = false
    @State private var modelFetchError: String? = nil
    @State private var groqKeyInput: String = ""
    @State private var showGroqKey = false
    @State private var groqSaveStatus = ""
    @State private var isFetchingGroqModels = false
    @State private var groqModelFetchError: String? = nil
    @State private var codeMixOptions: [(name: String, description: String)] = [
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
    @State private var targetLanguages: [String] = [
        // Pure languages
        "English", "Hindi", "Spanish", "French", "German",
        "Portuguese", "Japanese", "Korean", "Arabic", "Bengali",
        "Tamil", "Telugu", "Kannada", "Marathi", "Punjabi",
        "Russian", "Chinese (Simplified)", "Italian", "Dutch", "Swahili",
        // Mixed / code-switch styles
        "Hinglish", "Tanglish", "Benglish", "Kanglish", "Tenglish",
        "Minglish", "Punglish", "Spanglish", "Franglais", "Portuñol",
        "Chinglish", "Japlish", "Konglish", "Arabizi", "Sheng", "Camfranglais",
    ]

    var body: some View {
        Form {
            Section("ASR API Key") {
                HStack(alignment: .center, spacing: 8) {
                    LeftAlignedTextField(text: $apiKeyInput, isSecure: !showAPIKey)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .id(showAPIKey)

                    Button(showAPIKey ? "Hide" : "Show") {
                        showAPIKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save") {
                        appState.keychainService.store(key: "deepgram_api_key", value: apiKeyInput)
                        appState.deepgramAPIKey = apiKeyInput
                        saveStatus = "Saved!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            saveStatus = ""
                        }
                    }
                    .disabled(apiKeyInput.isEmpty)

                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }

                Link("Get a free API key →", destination: URL(string: "https://console.deepgram.com/signup")!)
                    .font(.caption)
            }

            Section(header: HStack {
                Spacer()
                Button {
                    fetchGroqModels()
                } label: {
                    if isFetchingGroqModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(appState.availableGroqModels.isEmpty ? "Fetch Models" : "Refresh")
                            .font(.caption)
                    }
                }
                .disabled(appState.groqAPIKey.isEmpty || isFetchingGroqModels)
            }) {
                HStack(alignment: .center, spacing: 8) {
                    LeftAlignedTextField(text: $groqKeyInput, isSecure: !showGroqKey)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .id(showGroqKey)
                    Button(showGroqKey ? "Hide" : "Show") {
                        showGroqKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save") {
                        appState.keychainService.store(key: "groq_api_key", value: groqKeyInput)
                        appState.groqAPIKey = groqKeyInput
                        groqSaveStatus = "Saved!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { groqSaveStatus = "" }
                    }
                    .disabled(groqKeyInput.isEmpty)

                    if !groqSaveStatus.isEmpty {
                        Text(groqSaveStatus).foregroundColor(.green).font(.caption)
                    }
                }

                if !appState.availableGroqModels.isEmpty {
                    HStack {
                        Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                        Picker("", selection: $appState.selectedGroqModel) {
                            ForEach(appState.availableGroqModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                if let error = groqModelFetchError {
                    Text(error).foregroundColor(.red).font(.caption)
                }
            }

            Section(header: HStack {
                Spacer()
                Button {
                    fetchModels()
                } label: {
                    if isFetchingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(appState.availableModels.isEmpty ? "Fetch Models" : "Refresh")
                            .font(.caption)
                    }
                }
                .disabled(appState.deepgramAPIKey.isEmpty || isFetchingModels)
            }) {
                HStack {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if appState.availableModels.isEmpty {
                        TextField("", text: $appState.selectedModel)
                            .frame(maxWidth: .infinity)
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

                if let error = modelFetchError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
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

            Section("Corrections & Features") {
                Toggle("Spelling Correction", isOn: $appState.correctionModeEnabled)
                Toggle("Grammar Correction", isOn: $appState.grammarCorrectionEnabled)

                Toggle("Code-Mix Input", isOn: $appState.codeMixEnabled)
                if appState.codeMixEnabled {
                    Picker("Language", selection: $appState.selectedCodeMix) {
                        Text("Select...").tag("")
                        ForEach(codeMixOptions, id: \.name) { opt in
                            Text("\(opt.name) (\(opt.description))").tag(opt.name)
                        }
                    }
                }

                Toggle("Convert to Language", isOn: $appState.targetLanguageEnabled)
                if appState.targetLanguageEnabled {
                    Picker("Target Language", selection: $appState.selectedTargetLanguage) {
                        ForEach(targetLanguages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }
            }

            Section("Hotkey") {
                Picker("Trigger key", selection: $appState.selectedHotkey) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Text("Hold the selected key to record, release to transcribe.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Section("Permissions") {
                PermissionRowView(
                    label: "Microphone",
                    detail: "Required for audio capture",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                PermissionRowView(
                    label: "Accessibility",
                    detail: "Required for global hotkey and text injection",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                Text("VocalFlow — dictate into any text field using ASR")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 620)
        .onAppear {
            apiKeyInput = appState.deepgramAPIKey
            groqKeyInput = appState.groqAPIKey
            if appState.availableModels.isEmpty && !appState.deepgramAPIKey.isEmpty {
                fetchModels()
            }
            if appState.availableGroqModels.isEmpty && !appState.groqAPIKey.isEmpty {
                fetchGroqModels()
            }
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        modelFetchError = nil
        appState.deepgramService.fetchModels(apiKey: appState.deepgramAPIKey) { models in
            DispatchQueue.main.async {
                isFetchingModels = false
                if models.isEmpty {
                    modelFetchError = "Could not fetch models. Check your API key."
                } else {
                    appState.availableModels = models
                    if !models.contains(where: { $0.canonicalName == appState.selectedModel }) {
                        appState.selectedModel = models[0].canonicalName
                    }
                    resetLanguageForCurrentModel()
                }
            }
        }
    }

    private func fetchGroqModels() {
        isFetchingGroqModels = true
        groqModelFetchError = nil
        appState.groqService.fetchModels(apiKey: appState.groqAPIKey) { models in
            DispatchQueue.main.async {
                isFetchingGroqModels = false
                if models.isEmpty {
                    groqModelFetchError = "Could not fetch models. Check your Groq API key."
                } else {
                    appState.availableGroqModels = models
                    if !models.contains(where: { $0.id == appState.selectedGroqModel }) {
                        appState.selectedGroqModel = models[0].id
                    }
                }
            }
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
    let settingsURL: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: settingsURL)!)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
        }
    }
}
