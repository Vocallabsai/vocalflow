import SwiftUI
import Combine
import AVFoundation

/// Container app for the VocalFlow keyboard — and the actual recorder in the
/// background-dictation architecture (iOS forbids mic capture inside keyboard
/// extensions). Flow:
///   1. Keyboard opens `vocalflow://dictate?host=<bundle id>`.
///   2. This app starts recording + streaming to Deepgram, then immediately
///      bounces back to the host app (URL scheme map) — recording continues in
///      the background (`UIBackgroundModes: audio`), with live partials pushed
///      to the keyboard through the App Group + Darwin notifications.
///   3. The keyboard's ✓/✕ arrive as commands; on stop we post the final
///      transcript, which the keyboard inserts.
@main
struct VocalFlowApp: App {
    @StateObject private var dictation = DictationController()

    var body: some Scene {
        WindowGroup {
            Group {
                if dictation.isActive {
                    DictationView(controller: dictation)
                } else {
                    SetupView()
                }
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "vocalflow" else { return }
                let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "host" })?.value
                dictation.begin(returnToHost: host)
            }
        }
    }
}

// MARK: - Dictation engine (records here; the keyboard remote-controls it)

@MainActor
final class DictationController: ObservableObject {
    enum Phase {
        case starting, recording, transcribing, done
        case failed(String)
    }

    @Published var isActive = false
    @Published var phase: Phase = .starting
    @Published var liveText = ""
    @Published var finalText = ""
    /// True when we auto-returned to the host app — recording continues in the
    /// background and the keyboard is the primary UI.
    @Published var runningInBackground = false

    private let mic = MicCapture()
    private let deepgram = DeepgramService()
    private var commandObserver: DarwinObserver?
    private var returnURL: URL?

    /// Mic session stays hot for a while after a dictation so the next one can
    /// start instantly from the keyboard — no app flicker. The orange mic
    /// indicator stays on during this window (the mic is genuinely held open).
    private var micHot = false
    private var keepAliveTimer: Timer?
    private static let keepAliveSeconds: TimeInterval = 180

    init() {
        // Commands from the keyboard, delivered foreground OR background.
        commandObserver = DarwinObserver(name: SharedTranscript.commandNote) { [weak self] in
            guard let self, let command = SharedTranscript.takeCommand() else { return }
            switch command {
            case "start":  self.startFromKeyboard()
            case "stop":   self.finish()
            case "cancel": self.cancel()
            default: break
            }
        }
    }

    /// 🎤 tapped on the keyboard. Hot mic → start instantly in the background
    /// (no app switch). Cold + we happen to be foreground → normal start.
    /// Cold + backgrounded/dead → do nothing; the keyboard times out and falls
    /// back to opening the app via URL.
    private func startFromKeyboard() {
        if micHot {
            startHotDictation()
        } else if UIApplication.shared.applicationState == .active {
            begin(returnToHost: nil)
        }
    }

    private func startHotDictation() {
        keepAliveTimer?.invalidate()
        isActive = true
        runningInBackground = true
        liveText = ""
        finalText = ""
        wireDeepgram()
        phase = .recording
        SharedTranscript.writeState(.recording)
    }

    /// Bundle-id → URL-scheme map for bouncing back to where the user was
    /// dictating. Unknown hosts fall back to the manual ‹ back link.
    private static let returnSchemes: [String: String] = [
        "com.apple.MobileSMS": "sms:",
        "com.apple.mobilemail": "message:",
        "com.apple.mobilenotes": "mobilenotes:",
        "net.whatsapp.WhatsApp": "whatsapp://",
        "com.tinyspeck.chatlyio": "slack://",
        "ph.telegra.Telegraph": "tg://",
        "com.burbn.instagram": "instagram://",
        "com.google.chrome.ios": "googlechrome://",
        "com.hammerandchisel.discord": "discord://",
        "com.google.Gmail": "googlegmail://",
    ]

