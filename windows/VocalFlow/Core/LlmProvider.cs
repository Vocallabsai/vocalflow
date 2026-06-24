namespace VocalFlow.Core;

public enum LlmProvider { Groq, OpenRouter }

public static class LlmProviderExtensions
{
    public static string ToRawValue(this LlmProvider p) => p switch
    {
        LlmProvider.Groq => "groq",
        LlmProvider.OpenRouter => "open_router",
        _ => "groq",
    };

    public static LlmProvider FromRawValue(string? raw) => raw switch
    {
        "groq" => LlmProvider.Groq,
        "open_router" => LlmProvider.OpenRouter,
        _ => LlmProvider.Groq,
    };

    public static string DisplayName(this LlmProvider p) => p switch
    {
        LlmProvider.Groq => "Groq",
        LlmProvider.OpenRouter => "OpenRouter",
        _ => "Groq",
    };

    public static string BaseUrl(this LlmProvider p) => p switch
    {
        LlmProvider.Groq => "https://api.groq.com/openai/v1",
        LlmProvider.OpenRouter => "https://openrouter.ai/api/v1",
        _ => "https://api.groq.com/openai/v1",
    };

    public static string ModelsUrl(this LlmProvider p) => p.BaseUrl() + "/models";
    public static string ChatCompletionsUrl(this LlmProvider p) => p.BaseUrl() + "/chat/completions";

    public static string SignupUrl(this LlmProvider p) => p switch
    {
        LlmProvider.Groq => "https://console.groq.com/keys",
        LlmProvider.OpenRouter => "https://openrouter.ai/keys",
        _ => "https://console.groq.com/keys",
    };

    /// <summary>Storage key for the provider's API key.</summary>
    public static string CredentialKey(this LlmProvider p) => p switch
    {
        LlmProvider.Groq => "groq_api_key",
        LlmProvider.OpenRouter => "openrouter_api_key",
        _ => "groq_api_key",
    };

    public static IReadOnlyList<LlmProvider> All { get; } = Enum.GetValues<LlmProvider>();
}

/// <summary>
/// The post-processing steps to apply to a transcript. Null/empty fields are disabled.
/// </summary>
public sealed class LlmProcessingOptions
{
    public string? CodeMix { get; init; }        // null = disabled; value = mix type e.g. "Hinglish"
    public bool FixSpelling { get; init; }
    public bool FixGrammar { get; init; }
    public string? TargetLanguage { get; init; } // null = disabled; value = e.g. "French"
    public string? CustomPrompt { get; init; }   // null/empty = disabled

    public bool HasAnyStep
    {
        get
        {
            if (CodeMix != null || FixSpelling || FixGrammar || TargetLanguage != null) return true;
            return !string.IsNullOrWhiteSpace(CustomPrompt);
        }
    }
}
