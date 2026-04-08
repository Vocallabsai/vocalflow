import AppKit

class HotkeyManager {
    private var flagsMonitor: Any?
    private let appState: AppState
    private var triggerKeyIsDown = false

    init(appState: AppState) {
        self.appState = appState
    }

    func startListening() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let hotkey = appState.selectedHotkey
        guard event.keyCode == hotkey.keyCode else { return }

        let isNowPressed = event.modifierFlags.contains(hotkey.modifierFlag)

        if isNowPressed && !triggerKeyIsDown {
            triggerKeyIsDown = true
            startRecording()
        } else if !isNowPressed && triggerKeyIsDown {
            triggerKeyIsDown = false
            stopRecordingAndTranscribe()
        }
    }

    private func startRecording() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.recordingState = .recording
            // Start WebSocket early so connection is ready by the time capture begins
            self.appState.deepgramService.connect(
                apiKey: self.appState.deepgramAPIKey,
                model: self.appState.selectedModel,
                language: self.appState.selectedLanguage
            )
            // Play chime before muting so it isn't silenced
            NSSound(named: .init("Tink"))?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.appState.audioMuter.mute()
                self.appState.audioEngine.startCapture { [weak self] buffer, format in
                    self?.appState.deepgramService.sendAudioBuffer(buffer, format: format)
                }
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.recordingState = .transcribing
            self.appState.audioEngine.stopCapture()
            self.appState.audioMuter.unmute()
            // Play chime after unmuting so it goes through
            NSSound(named: .init("Tink"))?.play()
            self.appState.deepgramService.closeStream { [weak self] finalTranscript in
                guard let self else { return }
                guard !finalTranscript.isEmpty else {
                    DispatchQueue.main.async { self.appState.recordingState = .idle }
                    return
                }

                let inject: (String) -> Void = { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.appState.lastTranscript = text
                        self.appState.textInjector.inject(text: text)
                        self.appState.recordingState = .idle
                    }
                }

                let hasGroqConfig = !self.appState.groqAPIKey.isEmpty
                    && !self.appState.selectedGroqModel.isEmpty

                let options = GroqProcessingOptions(
                    codeMix: (self.appState.codeMixEnabled && !self.appState.selectedCodeMix.isEmpty)
                        ? self.appState.selectedCodeMix : nil,
                    fixSpelling: self.appState.correctionModeEnabled,
                    fixGrammar: self.appState.grammarCorrectionEnabled,
                    targetLanguage: (self.appState.targetLanguageEnabled && !self.appState.selectedTargetLanguage.isEmpty)
                        ? self.appState.selectedTargetLanguage : nil
                )

                if hasGroqConfig && options.hasAnyStep {
                    self.appState.groqService.processText(
                        finalTranscript,
                        options: options,
                        apiKey: self.appState.groqAPIKey,
                        model: self.appState.selectedGroqModel,
                        completion: inject
                    )
                } else {
                    inject(finalTranscript)
                }
            }
        }
    }

    deinit {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
