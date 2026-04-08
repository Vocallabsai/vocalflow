import Foundation
import AVFoundation

// MARK: - Public model type

struct DeepgramModel: Identifiable, Hashable {
    let canonicalName: String
    let displayName: String
    let languages: [String]
    var id: String { canonicalName }
}

// MARK: - Service

class DeepgramService: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var accumulatedTranscript: String = ""
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
        isWaitingForFinal = false
        finalTranscriptCallback = nil

        guard !apiKey.isEmpty else { return }

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "encoding",        value: "linear16"),
            URLQueryItem(name: "sample_rate",     value: "16000"),
            URLQueryItem(name: "channels",        value: "1"),
            URLQueryItem(name: "model",           value: model),
            URLQueryItem(name: "language",        value: language),
            URLQueryItem(name: "punctuate",       value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveNext()
    }

    func fetchModels(apiKey: String, completion: @escaping ([DeepgramModel]) -> Void) {
        guard !apiKey.isEmpty else { completion([]); return }

        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/models")!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil,
                  let root = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
                completion([])
                return
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
            completion(models)
        }.resume()
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let task = webSocketTask, task.state == .running else { return }
        guard let channelData = buffer.int16ChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let data = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)

        task.send(.data(data)) { _ in }
    }

    func closeStream(completion: @escaping (String) -> Void) {
        finalTranscriptCallback = completion
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

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handleMessage(text)
                }
                self.receiveNext()
            case .failure:
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

        if response.isFinal == true && !transcript.isEmpty {
            if !accumulatedTranscript.isEmpty {
                accumulatedTranscript += " "
            }
            accumulatedTranscript += transcript
        }

        // speech_final = true means Deepgram received our stream-close signal and is done
        if isWaitingForFinal && response.isFinal == true && response.speechFinal == true {
            timeoutWorkItem?.cancel()
            deliverAndDisconnect()
        }
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
