using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace VocalFlow.UI;

/// <summary>
/// Applies a dark window title bar (DWM immersive dark mode) so the OS chrome matches the
/// app's dark VocalLabs theme. Call from a window's SourceInitialized handler.
/// </summary>
internal static class ThemeHelper
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19; // pre-20H1 builds

    public static void UseDarkTitleBar(Window window)
    {
        try
        {
            var hwnd = new WindowInteropHelper(window).EnsureHandle();
            int on = 1;
            if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref on, sizeof(int));
        }
        catch { /* DWM unavailable -> light title bar, no harm */ }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
