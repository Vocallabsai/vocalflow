using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Navigation;
using VocalFlow.Core;
using VocalFlow.Services;
using Brush = System.Windows.Media.Brush;

namespace VocalFlow.UI;

/// <summary>
/// The settings window: a sidebar of section pills on the left, one page of cards on the right.
/// Port of the macOS SettingsView (SwiftUI sidebar + paged sections -> WPF). Simple toggles and
/// the custom-prompt field are data-bound to AppState; combos, key fields, the async model
/// fetches, and the Dictionary entry list are driven imperatively from here.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly AppState _appState;
    private readonly UpdaterManager _updater;
    private bool _loading;
    private bool _deepgramKeyVisible;
    private bool _llmKeyVisible;

    // Sidebar navigation model: each section is one page. Mirrors the macOS SettingsSection.
    private enum Section { Dictation, Transcription, AiPolish, Corrections, Dictionary, Permissions, About }

    private sealed record SectionInfo(string Title, string Subtitle, string Glyph, string ChipBrushKey);

    private static readonly Dictionary<Section, SectionInfo> Sections = new()
    {
        [Section.Dictation] = new("Dictation", "Hotkey, feedback sound & microphone", "", "ChipVioletBrush"),
        [Section.Transcription] = new("Transcription", "Deepgram speech-to-text engine", "", "ChipBlueBrush"),
        [Section.AiPolish] = new("AI Polish", "LLM cleanup applied after transcription", "", "ChipMagentaBrush"),
        [Section.Corrections] = new("Corrections", "Spelling, grammar, code-mix & translation", "", "ChipEmeraldBrush"),
        [Section.Dictionary] = new("Dictionary", "Exact spellings & spoken text expansions", "", "ChipAmberBrush"),
        [Section.Permissions] = new("Permissions", "System access VocalFlow needs to work", "", "ChipRedBrush"),
        [Section.About] = new("About", "Version & software updates", "", "ChipSlateBrush"),
    };

    private Section _section = Section.Dictation;

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

    public SettingsWindow(AppState appState, UpdaterManager updater)
    {
        InitializeComponent();
        Icon = IconFactory.AppImage(); // match the tray / taskbar mic icon
        _appState = appState;
        _updater = updater;
        DataContext = appState;
        _appState.PropertyChanged += OnAppStateChanged;
        _updater.StatusChanged += OnUpdaterStatus;
        _updater.BusyChanged += OnUpdaterBusy;
        Loaded += OnLoaded;
        Closed += OnSettingsClosed;
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

        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "?";
        VersionText.Text = version;
        SidebarVersion.Text = $"Version {version}";

        RebuildDictList();

        _loading = false;

        ApplySection(animated: false);
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
        else if (e.PropertyName == nameof(AppState.FocusWords))
            RebuildDictList(); // e.g. type-over auto-learn appended a word while the window is open
    }

    // MARK: - Sidebar navigation / paging

    private void OnNavChecked(object sender, RoutedEventArgs e)
    {
        if (!IsInitialized || _loading) return;
        var section = sender switch
        {
            _ when ReferenceEquals(sender, NavDictation) => Section.Dictation,
            _ when ReferenceEquals(sender, NavTranscription) => Section.Transcription,
            _ when ReferenceEquals(sender, NavAiPolish) => Section.AiPolish,
            _ when ReferenceEquals(sender, NavCorrections) => Section.Corrections,
            _ when ReferenceEquals(sender, NavDictionary) => Section.Dictionary,
            _ when ReferenceEquals(sender, NavPermissions) => Section.Permissions,
            _ => Section.About,
        };
        if (section == _section) return;
        _section = section;
        ApplySection(animated: true);
    }

    private FrameworkElement PageFor(Section s) => s switch
    {
        Section.Dictation => PageDictation,
        Section.Transcription => PageTranscription,
        Section.AiPolish => PageAiPolish,
        Section.Corrections => PageCorrections,
        Section.Dictionary => PageDictionary,
        Section.Permissions => PagePermissions,
        _ => PageAbout,
    };

    /// <summary>Retarget the page header, show only the active page, and crossfade it in.</summary>
    private void ApplySection(bool animated)
    {
        var info = Sections[_section];
        HeaderTitle.Text = info.Title;
        HeaderSubtitle.Text = info.Subtitle;
        HeaderGlyph.Text = info.Glyph;
        var chip = (Brush)FindResource(info.ChipBrushKey);
        HeaderChip.Background = chip;
        if (chip is System.Windows.Media.SolidColorBrush solid)
            HeaderChipGlow.Color = solid.Color;

        foreach (Section s in Enum.GetValues<Section>())
            PageFor(s).Visibility = s == _section ? Visibility.Visible : Visibility.Collapsed;

        PageScroll.ScrollToTop();
        if (animated)
            PageHost.BeginAnimation(OpacityProperty,
                new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(150)));
    }

    // MARK: - Deepgram

    private void OnToggleDeepgramShow(object sender, RoutedEventArgs e)
    {
        _deepgramKeyVisible = !_deepgramKeyVisible;
        DeepgramShowBtn.Content = _deepgramKeyVisible ? "Hide" : "Show";
        if (_deepgramKeyVisible)
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

    private string ReadDeepgramKey() => _deepgramKeyVisible ? DeepgramKeyText.Text : DeepgramKeyBox.Password;

    private void SetDeepgramKey(string value)
    {
        DeepgramKeyBox.Password = value;
        DeepgramKeyText.Text = value;
        DeepgramSaveBtn.IsEnabled = value.Length > 0;
    }

    private void OnDeepgramKeyEdited(object sender, RoutedEventArgs e)
        => DeepgramSaveBtn.IsEnabled = ReadDeepgramKey().Length > 0;

    private async void OnSaveDeepgram(object sender, RoutedEventArgs e)
    {
        var key = ReadDeepgramKey();
        _appState.Credentials.Store("deepgram_api_key", key);
        _appState.DeepgramApiKey = key;
        RebuildModelCombo(); // key presence toggles the model rows
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

        // Hide the model/language rows until there's a key (or fetched models) to pick from.
        bool showModelArea = _appState.AvailableModels.Count > 0 || !string.IsNullOrEmpty(_appState.DeepgramApiKey);
        DeepgramModelDivider.Visibility = showModelArea ? Visibility.Visible : Visibility.Collapsed;
        ModelPanel.Visibility = showModelArea ? Visibility.Visible : Visibility.Collapsed;

        RebuildLanguageCombo();
        _loading = false;
    }

    private void RebuildLanguageCombo()
    {
        var langs = _appState.AvailableModels.FirstOrDefault(m => m.CanonicalName == _appState.SelectedModel)?.Languages
                    ?? Array.Empty<string>();
        if (langs.Count > 0 && ModelPanel.Visibility == Visibility.Visible)
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
        LlmSaveBtn.IsEnabled = key.Length > 0;
        LlmKeyHyperlink.NavigateUri = new Uri(_appState.SelectedLlmProvider.SignupUrl());
        LlmKeyHyperlink.Inlines.Clear();
        LlmKeyHyperlink.Inlines.Add($"Get a {_appState.SelectedLlmProvider.DisplayName()} key →");
    }

    private void OnToggleLlmShow(object sender, RoutedEventArgs e)
    {
        _llmKeyVisible = !_llmKeyVisible;
        LlmShowBtn.Content = _llmKeyVisible ? "Hide" : "Show";
        if (_llmKeyVisible)
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

    private string ReadLlmKey() => _llmKeyVisible ? LlmKeyText.Text : LlmKeyBox.Password;

    private void OnLlmKeyEdited(object sender, RoutedEventArgs e)
        => LlmSaveBtn.IsEnabled = ReadLlmKey().Length > 0;

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
            LlmModelDivider.Visibility = Visibility.Visible;
            LlmModelPanel.Visibility = Visibility.Visible;
            LlmModelCombo.ItemsSource = models.Select(m => m.DisplayName).ToList();
            var selectedId = _appState.CurrentLlmModel;
            var idx = models.ToList().FindIndex(m => m.Id == selectedId);
            LlmModelCombo.SelectedIndex = idx >= 0 ? idx : 0;
            LlmFetchBtn.Content = "Refresh";
        }
        else
        {
            LlmModelDivider.Visibility = Visibility.Collapsed;
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

    // MARK: - Dictionary (a managed view over the focus-words string)

    /// <summary>One row of the Dictionary entry list. Rebuilt wholesale on every change.</summary>
    public sealed class DictRow
    {
        public required DictionaryEntry Entry { get; init; }
        public required bool IsFavorite { get; init; }
        public required bool IsEditing { get; init; }
        public required bool ShowDivider { get; init; }
        public string Key => Entry.Key;
        /// <summary>Second line for expansions; empty (hidden) for plain spelling entries.</summary>
        public string Expansion => Entry.Value == Entry.Key ? "" : $"→ {Entry.Value}";
    }

    /// <summary>Original key of the entry being edited; null = the form adds a new entry.</summary>
    private string? _editingKey;

    private IReadOnlyList<DictionaryEntry> DictionaryEntries => FocusWordsDictionary.ParseEntries(_appState.FocusWords);

    /// <summary>
    /// Serialize back to the newline "key : value" format FocusWordsDictionary parses (and the
    /// type-over auto-learn appends to). Plain entries (value == key) serialize as just the key.
    /// </summary>
    private void SaveDictEntries(IEnumerable<DictionaryEntry> entries)
    {
        _appState.FocusWords = string.Join("\n",
            entries.Select(en => en.Key == en.Value ? en.Key : $"{en.Key} : {en.Value}"));
    }

    private void RebuildDictList()
    {
        var all = DictionaryEntries;
        // Favorites pinned first; original order preserved within each group.
        var displayed = all.Where(en => _appState.IsFavoriteFocusWord(en.Key))
            .Concat(all.Where(en => !_appState.IsFavoriteFocusWord(en.Key)))
            .ToList();

        DictListTitle.Text = $"Entries ({all.Count})";
        DictEmptyText.Visibility = all.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        DictList.ItemsSource = displayed.Select((en, i) => new DictRow
        {
            Entry = en,
            IsFavorite = _appState.IsFavoriteFocusWord(en.Key),
            IsEditing = _editingKey == en.Key,
            ShowDivider = i > 0,
        }).ToList();
    }

    private void OnDictFormChanged(object sender, TextChangedEventArgs e)
        => DictCommitBtn.IsEnabled = DictWordBox.Text.Trim().Length > 0;

    private void OnDictFormKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        CommitDictEntry();
        e.Handled = true;
    }

    private void OnDictCommit(object sender, RoutedEventArgs e) => CommitDictEntry();

    private void CommitDictEntry()
    {
        var trigger = DictWordBox.Text.Trim();
        var repl = DictReplacementBox.Text.Trim();
        if (trigger.Length == 0) return;
        var entry = new DictionaryEntry(trigger, repl.Length == 0 ? trigger : repl);

        var entries = DictionaryEntries.ToList();
        int editIdx = _editingKey == null ? -1 : entries.FindIndex(en => en.Key == _editingKey);
        if (editIdx >= 0)
        {
            // Carry a favorite across a rename.
            if (_editingKey != null && _appState.IsFavoriteFocusWord(_editingKey) &&
                !string.Equals(_editingKey, trigger, StringComparison.OrdinalIgnoreCase))
            {
                _appState.SetFavoriteFocusWord(_editingKey, false);
                _appState.SetFavoriteFocusWord(trigger, true);
            }
            entries[editIdx] = entry;
        }
        else
        {
            int existing = entries.FindIndex(en => string.Equals(en.Key, trigger, StringComparison.OrdinalIgnoreCase));
            if (existing >= 0) entries[existing] = entry; // re-adding an existing trigger updates it
            else entries.Add(entry);
        }
        ResetDictForm();
        SaveDictEntries(entries); // triggers RebuildDictList via the FocusWords property change
        DictWordBox.Focus();
    }

    private void OnDictCancelEdit(object sender, RoutedEventArgs e)
    {
        ResetDictForm();
        RebuildDictList(); // drop the row's editing highlight
    }

    private void ResetDictForm()
    {
        _editingKey = null;
        DictWordBox.Text = "";
        DictReplacementBox.Text = "";
        DictFormTitle.Text = "Add Entry";
        DictCommitBtn.Content = "Add to Dictionary";
        DictCancelBtn.Visibility = Visibility.Collapsed;
    }

    private static DictRow? RowOf(object sender) => (sender as FrameworkElement)?.DataContext as DictRow;

    private void OnDictFavorite(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        _appState.SetFavoriteFocusWord(row.Key, !row.IsFavorite);
        RebuildDictList();
    }

    private void OnDictEdit(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        _editingKey = row.Key;
        DictWordBox.Text = row.Entry.Key;
        DictReplacementBox.Text = row.Entry.Value == row.Entry.Key ? "" : row.Entry.Value;
        DictFormTitle.Text = $"Edit “{row.Key}”";
        DictCommitBtn.Content = "Save Changes";
        DictCancelBtn.Visibility = Visibility.Visible;
        RebuildDictList(); // highlight the row being edited
        DictWordBox.Focus();
    }

    private void OnDictDelete(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        if (_editingKey == row.Key) ResetDictForm();
        _appState.SetFavoriteFocusWord(row.Key, false);
        SaveDictEntries(DictionaryEntries.Where(en => en.Key != row.Key));
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

    // MARK: - Permissions

    private void OnOpenMicPrivacy(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch { }
    }

    // MARK: - Updates

    private async void OnCheckForUpdates(object sender, RoutedEventArgs e)
        => await _updater.CheckForUpdatesAsync(userInitiated: true);

    private void OnUpdaterStatus(string status) => UpdateStatus.Text = status;

    private void OnUpdaterBusy(bool busy) => CheckUpdateBtn.IsEnabled = !busy;

    private void OnSettingsClosed(object? sender, EventArgs e)
    {
        _updater.StatusChanged -= OnUpdaterStatus;
        _updater.BusyChanged -= OnUpdaterBusy;
        _appState.PropertyChanged -= OnAppStateChanged;
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
