import AVFoundation
import Speech
import os.log

private let asLogger = Logger(subsystem: "com.vocalflow.app", category: "applespeech")

/// The surface the hotkey pipeline drives, so the speech-to-text backend can be swapped.
protocol TranscriptionEngine: AnyObject {
    /// Running transcript for the overlay. Always called on the main queue.
    var onPartialTranscript: ((String) -> Void)? { get set }
    func begin(apiKey: String, model: String, language: String, keyterms: [String])
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat)
    func closeStream() async -> String
    func cancel()
}

extension DeepgramService: TranscriptionEngine {
    func begin(apiKey: String, model: String, language: String, keyterms: [String]) {
        connect(apiKey: apiKey, model: model, language: language, keyterms: keyterms)
    }
}

enum TranscriptionEngineKind: String, CaseIterable, Identifiable {
    case apple
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:    return "On-device (Apple)"
        case .deepgram: return "Deepgram (cloud)"
        }
    }

    static var isAppleAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static var defaultKind: TranscriptionEngineKind { isAppleAvailable ? .apple : .deepgram }
}

/// On-device transcription with Apple's `DictationTranscriber` — the engine behind macOS
/// dictation. Audio never leaves the Mac and no API key is needed.
///
/// Mirrors `DeepgramService`'s lifecycle: `begin` on hotkey-down, `sendAudioBuffer` per mic
/// buffer, `closeStream` on hotkey-up. Analyzer setup is async (model load), so buffers that
/// arrive before it's ready are held and fed in order once it is — no speech is dropped.
@available(macOS 26, *)
final class AppleSpeechService: TranscriptionEngine {
    var onPartialTranscript: ((String) -> Void)?
    /// Non-fatal setup/recognition failures, for surfacing in the menu bar.
    var onError: ((String) -> Void)?

    private let lock = NSLock()
    private var session = 0
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    /// False once the hotkey is released; the stream is finished as soon as any audio
    /// buffered during model setup has been fed in.
    private var acceptingAudio = false
    private var formatResolved = false
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var analyzer: SpeechAnalyzer?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""

    // MARK: - TranscriptionEngine

    func begin(apiKey: String, model: String, language: String, keyterms: [String]) {
        cancel()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        session += 1
        let id = session
        self.continuation = continuation
        acceptingAudio = true
        lock.unlock()
        emitPartial()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(session: id, stream: stream, language: language, keyterms: keyterms)
        }
        lock.lock()
        setupTask = task
        lock.unlock()
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingAudio, continuation != nil else { return }
        if formatResolved {
            yieldConverted(buffer)
        } else {
            pendingBuffers.append(buffer)
        }
    }

    func closeStream() async -> String {
        let (id, setup) = stopAcceptingAudio()

        // Finalize whatever was heard; cap the wait so a stuck model can't hang the pipeline.
        await Self.withTimeout(seconds: 6) { [weak self] in
            await setup?.value
            guard let self else { return }
            let (analyzer, results) = self.lock.withLock { (self.analyzer, self.resultsTask) }
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                asLogger.error("Finalize failed: \(error.localizedDescription, privacy: .public)")
            }
            await results?.value
        }

        let text = lock.withLock { isCurrentLocked(id) ? Self.join(finalText, volatileText) : "" }
        teardown()
        return text
    }

    private func stopAcceptingAudio() -> (Int, Task<Void, Never>?) {
        lock.withLock {
            acceptingAudio = false
            if formatResolved {
                continuation?.finish()
                continuation = nil
            }
            return (session, setupTask)
        }
    }

    /// Hand a ready analyzer to the live session and feed it audio buffered during setup.
    /// Returns false if the session was cancelled or superseded meanwhile.
    private func install(analyzer: SpeechAnalyzer, results: Task<Void, Never>, format: AVAudioFormat?, session id: Int) -> Bool {
        lock.withLock {
            guard isCurrentLocked(id) else { return false }
            self.analyzer = analyzer
            self.resultsTask = results
            self.analyzerFormat = format
            self.formatResolved = true
            let buffered = pendingBuffers
            pendingBuffers.removeAll()
            for buffer in buffered { yieldConverted(buffer) }
            if !acceptingAudio {
                continuation?.finish()
                continuation = nil
            }
            return true
        }
    }

    func cancel() {
        lock.lock()
        session += 1
        acceptingAudio = false
        continuation?.finish()
        continuation = nil
        let analyzer = self.analyzer
        lock.unlock()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        teardown()
    }

    /// Ensure the speech model for `language` is installed, so the first dictation doesn't
    /// wait on a download. Safe to call repeatedly.
    func prepare(language: String) {
        Task {
            await Self.requestAuthorizationIfNeeded()
            do {
                let transcriber = DictationTranscriber(locale: await Self.resolveLocale(language), preset: Self.preset)
                try await Self.ensureAssets(for: transcriber)
            } catch {
                asLogger.error("Model install failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Pipeline

    private static var preset: DictationTranscriber.Preset {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.transcriptionOptions.insert(.punctuation)
        return preset
    }

    private func run(session id: Int, stream: AsyncStream<AnalyzerInput>, language: String, keyterms: [String]) async {
        do {
            let locale = await Self.resolveLocale(language)
            let transcriber = DictationTranscriber(locale: locale, preset: Self.preset)
            try await Self.ensureAssets(for: transcriber)

            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            )
            if !keyterms.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = keyterms
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)

            let results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result, session: id)
                    }
                } catch {
                    asLogger.error("Results failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            guard install(analyzer: analyzer, results: results, format: format, session: id) else {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                return
            }

            try await analyzer.start(inputSequence: stream)
        } catch {
            asLogger.error("On-device transcription failed: \(error.localizedDescription, privacy: .public)")
            onError?("On-device transcription: \(error.localizedDescription)")
        }
    }

    private func handle(_ result: DictationTranscriber.Result, session id: Int) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard isCurrentLocked(id) else { lock.unlock(); return }
        if result.isFinal {
            finalText = Self.join(finalText, text)
            volatileText = ""
        } else {
            volatileText = text
        }
        lock.unlock()
        emitPartial()
    }

    /// Caller must hold `lock`.
    private func yieldConverted(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        guard let target = analyzerFormat, target != buffer.format else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil && output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    private func emitPartial() {
        lock.lock()
        let combined = Self.join(finalText, volatileText)
        lock.unlock()
        let callback = onPartialTranscript
        DispatchQueue.main.async { callback?(combined) }
    }

    private func teardown() {
        lock.lock()
        setupTask?.cancel()
        setupTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        converter = nil
        analyzerFormat = nil
        formatResolved = false
        pendingBuffers.removeAll()
        finalText = ""
        volatileText = ""
        lock.unlock()
    }

    /// Caller must hold `lock`.
    private func isCurrentLocked(_ id: Int) -> Bool { id == session }

    // MARK: - Helpers

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private static func resolveLocale(_ identifier: String) async -> Locale {
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
            return match
        }
        return await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en-US")
    }

    private static func ensureAssets(for transcriber: DictationTranscriber) async throws {
        if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
        for locale in transcriber.selectedLocales {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            asLogger.info("Downloading on-device speech model")
            try await request.downloadAndInstall()
        }
    }

    private static func requestAuthorizationIfNeeded() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    private static func withTimeout(seconds: Double, _ work: @escaping () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
}
