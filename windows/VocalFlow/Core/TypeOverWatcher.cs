using System.Diagnostics;
using System.Windows.Automation;
using Timer = System.Threading.Timer;

namespace VocalFlow.Core;

/// <summary>
/// Watches the focused text field (via UI Automation) for a short window after VocalFlow injects
/// text, and reports an in-place spelling correction of an injected word. Windows port of the macOS
/// <c>TypeOverWatcher</c>: UIA's <c>AutomationElement.FocusedElement</c> stands in for the AX
/// <c>kAXFocusedUIElement</c>.
///
/// Change detection is by <b>polling</b> the element's text on a background timer rather than by UIA
/// change events: value/text-changed events are raised inconsistently across apps (classic Win32 edit
/// controls in particular), whereas re-reading the value — which we already confirmed is readable at
/// <see cref="Start"/> — works everywhere the field exposes its text. This mirrors the macOS AX
/// observer's effect without depending on any app to raise events correctly.
///
/// Privacy: it only diffs against what was injected and keeps just the wrong→right word pair — it
/// never stores the surrounding field text.
///
/// All UI Automation work runs on thread-pool threads (never the WPF UI thread), which is the
/// Microsoft-recommended pattern for UIA clients. Standard Win32 edit fields expose their text well;
/// browsers/Electron/terminals do so inconsistently (a platform limitation, same as the macOS AX story).
/// </summary>
public sealed class TypeOverWatcher
{
    /// <summary>
    /// Called once the user has *finished* editing a word into its corrected spelling. <c>original</c>
    /// is the word that was typed and corrected away from, so the caller can drop it and its
    /// near-variants from the dictionary — collapsing successive re-spellings of the same word.
    /// Invoked on a background thread; the handler is responsible for marshalling to the UI thread.
    /// </summary>
    public Action<string /* corrected */, string /* original */>? OnCorrection;

    private readonly object _gate = new();

    private AutomationElement? _element;
    private string _baseline = "";
    private string _lastPolled = "";
    private HashSet<string> _injectedWords = new();
    private string? _lastLearned;   // the word we've already auto-added this session

    private Timer? _startTimer;
    private Timer? _pollTimer;
    private Timer? _settleTimer;
    private Timer? _stopTimer;
    private int _polling;           // re-entrancy guard so a slow UIA read can't overlap the next tick

    private const int StartDelayMs = 500;      // let the paste settle before snapshotting the baseline
    private const int BaselineTimeoutMs = 3000; // keep re-reading up to this long for the paste to land
    private const int BaselinePollMs = 150;    // re-check cadence while waiting for the injected text
    private const int PollMs = 400;            // how often we re-read the field for edits
    private const int SettleMs = 2000;         // idle time before we treat an edit as finished
    private const int WatchMs = 120_000;       // stop watching after two minutes

    /// <summary>
    /// Begin watching after <paramref name="injected"/> was typed into the focused field. The baseline
    /// snapshot is deferred briefly so the paste has settled.
    /// </summary>
    public void Watch(string injected)
    {
        var words = TypeOverDetector.Tokenize(injected).Select(w => w.ToLowerInvariant()).ToHashSet();
        if (words.Count == 0) return;

        lock (_gate)
        {
            _startTimer?.Dispose();
            _startTimer = new Timer(_ => Start(words), null, StartDelayMs, Timeout.Infinite);
        }
    }

    private void Start(HashSet<string> words)
    {
        Stop();
        try
        {
            // Snapshot the baseline only once the paste has actually landed. We re-read the focused
            // field until its text contains the words we injected, which confirms three things at
            // once: the Ctrl+V completed, focus has settled back on the target (not VocalFlow's own
            // recording overlay), and we're reading the element we'll go on to watch. A single blind
            // read at a fixed delay is racy — if it fires a beat early, the baseline is missing the
            // injected text and every later diff sees those words as "new", so nothing is ever
            // learned. Best-effort: if the text never matches (e.g. the app doesn't expose it), fall
            // back to the last readable value so behaviour is no worse than before.
            AutomationElement? el = null;
            string? baseline = null;
            var deadline = Environment.TickCount + BaselineTimeoutMs;
            while (true)
            {
                var focused = SafeFocusedElement();
                if (focused != null && !IsOwnProcess(focused) && TryGetText(focused) is string text)
                {
                    el = focused;
                    baseline = text;
                    if (ContainsAll(words, text)) break;   // injection has landed → trustworthy baseline
                }
                if (Environment.TickCount >= deadline) break;
                Thread.Sleep(BaselinePollMs);
            }

            if (el == null || baseline == null) return;   // never got readable text → nothing to watch

            lock (_gate)
            {
                _element = el;
                _baseline = baseline;
                _lastPolled = baseline;
                _injectedWords = words;
                _lastLearned = null;
                _stopTimer?.Dispose();
                _stopTimer = new Timer(_ => Stop(), null, WatchMs, Timeout.Infinite);
                _pollTimer?.Dispose();
                _pollTimer = new Timer(_ => Poll(), null, PollMs, PollMs);
            }
        }
        catch (Exception e)
        {
            Debug.WriteLine($"[typeover] start failed: {e.Message}");
        }
    }

