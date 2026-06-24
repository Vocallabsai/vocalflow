namespace VocalFlow.Core;

/// <summary>A streaming-capable Deepgram model and the languages it supports.</summary>
public sealed record DeepgramModel(string CanonicalName, string DisplayName, IReadOnlyList<string> Languages)
{
    public string Id => CanonicalName;
}

/// <summary>An LLM model id + human-readable name.</summary>
public sealed record LlmModel(string Id, string DisplayName);

/// <summary>Audio input device. Id is the WASAPI endpoint id (persisted); empty = system default.</summary>
public sealed record AudioInputDevice(string Id, string Name);

public enum RecordingStateKind { Idle, Recording, Transcribing, Error }

public sealed record RecordingState(RecordingStateKind Kind, string? ErrorMessage = null)
{
    public static readonly RecordingState Idle = new(RecordingStateKind.Idle);
    public static readonly RecordingState Recording = new(RecordingStateKind.Recording);
    public static readonly RecordingState Transcribing = new(RecordingStateKind.Transcribing);
    public static RecordingState Error(string message) => new(RecordingStateKind.Error, message);
}

/// <summary>One dictation result. Mirrors the macOS TranscriptEntry.</summary>
public sealed class TranscriptEntry
{
    public Guid Id { get; } = Guid.NewGuid();
    public DateTime Timestamp { get; }
    public string Raw { get; }
    public string? Processed { get; }

    public TranscriptEntry(DateTime timestamp, string raw, string? processed)
    {
        Timestamp = timestamp;
        Raw = raw;
        Processed = processed;
    }

    /// <summary>What was actually typed into the focused app.</summary>
    public string Typed => Processed ?? Raw;

    /// <summary>True iff an LLM step ran and changed the text.</summary>
    public bool HasLlmProcessing => Processed != null && Processed != Raw;
}

/// <summary>
/// Push-to-talk trigger keys. On Windows these are physical left/right modifier keys
/// distinguished by the low-level keyboard hook's virtual-key codes.
/// </summary>
public enum HotkeyOption
{
    RightAlt,
    LeftAlt,
    RightCtrl,
    LeftCtrl,
}

public static class HotkeyOptionExtensions
{
    // Virtual-key codes reported by the low-level keyboard hook (left/right distinguished).
    public const int VK_LCONTROL = 0xA2;
    public const int VK_RCONTROL = 0xA3;
    public const int VK_LMENU = 0xA4;   // Left Alt
    public const int VK_RMENU = 0xA5;   // Right Alt

    public static string ToRawValue(this HotkeyOption o) => o switch
    {
        HotkeyOption.RightAlt => "right_alt",
        HotkeyOption.LeftAlt => "left_alt",
        HotkeyOption.RightCtrl => "right_ctrl",
        HotkeyOption.LeftCtrl => "left_ctrl",
        _ => "right_alt",
    };

    public static HotkeyOption FromRawValue(string? raw) => raw switch
    {
        "right_alt" => HotkeyOption.RightAlt,
        "left_alt" => HotkeyOption.LeftAlt,
        "right_ctrl" => HotkeyOption.RightCtrl,
        "left_ctrl" => HotkeyOption.LeftCtrl,
        // "right_win" is no longer offered; anyone who had it picked falls back to the default.
        _ => HotkeyOption.RightAlt,
    };

    public static string DisplayName(this HotkeyOption o) => o switch
    {
        HotkeyOption.RightAlt => "Right Alt",
        HotkeyOption.LeftAlt => "Left Alt",
        HotkeyOption.RightCtrl => "Right Ctrl",
        HotkeyOption.LeftCtrl => "Left Ctrl",
        _ => "Right Alt",
    };

    public static int VirtualKey(this HotkeyOption o) => o switch
    {
        HotkeyOption.RightAlt => VK_RMENU,
        HotkeyOption.LeftAlt => VK_LMENU,
        HotkeyOption.RightCtrl => VK_RCONTROL,
        HotkeyOption.LeftCtrl => VK_LCONTROL,
        _ => VK_RMENU,
    };

    public static IReadOnlyList<HotkeyOption> All { get; } = Enum.GetValues<HotkeyOption>();
}
