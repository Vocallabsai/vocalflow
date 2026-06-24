using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VocalFlow.Core;

/// <summary>A newer Windows release found on GitHub.</summary>
public sealed record UpdateInfo(Version Version, string TagName, string AssetUrl, long AssetSize, string ReleaseNotes, string HtmlUrl);

/// <summary>
/// Self-update for the portable Windows build. The macOS app uses Sparkle + a self-hosted appcast;
/// on Windows the distribution channel is GitHub releases, so this polls the releases API for the
/// newest <c>windows-v*</c> tag, downloads the published exe, and swaps it in for the running one.
/// No external dependency — just the GitHub API and an in-place exe replacement.
/// </summary>
public sealed class UpdateService
{
    private const string Owner = "Vocallabsai";
    private const string Repo = "vocalflow";
    private const string TagPrefix = "windows-v";
    private const string AssetName = "VocalFlow-windows-x64.exe";

    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        // 30s covers the (tiny) releases query and the download's header phase; the body is read
        // with ResponseHeadersRead so a slow 100+ MB download isn't bound by this timeout.
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        c.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "VocalFlow-Updater");
        c.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "application/vnd.github+json");
        return c;
    }

    /// <summary>The running build's version, normalised to three components.</summary>
    public static Version CurrentVersion => Normalize(Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0));

    /// <summary>
    /// Query GitHub releases and return the newest published <c>windows-v*</c> release if it is newer
    /// than the running build, otherwise null. Network/parse failures return null (treated as "no update").
    /// </summary>
    public async Task<UpdateInfo?> CheckForUpdateAsync(CancellationToken ct = default)
    {
        var url = $"https://api.github.com/repos/{Owner}/{Repo}/releases?per_page=30";
        using var resp = await Http.GetAsync(url, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode) return null;
        var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

        List<ReleaseDto>? releases;
        try { releases = JsonSerializer.Deserialize<List<ReleaseDto>>(json); }
        catch { return null; }
        if (releases == null) return null;

        UpdateInfo? best = null;
        foreach (var r in releases)
        {
            if (r.Draft || r.Prerelease || r.TagName == null) continue;
            if (!r.TagName.StartsWith(TagPrefix, StringComparison.OrdinalIgnoreCase)) continue;
            if (!TryParseVersion(r.TagName, out var ver)) continue;

            var asset = r.Assets?.FirstOrDefault(a => string.Equals(a.Name, AssetName, StringComparison.OrdinalIgnoreCase))
                        ?? r.Assets?.FirstOrDefault(a => a.Name != null && a.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
            if (asset?.DownloadUrl == null) continue;

            if (best == null || ver > best.Version)
                best = new UpdateInfo(ver, r.TagName, asset.DownloadUrl, asset.Size, r.Body ?? "", r.HtmlUrl ?? "");
        }

        return best != null && best.Version > CurrentVersion ? best : null;
    }

    /// <summary>Download the update's exe into a per-user staging folder; returns the local path.</summary>
    public async Task<string> DownloadAsync(UpdateInfo info, IProgress<double>? progress, CancellationToken ct = default)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VocalFlow", "updates");
        Directory.CreateDirectory(dir);
        var dest = Path.Combine(dir, $"VocalFlow-{info.Version}.exe");

        using var resp = await Http.GetAsync(info.AssetUrl, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        var total = resp.Content.Headers.ContentLength ?? info.AssetSize;

        await using var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        await using var fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None);
        var buffer = new byte[81920];
        long read = 0;
        int n;
        while ((n = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
        {
            await fs.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
            read += n;
            if (total > 0) progress?.Report((double)read / total);
        }
        return dest;
    }

    /// <summary>
    /// Replace the running exe with the downloaded one and relaunch. Windows lets us rename a running
    /// exe, so we move the live file aside, drop the new one in its place, and start it. Returns false
    /// if the swap fails (e.g. the app lives in a read-only folder), with the original left in place.
    /// </summary>
    public static bool ApplyAndRestart(string newExePath)
    {
        var current = Environment.ProcessPath; // on-disk apphost path, even for a single-file build
        if (string.IsNullOrEmpty(current)) return false;

        var old = current + ".old";
        try
        {
            if (File.Exists(old)) File.Delete(old);
            File.Move(current, old);        // allowed while the process is running
            File.Copy(newExePath, current); // put the new build where the old one was

            // Relaunch via a short-delayed shell so this instance — and its single-instance
            // mutex — is fully gone before the new build starts (otherwise the new process
            // would see the mutex and immediately exit).
            Process.Start(new ProcessStartInfo("cmd.exe", $"/c ping 127.0.0.1 -n 3 >nul & start \"\" \"{current}\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden,
            });
            return true;
        }
        catch
        {
            // If we renamed but couldn't replace, restore the original so the app isn't left broken.
            try { if (!File.Exists(current) && File.Exists(old)) File.Move(old, current); }
            catch { /* nothing more we can do */ }
            return false;
        }
    }

    /// <summary>
    /// Clean up after a previous update: delete the leftover <c>*.old</c> and any staged downloads.
    /// Safe to call at startup.
    /// </summary>
    public static void CleanupAfterUpdate()
    {
        try
        {
            var current = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(current) && File.Exists(current + ".old")) File.Delete(current + ".old");
        }
        catch { /* best effort */ }

        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VocalFlow", "updates");
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
        catch { /* best effort */ }
    }

    private static bool TryParseVersion(string tag, out Version version)
    {
        version = new Version(0, 0, 0);
        var s = tag.Substring(TagPrefix.Length);       // strip "windows-v"
        var dash = s.IndexOf('-');                     // drop any -beta / -rc suffix
        if (dash >= 0) s = s.Substring(0, dash);
        if (!Version.TryParse(s, out var v)) return false;
        version = Normalize(v);
        return true;
    }

    private static Version Normalize(Version v) => new(v.Major, v.Minor, v.Build < 0 ? 0 : v.Build);

    // MARK: - GitHub API DTOs

    private sealed class ReleaseDto
    {
        [JsonPropertyName("tag_name")] public string? TagName { get; set; }
        [JsonPropertyName("body")] public string? Body { get; set; }
        [JsonPropertyName("html_url")] public string? HtmlUrl { get; set; }
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<AssetDto>? Assets { get; set; }
    }

    private sealed class AssetDto
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("browser_download_url")] public string? DownloadUrl { get; set; }
        [JsonPropertyName("size")] public long Size { get; set; }
    }
}
