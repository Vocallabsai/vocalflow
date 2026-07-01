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
| Type-over keyword learning | `TypeOverWatcher` (AX observer on focused element) | `Core/TypeOverWatcher` (UI Automation; polls focused element's text) |
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
  of the macOS Accessibility API) instead of `AXObserver`, and **polls** the field's text rather than
  subscribing to change events (UIA change events fire inconsistently across apps). See
  **Type-over keyword learning: coverage & limits** below.

## Type-over keyword learning: coverage & limits

After VocalFlow injects dictated text, it briefly watches the focused field; if you edit a word it
just typed into a close spelling variant (e.g. `Jon` → `John`), the corrected spelling is auto-added
to your **Focus Words** as a spelling lock (which biases Deepgram toward it next time). Re-spelling
the same word updates that entry in place rather than piling up duplicates.

**Where it works.** Anywhere the focused control exposes its text to **UI Automation** — Notepad,
WordPad, standard Win32 edit boxes, most WinUI / WPF / WinForms apps, and many native editors. Focus
is resolved to the text control itself or, if the app focuses a container, its immediate child.

**Where it does *not* work (platform limits, not bugs).**
- **Chromium / Electron apps** — Chrome, Edge, VS Code, Slack, Discord, Teams and other web-view UIs
  render their own text and don't expose it usably to UI Automation.
- **Terminals** and **custom-drawn / canvas editors** — their text isn't published to UIA.
- **Elevated (admin) windows** — a normally-run VocalFlow can't read into a process running as
  administrator (Windows UIPI). Only run VocalFlow elevated if you specifically need this.
- This is the same class of limitation as the macOS version, which likewise depends on the
  accessibility layer.

**Behavioral notes.**
- **~2 s settle** — it learns only after you pause editing for about two seconds, so a half-typed
  word (e.g. `Joh`) is never learned.
- **One correction per dictation** — the baseline is captured per injection, so it learns a single
  word swap from each dictated snippet.
- **Conservative on purpose** — only single-word swaps within a small edit distance, length ≥ 3, and
  excluding everyday/common words are learned, to keep Focus Words clean.
- **Privacy** — it only diffs against the words it injected and keeps just the wrong → right pair; it
  never stores or transmits the surrounding field text.

## Known limitations / TODO

- Run-at-login is not wired up yet (add a Startup shortcut or registry `Run` entry if you want it).
- The tray icon is drawn programmatically; swap in a branded `.ico` if desired.
- No installer yet — ship the published folder/exe, or wrap it with MSIX / Inno Setup.
