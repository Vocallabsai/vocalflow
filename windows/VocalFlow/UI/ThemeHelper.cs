using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace VocalFlow.UI;

/// <summary>
/// Applies a dark window title bar (DWM immersive dark mode) and tints the native caption to the
/// app's VocalLabs theme colors, so the OS chrome blends into the window body instead of sitting on
/// top as a disjoint gray slab. Call from a window's SourceInitialized handler.
/// </summary>
internal static class ThemeHelper
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19; // pre-20H1 builds
    private const int DWMWA_BORDER_COLOR = 34;  // Windows 11 (build 22000+)
    private const int DWMWA_CAPTION_COLOR = 35; // Windows 11 (build 22000+)
    private const int DWMWA_TEXT_COLOR = 36;    // Windows 11 (build 22000+)

    public static void UseDarkTitleBar(Window window)
    {
        try
        {
            var hwnd = new WindowInteropHelper(window).EnsureHandle();
            int on = 1;
            if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref on, sizeof(int));

            // Match the caption to the app body. No-ops on Windows 10, where these attributes
            // are unsupported (DwmSetWindowAttribute just returns an error we ignore).
            TrySetCaptionColor(hwnd, DWMWA_CAPTION_COLOR, "WindowBgColor");
            TrySetCaptionColor(hwnd, DWMWA_TEXT_COLOR, "TextPrimaryColor");
            TrySetCaptionColor(hwnd, DWMWA_BORDER_COLOR, "CardBorderColor");
        }
        catch { /* DWM unavailable -> default title bar, no harm */ }
    }

    /// <summary>Pull a <c>Color</c> from the merged theme and push it to a DWM caption attribute.</summary>
    private static void TrySetCaptionColor(IntPtr hwnd, int attr, string resourceKey)
    {
        if (Application.Current?.TryFindResource(resourceKey) is System.Windows.Media.Color c)
        {
            // DWM wants a COLORREF: 0x00BBGGRR.
            int colorRef = c.R | (c.G << 8) | (c.B << 16);
            DwmSetWindowAttribute(hwnd, attr, ref colorRef, sizeof(int));
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
