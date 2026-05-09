import Foundation
import AVFoundation
import os.log

private let dgLogger = Logger(subsystem: "com.vocalflow.app", category: "deepgram")

// MARK: - Public model type

struct DeepgramModel: Identifiable, Hashable {
    let canonicalName: String
    let displayName: String
    let languages: [String]
    var id: String { canonicalName }
}

// MARK: - Service

class DeepgramService: NSObject, URLSessionWebSocketDelegate {
    private static let listenURL = URL(staticString: "wss://api.deepgram.com/v1/listen")
    private static let modelsURL = URL(staticString: "https://api.deepgram.com/v1/models")

    /// Fired whenever the live transcript changes (interim or final). Always called on the main queue.
    /// The string is the running transcript from the start of the current session, including the
    /// latest interim guess, so it's safe to bind directly to UI state.
    var onPartialTranscript: ((String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var accumulatedTranscript: String = ""
    private var currentInterim: String = ""
    private var finalTranscriptCallback: ((String) -> Void)?
    private var isWaitingForFinal = false
    private var timeoutWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
    }

    func connect(apiKey: String, model: String, language: String) {
        accumulatedTranscript = ""
        currentInterim = ""
        isWaitingForFinal = false
        finalTranscriptCallback = nil
        emitPartial()

        guard !apiKey.isEmpty else { return }

        guard var components = URLComponents(url: Self.listenURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("Invalid Deepgram listen URL")
        }
        components.queryItems = [
            URLQueryItem(name: "encoding",        value: "linear16"),
            URLQueryItem(name: "sample_rate",     value: "16000"),
            URLQueryItem(name: "channels",        value: "1"),
            URLQueryItem(name: "model",           value: model),
            URLQueryItem(name: "language",        value: language),
            URLQueryItem(name: "punctuate",       value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
        ]

        guard let url = components.url else {
            preconditionFailure("Failed to build Deepgram listen URL from components")
        }
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        dgLogger.info("WebSocket connecting (model=\(model), language=\(language))")
        receiveNext()
    }

    func fetchModels(apiKey: String) async throws -> [DeepgramModel] {
        guard !apiKey.isEmpty else { throw APIError.missingKey }

        var request = URLRequest(url: Self.modelsURL)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            dgLogger.error("/v1/models network error: \(error.localizedDescription)")
            throw APIError.network(error.localizedDescription)
        }

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(httpStatus) else {
            let body = String(data: data, encoding: .utf8)
            dgLogger.error("/v1/models HTTP \(httpStatus): \(body ?? "<binary>")")
            throw APIError.http(status: httpStatus, body: body)
        }
        guard let root = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            let body = String(data: data, encoding: .utf8)
            dgLogger.error("/v1/models decode failed: \(body ?? "<binary>")")
            throw APIError.decoding
        }

        // Group by canonical_name; collect languages union, streaming if any variant supports it
        var streamingSupport: [String: Bool] = [:]
        var displayNames: [String: String] = [:]
        var languageMap: [String: [String]] = [:]
        for m in root.stt ?? [] {
            guard let canonical = m.canonicalName, !canonical.isEmpty else { continue }
            streamingSupport[canonical] = (streamingSupport[canonical] ?? false) || (m.streaming ?? false)
            if displayNames[canonical] == nil { displayNames[canonical] = m.name }
            let existing = languageMap[canonical] ?? []
            let newLangs = (m.languages ?? []).filter { !existing.contains($0) }
            languageMap[canonical] = existing + newLangs
        }
        let models = streamingSupport
            .filter { $0.value }
            .map { (canonical, _) in
                var langs = (languageMap[canonical] ?? []).sorted()
                // Inject "multi" for nova-2 and nova-3 families (not returned by API)
                if canonical.hasPrefix("nova-2") || canonical.hasPrefix("nova-3") {
                    langs.append("multi")
                }
                return DeepgramModel(
                    canonicalName: canonical,
                    displayName: displayNames[canonical] ?? canonical,
                    languages: langs
                )
            }
            .sorted { $0.canonicalName < $1.canonicalName }
        dgLogger.info("/v1/models returned \(models.count) streaming models")
        return models
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let task = webSocketTask, task.state == .running else { return }
        guard let channelData = buffer.int16ChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let data = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)

