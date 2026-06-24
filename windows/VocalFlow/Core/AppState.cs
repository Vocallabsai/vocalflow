using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using VocalFlow.Services;

namespace VocalFlow.Core;

/// <summary>
/// Central observable application state and the home of the shared services. Port of the macOS
/// AppState (ObservableObject -> INotifyPropertyChanged). Persisted preferences go through
/// SettingsStore; secret API keys go through CredentialStore (DPAPI).
/// </summary>
public sealed class AppState : INotifyPropertyChanged
{
    // Persisted-preference keys (match the macOS DefaultsKey raw values).
    private static class Keys
    {
        public const string SelectedModel = "selected_model";
        public const string SelectedLanguage = "selected_language";
        public const string SelectedHotkey = "selected_hotkey";
        public const string SelectedLlmProvider = "selected_llm_provider";
        public const string SelectedGroqModel = "selected_groq_model";
        public const string SelectedOpenRouterModel = "selected_openrouter_model";
        public const string CorrectionModeEnabled = "correction_mode_enabled";
        public const string GrammarCorrectionEnabled = "grammar_correction_enabled";
        public const string CodeMixEnabled = "code_mix_enabled";
        public const string SelectedCodeMix = "selected_code_mix";
        public const string TargetLanguageEnabled = "target_language_enabled";
        public const string SelectedTargetLanguage = "selected_target_language";
        public const string FeedbackSoundName = "feedback_sound_name";
        public const string SelectedAudioDeviceUid = "selected_audio_device_uid";
        public const string CustomSystemPrompt = "custom_system_prompt";
    }

    // Shared services.
    public AudioEngine AudioEngine { get; } = new();
    public DeepgramService DeepgramService { get; } = new();
    public LlmService LlmService { get; } = new();
    public TextInjector TextInjector { get; } = new();
    public SystemAudioMuter AudioMuter { get; } = new();
    public SettingsStore Settings { get; } = new();
    public CredentialStore Credentials { get; } = new();

    private const int TranscriptHistoryLimit = 20;
    private int _errorGeneration;

    public AppState()
    {
        DeepgramApiKey = Credentials.Retrieve("deepgram_api_key") ?? "";

        _selectedModel = Settings.GetString(Keys.SelectedModel) ?? "nova-3-general";
        _selectedLanguage = Settings.GetString(Keys.SelectedLanguage) ?? "en-US";
        _selectedHotkey = HotkeyOptionExtensions.FromRawValue(Settings.GetString(Keys.SelectedHotkey));
        _selectedLlmProvider = LlmProviderExtensions.FromRawValue(Settings.GetString(Keys.SelectedLlmProvider));

        GroqApiKey = Credentials.Retrieve(LlmProvider.Groq.CredentialKey()) ?? "";
        _selectedGroqModel = Settings.GetString(Keys.SelectedGroqModel) ?? "";

        OpenRouterApiKey = Credentials.Retrieve(LlmProvider.OpenRouter.CredentialKey()) ?? "";
        _selectedOpenRouterModel = Settings.GetString(Keys.SelectedOpenRouterModel) ?? "";

        _correctionModeEnabled = Settings.GetBool(Keys.CorrectionModeEnabled);
        _grammarCorrectionEnabled = Settings.GetBool(Keys.GrammarCorrectionEnabled);
        _codeMixEnabled = Settings.GetBool(Keys.CodeMixEnabled);
        _selectedCodeMix = Settings.GetString(Keys.SelectedCodeMix) ?? "";
        _targetLanguageEnabled = Settings.GetBool(Keys.TargetLanguageEnabled);

        // Migration: code-mix styles used to live in the target-language picker.
        var storedTarget = Settings.GetString(Keys.SelectedTargetLanguage) ?? "English";
        var codeMixStyles = new HashSet<string>
        {
            "Hinglish", "Tanglish", "Benglish", "Kanglish", "Tenglish",
            "Minglish", "Punglish", "Spanglish", "Franglais", "Portuñol",
            "Chinglish", "Japlish", "Konglish", "Arabizi", "Sheng", "Camfranglais",
        };
        _selectedTargetLanguage = codeMixStyles.Contains(storedTarget) ? "English" : storedTarget;

        _feedbackSoundName = Settings.GetString(Keys.FeedbackSoundName) ?? "Asterisk";
        _customSystemPrompt = Settings.GetString(Keys.CustomSystemPrompt) ?? "";
        _selectedAudioDeviceUid = Settings.GetString(Keys.SelectedAudioDeviceUid) ?? "";

        DeepgramService.OnPartialTranscript = text => OnUi(() => LiveTranscript = text);
    }

