using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace VocalFlow.Services;

/// <summary>
/// Secure storage for API keys. Encrypts each value with Windows DPAPI (per-user) and writes the
/// ciphertext to %APPDATA%\VocalFlow\credentials.json. This is the Windows analogue of the
/// macOS Keychain — and an upgrade over the macOS app, whose KeychainService actually stored keys
/// in plain UserDefaults.
/// </summary>
public sealed class CredentialStore
{
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VocalFlow");
    private static readonly string FilePath = Path.Combine(Dir, "credentials.json");

    // Extra entropy mixed into the DPAPI blob — modest defence in depth.
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("VocalFlow.Credentials.v1");

    private readonly object _lock = new();
    private Dictionary<string, string> _blobs; // key -> base64(ciphertext)

    public CredentialStore()
    {
        _blobs = Load();
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
        catch { /* start fresh */ }
        return new();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(_blobs, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* best effort */ }
    }

    public void Store(string key, string value)
    {
        lock (_lock)
        {
            try
            {
                var cipher = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser);
                _blobs[key] = Convert.ToBase64String(cipher);
                Save();
            }
            catch { /* best effort */ }
        }
    }

    public string? Retrieve(string key)
    {
        lock (_lock)
        {
            if (!_blobs.TryGetValue(key, out var b64)) return null;
            try
            {
                var plain = ProtectedData.Unprotect(Convert.FromBase64String(b64), Entropy, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plain);
            }
            catch { return null; }
        }
    }

    public void Delete(string key)
    {
        lock (_lock)
        {
            if (_blobs.Remove(key)) Save();
        }
    }
}
