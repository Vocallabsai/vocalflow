using System.Text.RegularExpressions;

namespace VocalFlow.Core;

/// <summary>
/// One focus-words dictionary entry: a <c>Key</c> the user may dictate mapped to the <c>Value</c>
/// that should be written. A plain spelling term (no colon) has Value == Key.
/// </summary>
public sealed record DictionaryEntry(string Key, string Value);

/// <summary>
/// Deterministic, code-side application of the focus-words dictionary. This deliberately does NOT
/// go through the LLM: a model treats a glossary as a normalization target and over-fires (mapping
/// every name to the nearest entry, or substring-matching a phrase trigger).
///
/// Only expansion entries (Key != Value, e.g. "ashwin email : a@b.com") are applied here, as a
/// literal, whole-word, case-insensitive phrase replacement. Bare "ashwin" can't match the phrase
/// "ashwin email", so the replacement is unambiguous and never touches unrelated text.
///
/// Spelling entries (Key == Value, e.g. "alecs") are intentionally NOT text-replaced. Mapping a
/// mis-heard word to its intended spelling requires phonetic matching, and any text-only phonetic
/// scheme over-fires on ordinary words (Soundex alone maps the everyday word "also" to the same code
/// as "alecs"). Those terms are instead fed to Deepgram as keyterms (see Keys), so the recognizer —
/// which has the actual audio — biases "alex"→"alecs" without clobbering words that merely look
/// similar on paper. Mirrors the macOS FocusWordsDictionary.
/// </summary>
public static class FocusWordsDictionary
{
    /// <summary>
    /// Parse the raw focus-words string into key → value entries, one per line. A line of the form
    /// "trigger : replacement" becomes a substitution (split on the first colon that isn't part of
    /// "://", so URLs survive); a line with no colon becomes a spelling lock whose value mirrors its
    /// key. Trims whitespace, drops blank lines, and removes case-insensitive duplicate keys.
    /// </summary>
    public static IReadOnlyList<DictionaryEntry> ParseEntries(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return Array.Empty<DictionaryEntry>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var entries = new List<DictionaryEntry>();
        foreach (var line in raw.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.Length == 0) continue;

            string key, value;
            int colon = SeparatorColonIndex(trimmed);
            if (colon >= 0)
            {
                key = trimmed[..colon].Trim();
                var rhs = trimmed[(colon + 1)..].Trim();
                value = rhs.Length == 0 ? key : rhs;
            }
            else
            {
                key = trimmed;
                value = trimmed;
            }
            if (key.Length == 0) continue;
            if (seen.Add(key)) entries.Add(new DictionaryEntry(key, value));
        }
        return entries;
    }

    /// <summary>
    /// The dictionary keys (trigger phrases) — what the user actually says. Fed to Deepgram as
    /// keyterms so recognition is biased toward the spoken triggers, not the written replacements.
    /// </summary>
    public static IReadOnlyList<string> Keys(string? raw) =>
        ParseEntries(raw).Select(e => e.Key).ToList();

    /// <summary>
    /// Apply the dictionary's expansion entries to <paramref name="text"/>, returning the corrected
    /// string. Longer keys run first so a longer phrase wins over a shorter overlapping one. Bare
    /// spelling terms (Key == Value) are skipped — they bias recognition via Keys, not text
    /// replacement. Returns the text unchanged when there are no expansion entries.
    /// </summary>
    public static string Apply(string? raw, string text)
    {
        var entries = ParseEntries(raw);
        if (entries.Count == 0 || string.IsNullOrEmpty(text)) return text;

        var result = text;
        var expansions = entries
            .Where(e => !string.Equals(e.Key, e.Value, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(e => e.Key.Length);
        foreach (var entry in expansions)
            result = ReplaceExpansion(result, entry.Key, entry.Value);

        return result;
    }

    // MARK: - Expansion (literal whole-phrase replacement)

    private static string ReplaceExpansion(string text, string key, string value)
    {
        var words = key
            .Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(Regex.Escape)
            .ToArray();
        if (words.Length == 0) return text;
        // Allow any whitespace run between words; require a non-word-character boundary on each side
        // so "ashwin email" matches as a phrase but "ashwin" alone never matches it.
        var pattern = "(?<!\\w)" + string.Join("\\s+", words) + "(?!\\w)";
        return Regex.Replace(text, pattern, _ => value, RegexOptions.IgnoreCase);
    }

    /// <summary>
    /// Index of the first ":" that separates a trigger from its replacement, skipping any colon
    /// that's part of "://" so a URL (e.g. "https://x.com") survives as a bare term or a value.
    /// </summary>
    private static int SeparatorColonIndex(string s)
    {
        for (int i = 0; i < s.Length; i++)
            if (s[i] == ':' && (i + 1 >= s.Length || s[i + 1] != '/'))
                return i;
        return -1;
    }
}
