using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using VocalFlow.Core;

namespace VocalFlow.UI;

/// <summary>
/// Drives the Windows auto-update flow. Port of the macOS UpdaterManager (which wraps Sparkle):
/// runs a check shortly after launch and then every 24 hours when enabled, exposes a manual
/// "Check for Updates" trigger, and on finding an update downloads it and prompts the user to
/// restart. Owns no UI of its own beyond the prompt; status is surfaced via <see cref="StatusChanged"/>.
/// </summary>
public sealed class UpdaterManager
{
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);
    private static readonly TimeSpan InitialDelay = TimeSpan.FromSeconds(8);

    private readonly AppState _appState;
    private readonly UpdateService _service = new();
    private DispatcherTimer? _timer;
    private bool _busy;

    /// <summary>Human-readable status for the Settings UI ("Checking…", "You're up to date", …).</summary>
    public event Action<string>? StatusChanged;

    /// <summary>True while a check/download is in flight, so the button can disable itself.</summary>
    public event Action<bool>? BusyChanged;

    public string CurrentVersionString => UpdateService.CurrentVersion.ToString(3);

    public UpdaterManager(AppState appState) => _appState = appState;

    /// <summary>Schedule the initial check (soon after launch) and the recurring 24h check.</summary>
    public void Start()
    {
        var startup = new DispatcherTimer { Interval = InitialDelay };
        startup.Tick += (_, _) =>
        {
            startup.Stop();
            if (_appState.AutoUpdateEnabled) _ = CheckForUpdatesAsync(userInitiated: false);
        };
        startup.Start();

        _timer = new DispatcherTimer { Interval = CheckInterval };
        _timer.Tick += (_, _) => { if (_appState.AutoUpdateEnabled) _ = CheckForUpdatesAsync(userInitiated: false); };
        _timer.Start();
    }

    /// <summary>
    /// Check for an update. When <paramref name="userInitiated"/> is true, also report the
    /// "you're up to date" / failure outcomes via a dialog; background checks stay silent unless
    /// there's actually an update to offer.
    /// </summary>
    public async Task CheckForUpdatesAsync(bool userInitiated)
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            StatusChanged?.Invoke("Checking for updates…");

            UpdateInfo? info;
            try { info = await _service.CheckForUpdateAsync(); }
            catch { info = null; }

            if (info == null)
            {
                StatusChanged?.Invoke($"You're up to date (v{CurrentVersionString}).");
                if (userInitiated)
                    MessageBox.Show($"VocalFlow {CurrentVersionString} is the latest version.",
                        "No updates available", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            StatusChanged?.Invoke($"Downloading v{info.Version}…");
            var progress = new Progress<double>(p => StatusChanged?.Invoke($"Downloading v{info.Version}… {(int)(p * 100)}%"));

            string path;
            try { path = await _service.DownloadAsync(info, progress); }
            catch
            {
                StatusChanged?.Invoke("Download failed.");
                if (userInitiated)
                    MessageBox.Show("The update could not be downloaded. Please try again later.",
                        "Update failed", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            PromptAndApply(info, path);
        }
        finally { SetBusy(false); }
    }

    private void PromptAndApply(UpdateInfo info, string downloadedPath)
    {
        var choice = MessageBox.Show(
            $"VocalFlow {info.Version} is ready to install (you have {CurrentVersionString}).\n\nRestart now to update?",
            "Update available", MessageBoxButton.YesNo, MessageBoxImage.Question);

        if (choice != MessageBoxResult.Yes)
        {
            StatusChanged?.Invoke($"Update v{info.Version} downloaded — restart to finish.");
            return;
        }

        if (UpdateService.ApplyAndRestart(downloadedPath))
        {
            Application.Current.Shutdown();
            return;
        }

        // Couldn't self-replace (typically a read-only install folder) — offer the manual route.
        StatusChanged?.Invoke("Couldn't update automatically.");
        var open = MessageBox.Show(
            "VocalFlow couldn't replace itself automatically — this usually means it's running from a read-only folder.\n\nOpen the download page to update manually?",
            "Update", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (open == MessageBoxResult.Yes && !string.IsNullOrEmpty(info.HtmlUrl))
        {
            try { Process.Start(new ProcessStartInfo(info.HtmlUrl) { UseShellExecute = true }); } catch { /* ignore */ }
        }
    }

    private void SetBusy(bool value)
    {
        _busy = value;
        BusyChanged?.Invoke(value);
    }
}