    // MARK: - Volatile UI state

    private RecordingState _recordingState = RecordingState.Idle;
    public RecordingState RecordingState { get => _recordingState; set => SetField(ref _recordingState, value); }

    public string DeepgramApiKey { get; set; } = "";

    public string LastTranscript { get; set; } = "";

    private string _liveTranscript = "";
    public string LiveTranscript { get => _liveTranscript; set => SetField(ref _liveTranscript, value); }

    private IReadOnlyList<DeepgramModel> _availableModels = Array.Empty<DeepgramModel>();
    public IReadOnlyList<DeepgramModel> AvailableModels { get => _availableModels; set => SetField(ref _availableModels, value); }

    private List<TranscriptEntry> _transcriptHistory = new();
    public IReadOnlyList<TranscriptEntry> TranscriptHistory => _transcriptHistory;

    public void RecordTranscript(string raw, string? processed)
    {
        OnUi(() =>
        {
            _transcriptHistory.Insert(0, new TranscriptEntry(DateTime.Now, raw, processed));
            if (_transcriptHistory.Count > TranscriptHistoryLimit)
                _transcriptHistory.RemoveRange(TranscriptHistoryLimit, _transcriptHistory.Count - TranscriptHistoryLimit);
            OnPropertyChanged(nameof(TranscriptHistory));
        });
    }

    public void ClearTranscriptHistory()
    {
        OnUi(() =>
        {
            _transcriptHistory.Clear();
            OnPropertyChanged(nameof(TranscriptHistory));
        });
    }

    private string? _transientError;
    public string? TransientError { get => _transientError; private set => SetField(ref _transientError, value); }

    /// <summary>Surface a non-fatal error to the user; auto-clears after 4 seconds.</summary>
    public void ReportError(string message)
    {
        OnUi(() =>
        {
            TransientError = message;
            int gen = ++_errorGeneration;
            _ = Task.Delay(4000).ContinueWith(_ => OnUi(() =>
            {
                if (_errorGeneration == gen) TransientError = null;
            }), TaskScheduler.Default);
        });
    }

    // MARK: - Persisted preferences

    private string _selectedModel;
    public string SelectedModel
    {
        get => _selectedModel;
        set { if (SetField(ref _selectedModel, value)) Settings.SetString(Keys.SelectedModel, value); }
    }

    private string _selectedLanguage;
    public string SelectedLanguage
    {
        get => _selectedLanguage;
        set { if (SetField(ref _selectedLanguage, value)) Settings.SetString(Keys.SelectedLanguage, value); }
    }

    private HotkeyOption _selectedHotkey;
    public HotkeyOption SelectedHotkey
    {
        get => _selectedHotkey;
        set { if (SetField(ref _selectedHotkey, value)) Settings.SetString(Keys.SelectedHotkey, value.ToRawValue()); }
    }

    private LlmProvider _selectedLlmProvider;
    public LlmProvider SelectedLlmProvider
    {
        get => _selectedLlmProvider;
        set { if (SetField(ref _selectedLlmProvider, value)) Settings.SetString(Keys.SelectedLlmProvider, value.ToRawValue()); }
    }

    public string GroqApiKey { get; set; } = "";
    private IReadOnlyList<LlmModel> _availableGroqModels = Array.Empty<LlmModel>();
    public IReadOnlyList<LlmModel> AvailableGroqModels { get => _availableGroqModels; set => SetField(ref _availableGroqModels, value); }

    private string _selectedGroqModel;
    public string SelectedGroqModel
    {
        get => _selectedGroqModel;
        set { if (SetField(ref _selectedGroqModel, value)) Settings.SetString(Keys.SelectedGroqModel, value); }
    }

