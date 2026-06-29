import Foundation
import Combine
import AppKit

private enum DefaultsKey: String {
    case selectedModel           = "selected_model"
    case selectedLanguage        = "selected_language"
    case selectedHotkey          = "selected_hotkey"
    case selectedLLMProvider     = "selected_llm_provider"
    case selectedGroqModel       = "selected_groq_model"
    case selectedOpenRouterModel = "selected_openrouter_model"
    case correctionModeEnabled   = "correction_mode_enabled"
    case grammarCorrectionEnabled = "grammar_correction_enabled"
    case codeMixEnabled          = "code_mix_enabled"
    case selectedCodeMix         = "selected_code_mix"
    case targetLanguageEnabled   = "target_language_enabled"
    case selectedTargetLanguage  = "selected_target_language"
    case feedbackSoundName       = "feedback_sound_name"
    case selectedAudioDeviceUID  = "selected_audio_device_uid"
    case customSystemPrompt      = "custom_system_prompt"
    case focusWords              = "focus_words"
}

private extension UserDefaults {
    func string(forKey key: DefaultsKey) -> String? { string(forKey: key.rawValue) }
    func bool(forKey key: DefaultsKey) -> Bool     { bool(forKey: key.rawValue) }
    func set(_ value: Any?, forKey key: DefaultsKey) { set(value, forKey: key.rawValue) }
}

enum RecordingState {
    case idle
    case recording
    case transcribing
    case error(String)
}

struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let raw: String
    let processed: String?

    /// What was actually typed into the focused app.
    var typed: String { processed ?? raw }

    /// True iff an LLM step ran and changed the text. Drives the "Copy raw"
    /// alternate menu item — there's nothing to compare against otherwise.
    var hasLLMProcessing: Bool {
        guard let processed else { return false }
        return processed != raw
    }
}

enum HotkeyOption: String, CaseIterable, Identifiable {
    case rightOption  = "right_option"
    case leftOption   = "left_option"
    case rightCommand = "right_command"
    case leftCommand  = "left_command"
    case fn           = "fn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption:  return "Right Option (⌥)"
        case .leftOption:   return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftCommand:  return "Left Command (⌘)"
        case .fn:           return "Fn (🌐)"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption:  return 61
        case .leftOption:   return 58
        case .rightCommand: return 54
        case .leftCommand:  return 55
        case .fn:           return 63
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption:   return .option
        case .rightCommand, .leftCommand: return .command
        case .fn:                         return .function
        }
    }
}

