# VocalFlow iOS — keyboard + background dictation

**The Xcode project is checked in: open `ios/VocalFlow.xcodeproj` and hit ▶.**
(Sign both targets with your team on first open; free personal teams work —
installs just expire after ~7 days.)

## Architecture (and why)

The original spike asked: *can a custom keyboard extension record the mic?*
**No — iOS blocks audio capture inside keyboard extensions at the system
level.** Verified on device (iOS 26): with Full Access + mic permission +
usage strings all in place, the audio session activates but audio I/O is
refused at start by both `AVAudioEngine` ('what' / 2003329396) and the
C-level `AudioQueue`. Same restriction Wispr Flow works around.

So VocalFlow uses the **background-dictation** architecture (Wispr-parity):

```
Messages: user taps 🎤 on the VocalFlow keyboard
  ├─ hot mic (≤3 min since last dictation)?
  │    └─ keyboard sends "start" → the backgrounded app begins streaming
  │       instantly — NO app switch at all
  └─ cold start?
       └─ keyboard opens vocalflow://dictate → app starts recording →
          auto-returns via the suspend selector (~0.5 s flicker)
While recording: app streams mic → Deepgram in the BACKGROUND
  (UIBackgroundModes: audio; orange mic indicator on), heartbeating live
  state (partial transcript + RMS level) to the keyboard every 0.15 s
Keyboard = remote control: waveform + live words; ✓ = stop, ✕ = cancel
On ✓: app flushes the stream, posts the transcript → keyboard inserts it
```

The keyboard↔app bridge (`SharedTranscript.swift`) is an App Group file
mailbox + Darwin notifications, with a marked-pasteboard fallback and a
keyboard-side watchdog (recording state silent >6 s ⇒ "lost connection").

## Layout

- `VocalFlow.xcodeproj` — checked in, shared scheme included. Xcode 16
  synchronized-folders project; target membership lives in
  `PBXFileSystemSynchronizedBuildFileExceptionSet` blocks.
- `VocalFlow/` — app target's folder: assets, `Info.plist` (URL scheme +
  `UIBackgroundModes: audio`), entitlements.
- `VocalFlowKeyboard/` — all Swift sources (the app target compiles
  `VocalFlowApp.swift`, `MicCapture.swift`, `SharedTranscript.swift`,
  `AppSettings.swift` + the shared services from here via membership
  exceptions), keyboard `Info.plist` (`RequestsOpenAccess`), entitlements.
- `DeepgramService.swift`, `APIError.swift`, `URLConstants.swift` are copies
  of the macOS app's cross-platform files — keep them in sync with
  `Sources/VocalFlow/`.

The Deepgram key is **not in code**: the app's setup screen has a
Save & Verify field; the key lives in App Group `UserDefaults`
(`AppSettings.swift` — graduate to Keychain before shipping).

## Run / test (physical iPhone; the simulator can't test the keyboard flow)

1. Open `ios/VocalFlow.xcodeproj`, select the **VocalFlow** scheme + your
   iPhone, ▶. (Both targets: Signing & Capabilities → your team.)
2. In the app: paste your Deepgram key → **Save & Verify**.
3. Settings → General → Keyboard → Keyboards → Add **VocalFlow** →
   **Allow Full Access**.
4. Any app: 🌐 → VocalFlow → **🎤** → speak (watch live words on the
   keyboard) → **✓** → text inserts. Repeat taps within 3 min start
   instantly with no app switch.

## Known constraints / next steps

- The mic indicator stays on during the 3-min hot window (mic is genuinely
  held open for instant restarts) — tune `keepAliveSeconds` in
  `VocalFlowApp.swift`.
- Private APIs used (fine for dev; revisit for App Store review): the
  `suspend` selector for auto-return (fallback: URL-scheme map) and the
  host-bundle-ID KVC read. Review will also scrutinize a Full Access
  keyboard streaming mic audio off-device — needs clear disclosure.
- Next: LLM post-processing (reuse `LLMService`), Focus Words/Dictionary
  (reuse `FocusWordsDictionary`, feed keyterms into `connect`), transcript
  history, Keychain key storage, paid-team signing + TestFlight.
