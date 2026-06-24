using System.Drawing;
using System.Drawing.Drawing2D;
using VocalFlow.Core;

namespace VocalFlow.UI;

/// <summary>
/// Draws the tray icon for each recording state at runtime, so the app needs no .ico asset.
/// Mirrors the macOS menu-bar symbol changes (mic / mic.fill / ellipsis / warning triangle).
/// </summary>
public static class IconFactory
{
    private static readonly Dictionary<string, Icon> Cache = new();

    public static Icon ForState(RecordingStateKind kind, bool hasError)
    {
        string key = hasError ? "error" : kind.ToString();
        if (Cache.TryGetValue(key, out var cached)) return cached;

        var icon = Render(kind, hasError);
        Cache[key] = icon;
        return icon;
    }

    private static Icon Render(RecordingStateKind kind, bool hasError)
    {
        const int size = 32;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            if (hasError || kind == RecordingStateKind.Error)
            {
                DrawWarning(g, size);
            }
            else if (kind == RecordingStateKind.Transcribing)
            {
                DrawDots(g, size);
            }
            else
            {
                bool active = kind == RecordingStateKind.Recording;
                // Idle = VocalLabs purple; recording = red for an unmistakable "live" signal.
                DrawMic(g, size, active ? Color.FromArgb(255, 80, 80) : Color.FromArgb(145, 72, 255), filled: active);
            }
        }

        IntPtr hIcon = bmp.GetHicon();
        return Icon.FromHandle(hIcon);
    }

    private static void DrawMic(Graphics g, int size, Color color, bool filled)
    {
        using var pen = new Pen(color, 2.4f);
        using var brush = new SolidBrush(color);

        // Capsule body
        float bw = size * 0.34f, bh = size * 0.46f;
        float bx = (size - bw) / 2f, by = size * 0.12f;
        using var path = RoundedRect(bx, by, bw, bh, bw / 2f);
        if (filled) g.FillPath(brush, path); else g.DrawPath(pen, path);

        // Stand arc
        float ax = size * 0.24f, ay = size * 0.30f, aw = size * 0.52f, ah = size * 0.42f;
        g.DrawArc(pen, ax, ay, aw, ah, 20, 140);

        // Stem + base
        g.DrawLine(pen, size / 2f, by + bh + size * 0.12f, size / 2f, size * 0.88f);
        g.DrawLine(pen, size * 0.36f, size * 0.88f, size * 0.64f, size * 0.88f);
    }

    private static void DrawDots(Graphics g, int size)
    {
        using var brush = new SolidBrush(Color.FromArgb(145, 72, 255));
        float r = size * 0.10f;
        float y = size / 2f - r;
        float[] xs = { size * 0.22f, size * 0.5f - r, size * 0.78f - 2 * r };
        foreach (var x in xs) g.FillEllipse(brush, x, y, 2 * r, 2 * r);
    }

    private static void DrawWarning(Graphics g, int size)
    {
        using var brush = new SolidBrush(Color.FromArgb(255, 180, 0));
        using var dark = new SolidBrush(Color.FromArgb(40, 30, 0));
        var pts = new[]
        {
            new PointF(size * 0.5f, size * 0.12f),
            new PointF(size * 0.92f, size * 0.86f),
            new PointF(size * 0.08f, size * 0.86f),
        };
        g.FillPolygon(brush, pts);
        using var font = new Font(FontFamily.GenericSansSerif, size * 0.34f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString("!", font, dark, new RectangleF(0, size * 0.16f, size, size * 0.72f), sf);
    }

    private static GraphicsPath RoundedRect(float x, float y, float w, float h, float r)
    {
        var path = new GraphicsPath();
        float d = r * 2;
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