        task.send(.data(data)) { _ in }
    }

    func closeStream() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            finalTranscriptCallback = { transcript in
                continuation.resume(returning: transcript)
            }
            isWaitingForFinal = true

            // Send empty binary frame — Deepgram's signal to flush and finalize
            webSocketTask?.send(.data(Data())) { [weak self] error in
                if error != nil {
                    self?.deliverAndDisconnect()
                }
            }

            // Safety timeout: deliver what we have after 3 seconds
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isWaitingForFinal else { return }
                self.deliverAndDisconnect()
            }
            timeoutWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0, execute: workItem)
        }
    }

    /// Tear down a connection without waiting for any final transcript. Safe to call
    /// when an upstream failure (e.g. mic capture failed to start) means there's
    /// nothing to deliver.
    func cancel() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        finalTranscriptCallback = nil
        isWaitingForFinal = false
        accumulatedTranscript = ""
        currentInterim = ""
        disconnect()
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handleMessage(text)
                }
                self.receiveNext()
            case .failure(let error):
                dgLogger.error("WebSocket receive failed: \(error.localizedDescription)")
                if self.isWaitingForFinal {
                    self.deliverAndDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(DeepgramResponse.self, from: data) else {
            return
        }

        let transcript = response.channel?.alternatives?.first?.transcript ?? ""

        if response.isFinal == true {
            if !transcript.isEmpty {
                if !accumulatedTranscript.isEmpty {
                    accumulatedTranscript += " "
                }
                accumulatedTranscript += transcript
            }
            // Final result supersedes any interim guess for this utterance.
            currentInterim = ""
            emitPartial()
        } else {
            // Interim: each message replaces the previous interim guess for the current utterance.
            currentInterim = transcript
            emitPartial()
        }

        // speech_final = true means Deepgram received our stream-close signal and is done
        if isWaitingForFinal && response.isFinal == true && response.speechFinal == true {
            timeoutWorkItem?.cancel()
            deliverAndDisconnect()
        }
    }

    private func emitPartial() {
        let combined: String
        if currentInterim.isEmpty {
            combined = accumulatedTranscript
        } else if accumulatedTranscript.isEmpty {
            combined = currentInterim
        } else {
            combined = accumulatedTranscript + " " + currentInterim
        }
        let callback = onPartialTranscript
        DispatchQueue.main.async { callback?(combined) }
    }

    private func deliverAndDisconnect() {
        guard isWaitingForFinal else { return }
        isWaitingForFinal = false
        let transcript = accumulatedTranscript
        let callback = finalTranscriptCallback
        finalTranscriptCallback = nil
        callback?(transcript)
        disconnect()
    }

    private func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DeepgramService {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if isWaitingForFinal {
            deliverAndDisconnect()
        }
    }
}

// MARK: - Response Models

private struct DeepgramResponse: Codable {
    let channel: DeepgramChannel?
    let isFinal: Bool?
    let speechFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case channel
        case isFinal     = "is_final"
        case speechFinal = "speech_final"
    }
}

private struct DeepgramChannel: Codable {
    let alternatives: [DeepgramAlternative]?
}

private struct DeepgramAlternative: Codable {
    let transcript: String?
    let confidence: Double?
}

private struct ModelsResponse: Codable {
    let stt: [ModelEntry]?
    let tts: [ModelEntry]?
}

private struct ModelEntry: Codable {
    let name: String?
    let canonicalName: String?
    let streaming: Bool?
    let languages: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case canonicalName = "canonical_name"
        case streaming
        case languages
    }
}