class AppState: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var deepgramAPIKey: String = ""
    @Published var lastTranscript: String = ""
    /// Running transcript shown in the recording overlay while capture is active.
    /// Updated from Deepgram interim + final results; cleared on each new session.
    @Published var liveTranscript: String = ""
    @Published var availableModels: [DeepgramModel] = []

    /// Newest first. Capped at `transcriptHistoryLimit`.
    @Published var transcriptHistory: [TranscriptEntry] = []
    private let transcriptHistoryLimit = 20

    func recordTranscript(raw: String, processed: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let entry = TranscriptEntry(timestamp: Date(), raw: raw, processed: processed)
            self.transcriptHistory.insert(entry, at: 0)
            if self.transcriptHistory.count > self.transcriptHistoryLimit {
                self.transcriptHistory.removeLast(self.transcriptHistory.count - self.transcriptHistoryLimit)
            }
        }
    }

    func clearTranscriptHistory() {
        DispatchQueue.main.async { [weak self] in
            self?.transcriptHistory.removeAll()
        }
    }

    /// Short user-facing message that auto-clears after a few seconds. Drives the
    /// menu-bar warning icon flash and tooltip.
    @Published var transientError: String? = nil
    private var transientErrorClearWorkItem: DispatchWorkItem?

    /// Surface a non-fatal error to the user. Logs it and triggers a 4s flash.
    func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transientError = message
            self.transientErrorClearWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.transientError = nil
            }
            self.transientErrorClearWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: .selectedModel) }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: .selectedLanguage) }
    }

    @Published var selectedHotkey: HotkeyOption {
        didSet { UserDefaults.standard.set(selectedHotkey.rawValue, forKey: .selectedHotkey) }
    }

    @Published var selectedLLMProvider: LLMProvider {
        didSet { UserDefaults.standard.set(selectedLLMProvider.rawValue, forKey: .selectedLLMProvider) }
    }

    @Published var groqAPIKey: String = ""
    @Published var availableGroqModels: [LLMModel] = []

    @Published var selectedGroqModel: String {
        didSet { UserDefaults.standard.set(selectedGroqModel, forKey: .selectedGroqModel) }
    }

    @Published var openRouterAPIKey: String = ""
    @Published var availableOpenRouterModels: [LLMModel] = []

    @Published var selectedOpenRouterModel: String {
        didSet { UserDefaults.standard.set(selectedOpenRouterModel, forKey: .selectedOpenRouterModel) }
    }

    @Published var correctionModeEnabled: Bool {
        didSet { UserDefaults.standard.set(correctionModeEnabled, forKey: .correctionModeEnabled) }
    }

    @Published var grammarCorrectionEnabled: Bool {
        didSet { UserDefaults.standard.set(grammarCorrectionEnabled, forKey: .grammarCorrectionEnabled) }
    }

    @Published var codeMixEnabled: Bool {
        didSet { UserDefaults.standard.set(codeMixEnabled, forKey: .codeMixEnabled) }
    }

    @Published var selectedCodeMix: String {
        didSet { UserDefaults.standard.set(selectedCodeMix, forKey: .selectedCodeMix) }
    }

    @Published var targetLanguageEnabled: Bool {
        didSet { UserDefaults.standard.set(targetLanguageEnabled, forKey: .targetLanguageEnabled) }
    }

    @Published var selectedTargetLanguage: String {
        didSet { UserDefaults.standard.set(selectedTargetLanguage, forKey: .selectedTargetLanguage) }
    }

    /// System sound played on record start/stop. Empty string = muted.
    @Published var feedbackSoundName: String {
        didSet { UserDefaults.standard.set(feedbackSoundName, forKey: .feedbackSoundName) }
    }

    /// Free-form text prepended to the LLM system prompt — lets users bias output
    /// (tone, terminology, glossary). Empty = disabled.
    @Published var customSystemPrompt: String {
        didSet { UserDefaults.standard.set(customSystemPrompt, forKey: .customSystemPrompt) }
    }

    /// Focus-words dictionary — newline/comma-separated terms (names, emails, jargon) whose exact
    /// spelling matters. Fed to Deepgram as keyterms (Nova-3 only) and to the LLM as a glossary.
    /// Empty = disabled.
    @Published var focusWords: String {
        didSet { UserDefaults.standard.set(focusWords, forKey: .focusWords) }
    }

    /// Parsed, de-duplicated focus-word trigger keys. Drives the Deepgram keyterm query.
    var focusWordTerms: [String] { FocusWordsDictionary.keys(focusWords) }

    /// AVCaptureDevice.uniqueID of the chosen mic. Empty string = system default.
    @Published var selectedAudioDeviceUID: String {
        didSet { UserDefaults.standard.set(selectedAudioDeviceUID, forKey: .selectedAudioDeviceUID) }
    }

    /// Populated from `refreshAudioDevices()`. Not persisted — devices come and go.
    @Published var availableAudioDevices: [AudioInputDevice] = []

    func refreshAudioDevices() {
        let devices = AudioEngine.availableInputDevices()
        DispatchQueue.main.async { [weak self] in
            self?.availableAudioDevices = devices
        }
    }

    let audioEngine: AudioEngine = AudioEngine()
    let deepgramService: DeepgramService
    let llmService: LLMService = LLMService()
    let textInjector: TextInjector = TextInjector()
    let keychainService: KeychainService = KeychainService()
    let audioMuter: SystemAudioMuter = SystemAudioMuter()

    init() {
        self.deepgramService = DeepgramService()
        self.deepgramAPIKey = keychainService.retrieve(key: "deepgram_api_key") ?? ""

        let storedModel = UserDefaults.standard.string(forKey: .selectedModel) ?? "nova-3-general"
        self.selectedModel = storedModel

        let storedLanguage = UserDefaults.standard.string(forKey: .selectedLanguage) ?? "en-US"
        self.selectedLanguage = storedLanguage

        let storedHotkey = UserDefaults.standard.string(forKey: .selectedHotkey) ?? ""
        self.selectedHotkey = HotkeyOption(rawValue: storedHotkey) ?? .rightOption

        let storedProvider = UserDefaults.standard.string(forKey: .selectedLLMProvider) ?? ""
        self.selectedLLMProvider = LLMProvider(rawValue: storedProvider) ?? .groq

        self.groqAPIKey = keychainService.retrieve(key: LLMProvider.groq.keychainKey) ?? ""
        self.selectedGroqModel = UserDefaults.standard.string(forKey: .selectedGroqModel) ?? ""

        self.openRouterAPIKey = keychainService.retrieve(key: LLMProvider.openRouter.keychainKey) ?? ""
        self.selectedOpenRouterModel = UserDefaults.standard.string(forKey: .selectedOpenRouterModel) ?? ""

        self.correctionModeEnabled = UserDefaults.standard.bool(forKey: .correctionModeEnabled)
        self.grammarCorrectionEnabled = UserDefaults.standard.bool(forKey: .grammarCorrectionEnabled)
        self.codeMixEnabled = UserDefaults.standard.bool(forKey: .codeMixEnabled)
        self.selectedCodeMix = UserDefaults.standard.string(forKey: .selectedCodeMix) ?? ""
        self.targetLanguageEnabled = UserDefaults.standard.bool(forKey: .targetLanguageEnabled)

        // Migration: code-mix styles used to live in the target-language picker.
        // They now belong only to the Code-Mix Input toggle.
        let storedTarget = UserDefaults.standard.string(forKey: .selectedTargetLanguage) ?? "English"
        let codeMixStyles: Set<String> = [
            "Hinglish", "Tanglish", "Benglish", "Kanglish", "Tenglish",
            "Minglish", "Punglish", "Spanglish", "Franglais", "Portuñol",
            "Chinglish", "Japlish", "Konglish", "Arabizi", "Sheng", "Camfranglais"
        ]
        self.selectedTargetLanguage = codeMixStyles.contains(storedTarget) ? "English" : storedTarget

        self.feedbackSoundName = UserDefaults.standard.string(forKey: .feedbackSoundName) ?? "Tink"
        self.customSystemPrompt = UserDefaults.standard.string(forKey: .customSystemPrompt) ?? ""
        self.focusWords = UserDefaults.standard.string(forKey: .focusWords) ?? ""
        self.selectedAudioDeviceUID = UserDefaults.standard.string(forKey: .selectedAudioDeviceUID) ?? ""

        self.deepgramService.onPartialTranscript = { [weak self] text in
            // Service already hops to the main queue.
            self?.liveTranscript = text
        }
    }

    // MARK: - Helpers for the selected LLM provider

    var currentLLMAPIKey: String {
        switch selectedLLMProvider {
        case .groq:       return groqAPIKey
        case .openRouter: return openRouterAPIKey
        }
    }

    var currentLLMModel: String {
        switch selectedLLMProvider {
        case .groq:       return selectedGroqModel
        case .openRouter: return selectedOpenRouterModel
        }
    }
}
