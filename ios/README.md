# VocalFlow iOS — keyboard + app-bounce dictation

## Spike verdict (read this first)

The original de-risking question was: *can a custom keyboard extension record the
mic and stream to Deepgram?* **Answer: no — iOS blocks audio capture inside
keyboard extensions at the system level.** Verified on a physical iPhone (iOS 26):
with Full Access on, mic permission granted, and the usage descriptions in place,
the audio *session* activates but audio I/O is refused at start by **both**
`AVAudioEngine` (`'what'` / 2003329396) and the C-level `AudioQueue`. This matches
the platform's documented behavior — it's why Wispr Flow's iOS keyboard doesn't
record inline either.

**The shipped architecture is therefore the app-bounce flow** (same as Wispr):

```
Messages (user taps 🎤 on VocalFlow keyboard)
   └─ keyboard opens vocalflow://dictate  ──►  VocalFlow app (foreground)
                                                 ├─ records mic (full app privileges)
                                                 ├─ streams to Deepgram, live transcript
                                                 └─ posts final text to the App Group "mailbox"
User taps the system ‹ back link (top-left)  ──►  back in Messages
   └─ keyboard reappears → consumes mailbox → textDocumentProxy.insertText(...)
```

Cost: one extra tap (the ‹ back link). Benefit: no 50 MB keyboard memory ceiling,
full app UI during dictation (live transcript, later AI polish/dictionary), and it
actually works.

## Components

- `VocalFlowKeyboard/KeyboardViewController.swift` — the keyboard: 🎤 opens the
  app (responder-chain `openURL:` — keyboards have no `UIApplication.shared`);
  `viewWillAppear` consumes any fresh pending transcript and inserts it.
- `VocalFlowKeyboard/SharedTranscript.swift` — the mailbox. Primary: a JSON file
  in the App Group container (`group.vocallabsai.VocalFlow`). Fallback when the
  container is unavailable: a custom-marked pasteboard item. Transcripts expire
  after 3 minutes and are consumed at most once.
- `VocalFlowApp/VocalFlowApp.swift` — container app: `onOpenURL` →
  `DictationController` (MicCapture + DeepgramService) → post to mailbox →
  "tap ‹ to go back" instructions.
- `VocalFlowKeyboard/MicCapture.swift` — mic → 16 kHz mono Int16 PCM. Used by the
  **app** (keyboards can't record); keeps an AudioQueue fallback path.
- `VocalFlowKeyboard/SpikeConfig.swift` — hardcoded Deepgram key placeholder
  (spike only — never commit a real key).
- Copies of the macOS app's `DeepgramService.swift` + `APIError.swift` +
  `URLConstants.swift` (cross-platform, reused verbatim).
- `VocalFlowApp/App-Info.plist` — registers the `vocalflow://` URL scheme
  (named `Info.plist` inside the Xcode project's `VocalFlow/` folder).
- `*.entitlements` — App Groups on both targets.

## Xcode project assembly

The `.xcodeproj` is not checked in. It lives on the dev Mac (`~/Desktop/VocalFlow`)
as an Xcode 16 synchronized-folders project:
- Root folders `VocalFlow/` (app: Assets, Info.plist, entitlements) and
  `VocalFlowKeyboard/` (all Swift sources + keyboard Info.plist + entitlements).
- Target membership via `PBXFileSystemSynchronizedBuildFileExceptionSet`: the app
  target additionally compiles `VocalFlowApp.swift`, `MicCapture.swift`,
  `DeepgramService.swift`, `APIError.swift`, `URLConstants.swift`,
  `SpikeConfig.swift`, `SharedTranscript.swift` from the keyboard folder.
- App target: `INFOPLIST_FILE = VocalFlow/Info.plist` (merged with the generated
  plist), `CODE_SIGN_ENTITLEMENTS`, `INFOPLIST_KEY_NSMicrophoneUsageDescription`.
- Keyboard target: `RequestsOpenAccess = YES` and `NSMicrophoneUsageDescription`
  in its Info.plist (the usage string must ALSO be on the **app** — a keyboard's
  mic request is TCC-attributed to the host app; missing it = instant SIGABRT).

To recreate from scratch: iOS App project (SwiftUI) + Custom Keyboard Extension
target named `VocalFlowKeyboard`, add these sources per the membership above, set
the plist/entitlements build settings, sign both targets (App Groups needs the
group registered; automatic signing handles it).

## Test flow (physical iPhone)

1. Run the **VocalFlow** scheme (not the keyboard scheme — extensions can't
   launch standalone) on the device.
2. Settings → General → Keyboard → Keyboards → Add **VocalFlow** → **Allow Full
   Access** (required for the keyboard to read the App Group mailbox).
3. In Messages/Notes: 🌐 → VocalFlow keyboard → tap **🎤 Dictate**.
4. The app opens → grant mic on first run → speak → **Done**.
5. Tap **‹** (top-left status-bar back link) → the keyboard inserts the text.

## Known limitations / next steps

- One extra tap (‹ back) per dictation — platform tax, same as Wispr.
- Free personal team: app runs ~7 days per install; App Groups *should* provision
  on personal teams — if signing rejects it, `SharedTranscript` automatically
  falls back to the marked-pasteboard transport (iOS shows a paste banner).
- Next: move the Deepgram key from `SpikeConfig` to app UI + App Group storage,
  hold-to-talk & auto-return polish, LLM post-processing, Focus Words reuse.
