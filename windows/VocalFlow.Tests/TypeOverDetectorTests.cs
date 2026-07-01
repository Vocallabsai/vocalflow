using VocalFlow.Core;
using Xunit;

namespace VocalFlow.Tests;

/// <summary>
/// Mirrors the macOS <c>TypeOverDetectorTests</c> so the two ports stay behaviourally identical.
/// </summary>
public class TypeOverDetectorTests
{
    private static string? Corrected(string[] injected, string baseline, string current)
        => TypeOverDetector.Correction(
            injected.Select(w => w.ToLowerInvariant()).ToHashSet(),
            baseline, current)?.Corrected;

    // MARK: - Should detect a correction

    [Fact]
    public void BasicSpellingFix()
        => Assert.Equal("john", Corrected(new[] { "tell", "jon", "about", "it" }, "tell jon about it", "tell john about it"));

    [Fact]
    public void PreservesCorrectedWordCasing()
        => Assert.Equal("John", Corrected(new[] { "jon" }, "hi Jon", "hi John"));

    // Regression: count-based diff must survive repeated words in the field.
    [Fact]
    public void CorrectedWordAlreadyPresentElsewhere()
        => Assert.Equal("ayush", Corrected(new[] { "ayewsh" }, "hi ayush ayewsh", "hi ayush ayush"));

    [Fact]
    public void InjectedWordRepeatsEditingOneOccurrence()
        => Assert.Equal("ayush", Corrected(new[] { "ayewsh" }, "ayewsh ayewsh", "ayush ayewsh"));

    // MARK: - Should NOT detect

    [Fact]
    public void NoChange()
        => Assert.Null(Corrected(new[] { "jon" }, "tell jon", "tell jon"));

    [Fact]
    public void EditToWordVocalFlowDidNotInject()
        // "work" wasn't injected → editing it is the user's own text, not a correction.
        => Assert.Null(Corrected(new[] { "jon" }, "email jon at work", "email jon at home"));

    [Fact]
    public void IgnoresCommonHomophone()
        => Assert.Null(Corrected(new[] { "there" }, "go there now", "go their now"));

    [Fact]
    public void IgnoresTwoWordChange()
        => Assert.Null(Corrected(new[] { "jon", "smith" }, "call jon smith", "call john smyth"));

    [Fact]
    public void IgnoresUnrelatedReplacement()
        => Assert.Null(Corrected(new[] { "cat" }, "the cat", "the dog"));

    [Fact]
    public void IgnoresShortWords()
        => Assert.Null(Corrected(new[] { "it" }, "go to it", "go to is"));

    // MARK: - Levenshtein

    [Fact]
    public void Levenshtein()
    {
        Assert.Equal(1, TypeOverDetector.Levenshtein("jon", "john"));
        Assert.Equal(3, TypeOverDetector.Levenshtein("kitten", "sitting"));
        Assert.Equal(0, TypeOverDetector.Levenshtein("same", "same"));
    }
}
