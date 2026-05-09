# VocalFlow

A lightweight macOS menu bar app that lets you dictate into any text field — anywhere on your Mac — using a hold-to-record hotkey.

Hold a key → speak → release → text appears at your cursor.

## How it works

1. Hold the configured hotkey (e.g. Right Option)
2. Speak
3. Release — the transcript is injected at your cursor via simulated paste

Audio is streamed in real-time to [Deepgram](https://deepgram.com) for transcription. Optionally, the raw transcript is passed through an LLM ([Groq](https://groq.com) or [OpenRouter](https://openrouter.ai)) for spelling correction, grammar correction, code-mix transliteration, or translation before injection.

## Features

- **Hold-to-record hotkey** — configurable: Right Option, Left Option, Right/Left Command, or Fn (🌐)
- **Real-time streaming ASR** — powered by Deepgram's WebSocket API
- **LLM post-processing** — pluggable provider: **Groq** or **OpenRouter** (gives you access to Anthropic, OpenAI, Google, Meta, and 300+ models through a single key)
  - Spelling correction
  - Grammar correction
  - Code-mix transliteration (Hinglish, Tanglish, Spanglish, and 13 more)
  - Translation to any target language
- **Save & Verify** — Save buttons in Settings immediately validate the key against the provider's `/models` endpoint
- **Surfaced errors** — bad keys, rate limits, and network errors flash on the menu-bar icon and stream to `os_log` (`log stream --predicate 'subsystem == "com.vocalflow.app"' --level debug`)
- **Works in any app** — text is injected via simulated Cmd+V
- **Menu bar app** — no Dock icon, minimal footprint
- **API keys stored in Keychain** — never written to disk in plaintext

## Requirements

- macOS 13 Ventura or later
- [Deepgram API key](https://console.deepgram.com/signup) (free tier available)
- One LLM provider key (optional, for post-processing):
  - [Groq](https://console.groq.com/keys) — fast, free tier
  - [OpenRouter](https://openrouter.ai/keys) — pay-as-you-go across 300+ models
- Xcode Command Line Tools or Xcode (to build from source)

## Installation (Pre-built)

Download the latest `VocalFlow.app.zip` from the [Releases](../../releases) page, unzip it, and move it to `/Applications`.

Because VocalFlow is not notarized by Apple, macOS will block it on first launch with a *"cannot be opened because the developer cannot be verified"* warning. Run this one-time command to clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/VocalFlow.app
```

Then open it normally. You will not need to run this again.

> **Why is this needed?** macOS Gatekeeper flags apps downloaded from the internet that aren't signed with a paid Apple Developer certificate. The command above removes that flag — it does not disable any security globally.

---

## Build & Run

```bash
# Build release .app bundle
./build.sh

# Launch
open VocalFlow.app
```

After launch, grant permissions when prompted:
- **Microphone** — for audio capture
- **Accessibility** — for global hotkey detection and text injection

> After every rebuild, you must re-grant Accessibility permission in
> System Settings → Privacy & Security → Accessibility.

### Run with logs (for development)

```bash
# Run the binary directly — stdout/stderr appear in the terminal
./VocalFlow.app/Contents/MacOS/VocalFlow

# Or build a debug binary and run via Swift
swift run

# Stream VocalFlow's structured logs (Deepgram + LLM activity, errors)
log stream --predicate 'subsystem == "com.vocalflow.app"' --level debug
```

## Setup

1. Click the VocalFlow icon in the menu bar → **Settings**
2. Paste your **Deepgram API key** and click **Save & Verify** — the key is validated against `/v1/models` immediately
3. Choose a model and language
4. (Optional) In **LLM Post-Processing**, pick **Groq** or **OpenRouter**, paste the matching key, and click **Save & Verify**
5. Pick an LLM model and toggle the corrections / features you want
6. Choose your preferred hotkey
7. Start dictating

## Project Structure

```
Sources/VocalFlow/
├── main.swift                # Entry point
├── AppDelegate.swift         # App lifecycle
├── AppState.swift            # Shared state, settings persistence, transient errors
├── APIError.swift            # Shared HTTP/API error type
├── HotkeyManager.swift       # Global modifier-key monitor
├── AudioEngine.swift         # Microphone capture (AVAudioEngine)
├── DeepgramService.swift     # WebSocket streaming + /v1/models for Deepgram
├── LLMService.swift          # OpenAI-compatible client for Groq + OpenRouter
├── TextInjector.swift        # Clipboard-based text injection
├── MenuBarController.swift   # Menu bar icon, error indicator, settings window
├── SettingsView.swift        # SwiftUI settings panel
├── RecordingOverlayController.swift # On-screen recording indicator
├── WaveformOverlayView.swift # Live waveform during recording
├── SystemAudioMuter.swift    # Mutes system audio while recording
├── PermissionsManager.swift  # Microphone & Accessibility permissions
└── KeychainService.swift     # Secure API key storage
```

## Adding a new LLM provider

`LLMService.swift` is OpenAI-compatible. To add another provider (Together AI, Anyscale, a self-hosted llama.cpp, etc.) just add a case to the `LLMProvider` enum with its base URL, signup URL, and Keychain key. The Settings UI and HotkeyManager pick it up automatically.

## Contributing

Pull requests are welcome. For significant changes, open an issue first to discuss what you'd like to change.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Open a pull request

## License

[MIT](LICENSE)
