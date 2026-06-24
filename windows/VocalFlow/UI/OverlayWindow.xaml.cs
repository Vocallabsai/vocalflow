using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using VocalFlow.Core;
using Rectangle = System.Windows.Shapes.Rectangle;

namespace VocalFlow.UI;

/// <summary>
/// Borderless, click-through, always-on-top "recording" bubble shown at the bottom-center of the
/// primary screen while capture is active. Port of the macOS RecordingOverlayController +
/// WaveformOverlayView.
/// </summary>
public partial class OverlayWindow : Window
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TRANSPARENT = 0x20;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x80;

    private readonly AppState _appState;
    private const double MinBar = 6;
    private const double MaxBar = 28;

    public OverlayWindow(AppState appState)
    {
        InitializeComponent();
        _appState = appState;
        _appState.PropertyChanged += OnAppStateChanged;
        Loaded += (_, _) => StartBarAnimations();
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppState.LiveTranscript)) return;
        var text = _appState.LiveTranscript;
        TranscriptText.Text = text;
        TranscriptText.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        if (IsVisible) Reposition();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    }

    public void ShowOverlay()
    {
        Reposition();
        Opacity = 0;
        Show();
        var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200));
        BeginAnimation(OpacityProperty, fade);
    }

    public void HideOverlay()
    {
        var fade = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(180));
        fade.Completed += (_, _) => Hide();
        BeginAnimation(OpacityProperty, fade);
    }

    private void Reposition()
    {
        // SizeToContent updates lazily; force a measure so ActualWidth is current.
        UpdateLayout();
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        Top = area.Bottom - ActualHeight - 40;
    }

    private void StartBarAnimations()
    {
        Rectangle[] bars = { Bar1, Bar2, Bar3, Bar4 };
        for (int i = 0; i < bars.Length; i++)
        {
            var anim = new DoubleAnimation(MinBar, MaxBar, TimeSpan.FromSeconds(0.5))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                BeginTime = TimeSpan.FromMilliseconds(i * 80),
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            };
            bars[i].BeginAnimation(HeightProperty, anim);
        }
    }

    // Keep the window alive across show/hide for the app lifetime.
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        HideOverlay();
    }

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
