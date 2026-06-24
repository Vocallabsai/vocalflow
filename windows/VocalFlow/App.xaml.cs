using System.Threading;
using System.Windows;
using VocalFlow.Core;
using VocalFlow.Services;
using VocalFlow.UI;

namespace VocalFlow;

/// <summary>
/// Application entry point. Mirrors the macOS AppDelegate: a menu-bar (tray) accessory
/// app with no main window. Wires up AppState, the tray controller, the global hotkey
/// listener, and shows the welcome window on first run.
/// </summary>
public partial class App : Application
{
    private static Mutex? _singleInstanceMutex;

    private AppState? _appState;
    private TrayController? _tray;
    private HotkeyManager? _hotkeyManager;
    private UpdaterManager? _updater;
    private WelcomeWindow? _welcome;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Single-instance guard — a second launch just exits.
        _singleInstanceMutex = new Mutex(initiallyOwned: true, "VocalFlow.SingleInstance", out bool isNew);
        if (!isNew)
        {
            Shutdown();
            return;
        }

        // Finish any pending self-update from a previous run (remove the swapped-out exe + staging).
        UpdateService.CleanupAfterUpdate();

        var state = new AppState();
        _appState = state;

        _updater = new UpdaterManager(state);
        _tray = new TrayController(state, _updater);
        _hotkeyManager = new HotkeyManager(state);
        _hotkeyManager.StartListening();
        _updater.Start();

        if (WelcomeWindow.ShouldShow(state))
        {
            _welcome = new WelcomeWindow(state, onOpenSettings: () => _tray.ShowSettings());
            _welcome.Show();
        }
        else if (string.IsNullOrEmpty(state.DeepgramApiKey))
        {
            // Not first run but still unconfigured — make the tray presence discoverable.
            _tray.NotifyRunning();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkeyManager?.Dispose();
        _tray?.Dispose();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }
}