    /// <summary>
    /// Re-read the focused field on the poll interval. When the text differs from what we last saw,
    /// treat it as an edit and (re)arm the settle timer — we never act on the change directly here.
    /// </summary>
    private void Poll()
    {
        if (Interlocked.Exchange(ref _polling, 1) == 1) return;   // a previous read is still running
        try
        {
            AutomationElement? el;
            string lastPolled;
            lock (_gate)
            {
                el = _element;
                lastPolled = _lastPolled;
            }
            if (el == null) return;   // stopped between ticks

            if (TryGetText(el) is not string current) return;
            if (string.Equals(current, lastPolled, StringComparison.Ordinal)) return;

            bool active;
            lock (_gate)
            {
                active = _element != null;
                if (active) _lastPolled = current;
            }
            if (active) OnEdited();
        }
        catch (Exception e)
        {
            Debug.WriteLine($"[typeover] poll failed: {e.Message}");
        }
        finally
        {
            Interlocked.Exchange(ref _polling, 0);
        }
    }

    /// <summary>
    /// Fires on every detected edit — (re)arm the settle timer so we only evaluate once the user pauses.
    /// Each new keystroke pushes the timer out, so mid-word states like "Aysh" never get learned.
    /// </summary>
    private void OnEdited()
    {
        lock (_gate)
        {
            if (_element == null) return;
            _settleTimer?.Dispose();
            _settleTimer = new Timer(_ => Evaluate(), null, SettleMs, Timeout.Infinite);
        }
    }

    /// <summary>
    /// Run after editing settles: learn the *final* spelling. If we already learned a (now-superseded)
    /// word this session, the corrected value simply supersedes it.
    /// </summary>
    private void Evaluate()
    {
        AutomationElement? el;
        string baseline;
        HashSet<string> injected;
        string? last;
        lock (_gate)
        {
            el = _element;
            baseline = _baseline;
            injected = _injectedWords;
            last = _lastLearned;
        }
        if (el == null) return;

        if (TryGetText(el) is not string current) return;
        if (TypeOverDetector.Correction(injected, baseline, current) is not { } hit) return;
        var (original, corrected) = hit;
        if (string.Equals(corrected, last, StringComparison.OrdinalIgnoreCase)) return;

        lock (_gate) { _lastLearned = corrected; }
        OnCorrection?.Invoke(corrected, original);
    }

    /// <summary>Stop the session: cancel all timers, drop the element, and clear state.</summary>
    public void Stop()
    {
        lock (_gate)
        {
            _pollTimer?.Dispose(); _pollTimer = null;
            _settleTimer?.Dispose(); _settleTimer = null;
            _stopTimer?.Dispose(); _stopTimer = null;
            _element = null;
            _baseline = "";
            _lastPolled = "";
            _injectedWords = new();
            _lastLearned = null;
        }
    }

    /// <summary>Current focused element, or null if UIA can't resolve one right now.</summary>
    private static AutomationElement? SafeFocusedElement()
    {
        try { return AutomationElement.FocusedElement; }
        catch (Exception e) { Debug.WriteLine($"[typeover] focused-element read failed: {e.Message}"); return null; }
    }

    /// <summary>True if the element belongs to our own process (e.g. the recording overlay), which we
    /// must not mistake for the user's target field while focus is settling.</summary>
    private static bool IsOwnProcess(AutomationElement el)
    {
        try { return el.Current.ProcessId == Environment.ProcessId; }
        catch { return false; }
    }

    /// <summary>True if every injected word is present in <paramref name="text"/> (case-insensitive) —
    /// our signal that the paste has landed in the field we're looking at.</summary>
    private static bool ContainsAll(HashSet<string> words, string text)
    {
        var have = TypeOverDetector.Tokenize(text).Select(w => w.ToLowerInvariant()).ToHashSet();
        foreach (var w in words)
            if (!have.Contains(w)) return false;
        return true;
    }

    /// <summary>Read the element's text via ValuePattern, falling back to TextPattern. Null if neither.</summary>
    private static string? TryGetText(AutomationElement el)
    {
        try
        {
            if (el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp))
                return ((ValuePattern)vp).Current.Value;
        }
        catch (Exception e) { Debug.WriteLine($"[typeover] value read failed: {e.Message}"); }

        try
        {
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out var tp))
                return ((TextPattern)tp).DocumentRange.GetText(-1);
        }
        catch (Exception e) { Debug.WriteLine($"[typeover] text read failed: {e.Message}"); }

        return null;
    }
}
