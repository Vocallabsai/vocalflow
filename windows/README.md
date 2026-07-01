# VocalFlow for Windows

A native Windows port of VocalFlow — the free, open-source, bring-your-own-key voice dictation
app. Hold a hotkey, speak, release, and your words are typed into whatever text field has focus.

This is a **separate C#/.NET (WPF) codebase** that mirrors the behavior of the macOS Swift app in
the repo root. The two share only their design/spec, not code.

## How it works

1. Hold the configured trigger key (default **Right Alt**).
2. Speak — audio streams in real time to [Deepgram](https://deepgram.com) for transcription.
3. Release — the final transcript is (optionally) cleaned up by an LLM
   ([Groq](https://groq.com) or [OpenRouter](https://openrouter.ai)), then pasted at your cursor.

Press **Esc** while recording to cancel without transcribing.

You bring your own API keys. Both Deepgram and the LLM providers have free tiers.

## Requirements

- Windows 10 / 11 (x64)
- [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0) to run
  (or the .NET 8 SDK to build)

## Build & run

```powershell
cd windows/VocalFlow
dotnet build
dotnet run
```

The app has no main window — it lives in the **system tray** (mic icon). Double-click the icon, or
right-click → **Settings…**, to configure your API keys.

### Publish a single self-contained .exe

```powershell
cd windows/VocalFlow
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

The output exe under `bin/Release/net8.0-windows/win-x64/publish/` runs on a machine with no .NET
installed.

## First-time setup

1. Open **Settings…** from the tray icon.
2. Paste a **Deepgram API key**, click **Save & Verify**, pick a model + language.
3. (Optional) Pick an **LLM provider**, paste its key, **Save & Verify**, pick a model, and enable
   any of: spelling fix, grammar fix, code-mix transliteration, translation, custom instructions.
4. Hold the hotkey and start dictating.

API keys are stored **encrypted with Windows DPAPI** (per-user) under
`%APPDATA%\VocalFlow\credentials.json`; plain preferences live in `%APPDATA%\VocalFlow\settings.json`.

## Architecture — macOS → Windows mapping

| Concern | macOS (Swift) | Windows (C#) |
|---|---|---|
| Streaming ASR | `DeepgramService` (URLSessionWebSocketTask) | `Core/DeepgramService` (`ClientWebSocket`) |
| LLM post-processing | `LLMService` | `Core/LlmService` (`HttpClient`) |
| App state / settings | `AppState` + `UserDefaults` | `Core/AppState` + `Services/SettingsStore` (JSON) |
| Secret key storage | `KeychainService` (was plain UserDefaults) | `Services/CredentialStore` (DPAPI — actually encrypted) |
| Mic capture → 16 kHz mono PCM16 | `AudioEngine` (AVAudioEngine + AVAudioConverter) | `Services/AudioEngine` (NAudio WASAPI + linear resampler) |
| Global push-to-talk hotkey | `HotkeyManager` (`NSEvent` monitor) | `Services/HotkeyManager` (`WH_KEYBOARD_LL` hook) |
| Text injection | `TextInjector` (NSPasteboard + CGEvent Cmd+V) | `Services/TextInjector` (Clipboard + `SendInput` Ctrl+V) |
| Type-over keyword learning | `TypeOverWatcher` (AX observer on focused element) | `Core/TypeOverWatcher` (UI Automation focus + value/text-changed) |
| Mute system audio while recording | `SystemAudioMuter` (CoreAudio) | `Services/SystemAudioMuter` (NAudio endpoint mute) |
| Tray / menu | `MenuBarController` (NSStatusItem) | `UI/TrayController` (WinForms `NotifyIcon`) |
| Recording overlay | `RecordingOverlayController` + `WaveformOverlayView` | `UI/OverlayWindow` |
| Settings UI | `SettingsView` (SwiftUI) | `UI/SettingsWindow` (WPF) |
| Onboarding | `WelcomeWindowController` | `UI/WelcomeWindow` |
| Tray icons | SF Symbols | `UI/IconFactory` (drawn at runtime) |

## Differences from the macOS version (by necessity)

- **Hotkeys** are Windows modifier keys: Right/Left **Alt**, Right/Left **Ctrl**
  (the Mac uses Option/Command/Fn). Right Alt is the default and the closest analog to Right Option.
  Note: on some keyboard layouts Right Alt is **AltGr** and also emits Left Ctrl — pick Right Ctrl
  or Left Alt if that interferes.
- **No permission prompts.** Windows needs no Accessibility grant for `SendInput`/hooks. Microphone
  access is a system privacy toggle (tray → **Microphone Privacy…** opens it) rather than an
  in-app TCC prompt.
- **Feedback sounds** map to Windows system sounds (Asterisk/Beep/Exclamation/Hand/Question).
- **Key storage is genuinely encrypted** (DPAPI), an upgrade over the macOS app's `KeychainService`,
  which despite its name stored keys in plain `UserDefaults`.
- **Type-over keyword learning** reads the focused field via **UI Automation** (the Windows analog
  of the macOS Accessibility API) instead of `AXObserver`. Same caveat: standard Win32 edit fields
  expose their text well, but browsers/Electron/terminals do so inconsistently, and a non-elevated
  VocalFlow can't read into an elevated (admin) window (UIPI).

## Known limitations / TODO

- Run-at-login is not wired up yet (add a Startup shortcut or registry `Run` entry if you want it).
- The tray icon is drawn programmatically; swap in a branded `.ico` if desired.
- No installer yet — ship the published folder/exe, or wrap it with MSIX / Inno Setup.
