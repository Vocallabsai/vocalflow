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

            // Connect WebSocket and start capture immediately. DeepgramService
            // queues frames internally until the socket opens, so audio captured
            // during the handshake isn't lost. Previously we delayed capture by
            // 150ms (to let the chime finish before muting), which dropped the
            // start of the user's speech.
            self.appState.deepgramService.connect(
                apiKey: self.appState.deepgramAPIKey,
                model: self.appState.selectedModel,
                language: self.appState.selectedLanguage,
                keyterms: self.appState.focusWordTerms
            )
            do {
                try self.appState.audioEngine.startCapture(
                    deviceUID: self.appState.selectedAudioDeviceUID
                ) { [weak self] buffer, format in
                    self?.appState.deepgramService.sendAudioBuffer(buffer, format: format)
                }
            } catch {
                self.handleCaptureFailure(error)
                return
            }

            // Output-side feedback runs in parallel and doesn't gate capture.
            // The chime is short enough that any pickup by the mic transcribes
            // to nothing meaningful; the mute still waits so the chime isn't
            // cut off mid-play.
            self.playFeedbackSound()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.appState.audioMuter.mute()
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

            // Apply the focus-words dictionary deterministically as the final pass — after any LLM
            // processing — so it's the authoritative spelling/expansion override and works even with
            // no LLM configured.
            let llmText = processed ?? finalTranscript
            let typed = FocusWordsDictionary.apply(self.appState.focusWords, to: llmText)
            self.appState.lastTranscript = typed
            self.appState.recordTranscript(raw: finalTranscript, processed: typed == finalTranscript ? nil : typed)
            self.appState.textInjector.inject(text: typed)
            // Watch the focused field: if the user fixes a word's spelling, learn it.
            self.appState.noteInjection(typed)
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
