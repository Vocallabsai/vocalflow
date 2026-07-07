# VocalFlow iOS — keyboard-extension spike

This folder holds the **de-risking spike** for iOS VocalFlow: a custom keyboard with a
"hold to talk" mic button that streams to Deepgram and inserts the transcript into the
focused field. The goal is to answer the make-or-break question **before** building the
full app: *does mic + network work inside a keyboard extension, on a real device?*

> These are source files only. iOS keyboard extensions need an **Xcode project** with an
> app target + a keyboard-extension target; you create that in Xcode (below) and add
> these files to it. There's no `.xcodeproj` checked in yet.

---

## 0. Prerequisites (one-time)

1. **Install Xcode** from the Mac App Store (~15 GB). You currently have only Command
   Line Tools, so nothing iOS builds until this is done.
2. Point the toolchain at it and accept the license:
   ```
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   ```
3. **Sign in with your Apple Developer account:** Xcode → Settings → Accounts → “+” →
   Apple ID. Your team should appear (needed for App Groups later + device signing).
4. **Prep your iPhone:** plug it in (or same Wi-Fi), and on the phone enable
   Settings → Privacy & Security → **Developer Mode**. Trust the Mac when prompted.

## 1. Create the Xcode project

1. Xcode → File → New → Project → **iOS → App**.
   - Product Name: **VocalFlow**   • Interface: **SwiftUI**   • Language: **Swift**
   - Team: your developer team   • Bundle ID: e.g. `ai.vocallabs.vocalflow`
   - Save it **inside this `ios/` folder**.
2. Add the keyboard target: File → New → **Target… → iOS → Custom Keyboard Extension**.
   - Name: **VocalFlowKeyboard** → Finish → **Activate** the scheme if asked.
   - Xcode auto-wires the extension's `NSExtension` Info.plist and embeds it in the app.

## 2. Add these source files to the right targets

- Delete the stub `KeyboardViewController.swift` Xcode generated in the keyboard target.
- Add to the **VocalFlowKeyboard** target: everything in `VocalFlowKeyboard/`
  (`KeyboardViewController.swift`, `MicCapture.swift`, `SpikeConfig.swift`) **plus** copies
  of the app's shared networking:
  - `../Sources/VocalFlow/DeepgramService.swift`
  - `../Sources/VocalFlow/APIError.swift`
  (These are already cross-platform. Add them via *Add Files…*; put them in a "Shared"
  group. Don't edit them.)
- Add to the **VocalFlow** app target: `VocalFlowApp/VocalFlowApp.swift` (replace the
  template's `ContentView`/App file).

## 3. Configure capabilities

- **Full Access** (required for mic + network in a keyboard): open the keyboard target's
  `Info.plist` → `NSExtension → NSExtensionAttributes → RequestsOpenAccess = YES`.
- **Microphone usage string**: add `NSMicrophoneUsageDescription` = "VocalFlow needs the
  microphone to transcribe your speech." to **both** the app and the keyboard `Info.plist`.
- **Deployment target**: iOS **16.0+** on both targets.
- **Signing**: both targets → Signing & Capabilities → your Team, "Automatically manage
  signing". (App Groups isn't needed for the spike — see Next steps.)

## 4. Add your Deepgram key (spike only)

Open `SpikeConfig.swift` and paste your Deepgram key into `deepgramAPIKey`.
**Don't commit a real key** — it's a local placeholder for the spike; the real app will
read it from a shared App Group written by the container app.

## 5. Build & run on your iPhone

1. Select the **VocalFlow** app scheme + your iPhone as the run destination → ⌘R.
2. First run: on the phone, Settings → General → VPN & Device Management → trust your
   developer cert.
3. Enable the keyboard: **Settings → General → Keyboard → Keyboards → Add New Keyboard →
   VocalFlow**, then tap it and turn on **Allow Full Access**.
4. Open Notes (or any app), tap 🌐 to switch to the VocalFlow keyboard, **hold the mic
   button and speak**, release → the transcript should type into the field.

## What to watch for (this is the test)

- Does the mic actually record from inside the keyboard, and does text insert? ✅ = viable.
- **Memory**: keyboard extensions are killed around ~50–60 MB. If it crashes mid-dictation,
  that's the key risk — note it.
- Coverage: it should work in Notes/Mail/most native fields; some apps restrict keyboards.

## Next steps (after the spike works)

1. **App Group** to share the Deepgram key (and settings) from the container app to the
   keyboard, replacing `SpikeConfig` (both targets → Signing & Capabilities → + App Groups
   → `group.ai.vocallabs.vocalflow`; store/read the key via `UserDefaults(suiteName:)`).
2. Build out the container app: onboarding, key entry + verify, LLM post-processing toggle,
   Focus Words (reuse `FocusWordsDictionary.swift`).
3. Factor the shared core (`DeepgramService`, `LLMService`, `FocusWordsDictionary`,
   `APIError`) into a real shared Swift package used by macOS + iOS instead of copies.
