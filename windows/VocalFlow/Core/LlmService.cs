using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace VocalFlow.Core;

/// <summary>
/// Calls Groq/OpenRouter OpenAI-compatible chat completions to post-process a transcript,
/// and lists available models. Port of the macOS LlmService.
/// </summary>
public sealed class LlmService
{
    private static readonly HttpClient ModelsHttp = new();

    /// <summary>Per-request timeout for chat completions (some OpenRouter models take 30s+).</summary>
    public TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(90);

    /// <summary>Delay before the single retry on 429/5xx / network blips.</summary>
    public TimeSpan RetryDelay { get; set; } = TimeSpan.FromMilliseconds(250);

    public async Task<IReadOnlyList<LlmModel>> FetchModelsAsync(LlmProvider provider, string apiKey)
    {
        if (string.IsNullOrEmpty(apiKey)) throw ApiException.MissingKey();

        using var request = new HttpRequestMessage(HttpMethod.Get, provider.ModelsUrl());
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");

        var (data, status) = await PerformAsync(ModelsHttp, request).ConfigureAwait(false);
        if (status < 200 || status >= 300)
            throw ApiException.Http(status, data);

        LlmModelsResponse? root;
        try { root = JsonSerializer.Deserialize<LlmModelsResponse>(data); }
        catch { throw ApiException.Decoding(); }
        if (root == null) throw ApiException.Decoding();

        return (root.Data ?? new())
            .Select(m => new LlmModel(m.Id, m.Name ?? m.Id))
            .OrderBy(m => m.DisplayName.ToLowerInvariant(), StringComparer.Ordinal)
            .ToList();
    }

    public async Task<string> ProcessTextAsync(
        string text, LlmProcessingOptions options, LlmProvider provider, string apiKey, string model)
    {
        var systemPrompt = BuildSystemPrompt(options);
        if (systemPrompt == null) return text;
        if (string.IsNullOrEmpty(apiKey)) throw ApiException.MissingKey();
        if (string.IsNullOrEmpty(model)) throw ApiException.MissingModel();

        var body = new
        {
            model,
            messages = new[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = text },
            },
            temperature = 0,
        };

        string json;
        try { json = JsonSerializer.Serialize(body); }
        catch { throw ApiException.Encoding(); }