    public string OpenRouterApiKey { get; set; } = "";
    private IReadOnlyList<LlmModel> _availableOpenRouterModels = Array.Empty<LlmModel>();
    public IReadOnlyList<LlmModel> AvailableOpenRouterModels { get => _availableOpenRouterModels; set => SetField(ref _availableOpenRouterModels, value); }

    private string _selectedOpenRouterModel;
    public string SelectedOpenRouterModel
    {
        get => _selectedOpenRouterModel;
        set { if (SetField(ref _selectedOpenRouterModel, value)) Settings.SetString(Keys.SelectedOpenRouterModel, value); }
    }

    private bool _correctionModeEnabled;
    public bool CorrectionModeEnabled
    {
        get => _correctionModeEnabled;
        set { if (SetField(ref _correctionModeEnabled, value)) Settings.SetBool(Keys.CorrectionModeEnabled, value); }
    }

    private bool _grammarCorrectionEnabled;
    public bool GrammarCorrectionEnabled
    {
        get => _grammarCorrectionEnabled;
        set { if (SetField(ref _grammarCorrectionEnabled, value)) Settings.SetBool(Keys.GrammarCorrectionEnabled, value); }
    }

    private bool _codeMixEnabled;
    public bool CodeMixEnabled
    {
        get => _codeMixEnabled;
        set { if (SetField(ref _codeMixEnabled, value)) Settings.SetBool(Keys.CodeMixEnabled, value); }
    }

    private string _selectedCodeMix;
    public string SelectedCodeMix
    {
        get => _selectedCodeMix;
        set { if (SetField(ref _selectedCodeMix, value)) Settings.SetString(Keys.SelectedCodeMix, value); }
    }

    private bool _targetLanguageEnabled;
    public bool TargetLanguageEnabled
    {
        get => _targetLanguageEnabled;
        set { if (SetField(ref _targetLanguageEnabled, value)) Settings.SetBool(Keys.TargetLanguageEnabled, value); }
    }

    private string _selectedTargetLanguage;
    public string SelectedTargetLanguage
    {
        get => _selectedTargetLanguage;
        set { if (SetField(ref _selectedTargetLanguage, value)) Settings.SetString(Keys.SelectedTargetLanguage, value); }
    }

    private string _feedbackSoundName;
    public string FeedbackSoundName
    {
        get => _feedbackSoundName;
        set { if (SetField(ref _feedbackSoundName, value)) Settings.SetString(Keys.FeedbackSoundName, value); }
    }

    private string _customSystemPrompt;
    public string CustomSystemPrompt
    {
        get => _customSystemPrompt;
        set { if (SetField(ref _customSystemPrompt, value)) Settings.SetString(Keys.CustomSystemPrompt, value); }
    }

    private string _selectedAudioDeviceUid;
    public string SelectedAudioDeviceUid
    {
        get => _selectedAudioDeviceUid;
        set { if (SetField(ref _selectedAudioDeviceUid, value)) Settings.SetString(Keys.SelectedAudioDeviceUid, value); }
    }

    private IReadOnlyList<AudioInputDevice> _availableAudioDevices = Array.Empty<AudioInputDevice>();
    public IReadOnlyList<AudioInputDevice> AvailableAudioDevices { get => _availableAudioDevices; set => SetField(ref _availableAudioDevices, value); }

    public void RefreshAudioDevices()
    {
        var devices = AudioEngine.AvailableInputDevices();
        OnUi(() => AvailableAudioDevices = devices);
    }

    // MARK: - Helpers for the selected LLM provider

    public string CurrentLlmApiKey => SelectedLlmProvider switch
    {
        LlmProvider.Groq => GroqApiKey,
        LlmProvider.OpenRouter => OpenRouterApiKey,
        _ => GroqApiKey,
    };

    public string CurrentLlmModel => SelectedLlmProvider switch
    {
        LlmProvider.Groq => SelectedGroqModel,
        LlmProvider.OpenRouter => SelectedOpenRouterModel,
        _ => SelectedGroqModel,
    };

    // MARK: - INotifyPropertyChanged

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    /// <summary>Run on the WPF UI thread (or inline if already there / no app).</summary>
    internal static void OnUi(Action action)
    {
        var disp = Application.Current?.Dispatcher;
        if (disp == null || disp.CheckAccess()) action();
        else disp.BeginInvoke(action);
    }
}
