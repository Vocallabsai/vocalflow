using System.Diagnostics;
using System.Windows.Automation;
using Timer = System.Threading.Timer;

namespace VocalFlow.Core;

/// <summary>
/// Watches the focused text field (via UI Automation) for a short window after VocalFlow injects
/// text, and reports an in-place spelling correction of an injected word. Windows port of the macOS
/// <c>TypeOverWatcher</c>: UIA's <c>AutomationElement.FocusedElement</c> + a value/text-changed event
/// stand in for the AX <c>kAXFocusedUIElement</c> + <c>kAXValueChangedNotification</c>.
///
/// Privacy: it only diffs against what was injected and keeps just the wrong→right word pair — it
/// never stores the surrounding field text.
///
/// All UI Automation work runs on thread-pool threads (never the WPF UI thread), which is both the
/// Microsoft-recommended pattern for UIA clients and where the change-event callbacks already arrive.
/// Standard Win32 edit fields expose their text well; browsers/Electron/terminals do so
/// inconsistently (a platform limitation, same as the macOS AX story).
/// </summary>
public sealed class TypeOverWatcher
{
    /// <summary>
    /// Called once the user has *finished* editing a word into its corrected spelling. <c>original</c>
    /// is the word that was typed and corrected away from, so the caller can drop it and its
    /// near-variants from the dictionary — collapsing successive re-spellings of the same word.
    /// </summary>
    public Action<string /* corrected */, string /* original */>? OnCorrection;

    private readonly object _gate = new();

    private AutomationElement? _element;
    private AutomationPropertyChangedEventHandler? _valueHandler;
    private AutomationEventHandler? _textHandler;
    private string _baseline = "";
    private HashSet<string> _injectedWords = new();
    private string? _lastLearned;   // the word we've already auto-added this session

    private Timer? _startTimer;
    private Timer? _settleTimer;
    private Timer? _stopTimer;

    private const int StartDelayMs = 500;      // let the paste settle before snapshotting the baseline
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
            var el = AutomationElement.FocusedElement;
            if (el == null) return;
            if (TryGetText(el) is not string value) return;   // field must expose its text

            var valueHandler = new AutomationPropertyChangedEventHandler(OnUiaChanged);
            bool subscribed = false;
            try
            {
                Automation.AddAutomationPropertyChangedEventHandler(
                    el, TreeScope.Element, valueHandler, ValuePattern.ValueProperty);
                subscribed = true;
            }
            catch (Exception e) { Debug.WriteLine($"[typeover] value subscribe failed: {e.Message}"); }

            // Rich-text / document controls surface edits via TextPattern rather than ValuePattern.
            AutomationEventHandler? textHandler = null;
            if (SupportsPattern(el, TextPattern.Pattern))
            {
                textHandler = new AutomationEventHandler((_, _) => OnEdited());
                try
                {
                    Automation.AddAutomationEventHandler(
                        TextPattern.TextChangedEvent, el, TreeScope.Element, textHandler);
                    subscribed = true;
                }
                catch (Exception e) { Debug.WriteLine($"[typeover] text subscribe failed: {e.Message}"); textHandler = null; }
            }

            if (!subscribed) return;   // nothing to listen on → don't hold a dead element

            lock (_gate)
            {
                _element = el;
                _valueHandler = valueHandler;
                _textHandler = textHandler;
                _baseline = value;
                _injectedWords = words;
                _lastLearned = null;
                _stopTimer?.Dispose();
                _stopTimer = new Timer(_ => Stop(), null, WatchMs, Timeout.Infinite);
            }
        }
        catch (Exception e)
        {
            Debug.WriteLine($"[typeover] start failed: {e.Message}");
        }
    }

    // UIA property-changed callbacks arrive on a UIA worker thread; we don't act yet.
    private void OnUiaChanged(object sender, AutomationPropertyChangedEventArgs e) => OnEdited();

    /// <summary>
    /// Fires on every edit — (re)arm the settle timer so we only evaluate once the user pauses. Each
    /// new keystroke pushes the timer out, so mid-word states like "Aysh" never get learned.
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

    public void Stop()
    {
        AutomationElement? el;
        AutomationPropertyChangedEventHandler? valueHandler;
        AutomationEventHandler? textHandler;
        lock (_gate)
        {
            _settleTimer?.Dispose(); _settleTimer = null;
            _stopTimer?.Dispose(); _stopTimer = null;
            el = _element;
            valueHandler = _valueHandler;
            textHandler = _textHandler;
            _element = null;
            _valueHandler = null;
            _textHandler = null;
            _baseline = "";
            _injectedWords = new();
            _lastLearned = null;
        }

        if (el == null) return;
        try { if (valueHandler != null) Automation.RemoveAutomationPropertyChangedEventHandler(el, valueHandler); }
        catch (Exception e) { Debug.WriteLine($"[typeover] value unsubscribe failed: {e.Message}"); }
        try { if (textHandler != null) Automation.RemoveAutomationEventHandler(TextPattern.TextChangedEvent, el, textHandler); }
        catch (Exception e) { Debug.WriteLine($"[typeover] text unsubscribe failed: {e.Message}"); }
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

    private static bool SupportsPattern(AutomationElement el, AutomationPattern pattern)
    {
        try { return el.TryGetCurrentPattern(pattern, out _); }
        catch { return false; }
    }
}
