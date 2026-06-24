using System.Diagnostics;
using System.Windows;
using System.Windows.Navigation;
using VocalFlow.Core;

namespace VocalFlow.UI;

/// <summary>First-run onboarding. Port of the macOS WelcomeWindowController.</summary>
public partial class WelcomeWindow : Window
{
    private const string WelcomeShownKey = "welcome_shown_v1";

    private readonly AppState _appState;
    private readonly Action _onOpenSettings;

    public WelcomeWindow(AppState appState, Action onOpenSettings)
    {
        InitializeComponent();
        _appState = appState;
        _onOpenSettings = onOpenSettings;
        Loaded += (_, _) => _appState.Settings.SetBool(WelcomeShownKey, true);
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ThemeHelper.UseDarkTitleBar(this);
    }

    public static bool ShouldShow(AppState appState)
    {
        if (appState.Settings.GetBool(WelcomeShownKey)) return false;
        // Don't pester existing users who already configured the app.
        return string.IsNullOrEmpty(appState.DeepgramApiKey);
    }

    private void OnMaybeLater(object sender, RoutedEventArgs e) => Close();

    private void OnOpenSettings(object sender, RoutedEventArgs e)
    {
        Close();
        _onOpenSettings();
    }

    private void OnNavigate(object sender, RequestNavigateEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); } catch { }
        e.Handled = true;
    }
}
