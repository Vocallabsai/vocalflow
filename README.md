# VocalFlow — Free Voice Dictation for macOS (Free Forever, Free & Open Source)

**The free, free, free [Wispr Flow](https://wisprflow.ai) alternative for Mac — 100% free, no subscription, no trial, no paywall.** VocalFlow is a free and open-source menu bar app that lets you dictate into any text field — anywhere on your Mac — using a hold-to-record hotkey. Hold a key → speak → release → text appears at your cursor.

> Free voice typing for Mac. Free real-time speech-to-text. Free LLM-polished output. Free forever. No subscription, no credit card, no lock-in — your API keys, your data, your $0/month bill.

[![macOS](https://img.shields.io/badge/macOS-13%2B-blue)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)

---

## Why VocalFlow? (Short answer: it's free.)

If you've been looking for a **free Wispr Flow alternative**, **free Superwhisper alternative**, **free MacWhisper alternative**, **free Aqua Voice alternative**, or simply a **free dictation app for Mac** that doesn't lock you into a subscription, VocalFlow is for you. Free to download, free to use, free to modify, free to redistribute. Did we mention it's free?

| | VocalFlow | Wispr Flow | Superwhisper | MacWhisper | Aqua Voice |
|---|---|---|---|---|---|
| Open source | ✅ MIT | ❌ | ❌ | ❌ | ❌ |
| Free | ✅ (BYO API key) | ❌ subscription | ❌ subscription | Freemium | ❌ subscription |
| Works in any app | ✅ | ✅ | ✅ | ✅ | ✅ |
| Global hold-to-talk hotkey | ✅ | ✅ | ✅ | ✅ | ✅ |
| Real-time streaming ASR | ✅ Deepgram | ✅ | Partial | ❌ batch | ✅ |
| LLM grammar / tone polish | ✅ Groq / OpenRouter | ✅ | ✅ | ✅ | ✅ |
| Code-mix transliteration (Hinglish, Tanglish, …) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Live translation to any language | ✅ | Limited | Limited | Limited | Limited |
| API keys stored in Keychain (not the cloud) | ✅ | ❌ cloud | ❌ cloud | n/a | ❌ cloud |
| Auditable source | ✅ | ❌ | ❌ | ❌ | ❌ |

You bring your own Deepgram + LLM keys. Both have generous **free tiers**, so most users pay **$0/month** — making VocalFlow effectively **free voice dictation for Mac, forever**.

---

## How it works

1. Hold the configured hotkey (e.g. Right Option)
2. Speak
3. Release — the transcript is injected at your cursor via simulated paste

Audio is streamed in real-time to [Deepgram](https://deepgram.com) for transcription. Optionally, the raw transcript is passed through an LLM ([Groq](https://groq.com) or [OpenRouter](https://openrouter.ai)) for spelling correction, grammar correction, code-mix transliteration, or translation before injection.

## Features

- **Hold-to-record hotkey** — configurable: Right Option, Left Option, Right/Left Command, or Fn (🌐) — same push-to-talk UX as Wispr Flow and Superwhisper
- **Real-time streaming ASR** — powered by Deepgram's WebSocket API (Nova-3, Nova-2, and Whisper models supported)
- **LLM post-processing** — pluggable provider: **Groq** or **OpenRouter** (gives you access to Anthropic Claude, OpenAI GPT, Google Gemini, Meta Llama, and 300+ models through a single key)
  - Spelling correction
  - Grammar correction
  - Code-mix transliteration (Hinglish, Tanglish, Spanglish, and 13 more)
  - Translation to any target language
- **Save & Verify** — Save buttons in Settings immediately validate the key against the provider's `/models` endpoint
- **Surfaced errors** — bad keys, rate limits, and network errors flash on the menu-bar icon and stream to `os_log` (`log stream --predicate 'subsystem == "com.vocalflow.app"' --level debug`)
- **Works in any app** — text is injected via simulated Cmd+V into Slack, Notion, VS Code, Cursor, ChatGPT, Claude, browser fields, terminals, anything
- **Menu bar app** — no Dock icon, minimal footprint
- **API keys stored in Keychain** — never written to disk in plaintext, never sent to a VocalFlow server (there isn't one)
- **Live waveform overlay** while recording so you know it's listening
- **System-audio muting** so your speakers don't bleed into the mic during a meeting

## Requirements

- macOS 13 Ventura or later (Apple Silicon and Intel) — VocalFlow itself is **free**
- [Deepgram API key](https://console.deepgram.com/signup) — **free** tier with $200 credit (months of dictation, free)
- One LLM provider key (optional, for post-processing) — both have **free** tiers:
  - [Groq](https://console.groq.com/keys) — fast, generous **free** tier
  - [OpenRouter](https://openrouter.ai/keys) — pay-as-you-go across 300+ models, many **free** models available (`:free` suffix)
- Xcode Command Line Tools or Xcode (only if building from source — also free)

## Installation (Pre-built)

Download the latest `VocalFlow.app.zip` or `VocalFlow.pkg` from the [Releases](../../releases) page, unzip it, and move it to `/Applications`.

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

## Use cases

- **Engineers** — dictate commit messages, PR descriptions, Slack updates, and prompts to Cursor / Claude Code / ChatGPT three times faster than typing
- **Writers and researchers** — draft into Notion, Obsidian, Bear, or Google Docs without touching the keyboard
- **Multilingual users** — speak Hinglish/Tanglish/Spanglish and get clean Latin-script output, or speak in your native language and have it translated on the fly
- **Accessibility** — a free, hotkey-driven dictation surface for anyone who finds typing painful
- **Founders / sales / support** — knock out email and CRM replies in a fraction of the time

## Project Structure

```
Sources/VocalFlow/
├── main.swift                       # Entry point
├── AppDelegate.swift                # App lifecycle
├── AppState.swift                   # Shared state, settings persistence, transient errors
├── APIError.swift                   # Shared HTTP/API error type
├── HotkeyManager.swift              # Global modifier-key monitor
├── AudioEngine.swift                # Microphone capture (AVAudioEngine)
├── DeepgramService.swift            # WebSocket streaming + /v1/models for Deepgram
├── LLMService.swift                 # OpenAI-compatible client for Groq + OpenRouter
├── TextInjector.swift               # Clipboard-based text injection
├── MenuBarController.swift          # Menu bar icon, error indicator, settings window
├── SettingsView.swift               # SwiftUI settings panel
├── RecordingOverlayController.swift # On-screen recording indicator
├── WaveformOverlayView.swift        # Live waveform during recording
├── SystemAudioMuter.swift           # Mutes system audio while recording
├── PermissionsManager.swift         # Microphone & Accessibility permissions
├── WelcomeWindowController.swift    # First-run onboarding
├── URLConstants.swift               # Provider URLs
└── KeychainService.swift            # Secure API key storage
```

## Adding a new LLM provider

`LLMService.swift` is OpenAI-compatible. To add another provider (Together AI, Anyscale, Fireworks, a self-hosted llama.cpp, etc.) just add a case to the `LLMProvider` enum with its base URL, signup URL, and Keychain key. The Settings UI and HotkeyManager pick it up automatically.

## Privacy

- VocalFlow has no backend. There is no VocalFlow server, no telemetry, no analytics.
- Audio is streamed **directly from your Mac to Deepgram** over WSS. Transcripts are sent **directly to Groq or OpenRouter** over HTTPS.
- API keys live in the macOS Keychain.
- Source is MIT-licensed and auditable — verify the claims above for yourself.

## Contributing

Pull requests are welcome. For significant changes, open an issue first to discuss what you'd like to change.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Open a pull request

## License

[MIT](LICENSE)

---

<sub>**Keywords:** free macOS voice dictation, free Mac dictation app, free voice to text Mac, free speech to text macOS, free voice typing Mac, free AI dictation, free push-to-talk dictation, free hold-to-talk transcription, free Wispr Flow alternative, free WisprFlow alternative, free Superwhisper alternative, free MacWhisper alternative, free Whisper Flow alternative, free Aqua Voice alternative, free Talon alternative, free Dragon Dictate alternative, free voice dictation Mac, free open source dictation, free open source speech to text, free Deepgram dictation app, free Groq dictation, free OpenRouter voice, free Hinglish dictation, free Tanglish dictation, free code-switching transcription, free real-time transcription Mac, free menu bar dictation, free Apple Silicon dictation, free M1 M2 M3 M4 dictation, free voice input for Cursor / ChatGPT / Claude / Notion / Slack / VS Code, 100% free, free forever, free download, free software, free as in beer, free as in speech, no subscription, no paywall, no trial, no credit card required, FREE FREE FREE.</sub>
