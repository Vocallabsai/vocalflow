using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Navigation;
using VocalFlow.Core;
using VocalFlow.Services;
using Brush = System.Windows.Media.Brush;

namespace VocalFlow.UI;

/// <summary>
/// The settings window. Port of the macOS SettingsView (SwiftUI Form -> WPF). Simple toggles and
/// the custom-prompt field are data-bound to AppState; combos, key fields, and the async model
/// fetches are driven imperatively from here.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly AppState _appState;
    private bool _loading;

    private static readonly (string Name, string Description)[] CodeMixOptions =
    {
        ("Hinglish", "Hindi + English"), ("Tanglish", "Tamil + English"), ("Benglish", "Bengali + English"),
        ("Kanglish", "Kannada + English"), ("Tenglish", "Telugu + English"), ("Minglish", "Marathi + English"),
        ("Punglish", "Punjabi + English"), ("Spanglish", "Spanish + English"), ("Franglais", "French + English"),
        ("Portuñol", "Portuguese + Spanish"), ("Chinglish", "Chinese + English"), ("Japlish", "Japanese + English"),
        ("Konglish", "Korean + English"), ("Arabizi", "Arabic + English"), ("Sheng", "Swahili + English"),
        ("Camfranglais", "French + English + local languages"),
    };

    private static readonly string[] TargetLanguages =
    {
        "English", "Hindi", "Spanish", "French", "German", "Portuguese", "Japanese", "Korean", "Arabic", "Bengali",
        "Tamil", "Telugu", "Kannada", "Marathi", "Punjabi", "Russian", "Chinese (Simplified)", "Italian", "Dutch", "Swahili",
    };

    public SettingsWindow(AppState appState)
    {
        InitializeComponent();
        _appState = appState;
        DataContext = appState;
        _appState.PropertyChanged += OnAppStateChanged;
        Loaded += OnLoaded;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ThemeHelper.UseDarkTitleBar(this);
    }

    private void SetStatus(System.Windows.Controls.TextBlock target, string text, bool? ok)
    {
        target.Text = text;
        target.Foreground = ok switch
        {
            true => (Brush)FindResource("SuccessBrush"),
            false => (Brush)FindResource("ErrorBrush"),
            null => (Brush)FindResource("TextSecondaryBrush"),
        };
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _loading = true;

        // Static combos
        ProviderCombo.ItemsSource = LlmProviderExtensions.All.Select(p => p.DisplayName()).ToList();
        ProviderCombo.SelectedIndex = LlmProviderExtensions.All.ToList().IndexOf(_appState.SelectedLlmProvider);

        HotkeyCombo.ItemsSource = HotkeyOptionExtensions.All.Select(h => h.DisplayName()).ToList();
        HotkeyCombo.SelectedIndex = HotkeyOptionExtensions.All.ToList().IndexOf(_appState.SelectedHotkey);

        var feedback = new List<string> { "None (muted)" };
        feedback.AddRange(FeedbackSound.Options);
        FeedbackCombo.ItemsSource = feedback;
        FeedbackCombo.SelectedItem = string.IsNullOrEmpty(_appState.FeedbackSoundName) ? "None (muted)" : _appState.FeedbackSoundName;

        var codeMix = new List<string> { "Select…" };
        codeMix.AddRange(CodeMixOptions.Select(o => $"{o.Name} ({o.Description})"));
        CodeMixStyleCombo.ItemsSource = codeMix;
        SelectCodeMixStyle(_appState.SelectedCodeMix);

        TargetCombo.ItemsSource = TargetLanguages;
        TargetCombo.SelectedItem = TargetLanguages.Contains(_appState.SelectedTargetLanguage)
            ? _appState.SelectedTargetLanguage : "English";

        // Key fields
        SetDeepgramKey(_appState.DeepgramApiKey);
        SyncLlmKeyField();

        // Models
        RebuildModelCombo();
        RebuildLlmModelCombo();

        VersionText.Text = $"Version {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "?"}";

        _loading = false;

        RebuildMicCombo();
        _appState.RefreshAudioDevices();
        UpdateLlmDependentState();

        // Kick off model fetches if keys are present but lists empty.
        if (_appState.AvailableModels.Count == 0 && !string.IsNullOrEmpty(_appState.DeepgramApiKey))
            _ = FetchDeepgramModelsAsync();
        if (CurrentProviderModels().Count == 0 && !string.IsNullOrEmpty(_appState.CurrentLlmApiKey))
            _ = FetchLlmModelsAsync();
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppState.AvailableAudioDevices))
            RebuildMicCombo();
    }

    // MARK: - Deepgram

    private void OnToggleDeepgramShow(object sender, RoutedEventArgs e)
    {
        if (DeepgramShow.IsChecked == true)
        {
            DeepgramKeyText.Text = DeepgramKeyBox.Password;
            DeepgramKeyText.Visibility = Visibility.Visible;
            DeepgramKeyBox.Visibility = Visibility.Collapsed;
        }
        else
        {
            DeepgramKeyBox.Password = DeepgramKeyText.Text;
            DeepgramKeyBox.Visibility = Visibility.Visible;
            DeepgramKeyText.Visibility = Visibility.Collapsed;
        }
    }

    private string ReadDeepgramKey() =>
        DeepgramShow.IsChecked == true ? DeepgramKeyText.Text : DeepgramKeyBox.Password;

    private void SetDeepgramKey(string value)
    {
        DeepgramKeyBox.Password = value;
        DeepgramKeyText.Text = value;
    }

    private async void OnSaveDeepgram(object sender, RoutedEventArgs e)
    {
        var key = ReadDeepgramKey();
        _appState.Credentials.Store("deepgram_api_key", key);
        _appState.DeepgramApiKey = key;
        SetStatus(DeepgramStatus, "Verifying…", null);
        bool ok = await FetchDeepgramModelsAsync();
        SetStatus(DeepgramStatus, ok ? "Saved & verified ✓" : "Saved (verification failed)", ok);
        UpdateLlmDependentState();
        await Task.Delay(3000);
        DeepgramStatus.Text = "";
    }

    private async void OnFetchDeepgramModels(object sender, RoutedEventArgs e) => await FetchDeepgramModelsAsync();

    private async Task<bool> FetchDeepgramModelsAsync()
    {
        DeepgramFetchBtn.IsEnabled = false;
        DeepgramError.Visibility = Visibility.Collapsed;
        try
        {
            var models = await _appState.DeepgramService.FetchModelsAsync(_appState.DeepgramApiKey);
            if (models.Count == 0)
            {
                ShowError(DeepgramError, "Deepgram returned no streaming models.");
                return false;
            }
            _appState.AvailableModels = models;
            if (!models.Any(m => m.CanonicalName == _appState.SelectedModel))
                _appState.SelectedModel = models[0].CanonicalName;
            RebuildModelCombo();
            ResetLanguageForCurrentModel();
            return true;
        }
        catch (ApiException ex)
        {
            ShowError(DeepgramError, ex.UserMessage);
            return false;
        }
        catch (Exception ex)
        {
            ShowError(DeepgramError, ex.Message);
            return false;
        }
        finally { DeepgramFetchBtn.IsEnabled = true; }
    }

    private void RebuildModelCombo()
    {
        _loading = true;
        if (_appState.AvailableModels.Count > 0)
        {
            ModelCombo.ItemsSource = _appState.AvailableModels.Select(m => m.CanonicalName).ToList();
            DeepgramFetchBtn.Content = "Refresh";
        }
        ModelCombo.Text = _appState.SelectedModel;
        RebuildLanguageCombo();
        _loading = false;
    }

    private void RebuildLanguageCombo()
    {
        var langs = _appState.AvailableModels.FirstOrDefault(m => m.CanonicalName == _appState.SelectedModel)?.Languages
                    ?? Array.Empty<string>();
        if (langs.Count > 0)
        {
            LanguagePanel.Visibility = Visibility.Visible;
            LanguageCombo.ItemsSource = langs.Select(l => l == "multi" ? "multi (Code-switching)" : l).ToList();
            var idx = langs.ToList().IndexOf(_appState.SelectedLanguage);
            LanguageCombo.SelectedIndex = idx >= 0 ? idx : 0;
        }
        else
        {
            LanguagePanel.Visibility = Visibility.Collapsed;
        }
    }

    private void OnModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ModelCombo.SelectedItem is not string model) return;
        _appState.SelectedModel = model;
        ResetLanguageForCurrentModel();
        RebuildLanguageCombo();
    }

    private void OnModelTextCommitted(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var text = ModelCombo.Text?.Trim() ?? "";
        if (!string.IsNullOrEmpty(text) && text != _appState.SelectedModel)
        {
            _appState.SelectedModel = text;
            RebuildLanguageCombo();
        }
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        var langs = _appState.AvailableModels.FirstOrDefault(m => m.CanonicalName == _appState.SelectedModel)?.Languages
                    ?? Array.Empty<string>();
        int idx = LanguageCombo.SelectedIndex;
        if (idx >= 0 && idx < langs.Count) _appState.SelectedLanguage = langs[idx];
    }

    private void ResetLanguageForCurrentModel()
    {
        var langs = _appState.AvailableModels.FirstOrDefault(m => m.CanonicalName == _appState.SelectedModel)?.Languages
                    ?? Array.Empty<string>();
        if (langs.Count > 0 && !langs.Contains(_appState.SelectedLanguage))
            _appState.SelectedLanguage = langs[0];
    }

    // MARK: - LLM

    private IReadOnlyList<LlmModel> CurrentProviderModels() => _appState.SelectedLlmProvider switch
    {
        LlmProvider.Groq => _appState.AvailableGroqModels,
        LlmProvider.OpenRouter => _appState.AvailableOpenRouterModels,
        _ => Array.Empty<LlmModel>(),
    };

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        int idx = ProviderCombo.SelectedIndex;
        if (idx < 0) return;
        _appState.SelectedLlmProvider = LlmProviderExtensions.All[idx];
        SyncLlmKeyField();
        LlmError.Visibility = Visibility.Collapsed;
        LlmStatus.Text = "";
        RebuildLlmModelCombo();
        UpdateLlmDependentState();
    }

    private void SyncLlmKeyField()
    {
        var key = _appState.SelectedLlmProvider switch
        {
            LlmProvider.Groq => _appState.GroqApiKey,
            LlmProvider.OpenRouter => _appState.OpenRouterApiKey,
            _ => "",
        };
        LlmKeyBox.Password = key;
        LlmKeyText.Text = key;
        LlmKeyHyperlink.NavigateUri = new Uri(_appState.SelectedLlmProvider.SignupUrl());
        LlmKeyHyperlink.Inlines.Clear();
        LlmKeyHyperlink.Inlines.Add($"Get a {_appState.SelectedLlmProvider.DisplayName()} key →");
    }

    private void OnToggleLlmShow(object sender, RoutedEventArgs e)
    {
        if (LlmShow.IsChecked == true)
        {
            LlmKeyText.Text = LlmKeyBox.Password;
            LlmKeyText.Visibility = Visibility.Visible;
            LlmKeyBox.Visibility = Visibility.Collapsed;
        }
        else
        {
            LlmKeyBox.Password = LlmKeyText.Text;
            LlmKeyBox.Visibility = Visibility.Visible;
            LlmKeyText.Visibility = Visibility.Collapsed;
        }
    }

    private string ReadLlmKey() => LlmShow.IsChecked == true ? LlmKeyText.Text : LlmKeyBox.Password;

    private async void OnSaveLlm(object sender, RoutedEventArgs e)
    {
        var provider = _appState.SelectedLlmProvider;
        var key = ReadLlmKey();
        _appState.Credentials.Store(provider.CredentialKey(), key);
        if (provider == LlmProvider.Groq) _appState.GroqApiKey = key;
        else _appState.OpenRouterApiKey = key;

        SetStatus(LlmStatus, "Verifying…", null);
        bool ok = await FetchLlmModelsAsync();
        SetStatus(LlmStatus, ok ? "Saved & verified ✓" : "Saved (verification failed)", ok);
        UpdateLlmDependentState();
        await Task.Delay(3000);
        LlmStatus.Text = "";
    }

    private async void OnFetchLlmModels(object sender, RoutedEventArgs e) => await FetchLlmModelsAsync();

    private async Task<bool> FetchLlmModelsAsync()
    {
        var provider = _appState.SelectedLlmProvider;
        var apiKey = _appState.CurrentLlmApiKey;
        LlmFetchBtn.IsEnabled = false;
        LlmError.Visibility = Visibility.Collapsed;
        try
        {
            var models = await _appState.LlmService.FetchModelsAsync(provider, apiKey);
            if (provider != _appState.SelectedLlmProvider) return false; // provider changed mid-await
            if (models.Count == 0)
            {
                ShowError(LlmError, $"{provider.DisplayName()} returned no models.");
                return false;
            }
            if (provider == LlmProvider.Groq)
            {
                _appState.AvailableGroqModels = models;
                if (!models.Any(m => m.Id == _appState.SelectedGroqModel)) _appState.SelectedGroqModel = models[0].Id;
            }
            else
            {
                _appState.AvailableOpenRouterModels = models;
                if (!models.Any(m => m.Id == _appState.SelectedOpenRouterModel)) _appState.SelectedOpenRouterModel = models[0].Id;
            }
            RebuildLlmModelCombo();
            return true;
        }
        catch (ApiException ex)
        {
            if (provider == _appState.SelectedLlmProvider) ShowError(LlmError, ex.UserMessage);
            return false;
        }
        catch (Exception ex)
        {
            if (provider == _appState.SelectedLlmProvider) ShowError(LlmError, ex.Message);
            return false;
        }
        finally { LlmFetchBtn.IsEnabled = true; }
    }

    private void RebuildLlmModelCombo()
    {
        _loading = true;
        var models = CurrentProviderModels();
        if (models.Count > 0)
        {
            LlmModelPanel.Visibility = Visibility.Visible;
            LlmModelCombo.ItemsSource = models.Select(m => m.DisplayName).ToList();
            var selectedId = _appState.CurrentLlmModel;
            var idx = models.ToList().FindIndex(m => m.Id == selectedId);
            LlmModelCombo.SelectedIndex = idx >= 0 ? idx : 0;
            LlmFetchBtn.Content = "Refresh";
        }
        else
        {
            LlmModelPanel.Visibility = Visibility.Collapsed;
            LlmFetchBtn.Content = "Fetch Models";
        }
        _loading = false;
    }

    private void OnLlmModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        var models = CurrentProviderModels();
        int idx = LlmModelCombo.SelectedIndex;
        if (idx < 0 || idx >= models.Count) return;
        if (_appState.SelectedLlmProvider == LlmProvider.Groq) _appState.SelectedGroqModel = models[idx].Id;
        else _appState.SelectedOpenRouterModel = models[idx].Id;
        UpdateLlmDependentState();
    }

    // MARK: - Corrections / custom prompt gating

    private void UpdateLlmDependentState()
    {
        bool configured = !string.IsNullOrEmpty(_appState.CurrentLlmApiKey) && !string.IsNullOrEmpty(_appState.CurrentLlmModel);
        SpellingToggle.IsEnabled = configured;
        GrammarToggle.IsEnabled = configured;
        CodeMixToggle.IsEnabled = configured;
        TargetToggle.IsEnabled = configured;
        CodeMixStyleCombo.IsEnabled = configured;
        TargetCombo.IsEnabled = configured;
        CustomPromptBox.IsEnabled = configured;
        CorrectionsHint.Visibility = configured ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SelectCodeMixStyle(string name)
    {
        var idx = Array.FindIndex(CodeMixOptions, o => o.Name == name);
        CodeMixStyleCombo.SelectedIndex = idx >= 0 ? idx + 1 : 0; // +1 for the "Select…" entry
    }

    private void OnCodeMixStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        int idx = CodeMixStyleCombo.SelectedIndex;
        _appState.SelectedCodeMix = idx <= 0 ? "" : CodeMixOptions[idx - 1].Name;
    }

    private void OnTargetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || TargetCombo.SelectedItem is not string lang) return;
        _appState.SelectedTargetLanguage = lang;
    }

    // MARK: - Microphone

    private void RebuildMicCombo()
    {
        _loading = true;
        var items = new List<string> { "System default" };
        items.AddRange(_appState.AvailableAudioDevices.Select(d => d.Name));

        bool stale = !string.IsNullOrEmpty(_appState.SelectedAudioDeviceUid) &&
                     !_appState.AvailableAudioDevices.Any(d => d.Id == _appState.SelectedAudioDeviceUid);
        if (stale) items.Add($"Unavailable ({_appState.SelectedAudioDeviceUid})");

        MicCombo.ItemsSource = items;

        if (string.IsNullOrEmpty(_appState.SelectedAudioDeviceUid))
            MicCombo.SelectedIndex = 0;
        else
        {
            var devIdx = _appState.AvailableAudioDevices.ToList().FindIndex(d => d.Id == _appState.SelectedAudioDeviceUid);
            MicCombo.SelectedIndex = devIdx >= 0 ? devIdx + 1 : items.Count - 1;
        }
        _loading = false;
    }

    private void OnMicChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        int idx = MicCombo.SelectedIndex;
        if (idx <= 0) { _appState.SelectedAudioDeviceUid = ""; return; }
        var devices = _appState.AvailableAudioDevices;
        if (idx - 1 < devices.Count) _appState.SelectedAudioDeviceUid = devices[idx - 1].Id;
        // else: the stale "Unavailable" entry — leave the persisted uid untouched.
    }

    private void OnRefreshMics(object sender, RoutedEventArgs e) => _appState.RefreshAudioDevices();

    // MARK: - Hotkey / feedback

    private void OnHotkeyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        int idx = HotkeyCombo.SelectedIndex;
        if (idx >= 0) _appState.SelectedHotkey = HotkeyOptionExtensions.All[idx];
    }

    private void OnFeedbackChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (FeedbackCombo.SelectedItem is not string name) return;
        var value = name == "None (muted)" ? "" : name;
        _appState.FeedbackSoundName = value;
        if (!string.IsNullOrEmpty(value)) FeedbackSound.Play(value);
    }

    // MARK: - Misc

    private static void ShowError(System.Windows.Controls.TextBlock target, string message)
    {
        target.Text = message;
        target.Visibility = Visibility.Visible;
    }

    private void OnNavigate(object sender, RequestNavigateEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); } catch { }
        e.Handled = true;
    }
}
