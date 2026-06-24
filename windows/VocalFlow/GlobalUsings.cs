// With both UseWPF and UseWindowsForms enabled, several type names exist in both
// System.Windows.* and System.Windows.Forms.*. Default the ambiguous ones to the WPF types;
// WinForms types are referenced via the `WinForms` alias where needed (see TrayController).
global using Application = System.Windows.Application;
global using Clipboard = System.Windows.Clipboard;
global using MessageBox = System.Windows.MessageBox;
