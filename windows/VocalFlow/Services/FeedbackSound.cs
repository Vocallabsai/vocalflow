using System.Media;

namespace VocalFlow.Services;

/// <summary>
/// Plays a short feedback sound on record start/stop. The macOS app uses named NSSounds; on
/// Windows we map to the standard system sounds. Empty name = muted.
/// </summary>
public static class FeedbackSound
{
    public static readonly IReadOnlyList<string> Options = new[]
    {
        "Asterisk", "Beep", "Exclamation", "Hand", "Question",
    };

    public static void Play(string name)
    {
        if (string.IsNullOrEmpty(name)) return;
        try
        {
            switch (name)
            {
                case "Asterisk": SystemSounds.Asterisk.Play(); break;
                case "Beep": SystemSounds.Beep.Play(); break;
                case "Exclamation": SystemSounds.Exclamation.Play(); break;
                case "Hand": SystemSounds.Hand.Play(); break;
                case "Question": SystemSounds.Question.Play(); break;
                default: SystemSounds.Asterisk.Play(); break;
            }
        }
        catch { /* best effort */ }
    }
}
