# VocalFlow

A lightweight macOS menu bar app that lets you dictate into any text field — anywhere on your Mac — using a hold-to-record hotkey.

Hold a key → speak → release → text appears at your cursor.

## How it works

1. Hold the configured hotkey (e.g. Right Option)
2. Speak
3. Release — the transcript is injected at your cursor via simulated paste

Audio is streamed in real-time to [Deepgram](https://deepgram.com) for transcription. Optionally, the raw transcript is passed through [Groq](https://groq.com) for spelling correction, grammar correction, code-mix transliteration, or translation before injection.

## Features

- **Hold-to-record hotkey** — configurable: Right Option, Left Option, Right/Left Command, or Fn
- **Real-time streaming ASR** — powered by Deepgram's WebSocket API
- **Post-processing via Groq LLM**
  - Spelling correction
  - Grammar correction
  - Code-mix transliteration (Hinglish, Tanglish, Spanglish, and 13 more)
  - Translation to any target language
- **Works in any app** — text is injected via simulated Cmd+V
- **Menu bar app** — no Dock icon, minimal footprint
- **API keys stored in Keychain** — never written to disk in plaintext

## Requirements

- macOS 13 Ventura or later
- [Deepgram API key](https://console.deepgram.com/signup) (free tier available)
- [Groq API key](https://console.groq.com) (optional, for post-processing)
- Xcode Command Line Tools or Xcode (to build from source)

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

# Stream system logs for a running instance
log stream --predicate 'process == "VocalFlow"' --level debug
```

## Setup

1. Click the VocalFlow icon in the menu bar → **Settings**
2. Paste your **Deepgram API key** and click **Save**, then **Fetch Models**
3. Choose a model and language
4. (Optional) Paste your **Groq API key**, fetch models, and enable any post-processing options
5. Choose your preferred hotkey
6. Start dictating

## Project Structure

```
Sources/VocalFlow/
├── main.swift              # Entry point
├── AppDelegate.swift       # App lifecycle
├── AppState.swift          # Shared state, settings persistence
├── HotkeyManager.swift     # Global modifier-key monitor
├── AudioEngine.swift       # Microphone capture (AVAudioEngine)
├── DeepgramService.swift   # WebSocket streaming to Deepgram
├── GroqService.swift       # LLM post-processing via Groq
├── TextInjector.swift      # Clipboard-based text injection
├── MenuBarController.swift # Menu bar icon and popover
├── SettingsView.swift      # SwiftUI settings panel
├── PermissionsManager.swift# Microphone & Accessibility permissions
└── KeychainService.swift   # Secure API key storage
```

## Contributing

Pull requests are welcome. For significant changes, open an issue first to discuss what you'd like to change.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Open a pull request

## License

[MIT](LICENSE)
