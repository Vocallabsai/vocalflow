import SwiftUI
import Combine
import AVFoundation

/// Container app for the VocalFlow keyboard — and, in the bounce architecture,
/// the place where dictation actually happens (iOS forbids mic capture inside
/// keyboard extensions). The keyboard opens `vocalflow://dictate`; this app
/// records + streams to Deepgram, posts the transcript to `SharedTranscript`,
/// and the user taps the system ‹ back link to return and have it inserted.
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
                dictation.begin()
            }
        }
    }
}

// MARK: - Dictation engine (runs in the app, full privileges)

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

    private let mic = MicCapture()
    private let deepgram = DeepgramService()

    func begin() {
        isActive = true
        phase = .starting
        liveText = ""
        finalText = ""
        requestMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.phase = .failed("Microphone permission denied — enable it in Settings → Privacy → Microphone.")
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

    private func startRecording() {
        deepgram.onPartialTranscript = { [weak self] text in
            guard let self, case .recording = self.phase, !text.isEmpty else { return }
            self.liveText = text
        }
        deepgram.connect(apiKey: SpikeConfig.deepgramAPIKey, model: "nova-3-general", language: "en-US")
        mic.onBuffer = { [weak self] buffer, format in
            self?.deepgram.sendAudioBuffer(buffer, format: format)
        }
        do {
            try mic.start()
            phase = .recording
        } catch {
            deepgram.cancel()
            phase = .failed(error.localizedDescription)
        }
    }

    func finish() {
        guard case .recording = phase else { return }
        phase = .transcribing
        mic.stop()
        Task { [weak self] in
            guard let self else { return }
            let text = await self.deepgram.closeStream()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.finalText = text
            if text.isEmpty {
                self.phase = .failed("Nothing heard — try again.")
            } else {
                SharedTranscript.post(text)
                self.phase = .done
            }
        }
    }

    func retry() { begin() }

    func dismiss() {
        mic.stop()
        deepgram.cancel()
        isActive = false
    }
}

// MARK: - Dictation UI

struct DictationView: View {
    @ObservedObject var controller: DictationController

    private var brandPurple: Color { Color(red: 0.52, green: 0, blue: 1) }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("Cancel") { controller.dismiss() }
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
                    Label("Speak here, tap Done, then tap ‹ (top-left) to go back — the text types itself", systemImage: "4.circle")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Text("Dictation happens in this app because iOS doesn't allow keyboards to use the microphone. Full Access is required so the keyboard can pick the finished text up.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }
}