        // A fresh client per call so we can apply the long per-request timeout.
        using var client = new HttpClient { Timeout = RequestTimeout };
        return await SendChatCompletionAsync(client, provider, apiKey, json, allowRetry: true).ConfigureAwait(false);
    }

    /// <summary>
    /// Pure prompt assembly. Deterministic given options; returns null when no steps are enabled.
    /// </summary>
    public static string? BuildSystemPrompt(LlmProcessingOptions options)
    {
        if (!options.HasAnyStep) return null;

        var instructions = new List<string>();
        int step = 1;

        if (options.CodeMix is { } mixType)
        {
            instructions.Add($"{step}. The input is in {mixType}. Transliterate any non-Roman script (such as Devanagari, Tamil, etc.) to Roman script. Keep English words as-is. Do not translate — preserve the original meaning in mixed form.");
            step++;
        }
        if (options.FixSpelling)
        {
            instructions.Add($"{step}. Fix any spelling mistakes. Do not change meaning or structure.");
            step++;
        }
        if (options.FixGrammar)
        {
            instructions.Add($"{step}. Fix any grammar mistakes. Do not change meaning or add content.");
            step++;
        }
        if (options.TargetLanguage is { } lang)
        {
            instructions.Add($"{step}. Translate the entire text to {lang}. Every word must be in {lang}.");
        }

        string? stepsBlock = instructions.Count == 0
            ? null
            : "Process the following text by applying these steps in order:\n" + string.Join("\n", instructions);

        var trimmedCustom = options.CustomPrompt?.Trim() ?? "";
        string? customBlock = trimmedCustom.Length == 0 ? null : trimmedCustom;

        var blocks = new[] { customBlock, stepsBlock, "Return only the final processed text with no explanation." }
            .Where(b => b != null);
        return string.Join("\n\n", blocks);
    }

    private async Task<string> SendChatCompletionAsync(
        HttpClient client, LlmProvider provider, string apiKey, string json, bool allowRetry)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, provider.ChatCompletionsUrl());
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        if (provider == LlmProvider.OpenRouter)
        {
            request.Headers.TryAddWithoutValidation("HTTP-Referer", "https://github.com/Vocallabsai/vocalflow");
            request.Headers.TryAddWithoutValidation("X-Title", "VocalFlow");
        }

        int status;
        string data;
        try
        {
            (data, status) = await PerformAsync(client, request).ConfigureAwait(false);
        }
        catch (ApiException e) when (allowRetry && e.ErrorKind == ApiException.Kind.Network)
        {
            await Task.Delay(RetryDelay).ConfigureAwait(false);
            return await SendChatCompletionAsync(client, provider, apiKey, json, allowRetry: false).ConfigureAwait(false);
        }

        if (status < 200 || status >= 300)
        {
            Debug.WriteLine($"[llm] {provider.DisplayName()} /chat/completions HTTP {status}: {data}");
            if (allowRetry && (status == 429 || (status >= 500 && status < 600)))
            {
                await Task.Delay(RetryDelay).ConfigureAwait(false);
                return await SendChatCompletionAsync(client, provider, apiKey, json, allowRetry: false).ConfigureAwait(false);
            }
            throw ApiException.Http(status, data);
        }

        LlmChatResponse? root;
        try { root = JsonSerializer.Deserialize<LlmChatResponse>(data); }
        catch { throw ApiException.Decoding(); }
        var result = root?.Choices is { Count: > 0 } ch ? ch[0].Message?.Content : null;
        if (string.IsNullOrEmpty(result))
            throw ApiException.Decoding();

        return StripReasoning(result!);
    }

    /// <summary>
    /// Strip reasoning/thinking blocks some models emit inline. Handles &lt;think&gt;, &lt;thinking&gt;,
    /// and &lt;reasoning&gt; tags (case-insensitive). For an unbalanced opener, keep only text after
    /// the last opening tag.
    /// </summary>
    public static string StripReasoning(string text)
    {
        string[] tags = { "think", "thinking", "reasoning" };
        var output = text;
        foreach (var tag in tags)
        {
            var pattern = $"<\\s*{tag}\\s*>[\\s\\S]*?<\\s*/\\s*{tag}\\s*>";
            output = Regex.Replace(output, pattern, "", RegexOptions.IgnoreCase);

            var openPattern = $"<\\s*{tag}\\s*>";
            var matches = Regex.Matches(output, openPattern, RegexOptions.IgnoreCase);
            if (matches.Count > 0)
            {
                var last = matches[^1];
                output = output[(last.Index + last.Length)..];
            }
        }
        return output.Trim();
    }

    private static async Task<(string body, int status)> PerformAsync(HttpClient client, HttpRequestMessage request)
    {
        try
        {
            var response = await client.SendAsync(request).ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            return (body, (int)response.StatusCode);
        }
        catch (Exception e)
        {
            throw ApiException.Network(e.Message);
        }
    }

    // MARK: - Response DTOs

    private sealed class LlmModelsResponse
    {
        [JsonPropertyName("data")] public List<LlmModelEntry>? Data { get; set; }
    }

    private sealed class LlmModelEntry
    {
        [JsonPropertyName("id")] public string Id { get; set; } = "";
        [JsonPropertyName("name")] public string? Name { get; set; }
    }

    private sealed class LlmChatResponse
    {
        [JsonPropertyName("choices")] public List<LlmChoice>? Choices { get; set; }
    }

    private sealed class LlmChoice
    {
        [JsonPropertyName("message")] public LlmMessage? Message { get; set; }
    }

    private sealed class LlmMessage
    {
        [JsonPropertyName("content")] public string? Content { get; set; }
    }
}
