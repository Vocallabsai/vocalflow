# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VocalFlow is a macOS menu-bar voice-dictation app: hold a global hotkey → speak → the
transcript is streamed from Deepgram, optionally polished by an LLM (Groq/OpenRouter), and
injected at the cursor via a simulated Cmd+V. It's a **Swift Package Manager executable**
(not an Xcode project), assembled by hand into a `.app` bundle. Users bring their own API
keys (stored in the Keychain).

The repo root is the macOS app. Two ports live in subdirectories and **share no code** with
it — only the design/spec:
- `windows/` — a separate C#/.NET (WPF) codebase.
- `ios/` — an early keyboard-extension *spike* (see "iOS port" below), not a full app.

## Commands

```bash
# Dev loop (build .app bundle, ad-hoc sign, embed Sparkle, reset Accessibility)
./build.sh
./run.sh                      # kills any running instance and relaunches VocalFlow.app

# Raw compile / test
swift build -c release
swift test                                    # all tests
swift test --filter FocusWordsDictionaryTests # one test class (SwiftPM --filter takes a regex)

# Signed + notarized + stapled distributable .pkg + Sparkle appcast (release only)
./scripts/make-pkg.sh         # → dist/VocalFlow.pkg ; needs team signing certs on the Mac
SKIP_NOTARIZE=1 ./scripts/make-pkg.sh         # local signed-but-not-notarized build
```

**After every rebuild you must re-grant Accessibility permission** (System Settings →
Privacy & Security → Accessibility): `build.sh` runs `tccutil reset Accessibility
com.vocalflow.app`, so the old grant is invalidated. Without it the hotkey and text
injection silently do nothing. Debug logs stream via
`log stream --predicate 'subsystem == "com.vocalflow.app"' --level debug`.

## Architecture

`main.swift` sets `.accessory` activation policy (no Dock icon) and hands off to
`AppDelegate`, which is the **composition root** — it wires up every manager and branches
on first-run vs. returning-user:
- First run (`WelcomeWindowController.shouldShow` ⇔ Deepgram key is empty) → guided
  onboarding window that requests Microphone + Accessibility *in context* and starts the
  hotkey once Accessibility is granted.
- Returning user → quiet `PermissionsManager.requestPermissionsIfNeeded` then start listening.

**The dictation pipeline** (follow the data, not the file list):
`HotkeyManager` (global `NSEvent.flagsChanged` monitor; Esc aborts) → `AudioEngine`
(mic capture → 16 kHz mono Int16 PCM) → `DeepgramService` (URLSession WebSocket stream,
interim + final transcripts) → optional `LLMService` (Groq/OpenRouter post-processing:
spelling/grammar/code-mix transliteration/translation) → `TextInjector` (writes to
pasteboard, posts synthetic Cmd+V, then restores the old clipboard).

**State & persistence:**
- `AppState` — the single `ObservableObject` shared everywhere; owns recording state,
  transcript history, and all settings (backed by `UserDefaults`, keys centralized in the
  private `DefaultsKey` enum). Note settings survive reinstalls — reset via
  `defaults delete com.vocalflow.app`.
- `KeychainService` — API keys (never on disk in plaintext).
- `MenuBarController` — the `NSStatusItem` menu, recent-transcripts submenu, error surfacing,
  and hosts `SettingsView` (SwiftUI) + `RecordingOverlayController` (waveform overlay).

**Settings UI** — `SettingsView` is a sidebar + pages layout (Wispr-style): the private
`SettingsSection` enum defines the pages (Dictation, Transcription, AI Polish, Corrections,
Dictionary, Permissions, About) with per-section icon/chip-color/subtitle; shared visual
primitives (`VLCard`, `VLField`, button styles, brand colors) live in `Theme.swift` and are
also used by onboarding. The settings window uses a hidden titlebar
(`.fullSizeContentView`), so the sidebar owns the full window height. The **Dictionary**
page is entry-by-entry management (add/edit/favorite/delete) but is a pure UI layer over
the same newline `"key : value"` `focusWords` string — favorites live separately as a
lowercased-key set (`favorite_focus_words`), so `FocusWordsDictionary` parsing and
type-over auto-learn never see UI concerns.

**Focus Words + auto-learn** — `FocusWordsDictionary` holds user-pinned spellings (biased
into Deepgram as keyterms) and `trigger : replacement` expansions. `TypeOverWatcher` uses
the Accessibility API to detect when the user types over a just-dictated word and
auto-learns the corrected spelling. `TypeOverDetector` (in `TypeOverWatcher.swift`) is the
**pure, unit-tested** core: a count-based (not set-based) word diff that ignores a
hard-coded `commonWords` list.

**Auto-update** — `UpdaterManager` wraps Sparkle. The appcast feed and update `.zip` are
self-hosted at `https://www.vocallabs.ai/releases/vocalflow/`; `Info.plist`'s `SUFeedURL`
must match. `make-pkg.sh` regenerates and EdDSA-signs the appcast as part of a release.

## Non-obvious constraints

- **The `.app` bundle is hand-assembled** (`build.sh` / `make-pkg.sh`), not produced by
  Xcode. Sparkle.framework is copied into `Contents/Frameworks/` and found at runtime via
  the `@executable_path/../Frameworks` rpath baked in through `Package.swift`'s linker
  flags. Don't remove that linker setting.
- `make-pkg.sh` is the canonical, re-runnable release pipeline: universal build, inside-out
  signing of embedded Sparkle, notarization (keychain profile `AC_PROFILE_DIALER`, team
  `R65MP66K97`), stapling, zip, appcast generation. Config is overridable via env vars at
  the top of the script.
- `DEPLOY_TARGET` in `make-pkg.sh` must stay in sync with `Package.swift` `platforms` and
  `Info.plist` `LSMinimumSystemVersion`.

## Cross-platform reuse

`DeepgramService`, `LLMService`, `FocusWordsDictionary`, and `APIError` are written to be
platform-agnostic (URLSession + AVFoundation, no AppKit) and are **reused verbatim** by the
iOS spike. Everything else in `Sources/VocalFlow/` is macOS-only (global hotkey, Cmd+V
injection, Accessibility type-over, menu bar, Sparkle, system-audio mute) and has no iOS/
Windows equivalent.

### iOS port (`ios/`)
A de-risking spike, not a shippable app: a Custom Keyboard Extension (`KeyboardViewController`
+ `MicCapture` + `SpikeConfig`) that proves mic + Deepgram + text-insertion works *inside a
keyboard extension* under its ~50 MB memory ceiling. **No `.xcodeproj` is checked in** — it's
created in Xcode and these source files (plus copies of the shared services above) are added
to it. See `ios/README.md` for the full assembly steps. The real make-or-break test only
runs on a physical device, not the simulator. Requires Full Access (`RequestsOpenAccess`) and
`NSMicrophoneUsageDescription` in the extension's Info.plist.
