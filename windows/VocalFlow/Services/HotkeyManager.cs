using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using VocalFlow.Core;

namespace VocalFlow.Services;

/// <summary>
/// Global push-to-talk via a low-level keyboard hook (WH_KEYBOARD_LL). Hold the configured
/// trigger key to record, release to transcribe; Esc anywhere aborts an in-progress recording.
/// Drives the full pipeline (connect → capture → close → LLM → inject), mirroring the macOS
/// HotkeyManager. The hook callback runs on the WPF UI thread; heavy work is dispatched async
/// so the callback returns immediately and never stalls system input.
/// </summary>
public sealed class HotkeyManager : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int HC_ACTION = 0;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_ESCAPE = 0x1B;

    private readonly AppState _appState;
    private readonly LowLevelKeyboardProc _proc; // kept alive to avoid GC of the delegate
    private IntPtr _hookId = IntPtr.Zero;
    private bool _triggerKeyIsDown;

    public HotkeyManager(AppState appState)
    {
        _appState = appState;
        _proc = HookCallback;
    }

    public void StartListening()
    {
        using var process = Process.GetCurrentProcess();
        using var module = process.MainModule!;
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(module.ModuleName), 0);
        if (_hookId == IntPtr.Zero)
            Debug.WriteLine("[hotkey] SetWindowsHookEx failed");
    }

    private static Dispatcher Ui => Application.Current.Dispatcher;

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == HC_ACTION)
        {
            int vk = Marshal.ReadInt32(lParam); // KBDLLHOOKSTRUCT.vkCode is the first field
            int msg = (int)wParam;
            bool isDown = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
            bool isUp = msg is WM_KEYUP or WM_SYSKEYUP;

            int triggerVk = _appState.SelectedHotkey.VirtualKey();

            if (vk == triggerVk)
            {
                if (isDown && !_triggerKeyIsDown)
                {
                    _triggerKeyIsDown = true;
                    Ui.BeginInvoke(StartRecording);
                }
                else if (isUp && _triggerKeyIsDown)
                {
                    _triggerKeyIsDown = false;
                    Ui.BeginInvoke(() => _ = StopRecordingAndTranscribeAsync());
                }
            }
            else if (isDown && vk == VK_ESCAPE)
            {
                Ui.BeginInvoke(CancelRecording);
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private void StartRecording()
    {
        _appState.RecordingState = RecordingState.Recording;

        // Connect WebSocket and start capture immediately. DeepgramService buffers frames until
        // the socket opens, so audio captured during the handshake isn't lost.
        _appState.DeepgramService.Connect(
            _appState.DeepgramApiKey,
            _appState.SelectedModel,
            _appState.SelectedLanguage);

        try
        {
            _appState.AudioEngine.StartCapture(
                _appState.SelectedAudioDeviceUid,
                buffer => _appState.DeepgramService.SendAudio(buffer));
        }
        catch (Exception e)
        {
            HandleCaptureFailure(e);
            return;
        }

        FeedbackSound.Play(_appState.FeedbackSoundName);
        DelayThen(150, () => _appState.AudioMuter.Mute());
    }

    private void CancelRecording()
    {
        // Only act while actively recording — ignore Esc during transcription/idle.
        if (_appState.RecordingState.Kind != RecordingStateKind.Recording) return;
        _appState.AudioEngine.StopCapture();
        _appState.AudioMuter.Unmute();
        _appState.DeepgramService.Cancel();
        _triggerKeyIsDown = false;
        _appState.RecordingState = RecordingState.Idle;
    }

    private void HandleCaptureFailure(Exception error)
    {
        _appState.AudioMuter.Unmute();
        _appState.DeepgramService.Cancel();
        var message = $"Microphone failed: {error.Message}";
        _appState.RecordingState = RecordingState.Error(message);
        _appState.ReportError(message);
        _triggerKeyIsDown = false;
        DelayThen(4000, () =>
        {
            if (_appState.RecordingState.Kind == RecordingStateKind.Error)
                _appState.RecordingState = RecordingState.Idle;
        });
    }

    private async Task StopRecordingAndTranscribeAsync()
    {
        _appState.RecordingState = RecordingState.Transcribing;
        _appState.AudioEngine.StopCapture();
        _appState.AudioMuter.Unmute();
        FeedbackSound.Play(_appState.FeedbackSoundName);

        string finalTranscript = await _appState.DeepgramService.CloseStreamAsync();
        if (string.IsNullOrEmpty(finalTranscript))
        {
            _appState.RecordingState = RecordingState.Idle;
            return;
        }

        var provider = _appState.SelectedLlmProvider;
        var apiKey = _appState.CurrentLlmApiKey;
        var model = _appState.CurrentLlmModel;
        bool hasLlmConfig = !string.IsNullOrEmpty(apiKey) && !string.IsNullOrEmpty(model);

        var options = new LlmProcessingOptions
        {
            CodeMix = _appState.CodeMixEnabled && !string.IsNullOrEmpty(_appState.SelectedCodeMix)
                ? _appState.SelectedCodeMix : null,
            FixSpelling = _appState.CorrectionModeEnabled,
            FixGrammar = _appState.GrammarCorrectionEnabled,
            TargetLanguage = _appState.TargetLanguageEnabled && !string.IsNullOrEmpty(_appState.SelectedTargetLanguage)
                ? _appState.SelectedTargetLanguage : null,
            CustomPrompt = _appState.CustomSystemPrompt,
        };

        string? processed = null;
        if (hasLlmConfig && options.HasAnyStep)
        {
            try
            {
                processed = await _appState.LlmService.ProcessTextAsync(
                    finalTranscript, options, provider, apiKey, model);
            }
            catch (ApiException e)
            {
                _appState.ReportError($"{provider.DisplayName()}: {e.UserMessage}");
            }
            catch (Exception e)
            {
                _appState.ReportError($"{provider.DisplayName()}: {e.Message}");
            }
        }

        string typed = processed ?? finalTranscript;
        _appState.LastTranscript = typed;
        _appState.RecordTranscript(finalTranscript, processed);
        _appState.TextInjector.Inject(typed);
        _appState.RecordingState = RecordingState.Idle;
    }

    private static void DelayThen(int ms, Action action)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        timer.Tick += (_, _) => { timer.Stop(); action(); };
        timer.Start();
    }

    public void Dispose()
    {
        if (_hookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }
    }

    // MARK: - P/Invoke

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}
