import AppKit

class HotkeyManager {
    private var flagsMonitor: Any?
    private var escapeMonitor: Any?
    private let appState: AppState
    private var triggerKeyIsDown = false

    /// Virtual key code for Esc (layout-independent).
    private static let escapeKeyCode: UInt16 = 53

    init(appState: AppState) {
        self.appState = appState
    }

    func startListening() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Esc anywhere in the system aborts an in-progress recording without
        // running transcription or pasting anything into the focused app.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            self?.cancelRecording()
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
            self.playFeedbackSound()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.appState.audioMuter.mute()
                do {
                    try self.appState.audioEngine.startCapture(
                        deviceUID: self.appState.selectedAudioDeviceUID
                    ) { [weak self] buffer, format in
                        self?.appState.deepgramService.sendAudioBuffer(buffer, format: format)
                    }
                } catch {
                    self.handleCaptureFailure(error)
                }
            }
        }
    }

    private func cancelRecording() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only act while actively recording — ignore Esc during transcription
            // or idle so we don't clobber a paste-in-flight or a normal Esc press.
            guard case .recording = self.appState.recordingState else { return }
            self.appState.audioEngine.stopCapture()
            self.appState.audioMuter.unmute()
            self.appState.deepgramService.cancel()
            // Discard the in-flight press so the imminent hotkey-up doesn't try
            // to "stop" a session we just aborted.
            self.triggerKeyIsDown = false
            self.appState.recordingState = .idle
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        appState.audioMuter.unmute()
        appState.deepgramService.cancel()
        let message = "Microphone failed: \(error.localizedDescription)"
        appState.recordingState = .error(message)
        appState.reportError(message)
        // Discard the in-flight press so the imminent key-up doesn't try to "stop"
        // a session that never started.
        triggerKeyIsDown = false
        // Auto-clear the error icon after a few seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if case .error = self.appState.recordingState {
                self.appState.recordingState = .idle
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appState.recordingState = .transcribing
            self.appState.audioEngine.stopCapture()
            self.appState.audioMuter.unmute()
            // Play chime after unmuting so it goes through
            self.playFeedbackSound()

            let finalTranscript = await self.appState.deepgramService.closeStream()
            guard !finalTranscript.isEmpty else {
                self.appState.recordingState = .idle
                return
            }

            let provider = self.appState.selectedLLMProvider
            let apiKey = self.appState.currentLLMAPIKey
            let model = self.appState.currentLLMModel
            let hasLLMConfig = !apiKey.isEmpty && !model.isEmpty

            let options = LLMProcessingOptions(
                codeMix: (self.appState.codeMixEnabled && !self.appState.selectedCodeMix.isEmpty)
                    ? self.appState.selectedCodeMix : nil,
                fixSpelling: self.appState.correctionModeEnabled,
                fixGrammar: self.appState.grammarCorrectionEnabled,
                targetLanguage: (self.appState.targetLanguageEnabled && !self.appState.selectedTargetLanguage.isEmpty)
                    ? self.appState.selectedTargetLanguage : nil,
                customPrompt: self.appState.customSystemPrompt
            )

            var processed: String? = nil
            if hasLLMConfig && options.hasAnyStep {
                do {
                    processed = try await self.appState.llmService.processText(
                        finalTranscript,
                        options: options,
                        provider: provider,
                        apiKey: apiKey,
                        model: model
                    )
                } catch let error as APIError {
                    // Fall back to raw transcript so the user doesn't lose their dictation.
                    self.appState.reportError("\(provider.displayName): \(error.userMessage)")
                } catch {
                    self.appState.reportError("\(provider.displayName): \(error.localizedDescription)")
                }
            }

            let typed = processed ?? finalTranscript
            self.appState.lastTranscript = typed
            self.appState.recordTranscript(raw: finalTranscript, processed: processed)
            self.appState.textInjector.inject(text: typed)
            self.appState.recordingState = .idle
        }
    }

    private func playFeedbackSound() {
        let name = appState.feedbackSoundName
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    deinit {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
