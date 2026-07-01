using System.Text;

namespace VocalFlow.Core;

/// <summary>
/// Pure, testable logic for spotting a "type-over" spelling correction: a word VocalFlow injected
/// that the user then edited in place into a close variant. Direct port of the macOS
/// <c>TypeOverDetector</c> — kept free of any UI Automation / Win32 dependency so it can be unit-tested.
/// </summary>
public static class TypeOverDetector
{
    /// <summary>
    /// Common words we never auto-learn — biasing Deepgram toward them (or toward one side of a
    /// homophone like there/their) would hurt recognition. Focus words are meant for names / jargon /
    /// out-of-vocabulary terms.
    /// </summary>
    public static readonly IReadOnlySet<string> CommonWords = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "the","and","that","have","for","not","with","you","this","but","his","from","they",
        "say","her","she","will","one","all","would","there","their","they're","what","out","about",
        "who","get","which","when","make","can","like","time","just","him","know","take","into","your",
        "you're","year","good","some","could","them","see","other","than","then","now","look","only",
        "come","its","it's","over","think","also","back","after","use","two","too","to","how","our",
        "work","first","well","way","even","new","want","because","any","these","give","day","most",
        "here","hear","were","where","we're","been","being","are","off","of","on","in","is","as",
    };

    /// <summary>
    /// Detect a single-word in-place correction. <paramref name="injectedWords"/> are the (lowercased)
    /// words VocalFlow just typed; <paramref name="baseline"/> is the field right after injection;
    /// <paramref name="current"/> is the field after the user edited it. Returns the (original,
    /// corrected) pair preserving the words' real casing, or null when there's no clean single-word fix.
    /// </summary>
    public static (string Original, string Corrected)? Correction(ISet<string> injectedWords, string baseline, string current)
    {
        var baseTokens = Tokenize(baseline);
        var curTokens = Tokenize(current);

        // Count-based diff: how each word's occurrence count changed. Using counts (not set
        // membership) means it still works when a word repeats in the field or when the corrected
        // spelling already appears elsewhere.
        var delta = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var w in baseTokens) { var k = w.ToLowerInvariant(); delta[k] = delta.GetValueOrDefault(k) - 1; }
        foreach (var w in curTokens) { var k = w.ToLowerInvariant(); delta[k] = delta.GetValueOrDefault(k) + 1; }

        var gained = delta.Where(kv => kv.Value > 0).ToList();  // appears more now → the new spelling
        var lost = delta.Where(kv => kv.Value < 0).ToList();    // appears less now → the old spelling
        // Exactly one word swapped for exactly one other (each by a single occurrence).
        if (gained.Count != 1 || lost.Count != 1) return null;
        var added = gained[0];
        var removed = lost[0];
        if (added.Value != 1 || removed.Value != -1) return null;

        var originalLC = removed.Key;
        var correctedLC = added.Key;
        // The word that lost an occurrence must be one VocalFlow injected.
        if (!injectedWords.Contains(originalLC)) return null;

        // The change must be a spelling variant, not an unrelated word…
        var dist = Levenshtein(originalLC, correctedLC);
        var maxLen = Math.Max(originalLC.Length, correctedLC.Length);
        if (!(maxLen >= 3 && dist >= 1 && dist <= Math.Max(2, maxLen / 3))) return null;
        // …and not an everyday word.
        if (CommonWords.Contains(correctedLC)) return null;

        // Preserve the words' real casing as they appear in the text.
        var original = baseTokens.FirstOrDefault(t => string.Equals(t, originalLC, StringComparison.OrdinalIgnoreCase)) ?? originalLC;
        var corrected = curTokens.FirstOrDefault(t => string.Equals(t, correctedLC, StringComparison.OrdinalIgnoreCase)) ?? correctedLC;
        return (original, corrected);
    }

    /// <summary>
    /// Split into word tokens: runs of letters (and apostrophes), keeping only tokens that contain
    /// at least one letter. Mirrors the Swift <c>components(separatedBy: letters∪' inverted)</c>.
    /// </summary>
    public static List<string> Tokenize(string s)
    {
        var tokens = new List<string>();
        var sb = new StringBuilder();
        void Flush()
        {
            if (sb.Length > 0)
            {
                var tok = sb.ToString();
                if (tok.Any(char.IsLetter)) tokens.Add(tok);
                sb.Clear();
            }
        }
        foreach (var ch in s)
        {
            if (char.IsLetter(ch) || ch == '\'') sb.Append(ch);
            else Flush();
        }
        Flush();
        return tokens;
    }

    /// <summary>Classic Levenshtein edit distance (two-row DP).</summary>
    public static int Levenshtein(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;

        var prev = new int[b.Length + 1];
        var cur = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) prev[j] = j;

        for (int i = 1; i <= a.Length; i++)
        {
            cur[0] = i;
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            }
            (prev, cur) = (cur, prev);
        }
        return prev[b.Length];
    }
}