    func begin(returnToHost host: String?) {
        returnURL = host.flatMap { Self.returnSchemes[$0] }.flatMap { URL(string: $0) }
        isActive = true
        runningInBackground = false
        phase = .starting
        liveText = ""
        finalText = ""
        requestMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.fail("Microphone permission denied — enable it in Settings → Privacy → Microphone.")
                return
            }
            self.startRecording()
        }
    }

    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    /// Connect a fresh Deepgram stream and route mic buffers into it.
    private func wireDeepgram() {
        deepgram.onPartialTranscript = { [weak self] text in
            guard let self, case .recording = self.phase, !text.isEmpty else { return }
            self.liveText = text
            SharedTranscript.writeState(.recording, partial: text)
        }
        deepgram.connect(apiKey: SpikeConfig.deepgramAPIKey, model: "nova-3-general", language: "en-US")
        mic.onBuffer = { [weak self] buffer, format in
            self?.deepgram.sendAudioBuffer(buffer, format: format)
        }
    }

    private func startRecording() {
        wireDeepgram()
        do {
            try mic.start()
            phase = .recording
            SharedTranscript.writeState(.recording)
            bounceBack()
        } catch {
            deepgram.cancel()
            fail(error.localizedDescription)
        }
    }

    /// Hop straight back to whatever app the user was typing in. The audio
    /// session keeps running thanks to UIBackgroundModes=audio; the keyboard
    /// takes over as the UI.
    private func bounceBack() {
        // Give the session a beat to be fully established before backgrounding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, case .recording = self.phase else { return }
            self.runningInBackground = true
            // The `suspend` selector backgrounds us and iOS resumes the
            // previous app — universal, no host-app detection needed.
            // (Private API: fine for the spike; an App Store build would lead
            // with the URL-scheme map and keep this as fallback.)
            let suspend = NSSelectorFromString("suspend")
            if UIApplication.shared.responds(to: suspend) {
                UIApplication.shared.perform(suspend)
            } else if let url = self.returnURL {
                UIApplication.shared.open(url)
            }
        }
    }

    func finish() {
        guard case .recording = phase else { return }
        phase = .transcribing
        SharedTranscript.writeState(.transcribing)
        // Pause streaming but keep the engine + session hot so the next
        // dictation can start instantly from the keyboard (keep-alive window).
        mic.onBuffer = nil
        // Safety net for the stream flush in case iOS reevaluates our
        // background rights.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "finish-dictation")
        Task { [weak self] in
            defer { UIApplication.shared.endBackgroundTask(bgTask) }
            guard let self else { return }
            let text = await self.deepgram.closeStream()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.finalText = text
            if text.isEmpty {
                self.fail("Nothing heard — try again.")
            } else {
                SharedTranscript.post(text)
                SharedTranscript.writeState(.done)
                self.phase = .done
                self.startKeepAlive()
                // If the keyboard drove this, our work is done — go idle so the
                // next start begins clean.
                if self.runningInBackground { self.isActive = false }
            }
        }
    }

    private func startKeepAlive() {
        micHot = true
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: Self.keepAliveSeconds,
                                              repeats: false) { [weak self] _ in
            Task { @MainActor in self?.coolDown() }
        }
    }

    /// Fully release the microphone (ends the orange indicator; the next
    /// dictation will need the app-flicker start again).
    private func coolDown() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        micHot = false
        mic.stop()
    }

    func cancel() {
        deepgram.cancel()
        coolDown()
        SharedTranscript.clearState()
        isActive = false
        runningInBackground = false
    }

    func retry() { begin(returnToHost: nil) }

    private func fail(_ message: String) {
        coolDown()
        phase = .failed(message)
        SharedTranscript.writeState(.failed, message: message)
    }
}

// MARK: - Dictation UI (shown when the app itself is in front)

struct DictationView: View {
    @ObservedObject var controller: DictationController

    private var brandPurple: Color { Color(red: 0.52, green: 0, blue: 1) }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("Cancel") { controller.cancel() }
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()

            switch controller.phase {
            case .starting:
                ProgressView().controlSize(.large)
                Text("Starting microphone…").foregroundStyle(.secondary)

            case .recording:
                Image(systemName: "waveform")
                    .font(.system(size: 56))
                    .foregroundStyle(brandPurple)
                Text(controller.liveText.isEmpty ? "Listening… speak now" : controller.liveText)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 80)
                Text("Tap ‹ (top-left) to go back to your app — keep talking, the keyboard shows everything live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    controller.finish()
                } label: {
                    Text("Done")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(brandPurple)

            case .transcribing:
                ProgressView().controlSize(.large)
                Text("Transcribing…").foregroundStyle(.secondary)

            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text(controller.finalText)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                GroupBox {
                    Label("Tap ‹ in the top-left corner to go back — the VocalFlow keyboard will type this for you.",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.callout)
                }
                Button("Copy instead") {
                    UIPasteboard.general.string = controller.finalText
                }
                .font(.callout)
                .foregroundStyle(.secondary)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Try Again") { controller.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(brandPurple)
            }

            Spacer()
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Default screen (setup instructions)

struct SetupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.purple)
                Text("VocalFlow").font(.largeTitle.bold())
            }
            Text("Voice dictation keyboard (spike build)").foregroundStyle(.secondary)

            GroupBox("Enable the keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Settings → General → Keyboard → Keyboards → Add New Keyboard… → VocalFlow", systemImage: "1.circle")
                    Label("Tap VocalFlow in that list → turn on “Allow Full Access”", systemImage: "2.circle")
                    Label("In any app, tap 🌐 to switch to VocalFlow, then tap 🎤 Dictate", systemImage: "3.circle")
                    Label("VocalFlow flickers open, hops back, and you just talk — tap ✓ on the keyboard to insert", systemImage: "4.circle")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Text("Dictation records in this app (iOS doesn't let keyboards use the microphone) and keeps running in the background while you're back in your app. Full Access lets the keyboard pick the text up.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }
}
