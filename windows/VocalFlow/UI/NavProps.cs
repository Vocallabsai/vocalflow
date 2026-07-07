using System.Windows;

namespace VocalFlow.UI;

/// <summary>
/// Attached property carrying a Segoe Fluent/MDL2 glyph string into the shared NavItem
/// (sidebar row) control template, so each row can declare its icon in XAML alongside its
/// label and chip color.
/// </summary>
public static class NavProps
{
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.RegisterAttached(
        "Glyph", typeof(string), typeof(NavProps), new PropertyMetadata(""));

    public static string GetGlyph(DependencyObject obj) => (string)obj.GetValue(GlyphProperty);
    public static void SetGlyph(DependencyObject obj, string value) => obj.SetValue(GlyphProperty, value);
}
