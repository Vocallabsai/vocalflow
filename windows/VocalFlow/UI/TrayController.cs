using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using VocalFlow.Core;
using WinForms = System.Windows.Forms;

namespace VocalFlow.UI;

/// <summary>
/// The system-tray presence: icon that reflects recording state, context menu with recent
/// transcripts / settings / quit, and ownership of the recording overlay. Port of the macOS
/// MenuBarController (NSStatusItem -> WinForms NotifyIcon).
/// </summary>
public sealed class TrayController : IDisposable
{
    private const int HistoryPreviewLimit = 60;

    private readonly AppState _appState;
    private readonly UpdaterManager _updater;
    private readonly WinForms.NotifyIcon _notifyIcon;
    private readonly WinForms.ContextMenuStrip _menu;
    private readonly WinForms.ToolStripMenuItem _errorItem;
    private readonly WinForms.ToolStripSeparator _errorSeparator;
    private readonly WinForms.ToolStripMenuItem _historyItem;
    private readonly WinForms.ToolStripSeparator _historySeparator;

    private OverlayWindow? _overlay;
    private SettingsWindow? _settingsWindow;

    public TrayController(AppState appState, UpdaterManager updater)
    {
        _appState = appState;
        _updater = updater;

        _menu = new WinForms.ContextMenuStrip();

        _errorItem = new WinForms.ToolStripMenuItem { Visible = false, Enabled = false };
        _errorSeparator = new WinForms.ToolStripSeparator { Visible = false };
        _historyItem = new WinForms.ToolStripMenuItem("Recent Transcripts") { Visible = false };
        _historySeparator = new WinForms.ToolStripSeparator { Visible = false };

        var settingsItem = new WinForms.ToolStripMenuItem("Settings...", null, (_, _) => ShowSettings());
        var updateItem = new WinForms.ToolStripMenuItem("Check for Updates...", null,
            (_, _) => _ = _updater.CheckForUpdatesAsync(userInitiated: true));
        var micPrivacyItem = new WinForms.ToolStripMenuItem("Microphone Privacy...", null,
            (_, _) => OpenUrl("ms-settings:privacy-microphone"));
        var quitItem = new WinForms.ToolStripMenuItem("Quit VocalFlow", null, (_, _) => Application.Current.Shutdown());

        _menu.Items.Add(_errorItem);
        _menu.Items.Add(_errorSeparator);
        _menu.Items.Add(_historyItem);
        _menu.Items.Add(_historySeparator);
        _menu.Items.Add(settingsItem);
        _menu.Items.Add(updateItem);
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        _menu.Items.Add(micPrivacyItem);
        _menu.Items.Add(quitItem);

        _notifyIcon = new WinForms.NotifyIcon
        {
            Icon = IconFactory.ForState(RecordingStateKind.Idle, hasError: false),
            Text = "VocalFlow",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _notifyIcon.DoubleClick += (_, _) => ShowSettings();
        _notifyIcon.BalloonTipClicked += (_, _) => ShowSettings();

        _appState.PropertyChanged += OnAppStateChanged;
    }

    /// <summary>
    /// Show a one-off tray balloon so users can find the (otherwise invisible) app. The WPF tray
    /// has no window, so without this a fresh launch looks like nothing happened.
    /// </summary>
    public void NotifyRunning()
    {
        try
        {
            _notifyIcon.ShowBalloonTip(
                5000,
                "VocalFlow is running",
                "It lives in the system tray. Click here (or the mic icon) to open Settings and add your API keys.",
                WinForms.ToolTipIcon.Info);
        }
        catch { /* balloons can be suppressed by Focus Assist / policy */ }
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.RecordingState):
                UpdateIcon();
                if (_appState.RecordingState.Kind == RecordingStateKind.Recording) ShowOverlay();
                else HideOverlay();
                break;
            case nameof(AppState.TransientError):
                UpdateErrorIndicator(_appState.TransientError);
                UpdateIcon();
                break;
            case nameof(AppState.TranscriptHistory):
                RebuildHistory(_appState.TranscriptHistory);
                break;
        }
    }

    private void UpdateIcon()
    {
        bool hasError = _appState.TransientError != null;
        _notifyIcon.Icon = IconFactory.ForState(_appState.RecordingState.Kind, hasError);
        var tip = _appState.TransientError ?? "VocalFlow";
        _notifyIcon.Text = tip.Length > 60 ? tip[..60] : tip;
    }

    private void UpdateErrorIndicator(string? message)
    {
        if (!string.IsNullOrEmpty(message))
        {
            _errorItem.Text = $"⚠ {message}";
            _errorItem.Visible = true;
            _errorSeparator.Visible = true;
        }
        else
        {
            _errorItem.Text = "";
            _errorItem.Visible = false;
            _errorSeparator.Visible = false;
        }
    }

    private void RebuildHistory(IReadOnlyList<TranscriptEntry> history)
    {
        _historyItem.DropDownItems.Clear();

        if (history.Count == 0)
        {
            _historyItem.Visible = false;
            _historySeparator.Visible = false;
            return;
        }
        _historyItem.Visible = true;
        _historySeparator.Visible = true;

        foreach (var entry in history)
        {
            var time = RelativeTime(entry.Timestamp);
            var preview = PreviewLine(entry.Typed);
            var item = new WinForms.ToolStripMenuItem($"{preview}  ·  {time}") { ToolTipText = entry.Typed };
            var typed = entry.Typed;
            item.Click += (_, _) => CopyToClipboard(typed);
            _historyItem.DropDownItems.Add(item);

            if (entry.HasLlmProcessing)
            {
                var raw = entry.Raw;
                var rawItem = new WinForms.ToolStripMenuItem($"Raw: {PreviewLine(raw)}  ·  {time}") { ToolTipText = raw };
                rawItem.Click += (_, _) => CopyToClipboard(raw);
                _historyItem.DropDownItems.Add(rawItem);
            }
        }

        _historyItem.DropDownItems.Add(new WinForms.ToolStripSeparator());
        var clear = new WinForms.ToolStripMenuItem("Clear History", null, (_, _) => _appState.ClearTranscriptHistory());
        _historyItem.DropDownItems.Add(clear);
    }

    private static void CopyToClipboard(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        try { System.Windows.Clipboard.SetText(text); } catch { }
    }

    private static string PreviewLine(string text)
    {
        var single = text.Replace("\n", " ").Trim();
        return single.Length > HistoryPreviewLimit ? single[..HistoryPreviewLimit] + "…" : single;
    }

    private static string RelativeTime(DateTime when)
    {
        var span = DateTime.Now - when;
        if (span.TotalSeconds < 60) return "now";
        if (span.TotalMinutes < 60) return $"{(int)span.TotalMinutes}m ago";
        if (span.TotalHours < 24) return $"{(int)span.TotalHours}h ago";
        return $"{(int)span.TotalDays}d ago";
    }

    private OverlayWindow Overlay => _overlay ??= new OverlayWindow(_appState);

    private void ShowOverlay() => Overlay.ShowOverlay();
    private void HideOverlay() => _overlay?.HideOverlay();

    public void ShowSettings()
    {
        if (_settingsWindow == null)
        {
            _settingsWindow = new SettingsWindow(_appState, _updater);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
            _settingsWindow.Show();
        }
        else
        {
            _settingsWindow.Activate();
        }
        _settingsWindow.WindowState = WindowState.Normal;
        _settingsWindow.Activate();
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _menu.Dispose();
    }
}
