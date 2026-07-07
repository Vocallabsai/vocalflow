import UIKit
import AVFoundation

/// Spike keyboard: a single "hold to talk" button that records the mic, streams to
/// Deepgram, and inserts the transcript into whatever text field is focused via
/// `textDocumentProxy`. Reuses `DeepgramService` (copied from the macOS app).
///
/// This is the proof-of-concept for the make-or-break question: does mic + network
/// work inside a keyboard extension, under its memory limit? Build to a real device.
class KeyboardViewController: UIInputViewController {

    private let deepgram = DeepgramService()
    private let mic = MicCapture()
    private var isRecording = false

    private let micButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let nextKeyboardButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        deepgram.onPartialTranscript = { [weak self] text in
            guard let self, self.isRecording else { return }
            self.statusLabel.text = text.isEmpty ? "Listening…" : text
        }
    }

    // MARK: UI

    private func buildUI() {
        view.backgroundColor = UIColor(red: 0.047, green: 0.027, blue: 0.078, alpha: 1) // brand #0C0714

        statusLabel.text = "Hold the mic and speak"
        statusLabel.textColor = .lightGray
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.numberOfLines = 3
        statusLabel.textAlignment = .center

        micButton.setTitle("🎤  Hold to talk", for: .normal)
        micButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        micButton.setTitleColor(.white, for: .normal)
        micButton.backgroundColor = UIColor(red: 0.52, green: 0, blue: 1, alpha: 1) // brand accent #8400FF
        micButton.layer.cornerRadius = 14
        micButton.addTarget(self, action: #selector(startDictation), for: .touchDown)
        micButton.addTarget(self, action: #selector(stopDictation), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        nextKeyboardButton.setTitle("🌐", for: .normal)
        nextKeyboardButton.titleLabel?.font = .systemFont(ofSize: 20)
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        for v in [statusLabel, micButton, nextKeyboardButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // Keyboard height: use priority 999 (not required) so it doesn't fight the
        // system's own 'UIView-Encapsulated-Layout-Height' constraint on first layout.
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 240)
        heightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            heightConstraint,

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 8),
            micButton.widthAnchor.constraint(equalToConstant: 260),
            micButton.heightAnchor.constraint(equalToConstant: 66),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: Dictation

    @objc private func startDictation() {
        guard hasFullAccess else {
            statusLabel.text = "Enable “Allow Full Access” for VocalFlow in Settings → General → Keyboard."
            return
        }
        guard !isRecording else { return }
        requestMic { [weak self] granted in
            guard let self else { return }
            guard granted else { self.statusLabel.text = "Microphone denied — enable it in Settings."; return }
            self.beginStreaming()
        }
    }

    private func requestMic(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { g in DispatchQueue.main.async { completion(g) } }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { g in DispatchQueue.main.async { completion(g) } }
        }
    }

    private func beginStreaming() {
        isRecording = true
        statusLabel.text = "Listening…"
        deepgram.connect(apiKey: SpikeConfig.deepgramAPIKey, model: "nova-3-general", language: "en-US")
        mic.onBuffer = { [weak self] buffer, format in
            self?.deepgram.sendAudioBuffer(buffer, format: format)
        }
        do {
            try mic.start()
        } catch {
            statusLabel.text = "Mic failed: \(error.localizedDescription)"
            deepgram.cancel()
            isRecording = false
        }
    }

    @objc private func stopDictation() {
        guard isRecording else { return }
        isRecording = false
        mic.stop()
        statusLabel.text = "Transcribing…"
        Task { [weak self] in
            let text = await self?.deepgram.closeStream() ?? ""
            await MainActor.run {
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { self.textDocumentProxy.insertText(trimmed) }
                self.statusLabel.text = trimmed.isEmpty ? "Nothing heard — try again" : "Inserted ✓"
            }
        }
    }
}
