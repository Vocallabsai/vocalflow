import Foundation
import Combine
import AppKit

enum RecordingState {
    case idle
    case recording
    case transcribing
    case error(String)
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
        case .fn:           return "Fn"
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
    @Published var availableModels: [DeepgramModel] = []

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selected_model") }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selected_language") }
    }

    @Published var selectedHotkey: HotkeyOption {
        didSet { UserDefaults.standard.set(selectedHotkey.rawValue, forKey: "selected_hotkey") }
    }

    @Published var groqAPIKey: String = ""
    @Published var availableGroqModels: [GroqModel] = []

    @Published var selectedGroqModel: String {
        didSet { UserDefaults.standard.set(selectedGroqModel, forKey: "selected_groq_model") }
    }

    @Published var correctionModeEnabled: Bool {
        didSet { UserDefaults.standard.set(correctionModeEnabled, forKey: "correction_mode_enabled") }
    }

    @Published var grammarCorrectionEnabled: Bool {
        didSet { UserDefaults.standard.set(grammarCorrectionEnabled, forKey: "grammar_correction_enabled") }
    }

    @Published var codeMixEnabled: Bool {
        didSet { UserDefaults.standard.set(codeMixEnabled, forKey: "code_mix_enabled") }
    }

    @Published var selectedCodeMix: String {
        didSet { UserDefaults.standard.set(selectedCodeMix, forKey: "selected_code_mix") }
    }

    @Published var targetLanguageEnabled: Bool {
        didSet { UserDefaults.standard.set(targetLanguageEnabled, forKey: "target_language_enabled") }
    }

    @Published var selectedTargetLanguage: String {
        didSet { UserDefaults.standard.set(selectedTargetLanguage, forKey: "selected_target_language") }
    }

    let audioEngine: AudioEngine = AudioEngine()
    let deepgramService: DeepgramService
    let groqService: GroqService = GroqService()
    let textInjector: TextInjector = TextInjector()
    let keychainService: KeychainService = KeychainService()
    let audioMuter: SystemAudioMuter = SystemAudioMuter()

    init() {
        self.deepgramService = DeepgramService()
        self.deepgramAPIKey = keychainService.retrieve(key: "deepgram_api_key") ?? ""

        let storedModel = UserDefaults.standard.string(forKey: "selected_model") ?? "nova-3-general"
        self.selectedModel = storedModel

        let storedLanguage = UserDefaults.standard.string(forKey: "selected_language") ?? "en-US"
        self.selectedLanguage = storedLanguage

        let storedHotkey = UserDefaults.standard.string(forKey: "selected_hotkey") ?? ""
        self.selectedHotkey = HotkeyOption(rawValue: storedHotkey) ?? .rightOption

        self.groqAPIKey = keychainService.retrieve(key: "groq_api_key") ?? ""
        self.selectedGroqModel = UserDefaults.standard.string(forKey: "selected_groq_model") ?? ""
        self.correctionModeEnabled = UserDefaults.standard.bool(forKey: "correction_mode_enabled")
        self.grammarCorrectionEnabled = UserDefaults.standard.bool(forKey: "grammar_correction_enabled")
        self.codeMixEnabled = UserDefaults.standard.bool(forKey: "code_mix_enabled")
        self.selectedCodeMix = UserDefaults.standard.string(forKey: "selected_code_mix") ?? ""
        self.targetLanguageEnabled = UserDefaults.standard.bool(forKey: "target_language_enabled")
        self.selectedTargetLanguage = UserDefaults.standard.string(forKey: "selected_target_language") ?? "English"
    }
}
