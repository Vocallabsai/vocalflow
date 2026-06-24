using System.IO;
using System.Text.Json;

namespace VocalFlow.Services;

/// <summary>
/// Persists plain (non-secret) preferences to %APPDATA%\VocalFlow\settings.json.
/// The Windows analogue of macOS UserDefaults. Keys match the macOS DefaultsKey raw values
/// so behaviour is identical. Writes are debounced-free (small file, infrequent writes).
/// </summary>
public sealed class SettingsStore
{
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VocalFlow");
    private static readonly string FilePath = Path.Combine(Dir, "settings.json");

    private readonly object _lock = new();
    private Dictionary<string, string> _values;

    public SettingsStore()
    {
        _values = Load();
    }

    private static Dictionary<string, string> Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath);
                return JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? new();
            }
        }
        catch { /* corrupt/unreadable file -> start fresh */ }
        return new();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var json = JsonSerializer.Serialize(_values, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(FilePath, json);
        }
        catch { /* best effort */ }
    }

    public string? GetString(string key)
    {
        lock (_lock) return _values.TryGetValue(key, out var v) ? v : null;
    }

    public bool GetBool(string key)
    {
        lock (_lock) return _values.TryGetValue(key, out var v) && v == "true";
    }

    public void SetString(string key, string? value)
    {
        lock (_lock)
        {
            if (value == null) _values.Remove(key);
            else _values[key] = value;
            Save();
        }
    }

    public void SetBool(string key, bool value) => SetString(key, value ? "true" : "false");
}
